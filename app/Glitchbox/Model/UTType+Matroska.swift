import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (`UTImportedTypeDeclarations`), since macOS has no MKV type.
    static let matroska = UTType(importedAs: "org.matroska.mkv", conformingTo: .movie)
}
