import AVFoundation
import OSLog

struct AudioRecordingResult: Sendable {
    let url: URL
    let duration: TimeInterval
}

final class AudioRecorder: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.openvoicer.recording.capture", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.openvoicer.app", category: "recording")

    private var session: AVCaptureSession?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var destinationURL: URL?
    private var firstSampleTime: CMTime?
    private var lastSampleTime: CMTime?
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
                    tearDownCapture()
                    try? FileManager.default.removeItem(at: destinationURL)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws -> AudioRecordingResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let writer, let writerInput, let destinationURL else {
                    continuation.resume(throwing: AudioRecorderError.notRecording)
                    return
                }

                session?.stopRunning()
                writerInput.markAsFinished()

                guard firstSampleTime != nil else {
                    writer.cancelWriting()
                    tearDownCapture()
                    continuation.resume(throwing: AudioRecorderError.noAudioCaptured)
                    return
                }

                let duration = max(0, CMTimeGetSeconds(lastSampleTime ?? .zero) - CMTimeGetSeconds(firstSampleTime ?? .zero))
                writer.finishWriting { [self] in
                    queue.async { [self] in
                        let status = self.writer?.status
                        let error = self.writer?.error
                        tearDownCapture()

                        if status == AVAssetWriter.Status.completed {
                            continuation.resume(returning: AudioRecordingResult(url: destinationURL, duration: duration))
                        } else {
                            continuation.resume(throwing: error ?? AudioRecorderError.couldNotFinish)
                        }
                    }
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            session?.stopRunning()
            writer?.cancelWriting()
            tearDownCapture()
        }
    }

    private func configureAndStart(
        destinationURL: URL,
        deviceID: String?,
        meterHandler: @escaping @Sendable (Float, TimeInterval) -> Void
    ) throws {
        guard session == nil else { throw AudioRecorderError.alreadyRecording }
        guard let device = AudioDeviceManager.captureDevice(withID: deviceID) else {
            throw AudioRecorderError.microphoneUnavailable
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let captureSession = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else { throw AudioRecorderError.microphoneUnavailable }
        captureSession.addInput(input)

        let output = AVCaptureAudioDataOutput()
        guard captureSession.canAddOutput(output) else { throw AudioRecorderError.microphoneUnavailable }
        captureSession.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)

        let assetWriter = try AVAssetWriter(outputURL: destinationURL, fileType: .wav)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let assetWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        assetWriterInput.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(assetWriterInput) else { throw AudioRecorderError.unsupportedAudioFormat }
        assetWriter.add(assetWriterInput)
        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? AudioRecorderError.couldNotStart
        }

        session = captureSession
        writer = assetWriter
        writerInput = assetWriterInput
        self.destinationURL = destinationURL
        self.meterHandler = meterHandler
        firstSampleTime = nil
        lastSampleTime = nil
        captureSession.startRunning()
        logger.info("Started recording with (device.localizedName, privacy: .public)")
    }

    private func tearDownCapture() {
        session = nil
        writer = nil
        writerInput = nil
        destinationURL = nil
        firstSampleTime = nil
        lastSampleTime = nil
        meterHandler = nil
    }
}

extension AudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let writer, let writerInput else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if firstSampleTime == nil {
            firstSampleTime = presentationTime
            writer.startSession(atSourceTime: presentationTime)
        }

        if writerInput.isReadyForMoreMediaData, writerInput.append(sampleBuffer) {
            lastSampleTime = CMTimeAdd(presentationTime, sampleDuration(for: sampleBuffer))
        }

        let decibels = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
        let normalizedLevel = min(max(pow(10, decibels / 20), 0), 1)
        let elapsed = max(
            0,
            CMTimeGetSeconds(lastSampleTime ?? presentationTime)
                - CMTimeGetSeconds(firstSampleTime ?? presentationTime)
        )
        meterHandler?(normalizedLevel, elapsed)
    }

    private func sampleDuration(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let declaredDuration = CMSampleBufferGetDuration(sampleBuffer)
        if declaredDuration.isValid, declaredDuration.isNumeric, declaredDuration > .zero {
            return declaredDuration
        }

        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              streamDescription.pointee.mSampleRate > 0 else { return .zero }
        return CMTime(
            seconds: Double(CMSampleBufferGetNumSamples(sampleBuffer)) / streamDescription.pointee.mSampleRate,
            preferredTimescale: 48_000
        )
    }
}

enum AudioRecorderError: LocalizedError {
    case microphoneUnavailable
    case permissionDenied
    case alreadyRecording
    case notRecording
    case noAudioCaptured
    case unsupportedAudioFormat
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
        case .couldNotStart: "The microphone recording could not be started."
        case .couldNotFinish: "The microphone recording could not be saved."
        }
    }
}
