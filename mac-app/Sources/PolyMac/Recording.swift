import Foundation

/// What was actually true for an answer, entered after a training session.
enum GroundTruth: String, Codable, CaseIterable, Identifiable, Sendable {
    case truth, lie, unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .truth: "Truth"
        case .lie: "Lie"
        case .unknown: "?"
        }
    }
}

/// How a training session establishes ground truth.
enum TrainingProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case cardTest, labelAfter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cardTest: "Card test"
        case .labelAfter: "Label afterwards"
        }
    }

    var instructions: String {
        switch self {
        case .cardTest:
            "Have the subject secretly pick a number and write it down. Ask every question below; they answer No to all of them, so exactly one answer is a lie. At the end you enter the number and the app labels every answer."
        case .labelAfter:
            "Use your own questions, with the truth known to you (for example, the subject follows a sealed note saying which questions to lie on). When you end the session you mark each answer as truth or lie."
        }
    }
}

enum DataLocation {
    /// `<repo>/data` when running from the repo (it's gitignored), else ~/Documents/PolyMac Data.
    /// The packaged app (scripts/build-app.sh) always uses ~/Documents/PolyMac Data, and is compiled
    /// without `#filePath` so the builder's folder paths never end up inside a released binary.
    static var defaultDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "PolyMac Data")
        #if POLYMAC_APP_BUNDLE
        return documents
        #else
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PolyMac
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // mac-app
            .deletingLastPathComponent()  // repo root
        if FileManager.default.fileExists(atPath: repo.appending(path: "mac-app/Package.swift").path) {
            return repo.appending(path: "data")
        }
        return documents
        #endif
    }

    static func sessionCount(in directory: URL) -> Int {
        let sessions = directory.appending(path: "sessions")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        return entries.filter { FileManager.default.fileExists(atPath: sessions.appending(path: "\($0)/questions.csv").path) }.count
    }
}

/// Everything needed to write one session to disk.
struct SessionExport {
    var sessionID: UUID
    var startedAt: Date
    var endedAt: Date
    var profile: SubjectProfile
    var trainingProtocol: TrainingProtocol?
    var cardNumbers: Int?
    var chosenCard: Int?
    var source: String
    var simulatedSubject: String?
    var records: [QuestionRecord]
    var signalIndices: [Int]
    var signals: [[Double]]
    var modelSummary: String?
    var sensors: Set<Channel> = Channel.all
}

/// Writes `<data>/sessions/<date>_<id>/` with:
/// - `session.json`: who, when, protocol, baseline and settings
/// - `questions.csv`: one row per question: labels, the rule-based result, and `f_*` features
/// - `signals.csv`: the raw 100 Hz samples for the whole session
enum SessionExporter {
    static let schemaVersion = 1

    private struct Metadata: Encodable {
        var schemaVersion: Int
        var featureVersion: Int
        var sessionId: String
        var startedAt: Date
        var endedAt: Date
        var subjectId: String
        var trainingSession: Bool
        var trainingProtocol: String?
        var cardNumbers: Int?
        var chosenCard: Int?
        var source: String
        var simulated: Bool
        var simulatedSubject: String?
        var sampleRate: Double
        var baseline: Baseline?
        var gsrInverted: Bool
        var sensitivity: Double
        var responseSeconds: Double
        var questions: Int
        var labeledQuestions: Int
        var modelInUse: String?
        /// Sensors that were on. Features from sensors that were off are neutral (no change).
        var sensors: [String]
    }

    @discardableResult
    static func write(_ session: SessionExport, to dataDirectory: URL) throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let folder = dataDirectory.appending(path: "sessions/\(stamp.string(from: session.startedAt))_\(session.sessionID.uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let records = session.records.filter { !$0.interrupted }
        let metadata = Metadata(
            schemaVersion: schemaVersion,
            featureVersion: Signal.featureVersion,
            sessionId: session.sessionID.uuidString,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            subjectId: session.profile.id.uuidString,
            trainingSession: session.trainingProtocol != nil,
            trainingProtocol: session.trainingProtocol?.rawValue,
            cardNumbers: session.cardNumbers,
            chosenCard: session.chosenCard,
            source: session.source,
            simulated: session.source == "simulator",
            simulatedSubject: session.simulatedSubject,
            sampleRate: Signal.sampleRate,
            baseline: session.profile.baseline,
            gsrInverted: session.profile.gsrInverted,
            sensitivity: session.profile.sensitivity,
            responseSeconds: session.profile.responseSeconds,
            questions: records.count,
            labeledQuestions: records.filter { $0.label == .truth || $0.label == .lie }.count,
            modelInUse: session.modelSummary,
            sensors: Channel.displayOrder.filter(session.sensors.contains).map(\.title)
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: folder.appending(path: "session.json"))

        try questionsCSV(session, records: records).write(to: folder.appending(path: "questions.csv"), atomically: true, encoding: .utf8)
        try signalsCSV(session).write(to: folder.appending(path: "signals.csv"), atomically: true, encoding: .utf8)
        try updateSubjectIndex(id: session.profile.id, name: session.profile.name, in: dataDirectory)
        return folder
    }

    static func questionsCSV(_ session: SessionExport, records: [QuestionRecord]) -> String {
        var featureNames: [String] = []
        for record in records {
            for name in record.features?.names ?? [] where !featureNames.contains(name) {
                featureNames.append(name)
            }
        }
        let header = [
            "session_id", "subject_id", "simulated", "protocol", "number", "kind", "text", "card_number",
            "answer", "label", "stability_at_ask", "ask_sample", "answer_sample", "end_sample",
            "rule_index", "rule_verdict", "ml_probability",
        ] + featureNames.map { "f_" + $0 }

        var lines = [header.joined(separator: ",")]
        for record in records {
            var row: [String] = [
                session.sessionID.uuidString,
                session.profile.id.uuidString,
                session.source == "simulator" ? "1" : "0",
                session.trainingProtocol?.rawValue ?? "none",
                String(record.number),
                record.question.kind.rawValue,
                escape(record.question.text),
                record.question.cardNumber.map(String.init) ?? "",
                record.answer?.rawValue ?? "none",
                (record.label ?? .unknown).rawValue,
                record.stabilityAtAsk.title.lowercased(),
                String(record.askSample),
                record.answerSample.map(String.init) ?? "",
                record.responseEndSample.map(String.init) ?? "",
                record.score.map { format($0.index) } ?? "",
                record.verdict?.rawValue ?? "",
                record.mlProbability.map(format) ?? "",
            ]
            row += featureNames.map { name in record.features?[name].map(format) ?? "" }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func signalsCSV(_ session: SessionExport) -> String {
        var out = "sample,resp,pulse,gsr\n"
        out.reserveCapacity(session.signalIndices.count * 20)
        for (i, index) in session.signalIndices.enumerated() {
            out += "\(index),\(format(session.signals[0][i])),\(format(session.signals[1][i])),\(format(session.signals[2][i]))\n"
        }
        return out
    }

    /// `subjects.json` maps the anonymous subject IDs used in the data back to names, locally.
    static func updateSubjectIndex(id: UUID, name: String, in dataDirectory: URL) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let url = dataDirectory.appending(path: "subjects.json")
        var index = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
        index[id.uuidString] = name
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: url)
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(format: "%.5g", value)
    }

    private static func escape(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
