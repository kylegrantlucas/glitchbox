import Foundation
import Testing
@testable import GlitchboxKit

final class ToolchainTests {
    let dir: URL
    let contents: URL
    let cache: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "gbt-\(UUID().uuidString)", directoryHint: .isDirectory)
        contents = dir.appending(path: "Glitchbox.app/Contents", directoryHint: .isDirectory)
        cache = dir.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func writeManifest(_ json: String) throws {
        try Data(json.utf8).write(to: Toolchain.manifestURL(contents: contents))
    }

    @Test func expandsPlaceholdersAndBuildsHermeticEnvironment() throws {
        try writeManifest("""
            {"schema": 1, "digest": "abc123", "tools": {"ffmpeg": "8.1.2"},
             "path": ["@contents/Helpers"],
             "environment": {"FREI0R_PATH": "@contents/PlugIns/frei0r-1", "GST_REGISTRY": "@cache/gstreamer-abc.bin"}}
            """)
        let base = dir.appending(path: "library", directoryHint: .isDirectory)
        let kept = ["HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "TMPDIR": "/var/tmp/me/",
                    "LANG": "en_US.UTF-8", "LC_ALL": "C", "LC_CTYPE": "UTF-8", "TERM": "xterm-256color"]
        let leaked = ["PATH": "/opt/homebrew/bin:/usr/bin", "DYLD_LIBRARY_PATH": "/opt/lib", "GLITCHBOX_ROOT": "/elsewhere",
                      "FREI0R_PATH": "/usr/local/lib/frei0r-1", "SECRET_TOKEN": "hunter2", "SHELL": "/bin/zsh"]
        let toolchain = try Toolchain.load(contents: contents, cacheDir: cache)
        let env = toolchain.toolEnvironment(base: base, parent: kept.merging(leaked) { a, _ in a })

        let c = contents.standardizedFileURL.path
        let own = [
            "PATH": "\(c)/Helpers:\(base.path)/pipelines:/usr/bin:/bin:/usr/sbin:/sbin",
            "GLITCHBOX_ROOT": base.path,
            "GLITCHBOX_TOOLCHAIN": c,
            "FREI0R_PATH": "\(c)/PlugIns/frei0r-1",
            "GST_REGISTRY": "\(cache.path)/gstreamer-abc.bin",
        ]
        #expect(env.own == own)
        #expect(env.variables == own.merging(kept) { a, _ in a })
        #expect(env.digest == "abc123")
        #expect(toolchain.tools == ["ffmpeg": "8.1.2"])
    }

    @Test func missingOrInvalidManifestNamesItsPath() throws {
        let path = Toolchain.manifestURL(contents: contents).path
        let missing = #expect(throws: ToolchainError.self) { try Toolchain.load(contents: contents, cacheDir: self.cache) }
        #expect(missing?.localizedDescription.contains(path) == true)
        #expect(missing?.localizedDescription.contains("just app") == true)

        try writeManifest(#"{"schema": 2, "digest": "x", "path": []}"#)
        let invalid = #expect(throws: ToolchainError.self) { try Toolchain.load(contents: contents, cacheDir: self.cache) }
        #expect(invalid?.localizedDescription.contains(path) == true)
        #expect(invalid?.localizedDescription.contains("schema must be 1") == true)
    }

    @Test func shellExportsSortOwnKeysAndRoundTripThroughSh() throws {
        let tricky = #"it's "quoted" $HOME `cmd` \n"#
        let env = ToolEnvironment(own: ["B": tricky, "A": "/plain path"], passThrough: ["HOME": "/Users/me"], digest: "d")
        let exports = env.shellExports()
        #expect(exports == #"""
            export A='/plain path'
            export B='it'\''s "quoted" $HOME `cmd` \n'

            """#)

        let sh = Process()
        sh.executableURL = URL(filePath: "/bin/sh")
        sh.arguments = ["-c", exports + #"printf '%s|%s|%s' "$A" "$B" "${HOME-unset}""#]
        sh.environment = [:]
        let pipe = Pipe()
        sh.standardOutput = pipe
        try sh.run()
        sh.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(out == "/plain path|\(tricky)|unset")
    }
}
