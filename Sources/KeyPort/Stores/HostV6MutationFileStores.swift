import Darwin
import Foundation
import KeyPortCore

actor HostV6MutationJournalFileStore: HostV6MutationWorkflowJournalStoring {
    private let paths: KeyPortPaths
    private let fileManager: FileManager

    init(paths: KeyPortPaths = KeyPortPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() throws -> HostV6MutationJournal? {
        guard fileManager.fileExists(atPath: paths.v6MutationJournal.path) else { return nil }
        do {
            let journal = try HostV6.CanonicalJSON.decode(
                HostV6MutationJournal.self,
                from: Data(contentsOf: paths.v6MutationJournal)
            )
            try journal.validate()
            return journal
        } catch let error as HostV6.CloudV2Error {
            throw error
        } catch {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }
    }

    func save(_ journal: HostV6MutationJournal) throws {
        try journal.validate()
        try HostV6SecureFileStore.atomicReplace(
            HostV6.CanonicalJSON.encode(journal),
            at: paths.v6MutationJournal,
            fileManager: fileManager
        )
    }

    func remove() throws {
        guard fileManager.fileExists(atPath: paths.v6MutationJournal.path) else { return }
        try fileManager.removeItem(at: paths.v6MutationJournal)
        try HostV6SecureFileStore.syncDirectory(paths.applicationSupport)
    }
}
actor HostV6CommandLedgerFileStore: HostV6MutationJournalStoring {
    private struct StoredLedger: Codable, Sendable {
        let ledger: HostV6.CommandLedger
        let hash: String
    }

    private let paths: KeyPortPaths
    private let fileManager: FileManager

    init(paths: KeyPortPaths = KeyPortPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadLedger() throws -> HostV6.CommandLedger {
        guard fileManager.fileExists(atPath: paths.v6CommandLedger.path) else { return .empty }
        do {
            let stored = try HostV6.CanonicalJSON.decode(
                StoredLedger.self,
                from: Data(contentsOf: paths.v6CommandLedger)
            )
            let data = try HostV6.CanonicalJSON.encode(stored.ledger)
            guard HostV6.CanonicalJSON.sha256(data) == stored.hash else {
                throw HostV6.CloudV2Error.failure(.artifactMismatch)
            }
            return stored.ledger
        } catch let error as HostV6.CloudV2Error {
            throw error
        } catch {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }
    }

    func atomicReplaceLedger(_ ledger: HostV6.CommandLedger) throws {
        let data = try HostV6.CanonicalJSON.encode(ledger)
        let stored = StoredLedger(ledger: ledger, hash: HostV6.CanonicalJSON.sha256(data))
        try HostV6SecureFileStore.atomicReplace(
            HostV6.CanonicalJSON.encode(stored),
            at: paths.v6CommandLedger,
            fileManager: fileManager
        )
    }
}

private enum HostV6SecureFileStore {
    static func atomicReplace(_ data: Data, at destination: URL, fileManager: FileManager) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent)-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try syncDirectory(directory)
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }
    }
}
