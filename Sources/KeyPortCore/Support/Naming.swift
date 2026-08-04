import Foundation

public enum KeyPortNaming {
    public static func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let mapped = folded.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        return String(mapped)
            .split(separator: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    public static func alias(group: String, name: String) -> String {
        let pieces = [slug(group), slug(name)].filter { !$0.isEmpty }
        return pieces.joined(separator: "-")
    }

    public static func isValidAlias(_ alias: String) -> Bool {
        alias.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    public static func deviceIdentifier(name: String) -> String {
        let value = slug(name)
        return value.isEmpty ? "mac" : value
    }

    public static func newDeviceID() -> String { "dev_" + shortID() }
    public static func newKeyID() -> String { "key_" + shortID() }

    private static func shortID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }
}
