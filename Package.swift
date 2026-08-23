// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyPort",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KeyPort", targets: ["KeyPort"]),
        .executable(name: "KeyPortAskPass", targets: ["KeyPortAskPass"]),
        .executable(name: "KeyPortCoreChecks", targets: ["KeyPortCoreChecks"]),
        .library(name: "KeyPortCore", targets: ["KeyPortCore"]),
    ],
    targets: [
        .target(name: "KeyPortCore"),
        .executableTarget(
            name: "KeyPort",
            dependencies: ["KeyPortCore"],
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CloudKit"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "KeyPortAskPass"
        ),
        .executableTarget(name: "KeyPortCoreChecks", dependencies: ["KeyPortCore"]),
        .testTarget(name: "KeyPortTests", dependencies: ["KeyPort"]),
    ],
    swiftLanguageModes: [.v5]
)
