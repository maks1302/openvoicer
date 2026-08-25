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
}
