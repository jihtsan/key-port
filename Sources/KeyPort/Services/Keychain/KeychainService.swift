import Foundation
import LocalAuthentication
import Security

protocol KeychainItemAPI: Sendable {
    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus
    func add(_ attributes: [CFString: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func copyMatching(_ query: [CFString: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func delete(_ query: [CFString: Any]) -> OSStatus
}

struct SystemKeychainItemAPI: KeychainItemAPI {
    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ attributes: [CFString: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, result)
    }

    func copyMatching(_ query: [CFString: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, result)
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case status(OSStatus)
    case invalidData
    case synchronizableUnavailable
    case iCloudKeychainUnavailable

    var errorDescription: String? {
        switch self {
        case .status(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 错误 \(status)"
        case .invalidData: return "Keychain 返回了无效的密码数据。"
        case .synchronizableUnavailable:
            return "此版本无法使用 iCloud Keychain 同步。请关闭同步，将密码保存到此 Mac 的 Keychain。"
        case .iCloudKeychainUnavailable:
            return "iCloud Keychain 当前不可用。请检查 Apple 账户和系统设置中的密码与钥匙串同步。"
        }
    }
}

enum ServerPasswordStorage: Equatable, Sendable {
    case local
    case synchronizable

    var isSynchronizable: Bool {
        self == .synchronizable
    }
}

struct ServerCredential: Sendable {
    let username: String
    var passwordData: Data
}

actor KeychainService {
    static let serverPasswordService = "com.jihtsan.KeyPort.server-password"
    private static let authenticationReason = "访问 KeyPort 保存的服务器密码"

    private let itemAPI: any KeychainItemAPI
    // Security otherwise creates a one-shot context and prompts once per legacy item.
    private var authenticationContext: LAContext

    init(
        itemAPI: any KeychainItemAPI = SystemKeychainItemAPI(),
        authenticationContext: LAContext = LAContext()
    ) {
        self.itemAPI = itemAPI
        self.authenticationContext = authenticationContext
        self.authenticationContext.localizedReason = Self.authenticationReason
    }

    nonisolated static var synchronizableItemsAvailable: Bool {
        guard CodeSigningInfo.teamIdentifier != nil,
              let applicationIdentifier = CodeSigningInfo.entitlementValue("com.apple.application-identifier") as? String,
              let groups = CodeSigningInfo.entitlementValue("keychain-access-groups") as? [String] else {
            return false
        }
        return groups.contains(applicationIdentifier)
    }

    func saveServerPassword(_ password: String, serverID: UUID, synchronizable: Bool) throws {
        var passwordData = Data(password.utf8)
        defer { passwordData.resetBytes(in: passwordData.indices) }
        try saveServerPasswordData(passwordData, serverID: serverID, synchronizable: synchronizable)
    }

    func saveServerCredential(
        username: String,
        passwordData: Data,
        serverID: UUID,
        synchronizable: Bool?
    ) throws {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !passwordData.isEmpty else {
            throw KeychainError.invalidData
        }
        let targetStorage = synchronizable
            ?? serverPasswordStorage(serverID: serverID)?.isSynchronizable
            ?? false
        try saveServerPasswordData(
            passwordData,
            serverID: serverID,
            synchronizable: targetStorage,
            username: username
        )
    }

    func setServerPasswordSynchronizable(_ synchronizable: Bool, serverID: UUID) throws {
        guard let currentStorage = serverPasswordStorage(serverID: serverID) else {
            throw KeychainError.status(errSecItemNotFound)
        }
        guard currentStorage.isSynchronizable != synchronizable else { return }

        var credential = try serverCredential(serverID: serverID)
        defer { credential.passwordData.resetBytes(in: credential.passwordData.indices) }
        try saveServerPasswordData(
            credential.passwordData,
            serverID: serverID,
            synchronizable: synchronizable,
            username: credential.username.isEmpty ? nil : credential.username
        )
    }

    func serverPasswordStorage(serverID: UUID) -> ServerPasswordStorage? {
        if passwordItemExists(serverID: serverID, synchronizable: true) {
            return .synchronizable
        }
        if passwordItemExists(serverID: serverID, synchronizable: false) {
            return .local
        }
        return nil
    }

    func hasServerPassword(serverID: UUID) -> Bool {
        serverPasswordStorage(serverID: serverID) != nil
    }

    func hasServerCredential(serverID: UUID) -> Bool {
        hasServerPassword(serverID: serverID)
    }

    func serverPasswordData(serverID: UUID) throws -> Data {
        guard let storage = serverPasswordStorage(serverID: serverID) else {
            throw KeychainError.status(errSecItemNotFound)
        }
        return try passwordData(serverID: serverID, storage: storage)
    }

    func serverCredential(serverID: UUID) throws -> ServerCredential {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serverPasswordService,
            kSecAttrAccount: serverID.uuidString.lowercased(),
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecReturnAttributes: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: authenticationContext,
        ]
        var result: CFTypeRef?
        let status = itemAPI.copyMatching(query, result: &result)
        guard status == errSecSuccess else {
            resetAuthenticationContextIfNeeded(for: status)
            throw KeychainError.status(status)
        }
        guard let item = result as? [String: Any],
              let passwordData = item[kSecValueData as String] as? Data else {
            throw KeychainError.invalidData
        }
        let username: String
        if let usernameData = item[kSecAttrGeneric as String] as? Data {
            username = String(data: usernameData, encoding: .utf8) ?? ""
        } else if let storedUsername = item[kSecAttrGeneric as String] as? String {
            username = storedUsername
        } else {
            // Password-only entries from older versions remain readable and are
            // upgraded with a username the next time the credential is saved.
            username = ""
        }
        return ServerCredential(username: username, passwordData: passwordData)
    }

    func deleteServerCredential(serverID: UUID) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serverPasswordService,
            kSecAttrAccount: serverID.uuidString.lowercased(),
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecUseAuthenticationContext: authenticationContext,
        ]
        let status = itemAPI.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            resetAuthenticationContextIfNeeded(for: status)
            throw KeychainError.status(status)
        }
    }

    func deleteServerPassword(serverID: UUID) throws {
        try deleteServerCredential(serverID: serverID)
    }

    private func saveServerPasswordData(
        _ passwordData: Data,
        serverID: UUID,
        synchronizable: Bool,
        username: String? = nil
    ) throws {
        guard !synchronizable || Self.synchronizableItemsAvailable else {
            throw KeychainError.synchronizableUnavailable
        }
        let matchQuery = passwordQuery(serverID: serverID, synchronizable: synchronizable)
        var updateAttributes: [CFString: Any] = [
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: passwordData,
        ]
        if let username {
            updateAttributes[kSecAttrGeneric] = Data(username.utf8)
        }
        let updateStatus = itemAPI.update(matchQuery, attributes: updateAttributes)
        if updateStatus != errSecSuccess && updateStatus != errSecItemNotFound {
            throw mappedError(for: updateStatus, synchronizable: synchronizable)
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = matchQuery
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            addQuery[kSecValueData] = passwordData
            if let username {
                addQuery[kSecAttrGeneric] = Data(username.utf8)
            }
            let addStatus = itemAPI.add(addQuery, result: nil)
            guard addStatus == errSecSuccess else {
                throw mappedError(for: addStatus, synchronizable: synchronizable)
            }
        }

        let obsoleteQuery = passwordQuery(serverID: serverID, synchronizable: !synchronizable)
        let deleteStatus = itemAPI.delete(obsoleteQuery)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            resetAuthenticationContextIfNeeded(for: deleteStatus)
            throw KeychainError.status(deleteStatus)
        }
    }

