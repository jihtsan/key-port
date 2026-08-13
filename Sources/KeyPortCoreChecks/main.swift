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

    print("KeyPortCoreChecks: all assertions passed")
} catch {
    FileHandle.standardError.write(Data("KeyPortCoreChecks failed: \(error)\n".utf8))
    exit(1)
}
