import SwiftUI

struct WelcomeView: View {
    let controller: ProjectController
    @State private var isDropTargeted = false
    @State private var hoveredProjectID: UUID?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)

            VStack(spacing: 28) {
                welcomeHeader

                if !controller.recentProjects.projects.isEmpty {
                    recentProjects
                }

                dropHint
            }
            .frame(maxWidth: 680)
            .padding(48)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(20)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            controller.handleDroppedURLs(urls)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
    }

    private var welcomeHeader: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 7) {
                Text("DubLab")
                    .font(.largeTitle.weight(.semibold))
                Text("Create a local dubbing project from any movie.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("New Project…") {
                    controller.showNewProjectPanel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Open Project…") {
                    controller.showOpenProjectPanel()
                }
                .controlSize(.large)
            }
        }
    }

    private var recentProjects: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Recent Projects")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    controller.recentProjects.removeAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Clear Recent Projects")
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(controller.recentProjects.projects.enumerated()), id: \.element.id) { index, project in
                        recentProjectRow(project)
                        if index < controller.recentProjects.projects.count - 1 {
                            Divider()
                                .padding(.leading, 46)
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(controller.recentProjects.projects.count) * 57, 285))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator.opacity(0.45))
            }
        }
    }

    private func recentProjectRow(_ project: RecentProject) -> some View {
        let isAvailable = controller.recentProjects.isAvailable(project)

        return Button {
            controller.openRecentProject(project)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isAvailable ? "waveform.and.mic" : "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(isAvailable ? Color.accentColor : .orange)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text(project.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    Text(project.sourceVideoName ?? "No source movie imported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                if isAvailable {
                    Text(project.lastOpenedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.quaternary)
                } else {
                    Text("Missing")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(hoveredProjectID == project.id ? Color.primary.opacity(0.055) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredProjectID = isHovering ? project.id : nil
        }
        .contextMenu {
            Button("Remove from Recent Projects") {
                controller.recentProjects.remove(project)
            }
        }
        .help(isAvailable ? project.lastKnownPath : "The project has moved or is no longer available")
    }

    private var dropHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.title2)
            Text("Or drop a movie here")
                .font(.callout.weight(.medium))
            Text("The movie stays in its original location.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
    }
}
