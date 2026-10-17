import AVFoundation
import Observation

/// Loops one proxy file in an `AVQueuePlayer`.
@Observable @MainActor
final class PlayerController {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var current: URL?

    func load(_ url: URL?) {
        guard url != current else { return }
        current = url
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        guard let url else { return }
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }
}
