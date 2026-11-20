import SwiftUI

/// One channel of the polygraph: a label column on the left and a right-to-left scrolling trace.
struct StripChart: View {
    let channel: Channel
    let values: [Double]
    /// Samples received since reset, so grid lines scroll with the data instead of staying put.
    let total: Int
    let windowSamples: Int

    var body: some View {
        let range = Self.displayRange(for: values)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.title).font(.headline)
                Text(channel.subtitle).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(values.last.map { String(Int($0)) } ?? "—")
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(channel.color)
                Text("scale \(Int(range.lowerBound))–\(Int(range.upperBound))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            .padding(10)

            Canvas { context, size in
                drawGrid(in: &context, size: size)
                drawTrace(in: &context, size: size, range: range)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(maxHeight: .infinity)
    }

    private func x(forSlot slot: Int, width: CGFloat) -> CGFloat {
        width * CGFloat(slot) / CGFloat(max(windowSamples - 1, 1))
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var minor = Path()
        for i in 1..<4 {
            let y = size.height * CGFloat(i) / 4
            minor.move(to: CGPoint(x: 0, y: y))
            minor.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(minor, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)

        // A vertical line at every whole second, anchored to absolute sample count.
        let samplesPerSecond = AppModel.nominalSampleRate
        let firstAbsolute = total - windowSamples
        let remainder = ((firstAbsolute % samplesPerSecond) + samplesPerSecond) % samplesPerSecond
        var seconds = Path()
        var slot = (samplesPerSecond - remainder) % samplesPerSecond
        while slot < windowSamples {
            let x = x(forSlot: slot, width: size.width)
            seconds.move(to: CGPoint(x: x, y: 0))
            seconds.addLine(to: CGPoint(x: x, y: size.height))
            slot += samplesPerSecond
        }
        context.stroke(seconds, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
    }

    private func drawTrace(in context: inout GraphicsContext, size: CGSize, range: ClosedRange<Double>) {
        guard values.count > 1 else { return }
        let inset: CGFloat = 6
        let height = size.height - inset * 2
        let span = range.upperBound - range.lowerBound
        let offset = windowSamples - values.count  // new data enters from the right edge

        var trace = Path()
        for (i, value) in values.enumerated() {
            let point = CGPoint(
                x: x(forSlot: offset + i, width: size.width),
                y: inset + height * CGFloat(1 - (value - range.lowerBound) / span)
            )
            if i == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
        }
        context.stroke(trace, with: .color(channel.color), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
    }

    /// Auto-scales to the visible window, with headroom and a minimum span so a flat
    /// (or unplugged) channel doesn't magnify ADC noise to full height.
    static func displayRange(for values: [Double]) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0...1023 }
        let minimumSpan = 20.0
        let center = (low + high) / 2
        let span = max(high - low, minimumSpan) * 1.1
        return (center - span / 2)...(center + span / 2)
    }
}
