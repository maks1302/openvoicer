import Foundation

struct DubProject: Codable, Identifiable, Hashable, Sendable {
    static let currentSchemaVersion = 10

    var schemaVersion: Int
    let id: UUID
    var name: String
    let createdAt: Date
    var modifiedAt: Date
    var sourceVideo: SourceVideoReference?
    var subtitleSource: SubtitleSource?
    var segments: [DubSegment]
    var speakers: [Speaker]
    var settings: ProjectSettings
    var preparedAudioAssets: [PreparedAudioAsset]
    var mediaScope: ProjectMediaScope

    init(name: String) {
        schemaVersion = Self.currentSchemaVersion
        id = UUID()
        self.name = name
        createdAt = Date()
        modifiedAt = Date()
        sourceVideo = nil
        subtitleSource = nil
        segments = []
        speakers = []
        settings = ProjectSettings()
        preparedAudioAssets = []
        mediaScope = .fullMovie
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, createdAt, modifiedAt, sourceVideo
        case subtitleSource, segments, speakers, settings, preparedAudioAssets, mediaScope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        sourceVideo = try container.decodeIfPresent(SourceVideoReference.self, forKey: .sourceVideo)
        subtitleSource = try container.decodeIfPresent(SubtitleSource.self, forKey: .subtitleSource)
        segments = try container.decodeIfPresent([DubSegment].self, forKey: .segments) ?? []
        speakers = try container.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        settings = try container.decodeIfPresent(ProjectSettings.self, forKey: .settings) ?? ProjectSettings()
        preparedAudioAssets = try container.decodeIfPresent(
            [PreparedAudioAsset].self,
            forKey: .preparedAudioAssets
        ) ?? []
        mediaScope = try container.decodeIfPresent(ProjectMediaScope.self, forKey: .mediaScope) ?? .fullMovie
    }
}

struct ProjectMediaScope: Codable, Hashable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
        case fullMovie
        case clip

        var id: Self { self }
    }

    var mode: Mode
    var sourceStartTime: TimeInterval
    var sourceEndTime: TimeInterval?

    static let fullMovie = ProjectMediaScope(
        mode: .fullMovie,
        sourceStartTime: 0,
        sourceEndTime: nil
    )

    static func clip(start: TimeInterval, end: TimeInterval) -> ProjectMediaScope {
        ProjectMediaScope(mode: .clip, sourceStartTime: start, sourceEndTime: end)
    }

    func resolvedRange(sourceDuration: TimeInterval) -> ClosedRange<TimeInterval> {
        guard mode == .clip, let sourceEndTime else { return 0...max(sourceDuration, 0) }
        let start = min(max(sourceStartTime, 0), sourceDuration)
        let end = min(max(sourceEndTime, start), sourceDuration)
        return start...end
    }
}

struct PreparedAudioAsset: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var sourceAudioTrackID: String
    var backgroundSourceTrackID: String?
    var strategy: AudioPreparationStrategy
    var dialogueFileName: String
    var backgroundFileName: String
    var modelID: String
    var createdAt: Date
    var timelineStart: TimeInterval
    var timelineDuration: TimeInterval?

    init(
        id: UUID = UUID(),
        sourceAudioTrackID: String,
        backgroundSourceTrackID: String? = nil,
        strategy: AudioPreparationStrategy,
        dialogueFileName: String,
        backgroundFileName: String,
        modelID: String,
        createdAt: Date = Date(),
        timelineStart: TimeInterval = 0,
        timelineDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.sourceAudioTrackID = sourceAudioTrackID
        self.backgroundSourceTrackID = backgroundSourceTrackID
        self.strategy = strategy
        self.dialogueFileName = dialogueFileName
        self.backgroundFileName = backgroundFileName
        self.modelID = modelID
        self.createdAt = createdAt
        self.timelineStart = timelineStart
        self.timelineDuration = timelineDuration
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceAudioTrackID, backgroundSourceTrackID, strategy
        case dialogueFileName, backgroundFileName, modelID, createdAt
        case timelineStart, timelineDuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceAudioTrackID = try container.decode(String.self, forKey: .sourceAudioTrackID)
        backgroundSourceTrackID = try container.decodeIfPresent(String.self, forKey: .backgroundSourceTrackID)
        strategy = try container.decode(AudioPreparationStrategy.self, forKey: .strategy)
        dialogueFileName = try container.decode(String.self, forKey: .dialogueFileName)
        backgroundFileName = try container.decode(String.self, forKey: .backgroundFileName)
        modelID = try container.decode(String.self, forKey: .modelID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        timelineStart = try container.decodeIfPresent(TimeInterval.self, forKey: .timelineStart) ?? 0
        timelineDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .timelineDuration)
    }
}

