import Foundation
import Darwin
import KeyPortCore

protocol TunnelControlMasterExiting: Sendable {
    func exit(controlPath: String) async -> Bool
}

protocol TunnelProcessLiveness: Sendable {
    func isAlive(pid: Int32) -> Bool
}

struct SystemTunnelProcessLiveness: TunnelProcessLiveness, Sendable {
    func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

enum TunnelLeaseStoreError: Error, Equatable, Sendable {
    case invalidRuntimeDirectory
    case invalidLease
    case controlMasterExitFailed
}

struct OpenSSHControlMasterExiter: TunnelControlMasterExiting, Sendable {
    private let runner: ProcessRunner

    init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    func exit(controlPath: String) async -> Bool {
        do {
            let result = try await runner.run(
                "/usr/bin/ssh",
                arguments: [
                    "-T",
                    "-S", controlPath,
                    "-O", "exit",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=1",
                    "127.0.0.1"
                ]
            )
            return result.succeeded
        } catch {
            return false
        }
    }
}

final class FileTunnelLeaseStore: TunnelLeaseStore, @unchecked Sendable {
    private let directory: URL
    private let controlMasterExit: any TunnelControlMasterExiting
    private let processLiveness: any TunnelProcessLiveness
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    init(
        directory: URL,
        controlMasterExit: any TunnelControlMasterExiting,
        processLiveness: any TunnelProcessLiveness = SystemTunnelProcessLiveness()
    ) {
        self.directory = directory.standardizedFileURL
        self.controlMasterExit = controlMasterExit
        self.processLiveness = processLiveness
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func save(_ lease: TunnelLease) async throws {
        try saveSynchronously(lease)
    }

    func remove(_ lease: TunnelLease) async throws {
        try removeSynchronously(lease)
    }

    func reap() async -> CleanupStatus {
        let leaseURLs: [URL]
        do {
            leaseURLs = try leaseURLsSynchronously()
        } catch {
            return .pending
        }

        var status: CleanupStatus = .notNeeded
        for url in leaseURLs {
            guard let lease = loadLease(at: url), isManagedLease(lease, at: url) else {
                status = .pending
                continue
            }
            let exited = await controlMasterExit.exit(controlPath: lease.controlPath)
            if exited, FileManager.default.fileExists(atPath: lease.controlPath) {
                do {
                    try FileManager.default.removeItem(atPath: lease.controlPath)
                } catch {
                    status = .pending
                    continue
                }
            }
            let controlSocketExists = FileManager.default.fileExists(atPath: lease.controlPath)
            let brokerAlive = lease.brokerPID.map(processLiveness.isAlive) ?? false
            guard exited || (!controlSocketExists && !brokerAlive) else {
                status = .pending
                continue
            }
            do {
                try removeLeaseFileSynchronously(at: url)
                status = .completed
            } catch {
                status = .pending
            }
        }
        return status
    }

    private func saveSynchronously(_ lease: TunnelLease) throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectory()
        guard isManagedLease(lease) else { throw TunnelLeaseStoreError.invalidLease }
        let url = leaseURL(for: lease.tunnelID)
        let data = try encoder.encode(lease)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        guard isSecureFile(at: url) else { throw TunnelLeaseStoreError.invalidRuntimeDirectory }
    }

    private func removeSynchronously(_ lease: TunnelLease) throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectory()
        guard isManagedLease(lease) else { throw TunnelLeaseStoreError.invalidLease }
        for url in leaseURLs(for: lease.tunnelID) {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func leaseURLsSynchronously() throws -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectory()
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { url in
            url.lastPathComponent.hasPrefix("lease-") && url.pathExtension == "json"
        }
    }

    private func removeLeaseFileSynchronously(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func isManagedLease(_ lease: TunnelLease, at leaseURL: URL? = nil) -> Bool {
        guard isSecureDirectory() else { return false }
        let runtimePath = directory.resolvingSymlinksInPath().path
        let controlURL = URL(fileURLWithPath: lease.controlPath).standardizedFileURL
        let resolvedControlPath = controlURL.resolvingSymlinksInPath().path
        let expectedPrefix = runtimePath.hasSuffix("/") ? runtimePath : "\(runtimePath)/"
        let expectedControlNames = [
            TunnelRuntimeNaming.controlName(for: lease.tunnelID),
            TunnelRuntimeNaming.legacyControlName(for: lease.tunnelID)
        ]
        let expectedLeaseURLs = leaseURLs(for: lease.tunnelID)
        let leaseMatches = leaseURL.map { candidate in
            expectedLeaseURLs.contains { $0.standardizedFileURL == candidate.standardizedFileURL }
        } ?? true
        return expectedControlNames.contains(controlURL.lastPathComponent)
            && resolvedControlPath == expectedPrefix + controlURL.lastPathComponent
            && lease.controlPath == controlURL.path
            && leaseMatches
            && (lease.brokerPID == nil || lease.brokerPID! > 0)
    }

    private func leaseURL(for tunnelID: UUID) -> URL {
        directory.appendingPathComponent(TunnelRuntimeNaming.leaseName(for: tunnelID))
    }

    private func leaseURLs(for tunnelID: UUID) -> [URL] {
        [
            leaseURL(for: tunnelID),
            directory.appendingPathComponent(TunnelRuntimeNaming.legacyLeaseName(for: tunnelID))
        ]
    }

    private func loadLease(at url: URL) -> TunnelLease? {
        guard isSecureFile(at: url) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(TunnelLease.self, from: data)
        } catch {
            return nil
        }
    }

    private func isSecureDirectory() -> Bool {
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else {
            return false
        }
        return (info.st_mode & 0o077) == 0
    }

    private func isSecureFile(at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid() else {
            return false
        }
        return (info.st_mode & 0o077) == 0
    }
}
