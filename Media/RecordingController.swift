import AVFoundation
import Observation

@MainActor
@Observable
final class RecordingController {
    enum State: Equatable {
        case idle
        case countdown(Int)
        case recording
        case finishing
    }

    private(set) var state: State = .idle
    private(set) var inputLevel: Float = 0
    private(set) var isClipping = false
    private(set) var playingTakeID: UUID?
    private(set) var liveWaveformSamples: [Float] = []
    private(set) var recordingElapsed: TimeInterval = 0
    private(set) var recordingTimelineDuration: TimeInterval = 1
    private(set) var takePlaybackElapsed: TimeInterval = 0
    let devices = AudioDeviceManager()

    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var backgroundPlayer: AVAudioPlayer?
    @ObservationIgnored private var playbackCompletionTask: Task<Void, Never>?
    @ObservationIgnored private var lastLiveSampleIndex = 0

    var isActive: Bool { state != .idle }
    var isRecording: Bool { state == .recording }

    func begin(
        destinationURL: URL,
        deviceID: String?,
        countdownSeconds: Int,
        timelineDuration: TimeInterval
    ) async throws {
        guard state == .idle else { return }
        stopTakePlayback()

        guard await requestMicrophoneAccess() else {
            throw AudioRecorderError.permissionDenied
        }
        devices.refresh()
        recordingTimelineDuration = max(timelineDuration, 0.1)
        recordingElapsed = 0
        liveWaveformSamples = Array(repeating: 0, count: 600)
        lastLiveSampleIndex = 0

        do {
            if countdownSeconds > 0 {
                for value in stride(from: countdownSeconds, through: 1, by: -1) {
                    state = .countdown(value)
                    try await Task.sleep(for: .seconds(1))
                }
            }

            try Task.checkCancellation()
            state = .recording
            try await recorder.start(destinationURL: destinationURL, deviceID: deviceID) { [weak self] level, elapsed in
                Task { @MainActor in
                    self?.inputLevel = level
                    self?.isClipping = level >= 0.98
                    self?.appendLiveSample(level, at: elapsed)
                }
            }
        } catch {
            state = .idle
            throw error
        }
    }

    func stop() async throws -> AudioRecordingResult {
        guard state == .recording else { throw AudioRecorderError.notRecording }
        state = .finishing
        defer {
            state = .idle
            inputLevel = 0
            isClipping = false
        }
        return try await recorder.stop()
    }

    func cancel() {
        recorder.cancel()
        state = .idle
        inputLevel = 0
        isClipping = false
        recordingElapsed = 0
        liveWaveformSamples = []
        lastLiveSampleIndex = 0
    }

    func playTake(id: UUID, at url: URL, gain: Float, timelineDuration: TimeInterval? = nil) throws {
        stopTakePlayback()
        let player = try AVAudioPlayer(contentsOf: url)
        player.volume = min(max(gain, 0), 1)
        player.prepareToPlay()
        guard player.play() else { throw RecordingPlaybackError.couldNotPlay }
        audioPlayer = player
        playingTakeID = id
        takePlaybackElapsed = 0
        playbackCompletionTask = Task { [weak self] in
            while !Task.isCancelled, player.isPlaying {
                self?.takePlaybackElapsed = min(
                    player.currentTime,
                    timelineDuration ?? player.duration
                )
                try? await Task.sleep(for: .milliseconds(33))
            }
            guard !Task.isCancelled, self?.playingTakeID == id else { return }
            self?.audioPlayer = nil
            self?.playingTakeID = nil
            self?.takePlaybackElapsed = 0
        }
    }

    func playSeparatedPreview(
        takeID: UUID,
        takeURL: URL,
        takeGain: Float,
        backgroundURL: URL,
        backgroundOffset: TimeInterval,
        backgroundGain: Float
    ) throws {
        stopTakePlayback()
        let voice = try AVAudioPlayer(contentsOf: takeURL)
        let background = try AVAudioPlayer(contentsOf: backgroundURL)
        voice.volume = min(max(takeGain, 0), 1)
        background.volume = min(max(backgroundGain, 0), 1)
        background.currentTime = min(max(backgroundOffset, 0), background.duration)
        voice.prepareToPlay()
        background.prepareToPlay()

        let deviceTime = max(voice.deviceCurrentTime, background.deviceCurrentTime) + 0.02
        guard voice.play(atTime: deviceTime), background.play(atTime: deviceTime) else {
            throw RecordingPlaybackError.couldNotPlay
        }
        audioPlayer = voice
        backgroundPlayer = background
        playingTakeID = takeID
        takePlaybackElapsed = 0
        playbackCompletionTask = Task { [weak self] in
            while !Task.isCancelled, voice.isPlaying {
                self?.takePlaybackElapsed = voice.currentTime
                try? await Task.sleep(for: .milliseconds(33))
            }
            guard !Task.isCancelled, self?.playingTakeID == takeID else { return }
            self?.stopTakePlayback()
        }
    }

    func stopTakePlayback() {
        playbackCompletionTask?.cancel()
        playbackCompletionTask = nil
        audioPlayer?.stop()
        backgroundPlayer?.stop()
        audioPlayer = nil
        backgroundPlayer = nil
        playingTakeID = nil
        takePlaybackElapsed = 0
    }

    private func appendLiveSample(_ level: Float, at elapsed: TimeInterval) {
        recordingElapsed = elapsed
        guard !liveWaveformSamples.isEmpty else { return }
        let fraction = min(max(elapsed / recordingTimelineDuration, 0), 1)
        let index = min(Int(fraction * Double(liveWaveformSamples.count)), liveWaveformSamples.count - 1)
        var samples = liveWaveformSamples
        if index >= lastLiveSampleIndex {
            for sampleIndex in lastLiveSampleIndex...index {
                samples[sampleIndex] = max(samples[sampleIndex], level)
            }
        } else {
            samples[index] = max(samples[index], level)
        }
        lastLiveSampleIndex = index
        liveWaveformSamples = samples
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        default:
            false
        }
    }
}

enum RecordingPlaybackError: LocalizedError {
    case couldNotPlay

    var errorDescription: String? {
        "The selected recording could not be played."
    }
}
