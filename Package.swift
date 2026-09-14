// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyPort",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KeyPortDesignPreview", targets: ["KeyPortDesignPreview"]),
        .executable(name: "KeyPort", targets: ["KeyPort"]),
        .executable(name: "KeyPortAskPass", targets: ["KeyPortAskPass"]),
        .executable(name: "KeyPortSSHRelay", targets: ["KeyPortSSHRelay"]),
        .executable(name: "KeyPortTunnelBroker", targets: ["KeyPortTunnelBroker"]),
        .executable(name: "KeyPortCoreChecks", targets: ["KeyPortCoreChecks"]),
        .library(name: "KeyPortCore", targets: ["KeyPortCore"]),
    ],
    targets: [
        .target(name: "KeyPortInterface", resources: [.process("Resources")]),
        .executableTarget(name: "KeyPortDesignPreview", dependencies: ["KeyPortInterface"]),
        .testTarget(name: "KeyPortInterfaceTests", dependencies: ["KeyPortInterface"]),
        .target(name: "KeyPortCore"),
        .executableTarget(
            name: "KeyPort",
            dependencies: ["KeyPortCore", "KeyPortInterface"],
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CloudKit"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "KeyPortAskPass"
        ),
        .executableTarget(
            name: "KeyPortSSHRelay",
            dependencies: ["KeyPortCore"]
        ),
        .executableTarget(
            name: "KeyPortTunnelBroker",
            dependencies: ["KeyPortCore"],
            linkerSettings: [.linkedFramework("Network")]
        ),
        .executableTarget(name: "KeyPortCoreChecks", dependencies: ["KeyPortCore"]),
        .testTarget(name: "KeyPortTests", dependencies: ["KeyPort"]),
        .testTarget(name: "KeyPortCoreTests", dependencies: ["KeyPortCore"]),
        .testTarget(name: "KeyPortTunnelBrokerTests", dependencies: ["KeyPortTunnelBroker"]),
    ],
    swiftLanguageModes: [.v5]
)
