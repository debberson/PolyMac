import Foundation

/// Pure signal-processing helpers. Everything works on raw ADC counts sampled at `sampleRate`.
enum Signal {
    static let sampleRate = 100.0

    static func samples(_ seconds: Double) -> Int { Int(seconds * sampleRate) }

    static func mean<C: Collection>(_ x: C) -> Double where C.Element == Double {
        x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count)
    }

    static func standardDeviation<C: Collection>(_ x: C) -> Double where C.Element == Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x)
        return (x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1)).squareRoot()
    }

    static func median(_ x: [Double]) -> Double? { percentile(x, 0.5) }

    static func percentile(_ x: [Double], _ p: Double) -> Double? {
        guard !x.isEmpty else { return nil }
        let sorted = x.sorted()
        let position = p * Double(sorted.count - 1)
        let lower = Int(position)
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// Centered moving average; the window shrinks at the edges.
    static func movingAverage(_ x: [Double], window: Int) -> [Double] {
        guard window > 1, x.count > 1 else { return x }
        var prefix = [0.0]
        prefix.reserveCapacity(x.count + 1)
        for v in x { prefix.append(prefix[prefix.count - 1] + v) }
        let half = window / 2
        return x.indices.map { i in
            let lo = max(0, i - half)
            let hi = min(x.count, i + half + 1)
            return (prefix[hi] - prefix[lo]) / Double(hi - lo)
        }
    }

    /// Least-squares slope, in units per second.
    static func slope(_ y: [Double]) -> Double {
        guard y.count > 1 else { return 0 }
        let xm = Double(y.count - 1) / 2
        let ym = mean(y)
        var num = 0.0
        var den = 0.0
        for (i, v) in y.enumerated() {
            let dx = Double(i) - xm
            num += dx * (v - ym)
            den += dx * dx
        }
        return den > 0 ? num / den * sampleRate : 0
    }

    /// Lightly smoothed signal minus its slow trend, leaving just the cycles.
    static func detrended(_ x: [Double], smooth: Double, detrend: Double) -> [Double] {
        let s = movingAverage(x, window: samples(smooth))
        let base = movingAverage(s, window: samples(detrend))
        return zip(s, base).map { $0 - $1 }
    }

    /// Sign of GSR "arousal": sweat raises skin conductance, which lowers the Grove sensor's reading.
    static func arousal(_ gsr: [Double], inverted: Bool) -> [Double] {
        inverted ? gsr.map { -$0 } : gsr
    }
}

// MARK: - Cycle detection (heartbeats, breaths)

struct CycleEstimate {
    /// Sample index where each cycle's rising edge was detected.
    var indices: [Int] = []
    /// Seconds between successive cycles.
    var intervals: [Double] = []
    /// Peak-to-peak size of the detrended wave (sinusoid-equivalent).
    var amplitude: Double = 0

    var perMinute: Double? {
        guard intervals.count >= 2, let m = Signal.median(intervals), m > 0 else { return nil }
        return 60 / m
    }

    /// Coefficient of variation of cycle lengths: ~0.05 is steady, above ~0.3 is erratic.
    var irregularity: Double? {
        guard intervals.count >= 3 else { return nil }
        let m = Signal.mean(intervals)
        return m > 0 ? Signal.standardDeviation(intervals) / m : nil
    }

    /// Beat-by-beat (or breath-by-breath) rate, keyed by the sample index that closed the cycle.
    func instantaneousRates(in valid: ClosedRange<Double>) -> [(index: Int, rate: Double)] {
        zip(indices.dropFirst(), intervals).compactMap { index, interval in
            let rate = 60 / interval
            return valid.contains(rate) ? (index, rate) : nil
        }
    }
}

extension Signal {
    struct CycleSettings {
        var smooth: Double
        var detrend: Double
        var hysteresis: Double
        var minInterval: Double
    }

    static let pulseSettings = CycleSettings(smooth: 0.05, detrend: 0.75, hysteresis: 0.4, minInterval: 0.33)
    static let breathSettings = CycleSettings(smooth: 0.3, detrend: 8, hysteresis: 0.3, minInterval: 1.5)

