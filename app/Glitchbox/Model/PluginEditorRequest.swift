import Foundation

/// A request to open the plugin editor for one plugin id.
struct PluginEditorRequest: Identifiable, Hashable {
    let id: String
}
