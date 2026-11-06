// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HongguoCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HongguoCore", targets: ["HongguoCore"]),
        .library(name: "HongguoPlayback", targets: ["HongguoPlayback"]),
        .executable(name: "NativePlaybackCheck", targets: ["NativePlaybackCheck"]),
        .executable(name: "CatalogDiscoveryCheck", targets: ["CatalogDiscoveryCheck"]),
        .executable(name: "NativeAccountCheck", targets: ["NativeAccountCheck"])
    ],
    targets: [
        .target(name: "HongguoCore", exclude: ["NativeRuntime/UPSTREAM.md"], resources: [.copy("NativeRuntime/PlaybackAssets")], linkerSettings: [.linkedLibrary("z")]),
        .target(name: "HongguoPlayback", dependencies: ["HongguoCore"]),
        .testTarget(name: "HongguoCoreTests", dependencies: ["HongguoCore"]),
        .executableTarget(name: "NativePlaybackCheck", dependencies: ["HongguoCore", "HongguoPlayback"], path: "Tools/NativePlaybackCheck"),
        .executableTarget(name: "CatalogDiscoveryCheck", dependencies: ["HongguoCore"], path: "Tools/CatalogDiscoveryCheck"),
        .executableTarget(name: "NativeAccountCheck", dependencies: ["HongguoCore"], path: "Tools/NativeAccountCheck")
    ]
)
