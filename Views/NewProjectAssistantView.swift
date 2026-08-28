import AVFoundation
import SwiftUI

struct NewProjectAssistantView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                movieSection
                sourceAudioSection
                projectScopeSection
                subtitleSection
                preparationSection
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 720, height: 700)
    }

    private var draft: NewProjectDraft? { controller.newProjectDraft }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Create a Dubbing Project")
                    .font(.title2.weight(.semibold))
                Text("Choose the part of the movie and how its dialogue should be handled.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(22)
    }

    @ViewBuilder
    private var movieSection: some View {
        if let draft {
            Section("Movie") {
                LabeledContent("File", value: draft.sourceURL.lastPathComponent)
                LabeledContent("Duration", value: TimeFormatter.playbackTime(draft.metadata.duration))
                LabeledContent("Resolution", value: "\(draft.metadata.width) × \(draft.metadata.height)")
                if let codec = draft.metadata.videoCodec {
                    LabeledContent("Video", value: codec.uppercased())
                }
            }
        }
    }

    @ViewBuilder
    private var sourceAudioSection: some View {
        if let draft {
            Section("Source Audio") {
                Picker("Dialogue track", selection: binding(\.selectedAudioTrackID, fallback: "")) {
                    ForEach(draft.metadata.audioTracks) { track in
                        Text(trackLabel(track)).tag(track.id)
                    }
                }

                if let selected = draft.selectedAudioTrack {
                    HStack {
                        Label(trackSummary(selected), systemImage: "speaker.wave.2")
                            .foregroundStyle(.secondary)
                        Spacer()
                        auditionButton(selected)
                    }
                }

                if let candidate = draft.musicAndEffectsCandidate {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("M&E candidate detected", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Text(trackLabel(candidate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        auditionButton(candidate)
                    }
                } else {
                    Label("No confidently labelled M&E track found", systemImage: "waveform.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }

                Text("Audition tracks before creating the project. Container labels can be wrong, especially in multilingual MKV files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var projectScopeSection: some View {
        if let draft {
            Section("Project Scope") {
                Picker("Scope", selection: binding(\.scopeMode, fallback: .fullMovie)) {
                    Text("Full Movie").tag(ProjectMediaScope.Mode.fullMovie)
                    Text("Selected Clip").tag(ProjectMediaScope.Mode.clip)
                }
                .pickerStyle(.segmented)

                ZStack {
                    Color.black
                    PlayerSurfaceView(player: controller.newProjectPreviewPlayer)
                    if controller.newProjectPreviewPlayer.currentItem == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "play.rectangle")
                                .font(.title)
                            Text("Preview the selected range")
                                .font(.callout)
                        }
                        .foregroundStyle(.white.opacity(0.65))
                    }
                    if controller.isPreparingNewProjectPreview {
                        ZStack {
                            Color.black.opacity(0.55)
                            VStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.large)
                                Text("Preparing local preview…")
                            }
                            .foregroundStyle(.white)
                        }
                    }
                }
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    controller.previewNewProjectSelection()
                } label: {
                    Label("Preview 12 Seconds at In Point", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(controller.isPreparingNewProjectPreview)

                if draft.scopeMode == .clip {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("In")
                            Text(TimeFormatter.playbackTime(draft.normalizedClipStart))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Out")
                            Text(TimeFormatter.playbackTime(draft.normalizedClipEnd))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: binding(\.clipStartTime, fallback: 0),
                            in: 0...max(draft.normalizedClipEnd - 1, 0.01)
                        )
                        Slider(
                            value: binding(\.clipEndTime, fallback: draft.metadata.duration),
                            in: min(
                                draft.normalizedClipStart + 1,
                                draft.metadata.duration
                            )...max(draft.metadata.duration, draft.normalizedClipStart + 1.01)
                        )
                        HStack {
                            TextField("Start (seconds)", value: binding(\.clipStartTime, fallback: 0), format: .number)
                            TextField("End (seconds)", value: binding(\.clipEndTime, fallback: draft.metadata.duration), format: .number)
                        }
                    }

                    LabeledContent("Clip duration", value: TimeFormatter.playbackTime(draft.selectedDuration))
                    Text("DubLab processes only this range, plus three seconds of hidden context at each edge.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("All subtitles and the complete selected audio track remain in the project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var subtitleSection: some View {
        if let draft {
            Section("Embedded Subtitles") {
                if draft.embeddedSubtitleTracks.isEmpty {
                    Label("No embedded subtitle tracks detected", systemImage: "captions.bubble")
                        .foregroundStyle(.secondary)
                } else {
                    Picker(
                        "Import",
                        selection: binding(\.selectedEmbeddedSubtitleStreamIndex, fallback: nil)
                    ) {
                        Text("Not Now").tag(nil as Int?)
                        ForEach(draft.embeddedSubtitleTracks, id: \.streamIndex) { track in
                            Text(track.displayName)
                                .tag(Optional(track.streamIndex))
                                .disabled(!track.isTextBased)
                        }
                    }
                    Text("Only subtitle events intersecting the selected clip become dubbing lines.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var preparationSection: some View {
        if let draft {
            Section("Preparation") {
                LabeledContent("Recommended", value: draft.recommendedStrategy.title)

                Picker(
                    "Method",
                    selection: binding(\.audioPreparationPreference, fallback: .automatic)
                ) {
                    ForEach(AudioPreparationPreference.allCases) { preference in
                        Text(preference.title)
                            .tag(preference)
                            .disabled(!draft.supports(preference))
                    }
                }

                Label(preparationHeadline(draft), systemImage: preparationSymbol(draft))
                    .font(.callout.weight(.medium))
                Text(preparationDetail(draft))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if draft.effectiveStrategy != nil {
                    Toggle(
                        "Prepare clean background after creating",
                        isOn: binding(\.prepareBackgroundAfterCreation, fallback: true)
                    )
                    LabeledContent("Selected audio", value: TimeFormatter.playbackTime(draft.selectedDuration))
                    LabeledContent("Approximate stem storage", value: estimatedStorage(draft))
                }

                if draft.scopeMode == .fullMovie,
                   draft.effectiveStrategy == .cinematicSeparation,
                   draft.metadata.duration > 30 * 60 {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("A short clip will prepare much faster", systemImage: "hare")
                            .foregroundStyle(.orange)
                        Button("Use a 5-Minute Clip") {
                            updateDraft {
                                $0.scopeMode = .clip
                                $0.clipStartTime = 0
                                $0.clipEndTime = min($0.metadata.duration, 300)
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                controller.dismissNewProjectAssistant()
            }
            .disabled(controller.isCreatingProjectFromDraft)
            Spacer()
            if controller.isCreatingProjectFromDraft {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Creating project…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(draft?.scopeMode == .clip ? "Create Clip Project" : "Create Project") {
                    controller.createProjectFromDraft()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft?.canCreate != true)
            }
        }
        .padding(18)
    }

    private func auditionButton(_ track: AudioTrackMetadata) -> some View {
        Button {
            controller.auditionNewProjectAudioTrack(track.id)
        } label: {
            Label(
                controller.auditioningNewProjectTrackID == track.id ? "Stop" : "Audition",
                systemImage: controller.auditioningNewProjectTrackID == track.id ? "stop.fill" : "play.fill"
            )
        }
        .controlSize(.small)
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<NewProjectDraft, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { controller.newProjectDraft?[keyPath: keyPath] ?? fallback },
            set: { value in
                updateDraft { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func updateDraft(_ update: (inout NewProjectDraft) -> Void) {
        guard var draft = controller.newProjectDraft else { return }
        update(&draft)
        if !draft.supports(draft.audioPreparationPreference) {
            draft.audioPreparationPreference = .automatic
        }
        controller.newProjectDraft = draft
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

    private func trackSummary(_ track: AudioTrackMetadata) -> String {
        [track.languageCode?.uppercased(), track.codec?.uppercased(), track.channelCount.map { "\($0) channels" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func preparationHeadline(_ draft: NewProjectDraft) -> String {
        switch draft.effectiveStrategy {
        case .embeddedMusicAndEffects: "Best preservation · no AI required"
        case .surroundAssisted: "Center-guided local separation"
        case .cinematicSeparation: "Local full-mix AI separation"
        case nil: "Instant setup · original dialogue remains"
        }
    }

    private func preparationSymbol(_ draft: NewProjectDraft) -> String {
        switch draft.effectiveStrategy {
        case .embeddedMusicAndEffects: "checkmark.seal.fill"
        case .surroundAssisted: "speaker.wave.3.fill"
        case .cinematicSeparation: "waveform.badge.minus"
        case nil: "speaker.wave.1"
        }
    }

    private func preparationDetail(_ draft: NewProjectDraft) -> String {
        switch draft.effectiveStrategy {
        case .embeddedMusicAndEffects:
            "Use the detected M&E stream as continuous background. Audition it first because container metadata is not always trustworthy."
        case .surroundAssisted:
            "Preserve the selected surround mix while using its center channel as a dialogue reference for Bandit."
        case .cinematicSeparation:
            "Run Bandit across the selected range once and cache continuous dialogue and background stems."
        case nil:
            "Skip separation and lower the original mix beneath your takes. This is fastest but cannot remove the original speaker."
        }
    }

    private func estimatedStorage(_ draft: NewProjectDraft) -> String {
        let bytesPerSecond: Double = draft.effectiveStrategy == .embeddedMusicAndEffects ? 576_000 : 384_000
        let bytes = Int64(max(draft.selectedDuration, 0) * bytesPerSecond)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
