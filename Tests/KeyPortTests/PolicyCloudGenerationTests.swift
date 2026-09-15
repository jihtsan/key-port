import XCTest
import CloudKit
import KeyPortCore
@testable import KeyPort

final class PolicyCloudGenerationTests: XCTestCase {
    func testNewCollectionBootstrapsLegacyOnceAndThenIgnoresOldWriters() async throws {
        let service = CloudKitSyncService()
        let old = CKRecord(recordType: "KPTopologyMetadata", recordID: .init(recordName: "keyport-topology-v1"))
        var snapshot = TopologySnapshot(nodes: [.init(id: UUID(), name: "Legacy", roles: [.sshHost])])
        snapshot.nodes[0].createdAt = Date(timeIntervalSince1970: 0); snapshot.nodes[0].updatedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        old["payload"] = try encoder.encode(snapshot) as CKRecordValue
        let bootstrap = try await service.fetchRecord { id in
            guard id.recordName == "keyport-topology-v1" else { throw CKError(.unknownItem) }
            return old
        }
        XCTAssertTrue(bootstrap.2)
        XCTAssertEqual(bootstrap.0.recordID.recordName, "keyport-topology-policy-v1")
        XCTAssertEqual(bootstrap.1.nodes, snapshot.nodes)
        let current = bootstrap.0
        current["payload"] = try encoder.encode(TopologySnapshot.empty) as CKRecordValue
        let next = try await service.fetchRecord { id in
            XCTAssertEqual(id.recordName, "keyport-topology-policy-v1")
            return current
        }
        XCTAssertFalse(next.2)
        XCTAssertTrue(next.1.nodes.isEmpty)
    }
    func testMalformedOrFutureRecordDoesNotFallbackToOldCollection() async throws {
        for data in [Data("invalid".utf8), Data("{\"schemaVersion\":999}".utf8)] {
            let record = CKRecord(recordType: "KPTopologyMetadata", recordID: .init(recordName: "keyport-topology-policy-v1"))
            record["payload"] = data as CKRecordValue
            do {
                _ = try await CloudKitSyncService().fetchRecord { id in
                    XCTAssertEqual(id.recordName, "keyport-topology-policy-v1")
                    return record
                }
                XCTFail("Invalid current record was accepted")
            } catch { XCTAssertEqual(error as? CloudSyncError, .malformedRecord) }
        }
    }
}
