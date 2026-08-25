import Foundation

struct SRTParser: SubtitleParser {
    func parse(_ contents: String) throws -> SubtitleParseResult {
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var cues: [SubtitleCue] = []
        var skipped = 0
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.contains("-->") else {
                index += 1
                continue
            }

            let timingParts = line.components(separatedBy: "-->")
            guard timingParts.count == 2 else {
                skipped += 1
                index += 1
                continue
            }
            let startRaw = timingParts[0].trimmingCharacters(in: .whitespaces)
            let endRaw = timingParts[1].trimmingCharacters(in: .whitespaces)
            index += 1

            var textLines: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(String(lines[index]))
                index += 1
            }

            guard let start = SubtitleTimestamp.parse(Substring(startRaw)),
                  let end = SubtitleTimestamp.parse(Substring(endRaw)),
                  end > start else {
                skipped += 1
                continue
            }
            let text = SubtitleTextCleaner.clean(textLines.joined(separator: "\n"))
            guard !text.isEmpty else {
                skipped += 1
                continue
            }
            cues.append(SubtitleCue(startTime: start, endTime: end, text: text))
        }

        guard !cues.isEmpty else { throw SubtitleParserError.noValidCues }
        return SubtitleParseResult(cues: cues, skippedCueCount: skipped)
    }
}
