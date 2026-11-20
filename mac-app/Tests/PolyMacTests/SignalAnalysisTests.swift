import Foundation
import Testing
@testable import PolyMac

/// Synthetic three-channel recording. `reactionAt` (seconds) injects a stress response like the simulator's.
private func synthetic(
    seconds: Double,
    heartRate: Double = 72,
    breathingRate: Double = 15,
    reactionAt: Double? = nil,
    reactionStrength: Double = 1
) -> [[Double]] {
    let n = Int(seconds * 100)
    var resp: [Double] = []
    var pulse: [Double] = []
    var gsr: [Double] = []
    var pulsePhase = 0.0
    var breathPhase = 0.0
    var rng = SeededGenerator(seed: 42)
    for i in 0..<n {
        let t = Double(i) / 100
        var hr = heartRate
        var depth = 1.0
        var sweat = 0.0
        if let r = reactionAt, t > r + 1.5 {
            let dt = t - r - 1.5
            hr += 15 * reactionStrength * exp(-dt / 4)
            depth -= 0.7 * reactionStrength * exp(-dt / 5)
            sweat = 80 * reactionStrength * (1 - exp(-dt / 0.8)) * exp(-dt / 6)
        }
        pulsePhase += hr / 60 / 100
        breathPhase += breathingRate / 60 / 100
        let phase = pulsePhase.truncatingRemainder(dividingBy: 1)
        pulse.append(500 + 220 * exp(-pow((phase - 0.15) / 0.05, 2)) + 70 * exp(-pow((phase - 0.42) / 0.08, 2)) + rng.noise(4))
        resp.append(512 + depth * 140 * sin(2 * .pi * breathPhase) + rng.noise(3))
        gsr.append(380 - sweat + rng.noise(1))
    }
    return [resp, pulse, gsr]
}

private struct SeededGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func noise(_ amplitude: Double) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (Double(state >> 11) / Double(1 << 53) * 2 - 1) * amplitude
    }
}

@Test func detectsHeartAndBreathingRate() {
    let data = synthetic(seconds: 30, heartRate: 72, breathingRate: 15)
    let stats = Signal.liveStats(channels: data, samplesPerSecond: 100, gsrInverted: true, responseThreshold: 4)
    #expect(abs((stats.heartRate ?? 0) - 72) < 3)
    #expect(abs((stats.breathingRate ?? 0) - 15) < 1.5)
    #expect(stats.railed.isEmpty && stats.flat.isEmpty)
    #expect(stats.recentResponses == 0)
}

@Test func restingSubjectIsStable() {
    let data = synthetic(seconds: 30)
    let stats = Signal.liveStats(channels: data, samplesPerSecond: 100, gsrInverted: true, responseThreshold: 4)
    let report = Signal.stability(stats, baseline: nil)
    #expect(report.level == .stable, "\(report.checks.filter { $0.level != .stable })")
}

@Test func flatChannelIsUnstable() {
    var data = synthetic(seconds: 30)
    data[Channel.pulse.rawValue] = Array(repeating: 512, count: data[0].count)
    let stats = Signal.liveStats(channels: data, samplesPerSecond: 100, gsrInverted: true, responseThreshold: 4)
    #expect(Signal.stability(stats, baseline: nil).level == .unstable)
}

@Test func calibrationRecoversBaseline() {
    let (baseline, quality) = Signal.calibrate(channels: synthetic(seconds: 30, heartRate: 66, breathingRate: 12), gsrInverted: true)
    #expect(abs(baseline.heartRate - 66) < 3)
    #expect(abs(baseline.breathingRate - 12) < 1.5)
    #expect(quality.allSatisfy { $0.level == .good }, "\(quality)")
}

@Test func strongReactionScoresHigherThanCalm() throws {
    let (baseline, _) = Signal.calibrate(channels: synthetic(seconds: 30), gsrInverted: true)
    func score(strength: Double) throws -> ReactionScore {
        let data = synthetic(seconds: 20, reactionAt: 5, reactionStrength: strength)
        let pre = data.map { Array($0[0..<500]) }
        let post = data.map { Array($0[500..<1500]) }
        return try #require(Signal.reaction(pre: pre, post: post, baseline: baseline, gsrInverted: true))
    }
    let calm = try score(strength: 0)
    let strong = try score(strength: 1)
    #expect(calm.index < 20, "\(calm)")
    #expect(strong.index > 60, "\(strong)")
    #expect(strong.gsrDelta > 40)
    #expect(strong.heartRateDelta > 6)
}

@Test func verdictComparesAgainstControls() {
    #expect(Signal.verdict(index: 80, controlMean: 40, sensitivity: 0.5).verdict == .deceptive)
    #expect(Signal.verdict(index: 15, controlMean: 40, sensitivity: 0.5).verdict == .truthful)
    #expect(Signal.verdict(index: 42, controlMean: 40, sensitivity: 0.5).verdict == .inconclusive)
    #expect(Signal.verdict(index: 90, controlMean: nil, sensitivity: 0.5).verdict == .deceptive)
    #expect(Signal.verdict(index: 5, controlMean: nil, sensitivity: 0.5).verdict == .truthful)
    let gauge = Signal.verdict(index: 100, controlMean: 0, sensitivity: 0.5).gauge
    #expect(gauge == 1)
}

@Test func bufferRangesUseAbsoluteIndices() {
    let buffer = SampleBuffer(capacity: 5)
    for i in 0..<8 {
        buffer.append(Reading(deviceMillis: nil, resp: Double(i), pulse: 0, gsr: 0))
    }
    #expect(buffer.samples(from: 4, to: 7)[Channel.resp.rawValue] == [4, 5, 6])
    #expect(buffer.samples(from: 0, to: 4)[Channel.resp.rawValue] == [3])  // 0–2 already overwritten
    buffer.reset()
    #expect(buffer.totalCount == 8)
    #expect(buffer.samples(from: 0, to: 8)[Channel.resp.rawValue].isEmpty)
    buffer.append(Reading(deviceMillis: nil, resp: 99, pulse: 0, gsr: 0))
    #expect(buffer.samples(from: 8, to: 9)[Channel.resp.rawValue] == [99])
}
