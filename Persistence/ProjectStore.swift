import Foundation
import OSLog

actor ProjectStore {
    static let projectFileName = "project.json"

    private let logger = Logger(subsystem: "com.dublab.app", category: "project")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func create(_ project: DubProject, at packageURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)

        for directory in ProjectDirectory.allCases {
            try fileManager.createDirectory(
                at: packageURL.appending(path: directory.rawValue, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }

        try save(project, at: packageURL)
        logger.info("Created project package at \(packageURL.lastPathComponent, privacy: .public)")
    }

    func load(from packageURL: URL) throws -> DubProject {
        let data = try Data(contentsOf: metadataURL(for: packageURL))
        var project = try decoder.decode(DubProject.self, from: data)

        guard project.schemaVersion <= DubProject.currentSchemaVersion else {
            throw ProjectStoreError.unsupportedSchema(project.schemaVersion)
        }

        project.schemaVersion = DubProject.currentSchemaVersion

        return project
    }

    func save(_ project: DubProject, at packageURL: URL) throws {
        let data = try encoder.encode(project)
        try data.write(to: metadataURL(for: packageURL), options: .atomic)
    }

    private func metadataURL(for packageURL: URL) -> URL {
        packageURL.appending(path: Self.projectFileName)
    }
}

private enum ProjectDirectory: String, CaseIterable {
    case recordings
    case waveformCache = "waveform-cache"
    case thumbnails
    case temp
}

enum ProjectStoreError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "This project uses schema version \(version), which this version of DubLab cannot open."
        }
    }
}
