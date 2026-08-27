import Foundation
import XCTest
@testable import KeyPortCore

final class ServiceAccessTests: XCTestCase {
    func testFormatsHTTPAndTCPEndpointsForIPv4IPv6AndTunnel() throws {
        XCTAssertEqual(
            try ServiceAccessEndpointFormatter.url(
                scheme: .https,
                host: "2001:db8::10",
                port: 8443,
                path: "/status"
            ),
            "https://[2001:db8::10]:8443/status"
        )
        XCTAssertEqual(
            try ServiceAccessEndpointFormatter.url(
                scheme: .http,
                host: "example.test",
                port: 80,
                path: nil
            ),
            "http://example.test:80"
        )
        XCTAssertEqual(
            try ServiceAccessEndpointFormatter.tcpHostPort(host: "2001:db8::10", port: 22),
            "[2001:db8::10]:22"
        )
        XCTAssertEqual(
            try ServiceAccessEndpointFormatter.url(
                scheme: .https,
                host: "127.0.0.1",
                port: 49152,
                path: "/status"
            ),
            "https://127.0.0.1:49152/status"
        )
        XCTAssertEqual(
            try ServiceAccessEndpointFormatter.tcpHostPort(host: "127.0.0.1", port: 49152),
            "127.0.0.1:49152"
        )
        XCTAssertEqual(
            try ServiceAccessEndpointFormatter.tunnelURL(scheme: .https, localPort: 49152, path: "/status"),
            "https://127.0.0.1:49152/status"
        )
        XCTAssertEqual(
            try ServiceAccessEndpointFormatter.tunnelTCPHostPort(localPort: 49152),
            "127.0.0.1:49152"
        )
    }

    func testRejectsUnsafeURLHostAndNonAbsolutePath() {
        XCTAssertThrowsError(
            try ServiceAccessEndpointFormatter.url(
                scheme: .http,
                host: "user@example.test",
                port: 80,
                path: "/"
            )
        ) { error in
            XCTAssertEqual(error as? ServiceEndpointFormattingError, .invalidHost)
        }
        XCTAssertThrowsError(
            try ServiceAccessEndpointFormatter.url(
                scheme: .http,
                host: "example.test",
                port: 80,
                path: "status"
            )
        ) { error in
            XCTAssertEqual(error as? ServiceEndpointFormattingError, .invalidPath)
        }
        XCTAssertThrowsError(
            try ServiceAccessEndpointFormatter.tunnelURL(
                scheme: .http,
                localPort: 49152,
                path: "/status with space"
            )
        ) { error in
            XCTAssertEqual(error as? ServiceEndpointFormattingError, .invalidPath)
        }
    }

    func testPreservesValidPercentEncodedPathWithoutDoubleEncoding() throws {
        XCTAssertEqual(
            try ServiceAccessEndpointFormatter.url(
                scheme: .http,
                host: "example.test",
                port: 8080,
                path: "/status%20ready"
            ),
            "http://example.test:8080/status%20ready"
        )
    }

    func testChoosesDirectOnlyAfterAReachableNonLoopbackTargetProbe() {
        XCTAssertEqual(
            ServiceAccessDecider.decide(
                listener: .specific(.v4("192.0.2.10")),
                probe: .reachable,
                originSensitive: false
            ),
            .direct
        )
        XCTAssertEqual(
            ServiceAccessDecider.decide(
                listener: .loopbackV4,
                probe: .notAttempted,
                originSensitive: false
            ),
            .tunnel
        )
        XCTAssertEqual(
            ServiceAccessDecider.decide(
                listener: .wildcardV6,
                probe: .refused,
                originSensitive: false
            ),
            .tunnel
        )
    }

    func testSpecificLoopbackAddressesAlwaysUseATunnel() {
        XCTAssertEqual(
            ServiceAccessDecider.decide(
                listener: .specific(.v4("127.0.0.1")),
                probe: .reachable,
                originSensitive: false
            ),
            .tunnel
        )
        XCTAssertEqual(
            ServiceAccessDecider.decide(
                listener: .specific(.v6("::1")),
                probe: .reachable,
                originSensitive: false
            ),
            .tunnel
        )
    }

    func testOriginSensitiveHTTPSTunnelFailsClosedAndUnknownProbeDoesNotBecomeActive() {
        XCTAssertEqual(
            ServiceAccessDecider.decide(
                listener: .specific(.v4("192.0.2.10")),
                probe: .timedOut,
                originSensitive: true
            ),
            .failed(.originSensitiveTunnelUnsupported)
        )
        XCTAssertEqual(
            ServiceAccessDecider.decide(
                listener: .specific(.v4("192.0.2.10")),
                probe: .indeterminate,
                originSensitive: false
            ),
            .failed(.targetProbeIndeterminate)
        )
    }

