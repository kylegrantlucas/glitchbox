import Foundation
import Observation
import SwiftUI
import VideobedKit

/// Owns the chosen videobed root and the model built for it.
@Observable @MainActor
final class AppStore {
    private(set) var model: StudioModel?

    init() {
        if let root = Self.initialRoot() { model = StudioModel(root: root) }
    }

    /// Stored choice → bundled `VBRootHint` (the checkout the app was built from).
    private static func initialRoot() -> URL? {
        if let stored = UserDefaults.standard.string(forKey: "videobedRoot"), !stored.isEmpty {
            let url = URL(filePath: stored, directoryHint: .isDirectory).standardizedFileURL
            if RootLocator.isRoot(url) { return url }
        }
        if let hint = Bundle.main.object(forInfoDictionaryKey: "VBRootHint") as? String {
            let url = URL(filePath: hint, directoryHint: .isDirectory).standardizedFileURL
            if RootLocator.isRoot(url) { return url }
        }
        return nil
    }

    /// Returns false when `url` is not a videobed checkout.
    func choose(root url: URL) -> Bool {
        let url = url.standardizedFileURL
        guard RootLocator.isRoot(url) else { return false }
        UserDefaults.standard.set(url.path, forKey: "videobedRoot")
        model?.cancelRender()
        model = StudioModel(root: url)
        return true
    }
}
