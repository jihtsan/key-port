import Foundation

public struct DevicePresence: Identifiable, Hashable, Sendable {
    public enum ID: Hashable, Sendable {
        case keyPort(String)
        case tailscale(String)
    }

    public let id: ID
    public let registeredDevice: Device?
    public let tailscaleNode: TailscaleNode?

    public init(id: ID, registeredDevice: Device?, tailscaleNode: TailscaleNode?) {
        self.id = id
        self.registeredDevice = registeredDevice
        self.tailscaleNode = tailscaleNode
    }

    public var name: String { registeredDevice?.name ?? tailscaleNode?.name ?? "未知设备" }
    public var isCurrent: Bool { registeredDevice?.isCurrent == true || tailscaleNode?.isCurrent == true }
    public var isRevoked: Bool { registeredDevice?.isRevoked == true }

    public func matches(host: String) -> Bool {
        tailscaleNode?.matches(host: host) == true
            || registeredDevice?.tailscaleIdentity?.matches(host: host) == true
    }
}

public enum DevicePresenceMerger {
    public static func merge(devices: [Device], tailscaleNodes: [TailscaleNode]) -> [DevicePresence] {
        var unmatchedNodes = tailscaleNodes.reduce(into: [String: TailscaleNode]()) { result, node in
            result[node.id] = node
        }
        let localNode = unmatchedNodes.values.first(where: \.isCurrent)
        let localDeviceNames = Set(devices.lazy.filter(\.isCurrent).map { normalizedName($0.name) }.filter { !$0.isEmpty })
        // A regenerated local device ID can leave a same-machine CloudKit registration behind.
        let visibleDevices = devices.filter { device in
            device.isCurrent || !localDeviceNames.contains(normalizedName(device.name))
        }
        var items = visibleDevices.map { device -> DevicePresence in
            let matchedNode: TailscaleNode?
            if device.isCurrent {
                matchedNode = localNode
            } else if let identity = device.tailscaleIdentity {
                matchedNode = unmatchedNodes[identity.nodeID]
                    ?? unmatchedNodes.values.first(where: { identity.matches(node: $0) })
            } else {
                matchedNode = nil
            }
            if let matchedNode { unmatchedNodes.removeValue(forKey: matchedNode.id) }
            return DevicePresence(id: .keyPort(device.id), registeredDevice: device, tailscaleNode: matchedNode)
        }
        items.append(contentsOf: unmatchedNodes.values.map { node in
            DevicePresence(id: .tailscale(node.id), registeredDevice: nil, tailscaleNode: node)
        })
        return items.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return comparison == .orderedSame ? String(describing: lhs.id) < String(describing: rhs.id) : comparison == .orderedAscending
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
