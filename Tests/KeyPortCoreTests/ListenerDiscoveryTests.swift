import XCTest
@testable import KeyPortCore

final class ListenerDiscoveryTests: XCTestCase {
    func testLinuxParserRetainsIPv4IPv6AndProcessHints() throws {
        let output = """
        LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:((\"local-service\",pid=11,fd=3))
        LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:((\"docker-proxy\",pid=12,fd=4))
        LISTEN 0 128 [::1]:9090 [::]:* users:((\"v6-service\",pid=13,fd=5))
        LISTEN 0 128 [2001:db8::10]:9443 [::]:*
        """

        let result = try ListenerDiscoveryParser.parse(
            Data(output.utf8),
            platform: .linux
        )

        XCTAssertEqual(result.candidates.count, 4)
        XCTAssertEqual(result.candidates[0].bind, .loopbackV4)
        XCTAssertEqual(result.candidates[0].port, 8080)
        XCTAssertEqual(result.candidates[0].processHint, "local-service")
        XCTAssertEqual(result.candidates[1].bind, .wildcardV4)
        XCTAssertEqual(result.candidates[2].bind, .loopbackV6)
        XCTAssertEqual(result.candidates[3].bind, .specific(.init(value: "2001:db8::10", family: .v6)))
    }

    func testMacOSParserUsesNULFieldsAndKeepsPortWhenProcessIsUnavailable() throws {
        let output = "p101\0cnginx\0n127.0.0.1:80\0TST=LISTEN\0xunknown\0"
            + "p102\0n[::]:443\0TST=LISTEN\0"
            + "p103\0n[2001:db8::5]:8443\0TST=LISTEN\0"

        let result = try ListenerDiscoveryParser.parse(Data(output.utf8), platform: .macOS)

        XCTAssertEqual(result.candidates.count, 3)
        XCTAssertEqual(result.candidates[0].bind, .loopbackV4)
        XCTAssertEqual(result.candidates[0].processHint, "nginx")
        XCTAssertEqual(result.candidates[1].bind, .wildcardV6)
        XCTAssertNil(result.candidates[1].processHint)
        XCTAssertEqual(result.candidates[2].bind, .specific(.init(value: "2001:db8::5", family: .v6)))
        XCTAssertTrue(result.warnings.contains(.permissionLimited))
    }

    func testMacOSParserTreatsLeadingLineFeedAsTheRealLsofRecordBoundary() throws {
        let output = Data((
            "p101\0cnginx\0\nf1\0n127.0.0.1:8080\0TST=LISTEN\0"
                + "\np102\0cpostgres\0\nf2\0n127.0.0.1:5432\0TST=LISTEN\0"
        ).utf8)

        let result = try ListenerDiscoveryParser.parseMacOS(output)

        XCTAssertEqual(result.candidates.map { $0.port }, [8080, 5432])
        XCTAssertEqual(result.candidates.map { $0.processHint }, ["nginx", "postgres"])
    }

    func testParserReportsPartialParseOnlyWhenValidCandidatesRemain() throws {
        let output = """
        LISTEN 0 128 127.0.0.1:8080 0.0.0.0:*
        this is not an ss record
        LISTEN 0 128 :::9000 *:*
        """

        let result = try ListenerDiscoveryParser.parse(Data(output.utf8), platform: .linux)

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.partialParseCount, 1)
        XCTAssertTrue(result.warnings.contains(.partialParse))
    }

    func testLinuxParserDoesNotTreatPeerEndpointAsLocalListenerWhenLocalFieldIsMalformed() {
        let output = "LISTEN 0 128 malformed-host:bad 127.0.0.1:8080 users:((\"fixture\",pid=1,fd=3))"

        XCTAssertThrowsError(try ListenerDiscoveryParser.parseLinux(output)) { error in
            XCTAssertEqual(error as? ListenerDiscoveryParseError, .noValidRecords)
        }
    }

    func testParserRejectsUnknownNonEmptyOutput() {
        XCTAssertThrowsError(try ListenerDiscoveryParser.parse("unexpected output", platform: .linux)) { error in
            XCTAssertEqual(error as? ListenerDiscoveryParseError, .noValidRecords)
        }
    }

    func testParserRejectsOutputAboveConfiguredByteLimit() {
        let limits = DiscoveryLimits(maximumOutputBytes: 8)

        XCTAssertThrowsError(try ListenerDiscoveryParser.parse(Data(repeating: 0x41, count: 9), platform: .linux, limits: limits)) { error in
            XCTAssertEqual(error as? ListenerDiscoveryParseError, .outputLimitExceeded)
        }
    }

    func testParserCapsCandidatesAtConfiguredLimitAndMarksTruncation() throws {
        let lines = (1...3).map { port in
            "LISTEN 0 128 127.0.0.\(port):\(1000 + port) 0.0.0.0:*"
        }

        let result = try ListenerDiscoveryParser.parse(
            lines.joined(separator: "\n"),
            platform: .linux,
            limits: DiscoveryLimits(maximumCandidates: 2)
        )

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.warnings.contains(.truncated))
    }

    func testCapabilityParserKeepsOnlyKnownPlatformAndTools() {
        let output = "platform=linux\ntool=ss\ntool=lsof\ntool=unknown\n"

        let capabilities = DiscoveryCapabilities.parse(Data(output.utf8))

        XCTAssertEqual(capabilities.platform, .linux)
        XCTAssertEqual(capabilities.tools, [.ss, .lsof])
        XCTAssertTrue(capabilities.canDiscover)
    }

    func testLinuxParserSupportsColonStyleIPv6AndDeduplicatesListeners() throws {
        let output = """
        LISTEN 0 128 :::22 :::*
        LISTEN 0 128 [::]:22 [::]:* users:((\"sshd\",pid=10,fd=3))
        LISTEN 0 128 *:3000 *:*
        """

        let result = try ListenerDiscoveryParser.parseLinux(output)

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates[0].bind, .wildcardV6)
        XCTAssertEqual(result.candidates[0].port, 22)
        XCTAssertEqual(result.candidates[0].processHint, "sshd")
        XCTAssertEqual(result.candidates[1].bind, .wildcardV4)
    }

    func testMacOSParserRejectsMalformedNULRecordWhenNoValidListenerRemains() {
        let output = "p101\0nnot-an-endpoint\0TST=LISTEN\0"

        XCTAssertThrowsError(try ListenerDiscoveryParser.parseMacOS(Data(output.utf8))) { error in
            XCTAssertEqual(error as? ListenerDiscoveryParseError, .noValidRecords)
        }
    }

    func testProcessHintsRejectUnsafeOrOversizedNamesWithoutLeakingThem() throws {
        let oversized = String(repeating: "x", count: 81)
        let output = "LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:((\"bad/name\",pid=1,fd=1))\n"
            + "LISTEN 0 128 127.0.0.1:8081 0.0.0.0:* users:((\"\(oversized)\",pid=2,fd=2))\n"

        let result = try ListenerDiscoveryParser.parseLinux(output)

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertNil(result.candidates[0].processHint)
        XCTAssertNil(result.candidates[1].processHint)
        XCTAssertFalse(result.candidates.contains { $0.processHint?.contains("bad/name") == true })
    }
}
