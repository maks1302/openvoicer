import AppKit
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
        case .export:
            ExportInspectorView(controller: controller)
        }
    }
}

private struct DubbingInspectorView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        dubbingForm
    }

    private var dubbingForm: some View {
        Form {
            if let segment = controller.selectedSegment {
                Section("Current Line") {
                    Text(segment.text)
                        .font(.callout.weight(.medium))
                        .lineLimit(4)
                    HStack {
                        Text("\(TimeFormatter.playbackTime(segment.startTime)) – \(TimeFormatter.playbackTime(segment.endTime))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let accepted = controller.effectiveAcceptedVersion(for: segment) {
                            Label(acceptedLabel(accepted, in: segment), systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                }

                Section("Record") {
                    RecordingActionButton(controller: controller)
                        .frame(maxWidth: .infinity)
                    if controller.isPreparingMovieAudio {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(controller.sourceSeparation.isBusy
                                 ? controller.sourceSeparation.message
                                 : controller.audioPreparationMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Section("Audition Result") {
                    Picker("Result", selection: $controller.segmentPreviewMode) {
                        ForEach(SegmentMixTreatment.allCases) { treatment in
                            Text(treatment.shortTitle).tag(treatment)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .help("Choose exactly what this line should sound like in the export")

                    Label(resultDescription, systemImage: controller.segmentPreviewMode.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        controller.previewSelectedSegment()
                    } label: {
                        Label("Preview \(controller.segmentPreviewMode.title)", systemImage: "play.fill")
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canPreview(segment))

                    if controller.segmentPreviewMode == .duckedMix {
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
                    } else if controller.segmentPreviewMode == .cleanDub,
                              !controller.hasCleanBackgroundForSelectedTrack(segment) {
                        Label("Prepare the movie background before this result can be previewed.", systemImage: "waveform.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Choose Take") {
                    if segment.takes.isEmpty {
                        Text("Record a take, or choose Original above to keep this line unchanged.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Selected take", selection: selectedTakeID) {
                            ForEach(Array(segment.takes.enumerated()), id: \.element.id) { index, take in
                                Text("Take \(index + 1) · \(TimeFormatter.playbackTime(take.duration))")
                                    .tag(Optional(take.id))
                            }
                        }

                        ForEach(Array(segment.takes.enumerated()), id: \.element.id) { index, take in
                            takeRow(take, number: index + 1, selectedID: segment.selectedTakeID)
                        }
                    }
                }
                .disabled(controller.recording.isActive)

                Section {
                    Button {
                        controller.acceptSelectedVersionAndAdvance()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(acceptButtonTitle(segment))
                                    .fontWeight(.semibold)
                                Text("Save this result and open the next line")
                                    .font(.caption)
                                    .opacity(0.8)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.green)
                    .disabled(!controller.canAcceptSelectedVersion)
                }

                Section("Movie Background") {
                    voiceRemovalControl(segment)
                }
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
        guard !controller.recording.isActive else { return false }
        if controller.segmentPreviewMode != .original, segment.selectedTakeID == nil { return false }
        if controller.segmentPreviewMode == .cleanDub {
            return controller.hasCleanBackgroundForSelectedTrack(segment)
        }
        return true
    }

    private var selectedTakeID: Binding<UUID?> {
        Binding(
            get: { controller.selectedSegment?.selectedTakeID },
            set: { id in
                if let id { controller.selectTake(id) }
            }
        )
    }

    private var resultDescription: String {
        switch controller.segmentPreviewMode {
        case .original:
            "Keep the movie's original audio for this line."
        case .duckedMix:
            "Lower the original mix and layer the selected take over it."
        case .cleanDub:
            "Use the cleaned background stem with the selected take."
        case .takeOnly:
            "Play only the selected recording, without movie audio."
        }
    }

    private func acceptButtonTitle(_ segment: DubSegment) -> String {
        if controller.segmentPreviewMode == .original {
            return "Accept Original & Next"
        }
        let number = segment.takes.firstIndex { $0.id == segment.selectedTakeID }.map { $0 + 1 }
        let takeTitle = number.map { "Take \($0)" } ?? "Selected Take"
        return "Accept \(takeTitle) · \(controller.segmentPreviewMode.title)"
    }

    private func acceptedLabel(_ version: AcceptedSegmentVersion, in segment: DubSegment) -> String {
        guard let takeID = version.takeID,
              let index = segment.takes.firstIndex(where: { $0.id == takeID }) else {
            return version.treatment.title
        }
        return "T\(index + 1) · \(version.treatment.shortTitle)"
    }

    @ViewBuilder
    private func voiceRemovalControl(_ segment: DubSegment) -> some View {
        if controller.isPreparingMovieAudio {
            if controller.sourceSeparation.isBusy {
                ProgressView(value: controller.sourceSeparation.progress) {
                    Text(controller.sourceSeparation.message)
                        .lineLimit(2)
                }
            } else {
                ProgressView {
                    Text("Preparing movie audio…")
                    .lineLimit(2)
                }
            }
            Button("Cancel", role: .cancel) {
                controller.cancelSourceSeparation()
            }
        } else {
            let isPrepared = controller.hasCleanBackgroundForSelectedTrack(segment)
            if isPrepared {
                Label("Continuous movie background is ready", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                if let asset = controller.preparedAudioAsset {
                    Text(asset.strategy.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Prepare the selected audio track once. You can keep recording while it runs in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                controller.prepareMovieAudio()
            } label: {
                Label(
                    isPrepared ? "Reprepare Movie Audio" : "Prepare Movie Audio",
                    systemImage: "waveform.badge.minus"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.sourceSeparation.state == .checking || controller.isPreparingMovieAudio)
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

            Section("Movie Background") {
                LabeledContent(
                    "Recommended method",
                    value: controller.recommendedAudioPreparationStrategy.title
                )

                Text(preparationDescription)
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
                Text("Preparation runs locally and creates one continuous dialogue stem and one continuous background. Recording remains available while it runs.")
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
        } else if controller.isPreparingMovieAudio {
            ProgressView(value: controller.audioPreparationProgress) {
                Text(controller.audioPreparationMessage)
                    .lineLimit(2)
            }
            Button("Cancel", role: .cancel) {
                controller.cancelSourceSeparation()
            }
        } else if controller.project?.sourceVideo != nil {
            let isPrepared = controller.preparedAudioAsset != nil
            if isPrepared {
                Label("Continuous movie background is ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Button {
                controller.prepareMovieAudio()
            } label: {
                Label(isPrepared ? "Reprepare Movie Audio" : "Prepare Movie Audio", systemImage: "waveform.badge.minus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.project?.sourceVideo == nil || controller.sourceSeparation.state == .checking)
        } else {
            Text("Import a movie to prepare its continuous background.")
                .foregroundStyle(.secondary)
        }
    }

    private var selectedTrackID: Binding<String> {
        Binding(
            get: { controller.selectedAudioTrack?.id ?? "" },
            set: { controller.updateSelectedAudioTrack($0) }
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

    private var preparationDescription: String {
        switch controller.recommendedAudioPreparationStrategy {
        case .embeddedMusicAndEffects:
            let name = controller.musicAndEffectsCandidate?.title ?? "the detected M&E track"
            return "Use \(name) as the continuous background and derive a synchronized dialogue guide without AI."
        case .surroundAssisted:
            return "Preserve the selected surround mix while using its center channel as the dialogue reference for local AI separation."
        case .cinematicSeparation:
            return "Use local cinematic AI once for the complete selected stereo track, producing continuous dialogue and background stems."
        }
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

private struct ExportInspectorView: View {
    @Bindable var controller: ProjectController

    private var exporter: ExportController { controller.exportController }

    var body: some View {
        @Bindable var exporter = exporter

        Form {
            Section("Export Type") {
                Picker("Type", selection: $exporter.exportType) {
                    ForEach(ExportType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }

                Text(exportDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            scopeSettings(exporter: exporter)

            Section("Dub Summary") {
                LabeledContent("Accepted lines", value: acceptedLineCount.formatted())
                LabeledContent("Clean Dub", value: acceptedCount(for: .cleanDub).formatted())
                LabeledContent("Ducked Mix", value: acceptedCount(for: .duckedMix).formatted())
                LabeledContent("Take Only", value: acceptedCount(for: .takeOnly).formatted())
                LabeledContent("Original", value: acceptedCount(for: .original).formatted())
                if usesLineSelection {
                    LabeledContent("Selected lines", value: exporter.selectedLineIDs.count.formatted())
                }
            }

            exportStatus(exporter: exporter)
        }
        .formStyle(.grouped)
        .onAppear {
            exporter.configure(for: controller.playback.duration)
        }
    }

    @ViewBuilder
    private func scopeSettings(exporter: ExportController) -> some View {
        @Bindable var exporter = exporter

        switch exporter.exportType {
        case .finishedMovie:
            Section("Scope") {
                LabeledContent("Range", value: "Entire movie")
                LabeledContent("Duration", value: TimeFormatter.playbackTime(controller.playback.duration))
                Text("Unfinished lines keep their original audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .continuousClip:
            Section("Clip Range") {
                Picker("Range", selection: $exporter.clipRangeMode) {
                    ForEach(ClipRangeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if exporter.clipRangeMode == .custom {
                    TextField("Start (seconds)", value: $exporter.customStartTime, format: .number)
                    TextField("End (seconds)", value: $exporter.customEndTime, format: .number)
                    HStack {
                        Button("Set Start") {
                            exporter.customStartTime = controller.playback.currentTime
                        }
                        Button("Set End") {
                            exporter.customEndTime = controller.playback.currentTime
                        }
                    }
                    Text(
                        "\(TimeFormatter.playbackTime(exporter.customStartTime)) – \(TimeFormatter.playbackTime(exporter.customEndTime))"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    contextControl(exporter: exporter)
                }
            }

            if exporter.clipRangeMode == .selectedLines {
                lineSelection(exporter: exporter, acceptedOnly: false)
            }

        case .reviewReel:
            Section("Review Scope") {
                Picker("Lines", selection: $exporter.reviewLineMode) {
                    ForEach(ReviewLineMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                contextControl(exporter: exporter)
                Text("Overlapping clips are joined so nearby dialogue is not repeated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if exporter.reviewLineMode == .selected {
                lineSelection(exporter: exporter, acceptedOnly: true)
            }
        }
    }

    private func contextControl(exporter: ExportController) -> some View {
        @Bindable var exporter = exporter
        return Stepper(value: $exporter.contextDuration, in: 0...5, step: 0.5) {
            LabeledContent(
                "Context",
                value: exporter.contextDuration.formatted(.number.precision(.fractionLength(1))) + " s"
            )
        }
    }

    private func lineSelection(exporter: ExportController, acceptedOnly: Bool) -> some View {
        Section("Line Selection") {
            HStack {
                Button("Select Accepted") {
                    exporter.selectedLineIDs = Set(
                        (controller.project?.segments ?? [])
                            .filter { $0.status == .accepted }
                            .map(\.id)
                    )
                }
                Button("Clear") {
                    exporter.selectedLineIDs = []
                }
            }

            ForEach(Array((controller.project?.segments ?? []).enumerated()), id: \.element.id) { index, segment in
                let canSelect = !acceptedOnly || segment.status == .accepted
                Button {
                    exporter.toggleLine(segment.id)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: exporter.selectedLineIDs.contains(segment.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(exporter.selectedLineIDs.contains(segment.id) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1). \(segment.text.replacingOccurrences(of: "\n", with: " "))")
                                .lineLimit(2)
                            Text("\(TimeFormatter.playbackTime(segment.startTime)) · \(segment.status.rawValue.capitalized)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSelect)
            }
        }
    }

    @ViewBuilder
    private func exportStatus(exporter: ExportController) -> some View {
        Section("Output") {
            switch exporter.state {
            case .idle:
                Button {
                    controller.showExportPanel()
                } label: {
                    Label("Export MP4…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.project?.sourceVideo == nil)

            case .exporting:
                ProgressView(value: exporter.progress) {
                    Text(exporter.message)
                        .lineLimit(2)
                }
                Button("Cancel Export", role: .cancel) {
                    exporter.cancel()
                }

            case .completed(let url):
                Label("Export complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Export Another…") {
                    exporter.resetResult()
                    controller.showExportPanel()
                }

            case .failed(let message):
                Label("Export failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    exporter.resetResult()
                }
            }
        }
        .disabled(false)
    }

    private var acceptedLineCount: Int {
        controller.project?.segments.filter {
            controller.effectiveAcceptedVersion(for: $0) != nil
        }.count ?? 0
    }

    private func acceptedCount(for treatment: SegmentMixTreatment) -> Int {
        controller.project?.segments.filter {
            controller.effectiveAcceptedVersion(for: $0)?.treatment == treatment
        }.count ?? 0
    }

    private var usesLineSelection: Bool {
        (exporter.exportType == .continuousClip && exporter.clipRangeMode == .selectedLines)
            || (exporter.exportType == .reviewReel && exporter.reviewLineMode == .selected)
    }

    private var exportDescription: String {
        switch exporter.exportType {
        case .finishedMovie:
            "Export the complete movie with every accepted take applied."
        case .continuousClip:
            "Export one uninterrupted portion of the movie with exact boundaries."
        case .reviewReel:
            "Join dubbed-line clips into a compact performance review."
        }
    }
}
