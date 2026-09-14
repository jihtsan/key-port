import XCTest
@testable import KeyPortInterface

@MainActor final class AccessWorkspaceTests: XCTestCase {
    private func snapshot() -> AccessWorkspaceSnapshot {
        let paths = [ConfiguredAccessPath(id: "lan", deviceID: "mac", serverID: "router", account: "root", address: "192.0.2.1", verification: .verified, reachability: .reachable, checkedAt: Date(timeIntervalSince1970: 100)),
                     ConfiguredAccessPath(id: "v6", deviceID: "mac", serverID: "router", account: "root", address: "2001:db8::1", reachability: .unreachable),
                     ConfiguredAccessPath(id: "deploy", deviceID: "mac", serverID: "router", account: "deploy", address: "192.0.2.1")]
        return .init(deviceID: "mac", servers: [.init(id: "router", alias: "home-router", description: "家里的主路由器"), .init(id: "isolated", alias: "unconfigured")],
                     configuredPaths: paths, authorizations: [paths[0].authorizationKey: .installed])
    }
    func testConfiguredPathsAreDirectedAndDoNotMultiplyServerNodes() {
        let graph = snapshot().graph
        XCTAssertEqual(graph.servers.map(\.id), ["router", "isolated"])
        XCTAssertEqual(graph.paths.count, 3)
        XCTAssertTrue(graph.paths.allSatisfy { $0.deviceID == "mac" && $0.serverID == "router" })
        XCTAssertFalse(graph.paths.contains { $0.serverID == "isolated" })
        var noPaths = snapshot(); noPaths.configuredPaths = []
        XCTAssertEqual(noPaths.graph.servers.count, 2); XCTAssertTrue(noPaths.graph.paths.isEmpty)
    }
    func testProjectionRejectsUnresolvableAndForeignPathsAndDeduplicatesIDs() {
        var input = snapshot(); input.servers.append(input.servers[0]); input.configuredPaths.append(input.configuredPaths[0])
        input.configuredPaths += [
            .init(id: "foreign", deviceID: "anotherMac", serverID: "router", account: "root", address: "192.0.2.1"),
            .init(id: "missing", deviceID: "mac", serverID: "missing", account: "root", address: "192.0.2.1"),
            .init(id: "empty-account", deviceID: "mac", serverID: "router", account: "", address: "192.0.2.1"),
            .init(id: "invalid-address", deviceID: "mac", serverID: "router", account: "root", address: "!!!")]
        XCTAssertEqual(input.graph.servers.count, 2); XCTAssertEqual(input.graph.paths.map(\.id), ["lan", "v6", "deploy"])
    }
    func testAuthorizationIsAccountScopedAndIndependentOfAddressEvidence() {
        let input = snapshot(); let lan = input.graph.paths[0], ipv6 = input.graph.paths[1], deploy = input.graph.paths[2]
        XCTAssertEqual(lan.authorizationKey, ipv6.authorizationKey)
        XCTAssertNotEqual(lan.authorizationKey, deploy.authorizationKey)
        XCTAssertEqual(input.authorization(for: lan), .installed); XCTAssertEqual(input.authorization(for: ipv6), .installed)
        XCTAssertEqual(ipv6.reachability, .unreachable); XCTAssertEqual(ipv6.verification, .pending)
        XCTAssertEqual(input.authorization(for: deploy), .absent)
        XCTAssertEqual(ipv6.endpoint, "[2001:db8::1]:22"); XCTAssertEqual(ipv6.checkedLabel, "尚未检测")
        XCTAssertNotEqual(lan.checkedLabel, "尚未检测")
    }
    func testListAndGraphShareExactSelectionAndSearchAcrossSwitches() {
        let workspace = AccessWorkspace(snapshot: snapshot(), selection: .path("v6"))
        workspace.query = "主路由"
        workspace.presentation = .graph
        XCTAssertEqual(workspace.selectedPath?.id, "v6"); XCTAssertEqual(workspace.selectedServer?.id, "router")
        XCTAssertEqual(workspace.visibleGraph.paths.count, 3)
        workspace.presentation = .list
        XCTAssertEqual(workspace.selection, .path("v6")); XCTAssertEqual(workspace.query, "主路由")
        workspace.query = "HOME-ROUTER"
        XCTAssertEqual(workspace.visibleGraph.servers.map(\.id), ["router"])
    }
    func testSearchDoesNotDiscardHiddenSelectionAndExplicitLocateSelectsMatch() {
        let workspace = AccessWorkspace(snapshot: snapshot(), selection: .path("lan"))
        workspace.query = "unconfigured"
        XCTAssertEqual(workspace.selection, .path("lan")); XCTAssertTrue(workspace.selectionIsFilteredOut)
        XCTAssertEqual(workspace.searchTargetID, "isolated"); XCTAssertTrue(workspace.visibleGraph.paths.isEmpty)
        workspace.selectSearchResult()
        XCTAssertEqual(workspace.selection, .server("isolated")); XCTAssertFalse(workspace.selectionIsFilteredOut)
        workspace.query = "missing"
        XCTAssertTrue(workspace.visibleGraph.servers.isEmpty); XCTAssertNil(workspace.searchTargetID)
        workspace.selectSearchResult(); XCTAssertEqual(workspace.selection, .server("isolated"))
        workspace.query = ""; XCTAssertEqual(workspace.selectedServer?.id, "isolated")
    }
    func testSnapshotRefreshPreservesStableIDsButClearsDeletedObjects() {
        let workspace = AccessWorkspace(snapshot: snapshot(), selection: .server("router"))
        var renamed = snapshot(); renamed.servers[0].alias = "different-alias"; renamed.servers[0].description = "新说明"
        workspace.replaceSnapshot(renamed)
        XCTAssertEqual(workspace.selection, .server("router")); XCTAssertEqual(workspace.selectedServer?.description, "新说明")
        workspace.select(.path("lan")); renamed.configuredPaths = []
        workspace.replaceSnapshot(renamed); XCTAssertNil(workspace.selection)
        workspace.select(.server("router")); renamed.servers = []
        workspace.replaceSnapshot(renamed); XCTAssertNil(workspace.selection)
    }
    func testKeyboardTraversalIncludesPathsAndDeviceWithNoDuplicateNodes() {
        let workspace = AccessWorkspace(snapshot: snapshot())
        var visited: [WorkspaceSelection?] = []
        for _ in 0..<6 { workspace.advanceSelection(); visited.append(workspace.selection) }
        XCTAssertEqual(visited, [.device("mac"), .server("router"), .server("isolated"), .path("lan"), .path("v6"), .path("deploy")])
        workspace.advanceSelection(); XCTAssertEqual(workspace.selection, .device("mac"))
        workspace.select(nil); XCTAssertNil(workspace.selection)
        workspace.replaceSnapshot(.init(deviceID: "mac", servers: [], configuredPaths: []))
        workspace.advanceSelection(); XCTAssertNil(workspace.selection)
    }
    func testGraphGeometryChangesPathsWithoutDuplicatingOrMovingServerNodes() {
        let all = snapshot().graph; var single = snapshot(); single.configuredPaths = [single.configuredPaths[0]]
        let a = DirectGraphLayout(projection: all), b = DirectGraphLayout(projection: single.graph)
        XCTAssertEqual(a.serverCenter("router"), b.serverCenter("router"))
        XCTAssertEqual(Set(all.paths.map { a.laneCenter($0).y }).count, 3)
        XCTAssertEqual(Set(all.paths.map { a.endpoint($0).y }).count, 3)
        XCTAssertEqual(a.fittedScale(in: CGSize(width: 824, height: 944)), 1)
        XCTAssertLessThan(a.fittedScale(in: CGSize(width: 604, height: 600)), 1)
    }
    func testTwoPathsToSameServerNeverShareLabelOrEndpoint() {
        var input = snapshot(); input.configuredPaths = Array(input.configuredPaths.prefix(2))
        let layout = DirectGraphLayout(projection: input.graph)
        let paths = input.graph.paths
        XCTAssertGreaterThanOrEqual(abs(layout.laneCenter(paths[0]).y - layout.laneCenter(paths[1]).y), 80)
        XCTAssertNotEqual(layout.endpoint(paths[0]), layout.endpoint(paths[1]))
        input.configuredPaths.reverse()
        let reordered = DirectGraphLayout(projection: input.graph)
        for path in paths { XCTAssertEqual(layout.laneCenter(path), reordered.laneCenter(path)) }
        let filtered = DirectGraphLayout(projection: input.graph.matching("home-router"))
        XCTAssertNotEqual(filtered.laneCenter(paths[0]), filtered.laneCenter(paths[1]))
    }
    func testDenseGroupRetainsPathsAndMixedStatusWhenCollapsed() {
        var input = snapshot()
        input.configuredPaths = (0..<6).map { i in
            .init(id: "path-\(i)", deviceID: "mac", serverID: "router", account: "root", address: "192.0.2.\(i + 1)", verification: i == 0 ? .verified : i == 5 ? .failed : .pending)
        }
        let collapsed = DirectGraphLayout(projection: input.graph)
        let expanded = DirectGraphLayout(projection: input.graph, expandedServerIDs: ["router"])
        XCTAssertTrue(collapsed.isCollapsed("router")); XCTAssertFalse(expanded.isCollapsed("router"))
        XCTAssertEqual(collapsed.paths(for: "router").count, 6)
        XCTAssertEqual(input.configuredPaths.verificationSummary, "1 已验证 / 4 待验证 / 1 失败")
        XCTAssertEqual(Set(input.configuredPaths.map { expanded.laneCenter($0).y }).count, 6)
        let allPaths = input.configuredPaths
        for count in 0...3 {
            input.configuredPaths = Array(allPaths.prefix(count))
            XCTAssertFalse(DirectGraphLayout(projection: input.graph).isCollapsed("router"))
        }
    }

