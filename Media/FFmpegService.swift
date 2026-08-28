import Foundation
import OSLog

actor FFmpegService {
    private let logger = Logger(subsystem: "com.dublab.app", category: "ffmpeg")

    func mediaMetadata(in source: URL) async throws -> VideoMetadata {
        guard let executableURL = Self.findExecutable(named: "ffprobe") else {
            throw FFmpegError.notInstalled
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "DubLab-MediaProbe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let outputURL = temporaryDirectory.appending(path: "media.json")
        let logURL = temporaryDirectory.appending(path: "ffprobe.log")
        let arguments = [
            "-v", "error",
            "-show_entries",
            "format=duration:stream=codec_type,codec_name,width,height,avg_frame_rate,channels:stream_tags=language,title",
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
        guard result.exitCode == 0 else { throw FFmpegError.probeFailed }
        let probe = try JSONDecoder().decode(
            FFprobeMediaOutput.self,
            from: Data(contentsOf: outputURL)
        )
        guard let duration = probe.format.duration.flatMap(Double.init), duration > 0,
              let video = probe.streams.first(where: { $0.codecType == "video" }) else {
            throw VideoImportError.invalidDuration
        }
        let audioTracks = probe.streams
            .filter { $0.codecType == "audio" }
            .enumerated()
            .map { index, stream in
                AudioTrackMetadata(
                    id: "audio-\(index)",
                    title: stream.tags?.title?.nilIfEmpty ?? "Audio \(index + 1)",
                    languageCode: stream.tags?.language?.nilIfEmpty,
                    codec: stream.codecName,
                    channelCount: stream.channels
                )
            }
        return VideoMetadata(
            duration: duration,
            width: video.width ?? 0,
            height: video.height ?? 0,
            frameRate: Self.parseFrameRate(video.averageFrameRate),
            videoCodec: video.codecName,
            audioTracks: audioTracks
        )
    }

    func createPlaybackCopy(source: URL, destination: URL) async throws {
        guard let executableURL = Self.findExecutable(named: "ffmpeg") else {
            throw FFmpegError.notInstalled
        }

        let logURL = destination.deletingLastPathComponent().appending(path: "ffmpeg-remux.log")
        let videoCodec = try await primaryVideoCodec(in: source)
        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", "pipe:0",
            "-map", "0:v:0",
            "-map", "0:a?",
            "-map_metadata", "0",
            "-c:v", "copy",
            "-c:a", "copy",
            "-sn",
        ]
        if videoCodec == "hevc" {
            // AVFoundation may reject HEVC carried as hev1 even though the
            // underlying Main/Main10 bitstream is hardware-decodable.
            arguments += ["-tag:v:0", "hvc1"]
        }
        arguments += [
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

    private func primaryVideoCodec(in source: URL) async throws -> String? {
        guard let executableURL = Self.findExecutable(named: "ffprobe") else {
            throw FFmpegError.notInstalled
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "DubLab-Probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let outputURL = temporaryDirectory.appending(path: "video-codec.json")
        let logURL = temporaryDirectory.appending(path: "ffprobe.log")
        let arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_name",
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
        guard result.exitCode == 0 else { throw FFmpegError.probeFailed }
        let data = try Data(contentsOf: outputURL)
        return try JSONDecoder().decode(FFprobeVideoOutput.self, from: data).streams.first?.codecName
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

    func audioTracks(in source: URL) async throws -> [AudioTrackMetadata] {
        guard let executableURL = Self.findExecutable(named: "ffprobe") else {
            throw FFmpegError.notInstalled
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "DubLab-AudioProbe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let outputURL = temporaryDirectory.appending(path: "audio-tracks.json")
        let logURL = temporaryDirectory.appending(path: "ffprobe.log")
        let arguments = [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries", "stream=codec_name,channels:stream_tags=language,title",
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
        guard result.exitCode == 0 else { throw FFmpegError.probeFailed }
        let data = try Data(contentsOf: outputURL)
        let probe = try JSONDecoder().decode(FFprobeAudioOutput.self, from: data)
        return probe.streams.enumerated().map { index, stream in
            AudioTrackMetadata(
                id: "audio-\(index)",
                title: stream.tags?.title?.nilIfEmpty ?? "Audio \(index + 1)",
                languageCode: stream.tags?.language?.nilIfEmpty,
                codec: stream.codecName,
                channelCount: stream.channels
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
            "-f", "wav", destination.path
        ]

        let result = try await Task.detached(priority: .userInitiated) {
            try MediaProcess.runWithStreamingInput(
                executableURL: executableURL,
                arguments: arguments,
                inputURL: source,
                logURL: logURL
            )
        }.value
        guard result.exitCode == 0 else {
            throw FFmpegError.audioExtractionFailed(details: result.errorSummary)
        }
    }

    func extractAudioTrack(
        from source: URL,
        audioTrackIndex: Int,
        mode: AudioTrackExtractionMode,
        startTime: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        destination: URL
    ) async throws {
        guard let executableURL = Self.findExecutable(named: "ffmpeg") else {
            throw FFmpegError.notInstalled
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let logURL = destination.deletingLastPathComponent().appending(path: "ffmpeg-audio-preparation.log")
        var arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-i", "pipe:0",
            "-map", "0:a:\(audioTrackIndex)",
            "-vn", "-sn"
        ]
        if let startTime, startTime > 0 {
            arguments += ["-ss", Self.number(startTime)]
        }
        if let duration, duration > 0 {
            arguments += ["-t", Self.number(duration)]
        }
        switch mode {
        case .stereoMix:
            arguments += ["-ac", "2"]
        case .centerReference:
            arguments += ["-af", "pan=mono|c0=FC", "-ac", "1"]
        }
        // WAV requires FFmpeg to seek back and finalize its RIFF/data sizes.
        // Sending WAV to stdout leaves those fields at 0xffffffff, which makes
        // Python's wave reader report billions of nonexistent frames. Keep the
        // movie input on a security-safe pipe, but write this temporary output
        // directly so the header contains the true duration.
        arguments += ["-ar", "48000", "-c:a", "pcm_s16le", "-f", "wav", destination.path]

        let result = try await Task.detached(priority: .userInitiated) {
            try MediaProcess.runWithStreamingInput(
                executableURL: executableURL,
                arguments: arguments,
                inputURL: source,
                logURL: logURL
            )
        }.value
        guard result.exitCode == 0 else {
            throw FFmpegError.audioExtractionFailed(details: result.errorSummary)
        }
    }

    func createDialogueDifference(
        originalURL: URL,
        backgroundURL: URL,
        destination: URL
    ) async throws {
        guard let executableURL = Self.findExecutable(named: "ffmpeg") else {
            throw FFmpegError.notInstalled
        }
        let logURL = destination.deletingLastPathComponent().appending(path: "ffmpeg-me-difference.log")
        let arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-i", originalURL.path,
            "-i", backgroundURL.path,
            "-filter_complex",
            "[0:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[o];[1:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[b];[o][b]amix=inputs=2:weights=1\\ -1:normalize=0:duration=first[d]",
            "-map", "[d]",
            // The mathematical difference can exceed ±1 even though adding it
            // back to M&E reconstructs the source. Float PCM preserves that
            // headroom instead of clipping one stem independently.
            "-c:a", "pcm_f32le",
            destination.path
        ]
        let result = try await Task.detached(priority: .userInitiated) {
            try MediaProcess.runWithoutStreamingInput(
                executableURL: executableURL,
                arguments: arguments,
                logURL: logURL
            )
        }.value
        guard result.exitCode == 0 else {
            throw FFmpegError.audioExtractionFailed(details: result.errorSummary)
        }
    }

    func createSetupPreview(
        source: URL,
        startTime: TimeInterval,
        duration: TimeInterval,
        audioTrackIndex: Int,
        destination: URL
    ) async throws {
        guard let executableURL = Self.findExecutable(named: "ffmpeg") else {
            throw FFmpegError.notInstalled
        }
        let logURL = destination.deletingLastPathComponent().appending(path: "ffmpeg-setup-preview.log")
        let arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-i", "pipe:0",
            "-ss", Self.number(startTime),
            "-t", Self.number(duration),
            "-map", "0:v:0",
            "-map", "0:a:\(audioTrackIndex)?",
            "-vf", "scale=w='min(960,iw)':h=-2",
            // Setup previews are deliberately short. Software H.264 is more
            // reliable here than VideoToolbox, which may reject an encoding
            // session while the app is sandboxed or running headlessly.
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "24",
            "-c:a", "aac",
            "-b:a", "160k",
            "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
            "-f", "mp4",
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
            throw FFmpegError.processFailed(details: result.errorSummary)
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

    private nonisolated static func parseFrameRate(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: "/")
        if parts.count == 2,
           let numerator = Double(parts[0]),
           let denominator = Double(parts[1]), denominator != 0 {
            let rate = numerator / denominator
            return rate > 0 ? rate : nil
        }
        return Double(value).flatMap { $0 > 0 ? $0 : nil }
    }

    private nonisolated static func number(_ value: Double) -> String {
        value.formatted(
            .number
                .locale(Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(0...6))
                .grouping(.never)
        )
    }
}

enum AudioTrackExtractionMode: Sendable {
    case stereoMix
    case centerReference
}

private enum MediaProcess {
    nonisolated static func runWithStreamingInput(
        executableURL: URL,
        arguments: [String],
        inputURL: URL,
        logURL: URL
    ) throws -> MediaProcessResult {
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.truncate(atOffset: 0)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer {
            try? logHandle.close()
            try? inputHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputHandle
        process.standardOutput = logHandle
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

    nonisolated static func runWithoutStreamingInput(
        executableURL: URL,
        arguments: [String],
        logURL: URL
    ) throws -> MediaProcessResult {
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.truncate(atOffset: 0)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = logHandle
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

private struct FFprobeVideoOutput: Decodable {
    let streams: [Stream]

    struct Stream: Decodable {
        let codecName: String

        enum CodingKeys: String, CodingKey {
            case codecName = "codec_name"
        }
    }
}

private struct FFprobeAudioOutput: Decodable {
    let streams: [Stream]

    struct Stream: Decodable {
        let codecName: String?
        let channels: Int?
        let tags: Tags?

        enum CodingKeys: String, CodingKey {
            case codecName = "codec_name"
            case channels, tags
        }
    }

    struct Tags: Decodable {
        let language: String?
        let title: String?
    }
}

private struct FFprobeMediaOutput: Decodable {
    let streams: [Stream]
    let format: Format

    struct Stream: Decodable {
        let codecType: String?
        let codecName: String?
        let width: Int?
        let height: Int?
        let averageFrameRate: String?
        let channels: Int?
        let tags: Tags?

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type"
            case codecName = "codec_name"
            case width, height, channels, tags
            case averageFrameRate = "avg_frame_rate"
        }
    }

    struct Format: Decodable {
        let duration: String?
    }

    struct Tags: Decodable {
        let language: String?
        let title: String?
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
