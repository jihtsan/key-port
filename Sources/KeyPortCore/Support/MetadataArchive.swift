import CryptoKit
import Foundation

public struct KeyPortArchiveContainer: Codable, Sendable {
    public let format: String
    public let version: Int
    public let kdf: String
    public let iterations: Int
    public let salt: Data
    public let sealedPayload: Data
}

/// The encrypted archive payload. `topology` is optional so archives created
/// before the unified topology existed remain readable as AppSnapshot-only
/// archives.
public struct MetadataArchivePayload: Codable, Sendable {
    public let snapshot: AppSnapshot
    public let topology: TopologySnapshot?

    public init(snapshot: AppSnapshot, topology: TopologySnapshot? = nil) {
        self.snapshot = snapshot
        self.topology = topology
    }
}

public enum MetadataArchiveError: LocalizedError {
    case passwordRequired
    case invalidContainer
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .passwordRequired: "请输入加密归档的恢复密码。"
        case .invalidContainer: "这不是受支持的 KeyPort 归档。"
        case .authenticationFailed: "归档密码不正确，或文件已被修改。"
        }
    }
}

public enum MetadataArchiveCodec {
    public static func seal(_ snapshot: AppSnapshot, password: String, iterations: Int = 210_000) throws -> Data {
        try seal(
            payload: MetadataArchivePayload(snapshot: sanitizedSnapshot(snapshot)),
            password: password,
            iterations: iterations,
            version: 1
        )
    }

    /// Seals both compatibility metadata and the unified topology. The
    /// topology is sanitized with the same local-state boundary as CloudKit;
    /// route policy and ordered candidates remain, while local key paths,
    /// observations and audit history do not leave this Mac.
    public static func seal(
        _ snapshot: AppSnapshot,
        topology: TopologySnapshot,
        password: String,
        iterations: Int = 210_000
    ) throws -> Data {
        try seal(
            payload: MetadataArchivePayload(
                snapshot: sanitizedSnapshot(snapshot),
                topology: TopologyCloudMetadataSnapshotPolicy.sanitized(topology)
            ),
            password: password,
            iterations: iterations,
            version: 2
        )
    }

    public static func open(_ data: Data, password: String) throws -> AppSnapshot {
        try openPayload(data, password: password).snapshot
    }

    public static func openPayload(_ data: Data, password: String) throws -> MetadataArchivePayload {
        guard !password.isEmpty else { throw MetadataArchiveError.passwordRequired }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let container = try? decoder.decode(KeyPortArchiveContainer.self, from: data),
              container.format == "keyport",
              [1, 2].contains(container.version),
              container.kdf == "pbkdf2-hmac-sha256",
              container.iterations >= 1_000,
              container.iterations <= 1_000_000,
              container.salt.count == 16 else {
            throw MetadataArchiveError.invalidContainer
        }
        let payloadData = try decrypt(container: container, password: password)
        do {
            if container.version == 1 {
                return MetadataArchivePayload(
                    snapshot: try decoder.decode(AppSnapshot.self, from: payloadData)
                )
            }
            return try decoder.decode(MetadataArchivePayload.self, from: payloadData)
        } catch {
            throw MetadataArchiveError.authenticationFailed
        }
    }

    private static func seal(
        payload: MetadataArchivePayload,
        password: String,
        iterations: Int,
        version: Int
    ) throws -> Data {
        guard !password.isEmpty else { throw MetadataArchiveError.passwordRequired }

        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let keyData = pbkdf2(password: Data(password.utf8), salt: salt, iterations: iterations, keyLength: 32)
        let key = SymmetricKey(data: keyData)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedPayload: Data
        if version == 1 {
            encodedPayload = try encoder.encode(payload.snapshot)
        } else {
            encodedPayload = try encoder.encode(payload)
        }
        let sealed = try AES.GCM.seal(encodedPayload, using: key)
        guard let combined = sealed.combined else { throw MetadataArchiveError.invalidContainer }
        let container = KeyPortArchiveContainer(
            format: "keyport",
            version: version,
            kdf: "pbkdf2-hmac-sha256",
            iterations: iterations,
            salt: salt,
            sealedPayload: combined
        )
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(container)
    }

    private static func decrypt(container: KeyPortArchiveContainer, password: String) throws -> Data {
        let keyData = pbkdf2(password: Data(password.utf8), salt: container.salt, iterations: container.iterations, keyLength: 32)
        do {
            let box = try AES.GCM.SealedBox(combined: container.sealedPayload)
            return try AES.GCM.open(box, using: SymmetricKey(data: keyData))
        } catch {
            throw MetadataArchiveError.authenticationFailed
        }
    }

    private static func sanitizedSnapshot(_ snapshot: AppSnapshot) -> AppSnapshot {
        var sanitized = snapshot
        sanitized.keys = sanitized.keys.map { key in
            var copy = key
            copy.privateKeyPath = nil
            copy.isInAgent = false
            copy.isLocallyAvailable = false
            return copy
        }
        sanitized.devices = sanitized.devices.map { device in
            var copy = device
            copy.isCurrent = false
            return copy
        }
        sanitized.auditEvents = []
        return sanitized
    }

    private static func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let passwordKey = SymmetricKey(data: password)
        let hashLength = 32
        let blockCount = Int(ceil(Double(keyLength) / Double(hashLength)))
        var output = Data()
        for block in 1...blockCount {
            var bigEndianBlock = UInt32(block).bigEndian
            var input = salt
            withUnsafeBytes(of: &bigEndianBlock) { input.append(contentsOf: $0) }
            var u = Data(HMAC<SHA256>.authenticationCode(for: input, using: passwordKey))
            var accumulator = u
            if iterations > 1 {
                for _ in 2...iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: passwordKey))
                    for index in accumulator.indices { accumulator[index] ^= u[index] }
                }
            }
            output.append(accumulator)
        }
        return output.prefix(keyLength)
    }
}
