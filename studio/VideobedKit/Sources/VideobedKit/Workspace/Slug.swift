public enum Slug {
    public static func slug(_ name: String) throws -> String {
        var out = ""
        var pendingDash = false
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else {
                pendingDash = true
            }
        }
        guard !out.isEmpty else { throw WorkspaceError.emptySlug }
        return out
    }
}
