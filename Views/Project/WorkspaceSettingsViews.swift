import SwiftUI

struct MicrophoneSettingsView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Recording", systemImage: "mic.fill")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Microphone")
                    Picker("Microphone", selection: selectedDevice) {
                        Text("System Default").tag(nil as String?)
                        ForEach(controller.recording.devices.devices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }

                GridRow {
                    Text("Countdown")
                    Picker("Countdown", selection: countdownSeconds) {
                        Text("Off").tag(0)
                        Text("1 second").tag(1)
                        Text("2 seconds").tag(2)
                        Text("3 seconds").tag(3)
                    }
                    .labelsHidden()
                    .frame(width: 120, alignment: .leading)
                }

                GridRow {
                    Text("Input level")
                    InputLevelMeter(controller: controller)
                        .frame(width: 210)
                }
            }
            .disabled(controller.recording.isActive)

            Text("The level meter becomes active while recording. Red indicates clipping.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { controller.recording.devices.refresh() }
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
}

struct AudioCleaningSettingsView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Dialogue Cleaning", systemImage: "waveform.badge.minus")
                .font(.headline)

            Picker("Cleaning", selection: cleaningPreset) {
                ForEach(DialogueCleaningPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            if let preset = controller.project?.settings.dialogueCleaningPreset {
                Text(preset.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Background level")
                Slider(value: backgroundVolume, in: 0...1)
                Text((controller.project?.settings.cleanBackgroundVolume ?? 1).formatted(
                    .percent.precision(.fractionLength(0))
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            }

            Divider()

            if controller.sourceSeparation.isBusy {
                ProgressView(value: controller.sourceSeparation.progress) {
                    Text(controller.sourceSeparation.message)
                        .lineLimit(1)
                }
                Button("Cancel") { controller.cancelSourceSeparation() }
            } else if let segment = controller.selectedSegment {
                HStack {
                    let hasCurrentBackground = controller.hasCleanBackgroundForSelectedTrack(segment)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasCurrentBackground ? "Current line has a cached background" : "Current line is not cleaned")
                        if hasCurrentBackground {
                            Text("Reprocess to apply the selected preset.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(hasCurrentBackground ? "Reprocess" : "Clean Line") {
                        controller.prepareCleanBackground()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Select a dialogue line to prepare its clean background.")
                    .foregroundStyle(.secondary)
            }

            Text("Cleaning is local. Stronger removal can also reduce sounds mixed near the center, including music, impacts, and ambience.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 410)
    }

    private var cleaningPreset: Binding<DialogueCleaningPreset> {
        Binding(
            get: { controller.project?.settings.dialogueCleaningPreset ?? .balanced },
            set: { controller.updateDialogueCleaningPreset($0) }
        )
    }

    private var backgroundVolume: Binding<Float> {
        Binding(
            get: { controller.project?.settings.cleanBackgroundVolume ?? 1 },
            set: { controller.updateCleanBackgroundVolume($0) }
        )
    }
}

struct InputLevelMeter: View {
    @Bindable var controller: ProjectController

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: controller.recording.isClipping ? "exclamationmark.triangle.fill" : "mic.fill")
                .foregroundStyle(controller.recording.isClipping ? .red : .secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.18))
                    Capsule()
                        .fill(controller.recording.isClipping ? Color.red : Color.green)
                        .frame(width: geometry.size.width * CGFloat(controller.recording.inputLevel))
                }
            }
            .frame(height: 6)
        }
        .help(controller.recording.isClipping ? "Input is clipping" : "Microphone input level")
    }
}
