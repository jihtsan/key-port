import Foundation
import LocalAuthentication
import Security
@testable import KeyPort
import XCTest

final class KeychainServiceTests: XCTestCase {
    func testLocalCredentialSaveSurvivesUnavailableSynchronizableCleanup() async throws {
        let itemAPI = KeychainItemAPISpy(
            updateStatus: errSecItemNotFound,
            addStatus: errSecSuccess,
            deleteStatus: errSecMissingEntitlement
        )
        let service = KeychainService(
            itemAPI: itemAPI,
            authenticationContext: LAContext()
        )

        try await service.saveServerCredential(
            username: "fixture-user",
            passwordData: Data("fixture-password".utf8),
            serverID: UUID(),
            synchronizable: false
        )

        XCTAssertEqual(itemAPI.addCallCount(), 1)
        XCTAssertEqual(itemAPI.deleteCallCount(), 1)
    }

    func testPasswordReadsReuseOneAuthenticationContext() async throws {
        let itemAPI = KeychainItemAPISpy()
        let authenticationContext = LAContext()
        let service = KeychainService(
            itemAPI: itemAPI,
            authenticationContext: authenticationContext
        )

        _ = try await service.serverPasswordData(serverID: UUID())
        _ = try await service.serverPasswordData(serverID: UUID())

        let contexts = itemAPI.capturedAuthenticationContexts()
        XCTAssertEqual(contexts.count, 2)
        XCTAssertTrue(contexts.allSatisfy { $0 === authenticationContext })
    }

    func testCanceledAuthenticationUsesFreshContextOnNextRead() async throws {
        let itemAPI = KeychainItemAPISpy(dataStatuses: [errSecUserCanceled, errSecSuccess])
        let initialContext = LAContext()
        let service = KeychainService(
            itemAPI: itemAPI,
            authenticationContext: initialContext
        )

        do {
            _ = try await service.serverPasswordData(serverID: UUID())
            XCTFail("A canceled Keychain authentication unexpectedly succeeded")
        } catch {
            // The next attempt should use a newly-created context.
        }
        _ = try await service.serverPasswordData(serverID: UUID())

        let contexts = itemAPI.capturedAuthenticationContexts()
        XCTAssertEqual(contexts.count, 2)
        XCTAssertTrue(contexts[0] === initialContext)
        XCTAssertFalse(contexts[1] === initialContext)
    }
}

private final class KeychainItemAPISpy: KeychainItemAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var authenticationContexts: [LAContext?] = []
    private var dataStatuses: [OSStatus]
    private let updateStatus: OSStatus
    private let addStatus: OSStatus
    private let deleteStatus: OSStatus
    private var addCalls = 0
    private var deleteCalls = 0

    init(
        dataStatuses: [OSStatus] = [],
        updateStatus: OSStatus = errSecUnimplemented,
        addStatus: OSStatus = errSecUnimplemented,
        deleteStatus: OSStatus = errSecUnimplemented
    ) {
        self.dataStatuses = dataStatuses
        self.updateStatus = updateStatus
        self.addStatus = addStatus
        self.deleteStatus = deleteStatus
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        updateStatus
    }

    func add(_ attributes: [CFString: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.lock()
        addCalls += 1
        lock.unlock()
        return addStatus
    }

    func copyMatching(_ query: [CFString: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        if query[kSecReturnData] as? Bool == true {
            lock.lock()
            authenticationContexts.append(query[kSecUseAuthenticationContext] as? LAContext)
            let status = dataStatuses.isEmpty ? errSecSuccess : dataStatuses.removeFirst()
            lock.unlock()
            guard status == errSecSuccess else { return status }
            result?.pointee = Data("fixture-password".utf8) as CFData
            return errSecSuccess
        }

        return query[kSecAttrSynchronizable] as? Bool == true
            ? errSecItemNotFound
            : errSecSuccess
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        lock.lock()
        deleteCalls += 1
        lock.unlock()
        return deleteStatus
    }

    func capturedAuthenticationContexts() -> [LAContext?] {
        lock.lock()
        defer { lock.unlock() }
        return authenticationContexts
    }

    func addCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return addCalls
    }

    func deleteCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return deleteCalls
    }
}
