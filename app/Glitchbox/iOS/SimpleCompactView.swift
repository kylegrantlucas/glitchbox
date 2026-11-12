import SwiftUI

/// Simple mode on iPhone and in narrow iPad windows: the viewer over the source, then the
/// looks or the chosen look's effects. Modes switch from the More menu; the bar has no room
/// for a segmented control. The viewer goes full screen for swiping through looks
/// (`LookSwipeViewer`); everything under it is hidden meanwhile.
struct SimpleCompactView: View {
    private enum Tab { case looks, adjust }

    @State private var tab = Tab.looks
    @State private var isFullScreen = false

    var body: some View {
        NavigationStack {
            // One viewer in both states, resized rather than swapped, so playback carries through.
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    LookSwipeViewer(isFullScreen: $isFullScreen)
                        .frame(height: isFullScreen ? geometry.size.height : geometry.size.width * 9 / 16)
                    if !isFullScreen {
                        Divider()
                        SourceSection()
                        Picker("Show", selection: $tab) {
                            Text("Looks").tag(Tab.looks)
                            Text("Adjust").tag(Tab.adjust)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        switch tab {
                        case .looks:
                            LooksGallery()
                        case .adjust:
                            StillSuggestionView()
                            SimpleEffectList()
                        }
                        NoticesView()
                        ExportOutcomeView()
                    }
                }
            }
            .modifier(FullScreenChrome(isOn: isFullScreen))
            .navigationTitle("Glitchbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { StudioMoreMenu() }
                SimpleToolbar()
                ToolbarItem(placement: .topBarTrailing) { FullScreenButton(isFullScreen: $isFullScreen) }
            }
        }
    }
}
