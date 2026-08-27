import SwiftUI

struct SegmentSidebarView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let segments = controller.project?.segments, !segments.isEmpty {
                segmentList(segments)
            } else if controller.project?.sourceVideo != nil {
                subtitleEmptyState
            } else {
                ContentUnavailableView {
                    Label("No Video", systemImage: "film")
                } description: {
                    Text("Import a source movie to begin.")
                }
            }
        }
        .background(.bar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.project?.name ?? "Project")
                        .font(.headline)
                        .lineLimit(1)
                    if let source = controller.project?.sourceVideo {
                        Text(source.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if controller.isLoadingSubtitles {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let project = controller.project, !project.segments.isEmpty {
                let completed = project.segments.filter { $0.status == .accepted }.count
                Text("\(completed) / \(project.segments.count) lines completed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private func segmentList(_ segments: [DubSegment]) -> some View {
        List(selection: selection) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                SegmentRow(index: index + 1, segment: segment)
                    .tag(segment.id)
            }
        }
        .listStyle(.sidebar)
    }

    private var subtitleEmptyState: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Add Dialogue")
                    .font(.headline)
                Text("Use subtitles embedded in the movie, or import an SRT or WebVTT file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if !controller.embeddedSubtitleTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EMBEDDED SUBTITLES")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(controller.embeddedSubtitleTracks) { track in
                            Button {
                                controller.importEmbeddedSubtitleTrack(track)
                            } label: {
                                HStack {
                                    Image(systemName: "captions.bubble.fill")
                                    Text(track.displayName)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(track.codec.uppercased())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!track.isTextBased || controller.isLoadingSubtitles)
                        }
                    }
                    .padding(.top, 8)
                }

                Button("Import SRT or WebVTT…") {
                    controller.showSubtitleImportPanel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isLoadingSubtitles)
            }
            .padding(24)
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { controller.selectedSegmentID },
            set: { controller.selectSegment($0) }
        )
    }
}

private struct SegmentRow: View {
    let index: Int
    let segment: DubSegment

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(index.formatted(.number.grouping(.never)))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let treatment = segment.acceptedVersion?.treatment {
                        Text(treatment.shortTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    Text(TimeFormatter.playbackTime(segment.duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(segment.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.callout)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusSymbol: String {
        switch segment.status {
        case .pending: "circle"
        case .recorded: "circle.fill"
        case .accepted: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    private var statusColor: Color {
        switch segment.status {
        case .pending: .secondary
        case .recorded: .orange
        case .accepted: .green
        case .skipped: .secondary
        }
    }
}
