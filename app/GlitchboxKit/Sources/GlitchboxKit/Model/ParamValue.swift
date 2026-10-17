import Foundation

/// A parameter value as stored in manifests, presets, and sessions.
public enum ParamValue: Codable, Hashable, Sendable {
    case int(Int)
    case float(Double)
    case bool(Bool)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .float(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected bool, number, or string")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .float(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .string(let s): try c.encode(s)
        }
    }

    /// Text substituted into argv templates and `GB_P_*` variables.
    public var rendered: String {
        switch self {
        case .int(let i): String(i)
        case .float(let d): String(d)
        case .bool(let b): b ? "1" : "0"
        case .string(let s): s
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): Double(i)
        case .float(let d): d
        default: nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
