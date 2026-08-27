import SwiftUI

struct InputLevelMeter: View {
    @Bindable var controller: ProjectController

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: controller.recording.isClipping ? "exclamationmark.triangle.fill" : "mic.fill")
                .foregroundStyle(controller.recording.isClipping ? .red : .secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.18))
                    Capsule()
                        .fill(controller.recording.isClipping ? Color.red : Color.green)
                        .frame(width: geometry.size.width * CGFloat(controller.recording.inputLevel))
                }
            }
            .frame(height: 6)
        }
        .help(controller.recording.isClipping ? "Input is clipping" : "Microphone input level")
    }
}
