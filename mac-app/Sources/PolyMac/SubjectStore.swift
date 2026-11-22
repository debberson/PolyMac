import Foundation

// The subject database: one folder per person in `<data>/subjects/<id>/`:
//   profile.json       name, notes, settings and current baseline
//   calibrations.json  every saved calibration (resting heart rate, GSR level, HRV, …)
//   exams.json         every finished exam: each question, answer, reaction and verdict
// Plain JSON, so it can be read from Python next to the training sessions.

/// One saved calibration.
struct CalibrationEntry: Codable, Identifiable, Equatable {
    enum Method: String, Codable {
        /// A normal resting recording.
        case recorded
        /// A short recording whose variability estimates were steadied with this subject's history.
        case quick
        /// No recording: the subject's usual values from earlier calibrations.
        case usual
    }

    var id = UUID()
    var baseline: Baseline
    var method: Method
    var source: String
    /// Channel title → "good: 68 bpm, clean beats".
    var quality: [String: String] = [:]
    var date: Date { baseline.recordedAt }
}

/// One question from a finished exam.
struct ExamQuestionEntry: Codable, Equatable, Identifiable {
    var number: Int
    var text: String
    var kind: QuestionKind
    var answer: Answer?
    var reactionIndex: Double?
    var gsrDelta: Double?
    var heartRateDelta: Double?
    var breathingSuppression: Double?
    var verdict: Verdict?
    var mlProbability: Double?
    var label: GroundTruth?
    var stableAtAsk: Bool
    var id: Int { number }
}

/// One finished exam session.
struct ExamEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var source: String
    var sensors: Set<Channel>
    var trainingProtocol: TrainingProtocol?
    var verdict: Verdict?
    /// 0 = fully truthful side of the gauge, 1 = fully deceptive.
    var verdictGauge: Double?
    /// "rules" or "model".
    var verdictSource: String
    var questions: [ExamQuestionEntry]
    /// Folder name under `<data>/sessions/` when the session was also saved as training data.
    var savedSession: String?

    var relevantCount: Int { questions.filter { $0.kind == .relevant }.count }
}

struct SubjectHistory: Equatable {
    var calibrations: [CalibrationEntry] = []
    var exams: [ExamEntry] = []

    /// This person's typical resting values: the median over their recent calibrations, per sensor,
    /// counting only calibrations where that sensor was on.
    var usual: UsualValues? {
        let recent = calibrations.filter { $0.method != .usual && $0.baseline.seconds > 0 }.suffix(8)
        guard !recent.isEmpty else { return nil }
        func values(_ channel: Channel, _ key: (Baseline) -> Double?) -> [Double] {
            recent.filter { ($0.baseline.sensors ?? Channel.all).contains(channel) && $0.quality[channel.title]?.hasPrefix("good") != false }
                .compactMap { key($0.baseline) }
        }
        let hr = values(.pulse) { $0.heartRate }
        let gsr = values(.gsr) { $0.gsrRaw }
        return UsualValues(
            calibrations: recent.count,
            heartRate: Signal.median(hr),
            heartRateSpread: Signal.median(values(.pulse) { $0.heartRateSpread }),
            hrv: Signal.median(values(.pulse) { $0.hrvRmssd }),
            breathingRate: Signal.median(values(.resp) { $0.breathingRate }),
            breathingAmplitude: Signal.median(values(.resp) { $0.breathingAmplitude }),
            gsrRaw: Signal.median(gsr),
            gsrArousal: Signal.median(values(.gsr) { $0.gsrArousal }),
            gsrNoise: Signal.median(values(.gsr) { $0.gsrNoise }),
            heartRateSamples: hr.count,
            gsrSamples: gsr.count
        )
    }
}

struct UsualValues: Equatable {
    var calibrations: Int
    var heartRate: Double?
    var heartRateSpread: Double?
    var hrv: Double?
    var breathingRate: Double?
    var breathingAmplitude: Double?
    var gsrRaw: Double?
    var gsrArousal: Double?
    var gsrNoise: Double?
    var heartRateSamples: Int
    var gsrSamples: Int

