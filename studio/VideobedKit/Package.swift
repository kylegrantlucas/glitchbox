// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VideobedKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VideobedKit", targets: ["VideobedKit"]),
        .executable(name: "vbplug", targets: ["vbplug"]),
    ],
    targets: [
        .target(name: "VideobedKit"),
        .executableTarget(name: "vbplug", dependencies: ["VideobedKit"]),
        .testTarget(name: "VideobedKitTests", dependencies: ["VideobedKit"]),
    ]
)
