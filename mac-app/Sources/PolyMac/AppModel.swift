import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum Source: Equatable {
        case none
        case serial(String)
        case simulator
    }

    enum ExamPhase: Equatable {
        case idle
        case awaitingAnswer(UUID)
        case responseWindow(UUID, end: Int)
    }

    struct CalibrationResult: Equatable {
        var baseline: Baseline
        var quality: [ChannelQuality]
    }

    enum CalibrationState: Equatable {
        case idle
        case recording(start: Int, end: Int)
        case finished(CalibrationResult)
        case failed(String)
    }

    static let baudRate = 115_200
    static let nominalSampleRate = 100  // matches SAMPLE_INTERVAL_US in the firmware
    static let windowChoices = [5, 10, 30]
    static let answerTimeout = 10.0
    static let preQuestionSeconds = 5.0
    static let calibrationChoices = [20, 30, 60]

    // MARK: Connection

    var ports: [String] = []
    var selectedPort: String?
    var windowSeconds = 10
    private(set) var source: Source = .none
    var errorMessage: String?

    // MARK: Live analysis (refreshed 5× a second)

    private(set) var currentSample = 0
    private(set) var stats = LiveStats.empty
    private(set) var stability = StabilityReport.noData
    private(set) var stableSeconds: Double = 0
    @ObservationIgnored private var stableSince: Date?

    // MARK: Subjects

    var profiles: [SubjectProfile] {
        didSet { Persistence.save(profiles, key: "profiles") }
    }

    var selectedProfileID: UUID {
        didSet {
            UserDefaults.standard.set(selectedProfileID.uuidString, forKey: "selectedProfile")
            recomputeVerdicts()
        }
    }

    // MARK: Calibration

    private(set) var calibration: CalibrationState = .idle
    var calibrationSeconds = 30
    var showingCalibration = false

    // MARK: Examination

    var questions: [Question] {
        didSet { Persistence.save(questions, key: "questions") }
    }

    var selectedQuestionID: UUID?
    private(set) var records: [QuestionRecord] = []
    private(set) var phase: ExamPhase = .idle
    private(set) var liveReaction: ReactionScore?
    var requireStability = true
    var simulatedSubject: SimulatedSubject = .random

    @ObservationIgnored let buffer = SampleBuffer(capacity: AppModel.nominalSampleRate * 300)
    @ObservationIgnored private var serial: SerialPort?
    @ObservationIgnored private var simulator: Simulator?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init() {
        let saved = Persistence.load([SubjectProfile].self, key: "profiles") ?? []
        let profiles = saved.isEmpty ? [SubjectProfile(name: "Guest")] : saved
        self.profiles = profiles
        let savedID = UserDefaults.standard.string(forKey: "selectedProfile").flatMap(UUID.init(uuidString:))
        selectedProfileID = profiles.first { $0.id == savedID }?.id ?? profiles[0].id
        questions = Persistence.load([Question].self, key: "questions") ?? Question.starterSet
        selectedQuestionID = questions.first?.id
        refreshPorts()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                self.tick()
            }
        }
    }

    var isRunning: Bool { source != .none }

    var isCalibrating: Bool {
        if case .recording = calibration { return true }
        return false
    }

    // MARK: - Connection

    func refreshPorts() {
        ports = SerialPort.availablePorts()
        if let selected = selectedPort, ports.contains(selected) { return }
        selectedPort = ports.first(where: SerialPort.looksLikeBoard) ?? ports.first
    }

    func connect() {
        guard let path = selectedPort else { return }
        stop()
        buffer.reset()
        let buffer = buffer
        let port = SerialPort(
            path: path,
            onLine: { line in
                if let reading = SampleParser.parse(line) {
                    buffer.append(reading)
                } else {
                    buffer.noteUnparsedLine()
                }
            },
            onUnexpectedClose: { [weak self] reason in
                Task { @MainActor in self?.serialClosed(path: path, reason: reason) }
            }
        )
        do {
            try port.open(baud: Self.baudRate)
            serial = port
            source = .serial(path)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startSimulation() {
        stop()
        buffer.reset()
        let buffer = buffer
        let simulator = Simulator { buffer.append($0) }
        simulator.start()
        self.simulator = simulator
        source = .simulator
        errorMessage = nil
    }

    func stop() {
        serial?.close()
        serial = nil
        simulator?.stop()
        simulator = nil
        source = .none
        interruptActiveQuestion()
        if isCalibrating { calibration = .failed("The data stream stopped before calibration finished.") }
    }

    private func serialClosed(path: String, reason: String) {
        guard source == .serial(path) else { return }
        serial = nil
        source = .none
        interruptActiveQuestion()
        if isCalibrating { calibration = .failed("The board disconnected during calibration.") }
        errorMessage = "\(displayName(for: path)): \(reason)"
        refreshPorts()
    }

    func displayName(for path: String) -> String {
        path.replacingOccurrences(of: "/dev/cu.", with: "")
    }

    // MARK: - Periodic analysis

    private func tick() {
        currentSample = buffer.totalCount
        if isRunning {
            let snapshot = buffer.snapshot(last: Signal.samples(30))
            stats = Signal.liveStats(
                channels: snapshot.channels,
                samplesPerSecond: snapshot.samplesPerSecond,
                gsrInverted: profile.gsrInverted,
                responseThreshold: baseline.gsrResponseThreshold
            )
            stability = Signal.stability(stats, baseline: profile.baseline)
        } else {
            stats = .empty
            stability = .noData
        }

        if stability.level == .stable {
            let since = stableSince ?? .now
            stableSince = since
            stableSeconds = Date.now.timeIntervalSince(since)
        } else {
            stableSince = nil
            stableSeconds = 0
        }

        advanceCalibration()
        advanceExam()
    }

    // MARK: - Subjects

    var profile: SubjectProfile {
        get { profiles.first { $0.id == selectedProfileID } ?? profiles[0] }
        set {
            guard let i = profiles.firstIndex(where: { $0.id == newValue.id }) else { return }
            profiles[i] = newValue
            recomputeVerdicts()
        }
    }

    /// The selected subject's baseline, or generic defaults before calibration.
    var baseline: Baseline { profile.baseline ?? .defaults }

    func addProfile() {
        let new = SubjectProfile(name: "Subject \(profiles.count + 1)")
        profiles.append(new)
        selectedProfileID = new.id
    }

    func deleteSelectedProfile() {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == selectedProfileID }
        selectedProfileID = profiles[0].id
    }

    // MARK: - Calibration

    var calibrationProgress: Double {
        guard case .recording(let start, let end) = calibration else { return 0 }
        return Signal.clamp01(Double(currentSample - start) / Double(end - start))
    }

    var calibrationSecondsLeft: Int {
        guard case .recording(_, let end) = calibration else { return 0 }
        return max(0, Int((Double(end - currentSample) / Signal.sampleRate).rounded(.up)))
    }

    func startCalibration() {
        guard isRunning, phase == .idle else { return }
        let start = buffer.totalCount
        calibration = .recording(start: start, end: start + Signal.samples(Double(calibrationSeconds)))
    }

    func cancelCalibration() {
        calibration = .idle
    }

    func saveCalibration() {
        guard case .finished(let result) = calibration else { return }
        var updated = profile
        updated.baseline = result.baseline
        profile = updated
        calibration = .idle
        showingCalibration = false
    }

    func closeCalibration() {
        if case .finished = calibration { calibration = .idle }
        if case .failed = calibration { calibration = .idle }
        showingCalibration = false
    }

    private func advanceCalibration() {
        guard case .recording(let start, let end) = calibration, currentSample >= end else { return }
        let data = buffer.samples(from: start, to: end)
        guard data[0].count >= (end - start) * 9 / 10 else {
            calibration = .failed("Some samples went missing during the recording. Try again.")
            return
        }
        let (baseline, quality) = Signal.calibrate(channels: data, gsrInverted: profile.gsrInverted)
        calibration = .finished(CalibrationResult(baseline: baseline, quality: quality))
    }

    // MARK: - Examination

    var selectedQuestion: Question? {
        questions.first { $0.id == selectedQuestionID }
    }

    var activeRecord: QuestionRecord? {
        switch phase {
        case .idle: nil
        case .awaitingAnswer(let id), .responseWindow(let id, _): records.first { $0.id == id }
        }
    }

    var secondsSinceAsk: Double {
        guard let record = activeRecord else { return 0 }
        return Double(currentSample - record.askSample) / Signal.sampleRate
    }

    var responseProgress: Double {
        guard case .responseWindow(_, let end) = phase, let record = activeRecord, let answered = record.answerSample else { return 0 }
        return Signal.clamp01(Double(currentSample - answered) / Double(end - answered))
    }

    var responseSecondsLeft: Int {
        guard case .responseWindow(_, let end) = phase else { return 0 }
        return max(0, Int((Double(end - currentSample) / Signal.sampleRate).rounded(.up)))
    }

    /// Why the Ask button is disabled, if it is.
    var askBlockedReason: String? {
        if !isRunning { return "Connect a board or start the simulator." }
        if isCalibrating { return "Wait for calibration to finish." }
        if phase != .idle { return "A question is already in progress." }
        if selectedQuestion == nil { return "Pick or add a question below." }
        if requireStability && stability.level != .stable { return "Waiting for the subject to be stable." }
        return nil
    }

    var canAsk: Bool { askBlockedReason == nil }

    func ask() {
        guard canAsk, let question = selectedQuestion else { return }
        let record = QuestionRecord(
            number: records.count + 1,
            question: question,
            askSample: buffer.totalCount,
            stabilityAtAsk: stability.level
        )
        records.append(record)
        phase = .awaitingAnswer(record.id)
        liveReaction = nil
        simulator?.stimulate(strength: simulatedStrength(for: question.kind))
    }

    func answer(_ answer: Answer) {
        guard case .awaitingAnswer(let id) = phase, let i = records.firstIndex(where: { $0.id == id }) else { return }
        let now = buffer.totalCount
        let end = now + Signal.samples(profile.responseSeconds)
        records[i].answer = answer
        records[i].answerSample = now
        records[i].responseEndSample = end
        phase = .responseWindow(id, end: end)
    }

    func cancelQuestion() {
        interruptActiveQuestion()
    }

    func addQuestion(_ text: String, kind: QuestionKind) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let question = Question(text: trimmed, kind: kind)
        questions.append(question)
        selectedQuestionID = question.id
    }

    func deleteQuestion(_ id: UUID) {
        questions.removeAll { $0.id == id }
        if selectedQuestionID == id { selectedQuestionID = questions.first?.id }
    }

    func resetSession() {
        interruptActiveQuestion()
        records.removeAll()
        selectedQuestionID = questions.first?.id
    }

    func timesAsked(_ question: Question) -> Int {
        records.filter { $0.question.id == question.id && !$0.interrupted }.count
    }

    private func interruptActiveQuestion() {
        if let id = activeRecord?.id, let i = records.firstIndex(where: { $0.id == id }) {
            records[i].interrupted = true
        }
        phase = .idle
        liveReaction = nil
    }

    private func advanceExam() {
        guard let record = activeRecord, let i = records.firstIndex(where: { $0.id == record.id }) else {
            phase = .idle
            liveReaction = nil
            return
        }
        switch phase {
        case .idle:
            break
        case .awaitingAnswer:
            liveReaction = reaction(for: record, until: currentSample)
            if secondsSinceAsk >= Self.answerTimeout { answer(.none) }
        case .responseWindow(_, let end):
            liveReaction = reaction(for: record, until: min(currentSample, end))
            if currentSample >= end {
                records[i].score = reaction(for: record, until: end)
                phase = .idle
                liveReaction = nil
                recomputeVerdicts()
                advanceSelection(after: record.question)
            }
        }
    }

    private func reaction(for record: QuestionRecord, until end: Int) -> ReactionScore? {
        let pre = buffer.samples(from: record.askSample - Signal.samples(Self.preQuestionSeconds), to: record.askSample)
        let post = buffer.samples(from: record.askSample, to: end)
        return Signal.reaction(pre: pre, post: post, baseline: baseline, gsrInverted: profile.gsrInverted)
    }

    private func advanceSelection(after question: Question) {
        guard let i = questions.firstIndex(where: { $0.id == question.id }) else { return }
        selectedQuestionID = questions[(i + 1) % questions.count].id
    }

    private func simulatedStrength(for kind: QuestionKind) -> Double {
        switch kind {
        case .irrelevant:
            return Double.random(in: 0...0.1)
        case .control:
            return Double.random(in: 0.4...0.65)
        case .relevant:
            let lying = simulatedSubject == .lying || (simulatedSubject == .random && Bool.random())
            return lying ? Double.random(in: 0.8...1) : Double.random(in: 0.05...0.3)
        }
    }

    // MARK: - Verdicts

    /// Mean reaction to control questions this session, the yardstick for relevant ones.
    var controlMean: Double? {
        let controls = records.filter { $0.question.kind == .control }.compactMap { $0.score?.index }
        return controls.isEmpty ? nil : Signal.mean(controls)
    }

    private func recomputeVerdicts() {
        let control = controlMean
        for i in records.indices {
            guard records[i].question.kind == .relevant, let score = records[i].score else {
                records[i].verdict = nil
                continue
            }
            records[i].verdict = Signal.verdict(index: score.index, controlMean: control, sensitivity: profile.sensitivity).verdict
        }
    }

    var overallVerdict: VerdictReading? {
        let relevant = records.filter { $0.question.kind == .relevant }.compactMap { $0.score?.index }
        guard !relevant.isEmpty else { return nil }
        return Signal.verdict(index: Signal.mean(relevant), controlMean: controlMean, sensitivity: profile.sensitivity)
    }

    /// What the gauge shows: the live reading while a relevant question is in progress, else the session verdict.
    var displayedVerdict: (reading: VerdictReading?, isLive: Bool) {
        if let record = activeRecord, record.question.kind == .relevant, let live = liveReaction {
            return (Signal.verdict(index: live.index, controlMean: controlMean, sensitivity: profile.sensitivity), true)
        }
        return (overallVerdict, false)
    }

    // MARK: - Chart annotations

    var chartMarkers: [ChartMarker] {
        records.filter { !$0.interrupted }.flatMap { record -> [ChartMarker] in
            var markers = [ChartMarker(id: "\(record.id)-ask", sample: record.askSample, label: "Q\(record.number)", color: record.question.kind.color)]
            if let sample = record.answerSample, let answer = record.answer {
                markers.append(ChartMarker(id: "\(record.id)-answer", sample: sample, label: answer.shortTitle, color: .secondary))
            }
            return markers
        }
    }

    var chartRegions: [ChartRegion] {
        var regions = records.filter { !$0.interrupted }.map { record in
            ChartRegion(id: "\(record.id)", start: record.askSample, end: record.responseEndSample ?? currentSample, color: record.question.kind.color)
        }
        if case .recording(let start, let end) = calibration {
            regions.append(ChartRegion(id: "calibration", start: start, end: min(end, currentSample), color: .blue))
        }
        return regions
    }
}