enum AudioPreparationStrategy: String, Codable, Hashable, Sendable {
    case embeddedMusicAndEffects
    case surroundAssisted
    case cinematicSeparation

    var title: String {
        switch self {
        case .embeddedMusicAndEffects: "Embedded M&E"
        case .surroundAssisted: "Surround-assisted"
        case .cinematicSeparation: "Cinematic AI"
        }
    }
}

struct SourceVideoReference: Codable, Hashable, Sendable {
    var displayName: String
    var bookmarkData: Data
    var lastKnownPath: String
    var metadata: VideoMetadata
    var playbackFileName: String?
    var playbackPreparationVersion: Int?
}

struct ProjectSettings: Codable, Hashable, Sendable {
    var preRollDuration: TimeInterval = 1.5
    var postRollDuration: TimeInterval = 1.0
    var originalVolume: Float = 1.0
    var duckedOriginalVolume: Float = 0.2
    var selectedInputDeviceID: String?
    var recordingCountdownSeconds = 3
    var recordingGain: Float = 1.0
    var dialogueCleaningPreset: DialogueCleaningPreset = .balanced
    var cleanBackgroundVolume: Float = 1.0
    var selectedAudioTrackID: String?
    var audioPreparationPreference: AudioPreparationPreference = .automatic

    private enum CodingKeys: String, CodingKey {
        case preRollDuration, postRollDuration, originalVolume, duckedOriginalVolume
        case selectedInputDeviceID, recordingCountdownSeconds, recordingGain
        case dialogueCleaningPreset, cleanBackgroundVolume
        case selectedAudioTrackID, audioPreparationPreference
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preRollDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .preRollDuration) ?? 1.5
        postRollDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .postRollDuration) ?? 1.0
        originalVolume = try container.decodeIfPresent(Float.self, forKey: .originalVolume) ?? 1.0
        duckedOriginalVolume = try container.decodeIfPresent(Float.self, forKey: .duckedOriginalVolume) ?? 0.2
        selectedInputDeviceID = try container.decodeIfPresent(String.self, forKey: .selectedInputDeviceID)
        recordingCountdownSeconds = try container.decodeIfPresent(Int.self, forKey: .recordingCountdownSeconds) ?? 3
        recordingGain = try container.decodeIfPresent(Float.self, forKey: .recordingGain) ?? 1.0
        dialogueCleaningPreset = try container.decodeIfPresent(
            DialogueCleaningPreset.self,
            forKey: .dialogueCleaningPreset
        ) ?? .balanced
        cleanBackgroundVolume = try container.decodeIfPresent(Float.self, forKey: .cleanBackgroundVolume) ?? 1.0
        selectedAudioTrackID = try container.decodeIfPresent(String.self, forKey: .selectedAudioTrackID)
        audioPreparationPreference = try container.decodeIfPresent(
            AudioPreparationPreference.self,
            forKey: .audioPreparationPreference
        ) ?? .automatic
    }
}

enum AudioPreparationPreference: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case automatic
    case embeddedMusicAndEffects
    case surroundAssisted
    case cinematicSeparation
    case duckingOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .embeddedMusicAndEffects: "Embedded M&E"
        case .surroundAssisted: "Surround-Assisted"
        case .cinematicSeparation: "Cinematic AI"
        case .duckingOnly: "Original Audio Ducking"
        }
    }
}

enum DialogueCleaningPreset: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case gentle
    case balanced
    case strong

    var id: Self { self }

    var title: String {
        switch self {
        case .gentle: "Gentle"
        case .balanced: "Balanced"
        case .strong: "Strong"
        }
    }

    var detail: String {
        switch self {
        case .gentle: "Preserves more music and effects, with more chance of dialogue leakage."
        case .balanced: "Reduces dialogue while retaining most of the surrounding mix."
        case .strong: "Removes the most dialogue, but may soften centered music and effects."
        }
    }

    var centerCancellationStrength: Double {
        switch self {
        case .gentle: 0.55
        case .balanced: 0.78
        case .strong: 1.0
        }
    }

    var dialogueReduction: Double { 1.0 }

    var residualSuppressionStrength: Double {
        switch self {
        case .gentle: 0
        case .balanced: 0.3
        case .strong: 0.82
        }
    }
}

struct SubtitleSource: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case externalFile
        case embeddedTrack
    }

    var kind: Kind
    var displayName: String
    var languageCode: String?
    var streamIndex: Int?
    var bookmarkData: Data?
    var lastKnownPath: String?
}
