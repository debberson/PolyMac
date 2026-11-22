import Foundation
import Testing
@testable import PolyMac

// MARK: - Sensors on/off

/// Synthetic signals with the breathing channel unplugged (a flat line), as when the band isn't set up.
private func noBreathingBand(seconds: Double) -> [[Double]] {
    var channels = synthetic(seconds: seconds, heartRate: 70, seed: 21)
    channels[Channel.resp.rawValue] = Array(repeating: 0, count: channels[0].count)
    return channels
}

@Test func stabilityIgnoresSensorsThatAreOff() {
    let channels = noBreathingBand(seconds: 30)
    let all = Signal.stability(Signal.liveStats(channels: channels, samplesPerSecond: 100, gsrInverted: true, responseThreshold: 3), baseline: nil)
    #expect(all.level == .unstable)  // the dead resp channel is flagged

    let sensors: Set<Channel> = [.pulse, .gsr]
    let stats = Signal.liveStats(channels: channels, samplesPerSecond: 100, gsrInverted: true, responseThreshold: 3, sensors: sensors)
    let report = Signal.stability(stats, baseline: nil, sensors: sensors)
    #expect(!report.checks.contains { $0.name == "Breathing" })
    #expect(report.checks.first { $0.name == "Sensors" }?.level == .stable)
    #expect(stats.breathingRate == nil && stats.heartRate != nil)
}

@Test func reactionWeightsRescaleToSensorsThatAreOn() {
    let all = Signal.reactionWeights(Channel.all)
    #expect(all.gsr == 0.5 && all.heart == 0.3 && all.breathing == 0.2)
    let noResp = Signal.reactionWeights([.gsr, .pulse])
    #expect(abs(noResp.gsr + noResp.heart - 1) < 1e-9 && noResp.breathing == 0)
    #expect(abs(noResp.gsr / noResp.heart - 0.5 / 0.3) < 1e-9)

    // With resp off, a dead breathing channel must not read as "breathing stopped" (full suppression).
    let channels = noBreathingBand(seconds: 20)
    let pre = channels.map { Array($0[0..<300]) }
    let post = channels.map { Array($0[300..<1200]) }
    let score = Signal.reaction(pre: pre, post: post, baseline: .defaults, gsrInverted: true, sensors: [.gsr, .pulse])
    #expect(score?.breathingComponent == 0 && score?.breathingSuppression == 0)
}

@Test func calibrationKeepsPreviousValuesForSensorsThatAreOff() {
    var previous = Baseline.defaults
    previous.breathingRate = 11.5
    previous.breathingAmplitude = 88
    let (baseline, quality) = Signal.calibrate(channels: noBreathingBand(seconds: 30), gsrInverted: true, sensors: [.pulse, .gsr], previous: previous)
    #expect(baseline.breathingRate == 11.5 && baseline.breathingAmplitude == 88)
    #expect(abs(baseline.heartRate - 70) < 3)
    #expect(baseline.gsrRaw != nil && baseline.hrvRmssd != nil)
    #expect(baseline.sensors == [.pulse, .gsr])
    #expect(quality.first { $0.channel == .resp }?.level == .off)
    #expect(quality.map(\.channel) == Channel.displayOrder)
}

@Test func featuresFromSensorsThatAreOffAreNeutral() throws {
    let channels = noBreathingBand(seconds: 20)
    let pre = channels.map { Array($0[0..<300]) }
    let post = channels.map { Array($0[300..<1200]) }
    let f = try #require(Signal.features(
        pre: pre, post: post, baseline: .defaults, gsrInverted: true, kind: .relevant,
        answerLatency: 1, stableAtAsk: true, sensors: [.gsr, .pulse]
    ))
    #expect(f["resp_amp_ratio"] == 1 && f["resp_rate_delta"] == 0)
}

@Test func experimentAnalysisLeavesOutSensorsThatWereOff() {
    let rest = noBreathingBand(seconds: 60)
    let task = synthetic(seconds: 60, heartRate: 86, reactionAt: 10, seed: 22)
    var channels = (0..<3).map { rest[$0] + task[$0] }
    channels[Channel.resp.rawValue] = Array(repeating: 0, count: channels[0].count)
    let recording = ExperimentRecording(
        title: "No band", templateID: "mental-arithmetic", subjectID: UUID(), subjectName: "T", startedAt: .now,
        source: "simulator", gsrInverted: true, baseline: nil, channels: channels, markers: [],
        phases: [ExperimentPhase(name: "Rest", start: 0, end: 6000), ExperimentPhase(name: "Task", start: 6000, end: 12000)],
        sensors: [.pulse, .gsr]
    )
    let analysis = Signal.analyze(recording)
    #expect(analysis.phases.allSatisfy { $0.stats.breathingRate == nil && $0.stats.heartRate != nil })
    let comparison = analysis.interpretation.first { $0.hasPrefix("Task vs Rest") } ?? ""
    #expect(!comparison.contains("breathing") && comparison.contains("heart rate"), "\(comparison)")
}

