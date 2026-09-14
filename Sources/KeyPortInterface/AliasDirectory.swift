import Foundation

/// An injected snapshot, never a reader of ~/.ssh/config. Integration must refresh and
/// reserve aliases atomically when persisting; this preview has no persistence boundary.
public struct AliasDirectory {
    public enum Source: Equatable { case managed, sshConfiguration }
    public struct Entry: Equatable {
        public let alias: String
        public let source: Source
        /// Stable managed-entry identity, also shared by its projected SSH configuration.
        public let ownerID: String?
        public init(alias: String, source: Source, ownerID: String? = nil) {
            self.alias = alias; self.source = source; self.ownerID = ownerID
        }
    }
    public let entries: [Entry]
    public init(entries: [Entry] = []) { self.entries = entries }

    public static func isValidNewAlias(_ alias: String) -> Bool {
        guard let first = alias.first, first.isASCII, first.isLetter else { return false }
        return alias.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public func validationMessage(for alias: String, editingEntryID: String? = nil) -> String? {
        if alias.isEmpty || alias.allSatisfy({ $0.isWhitespace }) { return "请输入 SSH 别名。" }
        // Preserve exact stored legacy names only for their actual owner. A case change
        // counts as editing the alias and is subject to new-product syntax rules.
        let retained = editingEntryID.map { id in
            entries.contains { $0.ownerID == id && $0.source == .managed && $0.alias == alias }
        } ?? false
        if !retained && !Self.isValidNewAlias(alias) {
            return "别名仅支持英文字母、数字、- 和 _，并以字母开头。中文说明请填在描述中。"
        }
        // ASCII case-insensitive collision check; do not trim, slug, or rewrite input.
        if let conflict = entries.first(where: {
            $0.alias.lowercased() == alias.lowercased()
                && !(editingEntryID != nil && $0.ownerID == editingEntryID)
        }) {
            return conflict.source == .sshConfiguration
                ? "此别名已用于现有 SSH 配置。请换一个，例如 home-router-2。"
                : "此别名已用于已管理服务器。请换一个别名。"
        }
        return nil
    }
}

/// Isolated compatibility projection. It does not validate all legal OpenSSH Host
/// patterns and never changes a stored alias to satisfy the new-product rule.
public struct ServerNaming: Equatable, Identifiable {
    public let id: String
    public var alias: String
    public var description: String
    public init(id: String, alias: String, description: String = "") {
        self.id = id; self.alias = alias; self.description = description
    }
    public static func legacy(id: String, displayName: String, existingAlias: String) -> Self {
        Self(id: id, alias: existingAlias, description: displayName)
    }
    public var visibleDescription: String? {
        description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description
    }
    public func matches(_ query: String) -> Bool {
        query.isEmpty || alias.localizedCaseInsensitiveContains(query) || description.localizedCaseInsensitiveContains(query)
    }
}
