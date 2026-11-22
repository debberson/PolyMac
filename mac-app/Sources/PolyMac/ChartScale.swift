import Observation

/// Vertical scale of each live strip chart.
///
/// - **Auto Scale on:** follows the signal, but calmly. The scale widens as soon as the trace would
///   leave it, only narrows once the trace has shrunk to well under half of it, and glides to each
///   new range instead of jumping. Small drifts never rescale.
/// - **Auto Scale off:** the scale holds still, so a change in the trace is a change in the signal.
///   Fit rescales once to what's on screen; zoom in/out keeps the centre.
@MainActor @Observable
final class ChartScales {
    /// Bumped by Fit and zoom so the charts redraw even while streaming is stopped.
    private(set) var revision = 0
    @ObservationIgnored private var shown: [Channel: ClosedRange<Double>] = [:]
    @ObservationIgnored private var target: [Channel: ClosedRange<Double>] = [:]
    @ObservationIgnored private var lastValues: [Channel: [Double]] = [:]

    static let minimumSpan = 20.0

    /// Called once per drawn frame with the visible samples.
    func range(for channel: Channel, values: [Double], auto: Bool) -> ClosedRange<Double> {
        lastValues[channel] = values
        guard let current = shown[channel] else {
            let fit = Self.fit(values)
            shown[channel] = fit
            target[channel] = fit
            return fit
        }
        guard auto else { return current }

        var goal = target[channel] ?? current
        if let low = values.min(), let high = values.max() {
            let span = goal.upperBound - goal.lowerBound
            let escaping = low < goal.lowerBound || high > goal.upperBound
            let tooLoose = high - low < 0.35 * span && span > Self.minimumSpan * 1.5
            if escaping || tooLoose {
                goal = Self.fit(values)
                target[channel] = goal
            }
        }
        // Glide about a fifth of the way per frame (a few hundred ms at 60 fps); snap when close.
        let lower = current.lowerBound + (goal.lowerBound - current.lowerBound) * 0.2
        let upper = current.upperBound + (goal.upperBound - current.upperBound) * 0.2
        let next = abs(lower - goal.lowerBound) + abs(upper - goal.upperBound) < 0.5 ? goal : lower...upper
        shown[channel] = next
        return next
    }

    /// Rescale once to the visible trace (stays put afterwards when Auto Scale is off).
    func fitNow(_ channel: Channel) {
        let fit = Self.fit(lastValues[channel] ?? [])
        shown[channel] = fit
        target[channel] = fit
        revision += 1
    }

    func fitAll() {
        Channel.allCases.forEach(fitNow)
    }

    /// factor < 1 zooms in (smaller span, bigger wiggles); > 1 zooms out.
    func zoom(_ channel: Channel, by factor: Double) {
        guard let current = shown[channel] else { return }
        let center = (current.lowerBound + current.upperBound) / 2
        let half = max((current.upperBound - current.lowerBound) * factor, Self.minimumSpan / 4) / 2
        shown[channel] = (center - half)...(center + half)
        target[channel] = shown[channel]
        revision += 1
    }

    /// The visible range plus 30% headroom, so ordinary wiggle and drift stay inside it.
    static func fit(_ values: [Double]) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0...1023 }
        let center = (low + high) / 2
        let span = max(high - low, minimumSpan) * 1.3
        return (center - span / 2)...(center + span / 2)
    }
}
