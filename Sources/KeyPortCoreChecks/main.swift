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

    print("KeyPortCoreChecks: 69 assertions passed")
} catch {
    FileHandle.standardError.write(Data("KeyPortCoreChecks failed: \(error)\n".utf8))
    exit(1)
}
