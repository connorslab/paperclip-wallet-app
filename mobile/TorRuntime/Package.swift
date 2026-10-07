// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "TorRuntime", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "TorRuntime", targets: ["TorRuntime"])],
    targets: [
        .binaryTarget(name: "tor", url: "https://github.com/iCepa/Tor.framework/releases/download/v409.13.1/tor.xcframework.zip",
            checksum: "851174402abc8655273264f6b877a625648e52e6f9dd490b35e7cb94c2c924c6"),
        .target(name: "TorRuntime", dependencies: ["tor"], linkerSettings: [.linkedLibrary("z")])
    ])
