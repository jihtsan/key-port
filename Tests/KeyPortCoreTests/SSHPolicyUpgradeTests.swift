import XCTest
@testable import KeyPortCore

final class SSHPolicyUpgradeTests: XCTestCase {
    func testMergePreservesEndpointEvidenceAndSuppressesStaleCloudProfiles() throws {
        let node = UUID(), account = UUID(), a = UUID(), b = UUID()
        let p = SSHConnectionProfile(id: UUID(), accountID: account, sshAlias: "server", routePolicy: .fixed(endpointID: a))
        let q = SSHConnectionProfile(id: UUID(), accountID: account, sshAlias: "server", routePolicy: .fixed(endpointID: b))
        let other = SSHConnectionProfile(id: UUID(), accountID: UUID(), sshAlias: "different", routePolicy: .fixed(endpointID: b))
        var t = TopologySnapshot(nodes: [.init(id: node, name: "Server", roles: [.sshHost])], endpoints: [.init(id: a, nodeID: node, address: "192.0.2.1", port: 22, protocol: .ssh), .init(id: b, nodeID: node, address: "2001:db8::1", port: 22, protocol: .ssh)], sshAccounts: [.init(id: account, nodeID: node, username: "user")], sshConnectionProfiles: [p,q,other])
        t.accessVerifications = [p,q].map { .init(accountID: account, deviceID: "local", profileID: $0.id, endpointID: $0.routePolicy.fixedEndpointID, status: .authorized) }
        let old = t
        let id = try SSHPolicyUpgrade.apply(profileID: p.id, endpointIDs: [b,a], automatic: true, to: &t)
        XCTAssertEqual(t.activeConnectionProfiles.count, 2)
        XCTAssertEqual(t.activeConnectionProfiles.first { $0.id == id }?.candidateEndpointIDs, [b,a])
        XCTAssertEqual(t.accessVerifications.count, 2)
        XCTAssertEqual(Set(t.accessVerifications.map(\.id)).count, 2)
        XCTAssertEqual(Set(t.accessVerifications.compactMap(\.profileID)), [id])
        XCTAssertEqual(TopologyCloudMetadataSnapshotPolicy.merge(local: t, remote: old).activeConnectionProfiles.count, 2)
        XCTAssertEqual(try SSHPolicyUpgrade.apply(profileID: id, endpointIDs: [b,a], automatic: true, to: &t), id)
        XCTAssertEqual(t.accessVerifications.count, 2)
        XCTAssertNotEqual(SSHPolicyUpgrade.pathID(profileID: id, endpointID: a), SSHPolicyUpgrade.pathID(profileID: id, endpointID: b))
    }
    func testConcurrentOrdersConvergeWithoutDowngradeAndRequireConfirmation() throws {
        let node = UUID(), account = UUID(), a = UUID(), b = UUID(), id = UUID()
        let profile = SSHConnectionProfile(id: id, accountID: account, sshAlias: "server", routePolicy: .fixed(endpointID: a))
        let old = TopologySnapshot(nodes: [.init(id: node, name: "Server", roles: [.sshHost])], endpoints: [.init(id: a, nodeID: node, address: "192.0.2.1", port: 22, protocol: .ssh), .init(id: b, nodeID: node, address: "192.0.2.2", port: 22, protocol: .ssh)], sshAccounts: [.init(id: account, nodeID: node, username: "user")], sshConnectionProfiles: [profile])
        var first = old, second = old
        let now = Date(timeIntervalSince1970: 100)
        _ = try SSHPolicyUpgrade.apply(profileID: id, endpointIDs: [a,b], automatic: true, to: &first, now: now)
        _ = try SSHPolicyUpgrade.apply(profileID: id, endpointIDs: [b,a], automatic: true, to: &second, now: now)
        var merged = TopologyCloudMetadataSnapshotPolicy.merge(local: first, remote: second)
        let reverse = TopologyCloudMetadataSnapshotPolicy.merge(local: second, remote: first)
        XCTAssertEqual(merged.sshConnectionProfiles, reverse.sshConnectionProfiles)
        XCTAssertEqual(merged.activeConnectionProfiles.first?.policyConflict, true)
        var stale = old; stale.sshConnectionProfiles[0].version = 999
        merged = TopologyCloudMetadataSnapshotPolicy.merge(local: merged, remote: stale)
        XCTAssertEqual(merged.activeConnectionProfiles.first?.policyVersion, 1)
        XCTAssertEqual(merged.activeConnectionProfiles.first?.candidateEndpointIDs.count, 2)
        _ = try SSHPolicyUpgrade.apply(profileID: id, endpointIDs: [a,b], automatic: true, to: &merged)
        XCTAssertEqual(TopologyCloudMetadataSnapshotPolicy.merge(local: merged, remote: second).activeConnectionProfiles.first?.policyConflict, false)
    }

}
