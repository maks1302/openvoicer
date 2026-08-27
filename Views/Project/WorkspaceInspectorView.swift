import SwiftUI

struct WorkspaceInspectorView: View {
    let section: WorkspaceInspectorSection
    @Bindable var controller: ProjectController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .foregroundStyle(.tint)
                Text(section.title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            inspectorContent
        }
        .background(.bar)
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch section {
        case .dubbing:
            DubbingInspectorView(controller: controller)
        case .microphone:
            MicrophoneInspectorView(controller: controller)
        case .dialogue:
            DialogueInspectorView(controller: controller)
        case .audio:
            AudioInspectorView(controller: controller)
        case .project:
            ProjectInspectorView(controller: controller)
        }
    }
}

private struct DubbingInspectorView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        Form {
            if let segment = controller.selectedSegment {
                Section("Current Line") {
                    Text(segment.text)
                        .font(.callout.weight(.medium))
                        .lineLimit(4)
                    LabeledContent(
                        "Timing",
                        value: "\(TimeFormatter.playbackTime(segment.startTime)) – \(TimeFormatter.playbackTime(segment.endTime))"
                    )
                }

                Section("Preview") {
                    Picker("Listen to", selection: $controller.segmentPreviewMode) {
                        Text("Original").tag(ProjectController.SegmentPreviewMode.original)
                        Text("Take Only").tag(ProjectController.SegmentPreviewMode.voice)
                        Text("Quick Mix").tag(ProjectController.SegmentPreviewMode.mixed)
                        Text("Clean Dub").tag(ProjectController.SegmentPreviewMode.clean)
                    }

                    Button {
                        controller.previewSelectedSegment()
                    } label: {
                        Label("Listen", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPreview(segment))

                    if controller.segmentPreviewMode == .mixed {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Original audio")
                                Spacer()
                                Text(duckedVolume.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: duckedVolume, in: 0...1)
                        }
                    } else if controller.segmentPreviewMode == .clean,
                              !controller.hasCleanBackgroundForSelectedTrack(segment) {
                        Label("Prepare this line in the Audio inspector first.", systemImage: "waveform.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Recording") {
                    RecordingActionButton(controller: controller)
                        .frame(maxWidth: .infinity)

                    if !segment.takes.isEmpty {
                        AcceptTakeButton(controller: controller)
                            .frame(maxWidth: .infinity)
                    }
                }

                Section("Original Voice") {
                    voiceRemovalControl(segment)
                }

                Section("Takes") {
                    if segment.takes.isEmpty {
                        Text("Your recordings for this line will appear here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(segment.takes.enumerated()), id: \.element.id) { index, take in
                            takeRow(take, number: index + 1, selectedID: segment.selectedTakeID)
                        }
                    }
                }
                .disabled(controller.recording.isActive)
            } else {
                ContentUnavailableView(
                    "No Line Selected",
                    systemImage: "text.bubble",
                    description: Text("Select a dialogue line in the sidebar to begin dubbing.")
                )
            }
        }
        .formStyle(.grouped)
    }

