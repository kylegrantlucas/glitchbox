import AVKit
import SwiftUI

extension EnvironmentValues {
    /// False hides AVKit's transport controls (and their gestures) over the picture.
    @Entry var playerShowsControls = true
}

/// AVKit's player view controller, with the system transport controls.
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = false
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.showsPlaybackControls = context.environment.playerShowsControls
    }
}
