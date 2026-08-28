import Foundation

struct VideoMetadata: Codable, Hashable, Sendable {
    var duration: TimeInterval
    var width: Int
    var height: Int
    var frameRate: Double?
    var videoCodec: String?
    var audioTracks: [AudioTrackMetadata]

    static let empty = VideoMetadata(
        duration: 0,
        width: 0,
        height: 0,
        frameRate: nil,
        videoCodec: nil,
        audioTracks: []
    )
}

struct AudioTrackMetadata: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var languageCode: String?
    var codec: String?
    var channelCount: Int?

    var isLikelyMusicAndEffects: Bool {
        let raw = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let symbolic = raw.filter { !$0.isWhitespace }
        let normalized = raw
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let compact = normalized.filter { $0.isLetter || $0.isNumber }
        return symbolic == "m&e"
            || symbolic == "m+e"
            || normalized.contains("music and effects")
            || normalized.contains("music effects")
            || normalized.contains("international mix")
            || normalized.contains("international version")
            || normalized.contains("dialogue free")
            || compact == "me"
            || compact == "mxe"
            || compact == "dme"
    }
}
