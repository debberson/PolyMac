import SwiftUI

struct ChartMarker: Identifiable, Equatable {
    let id: String
    let sample: Int
    let label: String
    let color: Color
}

struct ChartRegion: Identifiable, Equatable {
    let id: String
    let start: Int
    let end: Int
    let color: Color
}

/// A stretch of one channel that fed a question's reaction score, drawn as a coloured band.
/// `rise` adds a bracket from a reference level to a peak (the skin-conductance change).
struct ChartHighlight: Identifiable, Equatable {
    let id: String
    let channel: Channel
    let start: Int
    let end: Int
    let color: Color
    /// 0–1: how much of the reaction this part accounts for; sets the band's strength.
    let strength: Double
    let label: String
    var rise: Rise? = nil

    struct Rise: Equatable {
        var referenceStart: Int
        var from: Double
        var to: Double
    }
}

/// Live stat shown beside a channel's trace.
struct ChannelReadout: Equatable {
    var value: String
    var unit: String
    var details: [String]
}

/// One channel of the polygraph: a stats column on the left and a right-to-left scrolling trace.
struct StripChart: View {
    let channel: Channel
    let values: [Double]
    /// Absolute index one past the newest sample, so grid lines and markers scroll with the data.
    let total: Int
    let windowSamples: Int
    let readout: ChannelReadout
    let markers: [ChartMarker]
    let regions: [ChartRegion]
    var highlights: [ChartHighlight] = []
    let showMarkerLabels: Bool
    /// Vertical scale, from `ChartScales`.
    let range: ClosedRange<Double>
    let autoScale: Bool
    var onFit: () -> Void = {}
    var onZoom: (Double) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.title).font(.headline)
                Text(channel.subtitle).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(readout.value)
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(channel.color)
                    Text(readout.unit).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(readout.details, id: \.self) { line in
                    Text(line).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                scaleFooter
            }
            .frame(width: 170, alignment: .leading)
            .padding(10)

            Canvas { context, size in
                drawRegions(in: &context, size: size)
                drawHighlightBands(in: &context, size: size)
                drawGrid(in: &context, size: size)
                drawTrace(in: &context, size: size, range: range)
                drawHighlightDetails(in: &context, size: size, range: range)
                drawMarkers(in: &context, size: size)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(maxHeight: .infinity)
    }

    private var offScale: Bool {
        guard let last = values.last else { return false }
        return !range.contains(last)
    }

    private var scaleFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if !autoScale {
                    Image(systemName: "lock.fill").help("Scale is held. Turn on Auto Scale in the toolbar to follow the signal.")
                }
                Text("raw \(values.last.map { String(Int($0)) } ?? "—") · scale \(Int(range.lowerBound))–\(Int(range.upperBound))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            if !autoScale {
                HStack(spacing: 6) {
                    Button("Fit", action: onFit)
                        .help("Rescale once to the trace on screen")
                    Button { onZoom(1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Zoom out: show a wider range")
                    Button { onZoom(1 / 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Zoom in: make small changes bigger")
                    if offScale {
                        Text("off scale").foregroundStyle(.orange).help("The signal has left the held scale. Click Fit or zoom out.")
                    }
                }
                .font(.caption2)
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    private var firstSample: Int { total - windowSamples }

    private func x(forSlot slot: Int, width: CGFloat) -> CGFloat {
        width * CGFloat(slot) / CGFloat(max(windowSamples - 1, 1))
    }

    private func drawRegions(in context: inout GraphicsContext, size: CGSize) {
        for region in regions {
            let start = max(region.start - firstSample, 0)
            let end = min(region.end - firstSample, windowSamples - 1)
            guard end > start else { continue }
            let rect = CGRect(
                x: x(forSlot: start, width: size.width), y: 0,
                width: x(forSlot: end, width: size.width) - x(forSlot: start, width: size.width), height: size.height
            )
            context.fill(Path(rect), with: .color(region.color.opacity(0.1)))
        }
    }

    private func y(for value: Double, range: ClosedRange<Double>, height: CGFloat) -> CGFloat {
        let inset: CGFloat = 6
        let span = max(range.upperBound - range.lowerBound, 1e-9)
        return inset + (height - inset * 2) * CGFloat(1 - (value - range.lowerBound) / span)
    }

    private func visibleX(_ sample: Int, _ width: CGFloat) -> CGFloat {
        x(forSlot: min(max(sample - firstSample, 0), windowSamples - 1), width: width)
    }

    /// Coloured bands behind the trace, stronger for the parts that weighed more in the score.
    private func drawHighlightBands(in context: inout GraphicsContext, size: CGSize) {
        for h in highlights where h.end > firstSample && h.start < total {
            let x0 = visibleX(h.start, size.width)
            let x1 = max(visibleX(h.end, size.width), x0 + 2)
            let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)
            context.fill(Path(rect), with: .color(h.color.opacity(0.10 + 0.30 * h.strength)))
            context.fill(Path(CGRect(x: x0, y: size.height - 3, width: x1 - x0, height: 3)), with: .color(h.color.opacity(0.9)))
        }
    }

    /// The skin-response bracket (reference level → peak) and each highlight's label, over the trace.
    private func drawHighlightDetails(in context: inout GraphicsContext, size: CGSize, range: ClosedRange<Double>) {
        let labelTop: CGFloat = showMarkerLabels ? 18 : 4
        for h in highlights where h.end > firstSample && h.start < total {
            var labelX = (visibleX(h.start, size.width) + visibleX(h.end, size.width)) / 2
            var labelY = labelTop
            if let rise = h.rise {
                let xRef = visibleX(rise.referenceStart, size.width)
                let xPeak = visibleX(h.end, size.width)
                let yFrom = y(for: rise.from, range: range, height: size.height)
                let yTo = y(for: rise.to, range: range, height: size.height)
                var reference = Path()
                reference.move(to: CGPoint(x: xRef, y: yFrom))
                reference.addLine(to: CGPoint(x: xPeak, y: yFrom))
                context.stroke(reference, with: .color(h.color), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                var bracket = Path()
                bracket.move(to: CGPoint(x: xPeak, y: yFrom))
                bracket.addLine(to: CGPoint(x: xPeak, y: yTo))
                context.stroke(bracket, with: .color(h.color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: xPeak - 3.5, y: yTo - 3.5, width: 7, height: 7)), with: .color(h.color))
                labelX = xPeak
                labelY = min(max(min(yFrom, yTo) - 18, labelTop), size.height - 20)
            }
            let text = context.resolve(Text(h.label).font(.caption2.weight(.semibold)).foregroundStyle(.white))
            let textSize = text.measure(in: CGSize(width: 240, height: 20))
            let box = CGRect(
                x: min(max(labelX - textSize.width / 2 - 4, 2), size.width - textSize.width - 10),
                y: labelY, width: textSize.width + 8, height: textSize.height + 2
            )
            context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(h.color.opacity(0.92)))
            context.draw(text, at: CGPoint(x: box.midX, y: box.midY))
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var minor = Path()
        for i in 1..<4 {
            let y = size.height * CGFloat(i) / 4
            minor.move(to: CGPoint(x: 0, y: y))
            minor.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(minor, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)

        // A vertical line at every whole second, anchored to the absolute sample count.
        let perSecond = AppModel.nominalSampleRate
        let remainder = ((firstSample % perSecond) + perSecond) % perSecond
        var seconds = Path()
        var slot = (perSecond - remainder) % perSecond
        while slot < windowSamples {
            let x = x(forSlot: slot, width: size.width)
            seconds.move(to: CGPoint(x: x, y: 0))
            seconds.addLine(to: CGPoint(x: x, y: size.height))
            slot += perSecond
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

    private func drawMarkers(in context: inout GraphicsContext, size: CGSize) {
        for marker in markers {
            let slot = marker.sample - firstSample
            guard (0..<windowSamples).contains(slot) else { continue }
            let x = x(forSlot: slot, width: size.width)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(marker.color.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            if showMarkerLabels {
                context.draw(
                    Text(marker.label).font(.caption2.weight(.bold)).foregroundStyle(marker.color),
                    at: CGPoint(x: x + 3, y: 3),
                    anchor: .topLeading
                )
            }
        }
    }

}

extension AppModel {
    func readout(for channel: Channel) -> ChannelReadout {
        let s = stats
        let base = profile.baseline
        switch channel {
        case .resp:
            return ChannelReadout(
                value: s.breathingRate.map { String(format: "%.1f", $0) } ?? "—",
                unit: "breaths/min",
                details: [
                    "depth \(Int(s.breathingAmplitude))" + (base.map { " (base \(Int($0.breathingAmplitude)))" } ?? ""),
                    base.map { String(format: "baseline %.1f/min", $0.breathingRate) } ?? "uncalibrated",
                ]
            )
        case .pulse:
            var details: [String] = []
            if let hr = s.heartRate, let base {
                details.append(Self.signed(hr - base.heartRate, unit: "bpm") + " vs baseline")
            } else {
                details.append(base == nil ? "uncalibrated" : "—")
            }
            if let hrv = s.hrv {
                details.append("HRV \(Int(hrv.rmssd.rounded())) ms RMSSD")
            } else if let irregular = s.heartIrregularity {
                details.append(irregular < 0.1 ? "steady rhythm" : "variable rhythm")
            }
            return ChannelReadout(value: s.heartRate.map { String(Int($0.rounded())) } ?? "—", unit: "bpm", details: details)
        case .gsr:
            let arousal = s.gsrArousal
            let value: String
            let unit: String
            if let arousal, let base {
                value = Self.signed(arousal - base.gsrArousal, unit: nil)
                unit = "vs baseline"
            } else {
                value = s.gsrRaw.map { String(Int($0)) } ?? "—"
                unit = "level"
            }
            return ChannelReadout(
                value: value,
                unit: unit,
                details: [
                    "\(s.recentResponses) response\(s.recentResponses == 1 ? "" : "s") / 30 s",
                    String(format: "trend %+.1f/s", s.gsrSlope),
                ]
            )
        }
    }

    nonisolated static func signed(_ value: Double, unit: String?) -> String {
        let number = String(format: "%+d", Int(value.rounded()))
        return unit.map { "\(number) \($0)" } ?? number
    }
}
