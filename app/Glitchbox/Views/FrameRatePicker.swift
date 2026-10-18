import GlitchboxKit
import SwiftUI

/// Standard rates plus "Match source", which shows the rate it snaps to when known.
struct FrameRatePicker: View {
    @Binding var selection: FrameRate?
    /// The source's own rate, when probed.
    var sourceRate: Double?

    var body: some View {
        Picker("FPS", selection: $selection) {
            Text(matchLabel).tag(FrameRate?.none)
            Divider()
            ForEach(FrameRate.standard, id: \.self) { Text($0.label).tag(FrameRate?.some($0)) }
        }
    }

    private var matchLabel: String {
        guard let sourceRate else { return "Match source" }
        return "Match source (\(FrameRate.nearestStandard(to: sourceRate).label))"
    }
}
