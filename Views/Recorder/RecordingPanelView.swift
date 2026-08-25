import SwiftUI

struct RecordingPanelView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        if let segment = controller.selectedSegment {
            VStack(spacing: 12) {
                waveformStack

                if !segment.takes.isEmpty {
                    takeStrip(segment)
                }

                previewControls(segment)

                HStack(spacing: 14) {
                    microphonePicker
                    inputMeter

                    Spacer()

                    recordButton

                    if !segment.takes.isEmpty {
                        Button("Accept & Next") {
                            controller.acceptSelectedTakeAndAdvance()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(controller.recording.isActive || segment.selectedTakeID == nil)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
            .onAppear {
                controller.recording.devices.refresh()
            }
        }
    }

    private var waveformStack: some View {
        VStack(spacing: 5) {
            waveformRow(label: "Original", samples: controller.waveforms.originalSamples, color: .secondary)
            waveformRow(label: "Take", samples: controller.waveforms.takeSamples, color: .accentColor)
        }
        .overlay(alignment: .trailing) {
            if controller.waveforms.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.trailing, 4)
            }
        }
    }

    private func waveformRow(label: String, samples: [Float], color: Color) -> some View {
        HStack(spacing: 9) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            ZStack {
                Capsule()
                    .fill(.secondary.opacity(0.08))
                if samples.isEmpty {
                    Rectangle()
                        .fill(.secondary.opacity(0.22))
                        .frame(height: 1)
                        .padding(.horizontal, 5)
                } else {
                    WaveformView(samples: samples, color: color)
                        .padding(.horizontal, 4)
                }
            }
            .frame(height: 27)
        }
    }

    private func previewControls(_ segment: DubSegment) -> some View {
        HStack(spacing: 10) {
            Text("PREVIEW")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Preview", selection: $controller.segmentPreviewMode) {
                Text("Original").tag(ProjectController.SegmentPreviewMode.original)
                Text("Voice").tag(ProjectController.SegmentPreviewMode.voice)
                Text("Mixed").tag(ProjectController.SegmentPreviewMode.mixed)
                Text("Clean").tag(ProjectController.SegmentPreviewMode.clean)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 290)

            Button {
                controller.previewSelectedSegment()
            } label: {
                Label("Preview", systemImage: "play.fill")
            }
            .disabled(
                controller.recording.isActive
                    || controller.sourceSeparation.isBusy
                    || (controller.segmentPreviewMode != .original && segment.selectedTakeID == nil)
                    || (controller.segmentPreviewMode == .clean && segment.separatedBackground == nil)
            )

            if controller.segmentPreviewMode == .mixed {
                Spacer()
                Text("Original")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: duckingVolume, in: 0...1)
                    .frame(width: 110)
                Text((controller.project?.settings.duckedOriginalVolume ?? 0.2).formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            } else if controller.segmentPreviewMode == .clean || controller.sourceSeparation.isBusy {
                Spacer()
                cleanBackgroundControl(segment)
            } else {
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func cleanBackgroundControl(_ segment: DubSegment) -> some View {
        if controller.sourceSeparation.isBusy {
            ProgressView(value: controller.sourceSeparation.progress)
                .frame(width: 120)
            Text(controller.sourceSeparation.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
            Button("Cancel") {
                controller.cancelSourceSeparation()
            }
            .controlSize(.small)
        } else if segment.separatedBackground != nil {
            Label("Dialogue removed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
            Button("Reprocess") {
                controller.prepareCleanBackground()
            }
            .controlSize(.small)
        } else {
            Button {
                controller.prepareCleanBackground()
            } label: {
                Label(
                    controller.sourceSeparation.state == .unavailable
                        ? "Set Up Voice Removal…"
                        : "Remove Original Voice",
                    systemImage: "waveform.badge.minus"
                )
            }
            .controlSize(.small)
            .disabled(controller.sourceSeparation.state == .checking)
            .help("Locally separate speech from music and effects. First use downloads about 1.2 GB.")
        }
    }

    private func takeStrip(_ segment: DubSegment) -> some View {
        HStack(spacing: 8) {
            Text("TAKES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(segment.takes.enumerated()), id: \.element.id) { index, take in
                        Button {
                            controller.selectTake(take.id)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: take.id == segment.selectedTakeID ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(take.id == segment.selectedTakeID ? Color.accentColor : .secondary)
                                Text("Take \(index + 1)")
                                Text(TimeFormatter.playbackTime(take.duration))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if let selectedTakeID = segment.selectedTakeID {
                Button {
                    controller.playTake(selectedTakeID)
                } label: {
                    Label(
                        controller.recording.playingTakeID == selectedTakeID ? "Stop Take" : "Play Take",
                        systemImage: controller.recording.playingTakeID == selectedTakeID ? "stop.fill" : "play.fill"
                    )
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    controller.deleteSelectedTake()
                } label: {
                    Label("Delete Take", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .help("Delete Selected Take")
            }
        }
        .disabled(controller.recording.isActive)
    }

    private var microphonePicker: some View {
        HStack(spacing: 8) {
            Picker("Microphone", selection: selectedDevice) {
                Text("System Default").tag(nil as String?)
                ForEach(controller.recording.devices.devices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 210)
            .disabled(controller.recording.isActive)

            Picker("Countdown", selection: countdownSeconds) {
                Text("No Countdown").tag(0)
                Text("1 second").tag(1)
                Text("2 seconds").tag(2)
                Text("3 seconds").tag(3)
            }
            .labelsHidden()
            .frame(width: 115)
            .disabled(controller.recording.isActive)
        }
    }

    private var inputMeter: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .foregroundStyle(controller.recording.isClipping ? .red : .secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.18))
                    Capsule()
                        .fill(controller.recording.isClipping ? Color.red : Color.green)
                        .frame(width: geometry.size.width * CGFloat(controller.recording.inputLevel))
                }
            }
            .frame(width: 72, height: 6)
        }
        .help(controller.recording.isClipping ? "Input is clipping" : "Microphone input level")
    }

    @ViewBuilder
    private var recordButton: some View {
        switch controller.recording.state {
        case .idle:
            Button {
                controller.toggleRecording()
            } label: {
                Label(controller.selectedSegment?.takes.isEmpty == false ? "Record Another" : "Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

        case .countdown(let value):
            Button {
                controller.toggleRecording()
            } label: {
                Text("\(value)")
                    .font(.title2.monospacedDigit().weight(.bold))
                    .frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .help("Cancel Countdown")

        case .recording:
            Button {
                controller.toggleRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

        case .finishing:
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 82)
        }
    }

    private var selectedDevice: Binding<String?> {
        Binding(
            get: { controller.project?.settings.selectedInputDeviceID },
            set: { controller.updateSelectedInputDevice($0) }
        )
    }

    private var countdownSeconds: Binding<Int> {
        Binding(
            get: { controller.project?.settings.recordingCountdownSeconds ?? 3 },
            set: { controller.updateRecordingCountdown($0) }
        )
    }

    private var duckingVolume: Binding<Float> {
        Binding(
            get: { controller.project?.settings.duckedOriginalVolume ?? 0.2 },
            set: { controller.updateDuckedOriginalVolume($0) }
        )
    }
}
