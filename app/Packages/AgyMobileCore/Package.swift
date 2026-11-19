// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgyMobileCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AgyMobileCore", targets: ["AgyMobileCore"])],
    targets: [
        .target(name: "AgyMobileCore"),
        .testTarget(name: "AgyMobileCoreTests", dependencies: ["AgyMobileCore"]),
    ]
)
