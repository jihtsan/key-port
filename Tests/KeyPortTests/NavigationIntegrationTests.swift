import KeyPortCore
@testable import KeyPort
import XCTest

@MainActor
final class NavigationIntegrationTests: XCTestCase {
    func testPrimaryNavigationContainsOnlyProductWorkspaces() {
        XCTAssertEqual(
            SidebarDestination.primaryCases,
            [.servers, .devices, .activity]
        )
        XCTAssertEqual(ServerWorkspaceMode.allCases, [.list, .graph])
    }

    func testActivityFilterSeparatesFailuresFromHistory() {
        let success = AuditEvent(
            category: "server",
            action: "create",
            result: "success"
        )
        let failure = AuditEvent(
            category: "ssh-auth",
            action: "password-check",
            result: "missing-password",
            level: .warning
        )

        XCTAssertTrue(ActivityFilter.all.matches(success))
        XCTAssertFalse(ActivityFilter.failed.matches(success))
        XCTAssertTrue(ActivityFilter.failed.matches(failure))
        XCTAssertFalse(ActivityFilter.inProgress.matches(failure))
    }

    func testDeviceWorkspaceExcludesTailscaleOnlyDiscoveries() {
        let model = AppModel()
        model.snapshot.devices = [
            Device(id: "mac-a", name: "Mac A", isCurrent: true),
        ]
        model.tailscaleStatus = TailscaleStatus(
            backendState: "Running",
            tailnetName: "example.ts.net",
            magicDNSSuffix: "example.ts.net",
            nodes: [
                TailscaleNode(
                    id: "peer-a",
                    name: "server-a",
                    dnsName: "server-a.example.ts.net",
                    operatingSystem: "linux",
                    addresses: ["100.64.0.10"],
                    isOnline: true,
                    isCurrent: false,
                    lastSeen: nil,
                    relay: nil,
                    isExitNode: false,
                    isExitNodeOption: false,
                    stableNodeID: "peer-a"
                ),
            ]
        )

        XCTAssertEqual(model.deviceListItems.count, 2)
        XCTAssertEqual(model.registeredDeviceListItems.count, 1)
        XCTAssertEqual(model.selectedDeviceItem?.registeredDevice?.id, "mac-a")
    }
}