    private func passwordItemExists(serverID: UUID, synchronizable: Bool) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serverPasswordService,
            kSecAttrAccount: serverID.uuidString.lowercased(),
            kSecAttrSynchronizable: synchronizable,
            kSecReturnData: false,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        return itemAPI.copyMatching(query, result: nil) == errSecSuccess
    }

    private func passwordData(serverID: UUID, storage: ServerPasswordStorage) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serverPasswordService,
            kSecAttrAccount: serverID.uuidString.lowercased(),
            kSecAttrSynchronizable: storage.isSynchronizable,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: authenticationContext,
        ]
        var result: CFTypeRef?
        let status = itemAPI.copyMatching(query, result: &result)
        guard status == errSecSuccess else {
            resetAuthenticationContextIfNeeded(for: status)
            throw KeychainError.status(status)
        }
        guard let data = result as? Data else { throw KeychainError.invalidData }
        return data
    }

    private func mappedError(for status: OSStatus, synchronizable: Bool) -> KeychainError {
        resetAuthenticationContextIfNeeded(for: status)
        guard synchronizable else { return .status(status) }
        switch status {
        case errSecMissingEntitlement:
            return .synchronizableUnavailable
        case errSecNotAvailable:
            return .iCloudKeychainUnavailable
        default:
            return .status(status)
        }
    }

    private func passwordQuery(serverID: UUID, synchronizable: Bool) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serverPasswordService,
            kSecAttrAccount: serverID.uuidString.lowercased(),
            kSecAttrSynchronizable: synchronizable,
            kSecUseAuthenticationContext: authenticationContext,
        ]
    }

    private func resetAuthenticationContextIfNeeded(for status: OSStatus) {
        guard status == errSecAuthFailed
                || status == errSecUserCanceled
                || status == errSecInteractionNotAllowed
                || status == errSecInvalidContext else { return }
        authenticationContext.invalidate()
        authenticationContext = LAContext()
        authenticationContext.localizedReason = Self.authenticationReason
    }
}
