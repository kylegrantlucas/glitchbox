import Foundation

public enum ManifestValidator {
    public static func isValidID(_ s: String) -> Bool {
        s.wholeMatch(of: /[a-z0-9][a-z0-9-]*/) != nil
    }

    public static func isValidKey(_ s: String) -> Bool {
        s.wholeMatch(of: /[a-z][a-z0-9_]*/) != nil
    }

    public static func validate(_ m: PluginManifest, fileName: String?, root: URL? = nil) -> [ValidationIssue] {
        var issues: [String] = []
        if m.schema != 1 { issues.append("schema must be 1 (got \(m.schema))") }
        if !isValidID(m.id) { issues.append("id '\(m.id)' must match [a-z0-9][a-z0-9-]*") }
        if let fileName, fileName != "\(m.id).json" {
            issues.append("file name '\(fileName)' must be '\(m.id).json'")
        }
        if m.name.trimmingCharacters(in: .whitespaces).isEmpty { issues.append("name must not be empty") }

        var seen = Set<String>()
        for p in m.params {
            let tag = "param '\(p.key)'"
            if !isValidKey(p.key) { issues.append("\(tag): key must match [a-z][a-z0-9_]*") }
            if !seen.insert(p.key).inserted { issues.append("\(tag): duplicate key") }
            guard p.coerce(p.default) != nil || p.type == .enumeration else {
                issues.append("\(tag): default does not match type \(p.type.rawValue)"); continue
            }
            switch p.type {
            case .int, .float:
                if let lo = p.min, let hi = p.max, lo > hi { issues.append("\(tag): min > max") }
                if let d = p.coerce(p.default)?.doubleValue {
                    if let lo = p.min, d < lo { issues.append("\(tag): default \(p.default.rendered) below min") }
                    if let hi = p.max, d > hi { issues.append("\(tag): default \(p.default.rendered) above max") }
                }
            case .enumeration:
                let opts = p.options ?? []
                if opts.isEmpty { issues.append("\(tag): enum needs options") }
                else if p.coerce(p.default) == nil { issues.append("\(tag): default not in options") }
            case .bool, .string, .file:
                break
            }
        }

        if m.steps.isEmpty { issues.append("at least one step is required") }
        let declared = Set(m.params.map(\.key))
        for (i, s) in m.steps.enumerated() {
            let tag = "step \(i + 1)" + (s.name.isEmpty ? "" : " '\(s.name)'")
            if s.name.trimmingCharacters(in: .whitespaces).isEmpty { issues.append("\(tag): name must not be empty") }
            let hasArgv = !(s.argv ?? []).isEmpty
            let hasScript = !(s.script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasArgv == hasScript { issues.append("\(tag): needs exactly one of argv or script") }
            for arg in s.argv ?? [] {
                do {
                    for name in try TemplateExpander.placeholders(in: arg)
                    where name.hasPrefix("p.") && !declared.contains(String(name.dropFirst(2))) {
                        issues.append("\(tag): {\(name)} names an undeclared param")
                    }
                } catch {
                    issues.append("\(tag): \(error.localizedDescription) in '\(arg)'")
                }
            }
        }

        if let root {
            for a in m.assets {
                if a.hasPrefix("/") || a.split(separator: "/").contains("..") {
                    issues.append("asset '\(a)' must be a relative path inside the repo")
                } else if !FileManager.default.fileExists(atPath: root.appending(path: a).path) {
                    issues.append("asset '\(a)' not found")
                }
            }
        }
        return issues.map(ValidationIssue.init)
    }
}
