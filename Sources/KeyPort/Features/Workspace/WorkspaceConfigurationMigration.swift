import Foundation
import KeyPortCore

/// Retires only the old generated file after verifying its ownership receipt.
/// The user's Include and all unrelated SSH files stay in place; a missing Include target is valid OpenSSH.
enum WorkspaceConfigurationMigration {
    private struct Receipt: Decodable {
        let schemaVersion: Int
        let phase: String
        let targetContentHash: String
    }
    static func retire<T>(paths: KeyPortPaths, migratedAliases: Set<String>, installing: () throws -> T) throws -> T {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.managedConfig.path) else { return try installing() }
        guard try paths.managedConfig.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              fm.fileExists(atPath: paths.managedConfigDerivationState.path) else {
            throw ManagedAliasInstallation.Failure(message: "旧 SSH 配置缺少所有权凭据，未覆盖；请先保留并检查旧配置。")
        }
        let data = try Data(contentsOf: paths.managedConfig)
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: paths.managedConfigDerivationState))
        let aliases = SSHConfigGenerator.aliases(in: String(decoding: data, as: UTF8.self))
        guard receipt.schemaVersion == 1, receipt.phase == "steady", receipt.targetContentHash == HostV6.CanonicalJSON.sha256(data),
              aliases.allSatisfy({ migratedAliases.contains($0.lowercased()) }) else {
            throw ManagedAliasInstallation.Failure(message: "旧 SSH 配置存在外部修改或未导入的连接，未覆盖。")
        }
        let backup = paths.keyPortDirectory.appendingPathComponent("retired-config-\(UUID().uuidString).backup")
        try fm.copyItem(at: paths.managedConfig, to: backup)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        guard try Data(contentsOf: paths.managedConfig) == data else { throw WorkspaceMigrationError.conflictingIdentity }
        try fm.removeItem(at: paths.managedConfig)
        do { return try installing() }
        catch {
            // Do not overwrite a concurrent external edit during recovery.
            if !fm.fileExists(atPath: paths.managedConfig.path) {
                try data.write(to: paths.managedConfig, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.managedConfig.path)
            }
            throw error
        }
    }
}
