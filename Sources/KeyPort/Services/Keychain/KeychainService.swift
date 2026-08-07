import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus)
    case invalidData
    case synchronizableUnavailable

    var errorDescription: String? {
        switch self {
        case .status(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 错误 \(status)"
        case .invalidData: return "Keychain 返回了无效的密码数据。"
        case .synchronizableUnavailable:
            return "此版本无法使用 iCloud Keychain 同步。请关闭同步，将密码保存到此 Mac 的 Keychain。"
        }
    }
}

struct ServerCredential: Sendable {
    let username: String
    var passwordData: Data
}

actor KeychainService {
    static let serverPasswordService = "com.jihtsan.KeyPort.server-password"

    nonisolated static var synchronizableItemsAvailable: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String] else {
            return false
        }
        return !groups.isEmpty
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
        if synchronizable == true, !Self.synchronizableItemsAvailable {
            throw KeychainError.synchronizableUnavailable
        }
        let account = serverID.uuidString.lowercased()
        let matchQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serverPasswordService,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ]

        var updateAttributes: [CFString: Any] = [
            kSecAttrGeneric: Data(username.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: passwordData,
        ]
        if let synchronizable {
            updateAttributes[kSecAttrSynchronizable] = synchronizable
        }
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            if synchronizable == true, updateStatus == errSecMissingEntitlement {
                throw KeychainError.synchronizableUnavailable
            }
            throw KeychainError.status(updateStatus)
        }

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serverPasswordService,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: synchronizable ?? false,
            kSecAttrGeneric: Data(username.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: passwordData,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if synchronizable == true, status == errSecMissingEntitlement {
            throw KeychainError.synchronizableUnavailable
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func hasServerCredential(serverID: UUID) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serverPasswordService,
            kSecAttrAccount: serverID.uuidString.lowercased(),
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecReturnData: false,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
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
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
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
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
