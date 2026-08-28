import AVFoundation
import CoreMedia
import Foundation
import OSLog

struct VideoMetadataLoader {
    private let logger = Logger(subsystem: "com.openvoicer.app", category: "video")

    func load(from url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        guard let videoTrack = videoTracks.first else {
            throw VideoImportError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let videoDescriptions = try await videoTrack.load(.formatDescriptions)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        var audioMetadata: [AudioTrackMetadata] = []
        for (index, track) in audioTracks.enumerated() {
            let language = try? await track.load(.extendedLanguageTag)
            let descriptions = try await track.load(.formatDescriptions)
            let formatDescription = descriptions.first
            let channelCount = formatDescription
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }
                .map { Int($0.pointee.mChannelsPerFrame) }

            audioMetadata.append(
                AudioTrackMetadata(
                    id: "audio-\(index)",
                    title: "Audio \(index + 1)",
                    languageCode: language,
                    codec: formatDescription.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) },
                    channelCount: channelCount
                )
            )
        }

        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            throw VideoImportError.invalidDuration
        }

        let metadata = VideoMetadata(
            duration: seconds,
            width: Int(abs(transformedRect.width.rounded())),
            height: Int(abs(transformedRect.height.rounded())),
            frameRate: frameRate > 0 ? Double(frameRate) : nil,
            videoCodec: videoDescriptions.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) },
            audioTracks: audioMetadata
        )
        logger.info("Loaded metadata for \(url.lastPathComponent, privacy: .public)")
        return metadata
    }

    private func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
    }
}

enum VideoImportError: LocalizedError {
    case noVideoTrack
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "The selected file does not contain a playable video track."
        case .invalidDuration:
            "The selected video has an invalid or unreadable duration."
        }
    }
}
