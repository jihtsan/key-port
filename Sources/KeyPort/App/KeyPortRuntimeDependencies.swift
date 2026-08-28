import Foundation

struct KeyPortRuntimeDependencies: Sendable {
    static let production = KeyPortRuntimeDependencies(
        tunnelRegistry: .production()
    )

    let tunnelRegistry: TunnelRegistry
}
