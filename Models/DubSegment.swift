import Foundation

struct SourceSeparationAsset: Codable, Hashable, Sendable {
    var fileName: String
    var preRollDuration: TimeInterval
    var modelID: String
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
        notes = nil
        separatedBackground = nil
    }

    var duration: TimeInterval {
        max(0, endTime - startTime)
    }
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
