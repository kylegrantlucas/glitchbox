import GlitchboxKit
import SwiftUI

/// Processing resolution: a short side in pixels, or native.
struct ResolutionPicker: View {
    let title: String
    @Binding var selection: Int?

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(RenderOptions.heights, id: \.self) { Text("\($0)p").tag(Int?.some($0)) }
            Text("Native").tag(Int?.none)
        }
        .help("Short side in pixels, so portrait video keeps its shape")
    }
}
