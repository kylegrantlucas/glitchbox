// swift-tools-version: 6.2
import PackageDescription

// The in-process ToolRunner for iOS: the ffmpeg/ffprobe CLIs and the FFglitch tools run as
// library calls, and plugins that spawn other tools get native step implementations.
// The macOS slices exist only so `swift test` runs on the host; the macOS app never links this.
//
// Binary targets are copies of build/ios/xcframeworks/*.xcframework in Artifacts/
// (`packaging/build.sh ios-tools`; SwiftPM refuses binary targets outside the package).
// Adding a framework = one more `binaryTarget` here plus a dependency where it is used.

// What libGlitchFFmpeg.a needs (its module map's `link` lines; C targets include its headers
// textually, so nothing autolinks them).
let glitchFFmpegLinks: [LinkerSetting] = ["z", "bz2", "iconv", "c++"].map { .linkedLibrary($0) }
    + ["AudioToolbox", "CoreAudio", "CoreFoundation", "CoreMedia", "CoreServices", "CoreVideo", "VideoToolbox"]
        .map { .linkedFramework($0) }

let package = Package(
    name: "GlitchboxInProcess",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "GlitchboxInProcess", targets: ["GlitchboxInProcess"]),
    ],
    dependencies: [
        .package(name: "GlitchboxKit", path: "../GlitchboxKit"),
    ],
    targets: [
        .binaryTarget(name: "GlitchFFmpeg", path: "Artifacts/GlitchFFmpeg.xcframework"),
        .binaryTarget(name: "FFglitch", path: "Artifacts/FFglitch.xcframework"),
        .binaryTarget(name: "GlitchboxFX", path: "Artifacts/GlitchboxFX.xcframework"),
        .binaryTarget(name: "GlitchboxBurns", path: "Artifacts/GlitchboxBurns.xcframework"),
        .binaryTarget(name: "onnxruntime", path: "Artifacts/onnxruntime.xcframework"),
        // Tool entry points behind an opaque cancel flag (Swift does not import C11 atomics).
        .target(name: "GBRun", dependencies: ["GlitchFFmpeg", "FFglitch"], linkerSettings: glitchFFmpegLinks),
        // Thread-safe libav helpers for native steps: decode → effect → encode.
        .target(name: "GBMedia", dependencies: ["GlitchFFmpeg"], linkerSettings: glitchFFmpegLinks),
        .target(name: "GlitchboxInProcess", dependencies: [
            "GBRun", "GBMedia", "GlitchboxFX", "GlitchboxBurns", "onnxruntime",
            .product(name: "GlitchboxKit", package: "GlitchboxKit"),
        ]),
        .testTarget(name: "GlitchboxInProcessTests", dependencies: [
            "GlitchboxInProcess", "GBMedia",
            .product(name: "GlitchboxKit", package: "GlitchboxKit"),
        ]),
    ]
)
