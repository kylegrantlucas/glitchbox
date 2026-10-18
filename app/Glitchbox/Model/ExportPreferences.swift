import Foundation
import GlitchboxKit

/// `<user library>/export.json`: the last export settings and destination folder.
struct ExportPreferences: Codable {
    var settings = ExportSettings()
    var directory: String?

    static func load(from url: URL) -> ExportPreferences {
        guard let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(ExportPreferences.self, from: data) else { return ExportPreferences() }
        return prefs
    }
}
