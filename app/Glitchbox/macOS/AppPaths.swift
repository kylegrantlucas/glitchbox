import Foundation

/// Where the running app finds its base library and toolchain.
struct AppPaths {
    /// Base (read-only) library root.
    let base: URL
    /// `Glitchbox.app/Contents` holding `Resources/toolchain.json`.
    let toolchain: URL

    /// Debug builds carry `GBDevRoot` (the repo checkout) and use the repo library with
    /// `<repo>/build/Glitchbox.app/Contents`; Release builds use their own bundle.
    static func current(bundle: Bundle = .main) -> AppPaths {
        if let dev = bundle.object(forInfoDictionaryKey: "GBDevRoot") as? String, !dev.isEmpty {
            let repo = URL(filePath: dev, directoryHint: .isDirectory).standardizedFileURL
            return AppPaths(base: repo, toolchain: repo.appending(path: "build/Glitchbox.app/Contents", directoryHint: .isDirectory))
        }
        let contents = bundle.bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        return AppPaths(base: contents.appending(path: "Resources/library", directoryHint: .isDirectory), toolchain: contents)
    }
}
