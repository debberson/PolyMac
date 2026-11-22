import Foundation

// MARK: - Heart rate variability

struct HeartRateVariability: Equatable {
    /// Root mean square of successive beat-interval differences, ms. Mostly reflects the vagal
    /// ("rest and digest") brake on the heart: higher when relaxed, lower under stress.
    var rmssd: Double
    /// Standard deviation of beat intervals, ms. Overall variability, including slow swings.
    var sdnn: Double
    var beats: Int
    var meanHeartRate: Double
}

extension Signal {
    /// Time (s) of each heartbeat's systolic peak, refined between samples with a parabola fit,
    /// so beat timing isn't limited to the 10 ms sample spacing.
    static func beatTimes(_ pulse: [Double]) -> [Double] {
        let estimate = cycles(pulse, pulseSettings)
        guard !estimate.indices.isEmpty else { return [] }
        let smooth = movingAverage(pulse, window: samples(0.03))
        let searchWindow = samples(0.3)
        var times: [Double] = []
        for start in estimate.indices {
            let end = min(smooth.count - 1, start + searchWindow)
            guard end - start >= 2 else { continue }
            var peak = start
            for j in start...end where smooth[j] > smooth[peak] { peak = j }
            var offset = 0.0
            if peak > 0 && peak < smooth.count - 1 {
                let a = smooth[peak - 1], b = smooth[peak], c = smooth[peak + 1]
                let curvature = a - 2 * b + c
                if curvature < 0 { offset = 0.5 * (a - c) / curvature }
            }
            times.append((Double(peak) + offset) / sampleRate)
        }
        return times
    }

    /// Beat-to-beat intervals (s) with artifacts removed: impossible intervals, and ones more than
    /// 25% off the local median (missed or extra beats).
    static func cleanIntervals(_ beatTimes: [Double]) -> [Double] {
        let raw = zip(beatTimes.dropFirst(), beatTimes).map { $0 - $1 }.filter { (0.3...1.5).contains($0) }
        guard raw.count >= 3 else { return raw }
        return raw.indices.compactMap { i in
            let neighborhood = Array(raw[max(0, i - 5)...min(raw.count - 1, i + 5)])
            guard let local = median(neighborhood) else { return nil }
            return abs(raw[i] - local) <= 0.25 * local ? raw[i] : nil
        }
    }

    static func heartRateVariability(_ pulse: [Double]) -> HeartRateVariability? {
        let intervals = cleanIntervals(beatTimes(pulse))
        guard intervals.count >= 8 else { return nil }
        let successive = zip(intervals.dropFirst(), intervals).map { ($0 - $1) * 1000 }
        let rmssd = (successive.reduce(0) { $0 + $1 * $1 } / Double(successive.count)).squareRoot()
        return HeartRateVariability(
            rmssd: rmssd,
            sdnn: standardDeviation(intervals) * 1000,
            beats: intervals.count + 1,
            meanHeartRate: 60 / mean(intervals)
        )
    }
}

// MARK: - Segment statistics

struct SegmentStats: Equatable {
    var seconds: Double
    var heartRate: Double?
    var hrv: HeartRateVariability?
    var breathingRate: Double?
    var breathingDepth: Double
    /// Mean skin conductance in "arousal" units (higher = more sweat), and the raw reading.
    var gsrArousal: Double
    var gsrRaw: Double
    var responsesPerMinute: Double
}

struct MarkerResponse: Equatable {
    /// Skin-conductance rise in the 10 s after the marker (arousal units).
    var gsrRise: Double
    /// Peak heart-rate change in the 10 s after the marker (bpm).
    var heartRateChange: Double
    /// Seconds from the marker to the skin-conductance peak.
    var peakLatency: Double
}

extension Signal {
    static func segmentStats(_ channels: [[Double]], range: Range<Int>, gsrInverted: Bool, responseThreshold: Double) -> SegmentStats {
        let lower = max(0, range.lowerBound)
        let upper = min(channels[0].count, range.upperBound)
        guard upper - lower >= samples(5) else {
            return SegmentStats(seconds: Double(max(0, upper - lower)) / sampleRate, breathingDepth: 0, gsrArousal: 0, gsrRaw: 0, responsesPerMinute: 0)
        }
        let resp = Array(channels[Channel.resp.rawValue][lower..<upper])
        let pulse = Array(channels[Channel.pulse.rawValue][lower..<upper])
        let gsr = Array(channels[Channel.gsr.rawValue][lower..<upper])
        let seconds = Double(upper - lower) / sampleRate

        let intervals = cleanIntervals(beatTimes(pulse))
        let breaths = cycles(resp, breathSettings)
        let a = movingAverage(arousal(gsr, inverted: gsrInverted), window: samples(0.5))
        return SegmentStats(
            seconds: seconds,
            heartRate: intervals.count >= 3 ? 60 / mean(intervals) : nil,
            hrv: heartRateVariability(pulse),
            breathingRate: breaths.perMinute,
            breathingDepth: breaths.amplitude,
            gsrArousal: mean(a),
            gsrRaw: mean(gsr),
            responsesPerMinute: Double(skinResponses(a, threshold: responseThreshold).count) / (seconds / 60)
        )
    }

