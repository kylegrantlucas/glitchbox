import SwiftUI

/// Simple mode on the Mac and in wide iPad windows: looks, the effects of the chosen look,
/// and the viewer side by side. A plain HStack: `NavigationSplitView` and `.inspector` both
/// have layout faults on macOS 27 (see AGENTS.md), and nothing here collapses. On iPad the
/// viewer can take the whole window for swiping through looks (`LookSwipeViewer`).
struct SimpleWideView: View {
    #if os(iOS)
    @State private var isFullScreen = false
    #endif

    var body: some View {
        #if os(iOS)
        NavigationStack {
            HStack(spacing: 0) {
                if !isFullScreen { panels }
                LookSwipeViewer(isFullScreen: $isFullScreen)
            }
            .modifier(FullScreenChrome(isOn: isFullScreen))
            .navigationTitle("Glitchbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SimpleToolbar()
                ToolbarItem(placement: .topBarTrailing) { FullScreenButton(isFullScreen: $isFullScreen) }
                ToolbarItem(placement: .secondaryAction) { StudioMoreMenu() }
            }
        }
        #else
        HStack(spacing: 0) {
            panels
            ViewerView()
        }
        .toolbar { SimpleToolbar() }
        #endif
    }

    /// The looks gallery and the effect cards, each with its trailing divider.
    @ViewBuilder private var panels: some View {
        LooksGallery()
            .frame(width: 280)
        Divider()
        VStack(spacing: 0) {
            SourceSection()
            Divider()
            StillSuggestionView()
            SimpleEffectList()
            NoticesView()
            ExportOutcomeView()
        }
        .frame(width: 340)
        Divider()
    }
}
