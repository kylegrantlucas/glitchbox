// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GlitchboxKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GlitchboxKit", targets: ["GlitchboxKit"]),
        .executable(name: "glitchbox", targets: ["glitchbox"]),
    ],
    targets: [
        .target(name: "GlitchboxKit"),
        .executableTarget(name: "glitchbox", dependencies: ["GlitchboxKit"]),
        .testTarget(name: "GlitchboxKitTests", dependencies: ["GlitchboxKit"]),
    ]
)
