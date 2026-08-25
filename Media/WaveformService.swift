import AVFoundation
import Foundation

actor WaveformService {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func samples(
        from audioURL: URL,
        timeRange: Range<TimeInterval>,
        sampleCount: Int,
        cacheURL: URL
    ) async throws -> [Float] {
        if let cached = try? Data(contentsOf: cacheURL),
           let samples = try? decoder.decode([Float].self, from: cached),
           samples.count == sampleCount {
            return samples
        }

        let samples = try await renderSamples(
            from: audioURL,
            timeRange: timeRange,
            sampleCount: sampleCount
        )
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(samples).write(to: cacheURL, options: .atomic)
        return samples
    }

    private func renderSamples(
        from audioURL: URL,
        timeRange: Range<TimeInterval>,
        sampleCount: Int
    ) async throws -> [Float] {
        guard sampleCount > 0, timeRange.upperBound > timeRange.lowerBound else { return [] }
        let asset = AVURLAsset(url: audioURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WaveformError.audioTrackMissing
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: timeRange.lowerBound, preferredTimescale: 48_000),
            duration: CMTime(seconds: timeRange.upperBound - timeRange.lowerBound, preferredTimescale: 48_000)
        )
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WaveformError.unsupportedAudioFormat }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? WaveformError.couldNotReadAudio
        }

        let estimatedSamples = max(Int((timeRange.upperBound - timeRange.lowerBound) * 48_000), 1)
        var peaks = Array(repeating: Float.zero, count: sampleCount)
        var consumedSamples = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            var bytes = Data(count: byteCount)
            let status = bytes.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: buffer.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr else { continue }

            bytes.withUnsafeBytes { buffer in
                let values = buffer.bindMemory(to: Int16.self)
                for value in values {
                    let bin = min(consumedSamples * sampleCount / estimatedSamples, sampleCount - 1)
                    let amplitude = abs(Float(value) / Float(Int16.max))
                    peaks[bin] = max(peaks[bin], amplitude)
                    consumedSamples += 1
                }
            }
        }

        guard reader.status == .completed else {
            throw reader.error ?? WaveformError.couldNotReadAudio
        }
        guard let maximum = peaks.max(), maximum > 0 else { return peaks }
        return peaks.map { sqrt($0 / maximum) }
    }
}

enum WaveformError: LocalizedError {
    case audioTrackMissing
    case unsupportedAudioFormat
    case couldNotReadAudio

    var errorDescription: String? {
        switch self {
        case .audioTrackMissing: "No audio track was found for the waveform."
        case .unsupportedAudioFormat: "This audio format cannot be visualized."
        case .couldNotReadAudio: "The audio waveform could not be generated."
        }
    }
}
