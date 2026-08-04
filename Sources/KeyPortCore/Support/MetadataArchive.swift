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

public enum MetadataArchiveError: LocalizedError {
    case passwordRequired
    case invalidContainer
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .passwordRequired: "Enter a recovery password for the encrypted archive."
        case .invalidContainer: "This is not a supported KeyPort archive."
        case .authenticationFailed: "The archive password is incorrect or the file was modified."
        }
    }
}

public enum MetadataArchiveCodec {
    public static func seal(_ snapshot: AppSnapshot, password: String, iterations: Int = 210_000) throws -> Data {
        guard !password.isEmpty else { throw MetadataArchiveError.passwordRequired }
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

        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let keyData = pbkdf2(password: Data(password.utf8), salt: salt, iterations: iterations, keyLength: 32)
        let key = SymmetricKey(data: keyData)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(sanitized)
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else { throw MetadataArchiveError.invalidContainer }
        let container = KeyPortArchiveContainer(format: "keyport", version: 1, kdf: "pbkdf2-hmac-sha256", iterations: iterations, salt: salt, sealedPayload: combined)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(container)
    }

    public static func open(_ data: Data, password: String) throws -> AppSnapshot {
        guard !password.isEmpty else { throw MetadataArchiveError.passwordRequired }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let container = try? decoder.decode(KeyPortArchiveContainer.self, from: data),
              container.format == "keyport",
              container.version == 1,
              container.kdf == "pbkdf2-hmac-sha256",
              container.iterations >= 1_000,
              container.iterations <= 1_000_000,
              container.salt.count == 16 else {
            throw MetadataArchiveError.invalidContainer
        }
        let keyData = pbkdf2(password: Data(password.utf8), salt: container.salt, iterations: container.iterations, keyLength: 32)
        do {
            let box = try AES.GCM.SealedBox(combined: container.sealedPayload)
            let payload = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
            return try decoder.decode(AppSnapshot.self, from: payload)
        } catch {
            throw MetadataArchiveError.authenticationFailed
        }
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
