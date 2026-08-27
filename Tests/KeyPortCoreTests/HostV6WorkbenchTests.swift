import XCTest
@testable import KeyPortCore

final class HostV6WorkbenchTests: XCTestCase {
    private let hostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let firstAddressID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let secondAddressID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let firstIdentityID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let secondIdentityID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private let serviceID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    private let otherHostID = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
    private let crossHostAddressID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-cccccccccccc")!
    private let reviewID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-cccccccccccc")!

    func testProjectionKeepsOneHostRowForMultipleAccountsAndComputesIndependentAxes() throws {
        let history = [ConnectionRecord(
            id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
            hostID: hostID,
            addressID: firstAddressID,
            sshIdentityID: firstIdentityID,
            serviceID: serviceID,
            action: .serviceOpen,
            accessMode: .direct,
            result: .succeeded,
            startedAt: Date(timeIntervalSince1970: 690),
            endedAt: Date(timeIntervalSince1970: 700)
        )]
        let envelope = makeEnvelope(
            firstPinState: .confirmed,
            secondPinState: .confirmed,
            firstEvidence: .init(
                addressID: firstAddressID,
                networkEpoch: 7,
                observedAt: Date(timeIntervalSince1970: 700),
                wasReachable: true
            ),
            history: history
        )

        let projection = HostV6.HostWorkbenchProjection.make(
            from: envelope,
            currentNetworkEpoch: 7,
            history: history
        )

        XCTAssertEqual(projection.rows.count, 1)
        let row = try XCTUnwrap(projection.rows.first)
        XCTAssertEqual(row.host.id, hostID)
        XCTAssertEqual(row.identityCount, 2)
        XCTAssertEqual(row.addressCount, 2)
        XCTAssertEqual(row.serviceCount, 1)
        XCTAssertEqual(row.axes.reachability, .reachable)
        XCTAssertEqual(row.axes.sshTrust, .confirmed)
        XCTAssertEqual(row.axes.accessMode, .direct)
        XCTAssertEqual(projection.aggregates[hostID]?.identities.map(\.id), [firstIdentityID, secondIdentityID])
    }

    func testFixedAddressResolutionUsesHighestPriorityReferenceAndDoesNotFallBackWhenInvalid() throws {
        var envelope = makeEnvelope()
        envelope.synced.hosts[0].fixedAddressID = firstAddressID
        envelope.synced.identities[0].preferredAddressID = secondAddressID
        envelope.synced.services[0].fixedAddressID = secondAddressID

        XCTAssertEqual(
            HostV6.HostWorkbenchProjection.resolveFixedAddress(
                in: try XCTUnwrap(envelope.synced.aggregate(hostID: hostID)),
                identityID: firstIdentityID,
                serviceID: serviceID
            ),
            .selected(addressID: secondAddressID, owner: .service)
        )

        envelope.synced.services[0].fixedAddressID = UUID()
        XCTAssertEqual(
            HostV6.HostWorkbenchProjection.resolveFixedAddress(
                in: try XCTUnwrap(envelope.synced.aggregate(hostID: hostID)),
                identityID: firstIdentityID,
                serviceID: serviceID
            ),
            .invalid(owner: .service)
        )
    }

    func testProjectionWithoutEvidenceKeepsReachabilityUnknownAndAccessUnavailable() throws {
        let projection = HostV6.HostWorkbenchProjection.make(
            from: makeEnvelope(),
            currentNetworkEpoch: 7
        )
        let row = try XCTUnwrap(projection.rows.first)

        XCTAssertEqual(row.axes.reachability, .unknown)
        XCTAssertEqual(row.addresses.map(\.reachability), [.unknown, .unknown])
        XCTAssertEqual(row.axes.sshTrust, .confirmed)
        XCTAssertEqual(row.axes.accessMode, .unavailable)
    }

