import SwiftUI

struct VideoWorkspaceView: View {
    @Bindable var controller: ProjectController
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black

                if controller.project?.sourceVideo != nil {
                    PlayerSurfaceView(player: controller.playback.player)
                } else {
                    emptyPlayer
                }

                if controller.isLoadingVideo {
                    ZStack {
                        Color.black.opacity(0.55)
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Preparing video…")
                                .foregroundStyle(.white)
                        }
                    }
                }

                if isDropTargeted {
                    ZStack {
                        Color.accentColor.opacity(0.18)
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                            .padding(16)
                        Label("Import this movie", systemImage: "arrow.down.doc")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }

                recordingVideoOverlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                controller.handleDroppedURLs(urls)
            } isTargeted: { isTargeted in
                isDropTargeted = isTargeted
            }

            CurrentSegmentView(controller: controller)

            RecordingPanelView(controller: controller)

            PlaybackControls(controller: controller)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.bar)
        }
    }

    private var emptyPlayer: some View {
        VStack(spacing: 14) {
            Image(systemName: "film")
                .font(.system(size: 44, weight: .light))
            Text("Drop a movie here")
                .font(.title3.weight(.medium))
            Button("Choose Video…") {
                controller.showVideoImportPanel()
            }
        }
        .foregroundStyle(.white.opacity(0.78))
    }

    @ViewBuilder
    private var recordingVideoOverlay: some View {
        switch controller.recording.state {
        case .countdown(let value):
            ZStack {
                Color.black.opacity(0.18)
                VStack(spacing: 5) {
                    Text("GET READY")
                        .font(.caption.weight(.semibold))
                        .tracking(1.4)
                    Text(value.formatted())
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 38)
                .padding(.vertical, 22)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .allowsHitTesting(false)

        case .recording:
            VStack {
                HStack {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(.red)
                            .frame(width: 9, height: 9)
                        Text("REC")
                            .font(.caption.weight(.bold))
                            .tracking(0.8)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                Spacer()
            }
            .padding(18)
            .transition(.opacity)
            .allowsHitTesting(false)

        case .idle, .finishing:
            EmptyView()
        }
    }
}

private struct PlaybackControls: View {
    @Bindable var controller: ProjectController

    private var playback: PlaybackController { controller.playback }

    var body: some View {
        VStack(spacing: 10) {
            Slider(
                value: playbackPosition,
                in: controller.projectPlaybackRange.lowerBound...max(
                    controller.projectPlaybackRange.upperBound,
                    controller.projectPlaybackRange.lowerBound + 0.01
                )
            )
                .disabled(playback.duration <= 0)

            ZStack {
                HStack(spacing: 12) {
                    Text(TimeFormatter.playbackTime(controller.projectDisplayTime(playback.currentTime)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)

                    Spacer()

                    Picker("Playback", selection: $controller.mainPlaybackMode) {
                        ForEach(ProjectController.MainPlaybackMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .help("Choose whether the main player uses source audio or accepted line versions")

                    Text(TimeFormatter.playbackTime(controller.projectDuration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }

                HStack(spacing: 18) {
                    Button {
                        controller.skipMainPlayback(by: -5)
                    } label: {
                        Image(systemName: "gobackward.5")
                    }
                    .help("Back 5 Seconds")

                    Button {
                        controller.toggleMainPlayback()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])
                    .help(playback.isPlaying ? "Pause" : "Play")

                    Button {
                        controller.skipMainPlayback(by: 5)
                    } label: {
                        Image(systemName: "goforward.5")
                    }
                    .help("Forward 5 Seconds")
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var playbackPosition: Binding<Double> {
        Binding(
            get: { playback.currentTime },
            set: { controller.seekMainPlayback(to: $0) }
        )
    }
}
