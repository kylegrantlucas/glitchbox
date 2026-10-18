import Foundation

/// State read from an ffmpeg `-progress` file: `key=value` blocks, each ending in
/// `progress=continue` or `progress=end`.
public struct ExportProgress: Equatable, Sendable {
    /// Seconds of output written; nil until ffmpeg reports a time (x264 lookahead and GIF's
    /// palette pass report `N/A` at first).
    public var outTime: Double?
    public var ended: Bool

    public init(outTime: Double? = nil, ended: Bool = false) {
        self.outTime = outTime; self.ended = ended
    }

    public static func parse(_ text: String) -> ExportProgress {
        var result = ExportProgress()
        var lines = text.split(whereSeparator: \.isNewline)
        // The last line may still be mid-write.
        if !text.hasSuffix("\n"), !lines.isEmpty { lines.removeLast() }
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq], value = line[line.index(after: eq)...]
            switch key {
            // `out_time_ms` is also microseconds; prefer the correctly named key.
            case "out_time_us", "out_time_ms":
                if let us = Int64(value), us >= 0 { result.outTime = Double(us) / 1_000_000 }
            case "progress":
                result.ended = value == "end"
            default:
                break
            }
        }
        return result
    }

    /// 0...1 against `duration` seconds; 1 once ended; nil when there is nothing to measure yet.
    public func fraction(of duration: Double?) -> Double? {
        if ended { return 1 }
        guard let outTime, let duration, duration > 0 else { return nil }
        return min(1, max(0, outTime / duration))
    }
}
