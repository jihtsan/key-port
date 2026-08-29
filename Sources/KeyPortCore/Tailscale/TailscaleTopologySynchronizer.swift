import Foundation

/// Projects a local Tailscale status snapshot into the unified topology.
///
/// The identity records are portable metadata. The observation records are
/// local to the Mac that produced them and are deliberately kept separate so
/// one Mac cannot overwrite another Mac's live status.
public enum TailscaleTopologySynchronizer {
    public static func apply(
        status: TailscaleStatus,
        to topology: TopologySnapshot,
        observerDeviceID: String,
        observedAt: Date? = nil
    ) -> TopologySnapshot {
        guard let tailnetKey = status.tailnetKey,
              !observerDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return topology
        }

        let observedAt = observedAt ?? status.observedAt
        var result = topology
        let currentNodeID = result.profiles.first(where: { $0.id == observerDeviceID })?.nodeID
            ?? TopologyStableID.node(forDeviceID: observerDeviceID)
        let previousIdentities = result.activeTailscaleNodes

        for tailscaleNode in status.nodes {
            guard let tailscaleNodeID = tailscaleNode.stableNodeID else {
                continue
            }

            let identityID = TailscaleNodeIdentity.identityID(
                tailnetKey: tailnetKey,
                tailscaleNodeID: tailscaleNodeID
            )
            let previousIdentity = previousIdentities.first { $0.id == identityID }
            let keyPortNodeID = previousIdentity?.keyPortNodeID
                ?? (tailscaleNode.isCurrent
                    ? currentNodeID
                    : matchingNodeID(
                        for: tailscaleNode,
                        topology: result,
                        excluding: currentNodeID
                    ))
                ?? TopologyStableID.node(
                    forTailscale: tailnetKey,
                    nodeID: tailscaleNodeID
                )

            guard let identity = TailscaleNodeIdentity(
                keyPortNodeID: keyPortNodeID,
                tailnetKey: tailnetKey,
                tailscaleNodeID: tailscaleNodeID,
                displayName: tailscaleNode.name,
                hostName: tailscaleNode.hostName,
                magicDNS: tailscaleNode.dnsName,
                addresses: tailscaleNode.addresses,
                operatingSystem: tailscaleNode.operatingSystem,
                isExitNode: tailscaleNode.isExitNode,
                isExitNodeOption: tailscaleNode.isExitNodeOption,
                updatedAt: observedAt
            ) else {
                continue
            }

            let updatedIdentity = TailscaleNodeIdentity(
                keyPortNodeID: identity.keyPortNodeID,
                tailnetKey: identity.tailnetKey,
                tailscaleNodeID: identity.tailscaleNodeID,
                displayName: identity.displayName,
                hostName: identity.hostName,
                magicDNS: identity.magicDNS,
                addresses: identity.addresses,
                operatingSystem: identity.operatingSystem,
                isExitNode: identity.isExitNode,
                isExitNodeOption: identity.isExitNodeOption,
                updatedAt: metadataChanged(previousIdentity, identity)
                    ? observedAt
                    : previousIdentity?.updatedAt ?? observedAt,
                isDeleted: false
            ) ?? identity

            if let index = result.tailscaleNodes.firstIndex(where: { $0.id == updatedIdentity.id }) {
                result.tailscaleNodes[index] = updatedIdentity
            } else {
                result.tailscaleNodes.append(updatedIdentity)
            }
            upsertNode(
                for: updatedIdentity,
                tailscaleNode: tailscaleNode,
                previousIdentity: previousIdentity,
                in: &result,
                observedAt: observedAt
            )

            guard let observation = TailscaleNodeObservation(
                tailnetKey: tailnetKey,
                tailscaleNodeID: tailscaleNodeID,
                observerDeviceID: observerDeviceID,
                backendState: status.backendState,
                observedAt: observedAt,
                isOnline: tailscaleNode.isOnline,
                lastSeenAt: tailscaleNode.lastSeen,
                relay: tailscaleNode.relay
            ) else {
                continue
            }
            if let index = result.tailscaleObservations.firstIndex(where: { $0.id == observation.id }) {
                result.tailscaleObservations[index] = observation
            } else {
                result.tailscaleObservations.append(observation)
            }
        }

        result.tailscaleNodes.sort { $0.id < $1.id }
        result.tailscaleObservations.sort { $0.id < $1.id }
        return result
    }

    private static func matchingNodeID(
        for tailscaleNode: TailscaleNode,
        topology: TopologySnapshot,
        excluding excludedNodeID: UUID
    ) -> UUID? {
        let candidates = Set(topology.activeEndpoints.compactMap { endpoint -> UUID? in
            guard endpoint.nodeID != excludedNodeID,
                  endpointMatches(endpoint.address, tailscaleNode: tailscaleNode) else {
                return nil
            }
            return endpoint.nodeID
        })
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func endpointMatches(_ address: String, tailscaleNode: TailscaleNode) -> Bool {
        tailscaleNode.matches(host: address)
    }

    private static func metadataChanged(
        _ previous: TailscaleNodeIdentity?,
        _ current: TailscaleNodeIdentity
    ) -> Bool {
        guard let previous else { return true }
        return previous.keyPortNodeID != current.keyPortNodeID
            || previous.displayName != current.displayName
            || previous.hostName != current.hostName
            || previous.magicDNS != current.magicDNS
            || previous.addresses != current.addresses
            || previous.operatingSystem != current.operatingSystem
            || previous.isExitNode != current.isExitNode
            || previous.isExitNodeOption != current.isExitNodeOption
    }

    private static func upsertNode(
        for identity: TailscaleNodeIdentity,
        tailscaleNode: TailscaleNode,
        previousIdentity: TailscaleNodeIdentity?,
        in topology: inout TopologySnapshot,
        observedAt: Date
    ) {
        let fallbackName = identity.magicDNS
            ?? identity.hostName
            ?? identity.addresses.first
            ?? identity.tailscaleNodeID
        guard let index = topology.nodes.firstIndex(where: { $0.id == identity.keyPortNodeID }) else {
            topology.nodes.append(Node(
                id: identity.keyPortNodeID,
                name: identity.displayName.isEmpty ? fallbackName : identity.displayName,
                roles: tailscaleNode.isCurrent ? [.clientDevice] : [],
                group: tailscaleNode.isCurrent ? "" : "Tailscale",
                createdAt: observedAt,
                updatedAt: observedAt
            ))
            return
        }

        var node = topology.nodes[index]
        guard !node.isDeleted else { return }
        let metadataChanged = metadataChanged(previousIdentity, identity)
        if node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || previousIdentity?.displayName == node.name {
            node.name = identity.displayName.isEmpty ? fallbackName : identity.displayName
        }
        if node.group.isEmpty, !tailscaleNode.isCurrent {
            node.group = "Tailscale"
        }
        if tailscaleNode.isCurrent, !node.roles.contains(.clientDevice) {
            node.roles.append(.clientDevice)
            node.roles.sort { $0.rawValue < $1.rawValue }
        }
        if metadataChanged {
            node.updatedAt = observedAt
        }
        topology.nodes[index] = node
    }
}