    /// Counts cycles as upward crossings of the detrended signal, with hysteresis so noise
    /// and the pulse wave's dicrotic notch don't double-count.
    static func cycles(_ x: [Double], _ settings: CycleSettings) -> CycleEstimate {
        var result = CycleEstimate()
        let minGap = samples(settings.minInterval)
        guard x.count >= minGap * 2 else { return result }
        let d = detrended(x, smooth: settings.smooth, detrend: settings.detrend)
        let sd = standardDeviation(d)
        result.amplitude = 2 * 2.0.squareRoot() * sd
        guard sd > 0.5 else { return result }

        let threshold = settings.hysteresis * sd
        var armed = false
        var last = Int.min / 2
        for (i, v) in d.enumerated() {
            if v < -threshold {
                armed = true
            } else if armed && v > threshold {
                armed = false
                if i - last >= minGap {
                    result.indices.append(i)
                    last = i
                }
            }
        }
        result.intervals = zip(result.indices.dropFirst(), result.indices).map { Double($0 - $1) / sampleRate }
        return result
    }

    /// Ratio of the last 2 s's biggest excursion to the window's typical one. ~1 when still; a
    /// shifted finger or a fidget spikes it.
    static func motionRatio(_ x: [Double], _ settings: CycleSettings) -> Double {
        guard x.count > samples(6) else { return 0 }
        let magnitude = detrended(x, smooth: settings.smooth, detrend: settings.detrend).map(abs)
        guard let typical = percentile(magnitude, 0.95), typical > 1 else { return 0 }
        return (magnitude.suffix(samples(2)).max() ?? 0) / typical
    }

    /// Sample indices where skin conductance rose by more than `threshold` within 2 s.
    static func skinResponses(_ arousal: [Double], threshold: Double) -> [Int] {
        let lookback = samples(2)
        let refractory = samples(3)
        var events: [Int] = []
        var i = lookback
        while i < arousal.count {
            let low = arousal[(i - lookback)..<i].min() ?? arousal[i]
            if arousal[i] - low > threshold {
                events.append(i)
                i += refractory
            } else {
                i += 5
            }
        }
        return events
    }
}

// MARK: - Live stats

struct LiveStats: Equatable {
    var secondsOfData: Double = 0
    var samplesPerSecond: Double = 0
    var heartRate: Double?
    var heartIrregularity: Double?
    var pulseAmplitude: Double = 0
    var breathingRate: Double?
    var breathingIrregularity: Double?
    var breathingAmplitude: Double = 0
    var gsrRaw: Double?
    var gsrArousal: Double?
    /// Arousal units per second over the last 10 s.
    var gsrSlope: Double = 0
    var recentResponses = 0
    var secondsSinceResponse: Double?
    var motion: Double = 0
    var railed: [Channel] = []
    var flat: [Channel] = []

    static let empty = LiveStats()
}

extension Signal {
    static func liveStats(
        channels: [[Double]],
        samplesPerSecond: Double,
        gsrInverted: Bool,
        responseThreshold: Double
    ) -> LiveStats {
        var stats = LiveStats()
        let resp = channels[Channel.resp.rawValue]
        let pulse = channels[Channel.pulse.rawValue]
        let gsr = channels[Channel.gsr.rawValue]
        stats.samplesPerSecond = samplesPerSecond
        stats.secondsOfData = Double(resp.count) / sampleRate
        guard resp.count >= samples(2) else { return stats }

        for channel in Channel.allCases {
            let recent = channels[channel.rawValue].suffix(samples(3))
            let low = recent.min() ?? 0
            let high = recent.max() ?? 0
            if high <= 5 || low >= 1018 {
                stats.railed.append(channel)
            } else if channel != .gsr && high - low < 2 {
                stats.flat.append(channel)
            }
        }

        let beats = cycles(Array(pulse.suffix(samples(15))), pulseSettings)
        stats.pulseAmplitude = beats.amplitude
        if let hr = beats.perMinute, (35...200).contains(hr) {
            stats.heartRate = hr
            stats.heartIrregularity = beats.irregularity
        }

        let breaths = cycles(resp, breathSettings)
        stats.breathingAmplitude = breaths.amplitude
        if let br = breaths.perMinute, (3...45).contains(br) {
            stats.breathingRate = br
            stats.breathingIrregularity = breaths.irregularity
        }

        let arousal = movingAverage(arousal(gsr, inverted: gsrInverted), window: samples(0.5))
        stats.gsrRaw = mean(gsr.suffix(samples(1)))
        stats.gsrArousal = mean(arousal.suffix(samples(1)))
        stats.gsrSlope = slope(Array(arousal.suffix(samples(10))))
        let responses = skinResponses(arousal, threshold: responseThreshold)
        stats.recentResponses = responses.count
        stats.secondsSinceResponse = responses.last.map { Double(arousal.count - $0) / sampleRate }

        stats.motion = max(motionRatio(resp, breathSettings), motionRatio(Array(pulse.suffix(samples(15))), pulseSettings))
        return stats
    }
}