    func testFixedAddressResolutionRejectsDeletedAndCrossHostReferencesWithoutFallback() throws {
        var envelope = makeEnvelope()
        let stamp = envelope.synced.hosts[0].stamp
        envelope.synced.hosts.append(HostV6.Host(
            id: otherHostID,
            name: "Other host",
            group: "lab",
            machineConfiguration: nil,
            fixedAddressID: nil,
            createdAt: stamp.updatedAt,
            stamp: stamp
        ))
        envelope.synced.addresses.append(HostV6.AccessAddress(
            id: crossHostAddressID,
            hostID: otherHostID,
            normalizedHost: "other.example.com",
            sshPort: 22,
            originalLabel: "other.example.com",
            source: .manual,
            sortOrder: 0,
            stamp: stamp
        ))

        envelope.synced.hosts[0].fixedAddressID = firstAddressID
        envelope.synced.identities[0].preferredAddressID = secondAddressID
        envelope.synced.services[0].fixedAddressID = firstAddressID
        envelope.synced.addresses[0].deletedAt = Date(timeIntervalSince1970: 200)
        let aggregate = try XCTUnwrap(envelope.synced.aggregate(hostID: hostID))
        XCTAssertEqual(
            HostV6.HostWorkbenchProjection.resolveFixedAddress(
                in: aggregate,
                identityID: firstIdentityID,
                serviceID: serviceID
            ),
            .invalid(owner: .service)
        )

        envelope.synced.addresses[0].deletedAt = nil
        envelope.synced.services[0].fixedAddressID = crossHostAddressID
        let refreshedAggregate = try XCTUnwrap(envelope.synced.aggregate(hostID: hostID))
        XCTAssertEqual(
            HostV6.HostWorkbenchProjection.resolveFixedAddress(
                in: refreshedAggregate,
                identityID: firstIdentityID,
                serviceID: serviceID
            ),
            .invalid(owner: .service)
        )

        envelope.synced.services[0].fixedAddressID = nil
        envelope.synced.identities[0].preferredAddressID = crossHostAddressID
        let crossIdentityAggregate = try XCTUnwrap(envelope.synced.aggregate(hostID: hostID))
        XCTAssertEqual(
            HostV6.HostWorkbenchProjection.resolveFixedAddress(
                in: crossIdentityAggregate,
                identityID: firstIdentityID,
                serviceID: serviceID
            ),
            .invalid(owner: .identity)
        )

        envelope.synced.identities[0].preferredAddressID = nil
        envelope.synced.hosts[0].fixedAddressID = crossHostAddressID
        let crossHostAggregate = try XCTUnwrap(envelope.synced.aggregate(hostID: hostID))
        XCTAssertEqual(
            HostV6.HostWorkbenchProjection.resolveFixedAddress(in: crossHostAggregate),
            .invalid(owner: .host)
        )
    }

    func testBlockingMergeReviewChangesTrustUntilItIsResolved() throws {
        var envelope = makeEnvelope()
        let stamp = envelope.synced.hosts[0].stamp
        envelope.synced.mergeReviews = [HostV6.MergeReview(
            id: reviewID,
            entityType: .host,
            entityID: hostID.uuidString,
            candidates: [],
            isBlocking: true,
            stamp: stamp
        )]

        XCTAssertEqual(
            try XCTUnwrap(HostV6.HostWorkbenchProjection.make(from: envelope, currentNetworkEpoch: 0).rows.first).axes.sshTrust,
            .changed
        )

        envelope.synced.mergeReviews[0].resolvedAt = Date(timeIntervalSince1970: 300)
        XCTAssertEqual(
            try XCTUnwrap(HostV6.HostWorkbenchProjection.make(from: envelope, currentNetworkEpoch: 0).rows.first).axes.sshTrust,
            .confirmed
        )
    }

    func testDeletedPinsDoNotBlockTrustAndReplacedPinsAreChanged() throws {
        var deletedPending = makeEnvelope(firstPinState: .pendingReview)
        deletedPending.synced.hostKeyPins[0].deletedAt = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(
            try XCTUnwrap(HostV6.HostWorkbenchProjection.make(from: deletedPending, currentNetworkEpoch: 0).rows.first).axes.sshTrust,
            .confirmed
        )

        let replaced = makeEnvelope(firstPinState: .replaced, secondPinState: .replaced)
        XCTAssertEqual(
            try XCTUnwrap(HostV6.HostWorkbenchProjection.make(from: replaced, currentNetworkEpoch: 0).rows.first).axes.sshTrust,
            .changed
        )
    }

    func testProjectionSortingIsStableWhenGraphArraysAreReordered() throws {
        var envelope = makeEnvelope()
        let stamp = envelope.synced.hosts[0].stamp
        envelope.synced.hosts.append(HostV6.Host(
            id: otherHostID,
            name: "Review host",
            group: "lab",
            machineConfiguration: nil,
            fixedAddressID: nil,
            createdAt: stamp.updatedAt,
            stamp: stamp
        ))
        envelope.synced.hosts.reverse()
        envelope.synced.addresses.reverse()
        envelope.synced.identities.reverse()
        envelope.synced.services.reverse()

        let projection = HostV6.HostWorkbenchProjection.make(from: envelope, currentNetworkEpoch: 0)

        XCTAssertEqual(projection.rows.map(\.id), [otherHostID, hostID])
        let hostRow = try XCTUnwrap(projection.rows.first { $0.id == hostID })
        XCTAssertEqual(hostRow.addresses.map(\.id), [firstAddressID, secondAddressID])
        XCTAssertEqual(hostRow.identities.map(\.id), [firstIdentityID, secondIdentityID])
        XCTAssertEqual(hostRow.services.map(\.id), [serviceID])
    }

