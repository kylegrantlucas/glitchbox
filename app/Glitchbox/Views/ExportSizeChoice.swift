import GlitchboxKit

/// Entries of the export sheet's size menu.
enum ExportSizeChoice: Hashable {
    case asRendered
    case shortSide(Int)
    /// Index into `OutputSize.social`.
    case social(Int)
    case custom

    init(_ size: OutputSize) {
        switch size {
        case .asRendered: self = .asRendered
        case .shortSide(let n): self = .shortSide(n)
        case .box:
            if let i = OutputSize.social.firstIndex(where: { $0.size == size }) { self = .social(i) } else { self = .custom }
        }
    }
}
