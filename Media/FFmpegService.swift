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
            "-i", source.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-map_metadata", "0",
            "-c", "copy",
            "-sn",
            destination.path
        ]

        logger.info("Creating an AVFoundation-compatible playback copy")
        let result = try await Task.detached(priority: .userInitiated) {
            try MediaProcess.run(executableURL: executableURL, arguments: arguments, logURL: logURL)
        }.value

        guard result.exitCode == 0 else {
            logger.error("FFmpeg remux failed with exit code \(result.exitCode)")
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
}

private enum MediaProcess {
    nonisolated static func run(
        executableURL: URL,
        arguments: [String],
        logURL: URL
    ) throws -> MediaProcessResult {
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
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

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "This MKV file needs FFmpeg for playback. Install FFmpeg for development, then import the movie again. A bundled FFmpeg binary will be provided before distribution."
        case .couldNotLaunch(let details):
            "FFmpeg could not be started. \(details)"
        case .processFailed:
            "FFmpeg could not create a playable copy of this MKV file. See ffmpeg-remux.log in the project’s temp folder for technical details."
        }
    }
}
