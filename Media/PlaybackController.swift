import AVFoundation
import Observation

@MainActor
@Observable
final class PlaybackController {
    let player = AVPlayer()
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false

    @ObservationIgnored private var periodicTimeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var boundaryTimeObserver: Any?

    init() {
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
    }

    isolated deinit {
        if let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let boundaryTimeObserver {
            player.removeTimeObserver(boundaryTimeObserver)
        }
    }

    func load(url: URL, duration: TimeInterval) {
        cancelBoundedPlayback()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        currentTime = 0
        self.duration = duration
        isPlaying = false
    }

    func clear() {
        cancelBoundedPlayback()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTime = 0
        duration = 0
        isPlaying = false
    }

    func togglePlayback() {
        cancelBoundedPlayback()
        if isPlaying {
            pause()
        } else {
            if duration > 0, currentTime >= duration - 0.1 {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        cancelBoundedPlayback()
        seekWithoutCancelling(to: seconds)
    }

    func play(from startTime: TimeInterval, to endTime: TimeInterval) {
        guard endTime > startTime else { return }
        cancelBoundedPlayback()
        pause()

        let end = min(endTime, duration)
        boundaryTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))],
            queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.pause()
                self?.cancelBoundedPlayback()
            }
        }
        seekWithoutCancelling(to: startTime)
        player.play()
        isPlaying = true
    }

    private func seekWithoutCancelling(to seconds: TimeInterval) {
        let target = min(max(seconds, 0), duration)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = target
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    private func cancelBoundedPlayback() {
        if let boundaryTimeObserver {
            player.removeTimeObserver(boundaryTimeObserver)
            self.boundaryTimeObserver = nil
        }
    }
}
