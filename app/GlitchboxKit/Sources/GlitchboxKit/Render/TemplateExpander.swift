/// Expands `{name}` placeholders in argv templates.
///
/// Grammar: `{{` → `{`, `}}` → `}`, `{name}` → value, unterminated `{` is an
/// error, a lone `}` is literal. Names: `builtinNames` and `p.<key>`.
public struct TemplateExpander {
    private enum Piece { case literal(String), placeholder(String) }

    /// `params` is the resolved-params JSON file; `source_audio` the source's
    /// trimmed audio track ("" when the source has none).
    public static let builtinNames: Set<String> = ["in", "out", "work", "root", "params", "source_audio"]

    public static func isValidName(_ name: String) -> Bool {
        if builtinNames.contains(name) { return true }
        guard name.hasPrefix("p.") else { return false }
        let key = name.dropFirst(2)
        guard let first = key.first, first.isASCII, first.isLowercase else { return false }
        return key.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
    }

    private static func parse(_ template: String) throws -> [Piece] {
        var pieces: [Piece] = []
        var lit = ""
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            let next = template.index(after: i)
            if c == "{" {
                if next < template.endIndex, template[next] == "{" {
                    lit.append("{"); i = template.index(after: next); continue
                }
                guard let close = template[next...].firstIndex(of: "}") else { throw TemplateError.unterminated }
                let name = String(template[next..<close])
                guard isValidName(name) else { throw TemplateError.unknownPlaceholder(name) }
                if !lit.isEmpty { pieces.append(.literal(lit)); lit = "" }
                pieces.append(.placeholder(name))
                i = template.index(after: close)
            } else if c == "}" {
                lit.append("}")
                i = (next < template.endIndex && template[next] == "}") ? template.index(after: next) : next
            } else {
                lit.append(c); i = next
            }
        }
        if !lit.isEmpty { pieces.append(.literal(lit)) }
        return pieces
    }

    public static func placeholders(in template: String) throws -> [String] {
        try parse(template).compactMap { if case .placeholder(let n) = $0 { n } else { nil } }
    }

    public static func expand(_ template: String, values: [String: String]) throws -> String {
        try parse(template).map { piece in
            switch piece {
            case .literal(let s): return s
            case .placeholder(let n):
                guard let v = values[n] else { throw TemplateError.unknownPlaceholder(n) }
                return v
            }
        }.joined()
    }
}
