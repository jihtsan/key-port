import Foundation
import XCTest
@testable import KeyPortCore

/// URL/TCP matrix (architecture 9.1 / 13.7): default and non-default ports,
/// path encoding, DNS/IPv4/IPv6 literals, direct vs tunnel formats. HTTPS is
/// preserved verbatim — there is no trust bypass to test for.
final class ServiceEndpointFormatterTests: XCTestCase {
    // MARK: - HTTP(S) direct

    func testDirectURLWithDNSAndDefaultPorts() throws {
        XCTAssertEqual(
            try ServiceEndpointFormatter.directURL(scheme: .http, host: "web.internal", port: 80).absoluteString,
            "http://web.internal:80"
        )
        XCTAssertEqual(
            try ServiceEndpointFormatter.directURL(scheme: .https, host: "web.internal", port: 443).absoluteString,
            "https://web.internal:443"
        )
    }

    func testDirectURLWithNonDefaultPortAndTrailingDotDNS() throws {
        XCTAssertEqual(
            try ServiceEndpointFormatter.directURL(scheme: .https, host: "DB.Example.COM.", port: 8443).absoluteString,
            "https://DB.Example.COM.:8443"
        )
    }

    func testDirectURLWithIPv4Literal() throws {
        XCTAssertEqual(
            try ServiceEndpointFormatter.directURL(scheme: .http, host: "192.168.1.10", port: 8080).absoluteString,
            "http://192.168.1.10:8080"
        )
    }

    func testDirectURLWrapsIPv6LiteralInBrackets() throws {
        XCTAssertEqual(
            try ServiceEndpointFormatter.directURL(scheme: .https, host: "fd00::10", port: 443).absoluteString,
            "https://[fd00::10]:443"
        )
        // Bracketed input is normalized, not double-wrapped.
        XCTAssertEqual(
            try ServiceEndpointFormatter.directURL(scheme: .https, host: "[fd00::10]", port: 443).absoluteString,
            "https://[fd00::10]:443"
        )
    }

    func testDirectURLPercentEncodesPath() throws {
        let url = try ServiceEndpointFormatter.directURL(
            scheme: .https,
            host: "web.internal",
            port: 443,
            path: "/deck/第一 版/draft.html"
        )
        XCTAssertEqual(url.path(percentEncoded: false), "/deck/第一 版/draft.html")
        XCTAssertFalse(url.absoluteString.contains(" "))
    }

    func testDirectURLRejectsNonNormalizedPaths() {
        let invalid = ["relative/path", "//double/slash", "/a/./b", "/a/../b", "/x?y=1", "/x#frag"]
        for path in invalid {
            XCTAssertThrowsError(
                try ServiceEndpointFormatter.directURL(scheme: .http, host: "h", port: 80, path: path),
                "path \(path) must be rejected"
            ) { error in
                XCTAssertEqual(error as? ServiceEndpointFormatter.FormattingError, .invalidPath)
            }
        }
    }

    func testURLNeverCarriesUserInfo() {
        XCTAssertThrowsError(try ServiceEndpointFormatter.directURL(scheme: .https, host: "user@web.internal", port: 443))
        XCTAssertThrowsError(try ServiceEndpointFormatter.directURL(scheme: .https, host: "user:pass@web.internal", port: 443))
        let url = try? ServiceEndpointFormatter.directURL(scheme: .https, host: "web.internal", port: 443, path: "/a")
        XCTAssertEqual(url?.user, nil)
        XCTAssertEqual(url?.password, nil)
        XCTAssertFalse(url?.absoluteString.contains("@") ?? true)
    }

    func testHTTPSSchemeIsNeverDowngraded() throws {
        let url = try ServiceEndpointFormatter.directURL(scheme: .https, host: "secure.internal", port: 443)
        XCTAssertEqual(url.scheme, "https")
        let tunnel = try ServiceEndpointFormatter.tunnelURL(scheme: .https, localPort: 5000)
        XCTAssertEqual(tunnel.scheme, "https")
    }

    // MARK: - HTTP(S) tunnel

    func testTunnelURLBindsIPv4LoopbackOnly() throws {
        XCTAssertEqual(
            try ServiceEndpointFormatter.tunnelURL(scheme: .http, localPort: 5000).absoluteString,
            "http://127.0.0.1:5000"
        )
        XCTAssertEqual(
            try ServiceEndpointFormatter.tunnelURL(scheme: .https, localPort: 5443, path: "/ui").absoluteString,
            "https://127.0.0.1:5443/ui"
        )
    }

    // MARK: - TCP host:port

    func testDirectHostPortFormatsDNSAndIPv4Bare() throws {
        XCTAssertEqual(try ServiceEndpointFormatter.directHostPort(host: "db.internal", port: 5432), "db.internal:5432")
        XCTAssertEqual(try ServiceEndpointFormatter.directHostPort(host: "10.0.0.2", port: 22), "10.0.0.2:22")
    }

    func testDirectHostPortBracketsIPv6() throws {
        XCTAssertEqual(try ServiceEndpointFormatter.directHostPort(host: "fd00::10", port: 22), "[fd00::10]:22")
        XCTAssertEqual(try ServiceEndpointFormatter.directHostPort(host: "[fd00::10]", port: 22), "[fd00::10]:22")
        XCTAssertEqual(try ServiceEndpointFormatter.directHostPort(host: "::1", port: 8080), "[::1]:8080")
    }

    func testTunnelHostPortIsIPv4Loopback() throws {
        XCTAssertEqual(try ServiceEndpointFormatter.tunnelHostPort(localPort: 5000), "127.0.0.1:5000")
    }

    func testInvalidHostsAndPortsAreRejected() {
        for host in ["", "  ", "has space", "slash/host", "not-ipv6:zzz", "fd00::10%en0"] {
            XCTAssertThrowsError(try ServiceEndpointFormatter.directHostPort(host: host, port: 22), "host \(host) must be rejected")
        }
        XCTAssertThrowsError(try ServiceEndpointFormatter.directHostPort(host: "db.internal", port: 0)) { error in
            XCTAssertEqual(error as? ServiceEndpointFormatter.FormattingError, .invalidPort)
        }
        XCTAssertThrowsError(try ServiceEndpointFormatter.tunnelHostPort(localPort: 0))
    }
}
