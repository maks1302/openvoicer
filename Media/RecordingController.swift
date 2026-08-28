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
    @ObservationIgnored private var preparedDialoguePlayer: AVPlayer?
    @ObservationIgnored private var preparedBackgroundPlayer: AVPlayer?
    @ObservationIgnored private var preparedDialogueURL: URL?
    @ObservationIgnored private var preparedBackgroundURL: URL?
    @ObservationIgnored private var preparedSeekTask: Task<Void, Never>?
    @ObservationIgnored private var preparedDialogueRampTask: Task<Void, Never>?
    @ObservationIgnored private var preparedBackgroundRampTask: Task<Void, Never>?
    @ObservationIgnored private var playbackCompletionTask: Task<Void, Never>?
    @ObservationIgnored private var lastLiveSampleIndex = 0

    var isActive: Bool { state != .idle }
    var isRecording: Bool { state == .recording }
    var isPreparedMoviePlaying: Bool {
        preparedDialoguePlayer != nil && preparedBackgroundPlayer != nil
    }

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
            try await recorder.start(destinationURL: destinationURL, deviceID: deviceID) { [weak self] level, elapsed in
                Task { @MainActor in
                    self?.inputLevel = level
                    self?.isClipping = level >= 0.98
                    self?.appendLiveSample(level, at: elapsed)
                }
            }
            state = .recording
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
        stopTakePlayback()
        recorder.cancel()
        state = .idle
        inputLevel = 0
        isClipping = false
        recordingElapsed = 0
        liveWaveformSamples = []
        lastLiveSampleIndex = 0
    }

    func playTake(
        id: UUID,
        at url: URL,
        gain: Float,
        timelineDuration: TimeInterval? = nil,
        startOffset: TimeInterval = 0,
        fadeInDuration: TimeInterval = 0.015
    ) throws {
        stopTakePlayback()
        let player = try AVAudioPlayer(contentsOf: url)
        let targetVolume = min(max(gain, 0), 1)
        player.volume = fadeInDuration > 0 ? 0 : targetVolume
        player.currentTime = min(max(startOffset, 0), player.duration)
        player.prepareToPlay()
        guard player.play() else { throw RecordingPlaybackError.couldNotPlay }
        if fadeInDuration > 0 {
            player.setVolume(targetVolume, fadeDuration: fadeInDuration)
        }
        audioPlayer = player
        playingTakeID = id
        takePlaybackElapsed = player.currentTime
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
        backgroundGain: Float,
        startOffset: TimeInterval = 0,
        timelineDuration: TimeInterval? = nil,
        voiceFadeInDuration: TimeInterval = 0.015,
        backgroundFadeInDuration: TimeInterval = 0.015
    ) throws {
        stopTakePlayback()
        let voice = try AVAudioPlayer(contentsOf: takeURL)
        let background = try AVAudioPlayer(contentsOf: backgroundURL)
        let voiceTargetVolume = min(max(takeGain, 0), 1)
        let backgroundTargetVolume = min(max(backgroundGain, 0), 1)
        voice.volume = voiceFadeInDuration > 0 ? 0 : voiceTargetVolume
        background.volume = backgroundFadeInDuration > 0 ? 0 : backgroundTargetVolume
        voice.currentTime = min(max(startOffset, 0), voice.duration)
        background.currentTime = min(max(backgroundOffset + startOffset, 0), background.duration)
        voice.prepareToPlay()
        background.prepareToPlay()

        let deviceTime = max(voice.deviceCurrentTime, background.deviceCurrentTime) + 0.02
        let hasRemainingVoice = voice.currentTime < voice.duration - 0.01
        let voiceStarted = !hasRemainingVoice || voice.play(atTime: deviceTime)
        guard voiceStarted, background.play(atTime: deviceTime) else {
            throw RecordingPlaybackError.couldNotPlay
        }
        if hasRemainingVoice, voiceFadeInDuration > 0 {
            voice.setVolume(voiceTargetVolume, fadeDuration: voiceFadeInDuration)
        }
        if backgroundFadeInDuration > 0 {
            background.setVolume(backgroundTargetVolume, fadeDuration: backgroundFadeInDuration)
        }
        audioPlayer = hasRemainingVoice ? voice : nil
        backgroundPlayer = background
        playingTakeID = takeID
        takePlaybackElapsed = startOffset
        playbackCompletionTask = Task { [weak self] in
            let startedAt = ContinuousClock.now
            let remainingDuration = max((timelineDuration ?? voice.duration) - startOffset, 0)
            while !Task.isCancelled, startedAt.duration(to: .now) < .seconds(remainingDuration) {
                let elapsed = startedAt.duration(to: .now).components
                let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                self?.takePlaybackElapsed = min(startOffset + elapsedSeconds, timelineDuration ?? voice.duration)
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

    func transitionOutTakePlayback(
        voiceDuration: TimeInterval = 0.015,
        backgroundDuration: TimeInterval = 0.12
    ) {
        playbackCompletionTask?.cancel()
        playbackCompletionTask = nil
        let voice = audioPlayer
        let background = backgroundPlayer
        audioPlayer = nil
        backgroundPlayer = nil
        playingTakeID = nil
        takePlaybackElapsed = 0

        voice?.setVolume(0, fadeDuration: voiceDuration)
        background?.setVolume(0, fadeDuration: backgroundDuration)
        let stopDelay = max(voiceDuration, backgroundDuration)
        Task {
            try? await Task.sleep(for: .seconds(stopDelay))
            voice?.stop()
            background?.stop()
        }
    }

    func startPreparedMoviePlayback(
        dialogueURL: URL,
        backgroundURL: URL,
        at timelineTime: TimeInterval,
        dialogueGain: Float,
        backgroundGain: Float
    ) {
        if preparedDialogueURL == dialogueURL,
           preparedBackgroundURL == backgroundURL,
           isPreparedMoviePlaying {
            synchronizePreparedMoviePlayback(to: timelineTime)
            setPreparedMovieVolumes(
                dialogue: dialogueGain,
                background: backgroundGain,
                fadeDuration: 0
            )
            return
        }

        stopPreparedMoviePlayback()
        let dialogue = AVPlayer(url: dialogueURL)
        let background = AVPlayer(url: backgroundURL)
        dialogue.volume = min(max(dialogueGain, 0), 1)
        background.volume = min(max(backgroundGain, 0), 1)
        preparedDialoguePlayer = dialogue
        preparedBackgroundPlayer = background
        preparedDialogueURL = dialogueURL
        preparedBackgroundURL = backgroundURL
        seekAndPlayPreparedMovie(to: timelineTime)
    }

    func synchronizePreparedMoviePlayback(to timelineTime: TimeInterval) {
        guard preparedSeekTask == nil,
              let dialogue = preparedDialoguePlayer,
              let background = preparedBackgroundPlayer else { return }
        let dialogueTime = dialogue.currentTime().seconds
        let backgroundTime = background.currentTime().seconds
        guard !dialogueTime.isFinite
                || !backgroundTime.isFinite
                || abs(dialogueTime - timelineTime) > 0.12
                || abs(backgroundTime - timelineTime) > 0.12 else { return }
        seekAndPlayPreparedMovie(to: timelineTime)
    }

    func setPreparedMovieVolumes(
        dialogue: Float,
        background: Float,
        fadeDuration: TimeInterval
    ) {
        rampPreparedPlayer(
            preparedDialoguePlayer,
            to: dialogue,
            duration: fadeDuration,
            task: &preparedDialogueRampTask
        )
        rampPreparedPlayer(
            preparedBackgroundPlayer,
            to: background,
            duration: fadeDuration,
            task: &preparedBackgroundRampTask
        )
    }

    func stopPreparedMoviePlayback() {
        preparedSeekTask?.cancel()
        preparedDialogueRampTask?.cancel()
        preparedBackgroundRampTask?.cancel()
        preparedSeekTask = nil
        preparedDialogueRampTask = nil
        preparedBackgroundRampTask = nil
        preparedDialoguePlayer?.pause()
        preparedBackgroundPlayer?.pause()
        preparedDialoguePlayer = nil
        preparedBackgroundPlayer = nil
        preparedDialogueURL = nil
        preparedBackgroundURL = nil
    }

    private func seekAndPlayPreparedMovie(to timelineTime: TimeInterval) {
        preparedSeekTask?.cancel()
        guard let dialogue = preparedDialoguePlayer,
              let background = preparedBackgroundPlayer else { return }
        let target = CMTime(seconds: max(timelineTime, 0), preferredTimescale: 48_000)
        preparedSeekTask = Task { [weak self] in
            await dialogue.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            await background.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled,
                  self?.preparedDialoguePlayer === dialogue,
                  self?.preparedBackgroundPlayer === background else { return }
            dialogue.play()
            background.play()
            self?.preparedSeekTask = nil
        }
    }

    private func rampPreparedPlayer(
        _ player: AVPlayer?,
        to target: Float,
        duration: TimeInterval,
        task: inout Task<Void, Never>?
    ) {
        task?.cancel()
        guard let player else {
            task = nil
            return
        }
        let clampedTarget = min(max(target, 0), 1)
        let start = player.volume
        guard duration > 0, abs(start - clampedTarget) > 0.001 else {
            player.volume = clampedTarget
            task = nil
            return
        }
        task = Task {
            let steps = 8
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
                guard !Task.isCancelled else { return }
                let fraction = Float(step) / Float(steps)
                player.volume = start + (clampedTarget - start) * fraction
            }
        }
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
