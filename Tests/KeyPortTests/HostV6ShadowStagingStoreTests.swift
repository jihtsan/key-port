import Foundation
import KeyPortCore
import XCTest
@testable import KeyPort

final class HostV6ShadowStagingStoreTests: XCTestCase {
    func testFileStoreAtomicallyPublishesHashAddressedShadowWithoutChangingProtectedArtifacts() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-shadow-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        try paths.prepareDirectories()
        try Data("legacy-state".utf8).write(to: paths.snapshot)
        try Data("Host user-alias\n".utf8).write(to: paths.userConfig)
        try Data("Host managed-alias\n".utf8).write(to: paths.managedConfig)
        try Data("example.test ssh-ed25519 fixture\n".utf8).write(to: paths.knownHosts)
        let identity = paths.identitiesDirectory.appendingPathComponent("key_fixture")
        try Data("fixture-private-material".utf8).write(to: identity)

        let artifactInspector = HostV6ProtectedArtifactInspector(paths: paths)
        let stagingStore = HostV6ShadowFileStagingStore(paths: paths)
        let before = try await artifactInspector.protectedArtifactHashes()
        let stateData = Data("{\"schemaVersion\":6}".utf8)
        let reportData = Data("{\"result\":\"lossless\"}".utf8)

        try await stagingStore.atomicPublish(stateData: stateData, reportData: reportData)