// MARK: - Stability

struct StabilityReport: Equatable {
    enum Level: Int, Comparable {
        case stable, settling, unstable
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Check: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let level: Level
        let detail: String
    }

    var checks: [Check] = []
    var level: Level { checks.map(\.level).max() ?? .unstable }

    static let noData = StabilityReport(checks: [
        Check(name: "Signal", level: .unstable, detail: "No data. Connect a board or start the simulator."),
    ])
}

extension Signal {
    static func stability(_ s: LiveStats, baseline: Baseline?) -> StabilityReport {
        guard s.samplesPerSecond > 0 else { return .noData }
        typealias Check = StabilityReport.Check
        var checks: [Check] = []

        if s.samplesPerSecond < 80 {
            checks.append(Check(name: "Signal", level: .unstable, detail: "Only \(Int(s.samplesPerSecond)) samples/s (expected 100)"))
        } else if s.secondsOfData < 10 {
            checks.append(Check(name: "Signal", level: .settling, detail: "Collecting data… \(Int(s.secondsOfData)) of 10 s"))
        } else {
            checks.append(Check(name: "Signal", level: .stable, detail: "Streaming at \(Int(s.samplesPerSecond.rounded())) samples/s"))
        }

        if !s.railed.isEmpty {
            checks.append(Check(name: "Sensors", level: .unstable, detail: "\(names(s.railed)) stuck at 0 or 1023. Check the wiring."))
        } else if !s.flat.isEmpty {
            checks.append(Check(name: "Sensors", level: .unstable, detail: "\(names(s.flat)) not changing. Sensor loose or unplugged?"))
        } else {
            checks.append(Check(name: "Sensors", level: .stable, detail: "All three channels live"))
        }

        if s.motion > 3 {
            checks.append(Check(name: "Movement", level: .unstable, detail: "Large movement. Ask the subject to sit still."))
        } else if s.motion > 1.8 {
            checks.append(Check(name: "Movement", level: .settling, detail: "Some movement in the last 2 s"))
        } else {
            checks.append(Check(name: "Movement", level: .stable, detail: "Still"))
        }

        if let hr = s.heartRate {
            if !(40...150).contains(hr) {
                checks.append(Check(name: "Heart rate", level: .unstable, detail: "\(Int(hr)) bpm is outside 40–150. Likely a bad reading."))
            } else if let irregular = s.heartIrregularity, irregular > 0.2 {
                checks.append(Check(name: "Heart rate", level: .settling, detail: "Beat timing is erratic. Keep the finger still."))
            } else if let base = baseline, hr - base.heartRate > 15 {
                checks.append(Check(name: "Heart rate", level: .settling, detail: "\(Int(hr)) bpm, +\(Int(hr - base.heartRate)) above baseline"))
            } else {
                checks.append(Check(name: "Heart rate", level: .stable, detail: "\(Int(hr)) bpm, steady"))
            }
        } else {
            checks.append(Check(name: "Heart rate", level: .unstable, detail: "No pulse detected. Reseat the finger clip."))
        }

        if let br = s.breathingRate {
            if !(6...30).contains(br) {
                checks.append(Check(name: "Breathing", level: .settling, detail: "\(Int(br)) breaths/min is unusual"))
            } else if let irregular = s.breathingIrregularity, irregular > 0.35 {
                checks.append(Check(name: "Breathing", level: .settling, detail: "Irregular. Breathe normally."))
            } else {
                checks.append(Check(name: "Breathing", level: .stable, detail: "\(Int(br.rounded())) breaths/min, regular"))
            }
        } else if s.breathingAmplitude < 4 && s.secondsOfData >= 10 {
            checks.append(Check(name: "Breathing", level: .unstable, detail: "Almost no stretch. Tighten the chest band."))
        } else {
            checks.append(Check(name: "Breathing", level: .settling, detail: "Waiting for a few breaths"))
        }

        if let since = s.secondsSinceResponse, since < 5 {
            checks.append(Check(name: "Skin response", level: .settling, detail: "Reacted \(Int(since)) s ago. Let it settle."))
        } else if abs(s.gsrSlope) > 2 {
            checks.append(Check(name: "Skin response", level: .settling, detail: "Still drifting"))
        } else {
            checks.append(Check(name: "Skin response", level: .stable, detail: "Settled"))
        }

        return StabilityReport(checks: checks)
    }

