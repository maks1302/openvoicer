import SwiftUI

struct WaveformView: View {
    let samples: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0, size.height > 0 else { return }
            let middle = size.height / 2
            let stride = max(samples.count / max(Int(size.width / 2), 1), 1)
            let visible = Swift.stride(from: 0, to: samples.count, by: stride).map { samples[$0] }
            let barWidth = size.width / CGFloat(max(visible.count, 1))

            var path = Path()
            for (index, sample) in visible.enumerated() {
                let height = max(CGFloat(sample) * (size.height - 4), 1)
                let x = CGFloat(index) * barWidth + barWidth / 2
                path.move(to: CGPoint(x: x, y: middle - height / 2))
                path.addLine(to: CGPoint(x: x, y: middle + height / 2))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(barWidth * 0.58, 1), lineCap: .round))
        }
        .accessibilityLabel("Audio waveform")
    }
}
