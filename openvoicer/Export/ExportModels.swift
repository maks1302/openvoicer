import Foundation

enum ExportType: String, CaseIterable, Identifiable {
    case finishedMovie
    case continuousClip
    case reviewReel

    var id: Self { self }

    var title: String {
        switch self {
        case .finishedMovie: "Finished Movie"
        case .continuousClip: "Continuous Clip"
        case .reviewReel: "Review Reel"
        }
    }
}

enum ClipRangeMode: String, CaseIterable, Identifiable {
    case currentLine
    case selectedLines
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .currentLine: "Current Line"
        case .selectedLines: "Selected Lines"
        case .custom: "Custom Time Range"
        }
    }
}

enum ReviewLineMode: String, CaseIterable, Identifiable {
    case accepted
    case selected

    var id: Self { self }

    var title: String {
        switch self {
        case .accepted: "All Accepted Lines"
        case .selected: "Selected Lines"
        }
    }
}

struct ExportTimeRange: Hashable, Sendable {
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }
}

struct ExportLineAsset: Sendable {
    let segmentID: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let takeURL: URL
    let takeDuration: TimeInterval
    let takeGain: Float
    let backgroundURL: URL?
    let backgroundPreRoll: TimeInterval
    let backgroundGain: Float
    let treatment: ExportMixTreatment

    var duration: TimeInterval { max(0, endTime - startTime) }
}

enum ExportMixTreatment: Sendable {
    case duckedMix
    case cleanDub
    case takeOnly
}

enum ExportRenderScope: Sendable {
    case finishedMovie
    case continuous(ExportTimeRange)
    case reviewReel([ExportTimeRange])

    func outputDuration(sourceDuration: TimeInterval) -> TimeInterval {
        switch self {
        case .finishedMovie: sourceDuration
        case .continuous(let range): range.duration
        case .reviewReel(let ranges): ranges.reduce(0) { $0 + $1.duration }
        }
    }
}

struct ExportJob: Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let logURL: URL
    let sourceDuration: TimeInterval
    let audioTrackIndex: Int
    let scope: ExportRenderScope
    let lines: [ExportLineAsset]
    let duckedOriginalVolume: Float
    var preparedDialogueURL: URL? = nil
    var preparedBackgroundURL: URL? = nil
    var preparedBackgroundGain: Float = 1
    var preparedAudioTimelineStart: TimeInterval = 0
}

enum ExportError: LocalizedError {
    case sourceUnavailable
    case noCurrentLine
    case noSelectedLines
    case noAcceptedLines
    case cleanBackgroundUnavailable
    case invalidTimeRange
    case couldNotLaunch(String)
    case renderingFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The source movie is not available for export."
        case .noCurrentLine:
            "Select a dialogue line before exporting the current line."
        case .noSelectedLines:
            "Select at least one dialogue line to export."
        case .noAcceptedLines:
            "There are no accepted dubbed lines to export."
        case .cleanBackgroundUnavailable:
            "The prepared background audio is no longer available. Prepare the movie audio again or accept a different result."
        case .invalidTimeRange:
            "The export end time must be after the start time and inside the movie."
        case .couldNotLaunch(let details):
            "FFmpeg could not be started. \(details)"
        case .renderingFailed:
            "The exported movie could not be rendered. See the export log for technical details."
        }
    }
}
