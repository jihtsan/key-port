import Foundation
import XCTest
import KeyPortCore
@testable import KeyPort

final class SSHKnownHostsPathTests: XCTestCase {
    /// Opt-in live trust-only regression. All credential methods are forcibly disabled.
    /// No scanning, trust replacement, password submission or remote command execution.
    func testKnownHostInDirectoryContainingSpacesPassesStrictVerification() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["KEYPORT_TRUST_TEST_HOST"], let account = env["KEYPORT_TRUST_TEST_ACCOUNT"],
              let source = env["KEYPORT_TRUST_TEST_KNOWN_HOSTS"] else {
            throw XCTSkip("Requires an explicitly approved endpoint and already trusted known_hosts file")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyPort trust fixture \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = KeyPortPaths(home: root)
        try paths.prepareDirectories()
        try FileManager.default.copyItem(atPath: source, toPath: paths.knownHosts.path)
        let line = try String(contentsOf: paths.knownHosts).split(separator: "\n").first!
        let parsed = try XCTUnwrap(PublicKeyParser.parse(String(line)))
        let host = HostKeyRecord(algorithm: parsed.type, fingerprint: parsed.fingerprint, knownHostsLine: String(line))
        let server = ServerConnection(name: "trust fixture", host: address, username: account, alias: "trust-fixture", confirmedHostKeys: [host])
        let key = SSHKeyRecord(id: "unused", deviceID: "fixture", kind: .ed25519, publicKey: "", fingerprint: "unused",
            privateKeyPath: "/dev/null", isInAgent: false, origin: .generated, isLocallyAvailable: false)
        let service = OpenSSHService(runner: ProcessRunner(executor: TrustOnlyExecutor()), paths: paths, askPassPath: "/usr/bin/false", isolatedConfiguration: true)
        // false means SSH reached credential rejection. A trust/configuration failure throws.
        let result = try await service.testPublicKey(server: server, key: key)
        XCTAssertFalse(result)
    }
}

private struct TrustOnlyExecutor: ProcessExecuting {
    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        var bounded = request
        bounded.arguments = ["-o", "PreferredAuthentications=none", "-o", "PubkeyAuthentication=no",
            "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "IdentityAgent=none"] + request.arguments
        return try await ProcessExecutor().execute(bounded)
    }
}
