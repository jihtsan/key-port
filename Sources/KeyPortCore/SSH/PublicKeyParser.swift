import CryptoKit
import Foundation

public struct ParsedPublicKey: Hashable, Sendable {
    public let type: String
    public let blob: String
    public let comment: String?
    public let fingerprint: String

    public var kind: SSHKeyKind {
        switch type {
        case "ssh-ed25519": .ed25519
        case "ssh-rsa": .rsa
        default: .other
        }
    }
}

public enum PublicKeyParser {
    private static let keyTypes = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "sk-ssh-ed25519@openssh.com"]

    public static func parse(_ line: String) -> ParsedPublicKey? {
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let typeIndex = fields.firstIndex(where: keyTypes.contains), fields.indices.contains(typeIndex + 1) else { return nil }
        let blob = fields[typeIndex + 1]
        guard let data = Data(base64Encoded: blob) else { return nil }
        let digest = SHA256.hash(data: data)
        let fingerprint = "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let commentStart = typeIndex + 2
        let comment = fields.indices.contains(commentStart) ? fields[commentStart...].joined(separator: " ") : nil
        return ParsedPublicKey(type: fields[typeIndex], blob: blob, comment: comment, fingerprint: fingerprint)
    }
}