    private static func names(_ channels: [Channel]) -> String {
        channels.map(\.title).joined(separator: ", ")
    }
}

// MARK: - Calibration

struct Baseline: Codable, Equatable {
    var heartRate: Double
    var heartRateSpread: Double
    var breathingRate: Double
    var breathingAmplitude: Double
    var gsrArousal: Double
    var gsrNoise: Double
    var seconds: Double
    var recordedAt: Date

    /// Rise in arousal units that counts as a skin response for this person.
    var gsrResponseThreshold: Double { max(4 * gsrNoise, 3) }

    static let defaults = Baseline(
        heartRate: 72, heartRateSpread: 3, breathingRate: 14, breathingAmplitude: 60,
        gsrArousal: 0, gsrNoise: 1, seconds: 0, recordedAt: .distantPast
    )
}

struct ChannelQuality: Identifiable, Equatable {
    enum Level { case good, weak, missing }
    let channel: Channel
    let level: Level
    let detail: String
    var id: Channel { channel }
}

extension Signal {
    static func calibrate(channels: [[Double]], gsrInverted: Bool) -> (Baseline, [ChannelQuality]) {
        var baseline = Baseline.defaults
        baseline.seconds = Double(channels[0].count) / sampleRate
        baseline.recordedAt = .now
        var quality: [ChannelQuality] = []

        let beats = cycles(channels[Channel.pulse.rawValue], pulseSettings)
        let rates = beats.instantaneousRates(in: 40...180).map(\.rate)
        if let hr = median(rates), rates.count >= 5 {
            baseline.heartRate = hr
            baseline.heartRateSpread = max(standardDeviation(rates), 1)
            if let irregular = beats.irregularity, irregular > 0.15 {
                quality.append(ChannelQuality(channel: .pulse, level: .weak, detail: "\(Int(hr)) bpm, but beat timing is erratic. The finger may be moving."))
            } else if beats.amplitude < 8 {
                quality.append(ChannelQuality(channel: .pulse, level: .weak, detail: "\(Int(hr)) bpm, but the pulse wave is faint. Adjust the clip."))
            } else {
                quality.append(ChannelQuality(channel: .pulse, level: .good, detail: "\(Int(hr)) bpm, clean beats"))
            }
        } else {
            quality.append(ChannelQuality(channel: .pulse, level: .missing, detail: "No heartbeat found. Using a generic 72 bpm."))
        }

        let breaths = cycles(channels[Channel.resp.rawValue], breathSettings)
        baseline.breathingAmplitude = max(breaths.amplitude, 1)
        if let br = breaths.perMinute, (4...40).contains(br) {
            baseline.breathingRate = br
            if breaths.amplitude < 10 {
                quality.append(ChannelQuality(channel: .resp, level: .weak, detail: String(format: "%.1f breaths/min, but shallow. Tighten the chest band.", br)))
            } else {
                quality.append(ChannelQuality(channel: .resp, level: .good, detail: String(format: "%.1f breaths/min", br)))
            }
        } else {
            quality.append(ChannelQuality(channel: .resp, level: .missing, detail: "No breathing cycles found. Check the stretch band."))
        }

        let raw = channels[Channel.gsr.rawValue]
        let a = arousal(raw, inverted: gsrInverted)
        baseline.gsrArousal = mean(a)
        baseline.gsrNoise = max(standardDeviation(detrended(a, smooth: 0.2, detrend: 5)), 0.5)
        let rawMean = mean(raw)
        if rawMean <= 5 || rawMean >= 1018 {
            quality.append(ChannelQuality(channel: .gsr, level: .missing, detail: "Reading stuck at \(Int(rawMean)). No skin contact?"))
        } else if abs(slope(movingAverage(a, window: samples(1)))) > 1.5 {
            quality.append(ChannelQuality(channel: .gsr, level: .weak, detail: "Level \(Int(rawMean)), still drifting. Electrodes may need time to settle."))
        } else {
            quality.append(ChannelQuality(channel: .gsr, level: .good, detail: "Level \(Int(rawMean)), steady"))
        }

        return (baseline, quality)
    }
}