    func testBrokerRecognizerAcceptsOnlyForwardConfirmationAndFailsUnknownOutputClosed() {
        var recognizer = TunnelBrokerOutputRecognizer()
        XCTAssertEqual(
            recognizer.consume(Data("debug: channel 0: open confirm rwindow 0 rmax 32768\n".utf8)),
            [.forwardEstablished]
        )

        var failedRecognizer = TunnelBrokerOutputRecognizer()
        XCTAssertEqual(
            failedRecognizer.consume(Data("debug: channel 0: open failed: connect failed: Connection refused\n".utf8)),
            [.targetRefused]
        )

        var unknownRecognizer = TunnelBrokerOutputRecognizer()
        XCTAssertEqual(
            unknownRecognizer.consume(Data("unrecognized broker diagnostic\n".utf8)),
            [.unknownOutput]
        )
    }

    func testBrokerRecognizerPreservesForwardRejectedFailureCode() {
        var recognizer = TunnelBrokerOutputRecognizer()

        XCTAssertEqual(
            recognizer.consume(Data("FORWARD_FAILED forward_rejected\n".utf8)),
            [.forwardRejected]
        )
    }

    func testBrokerRecognizerAcceptsAnyDirectTCPChannelAndFlushesAnUnterminatedLine() {
        var recognizer = TunnelBrokerOutputRecognizer()
        XCTAssertEqual(
            recognizer.consume(Data("debug1: channel 7: open confirm rwindow 0 rmax 32768\n".utf8)),
            [.forwardEstablished]
        )

        var unterminatedRecognizer = TunnelBrokerOutputRecognizer()
        XCTAssertEqual(
            unterminatedRecognizer.consume(Data("FORWARD_ESTABLISHED".utf8)),
            []
        )
        XCTAssertEqual(unterminatedRecognizer.finish(), [.forwardEstablished])
    }

    func testBrokerRecognizerCapsTotalDiagnosticBytesEvenWhenLinesAreConsumed() {
        var recognizer = TunnelBrokerOutputRecognizer()
        let line = Data("FORWARD_ESTABLISHED\n".utf8)
        var didFailClosed = false

        for _ in 0...TunnelBrokerOutputRecognizer.maximumBytes / line.count {
            let events = recognizer.consume(line)
            if events == [.unknownOutput] {
                didFailClosed = true
                break
            }
        }

        XCTAssertTrue(didFailClosed)
    }

    func testServiceAccessFeatureIsDisabledByDefault() {
        XCTAssertFalse(KeyPortFeatureFlags.serviceAccessEnabled)
    }

    func testBuildsFixedSSHForwardWithIPv6BracketsAndNoUserCommandSlot() throws {
        let command = try TunnelBrokerCommandBuilder.make(
            configuration: TunnelBrokerConfiguration(
                localPort: 49152,
                remoteHost: "[::1]",
                remotePort: 8080,
                sshHost: "[2001:db8::20]",
                sshPort: 2222,
                username: "admin",
                identityPath: "/Users/test/.ssh/keyport/identities/id",
                knownHostsPath: "/Users/test/.ssh/keyport/known_hosts",
                controlPath: "/Users/test/Library/Application Support/KeyPort/tunnel-runtime/control-id.sock",
                leasePath: "/Users/test/Library/Application Support/KeyPort/tunnel-runtime/lease-id.json"
            )
        )

        XCTAssertEqual(
            command.sshArguments[command.sshArguments.firstIndex(of: "-L")! + 1],
            "127.0.0.1:49152:[::1]:8080"
        )
        XCTAssertEqual(command.sshArguments.last, "admin@[2001:db8::20]")
        XCTAssertTrue(command.sshArguments.contains("-M"))
        XCTAssertTrue(command.sshArguments.contains("-S"))
        XCTAssertFalse(command.sshArguments.contains("-f"))
        XCTAssertTrue(command.sshArguments.contains("ExitOnForwardFailure=yes"))
        XCTAssertFalse(command.brokerArguments.contains(where: { $0.contains("ssh -") }))
    }

    func testOpenSSHVersionPolicyAllowsOnlyKnownFullVersions() {
        XCTAssertTrue(
            OpenSSHVersionPolicy.isSupported(
                "OpenSSH_10.2p1, LibreSSL 3.3.6"
            )
        )
        XCTAssertTrue(
            OpenSSHVersionPolicy.isSupported(
                "OpenSSH_9.7p1, LibreSSL 3.3.6"
            )
        )
        XCTAssertFalse(OpenSSHVersionPolicy.isSupported("OpenSSH_10.3p1, LibreSSL 3.3.6"))
        XCTAssertFalse(OpenSSHVersionPolicy.isSupported("OpenSSH_10.2p99, LibreSSL 3.3.6"))
        XCTAssertFalse(OpenSSHVersionPolicy.isSupported("OpenSSH_10.2p1, OpenSSL 3.0.0"))
        XCTAssertFalse(OpenSSHVersionPolicy.isSupported("OpenSSH_10.2p1"))
        XCTAssertFalse(OpenSSHVersionPolicy.isSupported("ssh version unknown"))
    }

