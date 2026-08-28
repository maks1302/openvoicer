import SwiftUI

struct RecordingPanelView: View {
    @Bindable var controller: ProjectController
    @State private var waveformLayout: WaveformLayoutMode = .tracks

    var body: some View {
        if let segment = controller.selectedSegment {
            VStack(spacing: 11) {
                waveformTimeline(segment)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .background(.bar)
        }
    }

    private func waveformTimeline(_ segment: DubSegment) -> some View {
        DubbingWaveformTimelineView(
            originalSamples: controller.waveforms.originalSamples,
            takeSamples: controller.recording.isActive
                ? controller.recording.liveWaveformSamples
                : controller.waveforms.takeSamples,
            duration: segment.duration,
            playheadFraction: playheadFraction(for: segment),
            playheadTime: playheadTime(for: segment),
            isPlayheadActive: controller.playback.isPlaying
                || controller.recording.playingTakeID != nil
                || controller.recording.isRecording,
            isRecording: controller.recording.isRecording,
            isLoading: controller.waveforms.isLoading,
            layoutMode: $waveformLayout,
            onSeek: controller.seekWithinSelectedSegment(to:)
        )
    }

    private func playheadTime(for segment: DubSegment) -> TimeInterval {
        if controller.recording.isActive {
            return min(controller.recording.recordingElapsed, segment.duration)
        }
        if controller.recording.playingTakeID != nil {
            return min(controller.recording.takePlaybackElapsed, segment.duration)
        }
        return min(max(controller.playback.currentTime - segment.startTime, 0), segment.duration)
    }

    private func playheadFraction(for segment: DubSegment) -> Double {
        guard segment.duration > 0 else { return 0 }
        return playheadTime(for: segment) / segment.duration
    }
}

struct RecordingActionButton: View {
    @Bindable var controller: ProjectController

    var body: some View {
        switch controller.recording.state {
        case .idle:
            Button {
                controller.toggleRecording()
            } label: {
                Label(
                    controller.selectedSegment?.takes.isEmpty == false ? "Record Another" : "Record",
                    systemImage: "record.circle.fill"
                )
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .disabled(controller.selectedSegment == nil)

        case .countdown:
            Button {
                controller.toggleRecording()
            } label: {
                Label("Cancel Countdown", systemImage: "xmark")
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.orange)
            .help("Cancel Countdown")

        case .recording:
            Button {
                controller.toggleRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)

        case .finishing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving take…")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
