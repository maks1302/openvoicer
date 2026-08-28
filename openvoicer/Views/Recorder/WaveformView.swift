import SwiftUI

enum WaveformLayoutMode: String, CaseIterable, Identifiable {
    case tracks
    case overlay

    var id: Self { self }

    var title: String {
        switch self {
        case .tracks: "Tracks"
        case .overlay: "Overlay"
        }
    }
}

struct DubbingWaveformTimelineView: View {
    let originalSamples: [Float]
    let takeSamples: [Float]
    let duration: TimeInterval
    let playheadFraction: Double
    let playheadTime: TimeInterval
    let isPlayheadActive: Bool
    let isRecording: Bool
    let isLoading: Bool
    @Binding var layoutMode: WaveformLayoutMode
    let onSeek: (Double) -> Void

    private let labelWidth: CGFloat = 62
    private let rulerHeight: CGFloat = 21

    var body: some View {
        VStack(spacing: 7) {
            header

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black.opacity(0.16))

                Canvas(rendersAsynchronously: true) { context, size in
                    drawTimeline(context: &context, size: size)
                }

                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let width = max(geometry.size.width - labelWidth, 1)
                                    let fraction = (value.location.x - labelWidth) / width
                                    onSeek(min(max(Double(fraction), 0), 1))
                                }
                        )
                }
                .allowsHitTesting(!isRecording)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .frame(height: 132)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            }
            .help(isRecording ? "Recording is shown live" : "Click or drag to seek within this line")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Original and recorded audio waveforms")
            .accessibilityValue(accessibilityValue)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Audio alignment", systemImage: "waveform.path")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if isRecording {
                Label("Recording", systemImage: "record.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
            } else if isPlayheadActive {
                Text(TimeFormatter.playbackTime(playheadTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Waveform layout", selection: $layoutMode) {
                ForEach(WaveformLayoutMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 142)
        }
    }

    private var accessibilityValue: String {
        let position = TimeFormatter.playbackTime(playheadTime)
        let total = TimeFormatter.playbackTime(duration)
        return "Position \(position) of \(total). \(layoutMode.title) view."
    }

    private func drawTimeline(context: inout GraphicsContext, size: CGSize) {
        guard size.width > labelWidth, size.height > rulerHeight else { return }

        let plot = CGRect(
            x: labelWidth,
            y: rulerHeight,
            width: size.width - labelWidth,
            height: size.height - rulerHeight
        )

        drawGrid(context: &context, plot: plot)

        switch layoutMode {
        case .tracks:
            let laneHeight = plot.height / 2
            let sourceLane = CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: laneHeight)
            let takeLane = CGRect(x: plot.minX, y: sourceLane.maxY, width: plot.width, height: laneHeight)

            drawLaneDivider(context: &context, y: takeLane.minY, plot: plot)
            drawLabel("SOURCE", context: &context, centerY: sourceLane.midY, color: .secondary)
            drawLabel(isRecording ? "LIVE" : "TAKE", context: &context, centerY: takeLane.midY, color: isRecording ? .red : .orange)
            drawWaveform(originalSamples, context: &context, rect: sourceLane.insetBy(dx: 0, dy: 7), color: .cyan, opacity: 0.55)
            drawWaveform(takeSamples, context: &context, rect: takeLane.insetBy(dx: 0, dy: 7), color: isRecording ? .red : .orange, opacity: 0.72)

        case .overlay:
            drawLabel("SOURCE", context: &context, centerY: plot.midY - 8, color: .cyan)
            drawLabel(isRecording ? "LIVE" : "TAKE", context: &context, centerY: plot.midY + 8, color: isRecording ? .red : .orange)
            let waveformRect = plot.insetBy(dx: 0, dy: 12)
            drawWaveform(originalSamples, context: &context, rect: waveformRect, color: .cyan, opacity: 0.34)
            drawWaveform(takeSamples, context: &context, rect: waveformRect, color: isRecording ? .red : .orange, opacity: 0.62)
        }

        drawPlayhead(context: &context, plot: plot)
    }

    private func drawGrid(context: inout GraphicsContext, plot: CGRect) {
        for index in 0...4 {
            let fraction = CGFloat(index) / 4
            let x = plot.minX + plot.width * fraction
            var line = Path()
            line.move(to: CGPoint(x: x, y: rulerHeight))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(.white.opacity(index == 0 ? 0.11 : 0.07)), lineWidth: 1)

            let timestamp = duration * Double(fraction)
            let text = Text(TimeFormatter.playbackTime(timestamp))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            let anchor: UnitPoint = index == 0 ? .topLeading : (index == 4 ? .topTrailing : .top)
            context.draw(text, at: CGPoint(x: x, y: 4), anchor: anchor)
        }
    }

    private func drawLaneDivider(context: inout GraphicsContext, y: CGFloat, plot: CGRect) {
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(line, with: .color(.white.opacity(0.08)), lineWidth: 1)
    }

    private func drawLabel(
        _ value: String,
        context: inout GraphicsContext,
        centerY: CGFloat,
        color: Color
    ) {
        let text = Text(value)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color.opacity(0.85))
        context.draw(text, at: CGPoint(x: 9, y: centerY), anchor: .leading)
    }

    private func drawWaveform(
        _ samples: [Float],
        context: inout GraphicsContext,
        rect: CGRect,
        color: Color,
        opacity: Double
    ) {
        guard !samples.isEmpty, rect.width > 0, rect.height > 0 else {
            var baseline = Path()
            baseline.move(to: CGPoint(x: rect.minX, y: rect.midY))
            baseline.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.stroke(baseline, with: .color(color.opacity(0.2)), lineWidth: 1)
            return
        }

        let count = samples.count
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))

        for index in samples.indices {
            let fraction = count == 1 ? 0 : CGFloat(index) / CGFloat(count - 1)
            let amplitude = displayedAmplitude(samples[index])
            path.addLine(to: CGPoint(
                x: rect.minX + fraction * rect.width,
                y: rect.midY - amplitude * rect.height / 2
            ))
        }
        for index in samples.indices.reversed() {
            let fraction = count == 1 ? 0 : CGFloat(index) / CGFloat(count - 1)
            let amplitude = displayedAmplitude(samples[index])
            path.addLine(to: CGPoint(
                x: rect.minX + fraction * rect.width,
                y: rect.midY + amplitude * rect.height / 2
            ))
        }
        path.closeSubpath()

        context.fill(path, with: .color(color.opacity(opacity)))
        context.stroke(path, with: .color(color.opacity(min(opacity + 0.18, 1))), lineWidth: 0.7)
    }

    private func drawPlayhead(context: inout GraphicsContext, plot: CGRect) {
        let fraction = CGFloat(min(max(playheadFraction, 0), 1))
        let x = plot.minX + plot.width * fraction
        let color: Color = isRecording ? .red : .accentColor

        var line = Path()
        line.move(to: CGPoint(x: x, y: rulerHeight - 1))
        line.addLine(to: CGPoint(x: x, y: plot.maxY))
        context.stroke(line, with: .color(color.opacity(isPlayheadActive ? 1 : 0.72)), lineWidth: 1.5)

        var marker = Path()
        marker.move(to: CGPoint(x: x - 4.5, y: rulerHeight - 1))
        marker.addLine(to: CGPoint(x: x + 4.5, y: rulerHeight - 1))
        marker.addLine(to: CGPoint(x: x, y: rulerHeight + 5))
        marker.closeSubpath()
        context.fill(marker, with: .color(color))
    }

    /// Uses a fixed -54 dB display floor so source and take remain comparable.
    private func displayedAmplitude(_ sample: Float) -> CGFloat {
        guard sample > 0 else { return 0 }
        let decibels = 20 * log10(Double(max(sample, 0.000_1)))
        return CGFloat(min(max((decibels + 54) / 54, 0), 1))
    }
}
