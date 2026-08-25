import SwiftUI

struct WelcomeView: View {
    let controller: ProjectController
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)

            VStack(spacing: 24) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 8) {
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
                .padding(.top, 10)
            }
            .padding(60)
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
}
