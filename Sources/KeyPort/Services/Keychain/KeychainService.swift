import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus)
    case invalidData
    case synchronizableUnavailable

    var errorDescription: String? {
        switch self {
        case .status(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        case .invalidData: return "Keychain returned invalid password data."
        case .synchronizableUnavailable:
            return "iCloud Keychain sync is unavailable in this build. Turn off sync to save the password in this Mac's Keychain."
        }
    }
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

    func saveServerPassword(_ password: String, serverID: UUID, synchronizable: Bool) throws {
        guard !synchronizable || Self.synchronizableItemsAvailable else {
            throw KeychainError.synchronizableUnavailable
        }
        let account = serverID.uuidString.lowercased()
        let matchQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serverPasswordService,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ]

        let updateAttributes: [CFString: Any] = [
            kSecAttrSynchronizable: synchronizable,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: Data(password.utf8),
        ]
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            if synchronizable, updateStatus == errSecMissingEntitlement {
                throw KeychainError.synchronizableUnavailable
            }
            throw KeychainError.status(updateStatus)
        }

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serverPasswordService,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: synchronizable,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: Data(password.utf8),
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if synchronizable, status == errSecMissingEntitlement {
            throw KeychainError.synchronizableUnavailable
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func hasServerPassword(serverID: UUID) -> Bool {
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

    func serverPasswordData(serverID: UUID) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serverPasswordService,
            kSecAttrAccount: serverID.uuidString.lowercased(),
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data else { throw KeychainError.invalidData }
        return data
    }

    func deleteServerPassword(serverID: UUID) throws {
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
