// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PixelLiftCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PixelLiftCore", targets: ["PixelLiftCore"])],
    targets: [
        .target(name: "PixelLiftCore"),
        .testTarget(name: "PixelLiftCoreTests", dependencies: ["PixelLiftCore"])
    ]
)