// MARK: - Reaction scoring

struct ReactionScore: Codable, Equatable {
    /// Rise in skin conductance after the question, arousal units.
    var gsrDelta: Double
    /// Peak heart-rate increase after the question, bpm.
    var heartRateDelta: Double
    /// 0–1: how much shallower breathing got than baseline.
    var breathingSuppression: Double
    var gsrComponent: Double
    var heartComponent: Double
    var breathingComponent: Double
    /// 0–100 combined reaction strength.
    var index: Double
}

enum Verdict: String, Codable {
    case truthful, inconclusive, deceptive
}

struct VerdictReading: Equatable {
    var verdict: Verdict
    /// 0 = fully truthful side of the gauge, 1 = fully deceptive side.
    var gauge: Double
}

extension Signal {
    /// Scores how strongly the body reacted after a question: skin-conductance rise (weighted most,
    /// as in classic polygraph scoring), heart-rate rise, and breathing suppression.
    static func reaction(pre: [[Double]], post: [[Double]], baseline: Baseline, gsrInverted: Bool) -> ReactionScore? {
        let preCount = pre[0].count
        let postCount = post[0].count
        guard preCount >= samples(1), postCount >= samples(1) else { return nil }
        func joined(_ channel: Channel) -> [Double] { pre[channel.rawValue] + post[channel.rawValue] }

        let a = movingAverage(arousal(joined(.gsr), inverted: gsrInverted), window: samples(0.5))
        let preLevel = mean(a[max(0, preCount - samples(2))..<preCount])
        let gsrDelta = (a[preCount...].max() ?? preLevel) - preLevel
        let gsrComponent = clamp01(gsrDelta / max(6 * baseline.gsrResponseThreshold, 30))

        let beats = cycles(joined(.pulse), pulseSettings).instantaneousRates(in: 40...180)
        let preRates = beats.filter { $0.index < preCount }.map(\.rate)
        let postRates = beats.filter { $0.index >= preCount }.map(\.rate).sorted()
        let preHR = preRates.isEmpty ? baseline.heartRate : mean(preRates)
        let postHR = postRates.count >= 2
            ? (postRates[postRates.count - 1] + postRates[postRates.count - 2]) / 2
            : postRates.last ?? preHR
        let hrDelta = postHR - preHR
        let heartComponent = clamp01(hrDelta / max(4 * baseline.heartRateSpread, 10))

        // Breathing depth needs at least a couple of breaths after the question to judge.
        var suppression = 0.0
        if postCount >= samples(6) {
            let d = detrended(joined(.resp), smooth: breathSettings.smooth, detrend: breathSettings.detrend)
            let postAmplitude = 2 * 2.0.squareRoot() * standardDeviation(d[preCount...])
            suppression = clamp01(1 - postAmplitude / baseline.breathingAmplitude)
        }
        let breathingComponent = clamp01(suppression / 0.6)

        let index = 100 * (0.5 * gsrComponent + 0.3 * heartComponent + 0.2 * breathingComponent)
        return ReactionScore(
            gsrDelta: gsrDelta, heartRateDelta: hrDelta, breathingSuppression: suppression,
            gsrComponent: gsrComponent, heartComponent: heartComponent, breathingComponent: breathingComponent,
            index: index
        )
    }

    /// With control questions answered, a relevant question is judged by how much more the subject
    /// reacted to it than to the controls (the comparison-question technique). Without controls it
    /// falls back to the absolute reaction index.
    static func verdict(index: Double, controlMean: Double?, sensitivity: Double) -> VerdictReading {
        if let control = controlMean {
            let diff = index - control
            let margin = 20 - 12 * sensitivity
            let verdict: Verdict = diff > margin ? .deceptive : diff < -margin ? .truthful : .inconclusive
            return VerdictReading(verdict: verdict, gauge: clamp01(0.5 + diff / 60))
        }
        let center = 50 - 20 * (sensitivity - 0.5)
        let band = 12.0
        let verdict: Verdict = index > center + band ? .deceptive : index < center - band ? .truthful : .inconclusive
        return VerdictReading(verdict: verdict, gauge: clamp01(0.5 + (index - center) / 80))
    }
}
