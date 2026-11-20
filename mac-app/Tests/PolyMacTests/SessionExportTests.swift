import Foundation
import Testing
@testable import PolyMac

/// Builds one card-test session from synthetic signals, using the app's real feature, scoring
/// and labeling code. The subject's picked number gets a strong reaction; the rest weak ones.
private func syntheticCardSession(subject: SubjectProfile, chosen: Int, numbers: Int, seed: UInt64, reactivity: Double) -> SessionExport {
    var rng = SeededGenerator(seed: seed)
    var records: [QuestionRecord] = []
    var number = 0
    for round in 0..<2 {
        for card in (1...numbers).shuffled() {
            number += 1
            let lie = card == chosen
            let strength = reactivity * (lie ? 0.65 + 0.35 * abs(rng.noise(1)) : 0.35 * abs(rng.noise(1)))
            let latency = (lie ? 1.6 : 1.1) + abs(rng.noise(0.6))
            let window = 8.0
            let data = synthetic(seconds: 5 + latency + window + 1, reactionAt: 5, reactionStrength: strength, seed: seed &+ UInt64(number * 31 + round))
            let postEnd = Int((5 + latency + window) * 100)
            let pre = data.map { Array($0[0..<500]) }
            let post = data.map { Array($0[500..<postEnd]) }
            let ask = number * 3000
            var record = QuestionRecord(
                number: number,
                question: Question(text: "Is your number \(card)?", kind: .relevant, cardNumber: card),
                askSample: ask,
                stabilityAtAsk: .stable
            )
            record.answer = .no
            record.answerSample = ask + Int(latency * 100)
            record.responseEndSample = ask + postEnd - 500
            let baseline = subject.baseline ?? .defaults
            record.score = Signal.reaction(pre: pre, post: post, baseline: baseline, gsrInverted: true)
            if let base = Signal.features(pre: pre, post: post, baseline: baseline, gsrInverted: true, kind: .relevant, answerLatency: record.latency, stableAtAsk: true) {
                record.features = Signal.addingSessionRelative(base, prior: records.compactMap(\.features))
            }
            record.label = (record.answer == .yes) == lie ? .truth : .lie
            records.append(record)
        }
    }
    return SessionExport(
        sessionID: UUID(), startedAt: .now, endedAt: .now, profile: subject,
        trainingProtocol: .cardTest, cardNumbers: numbers, chosenCard: chosen,
        source: "simulator", simulatedSubject: nil, records: records,
        signalIndices: [0, 1], signals: [[512, 513], [500, 501], [380, 381]], modelSummary: nil
    )
}

@Test func exportWritesReadableSessionFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "polymac-export-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var subject = SubjectProfile(name: "Test, \"Subject\"")
    subject.baseline = Signal.calibrate(channels: synthetic(seconds: 30), gsrInverted: true).0

    let folder = try SessionExporter.write(syntheticCardSession(subject: subject, chosen: 3, numbers: 4, seed: 1, reactivity: 1), to: directory)

    let csv = try String(contentsOf: folder.appending(path: "questions.csv"), encoding: .utf8)
    let lines = csv.split(separator: "\n")
    #expect(lines.count == 9)  // header + 4 numbers × 2 rounds
    let header = lines[0].split(separator: ",").map(String.init)
    #expect(header.contains("label") && header.contains("rule_index"))
    #expect(header.contains("f_gsr_rise_norm") && header.contains("f_rel_hr_peak_delta"))
    #expect(lines.dropFirst().filter { $0.contains(",lie,") }.count == 2)
    #expect(lines.dropFirst().allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == header.count })

    let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "session.json"))) as? [String: Any]
    #expect(meta?["chosen_card"] as? Int == 3)
    #expect(meta?["simulated"] as? Bool == true)
    #expect(meta?["labeled_questions"] as? Int == 8)

    let signals = try String(contentsOf: folder.appending(path: "signals.csv"), encoding: .utf8)
    #expect(signals.hasPrefix("sample,resp,pulse,gsr\n0,512,500,380\n"))
    let subjects = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appending(path: "subjects.json")))
    #expect(subjects[subject.id.uuidString] == subject.name)
}

/// Writes a batch of synthetic labeled sessions for exercising ml/train.py:
///   POLYMAC_DEMO_DATA=/tmp/demo swift test --filter writeDemoTrainingData
@Test(.enabled(if: ProcessInfo.processInfo.environment["POLYMAC_DEMO_DATA"] != nil))
func writeDemoTrainingData() throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["POLYMAC_DEMO_DATA"]))
    for s in 0..<16 {
        var subject = SubjectProfile(name: "Demo \(s + 1)")
        let heartRate = 60 + Double(s % 5) * 5
        subject.baseline = Signal.calibrate(channels: synthetic(seconds: 30, heartRate: heartRate, seed: UInt64(s)), gsrInverted: true).0
        for session in 0..<2 {
            let export = syntheticCardSession(
                subject: subject, chosen: (s + session) % 6 + 1, numbers: 6,
                seed: UInt64(1000 * s + session), reactivity: 0.5 + Double(s % 4) * 0.2
            )
            try SessionExporter.write(export, to: directory)
        }
    }
}

/// Loads a model produced by ml/train.py and checks the app reads sensible probabilities from it:
///   POLYMAC_MODEL=/path/to/PolyMacModel.mlmodel swift test --filter trainedModelLoads
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["POLYMAC_MODEL"] != nil))
func trainedModelLoadsInApp() throws {
    let model = try DeceptionModel(url: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["POLYMAC_MODEL"])))
    var subject = SubjectProfile(name: "Check")
    subject.baseline = Signal.calibrate(channels: synthetic(seconds: 30, seed: 7), gsrInverted: true).0
    let session = syntheticCardSession(subject: subject, chosen: 2, numbers: 6, seed: 99, reactivity: 1)
    let lies = session.records.filter { $0.label == .lie }.compactMap { $0.features.flatMap(model.probability) }
    let truths = session.records.filter { $0.label == .truth }.compactMap { $0.features.flatMap(model.probability) }
    #expect(lies.count == 2 && truths.count == 10, "model inputs: \(model.featureNames)")
    #expect(Signal.mean(lies) > 0.5 && Signal.mean(truths) < 0.5, "lies \(lies) truths \(truths)")
    #expect(!model.summary.isEmpty)
    print("MODEL", model.summary, "lies", lies.map { Int($0 * 100) }, "truths", truths.map { Int($0 * 100) })
}
