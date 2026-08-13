import Foundation
import XCTest
@testable import KeyPortCore

final class NodeAssociationTests: XCTestCase {
    private let serverID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testUniqueMagicDNSAutomaticallyLinks() throws {
        let result = try evaluate(host: "build.tail.example.", nodes: [node(id: "node-1", dns: "build.tail.example")])
        XCTAssertEqual(result.association.state, .linked)
        XCTAssertEqual(result.association.method, .automatic)
        XCTAssertEqual(result.association.evidenceKinds, [.exactMagicDNS])
        XCTAssertEqual(result.association.target?.nodeID, "node-1")
    }

    func testUniqueIPv6AutomaticallyLinksAfterNormalization() throws {
        let result = try evaluate(host: "[fd7a:115c:a1e0:0:0:0:0:1]", nodes: [node(id: "node-1", addresses: ["fd7a:115c:a1e0::1"])])
        XCTAssertEqual(result.association.state, .linked)
        XCTAssertEqual(result.association.evidenceKinds, [.exactTailscaleIP])
    }

    func testNoMatchAndMultipleMatchNeverAutomaticallyLink() throws {
        let noMatch = try evaluate(host: "public.example", nodes: [node(id: "node-1", dns: "build.tail.example")])
        XCTAssertEqual(noMatch.association.state, .unlinked)
        XCTAssertEqual(noMatch.association.reasonCodes, [.noMatch])

        let duplicate = try evaluate(host: "100.64.0.1", nodes: [
            node(id: "node-1", addresses: ["100.64.0.1"]),
            node(id: "node-2", addresses: ["100.64.0.1"]),
        ])
        XCTAssertEqual(duplicate.association.state, .pendingConfirmation)
        XCTAssertNil(duplicate.association.target)
        XCTAssertEqual(duplicate.association.reasonCodes, [.multipleStrongMatches])
    }

    func testProxyRouteNeverAutomaticallyLinks() throws {
        let status = status(nodes: [node(id: "node-1", dns: "build.tail.example")])
        let result = try NodeAssociationEngine.evaluate(
            testCaseNodeID: "tc-1",
            serverID: serverID,
            route: EffectiveSSHRoute(hostname: "build.tail.example", proxyJump: "bastion"),
            status: status,
            sourceState: .complete,
            now: now
        )
        XCTAssertEqual(result.association.state, .pendingConfirmation)
        XCTAssertEqual(result.association.reasonCodes, [.proxiedRoute])
    }

