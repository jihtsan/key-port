import Foundation

public struct AuthorizedKeyLine: Hashable, Sendable {
    public let rawLine: String
    public let key: ParsedPublicKey?

    public var isKeyPortManaged: Bool { key?.comment?.hasPrefix("keyport:v1:") == true }
}

public enum AuthorizedKeysParser {
    public static func parse(_ contents: String) -> [AuthorizedKeyLine] {
        contents.split(separator: "\n", omittingEmptySubsequences: false).map {
            let line = String($0)
            return AuthorizedKeyLine(rawLine: line, key: PublicKeyParser.parse(line))
        }
    }

    public static func containsFingerprint(_ fingerprint: String, in contents: String) -> Bool {
        parse(contents).contains { $0.key?.fingerprint == fingerprint }
    }

    public static func removingFingerprint(_ fingerprint: String, from contents: String) -> String {
        parse(contents)
            .filter { $0.key?.fingerprint != fingerprint }
            .map(\.rawLine)
            .joined(separator: "\n")
    }
}
