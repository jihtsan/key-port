import Foundation
import XCTest
import KeyPortCore
@testable import KeyPort

final class WorkspaceConfigurationMigrationTests: XCTestCase {
    private func fixture() throws -> (KeyPortPaths, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = KeyPortPaths(home: root); try paths.prepareDirectories()
        let content = Data("Host original\n    HostName test.example\n".utf8)
        try content.write(to: paths.managedConfig)
        let receipt: [String: Any] = ["schemaVersion": 1, "phase": "steady", "targetContentHash": HostV6.CanonicalJSON.sha256(content)]
        try JSONSerialization.data(withJSONObject: receipt).write(to: paths.managedConfigDerivationState)
        return (paths, content)
    }
    func testOwnedConfigurationIsBackedUpBeforeRetirement() throws {
        let (paths, content) = try fixture()
        try WorkspaceConfigurationMigration.retire(paths: paths, migratedAliases: ["original"]) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.managedConfig.path))
        }
        let backups = try FileManager.default.contentsOfDirectory(at: paths.keyPortDirectory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("retired-config-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), content)
    }
    func testInstallationFailureRestoresOldConfiguration() throws {
        let (paths, content) = try fixture()
        XCTAssertThrowsError(try WorkspaceConfigurationMigration.retire(paths: paths, migratedAliases: ["original"]) { throw CocoaError(.fileWriteUnknown) })
        XCTAssertEqual(try Data(contentsOf: paths.managedConfig), content)
    }
    func testExternalEditsAndUnimportedAliasesAreNeverRetired() throws {
        let (paths, content) = try fixture()
        XCTAssertThrowsError(try WorkspaceConfigurationMigration.retire(paths: paths, migratedAliases: []) { XCTFail("Unimported aliases accepted") })
        XCTAssertEqual(try Data(contentsOf: paths.managedConfig), content)
        let edited = content + Data("# external change\n".utf8); try edited.write(to: paths.managedConfig)
        XCTAssertThrowsError(try WorkspaceConfigurationMigration.retire(paths: paths, migratedAliases: ["original"]) { XCTFail("External edit accepted") })
        XCTAssertEqual(try Data(contentsOf: paths.managedConfig), edited)
    }
}
