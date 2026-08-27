import Foundation
import OSLog

struct ExportProgress: Sendable {
    let fraction: Double
    let message: String
}

protocol ExportService: Sendable {
    func render(
        job: ExportJob,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws
    func cancel() async
}

actor FFmpegExportService: ExportService {
    private let logger = Logger(subsystem: "com.dublab.app", category: "export")
    private var activeProcess: Process?

    func render(
        job: ExportJob,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws {
        guard let executableURL = Self.findExecutable(named: "ffmpeg") else {
            throw ExportError.couldNotLaunch("FFmpeg is not installed.")
        }

        try FileManager.default.createDirectory(
            at: job.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let expectedDuration = max(job.scope.outputDuration(sourceDuration: job.sourceDuration), 0.01)

        do {
            progress(.init(fraction: 0.01, message: "Preparing export…"))
            var result = try await execute(
                executableURL: executableURL,
                arguments: ExportCommandBuilder.arguments(for: job),
                expectedDuration: expectedDuration,
                progress: progress
            )
            try Task.checkCancellation()

            if result.exitCode != 0, job.scope.requiresVideoEncoding {
                progress(.init(fraction: 0.01, message: "Using compatibility video encoder…"))
                try? FileManager.default.removeItem(at: job.destinationURL)
                result = try await execute(
                    executableURL: executableURL,
                    arguments: ExportCommandBuilder.arguments(for: job, softwareVideoEncoding: true),
                    expectedDuration: expectedDuration,
                    progress: progress
                )
                try Task.checkCancellation()
            }

            try? result.summary.write(to: job.logURL, atomically: true, encoding: .utf8)
            guard result.exitCode == 0 else {
                logger.error("FFmpeg export failed: \(result.summary, privacy: .public)")
                throw ExportError.renderingFailed(result.summary)
            }
            progress(.init(fraction: 1, message: "Export complete"))
        } catch {
            activeProcess = nil
            if error is CancellationError {
                try? FileManager.default.removeItem(at: job.destinationURL)
            }
            throw error
        }
    }

    private func execute(
        executableURL: URL,
        arguments: [String],
        expectedDuration: TimeInterval,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> ExportProcessResult {
        let process = Process()
        let progressPipe = Pipe()
        let errorPipe = Pipe()
        let diagnostics = ExportDiagnostics()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = progressPipe
        process.standardError = errorPipe
        activeProcess = process

        let progressTask = Task.detached {
            for try await line in progressPipe.fileHandleForReading.bytes.lines {
                if line.hasPrefix("out_time_us="),
                   let microseconds = Double(line.dropFirst("out_time_us=".count)) {
                    let fraction = min(max(microseconds / 1_000_000 / expectedDuration, 0), 0.99)
                    progress(.init(fraction: fraction, message: "Rendering audio and video…"))
                }
            }
        }
        let diagnosticsTask = Task.detached {
            for try await line in errorPipe.fileHandleForReading.bytes.lines {
                await diagnostics.append(line)
            }
        }

        do {
            try process.run()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { _ in continuation.resume() }
                }
            } onCancel: {
                process.terminate()
            }
            _ = await progressTask.result
            _ = await diagnosticsTask.result
            activeProcess = nil
            try Task.checkCancellation()
            return ExportProcessResult(
                exitCode: process.terminationStatus,
                summary: await diagnostics.summary
            )
        } catch {
            activeProcess = nil
            progressTask.cancel()
            diagnosticsTask.cancel()
            throw error
        }
    }

    func cancel() {
        activeProcess?.terminate()
        activeProcess = nil
    }

    private nonisolated static func findExecutable(named name: String) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appending(path: name),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private struct ExportProcessResult: Sendable {
    let exitCode: Int32
    let summary: String
}

private extension ExportRenderScope {
    var requiresVideoEncoding: Bool {
        switch self {
        case .finishedMovie: false
        case .continuous, .reviewReel: true
        }
    }
}

private actor ExportDiagnostics {
    private var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 150 {
            lines.removeFirst(lines.count - 150)
        }
    }

    var summary: String { lines.joined(separator: "\n") }
}

enum ExportCommandBuilder {
    static func arguments(for job: ExportJob, softwareVideoEncoding: Bool = false) -> [String] {
        var arguments = ["-hide_banner", "-nostdin", "-y", "-i", job.sourceURL.path]
        var inputs: [UUID: (take: Int, background: Int?)] = [:]
        var nextInput = 1

        for line in job.lines {
            arguments += ["-i", line.takeURL.path]
            let takeInput = nextInput
            nextInput += 1
            var backgroundInput: Int?
            if let backgroundURL = line.backgroundURL {
                arguments += ["-i", backgroundURL.path]
                backgroundInput = nextInput
                nextInput += 1
            }
            inputs[line.segmentID] = (takeInput, backgroundInput)
        }

        arguments += ["-filter_complex", filterGraph(job: job, inputs: inputs)]

        switch job.scope {
        case .finishedMovie:
            arguments += ["-map", "0:v:0", "-map", "[aout]"]
            arguments += ["-c:v", "copy"]
        case .continuous, .reviewReel:
            arguments += ["-map", "[vout]", "-map", "[aout]"]
            if softwareVideoEncoding {
                arguments += [
                    "-c:v", "libx264",
                    "-preset", "medium",
                    "-crf", "18",
                    "-pix_fmt", "yuv420p"
                ]
            } else {
                arguments += [
                    "-c:v", "h264_videotoolbox",
                    "-allow_sw", "1",
                    "-b:v", "12M",
                    "-pix_fmt", "yuv420p"
                ]
            }
        }

        arguments += [
            "-c:a", "aac",
            "-b:a", "192k",
            "-ar", "48000",
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            "-nostats",
            job.destinationURL.path
        ]
        return arguments
    }

    private static func filterGraph(
        job: ExportJob,
        inputs: [UUID: (take: Int, background: Int?)]
    ) -> String {
        var filters: [String] = []
        filters.append("[0:a:\(job.audioTrackIndex)]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[base0]")

        var baseLabel = "base0"
        for (index, line) in job.lines.enumerated() {
            let nextLabel = "base\(index + 1)"
            let target: Double = switch line.treatment {
            case .duckedMix: Double(job.duckedOriginalVolume)
            case .cleanDub, .takeOnly: 0
            }
            filters.append("[\(baseLabel)]volume='\(volumeExpression(start: line.startTime, end: line.endTime, target: target))':eval=frame[\(nextLabel)]")
            baseLabel = nextLabel
        }

        var mixLabels = [baseLabel]
        for (index, line) in job.lines.enumerated() {
            guard let input = inputs[line.segmentID] else { continue }
            let voiceDuration = min(line.duration, line.takeDuration)
            if voiceDuration > 0 {
                let fade = min(0.05, voiceDuration / 2)
                let fadeOut = max(voiceDuration - fade, 0)
                let label = "voice\(index)"
                filters.append(
                    "[\(input.take):a:0]atrim=start=0:end=\(number(voiceDuration)),asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,volume=\(number(Double(line.takeGain))),afade=t=in:st=0:d=\(number(fade)),afade=t=out:st=\(number(fadeOut)):d=\(number(fade)),adelay=delays=\(milliseconds(line.startTime)):all=1[\(label)]"
                )
                mixLabels.append(label)
            }

            if let backgroundInput = input.background {
                let fade = min(0.05, line.duration / 2)
                let fadeOut = max(line.duration - fade, 0)
                let label = "background\(index)"
                filters.append(
                    "[\(backgroundInput):a:0]atrim=start=\(number(line.backgroundPreRoll)):end=\(number(line.backgroundPreRoll + line.duration)),asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,volume=\(number(Double(line.backgroundGain))),afade=t=in:st=0:d=\(number(fade)),afade=t=out:st=\(number(fadeOut)):d=\(number(fade)),adelay=delays=\(milliseconds(line.startTime)):all=1[\(label)]"
                )
                mixLabels.append(label)
            }
        }

        if mixLabels.count == 1 {
            filters.append("[\(baseLabel)]anull[mixed]")
        } else {
            let inputs = mixLabels.map { "[\($0)]" }.joined()
            filters.append("\(inputs)amix=inputs=\(mixLabels.count):duration=first:dropout_transition=0:normalize=0,alimiter=limit=0.95[mixed]")
        }

        switch job.scope {
        case .finishedMovie:
            filters.append("[mixed]atrim=start=0:end=\(number(job.sourceDuration)),asetpts=PTS-STARTPTS[aout]")

        case .continuous(let range):
            filters.append("[0:v:0]trim=start=\(number(range.start)):end=\(number(range.end)),setpts=PTS-STARTPTS[vout]")
            filters.append("[mixed]atrim=start=\(number(range.start)):end=\(number(range.end)),asetpts=PTS-STARTPTS[aout]")

        case .reviewReel(let ranges):
            if ranges.count == 1, let range = ranges.first {
                filters.append("[0:v:0]trim=start=\(number(range.start)):end=\(number(range.end)),setpts=PTS-STARTPTS[vout]")
                filters.append("[mixed]atrim=start=\(number(range.start)):end=\(number(range.end)),asetpts=PTS-STARTPTS[aout]")
            } else {
                let splitLabels = ranges.indices.map { "mix\($0)" }
                filters.append("[mixed]asplit=\(ranges.count)\(splitLabels.map { "[\($0)]" }.joined())")
                for (index, range) in ranges.enumerated() {
                    filters.append("[0:v:0]trim=start=\(number(range.start)):end=\(number(range.end)),setpts=PTS-STARTPTS[v\(index)]")
                    filters.append("[\(splitLabels[index])]atrim=start=\(number(range.start)):end=\(number(range.end)),asetpts=PTS-STARTPTS[a\(index)]")
                }
                let concatInputs = ranges.indices.map { "[v\($0)][a\($0)]" }.joined()
                filters.append("\(concatInputs)concat=n=\(ranges.count):v=1:a=1[vout][aout]")
            }
        }

        return filters.joined(separator: ";")
    }

    private static func volumeExpression(start: TimeInterval, end: TimeInterval, target: Double) -> String {
        let fade = 0.08
        let fadeStart = max(0, start - fade)
        let fadeEnd = end + fade
        return "if(lt(t,\(number(fadeStart))),1,if(lt(t,\(number(start))),1-(1-\(number(target)))*(t-\(number(fadeStart)))/\(number(max(start - fadeStart, 0.001))),if(lt(t,\(number(end))),\(number(target)),if(lt(t,\(number(fadeEnd))),\(number(target))+(1-\(number(target)))*(t-\(number(end)))/\(number(fade)),1))))"
    }

    private static func milliseconds(_ time: TimeInterval) -> Int {
        max(Int((time * 1_000).rounded()), 0)
    }

    private static func number(_ value: Double) -> String {
        value.formatted(
            .number
                .locale(Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(0...6))
                .grouping(.never)
        )
    }
}
