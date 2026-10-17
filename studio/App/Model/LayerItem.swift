import Foundation
import VideobedKit

struct LayerItem: Identifiable, Hashable {
    let id: UUID
    var spec: LayerSpec
    var status: LayerStatus = .idle
    var output: LayerOutput?

    init(id: UUID = UUID(), spec: LayerSpec, status: LayerStatus = .idle) {
        self.id = id; self.spec = spec; self.status = status
    }
}