@Test func experimentSensorsSurviveSaveAndReload() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "polymac-sensors-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = ExperimentRecording(
        title: "Two sensors", templateID: "free", subjectID: UUID(), subjectName: "T", startedAt: .now,
        source: "simulator", gsrInverted: true, baseline: nil, channels: noBreathingBand(seconds: 20), markers: [], phases: [],
        sensors: [.pulse, .gsr]
    )
    let folder = try ExperimentFiles.write(recording, analysis: Signal.analyze(recording), includeSignals: true, to: directory)
    let loaded = try ExperimentFiles.load(folder, subjectNames: [:])
    #expect(loaded.sensors == [.pulse, .gsr])
}

// MARK: - Subject database

@Test func profilesSavedBeforeNewFieldsStillLoad() throws {
    let old = #"{"id":"5A3C9F4E-1111-4222-8333-944455556666","name":"Alex","gsrInverted":true,"sensitivity":0.7,"responseSeconds":8}"#
    let profile = try JSONDecoder().decode(SubjectProfile.self, from: Data(old.utf8))
    #expect(profile.name == "Alex" && profile.sensitivity == 0.7 && profile.notes.isEmpty && profile.baseline == nil)
}

@Test func subjectDatabaseRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "polymac-subjects-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    // JSON stores dates to the second, so use whole-second dates for exact comparisons.
    let when = Date(timeIntervalSince1970: 1_800_000_000)
    var alex = SubjectProfile(name: "Alex")
    alex.createdAt = when
    alex.notes = "Drinks coffee before sessions"
    var baseline = Baseline.defaults
    baseline.heartRate = 64
    baseline.gsrRaw = 420
    baseline.hrvRmssd = 48
    baseline.sensors = [.pulse, .gsr]
    baseline.recordedAt = when
    alex.baseline = baseline
    try SubjectStore.save(alex, in: directory)
    try SubjectStore.save(SubjectProfile(name: "Sam"), in: directory)

    let loaded = SubjectStore.loadProfiles(in: directory)
    #expect(loaded.map(\.name).sorted() == ["Alex", "Sam"])
    #expect(loaded.first { $0.name == "Alex" } == alex)

    let exam = ExamEntry(
        id: UUID(), startedAt: when, endedAt: when.addingTimeInterval(600), source: "serial", sensors: [.pulse, .gsr], trainingProtocol: nil,
        verdict: .deceptive, verdictGauge: 0.8, verdictSource: "rules",
        questions: [ExamQuestionEntry(number: 1, text: "Did you take it?", kind: .relevant, answer: .no, reactionIndex: 72,
                                      gsrDelta: 40, heartRateDelta: 9, breathingSuppression: nil, verdict: .deceptive,
                                      mlProbability: nil, label: nil, stableAtAsk: true)],
        savedSession: nil
    )
    let calibration = CalibrationEntry(baseline: baseline, method: .recorded, source: "serial", quality: ["Cardio": "good: 64 bpm"])
    try SubjectStore.save(SubjectHistory(calibrations: [calibration], exams: [exam]), for: alex.id, in: directory)
    let history = SubjectStore.loadHistory(for: alex.id, in: directory)
    #expect(history.exams == [exam] && history.calibrations == [calibration])

    // The training pipeline's subject index stays in sync.
    let index = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appending(path: "subjects.json")))
    #expect(index[alex.id.uuidString] == "Alex")
}

private func calibration(hr: Double, gsr: Double, spread: Double = 3, noise: Double = 1, sensors: Set<Channel> = [.pulse, .gsr]) -> CalibrationEntry {
    var b = Baseline.defaults
    b.heartRate = hr
    b.heartRateSpread = spread
    b.gsrRaw = gsr
    b.gsrNoise = noise
    b.seconds = 30
    b.sensors = sensors
    return CalibrationEntry(baseline: b, method: .recorded, source: "serial")
}

@Test func usualValuesComeFromRecentCalibrations() throws {
    let history = SubjectHistory(calibrations: [
        calibration(hr: 62, gsr: 400), calibration(hr: 66, gsr: 430), calibration(hr: 90, gsr: 410),
        calibration(hr: 64, gsr: 700, sensors: [.pulse]),  // GSR was off: its level must not count
    ])
    let usual = try #require(history.usual)
    #expect(usual.calibrations == 4)
    #expect(usual.heartRate == 65)  // median of 62, 64, 66, 90
    #expect(usual.gsrRaw == 410)
    #expect(usual.breathingRate == nil)  // never measured

    var today = Baseline.defaults
    today.heartRate = 84
    today.gsrRaw = 415
    today.sensors = [.pulse, .gsr]
    let notes = usual.comparison(with: today)
    #expect(notes.first?.contains("usually 65") == true && notes.first?.contains("Higher than normal") == true)

    // A quick calibration keeps today's level but steadies the noisy variability estimate.
    today.heartRateSpread = 10
    let steadied = usual.steady(today)
    #expect(steadied.heartRate == 84)
    #expect(steadied.heartRateSpread < 6)
}
