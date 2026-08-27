// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ForedeckCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ForedeckCore", targets: ["ForedeckCore"])
    ],
    targets: [
        .target(name: "ForedeckCore"),
        .testTarget(name: "ForedeckCoreTests", dependencies: ["ForedeckCore"])
    ]
)
