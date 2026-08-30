import KeyPortCore
@testable import KeyPort
import XCTest

final class SSHTransportAdapterTests: XCTestCase {
    func testTailscaleTransportUsesCLIAsOpenSSHProxyCommand() throws {
        let adapter = SSHTransportAdapter(
            tailscaleCLIPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        )
        let tailscale = try adapter.configuration(for: .tailscaleCLI)
        let direct = try adapter.configuration(for: .direct)

        XCTAssertEqual(
            tailscale.openSSHArguments,
            [
                "-o",
                "ProxyCommand=/Applications/Tailscale.app/Contents/MacOS/Tailscale nc %h %p",
            ]
        )
        XCTAssertEqual(
            tailscale.proxyCommand,
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale nc %h %p"
        )
        XCTAssertEqual(direct.openSSHArguments, [])
        XCTAssertNil(direct.proxyCommand)
    }

    func testMissingTailscaleCLIProducesActionableError() {
        let adapter = SSHTransportAdapter(tailscaleCLIPath: nil)

        XCTAssertThrowsError(try adapter.configuration(for: .tailscaleCLI)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "所选 Tailnet 路径需要 Tailscale CLI，但当前 Mac 未找到可执行的 Tailscale。"
            )
        }
    }
}
