import AVKit
import SwiftUI

/// AppKit player view. SwiftUI's `VideoPlayer` aborts during `_AVKit_SwiftUI`
/// metadata initialization on macOS 27.0.1, so the app hosts `AVPlayerView`.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        // The video's natural size must not drive the split view's minimum size;
        // otherwise AppKit loops on update-constraints passes and throws.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentHuggingPriority(.init(1), for: orientation)
            view.setContentCompressionResistancePriority(.init(1), for: orientation)
        }
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
