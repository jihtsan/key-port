import CryptoKit
import Foundation

public extension HostV6 {
    enum StableID {
        private static let dnsNamespace = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        private static let keyPortNamespace = uuidV5(namespace: dnsNamespace, name: "app.keyport/host-v6")

        public static func uuidV5(namespace: UUID, name: String) -> UUID {
            let value = namespace.uuid
            var bytes: [UInt8] = [
                value.0, value.1, value.2, value.3,
                value.4, value.5, value.6, value.7,
                value.8, value.9, value.10, value.11,
                value.12, value.13, value.14, value.15,
            ]
            bytes.append(contentsOf: name.utf8)
            var digest = Array(Insecure.SHA1.hash(data: Data(bytes)))
            digest[6] = (digest[6] & 0x0f) | 0x50
            digest[8] = (digest[8] & 0x3f) | 0x80
            return UUID(uuid: (
                digest[0], digest[1], digest[2], digest[3],
                digest[4], digest[5], digest[6], digest[7],
                digest[8], digest[9], digest[10], digest[11],
                digest[12], digest[13], digest[14], digest[15]
            ))
        }

        public static func host(legacyEndpointKey: String) -> UUID {
            uuidV5(namespace: keyPortNamespace, name: "host|\(legacyEndpointKey)")
        }

        public static func legacyEndpointKey(host: String, port: UInt16) -> String {
            let normalizedHost = host
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return "endpoint:\(normalizedHost):\(port)"
        }

        public static func host(legacyHost: String, port: UInt16) -> UUID {
            host(legacyEndpointKey: legacyEndpointKey(host: legacyHost, port: port))
        }

        public static func address(hostID: UUID, endpointKey: String) -> UUID {
            uuidV5(
                namespace: keyPortNamespace,
                name: "address|\(hostID.uuidString.lowercased())|\(endpointKey)"
            )
        }

        public static func address(hostID: UUID, legacyHost: String, port: UInt16) -> UUID {
            address(hostID: hostID, endpointKey: legacyEndpointKey(host: legacyHost, port: port))
        }

        public static func hostKeyPin(addressID: UUID, algorithm: String, fingerprint: String) -> UUID {
            uuidV5(
                namespace: keyPortNamespace,
                name: "pin|\(addressID.uuidString.lowercased())|\(algorithm)|\(fingerprint)"
            )
        }

        public static func knownHostsLine(
            pinID: UUID,
            sourceID: UUID,
            rawLine: String,
            duplicateOrdinal: UInt32
        ) -> UUID {
            let digest = SHA256.hash(data: Data(rawLine.utf8)).map { String(format: "%02x", $0) }.joined()
            return uuidV5(
                namespace: keyPortNamespace,
                name: "known-hosts-line|\(pinID.uuidString.lowercased())|\(sourceID.uuidString.lowercased())|\(digest)|\(duplicateOrdinal)"
            )
        }

        public static func mergeReview(
            entityType: EntityType,
            entityID: String,
            conflictingMutationIDs: [UUID]
        ) -> UUID {
            let mutations = conflictingMutationIDs.map { $0.uuidString.lowercased() }.sorted().joined(separator: ",")
            return uuidV5(
                namespace: keyPortNamespace,
                name: "merge-review|\(entityType.rawValue)|\(entityID)|\(mutations)"
            )
        }
    }
}
