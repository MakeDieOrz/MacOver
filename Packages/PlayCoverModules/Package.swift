// swift-tools-version: 6.2
import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances")
]

let package = Package(
    name: "PlayCoverModules",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "PlayCoverCore", targets: ["PlayCoverCore"]),
        .library(name: "PlayCoverMachO", targets: ["PlayCoverMachO"]),
        .library(name: "PlayCoverKeymapping", targets: ["PlayCoverKeymapping"]),
        .library(name: "PlayCoverNetwork", targets: ["PlayCoverNetwork"]),
        .library(name: "PlayCoverSandbox", targets: ["PlayCoverSandbox"]),
        .library(name: "PlayCoverInstaller", targets: ["PlayCoverInstaller"]),
        .library(name: "PlayCoverUI", targets: ["PlayCoverUI"])
    ],
    targets: [
        .target(
            name: "PlayCoverCore",
            dependencies: [],
            swiftSettings: approachableConcurrencySettings
        ),
        .target(
            name: "PlayCoverMachO",
            dependencies: ["PlayCoverCore"],
            swiftSettings: approachableConcurrencySettings
        ),
        .target(
            name: "PlayCoverKeymapping",
            dependencies: ["PlayCoverCore"],
            swiftSettings: approachableConcurrencySettings
        ),
        .target(
            name: "PlayCoverNetwork",
            dependencies: ["PlayCoverCore"],
            swiftSettings: approachableConcurrencySettings
        ),
        .target(
            name: "PlayCoverSandbox",
            dependencies: ["PlayCoverCore"],
            swiftSettings: approachableConcurrencySettings
        ),
        .target(
            name: "PlayCoverInstaller",
            dependencies: ["PlayCoverCore", "PlayCoverMachO"],
            swiftSettings: approachableConcurrencySettings
        ),
        .target(
            name: "PlayCoverUI",
            dependencies: ["PlayCoverCore"],
            swiftSettings: approachableConcurrencySettings
        ),
        .testTarget(
            name: "PlayCoverCoreSPMTests",
            dependencies: ["PlayCoverCore"],
            swiftSettings: approachableConcurrencySettings
        ),
        .testTarget(
            name: "PlayCoverMachOSPMTests",
            dependencies: ["PlayCoverMachO", "PlayCoverCore"],
            swiftSettings: approachableConcurrencySettings
        ),
        .testTarget(
            name: "PlayCoverNetworkSPMTests",
            dependencies: ["PlayCoverNetwork", "PlayCoverCore"],
            swiftSettings: approachableConcurrencySettings
        ),
        .testTarget(
            name: "PlayCoverSandboxSPMTests",
            dependencies: ["PlayCoverSandbox", "PlayCoverCore"],
            swiftSettings: approachableConcurrencySettings
        ),
        .testTarget(
            name: "PlayCoverInstallerSPMTests",
            dependencies: ["PlayCoverInstaller", "PlayCoverMachO", "PlayCoverCore"],
            swiftSettings: approachableConcurrencySettings
        ),
        .testTarget(
            name: "PlayCoverUISPMTests",
            dependencies: ["PlayCoverUI", "PlayCoverCore"],
            swiftSettings: approachableConcurrencySettings
        )
    ],
    swiftLanguageModes: [.v6]
)
