import Foundation
import KeyPortCore
@testable import KeyPort
import XCTest

final class SSHCommandPresentationTests: XCTestCase {
    func testAliasCommandQuotesWhitespace() {
        let server = ServerConnection(
            name: "Home",
            host: "home.example.com",
            username: "root",
            alias: "home root"
        )

        XCTAssertEqual(
            SSHCommandPresentation.command(server: server),
            "ssh 'home root'"
        )
    }

    func testSelectedRouteBuildsExplicitCommandAndURL() throws {
        let nodeID = UUID()
        let server = ServerConnection(
            name: "Home",
            host: "home.example.com",
            username: "deploy",
            alias: "home-deploy"
        )
        let endpoint = Endpoint(
            id: UUID(),
            nodeID: nodeID,
            address: "100.64.0.20",
            port: 2222,
            protocol: .ssh,
            networkScope: .tailnet,
            source: .tailscale,
            priority: 1
        )

        XCTAssertEqual(
            SSHCommandPresentation.command(server: server, endpoint: endpoint),
            "ssh -p 2222 deploy@100.64.0.20"
        )

        let url = try XCTUnwrap(
            SSHCommandPresentation.terminalURL(server: server, endpoint: endpoint)
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "ssh")
        XCTAssertEqual(components.user, "deploy")
        XCTAssertEqual(components.host, "100.64.0.20")
        XCTAssertEqual(components.port, 2222)
    }
}
