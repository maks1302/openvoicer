import Foundation

struct DubProject: Codable, Identifiable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    var name: String
    let createdAt: Date
    var modifiedAt: Date
    var sourceVideo: SourceVideoReference?
    var settings: ProjectSettings

    init(name: String) {
        schemaVersion = Self.currentSchemaVersion
        id = UUID()
        self.name = name
        createdAt = Date()
        modifiedAt = Date()
        sourceVideo = nil
        settings = ProjectSettings()
    }
}

struct SourceVideoReference: Codable, Hashable, Sendable {
    var displayName: String
    var bookmarkData: Data
    var lastKnownPath: String
    var metadata: VideoMetadata
    var playbackFileName: String?
}

struct ProjectSettings: Codable, Hashable, Sendable {
    var preRollDuration: TimeInterval = 1.5
    var postRollDuration: TimeInterval = 1.0
    var originalVolume: Float = 1.0
    var duckedOriginalVolume: Float = 0.2
}