    private func takeRow(_ take: RecordingTake, number: Int, selectedID: UUID?) -> some View {
        HStack(spacing: 8) {
            Button {
                controller.selectTake(take.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: take.id == selectedID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(take.id == selectedID ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Take \(number)")
                        Text(TimeFormatter.playbackTime(take.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                controller.playTake(take.id)
            } label: {
                Image(systemName: controller.recording.playingTakeID == take.id ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help(controller.recording.playingTakeID == take.id ? "Stop Take" : "Play Take")

            Button(role: .destructive) {
                if take.id != selectedID {
                    controller.selectTake(take.id)
                }
                controller.deleteSelectedTake()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete Take")
        }
    }

    private func canPreview(_ segment: DubSegment) -> Bool {
        guard !controller.recording.isActive, !controller.sourceSeparation.isBusy else { return false }
        if controller.segmentPreviewMode != .original, segment.selectedTakeID == nil { return false }
        if controller.segmentPreviewMode == .clean {
            return controller.hasCleanBackgroundForSelectedTrack(segment)
        }
        return true
    }

    @ViewBuilder
    private func voiceRemovalControl(_ segment: DubSegment) -> some View {
        if controller.sourceSeparation.isBusy {
            ProgressView(value: controller.sourceSeparation.progress) {
                Text(controller.sourceSeparation.message)
                    .lineLimit(2)
            }
            Button("Cancel", role: .cancel) {
                controller.cancelSourceSeparation()
            }
        } else {
            let isPrepared = controller.hasCleanBackgroundForSelectedTrack(segment)
            if isPrepared {
                Label("Original voice removed for this line", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            Button {
                controller.prepareCleanBackground()
            } label: {
                Label(
                    isPrepared ? "Reprocess Voice Removal" : "Remove Original Voice",
                    systemImage: "waveform.badge.minus"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.sourceSeparation.state == .checking)
        }
    }

    private var duckedVolume: Binding<Float> {
        Binding(
            get: { controller.project?.settings.duckedOriginalVolume ?? 0.2 },
            set: { controller.updateDuckedOriginalVolume($0) }
        )
    }
}

private struct MicrophoneInspectorView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        Form {
            Section("Input Device") {
                Picker("Microphone", selection: selectedDevice) {
                    Text("System Default").tag(nil as String?)
                    ForEach(controller.recording.devices.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .disabled(controller.recording.isActive)

                LabeledContent("Input level") {
                    InputLevelMeter(controller: controller)
                        .frame(width: 155)
                }

                if controller.recording.isClipping {
                    Label("Input is clipping. Lower the microphone gain.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("The level meter becomes active while recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recording Behavior") {
                Picker("Countdown", selection: countdownSeconds) {
                    Text("Off").tag(0)
                    Text("1 second").tag(1)
                    Text("2 seconds").tag(2)
                    Text("3 seconds").tag(3)
                }
                .disabled(controller.recording.isActive)

                Text("The countdown begins after pressing Record and is not included in the saved take.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Format") {
                LabeledContent("Sample rate", value: "48 kHz")
                LabeledContent("Channels", value: "Mono")
                LabeledContent("File format", value: "WAV · PCM")
            }
        }
        .formStyle(.grouped)
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

private struct DialogueInspectorView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        Form {
            Section("Subtitle Source") {
                if let subtitle = controller.project?.subtitleSource {
                    LabeledContent("Source", value: subtitle.displayName)
                    if let language = subtitle.languageCode {
                        LabeledContent("Language", value: language.uppercased())
                    }
                    LabeledContent("Lines", value: controller.project?.segments.count.formatted() ?? "0")
                } else {
                    Text("No subtitles have been imported.")
                        .foregroundStyle(.secondary)
                }

                Button {
                    controller.showSubtitleImportPanel()
                } label: {
                    Label("Import SRT or WebVTT…", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.project?.sourceVideo == nil || controller.isLoadingSubtitles)
            }

            if !controller.embeddedSubtitleTracks.isEmpty {
                Section("Embedded Subtitles") {
                    ForEach(controller.embeddedSubtitleTracks) { track in
                        Button {
                            controller.importEmbeddedSubtitleTrack(track)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.displayName)
                                    Text(track.codec.uppercased())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.down")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!track.isTextBased || controller.isLoadingSubtitles)
                    }
                }
            }

            if let segment = controller.selectedSegment {
                Section("Selected Line") {
                    Text(segment.text)
                        .textSelection(.enabled)
                    LabeledContent("Start", value: TimeFormatter.playbackTime(segment.startTime))
                    LabeledContent("End", value: TimeFormatter.playbackTime(segment.endTime))
                    LabeledContent("Duration", value: TimeFormatter.playbackTime(segment.duration))
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AudioInspectorView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        Form {
            Section("Source Audio") {
                if let tracks = controller.project?.sourceVideo?.metadata.audioTracks, !tracks.isEmpty {
                    Picker("Track", selection: selectedTrackID) {
                        ForEach(tracks) { track in
                            Text(trackLabel(track)).tag(track.id)
                        }
                    }

                    if let track = controller.selectedAudioTrack {
                        LabeledContent("Language", value: track.languageCode?.uppercased() ?? "Unknown")
                        LabeledContent("Channels", value: track.channelCount.map(String.init) ?? "Unknown")
                        LabeledContent("Codec", value: track.codec?.uppercased() ?? "Unknown")
                    }
                } else {
                    Text("Import a movie to choose its audio track.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Dialogue Cleaning") {
                Picker("Strength", selection: cleaningPreset) {
                    ForEach(DialogueCleaningPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text((controller.project?.settings.dialogueCleaningPreset ?? .balanced).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Background level")
                        Spacer()
                        Text(backgroundVolume.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: backgroundVolume, in: 0...1)
                }

                cleaningAction
            }

            Section {
                Text("Cleaning runs locally. Stronger removal may also soften centered music, impacts, and ambience.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var cleaningAction: some View {
        if controller.sourceSeparation.isBusy {
            ProgressView(value: controller.sourceSeparation.progress) {
                Text(controller.sourceSeparation.message)
                    .lineLimit(2)
            }
            Button("Cancel", role: .cancel) {
                controller.cancelSourceSeparation()
            }
        } else if let segment = controller.selectedSegment {
            let isPrepared = controller.hasCleanBackgroundForSelectedTrack(segment)
            if isPrepared {
                Label("Current line is prepared", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Button {
                controller.prepareCleanBackground()
            } label: {
                Label(isPrepared ? "Reprocess Line" : "Remove Original Voice", systemImage: "waveform.badge.minus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.project?.sourceVideo == nil || controller.sourceSeparation.state == .checking)
        } else {
            Text("Select a dialogue line to prepare its clean background.")
                .foregroundStyle(.secondary)
        }
    }

    private var selectedTrackID: Binding<String> {
        Binding(
            get: { controller.selectedAudioTrack?.id ?? "" },
            set: { controller.updateSelectedAudioTrack($0) }
        )
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

    private func trackLabel(_ track: AudioTrackMetadata) -> String {
        [
            track.title,
            track.languageCode?.uppercased(),
            track.channelCount.map { "\($0) ch" }
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

private struct ProjectInspectorView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        Form {
            if let project = controller.project {
                Section("Project") {
                    LabeledContent("Name", value: project.name)
                    LabeledContent("Dialogue lines", value: project.segments.count.formatted())
                    LabeledContent("Accepted", value: project.segments.filter { $0.status == .accepted }.count.formatted())
                    LabeledContent("Modified", value: project.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if let source = controller.project?.sourceVideo {
                Section("Source Video") {
                    LabeledContent("File", value: source.displayName)
                    LabeledContent("Duration", value: TimeFormatter.playbackTime(source.metadata.duration))
                    LabeledContent("Resolution", value: "\(source.metadata.width) × \(source.metadata.height)")
                    if let frameRate = source.metadata.frameRate {
                        LabeledContent(
                            "Frame rate",
                            value: frameRate.formatted(.number.precision(.fractionLength(0...2))) + " fps"
                        )
                    }
                    if let codec = source.metadata.videoCodec {
                        LabeledContent("Video codec", value: codec.uppercased())
                    }

                    Button {
                        controller.showVideoImportPanel()
                    } label: {
                        Label("Replace Source Video…", systemImage: "film.stack")
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                Section("Source Video") {
                    Button {
                        controller.showVideoImportPanel()
                    } label: {
                        Label("Import Video…", systemImage: "film.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section("Privacy") {
                Label("Media stays on this Mac", systemImage: "lock.shield")
                Text("DubLab does not upload your movie or recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
