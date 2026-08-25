import Foundation
import KeyPortCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): message } }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

func containsSSHOption(_ arguments: [String], _ option: String) -> Bool {
    arguments.indices.contains { index in
        arguments[index] == "-o" && arguments.indices.contains(index + 1) && arguments[index + 1] == option
    }
}

do {
    try expect(KeyPortNaming.alias(group: "Prod", name: "Doris DB") == "prod-doris-db", "grouped alias normalization")
    try expect(KeyPortNaming.alias(group: "", name: "CN2 YLY") == "cn2-yly", "ungrouped alias normalization")
    try expect(KeyPortNaming.alias(group: "Asia", name: "") == "asia", "group-only alias normalization")
    try expect(
        KeyPortNaming.accountAlias(group: "Prod", name: "Doris DB", username: "root") == "prod-doris-db-root",
        "account alias omitted username"
    )
    try expect(
        KeyPortNaming.accountAlias(group: "", name: "Build Server", username: "Deploy User") == "build-server-deploy-user",
        "account alias did not normalize username"
    )
    try expect(
        KeyPortNaming.availableAlias("build-server-root", avoiding: ["build-server-root", "build-server-root-2"]) == "build-server-root-3",
        "account alias collision was not resolved"
    )
    let groupingDate = Date(timeIntervalSince1970: 1_700_000_000)
    let groupedConnections = ServerConnectionGrouping.groups([
        ServerConnection(name: "Database", host: "DB.EXAMPLE.COM.", username: "root", alias: "database-root", createdAt: groupingDate),
        ServerConnection(name: "Legacy Account Label", host: "db.example.com", username: "deploy", alias: "database-deploy", createdAt: groupingDate.addingTimeInterval(1)),
        ServerConnection(name: "Database Admin", host: "db.example.com", port: 2222, username: "admin", alias: "database-admin")
    ])
    try expect(groupedConnections.count == 2, "accounts on the same endpoint were not grouped as one server")
    try expect(
        groupedConnections.first(where: { $0.port == 22 })?.accounts.map(\.username) == ["deploy", "root"],
        "server accounts were not sorted by username"
    )
    try expect(
        groupedConnections.first(where: { $0.port == 2222 })?.accounts.count == 1,
        "different SSH ports were merged into one server"
    )
    try expect(
        groupedConnections.first(where: { $0.port == 22 })?.representative.name == "Database",
        "server display identity changed with account sort order"
    )
    try expect(KeyPortNaming.isValidAlias("cn2-yly"), "native alias rejected")
    try expect(KeyPortNaming.isValidAlias("kp-prod-doris"), "valid alias rejected")
    try expect(KeyPortNaming.isValidAlias("server1"), "alphanumeric alias rejected")
    try expect(!KeyPortNaming.isValidAlias("Prod Doris"), "unsafe alias accepted")
    try expect(!KeyPortNaming.isValidAlias("-cn2"), "leading hyphen accepted")
    try expect(!KeyPortNaming.isValidAlias("cn2-"), "trailing hyphen accepted")
    try expect(!KeyPortNaming.isValidAlias("cn2--yly"), "repeated hyphen accepted")
    try expect(!KeyPortNaming.isValidAlias("*.internal"), "wildcard alias accepted")
    try expect(!KeyPortNaming.isValidAlias("!blocked"), "negated alias accepted")
    try expect(!KeyPortNaming.isValidAlias("cn2_yly"), "SSH-special alias accepted")

    let managed = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB7x8G9rWQ7vLFU+O1Av0N6wLwBMSdyKjb8iDL4kKzW6 keyport:v1:key_1:mac"
    guard let parsed = PublicKeyParser.parse(managed) else { throw CheckFailure.failed("public key parse") }
    try expect(parsed.kind == .ed25519, "key kind")
    try expect(parsed.fingerprint.hasPrefix("SHA256:"), "fingerprint shape")
    try expect(parsed.comment == "keyport:v1:key_1:mac", "comment parse")

    let authorizationServerID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let localAuthorization = Authorization(
        serverID: authorizationServerID,
        keyID: "local-key",
        fingerprint: parsed.fingerprint,
        remoteComment: "keyport:v1:local-key:mac",
        status: .authorized
    )
    let remoteAuthorization = Authorization(
        serverID: authorizationServerID,
        keyID: "remote-key",
        fingerprint: parsed.fingerprint,
        remoteComment: "keyport:v1:remote-key:mac",
        status: .authorized
    )
    try expect(localAuthorization.id == remoteAuthorization.id, "authorization identity was tied to a device-local key ID")
    let legacyAuthorizationJSON = """
    {
      "serverID": "00000000-0000-0000-0000-000000000002",
      "keyID": "legacy-key",
      "fingerprint": "SHA256:legacy",
      "remoteComment": "keyport:v1:legacy-key:mac",
      "status": "authorized",
      "authorizedAt": null,
      "lastVerifiedAt": null
    }
    """
    let legacyAuthorization = try JSONDecoder().decode(Authorization.self, from: Data(legacyAuthorizationJSON.utf8))
    try expect(
        !legacyAuthorization.isDeleted && legacyAuthorization.updatedAt == .distantPast && legacyAuthorization.version == 1,
        "legacy authorization did not decode with sync defaults"
    )

    let cloudServerID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let cloudBaseDate = Date(timeIntervalSince1970: 1_710_000_000)
    let cloudHostKey = HostKeyRecord(
        algorithm: "ssh-ed25519",
        fingerprint: "SHA256:host-key",
        knownHostsLine: "cloud.example ssh-ed25519 AAAAC3NzaAllowedHostKey",
        firstConfirmedAt: cloudBaseDate,
        lastSeenAt: cloudBaseDate
    )
    let cloudServer = ServerConnection(
        id: cloudServerID,
        name: "Cloud Server",
        host: "cloud.example",
        port: 2222,
        username: "deploy",
        alias: "cloud-deploy",
        group: "Production",
        notes: "CLOUD_SECRET_PASSWORD_MARKER",
        confirmedHostKeys: [cloudHostKey],
        status: .authorized,
        statusDetail: "CLOUD_LOCAL_CHECK_MARKER",
        lastCheckedAt: cloudBaseDate,
        passwordCheck: AuthenticationCheck(state: .succeeded, detail: "CLOUD_LOCAL_CHECK_MARKER", checkedAt: cloudBaseDate),
        keyCheck: AuthenticationCheck(state: .succeeded, detail: "CLOUD_LOCAL_CHECK_MARKER", checkedAt: cloudBaseDate),
        machineConfigurationRefreshAttemptedAt: cloudBaseDate,
        createdAt: cloudBaseDate,
        updatedAt: cloudBaseDate,
        version: 1
    )
    let cloudKey = SSHKeyRecord(
        id: "key_cloud",
        deviceID: "device-cloud",
        kind: .ed25519,
        publicKey: managed,
        fingerprint: parsed.fingerprint,
        privateKeyPath: "/CLOUD_PRIVATE_KEY_PATH_MARKER",
        isInAgent: true,
        origin: .generated,
        isLocallyAvailable: true
    )
    var unsafeCloudSnapshot = AppSnapshot()
    unsafeCloudSnapshot.servers = [cloudServer]
    unsafeCloudSnapshot.devices = [Device(id: "device-cloud", name: "Cloud Mac", isCurrent: true)]
    unsafeCloudSnapshot.keys = [cloudKey]
    unsafeCloudSnapshot.authorizations = [Authorization(
        serverID: cloudServerID,
        keyID: cloudKey.id,
        fingerprint: cloudKey.fingerprint,
        remoteComment: "keyport:v1:key_cloud:device-cloud",
        status: .authorized,
        authorizedAt: cloudBaseDate,
        lastVerifiedAt: cloudBaseDate,
        updatedAt: cloudBaseDate
    )]
    unsafeCloudSnapshot.auditEvents = [AuditEvent(category: "credential", action: "test", result: "CLOUD_AUDIT_MARKER")]

    let sanitizedCloudSnapshot = CloudMetadataSnapshotPolicy.sanitized(unsafeCloudSnapshot)
    let cloudEncoder = JSONEncoder()
    cloudEncoder.dateEncodingStrategy = .iso8601
    cloudEncoder.outputFormatting = [.sortedKeys]
    let cloudPayloadText = String(decoding: try cloudEncoder.encode(sanitizedCloudSnapshot), as: UTF8.self)
    try expect(!cloudPayloadText.contains("CLOUD_SECRET_PASSWORD_MARKER"), "CloudKit payload included free-form credential text")
    try expect(!cloudPayloadText.contains("CLOUD_PRIVATE_KEY_PATH_MARKER"), "CloudKit payload included a private key path")
    try expect(!cloudPayloadText.contains("CLOUD_LOCAL_CHECK_MARKER"), "CloudKit payload included local check state")
    try expect(!cloudPayloadText.contains("CLOUD_AUDIT_MARKER"), "CloudKit payload included audit data")
    try expect(sanitizedCloudSnapshot.servers.first?.host == "cloud.example", "CloudKit payload omitted server metadata")
    try expect(sanitizedCloudSnapshot.servers.first?.port == 2222, "CloudKit payload omitted SSH port")
    try expect(sanitizedCloudSnapshot.servers.first?.username == "deploy", "CloudKit payload omitted SSH username")
    try expect(sanitizedCloudSnapshot.servers.first?.alias == "cloud-deploy", "CloudKit payload omitted SSH alias")
    try expect(sanitizedCloudSnapshot.servers.first?.confirmedHostKeys.first?.fingerprint == "SHA256:host-key", "CloudKit payload omitted host key fingerprint")
    try expect(sanitizedCloudSnapshot.keys.first?.publicKey == managed, "CloudKit payload omitted public key")
    try expect(sanitizedCloudSnapshot.devices.first?.isCurrent == false, "CloudKit payload retained current-device state")
    try expect(sanitizedCloudSnapshot.auditEvents.isEmpty, "CloudKit payload retained audit events")

    var remoteCloudSnapshot = AppSnapshot()
    var updatedCloudServer = cloudServer
    updatedCloudServer.name = "Cloud Server Updated"
    updatedCloudServer.host = "updated-cloud.example"
    updatedCloudServer.notes = "REMOTE_SECRET_MARKER"
    updatedCloudServer.updatedAt = cloudBaseDate.addingTimeInterval(60)
    updatedCloudServer.version = 2
    remoteCloudSnapshot.servers = [updatedCloudServer]
    unsafeCloudSnapshot.servers.append(cloudServer)
    unsafeCloudSnapshot.keys.append(cloudKey)
    let mergedCloudSnapshot = CloudMetadataSnapshotPolicy.merge(local: unsafeCloudSnapshot, remote: remoteCloudSnapshot)
    let restoredCloudSnapshot = CloudMetadataSnapshotPolicy.restoringLocalState(in: mergedCloudSnapshot, from: unsafeCloudSnapshot)
    try expect(mergedCloudSnapshot.servers.count == 1, "duplicate server records survived stable-ID merge")
    try expect(mergedCloudSnapshot.keys.count == 1, "duplicate public keys survived fingerprint merge")
    try expect(restoredCloudSnapshot.servers.first?.host == "updated-cloud.example", "newer remote server metadata did not win")
    try expect(restoredCloudSnapshot.servers.first?.notes == "CLOUD_SECRET_PASSWORD_MARKER", "local-only server notes were not restored")
    try expect(restoredCloudSnapshot.servers.first?.status == .authorized, "local authorization status was not restored")
    try expect(restoredCloudSnapshot.keys.first?.privateKeyPath == "/CLOUD_PRIVATE_KEY_PATH_MARKER", "local private key path was not restored")
    try expect(restoredCloudSnapshot.auditEvents.first?.result == "CLOUD_AUDIT_MARKER", "local audit data was not restored")

    let activeAuthorization = Authorization(
        serverID: cloudServerID,
        keyID: "old-device-key-id",
        fingerprint: parsed.fingerprint,
        remoteComment: "keyport:v1:old-device-key-id:old-device",
        status: .authorized,
        updatedAt: cloudBaseDate.addingTimeInterval(600),
        version: 1
    )
    let revokedAuthorization = Authorization(
        serverID: cloudServerID,
        keyID: "revoked-device-key-id",
        fingerprint: parsed.fingerprint,
        remoteComment: "keyport:v1:revoked-device-key-id:revoked-device",
        status: .needsAuthorization,
        updatedAt: cloudBaseDate,
        isDeleted: true,
        version: 2
    )
    var activeAuthorizationSnapshot = AppSnapshot()
    activeAuthorizationSnapshot.authorizations = [activeAuthorization, activeAuthorization]
    var revokedAuthorizationSnapshot = AppSnapshot()
    revokedAuthorizationSnapshot.schemaVersion = 6
    revokedAuthorizationSnapshot.authorizations = [revokedAuthorization]
    let tombstoneMerge = CloudMetadataSnapshotPolicy.merge(
        local: activeAuthorizationSnapshot,
        remote: revokedAuthorizationSnapshot
    )
    try expect(tombstoneMerge.schemaVersion == 6, "newer snapshot schema version was discarded")
    try expect(tombstoneMerge.authorizations.count == 1, "duplicate authorization records survived stable-ID merge")
    try expect(tombstoneMerge.authorizations.first?.isDeleted == true, "older active authorization restored a tombstone")
    try expect(tombstoneMerge.authorizations.first?.version == 2, "authorization logical version was discarded")
    let repeatedTombstoneMerge = CloudMetadataSnapshotPolicy.merge(local: tombstoneMerge, remote: activeAuthorizationSnapshot)
    try expect(repeatedTombstoneMerge.authorizations.count == 1 && repeatedTombstoneMerge.authorizations.first?.isDeleted == true, "repeated sync restored revoked authorization")
    var clockSkewedActiveSnapshot = AppSnapshot()
    var clockSkewedActive = activeAuthorization
    clockSkewedActive.version = 2
    clockSkewedActive.updatedAt = cloudBaseDate.addingTimeInterval(86_400)
    clockSkewedActiveSnapshot.authorizations = [clockSkewedActive]
    let clockSkewMerge = CloudMetadataSnapshotPolicy.merge(local: clockSkewedActiveSnapshot, remote: revokedAuthorizationSnapshot)
    try expect(clockSkewMerge.authorizations.first?.isDeleted == true, "clock-skewed active snapshot replaced same-version tombstone")

    let reauthorized = Authorization(
        serverID: cloudServerID,
        keyID: "new-device-key-id",
        fingerprint: parsed.fingerprint,
        remoteComment: "keyport:v1:new-device-key-id:new-device",
        status: .authorized,
        updatedAt: cloudBaseDate.addingTimeInterval(1),
        isDeleted: false,
        version: 3
    )
    var reauthorizedSnapshot = AppSnapshot()
    reauthorizedSnapshot.authorizations = [reauthorized]
    let reauthorizationMerge = CloudMetadataSnapshotPolicy.merge(local: tombstoneMerge, remote: reauthorizedSnapshot)
    try expect(reauthorizationMerge.authorizations.first?.isDeleted == false, "higher-version explicit reauthorization did not replace tombstone")
    try expect(reauthorizationMerge.authorizations.first?.version == 3, "reauthorization version was discarded")

    let managedServerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let renamedServer = ServerConnection(
        id: managedServerID,
        name: "Renamed",
        host: "example.internal",
        username: "root",
        alias: "new-alias"
    )
    let regeneratedConfig = SSHConfigGenerator.managedConfig(entries: [
        SSHConfigEntry(server: renamedServer, identityPath: "~/.ssh/key-1"),
        SSHConfigEntry(server: renamedServer, identityPath: "~/.ssh/key-2")
    ])
    try expect(regeneratedConfig.contains("Host new-alias"), "renamed alias missing from managed config")
    try expect(!regeneratedConfig.contains("Host old-alias"), "old alias remained in managed config")
    try expect(
        regeneratedConfig.components(separatedBy: "\n").filter { $0 == "Host new-alias" }.count == 1,
        "multiple authorizations created duplicate Host blocks"
    )
    try expect(
        regeneratedConfig.components(separatedBy: "\n").filter { $0 == "    IdentityFile ~/.ssh/key-1" }.count == 1
            && regeneratedConfig.components(separatedBy: "\n").filter { $0 == "    IdentityFile ~/.ssh/key-2" }.count == 1,
        "multiple authorizations were not merged into one Host block"
    )

    let unknown = "from=\"10.0.0.0/8\",command=\"backup\" ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCy unknown"
    let removed = AuthorizedKeysParser.removingFingerprint(parsed.fingerprint, from: unknown + "\n" + managed + "\n")
    try expect(removed.contains(unknown), "unknown authorized_keys line changed")
    try expect(!removed.contains("keyport:v1:key_1"), "target key was not removed")

    let original = "Host *\n    ServerAliveInterval 30\n"
    let once = SSHConfigGenerator.addingManagedInclude(to: original)
    try expect(once.hasPrefix(SSHConfigGenerator.includeLine), "include must precede Host blocks")
    try expect(SSHConfigGenerator.addingManagedInclude(to: once) == once, "include is not idempotent")
    let quotedInclude = "Include   \"~/.ssh/keyport/config\"\n"
    try expect(SSHConfigGenerator.addingManagedInclude(to: quotedInclude) == quotedInclude, "quoted include was duplicated")
    let discoveredAliases = SSHConfigGenerator.aliases(in: """
    Host example other *.internal !blocked
    Host ?ingle
    Host final # ignored-comment
    Host\ttabbed
    HostName not-an-alias
    """)
    try expect(discoveredAliases == ["example", "other", "final", "tabbed"], "literal alias parse")

    let effectiveConfig = """
    hostname example.internal
    user deploy
    port 2222
    identityfile ~/.ssh/id_ed25519
    identityfile /Users/example/Keys/production key
    identitiesonly yes
    """
    guard let discovered = SSHConfigDiscoveryParser.parse(alias: "production", output: effectiveConfig) else {
        throw CheckFailure.failed("effective SSH config parse")
    }
    try expect(discovered.id == "production", "discovered connection identity")
    try expect(discovered.host == "example.internal" && discovered.port == 2222, "effective endpoint parse")
    try expect(discovered.username == "deploy", "effective username parse")
    try expect(discovered.identityFiles == ["~/.ssh/id_ed25519", "/Users/example/Keys/production key"], "effective identities parse")
    try expect(SSHConfigDiscoveryParser.parse(alias: "broken", output: "hostname example.com\nport invalid\nuser root\n") == nil, "invalid effective port accepted")

    let machineOutput = """
    hostname\tdb-01
    operating_system\tUbuntu 24.04.1 LTS
    kernel\tLinux 6.8.0
    architecture\tx86_64
    processor_count\t8
    memory_bytes\t17179869184
    """
    guard let machine = RemoteMachineConfigurationParser.parse(machineOutput, synchronizedAt: Date(timeIntervalSince1970: 1_700_000_000)) else {
        throw CheckFailure.failed("remote machine configuration parse")
    }
    try expect(machine.hostname == "db-01" && machine.operatingSystem == "Ubuntu 24.04.1 LTS", "remote machine identity parse")
    try expect(machine.processorCount == 8 && machine.memoryBytes == 17_179_869_184, "remote machine capacity parse")
    try expect(machine.capacitySummary == "8C16G", "remote machine capacity summary")
    let compactMachine = RemoteMachineConfiguration(
        hostname: "app-01",
        operatingSystem: "Linux",
        kernel: "Linux 6.8",
        architecture: "arm64",
        processorCount: 2,
        memoryBytes: 4_294_967_296,
        synchronizedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try expect(compactMachine.capacitySummary == "2C4G", "two-core four-gibibyte summary")
    try expect(RemoteMachineConfigurationParser.parse("hostname\tonly\n") == nil, "incomplete remote machine configuration accepted")

    let refreshDate = Date(timeIntervalSince1970: 1_700_000_000)
    let configuredServer = ServerConnection(
        name: "Configured",
        host: "configured.example",
        username: "root",
        alias: "configured",
        machineConfiguration: compactMachine
    )
    try expect(!configuredServer.shouldRefreshMachineConfiguration(at: refreshDate.addingTimeInterval(RemoteMachineConfiguration.refreshInterval - 1)), "machine configuration refreshed too early")
    try expect(configuredServer.shouldRefreshMachineConfiguration(at: refreshDate.addingTimeInterval(RemoteMachineConfiguration.refreshInterval)), "stale machine configuration was not refreshed")
    var attemptedServer = ServerConnection(
        name: "Attempted",
        host: "attempted.example",
        username: "root",
        alias: "attempted",
        machineConfigurationRefreshAttemptedAt: refreshDate
    )
    try expect(!attemptedServer.shouldRefreshMachineConfiguration(at: refreshDate.addingTimeInterval(RemoteMachineConfiguration.refreshInterval - 1)), "failed daily refresh was retried too early")
    try expect(attemptedServer.shouldRefreshMachineConfiguration(at: refreshDate.addingTimeInterval(RemoteMachineConfiguration.refreshInterval)), "failed daily refresh did not retry on the next day")
    attemptedServer.machineConfigurationRefreshAttemptedAt = nil
    try expect(attemptedServer.shouldRefreshMachineConfiguration(at: refreshDate), "server without refresh history was skipped")

    let tailscaleStatusJSON = """
    {
      "BackendState": "Running",
      "MagicDNSSuffix": "example.ts.net",
      "CurrentTailnet": {
        "Name": "example@example.com",
        "MagicDNSSuffix": "example.ts.net",
        "MagicDNSEnabled": true
      },
      "Self": {
        "ID": "node-local",
        "HostName": "local-mac",
        "DNSName": "local-mac.example.ts.net.",
        "OS": "macOS",
        "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
        "Online": true,
        "Relay": "sfo"
      },
      "Peer": {
        "nodekey:peer": {
          "ID": "node-peer",
          "HostName": "build-server",
          "DNSName": "build-server.example.ts.net.",
          "OS": "linux",
          "TailscaleIPs": ["100.64.0.2"],
          "Online": false,
          "LastSeen": "2026-08-01T00:24:58.1Z",
          "Relay": "fra",
          "ExitNodeOption": true
        }
      }
    }
    """
    let tailscaleStatus = try TailscaleStatusParser.parse(tailscaleStatusJSON)
    try expect(tailscaleStatus.backendState == "Running", "tailscale backend state")
    try expect(tailscaleStatus.tailnetName == "example@example.com", "tailscale tailnet name")
    try expect(tailscaleStatus.nodes.count == 2, "tailscale node count")
    var nonJSONTailscaleError: Error?
    do {
        _ = try TailscaleStatusParser.parse("Tailscale is not ready")
    } catch {
        nonJSONTailscaleError = error
    }
    guard let nonJSONTailscaleError else {
        throw CheckFailure.failed("tailscale non-JSON command output was accepted")
    }
    try expect(!String(describing: nonJSONTailscaleError).contains("DecodingError"), "tailscale parser exposed decoder internals")
    guard let localNode = tailscaleStatus.nodes.first(where: \.isCurrent) else {
        throw CheckFailure.failed("tailscale current node missing")
    }
    try expect(localNode.id == "node-local", "tailscale current node identity")
    try expect(localNode.dnsName == "local-mac.example.ts.net", "tailscale DNS name normalization")
    try expect(localNode.addresses == ["100.64.0.1", "fd7a:115c:a1e0::1"], "tailscale addresses")
    guard let peerNode = tailscaleStatus.nodes.first(where: { !$0.isCurrent }) else {
        throw CheckFailure.failed("tailscale peer node missing")
    }
    try expect(peerNode.name == "build-server" && !peerNode.isOnline, "tailscale peer summary")
    try expect(peerNode.lastSeen != nil && peerNode.isExitNodeOption, "tailscale peer metadata")
    guard let serverSuggestion = TailscaleSSHServerSuggestion(node: peerNode) else {
        throw CheckFailure.failed("tailscale peer did not produce an SSH server suggestion")
    }
    try expect(
        serverSuggestion.name == "build-server"
            && serverSuggestion.host == "build-server.example.ts.net"
            && serverSuggestion.port == 22
            && serverSuggestion.group == "Tailscale"
            && serverSuggestion.alias == "tailscale-build-server",
        "tailscale SSH server suggestion"
    )
    try expect(serverSuggestion.matches(host: "BUILD-SERVER.EXAMPLE.TS.NET."), "tailscale MagicDNS host match")
    try expect(serverSuggestion.matches(host: "100.64.0.2"), "tailscale IP host match")
    try expect(!serverSuggestion.matches(host: "other.example.ts.net"), "unrelated SSH host matched tailscale node")
    try expect(peerNode.matches(host: "BUILD-SERVER.EXAMPLE.TS.NET."), "tailscale node MagicDNS host match")
    try expect(peerNode.matches(host: "100.64.0.2"), "tailscale node IP host match")
    try expect(!peerNode.matches(host: "100.64.0.20"), "tailscale node matched a different IP")
    try expect(serverSuggestion.availableAlias(avoiding: []) == "tailscale-build-server", "unused tailscale alias changed")
    try expect(
        serverSuggestion.availableAlias(avoiding: ["tailscale-build-server", "tailscale-build-server-2"]) == "tailscale-build-server-3",
        "tailscale alias collision was not resolved"
    )
    try expect(
        serverSuggestion.suggestedAlias(username: "root", avoiding: []) == "tailscale-build-server-root",
        "tailscale account alias omitted username"
    )
    try expect(
        serverSuggestion.suggestedAlias(username: "Deploy User", avoiding: []) == "tailscale-build-server-deploy-user",
        "tailscale account alias did not normalize username"
    )
    try expect(
        serverSuggestion.suggestedAlias(username: "root", avoiding: ["tailscale-build-server-root"]) == "tailscale-build-server-root-2",
        "tailscale account alias collision was not resolved"
    )
    let matchingTailscaleAccount = ServerConnection(
        name: "Build Server Root",
        host: "100.64.0.2",
        username: "root",
        alias: "tailscale-build-server-root"
    )
    try expect(
        serverSuggestion.matchesAccount(
            host: "build-server.example.ts.net",
            port: 22,
            username: "root",
            server: matchingTailscaleAccount
        ),
        "tailscale account identity did not match the same node"
    )
    try expect(
        !serverSuggestion.matchesAccount(
            host: "other.example.ts.net",
            port: 22,
            username: "root",
            server: matchingTailscaleAccount
        ),
        "tailscale account identity ignored a moved draft host"
    )
    try expect(TailscaleSSHServerSuggestion(node: localNode) == nil, "tailscale self was offered as a server")
    let unroutableNode = TailscaleNode(
        id: "node-unroutable",
        name: "unroutable",
        dnsName: nil,
        operatingSystem: "linux",
        addresses: [],
        isOnline: true,
        isCurrent: false,
        lastSeen: nil,
        relay: nil,
        isExitNode: false,
        isExitNodeOption: false
    )
    try expect(TailscaleSSHServerSuggestion(node: unroutableNode) == nil, "unroutable tailscale node was offered as a server")
    let addressOnlyNode = TailscaleNode(
        id: "node-address-only",
        name: "address-only",
        dnsName: nil,
        operatingSystem: "linux",
        addresses: ["fd7a:115c:a1e0::3", "100.64.0.3"],
        isOnline: true,
        isCurrent: false,
        lastSeen: nil,
        relay: nil,
        isExitNode: false,
        isExitNodeOption: false
    )
    try expect(TailscaleSSHServerSuggestion(node: addressOnlyNode)?.host == "100.64.0.3", "tailscale IPv4 fallback host")

    let registeredLocal = Device(id: "dev-local", name: "local-mac", isCurrent: true)
    let registeredSameNamePeer = Device(id: "dev-peer", name: "build-server", isCurrent: false)
    let devicePresences = DevicePresenceMerger.merge(
        devices: [registeredSameNamePeer, registeredLocal],
        tailscaleNodes: tailscaleStatus.nodes
    )
    try expect(devicePresences.count == 3, "tailscale peer was incorrectly merged by display name")
    try expect(devicePresences.first?.id == .keyPort("dev-local"), "current KeyPort device was not first")
    try expect(devicePresences.first?.tailscaleNode?.id == "node-local", "tailscale self was not merged into current device")
    try expect(devicePresences.first(where: { $0.id == .keyPort("dev-peer") })?.tailscaleNode == nil, "remote KeyPort device inherited a Tailscale peer")
    try expect(devicePresences.first(where: { $0.id == .tailscale("node-peer") })?.registeredDevice == nil, "tailscale peer inherited a KeyPort identity")

    let synchronizedPeer = Device(
        id: "dev-peer",
        name: "renamed-build-server",
        isCurrent: false,
        tailscaleIdentity: TailscaleDeviceIdentity(node: peerNode)
    )
    let linkedDevicePresences = DevicePresenceMerger.merge(
        devices: [synchronizedPeer, registeredLocal],
        tailscaleNodes: tailscaleStatus.nodes
    )
    try expect(linkedDevicePresences.count == 2, "network-linked device was duplicated")
    let linkedPeer = linkedDevicePresences.first(where: { $0.id == .keyPort("dev-peer") })
    try expect(linkedPeer?.tailscaleNode?.id == "node-peer", "network-linked device did not inherit its Tailscale node")
    try expect(linkedPeer?.registeredDevice?.name == "renamed-build-server", "network-linked device lost KeyPort metadata")
    try expect(linkedPeer?.matches(host: "100.64.0.2") == true, "linked device did not match its server IP")
    try expect(
        linkedPeer?.addressMatch(for: "BUILD-SERVER.EXAMPLE.TS.NET.") == .some(.tailscaleMagicDNS),
        "MagicDNS association evidence was not preserved"
    )
    try expect(
        linkedPeer?.addressMatch(for: "[100.64.0.2]") == .some(.tailscaleIP),
        "Tailscale IP association evidence was not preserved"
    )
    let publicEndpointDevice = Device(
        id: "dev-public-endpoint",
        name: "build-server",
        isCurrent: false,
        tailscaleIdentity: TailscaleDeviceIdentity(node: peerNode)
    )
    let publicEndpointPresence = DevicePresenceMerger.merge(
        devices: [publicEndpointDevice],
        tailscaleNodes: [peerNode]
    ).first
    try expect(
        publicEndpointPresence?.matches(host: "203.0.113.42") == false,
        "public IPv4 was incorrectly inferred from a Tailscale identity"
    )
    try expect(
        publicEndpointPresence?.addressMatch(for: "203.0.113.42") == nil,
        "public IPv4 received an unsupported association explanation"
    )
    try expect(
        !serverSuggestion.matches(host: "203.0.113.42"),
        "public IPv4 was treated as a Tailscale service address"
    )
    let publicAddressServer = ServerConnection(
        name: "Build Public",
        host: "203.0.113.42",
        username: "root",
        alias: "build-public"
    )
    let tailscaleAddressServer = ServerConnection(
        name: "Build Tailnet",
        host: "100.64.0.2",
        username: "root",
        alias: "build-tailnet"
    )
    try expect(
        ServerConnectionGrouping.groups([publicAddressServer, tailscaleAddressServer]).count == 2,
        "public and Tailscale endpoint addresses were automatically merged"
    )

    let duplicateAddressNode = TailscaleNode(
        id: "node-duplicate-address",
        name: "nat-neighbor",
        dnsName: "nat-neighbor.example.ts.net",
        operatingSystem: "linux",
        addresses: ["100.64.0.2"],
        isOnline: true,
        isCurrent: false,
        lastSeen: nil,
        relay: nil,
        isExitNode: false,
        isExitNodeOption: false,
        stableNodeID: "node-duplicate-address"
    )
    let stableIdentityPresences = DevicePresenceMerger.merge(
        devices: [synchronizedPeer],
        tailscaleNodes: [duplicateAddressNode, peerNode]
    )
    try expect(
        stableIdentityPresences.first(where: { $0.id == .keyPort("dev-peer") })?.tailscaleNode?.id == "node-peer",
        "an address collision overrode the stable Tailscale node identity"
    )

    let sameAddressChangedNode = TailscaleNode(
        id: "node-peer-reissued",
        name: "build-server",
        dnsName: "new-name.example.ts.net",
        operatingSystem: "linux",
        addresses: ["100.64.0.2"],
        isOnline: true,
        isCurrent: false,
        lastSeen: nil,
        relay: nil,
        isExitNode: false,
        isExitNodeOption: false,
        stableNodeID: "node-peer-reissued"
    )
    try expect(
        synchronizedPeer.tailscaleIdentity?.matches(node: sameAddressChangedNode) == false,
        "device identity silently followed an address after nodeId changed"
    )

    let staleLocalRegistration = Device(id: "dev-old-local", name: "LOCAL-MAC", isCurrent: false)
    let deduplicatedDevicePresences = DevicePresenceMerger.merge(
        devices: [registeredSameNamePeer, staleLocalRegistration, registeredLocal],
        tailscaleNodes: tailscaleStatus.nodes
    )
    try expect(deduplicatedDevicePresences.count == 3, "stale local device registration was displayed separately")
    try expect(deduplicatedDevicePresences.first(where: { $0.id == .keyPort("dev-old-local") }) == nil, "stale local device registration was not suppressed")

    let old = HostKeyRecord(algorithm: "ssh-ed25519", fingerprint: "SHA256:old", knownHostsLine: "host ssh-ed25519 old")
    let new = HostKeyRecord(algorithm: "ssh-ed25519", fingerprint: "SHA256:new", knownHostsLine: "host ssh-ed25519 new")
    let unconfirmedRSA = HostKeyRecord(algorithm: "ssh-rsa", fingerprint: "SHA256:rsa", knownHostsLine: "host ssh-rsa rsa")
    try expect(HostKeyEvaluator.evaluate(observed: [new], confirmed: [old]) == .changed(algorithms: ["ssh-ed25519"]), "host key change was not blocked")
    try expect(HostKeyEvaluator.evaluate(observed: [old], confirmed: [old]) == .confirmed, "confirmed key rejected")
    try expect(HostKeyEvaluator.evaluate(observed: [old], confirmed: []) == .pending, "unknown host key accepted")
    try expect(HostKeyEvaluator.evaluate(observed: [old, unconfirmedRSA], confirmed: [old]) == .pending, "unconfirmed additional host key algorithm was accepted")

    let passwordPolicy = SSHAuthenticationPolicy.passwordOnlyArguments
    try expect(containsSSHOption(passwordPolicy, "BatchMode=no"), "password check did not enable prompts")
    try expect(containsSSHOption(passwordPolicy, "PreferredAuthentications=password"), "password check allows another preferred method")
    try expect(containsSSHOption(passwordPolicy, "PubkeyAuthentication=no"), "password check did not disable public keys")
    try expect(containsSSHOption(passwordPolicy, "KbdInteractiveAuthentication=no"), "password check did not disable keyboard-interactive fallback")
    try expect(containsSSHOption(passwordPolicy, "IdentityAgent=none"), "password check did not disable SSH Agent")

    let keyPolicy = SSHAuthenticationPolicy.publicKeyOnlyArguments
    try expect(containsSSHOption(keyPolicy, "BatchMode=yes"), "key check can prompt interactively")
    try expect(containsSSHOption(keyPolicy, "PreferredAuthentications=publickey"), "key check allows another preferred method")
    try expect(containsSSHOption(keyPolicy, "PasswordAuthentication=no"), "key check did not disable password auth")
    try expect(containsSSHOption(keyPolicy, "KbdInteractiveAuthentication=no"), "key check did not disable keyboard-interactive auth")
    try expect(containsSSHOption(keyPolicy, "IdentityAgent=none"), "key check did not disable SSH Agent")

    try expect(
        SSHAuthenticationRecovery.action(hasStoredPassword: true) == .authorizeWithStoredPassword,
        "key failure did not select password authorization fallback"
    )
    try expect(
        SSHAuthenticationRecovery.action(hasStoredPassword: false) == .manualAuthorization,
        "key failure attempted password authorization without a stored password"
    )
    try expect(
        AuthorizationStatus.needsAuthorization.primaryAction(hasStoredPassword: true, hasLocalKey: true)
            == .synchronizeAuthorization,
        "authorized account did not offer the SSH authorization sync action"
    )
    try expect(
        AuthorizationStatus.needsAuthorization.primaryAction(hasStoredPassword: false, hasLocalKey: true)
            == .addAndVerifyPassword,
        "missing password did not block authorization sync"
    )
    try expect(
        AuthorizationStatus.missingLocalKey.primaryAction(hasStoredPassword: true, hasLocalKey: false)
            == .generateLocalKey,
        "missing local key did not offer key generation"
    )
    try expect(
        AuthorizationStatus.hostKeyMismatch.primaryAction(hasStoredPassword: true, hasLocalKey: true)
            == .confirmHostKey,
        "host key mismatch did not remain a confirmation block"
    )
    try expect(
        AuthorizationStatus.authorized.title == "免密可用",
        "authorized status was not presented as passwordless availability"
    )
    try expect(
        AuthorizationStatus.syncing.isInFlight,
        "SSH authorization syncing state was not marked in flight"
    )

    let legacyServerData = try JSONEncoder().encode(ServerConnection(name: "Legacy", host: "legacy.example", username: "root", alias: "legacy"))
    let decodedLegacyServer = try JSONDecoder().decode(ServerConnection.self, from: legacyServerData)
    try expect(decodedLegacyServer.passwordCheck == nil && decodedLegacyServer.keyCheck == nil, "legacy server check fields did not decode as empty")

    let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let checkedServer = ServerConnection(
        name: "Checked",
        host: "checked.example",
        username: "root",
        alias: "checked",
        passwordCheck: AuthenticationCheck(state: .failed, detail: "Rejected", checkedAt: checkedAt),
        keyCheck: AuthenticationCheck(state: .succeeded, detail: "Accepted", checkedAt: checkedAt)
    )
    let decodedCheckedServer = try JSONDecoder().decode(ServerConnection.self, from: JSONEncoder().encode(checkedServer))
    try expect(decodedCheckedServer.passwordCheck?.state == .failed, "password check state did not round trip")
    try expect(decodedCheckedServer.keyCheck?.state == .succeeded, "key check state did not round trip")

    var passwordGate = PasswordSSHValidationGate()
    let firstPasswordRevision = passwordGate.beginTest()
    passwordGate.finishTest(AuthenticationCheck(state: .succeeded, detail: "Accepted", checkedAt: checkedAt), for: firstPasswordRevision)
    try expect(passwordGate.canSave, "successful current password check did not unlock save")
    passwordGate.inputChanged()
    try expect(!passwordGate.canSave && passwordGate.check == nil, "password edit did not invalidate the prior check")
    let stalePasswordRevision = passwordGate.beginTest()
    passwordGate.inputChanged()
    passwordGate.finishTest(AuthenticationCheck(state: .succeeded, detail: "Stale", checkedAt: checkedAt), for: stalePasswordRevision)
    try expect(!passwordGate.canSave && passwordGate.check == nil, "stale password test result unlocked save")
    let failedPasswordRevision = passwordGate.beginTest()
    passwordGate.finishTest(AuthenticationCheck(state: .failed, detail: "Rejected", checkedAt: checkedAt), for: failedPasswordRevision)
    try expect(!passwordGate.canSave, "failed password check unlocked save")

    var archiveSnapshot = AppSnapshot()
    archiveSnapshot.servers = [ServerConnection(name: "Archive", host: "example.com", username: "root", alias: "kp-prod-archive")]
    archiveSnapshot.keys = [SSHKeyRecord(id: "key_test", deviceID: "dev_test", kind: .ed25519, publicKey: managed, fingerprint: parsed.fingerprint, privateKeyPath: "/secret/local/path", isInAgent: true, origin: .generated, isLocallyAvailable: true)]
    let archive = try MetadataArchiveCodec.seal(archiveSnapshot, password: "test-password", iterations: 1_000)
    let opened = try MetadataArchiveCodec.open(archive, password: "test-password")
    try expect(opened.servers.first?.alias == "kp-prod-archive", "archive round trip")
    try expect(opened.keys.first?.privateKeyPath == nil && opened.keys.first?.isInAgent == false, "archive leaked local key metadata")
    do {
        _ = try MetadataArchiveCodec.open(archive, password: "wrong-password")
        throw CheckFailure.failed("archive accepted wrong password")
    } catch MetadataArchiveError.authenticationFailed {
        // Expected authenticated-decryption failure.
    }

    let migrationIdentityID = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
    let migrationDate = Date(timeIntervalSince1970: 1_787_616_000)
    var migrationSnapshot = AppSnapshot()
    migrationSnapshot.servers = [ServerConnection(
        id: migrationIdentityID,
        name: "Migration Check",
        host: "migration-check.example",
        username: "fixture",
        alias: "migration-check",
        createdAt: migrationDate,
        updatedAt: migrationDate
    )]
    let migrationEncoder = JSONEncoder()
    migrationEncoder.dateEncodingStrategy = .iso8601
    migrationEncoder.outputFormatting = [.sortedKeys]
    let migrationInput = try migrationEncoder.encode(migrationSnapshot)
    let migrationArtifacts = [
        "state-v1.json": HostV6.CanonicalJSON.sha256(migrationInput),
    ]
    let migrationInspection = HostV6.ShadowMigrationInspection(
        keychainAccountsBefore: [migrationIdentityID.uuidString.lowercased(): .missing],
        keychainAccountsAfter: [migrationIdentityID.uuidString.lowercased(): .missing],
        artifactHashesBefore: migrationArtifacts,
        artifactHashesAfter: migrationArtifacts,
        existingSSHHostAliases: []
    )
    let migrationEngine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_core_checks")
    let migrationShadow = try migrationEngine.prepare(
        legacyData: migrationInput,
        previousStateData: nil,
        inspection: migrationInspection
    )
    let migrationReplay = try migrationEngine.prepare(
        legacyData: migrationInput,
        previousStateData: nil,
        inspection: migrationInspection
    )
    try expect(migrationShadow.envelope.schemaVersion == 6, "shadow migration did not emit schema 6")
    try expect(
        migrationShadow.envelope.migrationProvenance.authorityManifest == nil,
        "shadow migration signed authority before rollout gates"
    )
    try expect(migrationShadow.stateData == migrationReplay.stateData, "shadow migration replay changed state bytes")
    try expect(migrationShadow.reportData == migrationReplay.reportData, "shadow migration replay changed report bytes")

    print("KeyPortCoreChecks: all assertions passed")
} catch {
    FileHandle.standardError.write(Data("KeyPortCoreChecks failed: \(error)\n".utf8))
    exit(1)
}
