import Foundation

struct SubtitleCue: Hashable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

struct SubtitleParseResult: Sendable {
    let cues: [SubtitleCue]
    let skippedCueCount: Int
}

protocol SubtitleParser: Sendable {
    func parse(_ contents: String) throws -> SubtitleParseResult
}

enum SubtitleFormat: String, Sendable {
    case srt
    case webVTT = "vtt"
}

struct SubtitleParserService: Sendable {
    func parse(contents: String, format: SubtitleFormat) throws -> SubtitleParseResult {
        switch format {
        case .srt:
            try SRTParser().parse(contents)
        case .webVTT:
            try WebVTTParser().parse(contents)
        }
    }

    func parse(fileURL: URL) throws -> SubtitleParseResult {
        guard let format = SubtitleFormat(rawValue: fileURL.pathExtension.lowercased()) else {
            throw SubtitleParserError.unsupportedFormat
        }
        let contents: String
        do {
            contents = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw SubtitleParserError.invalidUTF8
        }
        return try parse(contents: contents, format: format)
    }
}

enum SubtitleParserError: LocalizedError, Equatable {
    case unsupportedFormat
    case invalidUTF8
    case noValidCues

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "DubLab currently supports SRT and WebVTT subtitle files."
        case .invalidUTF8:
            "The subtitle file is not valid UTF-8 text."
        case .noValidCues:
            "The subtitle file does not contain any valid timed dialogue."
        }
    }
}

enum SubtitleTextCleaner {
    static func clean(_ text: String) -> String {
        let withoutTags = text.replacingOccurrences(
            of: "<[^>]*>",
            with: "",
            options: .regularExpression
        )
        return withoutTags
            .replacingOccurrences(of: "\\{\\\\an\\d+\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SubtitleTimestamp {
    static func parse(_ rawValue: Substring) -> TimeInterval? {
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let timePart = value.split(separator: " ", maxSplits: 1).first.map(String.init) ?? value
        let components = timePart.split(separator: ":")
        guard components.count == 2 || components.count == 3 else { return nil }

        let hours: Double
        let minutes: Double
        let seconds: Double
        if components.count == 3 {
            guard let parsedHours = Double(components[0]),
                  let parsedMinutes = Double(components[1]),
                  let parsedSeconds = Double(components[2]) else { return nil }
            hours = parsedHours
            minutes = parsedMinutes
            seconds = parsedSeconds
        } else {
            guard let parsedMinutes = Double(components[0]),
                  let parsedSeconds = Double(components[1]) else { return nil }
            hours = 0
            minutes = parsedMinutes
            seconds = parsedSeconds
        }

        guard hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else {
            return nil
        }
        return hours * 3_600 + minutes * 60 + seconds
    }
}
