// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PaperclipMobile", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "PaperclipMobile", targets: ["PaperclipMobile"])],
    dependencies: [.package(url: "https://github.com/BlockchainCommons/URKit", revision: "ebba59b2e1538cb368d98147dd58c452e6d1dc47")],
    targets: [.target(name: "PaperclipMobile", dependencies: [.product(name: "URKit", package: "URKit")], linkerSettings: [.linkedLibrary("z")]), .testTarget(name: "PaperclipMobileTests", dependencies: ["PaperclipMobile"], resources: [.copy("Fixtures")])])
