import SwiftUI

struct CurrentSegmentView: View {
    let controller: ProjectController

    var body: some View {
        if let segment = controller.selectedSegment {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("CURRENT LINE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(TimeFormatter.playbackTime(segment.startTime)) – \(TimeFormatter.playbackTime(segment.endTime))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(segment.text)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .center)
                    .padding(.horizontal, 18)

                HStack {
                    Button {
                        controller.selectPreviousSegment()
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }

                    Spacer()

                    Button {
                        controller.playSelectedSegmentWithContext()
                    } label: {
                        Label("Context", systemImage: "arrow.left.and.right")
                    }

                    Button {
                        controller.playSelectedSegment()
                    } label: {
                        Label("Play Original", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    Button {
                        controller.selectNextSegment()
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)
        }
    }
}