    /// The body's response to one event: 3 s before the marker against the 10 s after it.
    static func markerResponse(_ channels: [[Double]], at sample: Int, gsrInverted: Bool) -> MarkerResponse? {
        let before = samples(3)
        let after = samples(10)
        guard sample - before >= 0, sample + samples(4) <= channels[0].count else { return nil }
        let end = min(channels[0].count, sample + after)
        let gsr = Array(channels[Channel.gsr.rawValue][(sample - before)..<end])
        let a = movingAverage(arousal(gsr, inverted: gsrInverted), window: samples(0.5))
        let preLevel = mean(a[(before - samples(2))..<before])
        let post = Array(a[before...])
        let peak = post.indices.max { post[$0] < post[$1] } ?? 0

        let pulse = Array(channels[Channel.pulse.rawValue][(sample - before)..<end])
        let beats = cycles(pulse, pulseSettings).instantaneousRates(in: 40...180)
        let preRates = beats.filter { $0.index < before }.map(\.rate)
        let postRates = beats.filter { $0.index >= before }.map(\.rate)
        let preHR = preRates.isEmpty ? (postRates.first ?? 0) : mean(preRates)
        return MarkerResponse(
            gsrRise: post[peak] - preLevel,
            heartRateChange: (postRates.max() ?? preHR) - preHR,
            peakLatency: Double(peak) / sampleRate
        )
    }
}

// MARK: - Whole-recording analysis and interpretation

struct ExperimentAnalysis {
    var overall: SegmentStats
    var phases: [(phase: ExperimentPhase, stats: SegmentStats)]
    var markers: [(marker: ExperimentMarker, response: MarkerResponse?)]
    var interpretation: [String]
}

extension Signal {
    static func analyze(_ recording: ExperimentRecording) -> ExperimentAnalysis {
        let threshold = (recording.baseline ?? .defaults).gsrResponseThreshold
        let channels = recording.channels
        let overall = segmentStats(channels, range: 0..<recording.sampleCount, gsrInverted: recording.gsrInverted, responseThreshold: threshold)
        let phases = recording.phases.map { phase in
            (phase, segmentStats(channels, range: phase.start..<phase.end, gsrInverted: recording.gsrInverted, responseThreshold: threshold))
        }
        let markers = recording.markers.sorted { $0.sample < $1.sample }.map { marker in
            (marker, markerResponse(channels, at: marker.sample, gsrInverted: recording.gsrInverted))
        }
        let interpretation = interpret(recording: recording, overall: overall, phases: phases, markers: markers)
        return ExperimentAnalysis(overall: overall, phases: phases, markers: markers, interpretation: interpretation)
    }

