import Foundation
import KeyPortCore

actor SSHKeyService {
    private let runner: ProcessRunner
    private let paths: KeyPortPaths

    init(runner: ProcessRunner, paths: KeyPortPaths = KeyPortPaths()) {
        self.runner = runner
        self.paths = paths
    }

    func scan(deviceID: String) async throws -> [SSHKeyRecord] {
        try paths.prepareDirectories()
        var candidates: [(line: String, privatePath: String?, origin: SSHKeyOrigin)] = []
        let manager = FileManager.default
        let discoveredURLs: [URL] = {
            guard let enumerator = manager.enumerator(at: paths.sshDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            return enumerator.compactMap { $0 as? URL }
        }()
        for url in discoveredURLs where url.pathExtension == "pub" {
                guard url.pathComponents.count - paths.sshDirectory.pathComponents.count <= 3,
                      let line = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                      PublicKeyParser.parse(line) != nil else { continue }
                let privateURL = url.deletingPathExtension()
                candidates.append((line, manager.fileExists(atPath: privateURL.path) ? privateURL.path : nil, .scanned))
        }

        let agent = try? await runner.run("/usr/bin/ssh-add", arguments: ["-L"])
        if let agent, agent.succeeded {
            candidates += agent.stdout.split(separator: "\n").map { (String($0), nil, .agent) }
        }

        var byFingerprint: [String: SSHKeyRecord] = [:]
        for candidate in candidates {
            guard let parsed = PublicKeyParser.parse(candidate.line) else { continue }
            let commentID = parsed.comment?.split(separator: ":").dropFirst(2).first.map(String.init)
            let id = commentID?.hasPrefix("key_") == true ? commentID! : KeyPortNaming.newKeyID()
            let record = SSHKeyRecord(
                id: id,
                deviceID: deviceID,
                kind: parsed.kind,
                publicKey: candidate.line,
                fingerprint: parsed.fingerprint,
                privateKeyPath: candidate.privatePath,
                isInAgent: candidate.origin == .agent,
                origin: candidate.origin,
                isLocallyAvailable: candidate.privatePath != nil || candidate.origin == .agent
            )
            if let existing = byFingerprint[parsed.fingerprint] {
                byFingerprint[parsed.fingerprint] = merge(existing, record)
            } else {
                byFingerprint[parsed.fingerprint] = record
            }
        }
        return byFingerprint.values.sorted { $0.id < $1.id }
    }

    func generate(device: Device) async throws -> SSHKeyRecord {
        try paths.prepareDirectories()
        let keyID = KeyPortNaming.newKeyID()
        let path = paths.identitiesDirectory.appendingPathComponent(keyID)
        let comment = "keyport:v1:\(keyID):\(KeyPortNaming.deviceIdentifier(name: device.name))"
        let result = try await runner.run("/usr/bin/ssh-keygen", arguments: ["-q", "-t", "ed25519", "-f", path.path, "-N", "", "-C", comment])
        guard result.succeeded else { throw SSHServiceError.operationFailed("Key generation failed.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let publicLine = try String(contentsOf: path.appendingPathExtension("pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = PublicKeyParser.parse(publicLine) else { throw SSHServiceError.operationFailed("Generated public key is invalid.") }
        return SSHKeyRecord(id: keyID, deviceID: device.id, kind: .ed25519, publicKey: publicLine, fingerprint: parsed.fingerprint, privateKeyPath: path.path, isInAgent: false, origin: .generated, isLocallyAvailable: true)
    }

    func addToAgent(_ key: SSHKeyRecord) async throws {
        guard let path = key.privateKeyPath else { throw SSHServiceError.operationFailed("This key has no local private file.") }
        let result = try await runner.run("/usr/bin/ssh-add", arguments: [path])
        guard result.succeeded else { throw SSHServiceError.operationFailed("ssh-agent rejected the key.") }
    }

    func importPrivateKey(from source: URL, device: Device) async throws -> SSHKeyRecord {
        try paths.prepareDirectories()
        let adjacentPublic = source.appendingPathExtension("pub")
        guard FileManager.default.fileExists(atPath: adjacentPublic.path) else {
            throw SSHServiceError.operationFailed("Select a private key that has a matching .pub file. Encrypted keys without a public companion are not imported automatically.")
        }
        let sourcePublic = try String(contentsOf: adjacentPublic, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = PublicKeyParser.parse(sourcePublic), parsed.kind == .ed25519 || parsed.kind == .rsa else {
            throw SSHServiceError.operationFailed("Only OpenSSH Ed25519 and RSA keys are supported in this release.")
        }
        let keyID = KeyPortNaming.newKeyID()
        let destination = paths.identitiesDirectory.appendingPathComponent(keyID)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SSHServiceError.operationFailed("The destination key already exists.")
        }
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let comment = "keyport:v1:\(keyID):\(KeyPortNaming.deviceIdentifier(name: device.name))"
            let normalizedPublic = "\(parsed.type) \(parsed.blob) \(comment)"
            try Data((normalizedPublic + "\n").utf8).write(to: destination.appendingPathExtension("pub"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.appendingPathExtension("pub").path)
            return SSHKeyRecord(id: keyID, deviceID: device.id, kind: parsed.kind, publicKey: normalizedPublic, fingerprint: parsed.fingerprint, privateKeyPath: destination.path, isInAgent: false, origin: .imported, isLocallyAvailable: true)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func merge(_ lhs: SSHKeyRecord, _ rhs: SSHKeyRecord) -> SSHKeyRecord {
        var merged = lhs
        merged.privateKeyPath = lhs.privateKeyPath ?? rhs.privateKeyPath
        merged.isInAgent = lhs.isInAgent || rhs.isInAgent
        merged.isLocallyAvailable = merged.privateKeyPath != nil || merged.isInAgent
        return merged
    }
}
