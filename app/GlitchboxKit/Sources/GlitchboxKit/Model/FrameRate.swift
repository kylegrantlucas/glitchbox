import Foundation

/// A rational frame rate, stored as `"num/den"` (or `"num"`) so ffmpeg can take it verbatim.
///
/// MPEG-2 (`mpeg2-mosh`) rewrites any other rate to the nearest MPEG-2 one and changes the
/// frame count, so the app only offers `standard` and snaps source rates to it.
public struct FrameRate: Codable, Hashable, Sendable {
    public let numerator: Int
    public let denominator: Int

    public init(_ numerator: Int, _ denominator: Int = 1) {
        precondition(numerator > 0 && denominator > 0, "frame rate must be positive")
        let g = Self.gcd(numerator, denominator)
        self.numerator = numerator / g
        self.denominator = denominator / g
    }

    public static let fps23_976 = FrameRate(24000, 1001)
    public static let fps24 = FrameRate(24)
    public static let fps25 = FrameRate(25)
    public static let fps29_97 = FrameRate(30000, 1001)
    public static let fps30 = FrameRate(30)
    public static let fps50 = FrameRate(50)
    public static let fps59_94 = FrameRate(60000, 1001)
    public static let fps60 = FrameRate(60)

    /// Rates that survive every layer unchanged.
    public static let standard: [FrameRate] = [.fps23_976, .fps24, .fps25, .fps29_97, .fps30, .fps50, .fps59_94, .fps60]

    public var value: Double { Double(numerator) / Double(denominator) }

    /// `30000/1001` or `30`.
    public var ffmpeg: String { denominator == 1 ? String(numerator) : "\(numerator)/\(denominator)" }

    /// `29.97` or `30`.
    public var label: String {
        if denominator == 1 { return String(numerator) }
        return value.formatted(.number.precision(.fractionLength(0...3)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// The standard rate closest to `fps` by ratio.
    public static func nearestStandard(to fps: Double) -> FrameRate {
        guard fps.isFinite, fps > 0 else { return .fps30 }
        return standard.min { abs(log($0.value / fps)) < abs(log($1.value / fps)) }!
    }

    /// Parses `30000/1001`, `30`, or a decimal such as `29.97`. A decimal within 0.01 of a
    /// standard rate becomes that rate; other decimals are rejected.
    public init?(parsing text: String) {
        let s = text.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let n = Int(parts[0]), let d = Int(parts[1]), n > 0, d > 0 else { return nil }
            self.init(n, d)
        } else if let n = Int(s) {
            guard n > 0 else { return nil }
            self.init(n)
        } else if let d = Double(s), d > 0 {
            guard let match = Self.standard.first(where: { abs($0.value - d) < 0.01 }) else { return nil }
            self = match
        } else {
            return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self), i > 0 { self.init(i); return }
        if let s = try? c.decode(String.self), let r = FrameRate(parsing: s) { self = r; return }
        if let d = try? c.decode(Double.self), let r = FrameRate(parsing: String(d)) { self = r; return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected a frame rate such as 30 or \"30000/1001\"")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(ffmpeg)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}
