import SwiftUI

struct ProjectView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        HSplitView {
            ProjectSidebar(controller: controller)
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 310)

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

                Button {
                    controller.save()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
            }
        }
    }
}

private struct ProjectSidebar: View {
    let controller: ProjectController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PROJECT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            if let source = controller.project?.sourceVideo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label {
                            Text(source.displayName)
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: "film")
                                .foregroundStyle(.tint)
                        }
                        .font(.headline)

                        Divider()

                        MetadataSection(metadata: source.metadata)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView {
                    Label("No Video", systemImage: "film")
                } description: {
                    Text("Import a source movie to begin.")
                }
            }

            Spacer(minLength: 0)

            if let url = controller.projectURL {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(12)
            }
        }
        .background(.bar)
    }
}

private struct MetadataSection: View {
    let metadata: VideoMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VIDEO")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            MetadataRow(label: "Duration", value: TimeFormatter.playbackTime(metadata.duration))
            MetadataRow(label: "Resolution", value: "\(metadata.width) × \(metadata.height)")
            if let frameRate = metadata.frameRate {
                MetadataRow(label: "Frame rate", value: frameRate.formatted(.number.precision(.fractionLength(0...2))) + " fps")
            }
            if let codec = metadata.videoCodec {
                MetadataRow(label: "Codec", value: codec.uppercased())
            }

            if !metadata.audioTracks.isEmpty {
                Text("AUDIO")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                ForEach(metadata.audioTracks) { track in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.callout.weight(.medium))
                        Text(audioDescription(track))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func audioDescription(_ track: AudioTrackMetadata) -> String {
        [
            track.codec?.uppercased(),
            track.channelCount.map { "\($0) ch" },
            track.languageCode
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}