        let loaded = try await stagingStore.previousStateData()
        let after = try await artifactInspector.protectedArtifactHashes()
        XCTAssertEqual(loaded, stateData)
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: paths.snapshot), Data("legacy-state".utf8))
        XCTAssertEqual(try Data(contentsOf: identity), Data("fixture-private-material".utf8))

        let pointerData = try Data(contentsOf: paths.shadowMigrationCurrentPointer)
        let pointer = try HostV6.CanonicalJSON.decode(
            HostV6ShadowFileStagingStore.Pointer.self,
            from: pointerData
        )
        let bundleDirectory = paths.shadowMigrationBundlesDirectory
            .appendingPathComponent(pointer.bundleID, isDirectory: true)
        let stateURL = bundleDirectory.appendingPathComponent("state-v6.json")
        let reportURL = bundleDirectory.appendingPathComponent("migration-report.json")
        XCTAssertEqual(try Data(contentsOf: stateURL), stateData)
        XCTAssertEqual(try Data(contentsOf: reportURL), reportData)
        XCTAssertEqual(try permissions(of: stateURL), 0o600)
        XCTAssertEqual(try permissions(of: reportURL), 0o600)
        XCTAssertEqual(try permissions(of: paths.shadowMigrationCurrentPointer), 0o600)

        try await stagingStore.atomicPublish(stateData: stateData, reportData: reportData)
        let bundleNames = try FileManager.default.contentsOfDirectory(
            atPath: paths.shadowMigrationBundlesDirectory.path
        ).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(bundleNames, [pointer.bundleID])

        try await stagingStore.removeAllStaging()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.shadowMigrationRoot.path))
        XCTAssertEqual(try Data(contentsOf: paths.snapshot), Data("legacy-state".utf8))
    }

    func testFileStoreFailureBeforePointerReplaceKeepsPreviouslyPublishedShadow() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-shadow-replace-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let originalState = Data("{\"generation\":1}".utf8)
        let originalReport = Data("{\"report\":1}".utf8)
        let store = HostV6ShadowFileStagingStore(paths: paths)
        try await store.atomicPublish(stateData: originalState, reportData: originalReport)
        let originalPointer = try Data(contentsOf: paths.shadowMigrationCurrentPointer)
        let failingStore = HostV6ShadowFileStagingStore(
            paths: paths,
            beforeCurrentPointerReplace: { throw ShadowStoreFixtureError.injectedBeforePointerReplace }
        )

        do {
            try await failingStore.atomicPublish(
                stateData: Data("{\"generation\":2}".utf8),
                reportData: Data("{\"report\":2}".utf8)
            )
            XCTFail("Expected pointer replacement failure")
        } catch let error as HostV6.ShadowMigrationError {
            XCTAssertEqual(error.failure.stage, .migration)
            XCTAssertEqual(error.failure.objectID, "v6-shadow-staging")
            XCTAssertEqual(error.failure.code, .artifactMismatch)
            XCTAssertEqual(error.detailCode, "atomicPublishFailed")
        }

        let currentPointer = try Data(contentsOf: paths.shadowMigrationCurrentPointer)
        let currentState = try await store.previousStateData()
        XCTAssertEqual(currentPointer, originalPointer)
        XCTAssertEqual(currentState, originalState)
    }

    func testSnapshotStoreStagesCurrentLegacyBytesWithoutChangingV5Authority() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-shadow-entry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        try paths.prepareDirectories()
        let identityID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        var snapshot = AppSnapshot()
        snapshot.servers = [ServerConnection(
            id: identityID,
            name: "Fixture",
            host: "fixture.example",
            username: "fixture-user",
            alias: "fixture-alias",
            createdAt: Date(timeIntervalSince1970: 1_787_616_000),
            updatedAt: Date(timeIntervalSince1970: 1_787_616_000)
        )]
        snapshot.devices = [Device(
            id: "device_fixture",
            name: "Fixture Mac",
            isCurrent: true,
            registeredAt: Date(timeIntervalSince1970: 1_787_616_000),
            lastActiveAt: Date(timeIntervalSince1970: 1_787_616_000)
        )]
        snapshot.keys = [SSHKeyRecord(
            id: "key_fixture",
            deviceID: "device_fixture",
            kind: .ed25519,
            publicKey: "ssh-ed25519 fixture-public-key",
            fingerprint: "SHA256:fixture-key",
            privateKeyPath: "/fixture-only/key_fixture",
            isInAgent: false,
            origin: .generated,
            isLocallyAvailable: true
        )]
        snapshot.authorizations = [Authorization(
            serverID: identityID,
            keyID: "key_fixture",
            fingerprint: "SHA256:fixture-key",
            remoteComment: "keyport:v1:key_fixture:fixture-mac",
            status: .authorized,
            authorizedAt: Date(timeIntervalSince1970: 1_787_616_000),
            lastVerifiedAt: Date(timeIntervalSince1970: 1_787_616_000),
            updatedAt: Date(timeIntervalSince1970: 1_787_616_000)
        )]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let legacyData = try encoder.encode(snapshot)
        try legacyData.write(to: paths.snapshot)
        let managedConfig = SSHConfigGenerator.managedConfig(entries: [
            SSHConfigEntry(server: snapshot.servers[0], identityPath: "/fixture-only/key_fixture"),
        ])
        let userConfig = "Include \(paths.managedConfig.path)\n"
        try Data(managedConfig.utf8).write(to: paths.managedConfig)
        try Data(userConfig.utf8).write(to: paths.userConfig)
        let sshFieldsBefore = try effectiveSSHFields(alias: "fixture-alias", config: paths.userConfig)
        let snapshotStore = SnapshotStore(paths: paths)
        let credentials = EntryCredentialInspector(states: [
            identityID.uuidString.lowercased(): .missing,
        ])

        let bundle = try await snapshotStore.stageV6Shadow(
            currentDeviceID: "device_fixture",
            credentialInspector: credentials
        )
        _ = try await snapshotStore.stageV6Shadow(
            currentDeviceID: "device_fixture",
            credentialInspector: credentials
        )
        _ = try await snapshotStore.stageV6Shadow(
            currentDeviceID: "device_fixture",
            credentialInspector: credentials
        )

        XCTAssertEqual(try Data(contentsOf: paths.snapshot), legacyData)
        XCTAssertEqual(try String(contentsOf: paths.userConfig, encoding: .utf8), userConfig)
        XCTAssertEqual(try String(contentsOf: paths.managedConfig, encoding: .utf8), managedConfig)
        XCTAssertEqual(
            try effectiveSSHFields(alias: "fixture-alias", config: paths.userConfig),
            sshFieldsBefore
        )
        XCTAssertEqual(userConfig.split(separator: "\n").filter { $0.hasPrefix("Include ") }.count, 1)
        XCTAssertEqual(SSHConfigGenerator.aliases(in: managedConfig), ["fixture-alias"])
        XCTAssertEqual(bundle.envelope.synced.identities.map(\.id), [identityID])
        XCTAssertNil(bundle.envelope.migrationProvenance.authorityManifest)
        let stagedState = try await HostV6ShadowFileStagingStore(paths: paths).previousStateData()
        XCTAssertEqual(stagedState, bundle.stateData)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func effectiveSSHFields(alias: String, config: URL) throws -> [String: [String]] {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", config.path, "--", alias]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw SSHGFixtureError.failed(process.terminationStatus, detail)
        }

        let criticalKeys: Set<String> = [
            "hostname", "port", "user", "identityfile", "identitiesonly", "userknownhostsfile",
        ]
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var result: [String: [String]] = [:]
        for rawLine in text.split(whereSeparator: \Character.isNewline) {
            let fields = rawLine.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
            guard fields.count == 2 else { continue }
            let key = String(fields[0]).lowercased()
            guard criticalKeys.contains(key) else { continue }
            result[key, default: []].append(String(fields[1]))
        }
        return result
    }
}

private actor EntryCredentialInspector: HostV6ShadowCredentialInspecting {
    let states: [String: HostV6.KeychainAccountState]

    init(states: [String: HostV6.KeychainAccountState]) {
        self.states = states
    }

    func accountState(for accountID: String) async -> HostV6.KeychainAccountState {
        states[accountID] ?? .missing
    }
}

private enum ShadowStoreFixtureError: Error {
    case injectedBeforePointerReplace
}

private enum SSHGFixtureError: Error {
    case failed(Int32, String)
}
