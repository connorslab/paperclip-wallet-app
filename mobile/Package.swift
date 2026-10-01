// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PaperclipMobile", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "PaperclipMobile", targets: ["PaperclipMobile"])],
    targets: [.target(name: "PaperclipMobile"), .testTarget(name: "PaperclipMobileTests", dependencies: ["PaperclipMobile"])])
