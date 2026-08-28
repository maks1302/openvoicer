import Foundation
import OSLog

struct SourceSeparationProgress: Sendable {
    var fraction: Double
    var message: String
}

protocol SourceSeparationService: Sendable {
    func isRuntimeReady() async -> Bool
    func installRuntime(progress: @escaping @Sendable (SourceSeparationProgress) -> Void) async throws
    func separate(
        inputURL: URL,
        outputURL: URL,
        dialogueOutputURL: URL?,
        dialogueInputURL: URL?,
        cleaningPreset: DialogueCleaningPreset,
        progress: @escaping @Sendable (SourceSeparationProgress) -> Void
    ) async throws
    func cancel() async
}

actor BanditSourceSeparationService: SourceSeparationService {
    static let modelID = "bandit-v2-multi"
    static let packageRevision = "d45cdec634bf1ee01cdd2acea74a2d100e639c8a"

    private let logger = Logger(subsystem: "com.openvoicer.app", category: "separation")
    private var activeProcess: Process?

    func isRuntimeReady() -> Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path)
            && FileManager.default.fileExists(atPath: weightsURL.path)
    }

    func installRuntime(
        progress: @escaping @Sendable (SourceSeparationProgress) -> Void
    ) async throws {
        if isRuntimeReady() { return }
        guard let uvURL = Self.findExecutable(named: "uv") else {
            throw SourceSeparationError.uvNotInstalled
        }
        guard let bootstrapPythonURL = Self.findExecutable(named: "python3") else {
            throw SourceSeparationError.developmentPythonNotInstalled
        }

        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        progress(.init(fraction: 0.02, message: "Creating the local separation runtime…"))
        try await run(
            executable: uvURL,
            arguments: ["venv", "--python", bootstrapPythonURL.path, environmentURL.path]
        )

        progress(.init(fraction: 0.12, message: "Installing the Apple Silicon audio engine…"))
        let archive = "https://github.com/openmirlab/bandit-infer/archive/\(Self.packageRevision).zip"
        try await run(
            executable: uvURL,
            arguments: [
                "pip", "install", "--python", pythonURL.path,
                "bandit-infer[mlx] @ \(archive)"
            ]
        )

        progress(.init(fraction: 0.42, message: "Downloading and verifying the Bandit v2 model…"))
        try await runHelper(arguments: ["--weights", weightsDirectory.path, "--prepare"]) { event in
            progress(.init(
                fraction: 0.42 + event.fraction * 0.56,
                message: event.message
            ))
        }
        progress(.init(fraction: 1, message: "Local dialogue separation is ready"))
    }

    func separate(
        inputURL: URL,
        outputURL: URL,
        dialogueOutputURL: URL?,
        dialogueInputURL: URL?,
        cleaningPreset: DialogueCleaningPreset,
        progress: @escaping @Sendable (SourceSeparationProgress) -> Void
    ) async throws {
        guard isRuntimeReady() else { throw SourceSeparationError.runtimeUnavailable }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var arguments = [
            "--weights", weightsDirectory.path,
            "--input", inputURL.path,
            "--background", outputURL.path,
            "--cleaning-preset", cleaningPreset.rawValue
        ]
        if let dialogueOutputURL {
            arguments += ["--dialogue", dialogueOutputURL.path]
        }
        if let dialogueInputURL {
            arguments += ["--dialogue-input", dialogueInputURL.path]
        }
        try await runHelper(arguments: arguments, progress: progress)
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SourceSeparationError.missingOutput
        }
        if let dialogueOutputURL,
           !FileManager.default.fileExists(atPath: dialogueOutputURL.path) {
            throw SourceSeparationError.missingOutput
        }
    }

    func cancel() {
        activeProcess?.terminate()
        activeProcess = nil
    }

    private func runHelper(
        arguments: [String],
        progress: @escaping @Sendable (SourceSeparationProgress) -> Void
    ) async throws {
        guard let helperURL = Self.helperURL else { throw SourceSeparationError.helperMissing }
        try await run(executable: pythonURL, arguments: [helperURL.path] + arguments) { line in
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(HelperProgress.self, from: data) else { return }
            progress(.init(fraction: event.progress, message: event.detail))
        }
    }

    private func run(
        executable: URL,
        arguments: [String],
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let process = Process()
        let output = Pipe()
        let capture = ProcessOutputCapture()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.environment = runtimeEnvironment

        let outputTask = Task.detached {
            for try await line in output.fileHandleForReading.bytes.lines {
                await capture.append(line)
                onOutput?(line)
            }
        }
        activeProcess = process
        do {
            try process.run()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { _ in continuation.resume() }
                }
            } onCancel: {
                process.terminate()
            }
            _ = await outputTask.result
            let details = await capture.summary
            activeProcess = nil
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                logger.error("Bandit process failed: \(details, privacy: .public)")
                throw SourceSeparationError.processFailed(Self.humanReadableError(from: details))
            }
        } catch {
            activeProcess = nil
            outputTask.cancel()
            throw error
        }
    }

    private var runtimeRoot: URL {
        URL.applicationSupportDirectory
            .appending(path: "OpenVoicer", directoryHint: .isDirectory)
            .appending(path: "SourceSeparation", directoryHint: .isDirectory)
    }

    private var environmentURL: URL { runtimeRoot.appending(path: "venv", directoryHint: .isDirectory) }
    private var pythonURL: URL { environmentURL.appending(path: "bin/python3") }
    private var weightsDirectory: URL { runtimeRoot.appending(path: "weights", directoryHint: .isDirectory) }
    private var weightsURL: URL { weightsDirectory.appending(path: "checkpoint-multi.ckpt") }

    private var runtimeEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["UV_CACHE_DIR"] = runtimeRoot.appending(path: "uv-cache").path
        environment["UV_NO_CACHE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    private nonisolated static var helperURL: URL? {
        Bundle.main.url(forResource: "bandit_helper", withExtension: "py")
    }

    private nonisolated static func findExecutable(named name: String) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appending(path: name),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            name == "python3" ? URL(fileURLWithPath: "/usr/bin/python3") : nil
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private nonisolated static func humanReadableError(from details: String) -> String {
        guard let line = details.split(separator: "\n").last(where: { $0.contains("\"error\"") }),
              let data = String(line).data(using: .utf8),
              let message = try? JSONDecoder().decode(HelperError.self, from: data).error else {
            let usefulLine = details
                .split(separator: "\n")
                .reversed()
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first {
                    !$0.isEmpty
                        && !$0.hasPrefix("Traceback")
                        && !$0.hasPrefix("File ")
                        && !$0.hasPrefix("^")
                }
            return usefulLine ?? "The local separation engine stopped unexpectedly."
        }
        return message
    }
}

private actor ProcessOutputCapture {
    private var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 80 {
            lines.removeFirst(lines.count - 80)
        }
    }

    var summary: String { lines.joined(separator: "\n") }
}

private struct HelperProgress: Decodable {
    let progress: Double
    let detail: String
}

private struct HelperError: Decodable {
    let error: String
}

enum SourceSeparationError: LocalizedError {
    case uvNotInstalled
    case developmentPythonNotInstalled
    case runtimeUnavailable
    case helperMissing
    case processFailed(String)
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .uvNotInstalled:
            "The development separation runtime needs uv. Install uv, then try again. OpenVoicer will bundle this runtime for distribution."
        case .developmentPythonNotInstalled:
            "The development separation runtime needs Homebrew Python 3.12 or newer. OpenVoicer will bundle its own signed runtime for distribution."
        case .runtimeUnavailable:
            "The local dialogue-separation model has not been installed."
        case .helperMissing:
            "OpenVoicer’s dialogue-separation helper is missing from the application bundle."
        case .processFailed(let details):
            "Dialogue separation failed. \(details)"
        case .missingOutput:
            "Dialogue separation finished without producing a background track."
        }
    }
}
