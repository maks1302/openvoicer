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
    let devices = AudioDeviceManager()

    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?

    var isActive: Bool { state != .idle }
    var isRecording: Bool { state == .recording }

    func begin(destinationURL: URL, deviceID: String?, countdownSeconds: Int) async throws {
        guard state == .idle else { return }
        stopTakePlayback()

        guard await requestMicrophoneAccess() else {
            throw AudioRecorderError.permissionDenied
        }
        devices.refresh()

        do {
            if countdownSeconds > 0 {
                for value in stride(from: countdownSeconds, through: 1, by: -1) {
                    state = .countdown(value)
                    try await Task.sleep(for: .seconds(1))
                }
            }

            try Task.checkCancellation()
            state = .recording
            try await recorder.start(destinationURL: destinationURL, deviceID: deviceID) { [weak self] level in
                Task { @MainActor in
                    self?.inputLevel = level
                    self?.isClipping = level >= 0.98
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
    }

    func playTake(id: UUID, at url: URL, gain: Float) throws {
        stopTakePlayback()
        let player = try AVAudioPlayer(contentsOf: url)
        player.volume = min(max(gain, 0), 1)
        player.prepareToPlay()
        guard player.play() else { throw RecordingPlaybackError.couldNotPlay }
        audioPlayer = player
        playingTakeID = id
    }

    func stopTakePlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingTakeID = nil
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
