import Foundation

struct SourceSeparationAsset: Codable, Hashable, Sendable {
    var fileName: String
    var preRollDuration: TimeInterval
    var modelID: String
    var sourceAudioTrackID: String?

    init(fileName: String, preRollDuration: TimeInterval, modelID: String, sourceAudioTrackID: String? = nil) {
        self.fileName = fileName
        self.preRollDuration = preRollDuration
        self.modelID = modelID
        self.sourceAudioTrackID = sourceAudioTrackID
    }
}

struct DubSegment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speakerID: UUID?
    var status: SegmentStatus
    var takes: [RecordingTake]
    var selectedTakeID: UUID?
    var acceptedVersion: AcceptedSegmentVersion?
    var notes: String?
    var separatedBackground: SourceSeparationAsset?

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        speakerID = nil
        status = .pending
        takes = []
        selectedTakeID = nil
        acceptedVersion = nil
        notes = nil
        separatedBackground = nil
    }

    var duration: TimeInterval {
        max(0, endTime - startTime)
    }
}

struct AcceptedSegmentVersion: Codable, Hashable, Sendable {
    var takeID: UUID?
    var treatment: SegmentMixTreatment
}

enum SegmentMixTreatment: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case original
    case duckedMix
    case cleanDub
    case takeOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .original: "Original"
        case .duckedMix: "Ducked Mix"
        case .cleanDub: "Clean Dub"
        case .takeOnly: "Take Only"
        }
    }

    var shortTitle: String {
        switch self {
        case .original: "Original"
        case .duckedMix: "Mix"
        case .cleanDub: "Clean"
        case .takeOnly: "Take"
        }
    }

    var systemImage: String {
        switch self {
        case .original: "film"
        case .duckedMix: "slider.horizontal.3"
        case .cleanDub: "waveform.badge.minus"
        case .takeOnly: "person.wave.2"
        }
    }

    var requiresTake: Bool { self != .original }
}

enum SegmentStatus: String, Codable, Hashable, Sendable {
    case pending
    case recorded
    case accepted
    case skipped
}

struct RecordingTake: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var fileName: String
    var createdAt: Date
    var duration: TimeInterval
    var gain: Float
    var isFavorite: Bool
}

struct Speaker: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
}