    /// A baseline built only from history, for starting without a recording.
    func baseline(sensors: Set<Channel>) -> Baseline {
        var b = Baseline.defaults
        b.heartRate = heartRate ?? b.heartRate
        b.heartRateSpread = heartRateSpread ?? b.heartRateSpread
        b.breathingRate = breathingRate ?? b.breathingRate
        b.breathingAmplitude = breathingAmplitude ?? b.breathingAmplitude
        b.gsrArousal = gsrArousal ?? b.gsrArousal
        b.gsrNoise = gsrNoise ?? b.gsrNoise
        b.gsrRaw = gsrRaw
        b.hrvRmssd = hrv
        b.sensors = sensors
        b.seconds = 0
        b.recordedAt = .now
        return b
    }

    /// Steadies a short recording: today's levels (heart rate, GSR level) are kept, while the
    /// variability measures, which a short recording estimates poorly, lean on this person's history.
    func steady(_ fresh: Baseline) -> Baseline {
        var b = fresh
        func blend(_ new: Double, _ usual: Double?) -> Double { usual.map { 0.35 * new + 0.65 * $0 } ?? new }
        let sensors = fresh.sensors ?? Channel.all
        if sensors.contains(.pulse) { b.heartRateSpread = blend(fresh.heartRateSpread, heartRateSpread) }
        if sensors.contains(.gsr) { b.gsrNoise = blend(fresh.gsrNoise, gsrNoise) }
        if sensors.contains(.resp) { b.breathingAmplitude = blend(fresh.breathingAmplitude, breathingAmplitude) }
        return b
    }

    /// How today's calibration compares with this person's usual, worth knowing before an exam.
    func comparison(with fresh: Baseline) -> [String] {
        var notes: [String] = []
        let sensors = fresh.sensors ?? Channel.all
        if sensors.contains(.pulse), let usual = heartRate, heartRateSamples >= 1 {
            let change = fresh.heartRate - usual
            let base = "Heart rate \(Int(fresh.heartRate.rounded())) bpm, usually \(Int(usual.rounded()))"
            if change > 10 {
                notes.append(base + ". Higher than normal: they may be nervous, tired or just had caffeine. Give them a few minutes.")
            } else if change < -10 {
                notes.append(base + ". Lower than normal.")
            } else {
                notes.append(base + ". Normal for them.")
            }
        }
        if sensors.contains(.gsr), let usual = gsrRaw, let now = fresh.gsrRaw, gsrSamples >= 1 {
            let change = now - usual
            notes.append("GSR level \(Int(now.rounded())), usually \(Int(usual.rounded()))"
                + (abs(change) > 60 ? ". Quite different: electrode placement or skin moisture changed." : "."))
        }
        return notes
    }
}

enum SubjectStore {
    static func folder(for id: UUID, in dataDirectory: URL) -> URL {
        dataDirectory.appending(path: "subjects/\(id.uuidString)")
    }

    static func loadProfiles(in dataDirectory: URL) -> [SubjectProfile] {
        let root = dataDirectory.appending(path: "subjects")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name in
            let url = root.appending(path: "\(name)/profile.json")
            return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(SubjectProfile.self, from: $0) }
        }
        .sorted { ($0.createdAt, $0.name.localizedLowercase) < ($1.createdAt, $1.name.localizedLowercase) }
    }

    static func save(_ profile: SubjectProfile, in dataDirectory: URL) throws {
        let folder = folder(for: profile.id, in: dataDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(profile).write(to: folder.appending(path: "profile.json"), options: .atomic)
        try SessionExporter.updateSubjectIndex(id: profile.id, name: profile.name, in: dataDirectory)
    }

    static func loadHistory(for id: UUID, in dataDirectory: URL) -> SubjectHistory {
        let folder = folder(for: id, in: dataDirectory)
        func load<T: Decodable>(_ file: String) -> [T] {
            (try? Data(contentsOf: folder.appending(path: file))).flatMap { try? decoder.decode([T].self, from: $0) } ?? []
        }
        return SubjectHistory(calibrations: load("calibrations.json"), exams: load("exams.json"))
    }

    static func save(_ history: SubjectHistory, for id: UUID, in dataDirectory: URL) throws {
        let folder = folder(for: id, in: dataDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(history.calibrations).write(to: folder.appending(path: "calibrations.json"), options: .atomic)
        try encoder.encode(history.exams).write(to: folder.appending(path: "exams.json"), options: .atomic)
    }

    /// Moves the subject's folder to the Trash, so a mistaken delete can be undone in Finder.
    static func trash(_ id: UUID, in dataDirectory: URL) throws {
        let folder = folder(for: id, in: dataDirectory)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
