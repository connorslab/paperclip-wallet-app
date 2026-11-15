// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "TorRuntime", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "TorRuntime", targets: ["TorRuntime"])],
    targets: [
        // XcodeGen prepares a checksum-verified copy with flat iOS framework bundles.
        .binaryTarget(name: "tor", path: "Artifacts/tor.xcframework"),
        .target(name: "TorRuntime", dependencies: ["tor"], linkerSettings: [.linkedLibrary("z")]),
        .testTarget(name: "TorRuntimeTests", dependencies: ["TorRuntime"])
    ])
