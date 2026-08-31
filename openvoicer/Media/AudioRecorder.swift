import AVFoundation
import AudioToolbox
import CoreAudio
import OSLog

struct AudioRecordingResult: Sendable {
    let url: URL
    let duration: TimeInterval
}

final class AudioRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.openvoicer.recording.engine", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.openvoicer.app", category: "recording")

    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingError: Error?
    private var destinationURL: URL?
    private var hasInputTap = false
    private var recordedFrames: AVAudioFramePosition = 0
    private var recordingSampleRate = 0.0
    private var meterHandler: (@Sendable (Float, TimeInterval) -> Void)?

    func start(
        destinationURL: URL,
        deviceID: String?,
        meterHandler: @escaping @Sendable (Float, TimeInterval) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try configureAndStart(
                        destinationURL: destinationURL,
                        deviceID: deviceID,
                        meterHandler: meterHandler
                    )
                    continuation.resume()
                } catch {
                    tearDownRecording()
                    try? FileManager.default.removeItem(at: destinationURL)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws -> AudioRecordingResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let destinationURL else {
                    continuation.resume(throwing: AudioRecorderError.notRecording)
                    return
                }

                stopEngine()
                if let recordingError {
                    tearDownRecording()
                    try? FileManager.default.removeItem(at: destinationURL)
                    continuation.resume(throwing: recordingError)
                    return
                }

                guard recordedFrames > 0, recordingSampleRate > 0 else {
                    tearDownRecording()
                    try? FileManager.default.removeItem(at: destinationURL)
                    continuation.resume(throwing: AudioRecorderError.noAudioCaptured)
                    return
                }

                let duration = Double(recordedFrames) / recordingSampleRate
                // Releasing AVAudioFile finalizes the WAV header before playback begins.
                audioFile = nil
                tearDownRecording()
                continuation.resume(returning: AudioRecordingResult(url: destinationURL, duration: duration))
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            let incompleteURL = destinationURL
            stopEngine()
            tearDownRecording()
            if let incompleteURL {
                try? FileManager.default.removeItem(at: incompleteURL)
            }
        }
    }

    private func configureAndStart(
        destinationURL: URL,
        deviceID: String?,
        meterHandler: @escaping @Sendable (Float, TimeInterval) -> Void
    ) throws {
        guard engine == nil else { throw AudioRecorderError.alreadyRecording }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        if let deviceID {
            try selectInputDevice(withUID: deviceID, on: inputNode)
        }
        let hardwareFormat = try hardwareInputFormat(for: inputNode)

        engine = audioEngine
        audioFile = nil
        recordingError = nil
        self.destinationURL = destinationURL
        self.meterHandler = meterHandler
        recordedFrames = 0
        recordingSampleRate = 0

        // outputFormat(forBus:) can remain cached at the previous device's
        // sample rate after switching AUHAL devices. Read the stream format
        // from the audio unit itself so the tap exactly matches the hardware.
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: hardwareFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        hasInputTap = true

        audioEngine.prepare()
        try audioEngine.start()
        logger.info("Audio engine recording started")
    }

    private func hardwareInputFormat(for inputNode: AVAudioInputNode) throws -> AVAudioFormat {
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioRecorderError.couldNotSelectDevice("The audio input unit is unavailable.")
        }

        var description = AudioStreamBasicDescription()
        var byteCount = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            // AUHAL input element 1 receives data from the physical device on
            // its input scope. Its output scope is the client-side format and
            // can still contain the previous device's sample rate.
            kAudioUnitScope_Input,
            1,
            &description,
            &byteCount
        )
        guard status == noErr,
              description.mSampleRate > 0,
              description.mChannelsPerFrame > 0 else {
            throw AudioRecorderError.unsupportedAudioFormatDetails(
                "Core Audio could not read the hardware input format (status \(status))."
            )
        }

        // Some USB drivers describe a stereo hardware stream as interleaved
        // even though AUHAL delivers two buffers. Build an explicit planar
        // Float32 client format so mNumberBuffers and NumberChannelStreams agree.
        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: description.mSampleRate,
            channels: AVAudioChannelCount(description.mChannelsPerFrame),
            interleaved: false
        ) else {
            throw AudioRecorderError.unsupportedAudioFormatDetails(
                "Core Audio could not create a planar input format."
            )
        }
        var clientDescription = clientFormat.streamDescription.pointee

        // Synchronize AUHAL's client side before AVAudioEngine creates its tap.
        let synchronizationStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &clientDescription,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard synchronizationStatus == noErr else {
            throw AudioRecorderError.unsupportedAudioFormatDetails(
                "Core Audio could not synchronize the input format (status \(synchronizationStatus))."
            )
        }

        logger.info("Selected hardware format: \(description.mChannelsPerFrame) channel(s)")
        logger.info("Selected hardware rate: \(description.mSampleRate, privacy: .public) Hz")
        return clientFormat
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard recordingError == nil else { return }
        do {
            if audioFile == nil {
                guard let destinationURL,
                      buffer.format.sampleRate > 0,
                      buffer.format.channelCount > 0 else {
                    throw AudioRecorderError.unsupportedAudioFormatDetails(
                        "The audio engine returned an invalid hardware format."
                    )
                }
                audioFile = try AVAudioFile(
                    forWriting: destinationURL,
                    settings: buffer.format.settings
                )
                recordingSampleRate = buffer.format.sampleRate
                let channelCount = buffer.format.channelCount
                let sampleRate = buffer.format.sampleRate
                logger.info("Hardware input: \(channelCount) channel(s)")
                logger.info("Hardware sample rate: \(sampleRate, privacy: .public) Hz")
            }
            try audioFile?.write(from: buffer)
            recordedFrames += AVAudioFramePosition(buffer.frameLength)
            let elapsed = Double(recordedFrames) / recordingSampleRate
            meterHandler?(peakLevel(in: buffer), elapsed)
        } catch {
            recordingError = error
            logger.error("Audio engine could not write microphone PCM: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func peakLevel(in buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return 0 }
        var peak: Float = 0
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audioBuffer.mData else { continue }
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<count {
                peak = max(peak, abs(samples[index]))
            }
        }
        return min(peak, 1)
    }

    private func selectInputDevice(withUID uid: String, on inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioRecorderError.couldNotSelectDevice("The audio input unit is unavailable.")
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var qualifier = uid as CFString
        let lookupStatus = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                qualifierPointer,
                &outputSize,
                &deviceID
            )
        }
        guard lookupStatus == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioRecorderError.couldNotSelectDevice(
                "Core Audio could not resolve the selected device (status \(lookupStatus))."
            )
        }

        let selectionStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard selectionStatus == noErr else {
            throw AudioRecorderError.couldNotSelectDevice(
                "Core Audio could not activate the selected device (status \(selectionStatus))."
            )
        }
    }

    private func stopEngine() {
        if hasInputTap {
            engine?.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        engine?.stop()
    }

    private func tearDownRecording() {
        stopEngine()
        engine = nil
        audioFile = nil
        recordingError = nil
        destinationURL = nil
        recordedFrames = 0
        recordingSampleRate = 0
        meterHandler = nil
    }
}

enum AudioRecorderError: LocalizedError {
    case microphoneUnavailable
    case permissionDenied
    case alreadyRecording
    case notRecording
    case noAudioCaptured
    case unsupportedAudioFormat
    case unsupportedAudioFormatDetails(String)
    case couldNotReadSamples(OSStatus)
    case couldNotSelectDevice(String)
    case couldNotStart
    case couldNotFinish

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: "The selected microphone is not available."
        case .permissionDenied: "Microphone permission was denied. Enable OpenVoicer in System Settings → Privacy & Security → Microphone."
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "No recording is currently in progress."
        case .noAudioCaptured: "No microphone audio was captured."
        case .unsupportedAudioFormat: "The microphone audio format could not be recorded."
        case .unsupportedAudioFormatDetails(let details): "The microphone audio format could not be recorded. \(details)"
        case .couldNotReadSamples(let status): "The microphone samples could not be read (Core Audio \(status))."
        case .couldNotSelectDevice(let details): "The selected microphone could not be activated. \(details)"
        case .couldNotStart: "The microphone recording could not be started."
        case .couldNotFinish: "The microphone recording could not be saved."
        }
    }
}
