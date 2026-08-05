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
}

public enum DevicePresenceMerger {
    public static func merge(devices: [Device], tailscaleNodes: [TailscaleNode]) -> [DevicePresence] {
        var unmatchedNodes = tailscaleNodes.reduce(into: [String: TailscaleNode]()) { result, node in
            result[node.id] = node
        }
        let localNode = unmatchedNodes.values.first(where: \.isCurrent)
        var items = devices.map { device -> DevicePresence in
            let matchedNode = device.isCurrent ? localNode : nil
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
}
