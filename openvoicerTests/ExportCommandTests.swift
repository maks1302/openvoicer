import Foundation
import Testing
@testable import OpenVoicerExport

struct ExportCommandTests {
    @Test func finishedMovieCopiesVideoAndMapsMixedAudio() {
        let arguments = ExportCommandBuilder.arguments(for: job(scope: .finishedMovie))
        let graph = filterGraph(in: arguments)

        #expect(arguments.contains("copy"))
        #expect(arguments.contains("0:v:0"))
        #expect(arguments.contains("[aout]"))
        #expect(!arguments.contains("[vout]"))
        #expect(graph.contains("aformat=sample_fmts=fltp:channel_layouts=stereo,asetpts=PTS-STARTPTS[base0]"))
    }

    @Test func continuousClipUsesExactTrimAndHardwareEncoder() {
        let arguments = ExportCommandBuilder.arguments(
            for: job(scope: .continuous(.init(start: 12.5, end: 18.25)))
        )
        let graph = filterGraph(in: arguments)

        #expect(arguments.contains("h264_videotoolbox"))
        #expect(graph.contains("trim=start=12.5:end=18.25"))
        #expect(graph.contains("atrim=start=12.5:end=18.25"))
    }

    @Test func reviewReelConcatenatesRangesAndSupportsSoftwareFallback() {
        let scope = ExportRenderScope.reviewReel([
            .init(start: 1, end: 3),
            .init(start: 8, end: 11)
        ])
        let arguments = ExportCommandBuilder.arguments(
            for: job(scope: scope),
            softwareVideoEncoding: true
        )
        let graph = filterGraph(in: arguments)

        #expect(arguments.contains("libx264"))
        #expect(graph.contains("asplit=2"))
        #expect(graph.contains("concat=n=2:v=1:a=1"))
        #expect(scope.outputDuration(sourceDuration: 30) == 5)
    }

    @Test func duckedMixKeepsConfiguredOriginalVolume() {
        let graph = filterGraph(in: ExportCommandBuilder.arguments(
            for: job(scope: .finishedMovie, lines: [line(treatment: .duckedMix)])
        ))

        #expect(graph.contains("if(lt(t,6),0.2,"))
        #expect(graph.contains("if(lt(t,3.88),1,"))
    }

    @Test func takeOnlyMutesOriginalDuringAcceptedLine() {
        let graph = filterGraph(in: ExportCommandBuilder.arguments(
            for: job(scope: .finishedMovie, lines: [line(treatment: .takeOnly)])
        ))

        #expect(graph.contains("if(lt(t,6),0,"))
        #expect(!graph.contains("if(lt(t,6),0.2,"))
    }

    @Test func adjacentLinesShareOneNonMultiplyingVolumeEnvelope() {
        let first = line(treatment: .cleanDub)
        let second = ExportLineAsset(
            segmentID: UUID(),
            startTime: 6,
            endTime: 8,
            takeURL: URL(fileURLWithPath: "/tmp/take-2.wav"),
            takeDuration: 2,
            takeGain: 1,
            backgroundURL: nil,
            backgroundPreRoll: 0,
            backgroundGain: 1,
            treatment: .cleanDub
        )
        let graph = filterGraph(in: ExportCommandBuilder.arguments(
            for: job(scope: .finishedMovie, lines: [first, second])
        ))

        #expect(graph.contains("[base0]volume='min(min(1,"))
        #expect(!graph.contains("[base1]volume="))
    }

    @Test func cleanBackgroundUsesContextForMatchedCrossfade() {
        let cleanLine = ExportLineAsset(
            segmentID: UUID(),
            startTime: 4,
            endTime: 6,
            takeURL: URL(fileURLWithPath: "/tmp/take.wav"),
            takeDuration: 2,
            takeGain: 1,
            backgroundURL: URL(fileURLWithPath: "/tmp/background.wav"),
            backgroundPreRoll: 2,
            backgroundGain: 1,
            treatment: .cleanDub
        )
        let graph = filterGraph(in: ExportCommandBuilder.arguments(
            for: job(scope: .finishedMovie, lines: [cleanLine])
        ))

        #expect(graph.contains("atrim=start=1.88:end=4.12"))
        #expect(graph.contains("afade=t=in:st=0:d=0.12"))
        #expect(graph.contains("afade=t=out:st=2.12:d=0.12"))
        #expect(graph.contains("adelay=delays=3880:all=1[background0]"))
    }

    @Test func preparedMovieAudioKeepsOneContinuousBackground() {
        var preparedJob = job(
            scope: .finishedMovie,
            lines: [line(treatment: .cleanDub)]
        )
        preparedJob.preparedDialogueURL = URL(fileURLWithPath: "/tmp/dialogue.wav")
        preparedJob.preparedBackgroundURL = URL(fileURLWithPath: "/tmp/background.wav")
        preparedJob.preparedBackgroundGain = 0.9
        preparedJob.preparedAudioTimelineStart = 117

        let arguments = ExportCommandBuilder.arguments(for: preparedJob)
        let graph = filterGraph(in: arguments)

        #expect(graph.contains("[1:a:0]"))
        #expect(graph.contains("[2:a:0]"))
        #expect(graph.contains("[preparedDialogue][preparedBackground]amix"))
        #expect(graph.contains("volume=0.9"))
        #expect(graph.components(separatedBy: "adelay=delays=117000:all=1").count == 3)
        #expect(!graph.contains("[0:a:1]aresample"))
    }

    private func job(scope: ExportRenderScope, lines: [ExportLineAsset] = []) -> ExportJob {
        ExportJob(
            sourceURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            destinationURL: URL(fileURLWithPath: "/tmp/output.mp4"),
            logURL: URL(fileURLWithPath: "/tmp/export.log"),
            sourceDuration: 30,
            audioTrackIndex: 1,
            scope: scope,
            lines: lines,
            duckedOriginalVolume: 0.2
        )
    }

    private func line(treatment: ExportMixTreatment) -> ExportLineAsset {
        ExportLineAsset(
            segmentID: UUID(),
            startTime: 4,
            endTime: 6,
            takeURL: URL(fileURLWithPath: "/tmp/take.wav"),
            takeDuration: 2,
            takeGain: 1,
            backgroundURL: nil,
            backgroundPreRoll: 0,
            backgroundGain: 1,
            treatment: treatment
        )
    }

    private func filterGraph(in arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "-filter_complex"),
              arguments.indices.contains(index + 1) else { return "" }
        return arguments[index + 1]
    }
}
