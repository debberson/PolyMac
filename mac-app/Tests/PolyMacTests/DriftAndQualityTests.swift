import Foundation
import Testing
@testable import PolyMac

/// Adds a steady drift to the Grove GSR reading, in raw units per minute (negative = the reading
/// falls, i.e. sweat building up under the electrodes).
private func withDrift(_ channels: [[Double]], perMinute: Double) -> [[Double]] {
    var c = channels
    c[Channel.gsr.rawValue] = c[Channel.gsr.rawValue].enumerated().map { $1 + perMinute / 6000 * Double($0) }
    return c
}

private func score(_ channels: [[Double]]) -> ReactionScore? {
    let pre = channels.map { Array($0[0..<500]) }
    let post = channels.map { Array($0[500..<1500]) }
    return Signal.reaction(pre: pre, post: post, baseline: .defaults, gsrInverted: true)
}

@Test func steadySkinDriftIsNotScoredAsAReaction() throws {
    let calm = synthetic(seconds: 15, seed: 51)
    let still = try #require(score(calm))
    let drifting = try #require(score(withDrift(calm, perMinute: -30)))  // the drift seen in real sessions
    // Without correction, 30/min over the ~11 s from reference to the end adds about 5 units.
    #expect(abs(drifting.gsrDelta - still.gsrDelta) < 1.5, "drift added \(drifting.gsrDelta - still.gsrDelta)")
    #expect(try #require(drifting.evidence).gsrDriftRemoved > 2)
}

@Test func reactionOnTopOfDriftKeepsItsSize() throws {
    let reacting = synthetic(seconds: 15, reactionAt: 5, seed: 52)
    let flat = try #require(score(reacting))
    let drifting = try #require(score(withDrift(reacting, perMinute: -30)))
    #expect(flat.gsrDelta > 10)
    #expect(abs(drifting.gsrDelta - flat.gsrDelta) < 2, "flat \(flat.gsrDelta), drifting \(drifting.gsrDelta)")
    // The bracket on the chart still equals the scored change.
    let e = try #require(drifting.evidence)
    #expect(abs((e.gsrReferenceRaw - e.gsrPeakRaw) - drifting.gsrDelta) < 1e-6)
    #expect(e.gsrReferenceStartRaw > e.gsrReferenceRaw)  // the reference line follows the falling reading
}

@Test func driftAwayFromArousalIsNotAddedBack() throws {
    // A reading rising (an earlier response fading) mustn't inflate the next score.
    let calm = synthetic(seconds: 15, seed: 53)
    let still = try #require(score(calm))
    let recovering = try #require(score(withDrift(calm, perMinute: 40)))
    #expect(recovering.gsrDelta <= still.gsrDelta + 0.5)
    #expect(try #require(recovering.evidence).gsrDriftRemoved == 0)
}

@Test func fastChangesBeforeTheQuestionAreCappedNotTreatedAsDrift() {
    // A response already rising before the question (far faster than drift) is capped, so most of
    // the reaction after the question still counts.
    let rising = (0..<500).map { Double($0) * 0.2 }  // 20 units/s
    #expect(Signal.gsrDrift(rising, baseline: .defaults) == Signal.maxGSRDrift(.defaults))
    #expect(Signal.gsrDrift(Array(rising.prefix(200)), baseline: .defaults) == 0)  // under 3 s: no estimate
}

// MARK: - Calibration warnings

@Test func calibrationWarnsWhenSkinReadingIsNearTheSensorsLimit() throws {
    var channels = synthetic(seconds: 30, seed: 54)
    channels[Channel.gsr.rawValue] = channels[Channel.gsr.rawValue].map { max(0, 14 + ($0 - Signal.mean(channels[Channel.gsr.rawValue])) * 0.1) }
    let (_, quality) = Signal.calibrate(channels: channels, gsrInverted: true)
    let gsr = try #require(quality.first { $0.channel == .gsr })
    #expect(gsr.level == .weak && gsr.detail.contains("bottom of the sensor's range"), "\(gsr.detail)")

    // The same low reading isn't a problem for a sensor that reads higher with more sweat.
    #expect(Signal.gsrRangeWarning(channels[Channel.gsr.rawValue], inverted: false) == nil)
}

@Test func calibrationWarnsWhileElectrodesAreStillSettling() throws {
    let settling = withDrift(synthetic(seconds: 30, seed: 55), perMinute: -40)  // first minutes after strapping on
    let (_, quality) = Signal.calibrate(channels: settling, gsrInverted: true)
    let gsr = try #require(quality.first { $0.channel == .gsr })
    #expect(gsr.level == .weak && gsr.detail.contains("still drifting"), "\(gsr.detail)")

    let longSession = withDrift(synthetic(seconds: 30, seed: 55), perMinute: -15)  // slow build-up later on
    #expect(Signal.calibrate(channels: longSession, gsrInverted: true).1.first { $0.channel == .gsr }?.level == .good)
}

// MARK: - Mains hum on the charts

@Test func humFilterRemovesMainsHumButKeepsTheSignal() {
    let n = 2000
    let slow = (0..<n).map { 300 + 20 * sin(2 * .pi * 0.2 * Double($0) / 100) }  // a skin response-sized wave
    for mains in [60.0, 50.0] {
        let hum = (0..<n).map { 6 * cos(2 * .pi * mains * Double($0) / 100 + 0.3) }
        let filtered = Signal.humFiltered(zip(slow, hum).map(+))
        // Compare after the filter's ~3 sample delay, away from the start.
        let error = (100..<n).map { abs(filtered[$0] - slow[$0 - 3]) }.max() ?? 0
        #expect(error < 0.6, "\(Int(mains)) Hz hum left \(error)")
    }
}