    func testExistingAutomaticLinkBecomesReviewRequiredWhenRouteGainsProxy() throws {
        let linked = try evaluate(host: "build.tail.example", nodes: [node(id: "node-1", dns: "build.tail.example")]).association
        let result = try NodeAssociationEngine.evaluate(
            testCaseNodeID: "tc-1",
            serverID: serverID,
            route: EffectiveSSHRoute(hostname: "build.tail.example", proxyJump: "bastion"),
            status: status(nodes: [node(id: "node-1", dns: "build.tail.example")]),
            sourceState: .complete,
            existing: linked,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(result.association.state, .reviewRequired)
        XCTAssertEqual(result.association.reasonCodes, [.proxiedRoute])
        XCTAssertFalse(result.association.allowsExecution)
    }

    func testFallbackParserIdentityCannotBePersistedOrAutomaticallyLinked() throws {
        let json = #"{"BackendState":"Running","CurrentTailnet":{"Name":"Tail.Example"},"Peer":{"nodekey:abc":{"PublicKey":"nodekey:abc","HostName":"build","DNSName":"build.tail.example.","TailscaleIPs":["100.64.0.1"]}}}"#
        let parsed = try TailscaleStatusParser.parse(json)
        XCTAssertNil(parsed.nodes.first?.stableNodeID)
        let result = try NodeAssociationEngine.evaluate(
            testCaseNodeID: "tc-1",
            serverID: serverID,
            route: EffectiveSSHRoute(hostname: "build.tail.example"),
            status: parsed,
            sourceState: .complete,
            now: now
        )
        XCTAssertEqual(result.association.state, .unlinked)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testManualConfirmRevisionConflictAndUnlinkTombstone() throws {
        let evaluation = try evaluate(host: "public.example", nodes: [node(id: "node-1", dns: "build.tail.example")])
        let target = ActualNodeReference(tailnetKey: "TAIL.EXAMPLE.", nodeID: "node-1")
        let confirmed = try NodeAssociationEngine.confirm(
            evaluation.association,
            target: target,
            expectedRevision: evaluation.association.revision,
            validTargets: [target],
            now: now
        )
        XCTAssertEqual(confirmed.method, .manual)
        XCTAssertTrue(confirmed.allowsExecution)
        XCTAssertThrowsError(try NodeAssociationEngine.unlink(confirmed, expectedRevision: confirmed.revision - 1))

        let unlinked = try NodeAssociationEngine.unlink(confirmed, expectedRevision: confirmed.revision, now: now)
        XCTAssertEqual(unlinked.state, .invalidated)
        XCTAssertFalse(unlinked.autoLinkEnabled)
        XCTAssertNil(unlinked.target)

        let reevaluated = try NodeAssociationEngine.evaluate(
            testCaseNodeID: "tc-1",
            serverID: serverID,
            route: EffectiveSSHRoute(hostname: "build.tail.example"),
            status: status(nodes: [node(id: "node-1", dns: "build.tail.example")]),
            sourceState: .complete,
            existing: unlinked,
            now: now
        )
        XCTAssertEqual(reevaluated.association.state, .invalidated)
        XCTAssertNil(reevaluated.association.target)
    }

    func testNodeIDChangeWithSameAddressRequiresReview() throws {
        let linked = try evaluate(host: "100.64.0.1", nodes: [node(id: "old", addresses: ["100.64.0.1"])]).association
        let result = try NodeAssociationEngine.evaluate(
            testCaseNodeID: "tc-1",
            serverID: serverID,
            route: EffectiveSSHRoute(hostname: "100.64.0.1"),
            status: status(nodes: [node(id: "new", addresses: ["100.64.0.1"])]),
            sourceState: .complete,
            existing: linked,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(result.association.state, .reviewRequired)
        XCTAssertEqual(result.association.reasonCodes, [.nodeIdentityChanged])
        XCTAssertEqual(result.association.target?.nodeID, "old")
        XCTAssertFalse(result.association.allowsExecution)
    }

    func testAutomaticLinkEndpointDriftRequiresReview() throws {
        let linked = try evaluate(host: "build.tail.example", nodes: [
            node(id: "node-1", dns: "build.tail.example"),
            node(id: "node-2", dns: "other.tail.example"),
        ]).association
        let result = try NodeAssociationEngine.evaluate(
            testCaseNodeID: "tc-1",
            serverID: serverID,
            route: EffectiveSSHRoute(hostname: "other.tail.example"),
            status: status(nodes: [
                node(id: "node-1", dns: "build.tail.example"),
                node(id: "node-2", dns: "other.tail.example"),
            ]),
            sourceState: .complete,
            existing: linked,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(result.association.state, .reviewRequired)
        XCTAssertEqual(result.association.reasonCodes, [.endpointConflict])
        XCTAssertEqual(result.association.target?.nodeID, "node-1")

        let repeated = try NodeAssociationEngine.evaluate(
            testCaseNodeID: "tc-1",
            serverID: serverID,
            route: EffectiveSSHRoute(hostname: "other.tail.example"),
            status: status(nodes: [
                node(id: "node-1", dns: "build.tail.example"),
                node(id: "node-2", dns: "other.tail.example"),
            ]),
            sourceState: .complete,
            existing: result.association,
            now: now.addingTimeInterval(120)
        )
        XCTAssertEqual(repeated.association.revision, result.association.revision)
        XCTAssertEqual(repeated.association.updatedAt, result.association.updatedAt)
    }

    func testUnavailableSourcePreservesMappingAndVerificationTime() throws {
        let linked = try evaluate(host: "100.64.0.1", nodes: [node(id: "node-1", addresses: ["100.64.0.1"])]).association
        let result = try NodeAssociationEngine.evaluate(
            testCaseNodeID: "tc-1",
            serverID: serverID,
            route: EffectiveSSHRoute(hostname: "100.64.0.1"),
            status: nil,
            sourceState: .unavailable,
            existing: linked,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(result.association.state, .linked)
        XCTAssertEqual(result.association.lastVerifiedAt, linked.lastVerifiedAt)
        XCTAssertEqual(result.association.reasonCodes, [.sourceUnavailable])
    }

    func testLegacySnapshotMigratesWithoutGuessingAndRoundTripContainsNoCandidates() throws {
        let legacy = #"{"schemaVersion":4,"servers":[],"devices":[],"keys":[],"authorizations":[],"auditEvents":[]}"#.data(using: .utf8)!
        var decoded = try JSONDecoder().decode(AppSnapshot.self, from: legacy)
        XCTAssertEqual(decoded.schemaVersion, 4)
        decoded.migrateNodeAssociationsSchemaIfNeeded()
        XCTAssertEqual(decoded.schemaVersion, 5)
        XCTAssertTrue(decoded.nodeAssociations.isEmpty)

        var snapshot = decoded
        snapshot.nodeAssociations = [NodeAssociation(testCaseNodeID: "tc-1", serverID: serverID)]
        let encoded = try JSONEncoder().encode(snapshot)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("username"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("identityfile"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("ssh -g"))
    }

    func testTombstoneWinsCloudStyleMerge() throws {
        let linked = try evaluate(host: "100.64.0.1", nodes: [node(id: "node-1", addresses: ["100.64.0.1"])]).association
        let tombstone = try NodeAssociationEngine.unlink(linked, expectedRevision: linked.revision, now: now.addingTimeInterval(60))
        let merged = NodeAssociationMerger.merge([tombstone, linked])
        XCTAssertEqual(merged.first?.state, .invalidated)
        XCTAssertFalse(merged.first?.autoLinkEnabled ?? true)
    }

    func testAssociationMutationsAreIdempotent() throws {
        let evaluation = try evaluate(host: "public.example", nodes: [node(id: "node-1", dns: "build.tail.example")])
        let target = ActualNodeReference(tailnetKey: "tail.example", nodeID: "node-1")
        let confirmed = try NodeAssociationEngine.confirm(
            evaluation.association,
            target: target,
            expectedRevision: evaluation.association.revision,
            validTargets: [target],
            now: now
        )
        XCTAssertEqual(
            try NodeAssociationEngine.confirm(
                confirmed,
                target: target,
                expectedRevision: confirmed.revision,
                validTargets: [target],
                now: now.addingTimeInterval(60)
            ),
            confirmed
        )
        let unlinked = try NodeAssociationEngine.unlink(confirmed, expectedRevision: confirmed.revision, now: now)
        XCTAssertEqual(
            try NodeAssociationEngine.unlink(
                unlinked,
                expectedRevision: unlinked.revision,
                now: now.addingTimeInterval(60)
            ),
            unlinked
        )
    }

    func testIncompleteTailscaleStatusIsNotAuthoritative() throws {
        let incomplete = TailscaleStatus(
            backendState: "NeedsLogin",
            tailnetName: "tail.example",
            magicDNSSuffix: nil,
            nodes: [node(id: "node-1")]
        )
        XCTAssertFalse(incomplete.isCompleteAssociationSnapshot)

        let fallbackNode = TailscaleNode(
            id: "fallback",
            name: "fallback",
            dnsName: nil,
            operatingSystem: nil,
            addresses: [],
            isOnline: false,
            isCurrent: false,
            lastSeen: nil,
            relay: nil,
            isExitNode: false,
            isExitNodeOption: false
        )
        let missingStableID = TailscaleStatus(
            backendState: "Running",
            tailnetName: "tail.example",
            magicDNSSuffix: nil,
            nodes: [fallbackNode]
        )
        XCTAssertFalse(missingStableID.isCompleteAssociationSnapshot)
    }

    func testMultipleTestCaseNodesCanShareOneStableTarget() throws {
        let first = try evaluate(host: "100.64.0.1", nodes: [node(id: "node-1", addresses: ["100.64.0.1"])]).association
        let second = try NodeAssociationEngine.evaluate(
            testCaseNodeID: "tc-2",
            serverID: serverID,
            route: EffectiveSSHRoute(hostname: "100.64.0.1"),
            status: status(nodes: [node(id: "node-1", addresses: ["100.64.0.1"])]),
            sourceState: .complete,
            now: now
        ).association
        let merged = NodeAssociationMerger.merge([first, second])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.compactMap(\.target?.nodeID)), ["node-1"])
    }

    func testExistingTestCaseNodeCannotBeEvaluatedForAnotherServer() throws {
        let existing = try evaluate(host: "100.64.0.1", nodes: [node(id: "node-1", addresses: ["100.64.0.1"])]).association
        XCTAssertThrowsError(try NodeAssociationEngine.evaluate(
            testCaseNodeID: existing.testCaseNodeID,
            serverID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            route: EffectiveSSHRoute(hostname: "100.64.0.1"),
            status: status(nodes: [node(id: "node-1", addresses: ["100.64.0.1"])]),
            sourceState: .complete,
            existing: existing,
            now: now
        )) { error in
            XCTAssertEqual(error as? NodeAssociationMutationError, .serverConflict)
        }
    }

    func testSSHConfigParserCapturesProxyAndHostKeyAlias() throws {
        let parsed = SSHConfigDiscoveryParser.parse(alias: "build", output: """
        hostname build.tail.example
        port 22
        user deploy
        proxyjump bastion
        proxycommand none
        hostkeyalias build-host-key
        """)
        XCTAssertEqual(parsed?.proxyJump, "bastion")
        XCTAssertEqual(parsed?.proxyCommand, "none")
        XCTAssertEqual(parsed?.hostKeyAlias, "build-host-key")
    }

    private func evaluate(host: String, nodes: [TailscaleNode]) throws -> NodeAssociationEvaluation {
        try NodeAssociationEngine.evaluate(
            testCaseNodeID: "tc-1",
            serverID: serverID,
            route: EffectiveSSHRoute(hostname: host),
            status: status(nodes: nodes),
            sourceState: .complete,
            now: now
        )
    }

    private func status(nodes: [TailscaleNode]) -> TailscaleStatus {
        TailscaleStatus(backendState: "Running", tailnetName: "Tail.Example.", magicDNSSuffix: nil, nodes: nodes)
    }

    private func node(id: String, dns: String? = nil, addresses: [String] = []) -> TailscaleNode {
        TailscaleNode(
            id: id,
            name: id,
            dnsName: dns,
            operatingSystem: "linux",
            addresses: addresses,
            isOnline: true,
            isCurrent: false,
            lastSeen: nil,
            relay: nil,
            isExitNode: false,
            isExitNodeOption: false,
            stableNodeID: id
        )
    }
}
