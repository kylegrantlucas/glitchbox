enum RenderMode: String, Codable, CaseIterable, Identifiable {
    case preview, full

    var id: Self { self }

    var title: String {
        switch self {
        case .preview: "Preview"
        case .full: "Full"
        }
    }
}
