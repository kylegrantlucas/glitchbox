import CryptoKit
import Foundation

public enum Hashing {
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// The file's SHA-256, read once per `FileIdentity`: every render keys the source and its
    /// file params by content, and re-reading a 4K source costs ~0.5 s per GB on every edit.
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let identity = try FileIdentity(url)
        if let digest = digests[identity] { return digest }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        // FileHandle's chunks are autoreleased, and a background thread has no pool that drains
        // during the loop: without one per chunk the whole file stays resident (a 153 MB layer
        // took phys_footprint from 11 to 157 MB; a 4K layer would be GBs, jetsam on iOS).
        while try autoreleasepool(invoking: {
            guard let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hex(hasher.finalize())
        // A write during the read moves ctime: keep only digests of contents that held still.
        if (try? FileIdentity(url)) == identity { digests[identity] = digest }
        return digest
    }

    private static let digests = Memo<FileIdentity, String>()
}

/// Names a file's contents without reading them: device, inode, size, and modification and
/// status-change times. Any write moves ctime, which no API can set back, so an unchanged
/// identity means unchanged contents.
struct FileIdentity: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modified: timespec
    let changed: timespec

    init(_ url: URL) throws {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        device = st.st_dev
        inode = st.st_ino
        size = st.st_size
        #if canImport(Darwin)
        modified = st.st_mtimespec
        changed = st.st_ctimespec
        #else
        modified = st.st_mtim
        changed = st.st_ctim
        #endif
    }

    static func == (a: Self, b: Self) -> Bool {
        a.device == b.device && a.inode == b.inode && a.size == b.size
            && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
            && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
    }

    func hash(into h: inout Hasher) {
        h.combine(device); h.combine(inode); h.combine(size)
        h.combine(modified.tv_sec); h.combine(modified.tv_nsec)
        h.combine(changed.tv_sec); h.combine(changed.tv_nsec)
    }
}

/// A process-wide, thread-safe dictionary for values derived from file contents.
final class Memo<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Key: Value] = [:]

    subscript(key: Key) -> Value? {
        get { lock.withLock { values[key] } }
        set { lock.withLock { values[key] = newValue } }
    }
}
