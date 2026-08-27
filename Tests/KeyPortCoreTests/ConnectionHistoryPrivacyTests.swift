import Foundation
import XCTest
@testable import KeyPortCore

/// Privacy gates for slice E: exact allow-lists per surface and static scans
/// that keep BSSID, raw output and location requests out of the codebase.
final class ConnectionHistoryPrivacyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_787_616_000)

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KeyPortCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private func jsonObject<T: Encodable>(of value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let object = try JSONSerialization.jsonObject(with: encoder.encode(value))
        return try XCTUnwrap(object as? [String: Any])
    }

    func testConnectionRecordAllowListIsExact() throws {
        let record = ConnectionRecord(
            id: UUID(), hostID: UUID(), addressID: UUID(), sshIdentityID: UUID(), serviceID: UUID(),
            action: .tunnelOperation, accessMode: .tunnel, result: .failed,
            failureCode: .targetConnectionRefused, startedAt: t0, endedAt: t0.addingTimeInterval(1),
            ssid: "FIXTURE_SSID_MARKER"
        )
        let object = try jsonObject(of: record)
        XCTAssertEqual(
            Set(object.keys),
            [
                "id", "hostID", "addressID", "sshIdentityID", "serviceID", "action",
                "accessMode", "result", "failureCode", "startedAt", "endedAt", "ssid",
            ],
            "ConnectionRecord must encode exactly the architecture 10.1 allow-list"
        )
        for forbidden in ["password", "privateKey", "publicKey", "command", "rawOutput", "bssid", "location", "headers", "cookies"] {
            XCTAssertFalse(object.keys.contains(forbidden), "history record gained forbidden field \(forbidden)")
        }
    }

    func testOperationContextAllowListIsExact() throws {
        let context = OperationContext(
            operationID: UUID(), hostID: UUID(), addressID: UUID(), sshIdentityID: UUID(),
            serviceID: UUID(), action: .serviceDiscovery, startedAt: t0
        )
        let object = try jsonObject(of: context)
        XCTAssertEqual(
            Set(object.keys),
            ["operationID", "hostID", "addressID", "sshIdentityID", "serviceID", "action", "startedAt"]
        )
    }

    func testSSIDStaysInsideTheLocalHistoryEnvelope() throws {
        let envelope = ConnectionHistoryEnvelope(
            inflight: [OperationContext(operationID: UUID(), hostID: UUID(), action: .sshCheck, startedAt: t0)],
            records: [ConnectionRecord(
                id: UUID(), hostID: UUID(), action: .serviceOpen,
                result: .succeeded, startedAt: t0, endedAt: t0, ssid: "FIXTURE_SSID_MARKER"
            )]
        )
        let text = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        XCTAssertTrue(text.contains("FIXTURE_SSID_MARKER"), "history is the one surface allowed to hold the SSID")
        XCTAssertFalse(text.contains("bssid"), "history must never carry a BSSID")
    }

    func testCloudPayloadAllowListExcludesHistoryAndSSID() throws {
        XCTAssertFalse(HostV6.SyncedGraph.cloudCodingKeys.contains("ssid"))
        XCTAssertFalse(HostV6.SyncedGraph.cloudCodingKeys.contains("records"))
        XCTAssertFalse(HostV6.SyncedGraph.cloudCodingKeys.contains("inflight"))

        let envelope = HostV6.MetadataEnvelope(
            synced: HostV6.SyncedGraph(),
            local: HostV6.LocalState(),
            migrationProvenance: .empty
        )
        let cloudPayload = HostV6.CloudPayload(envelope: envelope)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(cloudPayload)
        let syncedObject = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["synced"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(syncedObject.keys),
            Set(HostV6.SyncedGraph.cloudCodingKeys),
            "the Cloud payload must encode exactly the synced allow-list"
        )

        // A remote payload that smuggles an SSID is fail-closed: flagged with
        // the stable code and dropped, never decoded into local state.
        var smuggled = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var synced = try XCTUnwrap(smuggled["synced"] as? [String: Any])
        synced["ssid"] = "FIXTURE_SSID_MARKER"
        synced["connectionRecords"] = [["ssid": "FIXTURE_SSID_MARKER"]]
        smuggled["synced"] = synced
        let decoded = try HostV6.CloudPayloadCodec.decode(JSONSerialization.data(withJSONObject: smuggled))
        XCTAssertTrue(decoded.diagnosticCodes.contains(.unexpectedCloudField))
        XCTAssertTrue(decoded.unexpectedFieldPaths.contains("synced.ssid"))
        let reencoded = try encoder.encode(decoded.payload)
        XCTAssertFalse(String(decoding: reencoded, as: UTF8.self).contains("FIXTURE_SSID_MARKER"))
    }

    // MARK: static source scans

    private func sourceFiles() throws -> [URL] {
        let sources = Self.repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    func testNoSourceReadsBSSIDOrRequestsLocationAuthorization() throws {
        for file in try sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lowercased = text.lowercased()
            XCTAssertFalse(
                lowercased.contains(".bssid"),
                "\(file.lastPathComponent) reads a BSSID; only the SSID may be read"
            )
            XCTAssertFalse(
                text.contains("requestWhenInUseAuthorization"),
                "\(file.lastPathComponent) requests location authorization; consent flow is not part of this slice"
            )
        }
    }

    func testCoreWLANAccessIsConfinedToTheHintProvider() throws {
        var coreWLANFiles: [String] = []
        for file in try sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("import CoreWLAN") || text.contains("CWWiFiClient") {
                coreWLANFiles.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(
            coreWLANFiles,
            ["SystemNetworkHintProvider.swift"],
            "CoreWLAN must stay confined to the injectable hint provider"
        )
    }
}