    func testNetworkEpochMakesReachabilityStaleWithoutChangingTrustOrAccessAxis() throws {
        let history = [ConnectionRecord(
            id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
            hostID: hostID,
            addressID: firstAddressID,
            serviceID: serviceID,
            action: .serviceOpen,
            accessMode: .tunnel,
            result: .succeeded,
            startedAt: Date(timeIntervalSince1970: 690),
            endedAt: Date(timeIntervalSince1970: 700)
        )]
        let envelope = makeEnvelope(
            firstPinState: .pendingReview,
            secondPinState: .confirmed,
            firstEvidence: .init(
                addressID: firstAddressID,
                networkEpoch: 7,
                observedAt: Date(timeIntervalSince1970: 700),
                wasReachable: true
            ),
            history: history
        )

        let projection = HostV6.HostWorkbenchProjection.make(
            from: envelope,
            currentNetworkEpoch: 8,
            history: history
        )
        let row = try XCTUnwrap(projection.rows.first)

        XCTAssertEqual(row.axes.reachability, .stale)
        XCTAssertEqual(row.axes.sshTrust, .changed)
        XCTAssertEqual(row.axes.accessMode, .tunnel)
        XCTAssertEqual(row.addresses.first?.reachability, .stale)
    }

    private func makeEnvelope(
        firstPinState: HostV6.HostKeyPinState = .confirmed,
        secondPinState: HostV6.HostKeyPinState = .confirmed,
        firstEvidence: HostV6.ReachabilityEvidence? = nil,
        history: [ConnectionRecord] = []
    ) -> HostV6.MetadataEnvelope {
        let stamp = HostV6.SyncStamp(
            vector: ["device/test": 1],
            mutationID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let firstAddress = HostV6.AccessAddress(
            id: firstAddressID,
            hostID: hostID,
            normalizedHost: "public.example.com",
            sshPort: 22,
            originalLabel: "public.example.com",
            source: .manual,
            sortOrder: 0,
            stamp: stamp
        )
        let secondAddress = HostV6.AccessAddress(
            id: secondAddressID,
            hostID: hostID,
            normalizedHost: "100.64.0.2",
            sshPort: 2222,
            originalLabel: "tailnet",
            source: .tailscale,
            sortOrder: 1,
            stamp: stamp
        )
        let firstIdentity = HostV6.SSHIdentity(
            id: firstIdentityID,
            hostID: hostID,
            username: "alice",
            alias: "host-alice",
            preferredAddressID: nil,
            createdAt: stamp.updatedAt,
            stamp: stamp
        )
        let secondIdentity = HostV6.SSHIdentity(
            id: secondIdentityID,
            hostID: hostID,
            username: "bob",
            alias: "host-bob",
            preferredAddressID: nil,
            createdAt: stamp.updatedAt,
            stamp: stamp
        )
        let host = HostV6.Host(
            id: hostID,
            name: "Review host",
            group: "lab",
            machineConfiguration: nil,
            fixedAddressID: nil,
            createdAt: stamp.updatedAt,
            stamp: stamp
        )
        let firstPin = HostV6.HostKeyPin(
            id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            hostID: hostID,
            addressID: firstAddressID,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:first",
            state: firstPinState,
            firstConfirmedAt: stamp.updatedAt,
            lastSeenAt: stamp.updatedAt,
            stamp: stamp
        )
        let secondPin = HostV6.HostKeyPin(
            id: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            hostID: hostID,
            addressID: secondAddressID,
            algorithm: "rsa-sha2-512",
            fingerprint: "SHA256:second",
            state: secondPinState,
            firstConfirmedAt: stamp.updatedAt,
            lastSeenAt: stamp.updatedAt,
            stamp: stamp
        )
        let service = HostV6.SavedService(
            id: serviceID,
            hostID: hostID,
            name: "Dashboard",
            serviceProtocol: .http,
            endpoint: .init(bind: .loopbackV4, port: 8080, path: "/"),
            isFavorite: true,
            fixedAddressID: nil,
            stamp: stamp
        )
        let identityStates = [
            HostV6.LocalSSHIdentityState(
                sshIdentityID: firstIdentityID,
                status: .authorized,
                statusDetail: nil,
                lastCheckedAt: stamp.updatedAt,
                passwordCheck: nil,
                keyCheck: nil,
                machineConfigurationRefreshAttemptedAt: nil
            ),
            HostV6.LocalSSHIdentityState(
                sshIdentityID: secondIdentityID,
                status: .authorized,
                statusDetail: nil,
                lastCheckedAt: stamp.updatedAt,
                passwordCheck: nil,
                keyCheck: nil,
                machineConfigurationRefreshAttemptedAt: nil
            ),
        ]
        return HostV6.MetadataEnvelope(
            synced: .init(
                hosts: [host],
                addresses: [firstAddress, secondAddress],
                identities: [firstIdentity, secondIdentity],
                hostKeyPins: [firstPin, secondPin],
                services: [service]
            ),
            local: .init(
                identityStates: identityStates,
                reachabilityEvidence: firstEvidence.map { [$0] } ?? [],
                auditEvents: []
            ),
            migrationProvenance: .empty
        )
    }
}
