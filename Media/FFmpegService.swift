import Foundation
import OSLog

actor FFmpegService {
    private let logger = Logger(subsystem: "com.dublab.app", category: "ffmpeg")

    func createPlaybackCopy(source: URL, destination: URL) async throws {
        guard let executableURL = Self.findExecutable(named: "ffmpeg") else {
            throw FFmpegError.notInstalled
        }

        let logURL = destination.deletingLastPathComponent().appending(path: "ffmpeg-remux.log")
        let arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", "pipe:0",
            "-map", "0:v:0",
            "-map", "0:a?",
            "-map_metadata", "0",
            "-c", "copy",
            "-sn",
            "-f", "mov",
            "-movflags", "+frag_keyframe+empty_moov+default_base_moof+delay_moov",
            "pipe:1"
        ]

        logger.info("Creating an AVFoundation-compatible playback copy")
        let result = try await Task.detached(priority: .userInitiated) {
            try MediaProcess.run(
                executableURL: executableURL,
                arguments: arguments,
                inputURL: source,
                outputURL: destination,
                logURL: logURL
            )
        }.value

        guard result.exitCode == 0 else {
            logger.error("FFmpeg remux failed with exit code \(result.exitCode)")
            throw FFmpegError.processFailed(details: result.errorSummary)
        }
    }

    func embeddedSubtitleTracks(in source: URL) async throws -> [EmbeddedSubtitleTrack] {
        guard let executableURL = Self.findExecutable(named: "ffprobe") else {
            throw FFmpegError.notInstalled
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "DubLab-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let outputURL = temporaryDirectory.appending(path: "subtitle-tracks.json")
        let logURL = temporaryDirectory.appending(path: "ffprobe.log")
        let arguments = [
            "-v", "error",
            "-select_streams", "s",
            "-show_entries", "stream=index,codec_name:stream_tags=language,title",
            "-of", "json",
            "-i", "pipe:0"
        ]

        let result = try await Task.detached(priority: .utility) {
            try MediaProcess.run(
                executableURL: executableURL,
                arguments: arguments,
                inputURL: source,
                outputURL: outputURL,
                logURL: logURL
            )
        }.value
        guard result.exitCode == 0 else {
            throw FFmpegError.probeFailed
        }

        let data = try Data(contentsOf: outputURL)
        let probe = try JSONDecoder().decode(FFprobeSubtitleOutput.self, from: data)
        return probe.streams.map {
            EmbeddedSubtitleTrack(
                streamIndex: $0.index,
                codec: $0.codecName,
                languageCode: $0.tags?.language,
                title: $0.tags?.title
            )
        }
    }

    func extractSubtitleTrack(
        _ track: EmbeddedSubtitleTrack,
        from source: URL,
        destination: URL
    ) async throws {
        guard track.isTextBased else { throw FFmpegError.unsupportedSubtitleCodec(track.codec) }
        guard let executableURL = Self.findExecutable(named: "ffmpeg") else {
            throw FFmpegError.notInstalled
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let logURL = destination.deletingLastPathComponent().appending(path: "ffmpeg-subtitles.log")
        let arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-i", "pipe:0",
            "-map", "0:\(track.streamIndex)",
            "-f", "srt",
            "pipe:1"
        ]

        let result = try await Task.detached(priority: .userInitiated) {
            try MediaProcess.run(
                executableURL: executableURL,
                arguments: arguments,
                inputURL: source,
                outputURL: destination,
                logURL: logURL
            )
        }.value
        guard result.exitCode == 0 else {
            throw FFmpegError.subtitleExtractionFailed
        }
    }

    func extractAudioSegment(
        from source: URL,
        startTime: TimeInterval,
        duration: TimeInterval,
        audioTrackIndex: Int,
        preserveMultichannel: Bool = false,
        destination: URL
    ) async throws {
        guard let executableURL = Self.findExecutable(named: "ffmpeg") else {
            throw FFmpegError.notInstalled
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let logURL = destination.deletingLastPathComponent().appending(path: "ffmpeg-separation.log")
        var arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-ss", startTime.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(3))),
            "-i", "pipe:0",
            "-t", duration.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(3))),
            "-map", "0:a:\(audioTrackIndex)",
            "-vn", "-sn",
        ]
        if !preserveMultichannel {
            arguments += ["-ac", "2"]
        }
        arguments += [
            "-ar", "48000", "-c:a", "pcm_s16le",
            "-f", "wav", "pipe:1"
        ]

        let result = try await Task.detached(priority: .userInitiated) {
            try MediaProcess.run(
                executableURL: executableURL,
                arguments: arguments,
                inputURL: source,
                outputURL: destination,
                logURL: logURL
            )
        }.value
        guard result.exitCode == 0 else {
            throw FFmpegError.audioExtractionFailed(details: result.errorSummary)
        }
    }

    private nonisolated static func findExecutable(named name: String) -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appending(path: name),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)")
        ].compactMap { $0 }

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

private enum MediaProcess {
    nonisolated static func run(
        executableURL: URL,
        arguments: [String],
        inputURL: URL,
        outputURL: URL,
        logURL: URL
    ) throws -> MediaProcessResult {
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.truncate(atOffset: 0)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        try outputHandle.truncate(atOffset: 0)
        defer {
            try? logHandle.close()
            try? inputHandle.close()
            try? outputHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = logHandle

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw FFmpegError.couldNotLaunch(error.localizedDescription)
        }

        let errorSummary = (try? String(contentsOf: logURL, encoding: .utf8))
            .map { String($0.suffix(2_000)) } ?? "No diagnostic output was produced."
        return MediaProcessResult(exitCode: process.terminationStatus, errorSummary: errorSummary)
    }
}

private struct MediaProcessResult: Sendable {
    let exitCode: Int32
    let errorSummary: String
}

enum FFmpegError: LocalizedError {
    case notInstalled
    case couldNotLaunch(String)
    case processFailed(details: String)
    case probeFailed
    case unsupportedSubtitleCodec(String)
    case subtitleExtractionFailed
    case audioExtractionFailed(details: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "This MKV file needs FFmpeg for playback. Install FFmpeg for development, then import the movie again. A bundled FFmpeg binary will be provided before distribution."
        case .couldNotLaunch(let details):
            "FFmpeg could not be started. \(details)"
        case .processFailed:
            "FFmpeg could not create a playable copy of this MKV file. See ffmpeg-remux.log in the project’s temp folder for technical details."
        case .probeFailed:
            "DubLab could not inspect the embedded subtitle tracks."
        case .unsupportedSubtitleCodec(let codec):
            "The embedded \(codec.uppercased()) subtitle track is image-based or otherwise cannot be converted to editable dialogue."
        case .subtitleExtractionFailed:
            "DubLab could not extract the selected embedded subtitle track."
        case .audioExtractionFailed:
            "DubLab could not prepare this section of the movie audio for dialogue separation."
        }
    }
}

private struct FFprobeSubtitleOutput: Decodable {
    let streams: [Stream]

    struct Stream: Decodable {
        let index: Int
        let codecName: String
        let tags: Tags?

        enum CodingKeys: String, CodingKey {
            case index
            case codecName = "codec_name"
            case tags
        }
    }

    struct Tags: Decodable {
        let language: String?
        let title: String?
    }
}