    func testPrimaryActionPreservesAuthorizationAndAddressRecovery() {
        var input = snapshot(); let workspace = AccessWorkspace(snapshot: input)
        XCTAssertEqual(workspace.primaryAction(for: input.configuredPaths[0]), .openTerminal)
        XCTAssertEqual(workspace.primaryAction(for: input.configuredPaths[1]), .checkAddress)
        XCTAssertEqual(workspace.primaryAction(for: input.configuredPaths[2]), .authorize)
        input.authorizations[input.configuredPaths[0].authorizationKey] = .unknown
        workspace.replaceSnapshot(input)
        XCTAssertEqual(workspace.primaryAction(for: input.configuredPaths[0]), .authorize)
        let draft = workspace.accessDraft(for: input.configuredPaths[1])!
        XCTAssertEqual(draft.alias, "home-router"); XCTAssertEqual(draft.editingEntryID, "router")
        XCTAssertEqual(draft.address, "2001:db8::1"); XCTAssertEqual(draft.account, "root")
        XCTAssertTrue(draft.password.isEmpty)
        var submitted = draft; submitted.existingKey = true
        let directory = AliasDirectory(entries: [.init(alias: "home-router", source: .managed, ownerID: "router"), .init(alias: "home-router", source: .sshConfiguration, ownerID: "router")])
        XCTAssertNil(submitted.validationMessage(in: directory))
        submitted.editingEntryID = nil
        XCTAssertNotNil(submitted.validationMessage(in: directory))
    }
    func testFitIncludesGraphAndReservesToolbarSpaceInNarrowWindow() {
        var input = snapshot()
        for i in 0..<10 { input.servers.append(.init(id: "extra-\(i)", alias: "extra-\(i)")) }
        let layout = DirectGraphLayout(projection: input.graph)
        for size in [CGSize(width: 604, height: 684), CGSize(width: 824, height: 764)] {
            let scale = layout.fittedScale(in: size)
            XCTAssertLessThanOrEqual(layout.width * scale, size.width + 0.01)
            XCTAssertLessThanOrEqual(layout.height * scale, size.height - 180 + 0.01)
        }
    }

}