    static func interpret(
        recording: ExperimentRecording,
        overall: SegmentStats,
        phases: [(phase: ExperimentPhase, stats: SegmentStats)],
        markers: [(marker: ExperimentMarker, response: MarkerResponse?)]
    ) -> [String] {
        var notes: [String] = []
        if overall.heartRate == nil {
            notes.append("No reliable heartbeat was found, so heart rate and HRV can't be interpreted. Check the pulse sensor's contact.")
        }

        // Compare each phase with the baseline: the first phase named "rest", else the first phase.
        let usable = phases.filter { $0.stats.seconds >= 20 }
        if let base = usable.first(where: { $0.phase.name.lowercased().contains("rest") }) ?? usable.first, usable.count >= 2 {
            for (phase, stats) in usable where phase.id != base.phase.id {
                notes.append(compare(phase.name, stats, with: base.phase.name, base.stats))
            }
        } else if phases.isEmpty {
            var line = "Whole recording: "
            var parts: [String] = []
            if let hr = overall.heartRate { parts.append("heart rate \(Int(hr.rounded())) bpm") }
            if let hrv = overall.hrv { parts.append("HRV \(Int(hrv.rmssd.rounded())) ms RMSSD") }
            if let br = overall.breathingRate { parts.append(String(format: "%.1f breaths/min", br)) }
            parts.append(String(format: "%.1f skin responses/min", overall.responsesPerMinute))
            line += parts.joined(separator: ", ") + ". Start phases (Rest, Task…) next time to compare conditions."
            notes.append(line)
        }

        // Exercise: heart-rate recovery over the first minute of rest afterwards.
        if let exercise = phases.firstIndex(where: { $0.phase.name.lowercased().contains("exercise") }),
           exercise + 1 < phases.count {
            let endOfExercise = phases[exercise].phase.end
            let recoveryStart = phases[exercise + 1].phase.start
            let peak = segmentStats(recording.channels, range: (endOfExercise - samples(10))..<endOfExercise, gsrInverted: recording.gsrInverted, responseThreshold: 3).heartRate
            let oneMinute = segmentStats(recording.channels, range: (recoveryStart + samples(55))..<(recoveryStart + samples(65)), gsrInverted: recording.gsrInverted, responseThreshold: 3).heartRate
            if let peak, let oneMinute {
                let drop = peak - oneMinute
                let rating = drop >= 25 ? "a strong recovery" : drop >= 12 ? "a normal recovery" : "a slow recovery (or the effort was light)"
                notes.append("Heart-rate recovery: \(Int(drop.rounded())) bpm drop in the first minute after exercise (\(Int(peak.rounded())) → \(Int(oneMinute.rounded())) bpm), \(rating). Above ~12 bpm is typical.")
            }
        }

        // Repeated markers: does the response shrink (habituation)?
        let responses = markers.compactMap { $0.response?.gsrRise }
        if responses.count >= 3 {
            let firstHalf = mean(responses.prefix(responses.count / 2))
            let secondHalf = mean(responses.suffix(responses.count - responses.count / 2))
            let trend = slope(responses) / sampleRate  // per marker
            if firstHalf > 0, secondHalf < firstHalf * 0.7 {
                notes.append("Habituation: skin responses to markers shrank from an average of \(Int(firstHalf.rounded())) in the first half to \(Int(secondHalf.rounded())) in the second (\(Int(((1 - secondHalf / firstHalf) * 100).rounded()))% smaller). The body stopped treating the event as new.")
            } else if trend > 0.5 {
                notes.append("Sensitization: skin responses to markers grew over the recording instead of shrinking.")
            } else {
                notes.append("Skin responses to the \(responses.count) markers stayed about the same size (no clear habituation).")
            }
        }

        notes.append("These are patterns in one recording, not diagnoses. Compare several recordings, ideally from several people, before drawing conclusions.")
        return notes
    }

    private static func compare(_ name: String, _ stats: SegmentStats, with baseName: String, _ base: SegmentStats) -> String {
        var parts: [String] = []
        var arousal = 0
        var calm = 0
        if let hr = stats.heartRate, let baseHR = base.heartRate {
            let change = hr - baseHR
            parts.append("heart rate \(AppModel.signed(change, unit: "bpm"))")
            if change / baseHR > 0.05 { arousal += 1 } else if change / baseHR < -0.05 { calm += 1 }
        }
        if let hrv = stats.hrv, let baseHRV = base.hrv, baseHRV.rmssd > 0 {
            let change = (hrv.rmssd - baseHRV.rmssd) / baseHRV.rmssd
            parts.append("HRV \(String(format: "%+d", Int((change * 100).rounded())))%")
            if change < -0.15 { arousal += 1 } else if change > 0.15 { calm += 1 }
        }
        if let br = stats.breathingRate, let baseBR = base.breathingRate {
            parts.append(String(format: "breathing %.0f vs %.0f/min", br, baseBR))
        }
        let responseChange = stats.responsesPerMinute - base.responsesPerMinute
        parts.append(String(format: "%.1f vs %.1f skin responses/min", stats.responsesPerMinute, base.responsesPerMinute))
        if responseChange >= 1 { arousal += 1 } else if responseChange <= -1 { calm += 1 }
        if stats.gsrArousal - base.gsrArousal > 5 { arousal += 1 }

        let reading: String
        if arousal >= 2 && arousal > calm {
            reading = "Together this points to heightened arousal (a stress or effort response from the sympathetic nervous system)."
        } else if calm >= 2 && calm > arousal {
            reading = "Together this points to a calmer state than \(baseName) (more parasympathetic, \"rest and digest\")."
        } else {
            reading = "No strong overall change from \(baseName)."
        }
        return "\(name) vs \(baseName): " + parts.joined(separator: ", ") + ". " + reading
    }
}
