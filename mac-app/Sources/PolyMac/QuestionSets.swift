import AppKit
import Foundation

// Saved question lists: one file per save in `<data>/saved-questions/<subject>/`, named by date
// and subject, e.g. "Alex/2026-11-22 14.30 Alex.json". Each records who the questions were for, when, and, if they
// were asked, how each was answered. Clearing the list afterwards keeps questions off the screen.

struct SavedQuestionSet: Codable, Identifiable, Equatable {
    struct Session: Codable, Equatable {
        var id: UUID
        var startedAt: Date
        var verdict: Verdict?
    }

    struct Asked: Codable, Equatable {
        var number: Int
        var answer: Answer?
        var verdict: Verdict?
        var reactionIndex: Double?
    }

    struct Entry: Codable, Equatable, Identifiable {
        var id = UUID()
        var text: String
        var kind: QuestionKind
        /// Each time it was asked in the session, in order. Empty if it wasn't asked.
        var asked: [Asked] = []
    }

    var id = UUID()
    /// The subject's name when the list was saved.
    var askedTo: String
    var subjectID: UUID?
    var date: Date
    /// The exam session the answers come from, if the questions were asked.
    var session: Session?
    var questions: [Entry]

    var askedCount: Int { questions.filter { !$0.asked.isEmpty }.count }

    var questionList: [Question] { questions.map { Question(text: $0.text, kind: $0.kind) } }

    /// Builds a saved set from the question list plus the answers given in a session (matched by
    /// question text and kind, so it works for a session that has already ended too).
    static func make(
        questions: [Question], askedTo: String, subjectID: UUID?, date: Date = .now,
        session: Session?, answers: [ExamQuestionEntry]
    ) -> SavedQuestionSet {
        let entries = questions.map { question in
            Entry(
                text: question.text,
                kind: question.kind,
                asked: answers.filter { $0.text == question.text && $0.kind == question.kind }.map {
                    Asked(number: $0.number, answer: $0.answer, verdict: $0.verdict, reactionIndex: $0.reactionIndex)
                }
            )
        }
        let anyAsked = entries.contains { !$0.asked.isEmpty }
        return SavedQuestionSet(askedTo: askedTo, subjectID: subjectID, date: date, session: anyAsked ? session : nil, questions: entries)
    }
}

enum QuestionSetStore {
    static func folder(in dataDirectory: URL) -> URL { dataDirectory.appending(path: "saved-questions") }

    /// Every saved set, newest first, each paired with its file.
    static func load(in dataDirectory: URL) -> [(set: SavedQuestionSet, file: URL)] {
        // Files in each subject's folder, plus any saved before they were grouped by subject.
        let top = DataLocation.children(of: folder(in: dataDirectory))
        let files = top + top.flatMap(DataLocation.children(of:))
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let set = try? decoder.decode(SavedQuestionSet.self, from: data) else { return nil }
            return (set, url)
        }
        .sorted { $0.set.date > $1.set.date }
    }

    @discardableResult
    static func save(_ set: SavedQuestionSet, in dataDirectory: URL) throws -> URL {
        let name = DataLocation.folderName(for: set.askedTo)
        let folder = folder(in: dataDirectory).appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = set.date.formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)",
            timeZone: .current, calendar: Calendar(identifier: .gregorian)
        ))
        let base = "\(stamp) \(name)"
        var url = folder.appending(path: "\(base).json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) \(n).json")
            n += 1
        }
        try encoder.encode(set).write(to: url, options: .atomic)
        return url
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Local time with its offset ("2026-11-22T14:30:00-08:00"), so the file reads naturally.
        e.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Saving, clearing and reloading the question list.
extension AppModel {
    /// The list can't change while a question is waiting for its answer or reaction, and the
    /// generated card test isn't the operator's own list.
    var questionListLocked: Bool { phase != .idle || isCardTest }

    /// The subject's name now (they may have been renamed since), else the name saved in the file.
    func currentName(for set: SavedQuestionSet) -> String {
        profiles.first { $0.id == set.subjectID }?.name ?? set.askedTo
    }

    func refreshQuestionSets() {
        let found = QuestionSetStore.load(in: dataDirectory)
        savedQuestionSets = found.map(\.set)
        questionSetFiles = Dictionary(uniqueKeysWithValues: found.map { ($0.set.id, $0.file) })
    }

    /// Answers to attach: this session's if it has any, else the last finished session's, if
    /// that was with the current subject.
    private var answersForSaving: (session: SavedQuestionSet.Session?, answers: [ExamQuestionEntry]) {
        let answered = records.filter { !$0.interrupted && $0.answer != nil }
        if let startedAt = sessionStartedAt, !answered.isEmpty {
            let answers = answered.map {
                ExamQuestionEntry(number: $0.number, text: $0.question.text, kind: $0.question.kind, answer: $0.answer,
                                  reactionIndex: $0.score?.index, gsrDelta: nil, heartRateDelta: nil, breathingSuppression: nil,
                                  verdict: $0.verdict, mlProbability: nil, label: nil, stableAtAsk: $0.stabilityAtAsk == .stable)
            }
            return (SavedQuestionSet.Session(id: sessionID, startedAt: startedAt, verdict: overallVerdict?.verdict), answers)
        }
        if let last = lastExam, last.subjectID == selectedProfileID {
            return (SavedQuestionSet.Session(id: last.entry.id, startedAt: last.entry.startedAt, verdict: last.entry.verdict), last.entry.questions)
        }
        return (nil, [])
    }

    /// Writes the question list to its own file. Returns false if there was nothing to save or it failed.
    @discardableResult
    func saveQuestionSet() -> Bool {
        guard !questions.isEmpty else { return false }
        let (session, answers) = answersForSaving
        let set = SavedQuestionSet.make(questions: questions, askedTo: profile.name, subjectID: profile.id, session: session, answers: answers)
        do {
            let file = try QuestionSetStore.save(set, in: dataDirectory)
            questionSetMessage = "Saved \(questions.count) question\(questions.count == 1 ? "" : "s") for \(profile.name) to \(file.lastPathComponent)"
            refreshQuestionSets()
            return true
        } catch {
            errorMessage = "Couldn't save the questions: \(error.localizedDescription)"
            return false
        }
    }

    func clearQuestions() {
        guard !questionListLocked else { return }
        questions = []
        selectedQuestionID = nil
    }

    func saveAndClearQuestions() {
        guard !questionListLocked, saveQuestionSet() else { return }
        clearQuestions()
    }

    /// Puts a saved set back in the question list, replacing it or adding to the end.
    func loadQuestionSet(_ set: SavedQuestionSet, replace: Bool) {
        guard !questionListLocked else { return }
        let loaded = set.questionList
        questions = replace ? loaded : questions + loaded
        selectedQuestionID = loaded.first?.id
        questionSetMessage = nil
    }

    /// Moves the file to the Trash, so a mistaken delete can be undone in Finder.
    func deleteQuestionSet(_ set: SavedQuestionSet) {
        guard let file = questionSetFiles[set.id] else { return }
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        } catch {
            errorMessage = "Couldn't move the file to the Trash: \(error.localizedDescription)"
        }
        refreshQuestionSets()
    }

    func revealQuestionSet(_ set: SavedQuestionSet?) {
        if let set, let file = questionSetFiles[set.id] {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let folder = QuestionSetStore.folder(in: dataDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }
}
