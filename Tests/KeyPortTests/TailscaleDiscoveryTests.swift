import XCTest
import KeyPortCore
import KeyPortInterface
@testable import KeyPort

final class TailscaleDiscoveryTests: XCTestCase {
    private let json = #"{"BackendState":"Running","Self":{"ID":"self","HostName":"local","TailscaleIPs":["100.64.0.1"]},"Peer":{"peer":{"ID":"peer","HostName":"server","DNSName":"server.tail.example.","TailscaleIPs":["100.64.0.2","fd7a:115c:a1e0::2","100.64.0.2","-invalid"],"Online":false}}}"#

    func testDiscoveryKeepsOfflinePeersAndAllValidAddresses() async throws {
        let status = try await TailscaleDiscovery.detect(executor: Stub(output: json), executable: "/fixture/tailscale")
        let peer = try XCTUnwrap(status.nodes.first { !$0.isCurrent })
        XCTAssertFalse(peer.isOnline)
        XCTAssertEqual(TailscaleDiscovery.addresses(for: peer), ["server.tail.example", "100.64.0.2", "fd7a:115c:a1e0::2"])
        var draft = AccessFormDraft()
        draft.editingEntryID = "existing-server"
        draft.alias = "existing-alias"; draft.account = "root"; draft.port = "2222"; draft.description = "Saved"
        TailscaleDiscovery.apply(address: "fd7a:115c:a1e0::2", node: peer, to: &draft)
        XCTAssertEqual(draft.address, "fd7a:115c:a1e0::2")
        XCTAssertEqual(draft.alias, "existing-alias"); XCTAssertEqual(draft.account, "root")
        XCTAssertEqual(draft.port, "2222"); XCTAssertEqual(draft.description, "Saved")
        XCTAssertEqual(draft.editingEntryID, "existing-server")
        TailscaleDiscovery.apply(address: "unrelated.example", node: peer, to: &draft)
        XCTAssertEqual(draft.address, "fd7a:115c:a1e0::2")
    }
    func testStoppedAndMalformedAndFailedResultsAreRejected() async {
        for stub in [Stub(output: #"{"BackendState":"Stopped"}"#), Stub(output: "invalid"), Stub(output: json, ending: .timedOut(forcedKill: false)), Stub(output: json, ending: .exited(1))] {
            do {
                _ = try await TailscaleDiscovery.detect(executor: stub, executable: "/fixture/tailscale")
                XCTFail("Unusable discovery result was accepted")
            } catch { }
        }
    }
    func testNewServerGetsSuggestedNameWithoutGuessingAccount() throws {
        let node = try XCTUnwrap(TailscaleStatusParser.parse(json).nodes.first { !$0.isCurrent })
        var draft = AccessFormDraft()
        TailscaleDiscovery.apply(address: "100.64.0.2", node: node, to: &draft)
        XCTAssertFalse(draft.alias.isEmpty)
        XCTAssertEqual(draft.description, "server")
        XCTAssertTrue(draft.account.isEmpty)
    }
}

private struct Stub: ProcessExecuting {
    let output: String
    var ending: ProcessExecutionEnding = .exited(0)
    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        XCTAssertEqual(request.arguments, ["status", "--json"])
        XCTAssertEqual(request.environment["SHLVL"], "1")
        XCTAssertEqual(request.limits.timeout, 10)
        return .init(ending: ending, stdout: Data(output.utf8), stderr: Data(), duration: 0)
    }
}
