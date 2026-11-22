import Foundation
import Testing
@testable import PolyMac

private func answer(_ number: Int, _ text: String, _ kind: QuestionKind, _ answer: Answer, _ verdict: Verdict?) -> ExamQuestionEntry {
    ExamQuestionEntry(number: number, text: text, kind: kind, answer: answer, reactionIndex: 40, gsrDelta: nil, heartRateDelta: nil,
                      breathingSuppression: nil, verdict: verdict, mlProbability: nil, label: nil, stableAtAsk: true)
}

@Test func savedSetAttachesEachQuestionsAnswers() {
    let questions = [
        Question(text: "Is the light on?", kind: .irrelevant),
        Question(text: "Did you take it?", kind: .relevant),
        Question(text: "Not asked yet", kind: .control),
    ]
    let session = SavedQuestionSet.Session(id: UUID(), startedAt: .now, verdict: .deceptive)
    let set = SavedQuestionSet.make(
        questions: questions, askedTo: "Alex", subjectID: UUID(), session: session,
        answers: [
            answer(1, "Is the light on?", .irrelevant, .yes, nil),
            answer(2, "Did you take it?", .relevant, .no, .deceptive),
            answer(3, "Did you take it?", .relevant, .no, .inconclusive),
            answer(4, "Did you take it?", .control, .no, nil),  // same text, different kind: not this question
        ]
    )
    #expect(set.askedTo == "Alex" && set.session == session)
    #expect(set.questions.map(\.asked.count) == [1, 2, 0])
    #expect(set.questions[1].asked.map(\.verdict) == [.deceptive, .inconclusive])
    #expect(set.askedCount == 2)
    #expect(set.questionList.map(\.text) == questions.map(\.text))

    // Nothing asked: no session is attached.
    let unasked = SavedQuestionSet.make(questions: questions, askedTo: "Sam", subjectID: nil, session: session, answers: [])
    #expect(unasked.session == nil && unasked.askedCount == 0)
}

@Test func savedSetsAreFilesNamedByDateAndSubject() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "polymac-qsets-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let older = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9, minute: 5)))
    let newer = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 14, minute: 30)))
    let questions = [Question(text: "Did you take it?", kind: .relevant)]
    let a = SavedQuestionSet.make(questions: questions, askedTo: "Alex", subjectID: UUID(), date: older, session: nil, answers: [])
    let b = SavedQuestionSet.make(questions: questions, askedTo: "Sam / Jo", subjectID: UUID(), date: newer, session: nil, answers: [])
    let fileA = try QuestionSetStore.save(a, in: directory)
    let fileB = try QuestionSetStore.save(b, in: directory)
    let again = try QuestionSetStore.save(b, in: directory)

    #expect(fileA.lastPathComponent == "2026-11-20 09.05 Alex.json")
    #expect(fileA.deletingLastPathComponent().lastPathComponent == "Alex")  // one folder per subject
    #expect(fileB.lastPathComponent == "2026-11-22 14.30 Sam - Jo.json")
    #expect(again.lastPathComponent == "2026-11-22 14.30 Sam - Jo 2.json")  // never overwrites

    // The file leads with who and when, in local time.
    let text = try String(contentsOf: fileA, encoding: .utf8)
    #expect(text.contains(#""askedTo" : "Alex""#))
    #expect(text.contains(#""date" : "2026-11-20T09:05:00"#))

    let loaded = QuestionSetStore.load(in: directory)
    #expect(loaded.count == 3)
    #expect(loaded.last?.set == a)  // newest first
    #expect(loaded.first?.set.date == newer)
}

// MARK: - Sessions grouped by subject

private func makeSessionFolder(_ root: URL, _ name: String, subjectID: UUID) throws {
    let folder = root.appending(path: name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "number\n1\n".write(to: folder.appending(path: "questions.csv"), atomically: true, encoding: .utf8)
    try #"{"subject_id":"\#(subjectID.uuidString)"}"#.write(to: folder.appending(path: "session.json"), atomically: true, encoding: .utf8)
}

@Test func olderSessionsMoveIntoTheirSubjectsFolder() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "polymac-org-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessions = directory.appending(path: "sessions")
    let alex = UUID(), gone = UUID()
    try makeSessionFolder(sessions, "2026-11-20_090000_AAAA0001", subjectID: alex)
    try makeSessionFolder(sessions, "2026-11-21_090000_AAAA0002", subjectID: alex)
    try makeSessionFolder(sessions, "2026-11-21_100000_BBBB0001", subjectID: gone)
    try makeSessionFolder(sessions.appending(path: "Sam"), "2026-11-22_090000_CCCC0001", subjectID: UUID())  // already grouped
    #expect(DataLocation.sessionCount(in: directory) == 4)

    let moved = SessionExporter.organizeBySubject(in: directory, names: [alex: "Alex"])
    #expect(moved == [
        "2026-11-20_090000_AAAA0001": "Alex/2026-11-20_090000_AAAA0001",
        "2026-11-21_090000_AAAA0002": "Alex/2026-11-21_090000_AAAA0002",
        "2026-11-21_100000_BBBB0001": "Unknown subject/2026-11-21_100000_BBBB0001",
    ])
    #expect(DataLocation.isSession(sessions.appending(path: "Alex/2026-11-20_090000_AAAA0001")))
    #expect(DataLocation.sessionCount(in: directory) == 4)
    #expect(SessionExporter.organizeBySubject(in: directory, names: [alex: "Alex"]).isEmpty)  // nothing left to move

    // Renaming the subject renames their folder.
    try DataLocation.renameSubjectFolder(from: "Alex", to: "Alex K", under: sessions)
    #expect(DataLocation.isSession(sessions.appending(path: "Alex K/2026-11-21_090000_AAAA0002")))
    #expect(!FileManager.default.fileExists(atPath: sessions.appending(path: "Alex").path))
    #expect(DataLocation.sessionCount(in: directory) == 4)
}

@Test func subjectNamesBecomeSafeFolderNames() {
    #expect(DataLocation.folderName(for: "Alex") == "Alex")
    #expect(DataLocation.folderName(for: "  Sam / Jo ") == "Sam - Jo")
    #expect(DataLocation.folderName(for: "..") == "Unnamed")
    #expect(DataLocation.folderName(for: "") == "Unnamed")
}
