import Foundation
import Testing
@testable import GlitchboxKit

struct HashingTests {
    /// The digest memo must never serve a rewritten file's old digest, even when the new
    /// contents have the same size and land within the same second.
    @Test func rewritingAFileInPlaceChangesItsDigest() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "gbk-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("aaaa".utf8).write(to: url)
        let first = try Hashing.sha256Hex(fileAt: url)
        let fh = try FileHandle(forWritingTo: url)
        try fh.write(contentsOf: Data("bbbb".utf8))
        try fh.close()
        #expect(try Hashing.sha256Hex(fileAt: url) == Hashing.sha256Hex(Data("bbbb".utf8)))
        #expect(first == Hashing.sha256Hex(Data("aaaa".utf8)))
    }
}
