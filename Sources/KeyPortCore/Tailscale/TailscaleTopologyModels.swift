import Foundation

/// The stable Tailscale identity bound to one KeyPort Node.
///
/// `tailnetKey + tailscaleNodeID` is the external identity. The remaining
/// fields are last-known, non-secret metadata that can be synchronized through
/// the user's private CloudKit database.
public struct TailscaleNodeIdentity: Identifiable, Codable, Hashable, Sendable {
    public let keyPortNodeID: UUID
    public let tailnetKey: String
    public let tailscaleNodeID: String
    public var displayName: String
    public var hostName: String?
    public var magicDNS: String?
    public var addresses: [String]
    public var operatingSystem: String?
    public var isExitNode: Bool
    public var isExitNodeOption: Bool
    public var updatedAt: Date
    public var isDeleted: Bool

    public var id: String {
        Self.identityID(tailnetKey: tailnetKey, tailscaleNodeID: tailscaleNodeID)
    }

    public init?(
        keyPortNodeID: UUID,
        tailnetKey: String,
        tailscaleNodeID: String,
        displayName: String,
        hostName: String? = nil,
        magicDNS: String? = nil,
        addresses: [String] = [],
        operatingSystem: String? = nil,
        isExitNode: Bool = false,
        isExitNodeOption: Bool = false,
        updatedAt: Date = .now,
        isDeleted: Bool = false
    ) {
        let normalizedTailnetKey = Self.normalizeTailnetKey(tailnetKey)
        let normalizedNodeID = tailscaleNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTailnetKey.isEmpty, !normalizedNodeID.isEmpty else { return nil }

        self.keyPortNodeID = keyPortNodeID
        self.tailnetKey = normalizedTailnetKey
        self.tailscaleNodeID = normalizedNodeID
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hostName = Self.nonEmpty(hostName)
        self.magicDNS = Self.cleanDNS(magicDNS)
        self.addresses = Self.uniqueNonEmpty(addresses)
        self.operatingSystem = Self.nonEmpty(operatingSystem)
        self.isExitNode = isExitNode
        self.isExitNodeOption = isExitNodeOption
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }

    public static func identityID(tailnetKey: String, tailscaleNodeID: String) -> String {
        "tailscale:\(normalizeTailnetKey(tailnetKey)):\(tailscaleNodeID.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    public static func normalizeTailnetKey(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }

    public func matches(_ node: TailscaleNode, tailnetKey: String) -> Bool {
        self.tailnetKey == Self.normalizeTailnetKey(tailnetKey)
            && tailscaleNodeID == node.stableNodeID
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cleanDNS(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let cleaned = nonEmpty(value) else { return nil }
            let key = TailscaleHostIdentity.normalize(cleaned)
            guard seen.insert(key).inserted else { return nil }
            return cleaned
        }
    }
}

/// A local observation of one Tailscale identity.
///
/// Observations are intentionally scoped to the observing Mac and are not
/// CloudKit facts. They expire as the local Tailscale snapshot becomes stale.
public struct TailscaleNodeObservation: Identifiable, Codable, Hashable, Sendable {
    public static let defaultFreshnessInterval: TimeInterval = 90

    public let tailnetKey: String
    public let tailscaleNodeID: String
    public let observerDeviceID: String
    public let backendState: String
    public let observedAt: Date
    public let isOnline: Bool
    public let lastSeenAt: Date?
    public let relay: String?

    public var identityID: String {
        TailscaleNodeIdentity.identityID(
            tailnetKey: tailnetKey,
            tailscaleNodeID: tailscaleNodeID
        )
    }

    public var id: String { "\(observerDeviceID):\(identityID)" }

    public func isFresh(
        at date: Date = .now,
        maximumAge: TimeInterval = Self.defaultFreshnessInterval
    ) -> Bool {
        let age = date.timeIntervalSince(observedAt)
        return age >= 0 && age <= maximumAge
    }

    public init?(
        tailnetKey: String,
        tailscaleNodeID: String,
        observerDeviceID: String,
        backendState: String,
        observedAt: Date,
        isOnline: Bool,
        lastSeenAt: Date? = nil,
        relay: String? = nil
    ) {
        let normalizedTailnetKey = TailscaleNodeIdentity.normalizeTailnetKey(tailnetKey)
        let normalizedNodeID = tailscaleNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedObserver = observerDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTailnetKey.isEmpty, !normalizedNodeID.isEmpty, !normalizedObserver.isEmpty else {
            return nil
        }

        self.tailnetKey = normalizedTailnetKey
        self.tailscaleNodeID = normalizedNodeID
        self.observerDeviceID = normalizedObserver
        self.backendState = backendState
        self.observedAt = observedAt
        self.isOnline = isOnline
        self.lastSeenAt = lastSeenAt
        self.relay = relay?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