    func testOpenSSHVersionPolicyUsesCheckedInFixtures() throws {
        let fixtureDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OpenSSH", isDirectory: true)
        let fixtures: [(String, Bool)] = [
            ("supported-9.7p1.version", true),
            ("supported-10.2p1.version", true),
            ("unsupported-10.3p1.version", false),
            ("unsupported-10.2p99.version", false),
            ("unsupported-10.2p1-vendor.version", false),
            ("malformed.version", false)
        ]

        for (name, expected) in fixtures {
            let output = try String(contentsOf: fixtureDirectory.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(OpenSSHVersionPolicy.isSupported(output), expected, name)
        }
    }

    func testTargetEvidenceBindsDiscoverySubjectAndExpiresAfterThirtySeconds() throws {
        let operationID = UUID()
        let sessionID = UUID()
        let candidateID = UUID()
        let identityID = UUID()
        let addressID = UUID()
        let remote = RemoteServiceEndpoint(bind: .specific(.v4("192.0.2.20")), port: 8080)
        let tunnelID = UUID()
        let subject = TunnelSubject(
            operationID: operationID,
            sessionID: sessionID,
            candidateID: candidateID,
            sshIdentityID: identityID,
            sshAddressID: addressID,
            remote: remote,
            networkEpoch: 7
        )
        let verifiedAt = Date(timeIntervalSince1970: 100)
        let evidence = TargetVerificationEvidence(
            tunnelID: tunnelID,
            operationID: operationID,
            subject: subject,
            verifiedAt: verifiedAt
        )

        XCTAssertEqual(evidence.tunnelID, tunnelID)
        XCTAssertEqual(evidence.operationID, operationID)
        XCTAssertEqual(evidence.sshIdentityID, identityID)
        XCTAssertEqual(evidence.sshAddressID, addressID)
        XCTAssertEqual(evidence.remoteDigest, remote.remoteDigest)
        XCTAssertEqual(evidence.networkEpoch, 7)
        XCTAssertEqual(subject.remoteDigest, remote.remoteDigest)
        XCTAssertTrue(evidence.isValid(at: verifiedAt.addingTimeInterval(29), networkEpoch: 7))
        XCTAssertFalse(evidence.isValid(at: verifiedAt.addingTimeInterval(30), networkEpoch: 7))
        XCTAssertFalse(evidence.isValid(at: verifiedAt.addingTimeInterval(1), networkEpoch: 8))

        let mismatchedCandidate = TunnelSubject(
            operationID: operationID,
            sessionID: sessionID,
            candidateID: UUID(),
            sshIdentityID: identityID,
            sshAddressID: addressID,
            remote: remote,
            networkEpoch: 7
        )
        XCTAssertThrowsError(
            try evidence.adopt(candidate: mismatchedCandidate, at: verifiedAt.addingTimeInterval(1))
        ) { error in
            XCTAssertEqual(error as? TargetVerificationEvidenceError, .subjectMismatch)
        }
    }

    func testTargetEvidenceRetainsInitiatingOperationWhenSubjectIsAdopted() throws {
        let operationID = UUID()
        let identityID = UUID()
        let addressID = UUID()
        let remote = RemoteServiceEndpoint(bind: .loopbackV4, port: 8080)
        let candidate = TunnelSubject(
            operationID: operationID,
            sessionID: UUID(),
            candidateID: UUID(),
            sshIdentityID: identityID,
            sshAddressID: addressID,
            remote: remote,
            networkEpoch: 0
        )
        let saved = TunnelSubject(
            serviceID: UUID(),
            sshIdentityID: identityID,
            sshAddressID: addressID,
            remote: remote,
            networkEpoch: 0
        )
        let evidence = TargetVerificationEvidence(
            tunnelID: UUID(),
            operationID: operationID,
            subject: candidate,
            verifiedAt: Date(timeIntervalSince1970: 100)
        )

        let adopted = try evidence.adopting(
            savedSubject: saved,
            at: Date(timeIntervalSince1970: 101)
        )

        XCTAssertEqual(adopted.operationID, operationID)
    }

    func testRejectsAnInvalidRemoteForwardHost() {
        XCTAssertThrowsError(
            try TunnelBrokerCommandBuilder.make(
                configuration: TunnelBrokerConfiguration(
                    localPort: 49152,
                    remoteHost: "2001:db8::not-an-address",
                    remotePort: 8080,
                    sshHost: "ssh.example.test",
                    sshPort: 22,
                    username: "admin",
                    identityPath: "/Users/test/.ssh/keyport/identities/id",
                    knownHostsPath: "/Users/test/.ssh/known_hosts",
                    controlPath: "/Users/test/runtime/control-id.sock",
                    leasePath: "/Users/test/runtime/lease-id.json"
                )
            )
        ) { error in
            XCTAssertEqual((error as? TunnelOpenFailure)?.code, .invalidTunnelRequest)
        }
    }
}
