import AVFoundation
import Observation

@MainActor
@Observable
final class PlaybackController {
    let player = AVPlayer()
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var sourceURL: URL?

    @ObservationIgnored private var periodicTimeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var boundaryTimeObserver: Any?
    @ObservationIgnored var onPlaybackStopped: (@MainActor @Sendable () -> Void)?

    init() {
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
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
        sourceURL = url
        isPlaying = false
    }

    func selectAudioTrack(at index: Int) async throws {
        guard let item = player.currentItem,
              let group = try await item.asset.loadMediaSelectionGroup(for: .audible),
              group.options.indices.contains(index) else { return }
        item.select(group.options[index], in: group)
    }

    func clear() {
        cancelBoundedPlayback()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTime = 0
        duration = 0
        sourceURL = nil
        isPlaying = false
    }

    func togglePlayback() {
        cancelBoundedPlayback()
        if isPlaying {
            pause()
        } else {
            onPlaybackStopped?()
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
        onPlaybackStopped?()
    }

    func seek(to seconds: TimeInterval) {
        cancelBoundedPlayback()
        onPlaybackStopped?()
        seekWithoutCancelling(to: seconds)
    }

    func play(
        from startTime: TimeInterval,
        to endTime: TimeInterval,
        onPlaybackStarted: (@MainActor @Sendable () -> Void)? = nil
    ) {
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
        seekWithoutCancelling(to: startTime) { [weak self] finished in
            guard finished, let self else { return }
            self.player.play()
            self.isPlaying = true
            onPlaybackStarted?()
        }
    }

    private func seekWithoutCancelling(
        to seconds: TimeInterval,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let target = min(max(seconds, 0), duration)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { finished in
            guard let completion else { return }
            Task { @MainActor in completion(finished) }
        }
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
