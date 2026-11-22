import Foundation

/// Named numeric measurements for one question, in a fixed order. Exported as `f_<name>` CSV
/// columns for training, and passed by name to the trained Core ML model, so the app and the
/// training data always describe a question the same way.
struct FeatureVector: Equatable, Sendable {
    private(set) var names: [String] = []
    private(set) var values: [Double] = []

    mutating func set(_ name: String, _ value: Double) {
        let finite = value.isFinite ? value : 0
        if let i = names.firstIndex(of: name) {
            values[i] = finite
        } else {
            names.append(name)
            values.append(finite)
        }
    }

    subscript(name: String) -> Double? {
        names.firstIndex(of: name).map { values[$0] }
    }
}

extension Signal {
    /// Bump when features are added, removed or redefined, so old and new data aren't mixed blindly.
    static let featureVersion = 1

    /// Features that are also expressed relative to the rest of the session (`rel_<name>`), since
    /// people differ far more from each other than one person's truths differ from their lies.
    static let sessionRelativeFeatures = ["gsr_rise_norm", "gsr_area", "hr_peak_delta", "resp_amp_ratio", "pulse_amp_ratio"]

    /// Measures the body's response to one question. `pre` is the few seconds before it was
    /// asked; `post` runs from the ask to the end of the reaction window.
    static func features(
        pre: [[Double]],
        post: [[Double]],
        baseline: Baseline,
        gsrInverted: Bool,
        kind: QuestionKind,
        answerLatency: Double?,
        stableAtAsk: Bool,
        sensors: Set<Channel> = Channel.all
    ) -> FeatureVector? {
        let preCount = pre[0].count
        guard preCount >= samples(1), post[0].count >= samples(2) else { return nil }
        func joined(_ channel: Channel) -> [Double] { pre[channel.rawValue] + post[channel.rawValue] }

        var f = FeatureVector()
        f.set("kind_relevant", kind == .relevant ? 1 : 0)
        f.set("kind_control", kind == .control ? 1 : 0)
        f.set("answer_latency", answerLatency ?? 10)
        f.set("stable_at_ask", stableAtAsk ? 1 : 0)

        // Skin conductance: how far, how fast and how long it rose.
        let a = movingAverage(arousal(joined(.gsr), inverted: gsrInverted), window: samples(0.5))
        let preLevel = mean(a[max(0, preCount - samples(2))..<preCount])
        let after = Array(a[preCount...])
        let peak = after.indices.max { after[$0] < after[$1] } ?? 0
        let rise = after[peak] - preLevel
        f.set("gsr_rise", rise)
        f.set("gsr_rise_norm", rise / baseline.gsrResponseThreshold)
        f.set("gsr_peak_latency", Double(peak) / sampleRate)
        f.set("gsr_area", after.reduce(0) { $0 + max(0, $1 - preLevel) } / sampleRate)

        // Heart rate: acceleration, and the brief slowing ("orienting response") some people show.
        let pulse = joined(.pulse)
        let beats = cycles(pulse, pulseSettings).instantaneousRates(in: 40...180)
        let preRates = beats.filter { $0.index < preCount }.map(\.rate)
        let postRates = beats.filter { $0.index >= preCount }.map(\.rate)
        let preHR = preRates.isEmpty ? baseline.heartRate : mean(preRates)
        f.set("hr_pre", preHR)
        f.set("hr_peak_delta", (postRates.max() ?? preHR) - preHR)
        f.set("hr_mean_delta", postRates.isEmpty ? 0 : mean(postRates) - preHR)
        f.set("hr_min_delta", (postRates.min() ?? preHR) - preHR)
        f.set("hr_missing", postRates.count < 2 ? 1 : 0)

        // Finger pulse amplitude shrinks when stress constricts blood vessels.
        let pulseWave = detrended(pulse, smooth: pulseSettings.smooth, detrend: pulseSettings.detrend)
        let prePulseSize = standardDeviation(pulseWave[..<preCount])
        f.set("pulse_amp_ratio", prePulseSize > 0.5 ? standardDeviation(pulseWave[preCount...]) / prePulseSize : 1)

        // Breathing: shallower or faster/slower than this person's resting baseline.
        let resp = joined(.resp)
        let breathWave = detrended(resp, smooth: breathSettings.smooth, detrend: breathSettings.detrend)
        let postDepth = 2 * 2.0.squareRoot() * standardDeviation(breathWave[preCount...])
        f.set("resp_amp_ratio", baseline.breathingAmplitude > 1 ? postDepth / baseline.breathingAmplitude : 1)
        let postRate = cycles(Array(resp[preCount...]), breathSettings).perMinute
        f.set("resp_rate_delta", (postRate ?? baseline.breathingRate) - baseline.breathingRate)

        // Data quality: a big excursion after the question (vs. before) usually means movement.
        let magnitude = pulseWave.map(abs)
        let typical = percentile(Array(magnitude[..<preCount]), 0.95) ?? 0
        f.set("motion", typical > 1 ? (magnitude[preCount...].max() ?? 0) / typical : 0)

        // A sensor that's off gets neutral values ("no change"), not noise from an empty input.
        if !sensors.contains(.gsr) {
            ["gsr_rise", "gsr_rise_norm", "gsr_peak_latency", "gsr_area"].forEach { f.set($0, 0) }
        }
        if !sensors.contains(.pulse) {
            f.set("hr_pre", baseline.heartRate)
            ["hr_peak_delta", "hr_mean_delta", "hr_min_delta"].forEach { f.set($0, 0) }
            f.set("hr_missing", 1)
            f.set("pulse_amp_ratio", 1)
        }
        if !sensors.contains(.resp) {
            f.set("resp_amp_ratio", 1)
            f.set("resp_rate_delta", 0)
        }
        if !sensors.contains(.pulse) { f.set("motion", 0) }  // motion is measured on the pulse wave
        return f
    }

    /// Adds `rel_<name>`: this question's value minus the median of the session so far
    /// (including this question). Uses only earlier questions so the live app can compute it too.
    static func addingSessionRelative(_ features: FeatureVector, prior: [FeatureVector]) -> FeatureVector {
        var result = features
        for name in sessionRelativeFeatures {
            guard let value = features[name] else { continue }
            let history = prior.compactMap { $0[name] } + [value]
            result.set("rel_" + name, value - (median(history) ?? value))
        }
        return result
    }
}
