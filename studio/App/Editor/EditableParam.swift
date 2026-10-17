import Foundation
import VideobedKit

/// A param row in the editor; list fields stay as raw text while typing.
struct EditableParam: Identifiable, Hashable {
    let id = UUID()
    var spec: ParamSpec
    var optionsText: String
    var extensionsText: String

    init(_ spec: ParamSpec) {
        self.spec = spec
        optionsText = (spec.options ?? []).joined(separator: ", ")
        extensionsText = (spec.extensions ?? []).joined(separator: ", ")
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var options: [String] { Self.list(optionsText) }

    /// The spec with fields irrelevant to its type removed.
    var normalized: ParamSpec {
        var s = spec
        let numeric = s.type == .int || s.type == .float
        if !numeric { s.min = nil; s.max = nil; s.step = nil }
        if s.type != .float { s.step = nil }
        s.options = s.type == .enumeration ? options : nil
        s.extensions = s.type == .file ? Self.list(extensionsText) : nil
        if s.help?.isEmpty == true { s.help = nil }
        return s
    }

    /// Keeps the default representable after a type change.
    mutating func typeChanged() {
        if let v = spec.coerce(spec.default) { spec.default = v; return }
        spec.default = switch spec.type {
        case .int: .int(0)
        case .float: .float(0)
        case .bool: .bool(false)
        case .enumeration: .string(options.first ?? "")
        case .string, .file: .string("")
        }
    }
}
