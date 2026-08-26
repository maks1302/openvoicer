import SwiftUI

struct ProjectView: View {
    @Bindable var controller: ProjectController
    @State private var isShowingInspector = false
    @State private var isShowingMicrophoneSettings = false
    @State private var isShowingCleaningSettings = false

    var body: some View {
        HSplitView {
            SegmentSidebarView(controller: controller)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 370)

            VideoWorkspaceView(controller: controller)
                .frame(minWidth: 620)
        }
        .navigationTitle(controller.project?.name ?? "DubLab")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    controller.showVideoImportPanel()
                } label: {
                    Label(
                        controller.project?.sourceVideo == nil ? "Import Video" : "Replace Video",
                        systemImage: "film.stack"
                    )
                }

                SubtitleImportMenu(controller: controller)

                SourceAudioTrackMenu(controller: controller)

                Button {
                    isShowingMicrophoneSettings.toggle()
                } label: {
                    Label("Microphone Settings", systemImage: "mic")
                }
                .help("Microphone Settings")
                .popover(isPresented: $isShowingMicrophoneSettings, arrowEdge: .bottom) {
                    MicrophoneSettingsView(controller: controller)
                }

                Button {
                    isShowingCleaningSettings.toggle()
                } label: {
                    Label("Dialogue Cleaning", systemImage: "waveform.badge.minus")
                }
                .help("Dialogue Cleaning")
                .popover(isPresented: $isShowingCleaningSettings, arrowEdge: .bottom) {
                    AudioCleaningSettingsView(controller: controller)
                }

                Button {
                    isShowingInspector.toggle()
                } label: {
                    Label("Project Info", systemImage: "info.circle")
                }

            }
        }
        .inspector(isPresented: $isShowingInspector) {
            ProjectInspectorView(controller: controller)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 340)
        }
    }
}

private struct ProjectInspectorView: View {
    let controller: ProjectController

    var body: some View {
        Form {
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
                }

                if !source.metadata.audioTracks.isEmpty {
                    Section("Audio") {
                        ForEach(source.metadata.audioTracks) { track in
                            LabeledContent {
                                Text(audioDescription(track))
                            } label: {
                                HStack(spacing: 5) {
                                    if track.id == controller.selectedAudioTrack?.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                    Text(track.title)
                                }
                            }
                        }
                    }
                }
            }

            if let subtitleSource = controller.project?.subtitleSource {
                Section("Dialogue") {
                    LabeledContent("Source", value: subtitleSource.displayName)
                    LabeledContent("Segments", value: controller.project?.segments.count.formatted() ?? "0")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private func audioDescription(_ track: AudioTrackMetadata) -> String {
        [
            track.codec?.uppercased(),
            track.channelCount.map { "\($0) ch" },
            track.languageCode?.uppercased()
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

private struct SourceAudioTrackMenu: View {
    @Bindable var controller: ProjectController

    var body: some View {
        Menu {
            if let tracks = controller.project?.sourceVideo?.metadata.audioTracks {
                ForEach(tracks) { track in
                    Button {
                        controller.updateSelectedAudioTrack(track.id)
                    } label: {
                        if track.id == controller.selectedAudioTrack?.id {
                            Label(trackLabel(track), systemImage: "checkmark")
                        } else {
                            Text(trackLabel(track))
                        }
                    }
                }
            }
        } label: {
            Label("Source Audio", systemImage: "speaker.wave.2")
        }
        .help("Choose the movie audio track used for playback, waveforms, and dialogue cleaning")
        .disabled(controller.project?.sourceVideo?.metadata.audioTracks.isEmpty != false)
    }

    private func trackLabel(_ track: AudioTrackMetadata) -> String {
        var parts = [track.title]
        if let language = track.languageCode, !language.isEmpty {
            parts.append(language.uppercased())
        }
        if let channels = track.channelCount {
            parts.append("\(channels) ch")
        }
        if let codec = track.codec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        return parts.joined(separator: " · ")
    }
}

private struct SubtitleImportMenu: View {
    let controller: ProjectController

    var body: some View {
        Menu {
            Button("Import SRT or WebVTT…") {
                controller.showSubtitleImportPanel()
            }

            if !controller.embeddedSubtitleTracks.isEmpty {
                Divider()
                Section("Embedded in Video") {
                    ForEach(controller.embeddedSubtitleTracks) { track in
                        Button(track.displayName) {
                            controller.importEmbeddedSubtitleTrack(track)
                        }
                        .disabled(!track.isTextBased)
                    }
                }
            }
        } label: {
            Label("Subtitles", systemImage: "captions.bubble")
        }
        .disabled(controller.project?.sourceVideo == nil || controller.isLoadingSubtitles)
    }
}
