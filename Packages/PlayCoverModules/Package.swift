// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlayCoverModules",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "PlayCoverCore", targets: ["PlayCoverCore"]),
        .library(name: "PlayCoverMachO", targets: ["PlayCoverMachO"]),
        .library(name: "PlayCoverKeymapping", targets: ["PlayCoverKeymapping"]),
        .library(name: "PlayCoverSandbox", targets: ["PlayCoverSandbox"]),
        .library(name: "PlayCoverUI", targets: ["PlayCoverUI"])
    ],
    targets: [
        .target(
            name: "PlayCoverCore",
            dependencies: []
        ),
        .target(
            name: "PlayCoverMachO",
            dependencies: ["PlayCoverCore"]
        ),
        .target(
            name: "PlayCoverKeymapping",
            dependencies: ["PlayCoverCore"]
        ),
        .target(
            name: "PlayCoverSandbox",
            dependencies: ["PlayCoverCore"]
        ),
        .target(
            name: "PlayCoverUI",
            dependencies: ["PlayCoverCore"]
        ),
        .testTarget(
            name: "PlayCoverCoreSPMTests",
            dependencies: ["PlayCoverCore"]
        ),
        .testTarget(
            name: "PlayCoverMachOSPMTests",
            dependencies: ["PlayCoverMachO", "PlayCoverCore"]
        ),
        .testTarget(
            name: "PlayCoverSandboxSPMTests",
            dependencies: ["PlayCoverSandbox", "PlayCoverCore"]
        ),
        .testTarget(
            name: "PlayCoverUISPMTests",
            dependencies: ["PlayCoverUI", "PlayCoverCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
