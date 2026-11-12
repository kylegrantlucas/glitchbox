import GlitchboxKit
import SwiftUI

/// Simple mode's viewer on iPhone and iPad. Swipe down on it (or use the toolbar's Full Screen
/// button) and it fills the screen; there, swipe sideways to try the next or previous look, and
/// swipe down again (or tap the close button) to come back. The layout that owns
/// `isFullScreen` hides everything else while it is on.
struct LookSwipeViewer: View {
    @Binding var isFullScreen: Bool
    @Environment(StudioModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var pendingLook: ChainPreset?

    /// How far a drag must travel to count as a swipe.
    private static let swipeDistance: CGFloat = 60

    var body: some View {
        ViewerView()
            // Full screen is for watching and flicking through looks: no transport controls to catch the swipes.
            .environment(\.playerShowsControls, !isFullScreen)
            .overlay(alignment: .topTrailing) {
                if isFullScreen {
                    Button("Exit Full Screen", systemImage: "xmark") { setFullScreen(false) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .padding(12)
                }
            }
            .overlay(alignment: .bottom) {
                if isFullScreen { lookBar }
            }
            .contentShape(.rect)
            .simultaneousGesture(swipe)
            // Full screen is black whatever the system appearance: "Rendering…" and the controls must read on it.
            .environment(\.colorScheme, isFullScreen ? .dark : colorScheme)
            .confirmationDialog("Replace your changes?",
                                isPresented: Binding(get: { pendingLook != nil }, set: { if !$0 { pendingLook = nil } }),
                                presenting: pendingLook) { look in
                Button("Replace") { model.load(chain: look, keepingStillInput: true) }
            } message: { look in
                Text("“\(look.name)” replaces the effects you've adjusted.")
            }
    }

    /// The applied look and its place in the gallery, between previous and next buttons
    /// (the swipes' visible, VoiceOver-reachable twins).
    private var lookBar: some View {
        let looks = browsableLooks
        let index = looks.firstIndex { $0.name == model.appliedLook }
        return HStack(spacing: 16) {
            Button("Previous Look", systemImage: "chevron.left") { step(-1) }
            VStack(spacing: 2) {
                Text(index.map { looks[$0].name } ?? "No Look")
                    .font(.headline)
                    .lineLimit(1)
                Text(index.map { "\($0 + 1) of \(looks.count)" } ?? "Swipe for looks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(minWidth: 140)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("look-position")
            Button("Next Look", systemImage: "chevron.right") { step(1) }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .padding(.bottom, 24)
        .disabled(looks.isEmpty)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            let dx = value.translation.width, dy = value.translation.height
            if abs(dy) > abs(dx) {
                if dy > Self.swipeDistance { setFullScreen(!isFullScreen) }
            } else if isFullScreen, abs(dx) > Self.swipeDistance {
                step(dx < 0 ? 1 : -1)
            }
        }
    }

    /// The gallery's looks in its order, minus those this source can't run.
    private var browsableLooks: [ChainPreset] {
        SimpleCatalog.sections(model.chainPresets, order: SimpleCatalog.lookCategories) { $0.category ?? SimpleCatalog.userLooks }
            .flatMap(\.items)
            .filter { model.missingInput(for: $0) == nil }
    }

    /// Applies the look `offset` places from the current one, wrapping round; with no look
    /// applied, the first (or last).
    private func step(_ offset: Int) {
        let looks = browsableLooks
        guard !looks.isEmpty else { return }
        let target: ChainPreset
        if let index = looks.firstIndex(where: { $0.name == model.appliedLook }) {
            target = looks[(index + offset + looks.count) % looks.count]
        } else {
            target = offset > 0 ? looks[0] : looks[looks.count - 1]
        }
        if model.lookIsModified { pendingLook = target } else { model.load(chain: target, keepingStillInput: true) }
    }

    private func setFullScreen(_ on: Bool) {
        withAnimation(.snappy(duration: 0.25)) { isFullScreen = on }
    }
}

/// Toolbar button into full screen; the swipe's visible twin.
struct FullScreenButton: View {
    @Binding var isFullScreen: Bool

    var body: some View {
        Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
            withAnimation(.snappy(duration: 0.25)) { isFullScreen = true }
        }
    }
}

/// What a layout drops while its viewer is full screen: the navigation bar, the status bar, and
/// the light background.
struct FullScreenChrome: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .background { if isOn { Color.black.ignoresSafeArea() } }
            .toolbar(isOn ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(isOn)
            .persistentSystemOverlays(isOn ? .hidden : .automatic)
    }
}
