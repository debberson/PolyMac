// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PolyMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PolyMac", path: "Sources/PolyMac"),
        .testTarget(name: "PolyMacTests", dependencies: ["PolyMac"], path: "Tests/PolyMacTests"),
    ]
)
