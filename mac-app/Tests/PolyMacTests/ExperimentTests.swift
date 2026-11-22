import Foundation
import Testing
@testable import PolyMac

/// A pulse wave whose systolic peaks sit exactly at `beats` (seconds), so HRV has a known answer.
private func pulseWave(beats: [Double], seconds: Double, seed: UInt64 = 3) -> [Double] {
    var rng = SeededGenerator(seed: seed)
    let n = Int(seconds * 100)
    var wave = (0..<n).map { _ in 500 + rng.noise(3) }
    for beat in beats {
        let first = max(0, Int((beat - 0.2) * 100))
        let last = min(n - 1, Int((beat + 0.6) * 100))
        guard first <= last else { continue }
        for i in first...last {
            let t = Double(i) / 100 - beat
            wave[i] += 220 * exp(-pow(t / 0.05, 2)) + 70 * exp(-pow((t - 0.27) / 0.08, 2))
        }
    }
    return wave
}

private func beatSchedule(seconds: Double, intervals: (Int) -> Double) -> [Double] {
    var beats: [Double] = []
    var t = 0.5
    var i = 0
    while t < seconds - 0.5 {
        beats.append(t)
        t += intervals(i)
        i += 1
    }
    return beats
}

@Test func hrvMatchesKnownBeatIntervals() throws {
    // Alternating 800/900 ms beats: successive differences are all 100 ms, SD is 50 ms.
    let beats = beatSchedule(seconds: 60) { $0 % 2 == 0 ? 0.8 : 0.9 }
    let hrv = try #require(Signal.heartRateVariability(pulseWave(beats: beats, seconds: 60)))
    #expect(abs(hrv.rmssd - 100) < 8, "\(hrv)")
    #expect(abs(hrv.sdnn - 50) < 5, "\(hrv)")
    #expect(abs(hrv.meanHeartRate - 60 / 0.85) < 1.5)
}

@Test func hrvOfSteadyBeatsIsNearZero() throws {
    // Sub-sample peak timing keeps the noise floor well under typical resting RMSSD (20–80 ms).
    let beats = beatSchedule(seconds: 60) { _ in 0.857 }
    let hrv = try #require(Signal.heartRateVariability(pulseWave(beats: beats, seconds: 60)))
    #expect(hrv.rmssd < 10, "\(hrv)")
}

@Test func hrvIgnoresAMissedBeat() throws {
    var beats = beatSchedule(seconds: 60) { $0 % 2 == 0 ? 0.8 : 0.9 }
    beats.remove(at: 30)  // a dropped beat creates one ~1.7 s interval that must be rejected
    let hrv = try #require(Signal.heartRateVariability(pulseWave(beats: beats, seconds: 60)))
    #expect(abs(hrv.rmssd - 100) < 12, "\(hrv)")
}

private func stressRecording() -> ExperimentRecording {
    let rest = synthetic(seconds: 60, heartRate: 65, seed: 11)
    let task = synthetic(seconds: 60, heartRate: 84, breathingRate: 19, reactionAt: 10, seed: 12)
    let channels = (0..<3).map { rest[$0] + task[$0] }
    return ExperimentRecording(
        title: "Arithmetic, trial 1", templateID: "mental-arithmetic", subjectID: UUID(), subjectName: "Tester",
        startedAt: Date(timeIntervalSince1970: 1_800_000_000), source: "simulator", gsrInverted: true,
        baseline: nil, channels: channels,
        markers: [ExperimentMarker(sample: 7000, label: "Started counting", addedLive: true)],
        phases: [ExperimentPhase(name: "Rest", start: 0, end: 6000), ExperimentPhase(name: "Task", start: 6000, end: 12000)]
    )
}

@Test func analysisDescribesStressAgainstRest() throws {
    let analysis = Signal.analyze(stressRecording())
    #expect(analysis.phases.count == 2)
    let rest = try #require(analysis.phases[0].stats.heartRate)
    let task = try #require(analysis.phases[1].stats.heartRate)
    #expect(abs(rest - 65) < 3 && abs(task - 84) < 3)
    #expect((analysis.phases[1].stats.responsesPerMinute ?? 0) >= 1)
    let comparison = try #require(analysis.interpretation.first { $0.hasPrefix("Task vs Rest") })
    #expect(comparison.contains("heightened arousal"), "\(comparison)")
    let response = try #require(analysis.markers.first?.response)
    #expect((response.gsrRise ?? 0) > 30, "\(response)")
}

@Test func experimentSavesAndReopens() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "polymac-exp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var recording = stressRecording()
    recording.notes = "Subject laughed at 1:30"

    let folder = try ExperimentFiles.write(recording, analysis: Signal.analyze(recording), includeSignals: true, to: directory)
    #expect(folder.lastPathComponent.hasSuffix("_arithmetic-trial-1"))
    for file in ["experiment.json", "signals.csv", "phases.csv", "markers.csv", "beats.csv", "summary.txt"] {
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: file).path), "\(file)")
    }

    let listed = ExperimentFiles.list(in: directory)
    #expect(listed.count == 1 && listed[0].title == "Arithmetic, trial 1" && abs(listed[0].duration - 120) < 0.01)

    let loaded = try ExperimentFiles.load(folder, subjectNames: ExperimentFiles.subjectNames(in: directory))
    #expect(loaded.sampleCount == recording.sampleCount)
    #expect(loaded.channels[1][1234] == recording.channels[1][1234].rounded(.towardZero))
    #expect(loaded.markers == recording.markers && loaded.phases == recording.phases)
    #expect(loaded.notes == recording.notes && loaded.subjectName == "Tester")

    let phases = try String(contentsOf: folder.appending(path: "phases.csv"), encoding: .utf8).split(separator: "\n")
    #expect(phases.count == 3 && phases[2].hasPrefix("Task,"))
    let summary = try String(contentsOf: folder.appending(path: "summary.txt"), encoding: .utf8)
    #expect(summary.contains("Task vs Rest") && summary.contains("Started counting"))
}
