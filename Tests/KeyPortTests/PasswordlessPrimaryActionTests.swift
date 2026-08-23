import KeyPortCore
@testable import KeyPort
import XCTest

@MainActor
final class PasswordlessPrimaryActionTests: XCTestCase {
    func testAuthorizedServerWithPrivateKeyUsesVerify() {
        let (model, server) = makeModel(status: .authorized, hasPrivateKey: true, hasPassword: false)

        XCTAssertEqual(model.passwordlessPrimaryAction(for: server), .verify)
    }

    func testUnauthorisedServerWithPrivateKeyAndPasswordUsesEnable() {
        let (model, server) = makeModel(status: .needsAuthorization, hasPrivateKey: true, hasPassword: true)

        XCTAssertEqual(model.passwordlessPrimaryAction(for: server), .enable)
    }

    func testUnauthorisedServerWithoutPasswordRequestsPassword() {
        let (model, server) = makeModel(status: .needsAuthorization, hasPrivateKey: true, hasPassword: false)

        XCTAssertEqual(model.passwordlessPrimaryAction(for: server), .enterPasswordAndEnable)
    }

    func testServerWithoutPrivateKeyGeneratesKeyBeforeEnabling() {
        let (model, server) = makeModel(status: .missingLocalKey, hasPrivateKey: false, hasPassword: false)

        XCTAssertEqual(model.passwordlessPrimaryAction(for: server), .generateKeyAndEnable)
    }

    func testHostIdentityRiskTakesPriorityOverCredentials() {
        for status in [AuthorizationStatus.hostKeyPending, .hostKeyMismatch] {
            let (model, server) = makeModel(status: status, hasPrivateKey: false, hasPassword: false)

            XCTAssertEqual(model.passwordlessPrimaryAction(for: server), .reviewHostIdentity)
        }
    }

    private func makeModel(
        status: AuthorizationStatus,
        hasPrivateKey: Bool,
        hasPassword: Bool
    ) -> (AppModel, ServerConnection) {
        let device = Device(id: "test-device", name: "Test Mac", isCurrent: true)
        let hostKey = HostKeyRecord(
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:host-key",
            knownHostsLine: "example.com ssh-ed25519 AAAA"
        )
        let server = ServerConnection(
            name: "Example",
            host: "example.com",
            username: "admin",
            alias: "example-admin",
            confirmedHostKeys: status == .hostKeyPending ? [] : [hostKey],
            status: status
        )
        let model = AppModel()
        model.snapshot.devices = [device]
        if hasPrivateKey {
            model.snapshot.keys = [
                SSHKeyRecord(
                    id: "test-key",
                    deviceID: device.id,
                    kind: .ed25519,
                    publicKey: "ssh-ed25519 AAAA keyport:test",
                    fingerprint: "SHA256:test-key",
                    privateKeyPath: "/tmp/keyport-test-key",
                    isInAgent: false,
                    origin: .generated,
                    isLocallyAvailable: true
                )
            ]
        }
        if hasPassword {
            model.serverIDsWithStoredPassword.insert(server.id)
        }
        return (model, server)
    }
}
