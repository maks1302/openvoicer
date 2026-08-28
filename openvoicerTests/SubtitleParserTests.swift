import Testing
@testable import OpenVoicerSubtitles

struct SubtitleParserTests {
    @Test func parsesSRTMultilineFormattingAndOverlap() throws {
        let contents = """
        1
        00:00:01,250 --> 00:00:03,500
        <i>Hello</i>
        world

        2
        00:00:03.000 --> 00:00:04.000
        Overlapping line
        """

        let result = try SRTParser().parse(contents)

        #expect(result.cues.count == 2)
        #expect(result.cues[0].startTime == 1.25)
        #expect(result.cues[0].endTime == 3.5)
        #expect(result.cues[0].text == "Hello\nworld")
        #expect(result.cues[1].startTime == 3)
    }

    @Test func recoversAfterMalformedSRTCue() throws {
        let contents = """
        1
        not-a-time --> 00:00:02,000
        Broken

        2
        00:00:03,000 --> 00:00:04,000
        Valid
        """

        let result = try SRTParser().parse(contents)

        #expect(result.cues.count == 1)
        #expect(result.skippedCueCount == 1)
        #expect(result.cues[0].text == "Valid")
    }

    @Test func parsesWebVTTCueIdentifiersSettingsAndVoiceTags() throws {
        let contents = """
        WEBVTT

        intro
        00:01.000 --> 00:03.200 position:20%
        <v Walter><i>Say my name.</i></v>

        NOTE ignored block
        This is not dialogue.

        01:02:03.400 --> 01:02:05.000
        &quot;Heisenberg.&quot;
        """

        let result = try WebVTTParser().parse(contents)

        #expect(result.cues.count == 2)
        #expect(result.cues[0].startTime == 1)
        #expect(result.cues[0].text == "Say my name.")
        #expect(result.cues[1].startTime == 3_723.4)
        #expect(result.cues[1].text == "\"Heisenberg.\"")
    }

    @Test func rejectsFileWithoutValidDialogue() {
        #expect(throws: SubtitleParserError.noValidCues) {
            try SRTParser().parse("1\ninvalid --> invalid\nNo timing")
        }
    }
}
