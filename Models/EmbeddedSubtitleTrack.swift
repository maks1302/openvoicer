import Foundation

struct EmbeddedSubtitleTrack: Identifiable, Hashable, Sendable {
    let streamIndex: Int
    let codec: String
    let languageCode: String?
    let title: String?

    var id: Int { streamIndex }

    var isTextBased: Bool {
        ["ass", "ssa", "subrip", "srt", "mov_text", "webvtt", "text"].contains(codec.lowercased())
    }

    var displayName: String {
        let language = languageCode?.uppercased()
        return [language, title].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " — ").nilIfEmpty ?? "Subtitle track \(streamIndex)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
