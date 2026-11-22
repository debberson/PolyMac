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
        var method: CalibrationEntry.Method = .recorded
        /// How this compares with the subject's usual resting values.
        var notes: [String] = []
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
    static let cardTestRounds = 2
    /// Raw signal kept from before the first question of a recorded session.
    static let sessionLeadInSeconds = 30.0

    // MARK: Connection

    var ports: [String] = []
    var selectedPort: String?
    var windowSeconds = 10
    private(set) var source: Source = .none {
        didSet { updateStreamingActivity() }
    }
    var errorMessage: String?

    // MARK: Live analysis (refreshed 5× a second)

    private(set) var currentSample = 0
    private(set) var stats = LiveStats.empty
    private(set) var stability = StabilityReport.noData
    private(set) var stableSeconds: Double = 0
    @ObservationIgnored private var stableSince: Date?

    // MARK: Subjects

    /// Stored in the data folder's subject database (see `SubjectStore`), with a backup copy in
    /// UserDefaults that seeds a data folder that has no subjects yet.
    var profiles: [SubjectProfile] {
        didSet {
            Persistence.save(profiles, key: "profiles")
            if !loadingSubjects { saveChangedProfiles(oldValue) }
        }
    }

    var selectedProfileID: UUID {
        didSet {
            UserDefaults.standard.set(selectedProfileID.uuidString, forKey: "selectedProfile")
            recomputeVerdicts()
        }
    }

    /// Calibrations and finished exams per subject, loaded from the data folder.
    var histories: [UUID: SubjectHistory] = [:]
    @ObservationIgnored var loadingSubjects = false

    // MARK: Sensors

    /// Sensors that are plugged in and used. Ones that are off are hidden and left out of
    /// stability checks, calibration, scoring and experiment analysis.
    var enabledSensors: Set<Channel> {
        didSet { UserDefaults.standard.set(enabledSensors.map(\.rawValue).sorted(), forKey: "enabledSensors") }
    }

    // MARK: Calibration

    var calibration: CalibrationState = .idle
    var calibrationSeconds = 30
    @ObservationIgnored var calibrationMethod: CalibrationEntry.Method = .recorded
    var showingCalibration = false

    // MARK: Examination

    var questions: [Question] {
        didSet { Persistence.save(questions, key: "questions") }
    }

    var selectedQuestionID: UUID?
    private(set) var records: [QuestionRecord] = []
    private(set) var phase: ExamPhase = .idle
    private(set) var liveReaction: ReactionScore?
    private(set) var liveProbability: Double?
    var requireStability = true
    var simulatedSubject: SimulatedSubject = .random

    // MARK: Recording & training data

    var recordSessions: Bool {
        didSet { UserDefaults.standard.set(recordSessions, forKey: "recordSessions") }
    }

    /// Off: chart scales hold still (see `ChartScales`). Also fixes the review timeline's scale.
    var autoScale: Bool {
        didSet { UserDefaults.standard.set(autoScale, forKey: "autoScale") }
    }
    @ObservationIgnored let chartScales = ChartScales()

    var trainingMode: Bool {
        didSet {
            UserDefaults.standard.set(trainingMode, forKey: "trainingMode")
            selectFirstQuestion()
        }
    }

    var trainingProtocol: TrainingProtocol {
        didSet {
            UserDefaults.standard.set(trainingProtocol.rawValue, forKey: "trainingProtocol")
            selectFirstQuestion()
        }
    }

    var cardTestNumbers = 6 {
        didSet { regenerateCardTest() }
    }

    private(set) var cardTestQuestions: [Question] = []

    var dataDirectory: URL {
        didSet {
            UserDefaults.standard.set(dataDirectory.path, forKey: "dataDirectory")
            savedSessionCount = DataLocation.sessionCount(in: dataDirectory)
            loadModel()
            refreshSavedExperiments()
            reloadSubjects()
        }
    }

    private(set) var savedSessionCount = 0
    /// Set when the first question of a session is asked; cleared when the session is saved or discarded.
    private(set) var sessionStartedAt: Date?
    var showingSessionEnd = false
    var lastSaveMessage: String?
    /// Card test: the number the subject secretly picked, entered when labeling.
    var chosenCard: Int? {
        didSet { if let chosenCard { applyCardLabels(chosen: chosenCard) } }
    }

    @ObservationIgnored private(set) var sessionID = UUID()
    @ObservationIgnored private(set) var sessionSource = ""
    @ObservationIgnored private var sessionSimulatedSubject: SimulatedSubject?
    @ObservationIgnored private var simulatedCardChoice: Int?
    @ObservationIgnored private var signalsNext = 0
    @ObservationIgnored private var signalIndices: [Int] = []
    @ObservationIgnored private var signalChannels: [[Double]] = [[], [], []]

    // MARK: Experiment mode (logic in ExperimentModel.swift)

    var appMode: AppMode = .exam
    var experimentTemplateID = ExperimentTemplate.free.id
    var experimentTitle = ""
    var experimentRecording = false
    /// Absolute sample index where the live recording began.
    var experimentStart = 0
    var experimentPhases: [ExperimentPhase] = []
    var experimentMarkers: [ExperimentMarker] = []
    var markerDraft = ""
    var review: ExperimentRecording?
    var reviewAnalysis: ExperimentAnalysis?
    var reviewSaveStatus: String?
    var reviewWindowStart: Double = 0
    /// Seconds visible on the review timeline; 0 = whole recording.
    var reviewZoom: Double = 60
    var savedExperiments: [SavedExperiment] = []
    @ObservationIgnored var experimentChannels: [[Double]] = [[], [], []]
    @ObservationIgnored var experimentNext = 0

    // MARK: Trained model

    @ObservationIgnored private var model: DeceptionModel?
    private(set) var modelStatus = "No trained model yet"
    private(set) var modelLoaded = false
    var useModel = false {
        didSet { recomputeVerdicts() }
    }

    @ObservationIgnored let buffer = SampleBuffer(capacity: AppModel.nominalSampleRate * 300)
    @ObservationIgnored private var serial: SerialPort?
    @ObservationIgnored var simulator: Simulator?
    /// Held while a data source runs so App Nap can't throttle sampling, analysis and recording
    /// when the window is hidden or the display sleeps.
    @ObservationIgnored private var streamingActivity: NSObjectProtocol?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var lastPortScan = Date.distantPast

    init() {
        let defaults = UserDefaults.standard
        let dataDirectory = defaults.string(forKey: "dataDirectory").map { URL(fileURLWithPath: $0) } ?? DataLocation.defaultDirectory
        var profiles = SubjectStore.loadProfiles(in: dataDirectory)
        let migrating = profiles.isEmpty
        if migrating {
            let saved = Persistence.load([SubjectProfile].self, key: "profiles") ?? []
            profiles = saved.isEmpty ? [SubjectProfile(name: "Guest")] : saved
        }
        self.profiles = profiles
        let savedID = defaults.string(forKey: "selectedProfile").flatMap(UUID.init(uuidString:))
        selectedProfileID = profiles.first { $0.id == savedID }?.id ?? profiles[0].id
        questions = Persistence.load([Question].self, key: "questions") ?? Question.starterSet
        recordSessions = defaults.object(forKey: "recordSessions") as? Bool ?? true
        autoScale = defaults.object(forKey: "autoScale") as? Bool ?? true
        trainingMode = defaults.bool(forKey: "trainingMode")
        trainingProtocol = defaults.string(forKey: "trainingProtocol").flatMap(TrainingProtocol.init(rawValue:)) ?? .cardTest
        self.dataDirectory = dataDirectory
        let savedSensors = Set((defaults.array(forKey: "enabledSensors") as? [Int] ?? []).compactMap(Channel.init(rawValue:)))
        enabledSensors = savedSensors.isEmpty ? Channel.all : savedSensors

        if migrating { profiles.forEach(saveProfile) }
        reloadHistories()
        regenerateCardTest()
        selectFirstQuestion()
        savedSessionCount = DataLocation.sessionCount(in: dataDirectory)
        refreshPorts()
        loadModel()
        refreshSavedExperiments()
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

    var sessionInProgress: Bool { sessionStartedAt != nil || !records.isEmpty }
    var isRecordingSession: Bool { recordSessions && sessionStartedAt != nil }

    // MARK: - Connection

    /// Rescans /dev. Runs every couple of seconds while disconnected (see `tick`), so a board plugged
    /// in after launch shows up on its own. A newly appeared board is selected even if another port
    /// was picked before (for example Bluetooth-Incoming-Port, chosen when nothing was plugged in).
    func refreshPorts() {
        let found = SerialPort.availablePorts()
        let previous = ports
        if found != ports { ports = found }
        guard !isRunning else { return }
        let choice = Self.portToSelect(found: found, previous: previous, selected: selectedPort)
        if choice != selectedPort { selectedPort = choice }
    }

    nonisolated static func portToSelect(found: [String], previous: [String], selected: String?) -> String? {
        if let board = found.first(where: { SerialPort.looksLikeBoard($0) && !previous.contains($0) }) {
            return board  // just plugged in
        }
        if let selected, found.contains(selected) { return selected }
        return found.first(where: SerialPort.looksLikeBoard) ?? found.first
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
        captureSignals()
        if experimentRecording { finishExperiment() }
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
        captureSignals()
        if experimentRecording { finishExperiment() }
        serial = nil
        source = .none
        interruptActiveQuestion()
        if isCalibrating { calibration = .failed("The board disconnected during calibration.") }
        errorMessage = "\(displayName(for: path)): \(reason)"
        refreshPorts()
    }

    private func updateStreamingActivity() {
        if isRunning, streamingActivity == nil {
            streamingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Streaming and recording sensor data"
            )
        } else if !isRunning, let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
    }

    func displayName(for path: String) -> String {
        path.replacingOccurrences(of: "/dev/cu.", with: "")
    }

    // MARK: - Periodic analysis

    private func tick() {
        currentSample = buffer.totalCount
        if !isRunning, Date.now.timeIntervalSince(lastPortScan) >= 2 {
            lastPortScan = .now
            refreshPorts()
        }
        if isRunning {
            let snapshot = buffer.snapshot(last: Signal.samples(30))
            stats = Signal.liveStats(
                channels: snapshot.channels,
                samplesPerSecond: snapshot.samplesPerSecond,
                gsrInverted: profile.gsrInverted,
                responseThreshold: baseline.gsrResponseThreshold,
                sensors: enabledSensors
            )
            stability = Signal.stability(stats, baseline: profile.baseline, sensors: enabledSensors)
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

        captureSignals()
        advanceCalibration()
        advanceExam()
        advanceExperiment()
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
        calibrationMethod = .recorded
        let start = buffer.totalCount
        calibration = .recording(start: start, end: start + Signal.samples(Double(calibrationSeconds)))
    }

    static let quickCalibrationSeconds = 15

    /// A 15 s recording, steadied with the subject's earlier calibrations.
    func startQuickCalibration() {
        guard isRunning, phase == .idle, usualValues != nil else { return }
        calibrationMethod = .quick
        let start = buffer.totalCount
        calibration = .recording(start: start, end: start + Signal.samples(Double(Self.quickCalibrationSeconds)))
    }

    func cancelCalibration() {
        calibration = .idle
    }

    func saveCalibration() {
        guard case .finished(let result) = calibration else { return }
        var updated = profile
        updated.baseline = result.baseline
        profile = updated
        recordCalibration(result)
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
        var (baseline, quality) = Signal.calibrate(
            channels: data, gsrInverted: profile.gsrInverted, sensors: enabledSensors, previous: profile.baseline
        )
        let usual = usualValues
        if calibrationMethod == .quick, let usual { baseline = usual.steady(baseline) }
        calibration = .finished(CalibrationResult(
            baseline: baseline, quality: quality, method: calibrationMethod,
            notes: usual?.comparison(with: baseline) ?? []
        ))
    }

    // MARK: - Questions

    var isCardTest: Bool { trainingMode && trainingProtocol == .cardTest }

    /// The bank the operator picks from: the generated card test, or the editable question list.
    var activeQuestions: [Question] { isCardTest ? cardTestQuestions : questions }

    var selectedQuestion: Question? {
        activeQuestions.first { $0.id == selectedQuestionID }
    }

    func regenerateCardTest() {
        var generated: [Question] = []
        for _ in 0..<Self.cardTestRounds {
            var order = Array(1...cardTestNumbers).shuffled()
            // Don't ask the same number twice in a row across rounds.
            if order.first == generated.last?.cardNumber { order.swapAt(0, order.count - 1) }
            generated += order.map { Question(text: "Is your number \($0)?", kind: .relevant, cardNumber: $0) }
        }
        cardTestQuestions = generated
        if isCardTest { selectFirstQuestion() }
    }

    private func selectFirstQuestion() {
        selectedQuestionID = activeQuestions.first?.id
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
        if selectedQuestionID == id { selectFirstQuestion() }
    }

    func timesAsked(_ question: Question) -> Int {
        records.filter { $0.question.id == question.id && !$0.interrupted }.count
    }

    // MARK: - Examination

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
        if selectedQuestion == nil {
            return isCardTest ? "Card test complete. End the session to label and save it." : "Pick or add a question below."
        }
        if requireStability && stability.level != .stable { return "Waiting for the subject to be stable." }
        return nil
    }

    var canAsk: Bool { askBlockedReason == nil }

    func ask() {
        guard canAsk, let question = selectedQuestion else { return }
        if sessionStartedAt == nil { beginSession() }
        let reaction = simulatedReaction(to: question)
        var record = QuestionRecord(
            number: records.count + 1,
            question: question,
            askSample: buffer.totalCount,
            stabilityAtAsk: stability.level
        )
        record.simulatedTruth = reaction?.truth
        records.append(record)
        phase = .awaitingAnswer(record.id)
        liveReaction = nil
        liveProbability = nil
        if let reaction { simulator?.stimulate(strength: reaction.strength) }
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

    private func interruptActiveQuestion() {
        if let id = activeRecord?.id, let i = records.firstIndex(where: { $0.id == id }) {
            records[i].interrupted = true
        }
        phase = .idle
        liveReaction = nil
        liveProbability = nil
    }

    private func advanceExam() {
        guard let record = activeRecord, let i = records.firstIndex(where: { $0.id == record.id }) else {
            phase = .idle
            liveReaction = nil
            liveProbability = nil
            return
        }
        switch phase {
        case .idle:
            break
        case .awaitingAnswer:
            updateLive(record, until: currentSample)
            if secondsSinceAsk >= Self.answerTimeout { answer(.none) }
        case .responseWindow(_, let end):
            updateLive(record, until: min(currentSample, end))
            if currentSample >= end {
                records[i].score = reaction(for: record, until: end)
                records[i].features = features(for: records[i], until: end)
                records[i].mlProbability = records[i].features.flatMap { model?.probability($0) }
                phase = .idle
                liveReaction = nil
                liveProbability = nil
                recomputeVerdicts()
                advanceSelection(after: record.question)
            }
        }
    }

    private func updateLive(_ record: QuestionRecord, until end: Int) {
        liveReaction = reaction(for: record, until: end)
        if useModel, let model {
            liveProbability = features(for: record, until: end).flatMap { model.probability($0) }
        }
    }

    private func window(for record: QuestionRecord, until end: Int) -> (pre: [[Double]], post: [[Double]]) {
        let pre = buffer.samples(from: record.askSample - Signal.samples(Self.preQuestionSeconds), to: record.askSample)
        let post = buffer.samples(from: record.askSample, to: end)
        return (pre, post)
    }

    private func reaction(for record: QuestionRecord, until end: Int) -> ReactionScore? {
        let (pre, post) = window(for: record, until: end)
        return Signal.reaction(
            pre: pre, post: post, baseline: baseline, gsrInverted: profile.gsrInverted,
            sensors: enabledSensors, origin: record.askSample - pre[0].count
        )
    }

    private func features(for record: QuestionRecord, until end: Int) -> FeatureVector? {
        let (pre, post) = window(for: record, until: end)
        guard let base = Signal.features(
            pre: pre, post: post, baseline: baseline, gsrInverted: profile.gsrInverted,
            kind: record.question.kind, answerLatency: record.latency, stableAtAsk: record.stabilityAtAsk == .stable,
            sensors: enabledSensors
        ) else { return nil }
        let prior = records.filter { $0.id != record.id }.compactMap(\.features)
        return Signal.addingSessionRelative(base, prior: prior)
    }

    private func advanceSelection(after question: Question) {
        let bank = activeQuestions
        guard let i = bank.firstIndex(where: { $0.id == question.id }) else { return }
        if isCardTest {
            selectedQuestionID = i + 1 < bank.count ? bank[i + 1].id : nil
        } else {
            selectedQuestionID = bank[(i + 1) % bank.count].id
        }
    }

    /// How the simulator's fake subject reacts, and whether that counts as a lie (for pre-filled labels).
    private func simulatedReaction(to question: Question) -> (strength: Double, truth: GroundTruth?)? {
        guard source == .simulator else { return nil }
        if let number = question.cardNumber, let choice = simulatedCardChoice {
            return number == choice ? (Double.random(in: 0.65...1), .lie) : (Double.random(in: 0...0.35), .truth)
        }
        switch question.kind {
        case .irrelevant:
            return (Double.random(in: 0...0.1), .truth)
        case .control:
            return (Double.random(in: 0.4...0.65), .unknown)
        case .relevant:
            let lying = simulatedSubject == .lying || (simulatedSubject == .random && Bool.random())
            return lying ? (Double.random(in: 0.8...1), .lie) : (Double.random(in: 0.05...0.3), .truth)
        }
    }

    // MARK: - Sessions

    private func beginSession() {
        sessionID = UUID()
        sessionStartedAt = .now
        sessionSource = source == .simulator ? "simulator" : "serial"
        sessionSimulatedSubject = source == .simulator ? simulatedSubject : nil
        simulatedCardChoice = source == .simulator && isCardTest ? Int.random(in: 1...cardTestNumbers) : nil
        signalsNext = buffer.totalCount - Signal.samples(Self.sessionLeadInSeconds)
        signalIndices = []
        signalChannels = [[], [], []]
        lastSaveMessage = nil
    }

    /// Copies newly arrived samples into the session recording (the live buffer only keeps 5 minutes).
    private func captureSignals() {
        guard recordSessions, sessionStartedAt != nil else { return }
        let end = buffer.totalCount
        let (first, chunk) = buffer.range(from: signalsNext, to: end)
        signalsNext = end
        guard !chunk[0].isEmpty else { return }
        signalIndices += first..<(first + chunk[0].count)
        for channel in 0..<3 { signalChannels[channel] += chunk[channel] }
    }

    var completedRecords: [QuestionRecord] { records.filter { !$0.interrupted && $0.score != nil } }

    var labeledCount: Int { records.filter { !$0.interrupted && ($0.label == .truth || $0.label == .lie) }.count }

    /// "End Session": labels first for training sessions, then saves if recording is on.
    func endSession() {
        guard sessionInProgress else { return }
        interruptActiveQuestion()
        if recordSessions && trainingMode {
            for i in records.indices where records[i].label == nil {
                records[i].label = records[i].simulatedTruth ?? .unknown
            }
            if isCardTest, let choice = simulatedCardChoice { chosenCard = choice }
            showingSessionEnd = true
        } else if recordSessions {
            saveSession()
        } else {
            logExam(savedSession: nil)
            resetSession()
        }
    }

    func setLabel(_ label: GroundTruth, for id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].label = label
    }

    /// Card test: every answer is a lie exactly when it contradicts whether this was the picked number.
    private func applyCardLabels(chosen: Int) {
        for i in records.indices {
            guard let number = records[i].question.cardNumber, let answer = records[i].answer, answer != .none else {
                records[i].label = .unknown
                continue
            }
            records[i].label = (answer == .yes) == (number == chosen) ? .truth : .lie
        }
    }

    func saveSession() {
        captureSignals()
        guard let startedAt = sessionStartedAt else {
            resetSession()
            return
        }
        let export = SessionExport(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: .now,
            profile: profile,
            trainingProtocol: trainingMode ? trainingProtocol : nil,
            cardNumbers: isCardTest ? cardTestNumbers : nil,
            chosenCard: isCardTest ? chosenCard : nil,
            source: sessionSource,
            simulatedSubject: sessionSimulatedSubject?.rawValue,
            records: records,
            signalIndices: signalIndices,
            signals: signalChannels,
            modelSummary: useModel ? model?.summary : nil,
            sensors: enabledSensors
        )
        do {
            let folder = try SessionExporter.write(export, to: dataDirectory)
            let questions = records.filter { !$0.interrupted }.count
            lastSaveMessage = "Saved \(questions) question\(questions == 1 ? "" : "s")"
                + (trainingMode ? " (\(labeledCount) labeled)" : "") + " to \(folder.lastPathComponent)"
            savedSessionCount = DataLocation.sessionCount(in: dataDirectory)
            logExam(savedSession: folder.lastPathComponent)
            showingSessionEnd = false
            resetSession()
        } catch {
            errorMessage = "Couldn't save the session: \(error.localizedDescription)"
        }
    }

    func discardSession() {
        showingSessionEnd = false
        resetSession()
    }

    func resetSession() {
        interruptActiveQuestion()
        records.removeAll()
        sessionStartedAt = nil
        chosenCard = nil
        simulatedCardChoice = nil
        signalIndices = []
        signalChannels = [[], [], []]
        regenerateCardTest()
        selectFirstQuestion()
    }

    // MARK: - Trained model

    var modelURL: URL { dataDirectory.appending(path: "models/PolyMacModel.mlmodel") }

    var modelBeatsRules: Bool? {
        guard let modelAUC = model?.modelAUC, let ruleAUC = model?.ruleAUC else { return nil }
        return modelAUC > ruleAUC
    }

    func loadModel() {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            model = nil
            modelLoaded = false
            modelStatus = "No trained model yet. Run ml/train.sh after collecting labeled sessions."
            useModel = false
            return
        }
        do {
            let loaded = try DeceptionModel(url: modelURL)
            model = loaded
            modelLoaded = true
            modelStatus = loaded.summary
        } catch {
            model = nil
            modelLoaded = false
            useModel = false
            modelStatus = "Couldn't load the model: \(error.localizedDescription)"
        }
        for i in records.indices {
            records[i].mlProbability = records[i].features.flatMap { model?.probability($0) }
        }
        recomputeVerdicts()
    }

    // MARK: - Verdicts

    /// Mean reaction to control questions this session, the yardstick for relevant ones.
    var controlMean: Double? {
        let controls = records.filter { $0.question.kind == .control }.compactMap { $0.score?.index }
        return controls.isEmpty ? nil : Signal.mean(controls)
    }

    var modelActive: Bool { useModel && model != nil }

    private static func modelVerdict(probability: Double, sensitivity: Double) -> VerdictReading {
        let band = 0.2 - 0.12 * sensitivity
        let verdict: Verdict = probability > 0.5 + band ? .deceptive : probability < 0.5 - band ? .truthful : .inconclusive
        return VerdictReading(verdict: verdict, gauge: probability)
    }

    private func recomputeVerdicts() {
        let control = controlMean
        for i in records.indices {
            guard records[i].question.kind == .relevant, let score = records[i].score else {
                records[i].verdict = nil
                continue
            }
            if modelActive, let p = records[i].mlProbability {
                records[i].verdict = Self.modelVerdict(probability: p, sensitivity: profile.sensitivity).verdict
            } else {
                records[i].verdict = Signal.verdict(index: score.index, controlMean: control, sensitivity: profile.sensitivity).verdict
            }
        }
    }

    var overallVerdict: VerdictReading? {
        let relevant = records.filter { $0.question.kind == .relevant }
        if modelActive {
            let probabilities = relevant.compactMap(\.mlProbability)
            guard !probabilities.isEmpty else { return nil }
            return Self.modelVerdict(probability: Signal.mean(probabilities), sensitivity: profile.sensitivity)
        }
        let indices = relevant.compactMap { $0.score?.index }
        guard !indices.isEmpty else { return nil }
        return Signal.verdict(index: Signal.mean(indices), controlMean: controlMean, sensitivity: profile.sensitivity)
    }

    /// What the gauge shows: the live reading while a relevant question is in progress, else the session verdict.
    var displayedVerdict: (reading: VerdictReading?, isLive: Bool) {
        if let record = activeRecord, record.question.kind == .relevant {
            if modelActive, let p = liveProbability {
                return (Self.modelVerdict(probability: p, sensitivity: profile.sensitivity), true)
            }
            if !modelActive, let live = liveReaction {
                return (Signal.verdict(index: live.index, controlMean: controlMean, sensitivity: profile.sensitivity), true)
            }
        }
        return (overallVerdict, false)
    }

    // MARK: - Chart annotations

    var chartMarkers: [ChartMarker] {
        experimentChartMarkers + records.filter { !$0.interrupted }.flatMap { record -> [ChartMarker] in
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
        if experimentRecording {
            for (index, phase) in experimentPhases.enumerated() {
                regions.append(ChartRegion(id: "phase-\(phase.id)", start: experimentStart + phase.start, end: experimentStart + phase.end, color: PhasePalette.color(index)))
            }
        }
        return regions
    }

    /// The parts of each question's signal that produced its reaction score, coloured by the
    /// question's verdict (relevant), orange (control, the yardstick) or grey (irrelevant).
    var chartHighlights: [ChartHighlight] {
        records.filter { !$0.interrupted }.flatMap { record -> [ChartHighlight] in
            let score = record.score ?? (record.id == activeRecord?.id ? liveReaction : nil)
            guard let score, let evidence = score.evidence else { return [] }
            let color: Color = record.question.kind == .relevant
                ? (record.verdict ?? displayedVerdict.reading?.verdict).map(\.color) ?? .purple
                : record.question.kind.color
            let points = score.points(enabledSensors)
            let total = max(score.index, 1)
            var highlights: [ChartHighlight] = []
            func share(_ p: Double) -> String { "\(Int(p.rounded())) of \(Int(score.index.rounded())) pts" }

            if enabledSensors.contains(.gsr), points.gsr >= 0.5 {
                highlights.append(ChartHighlight(
                    id: "\(record.id)-gsr", channel: .gsr, start: evidence.gsrRiseStart, end: evidence.gsrPeak,
                    color: color, strength: points.gsr / total,
                    label: "Q\(record.number) skin \(Self.signed(score.gsrDelta, unit: nil)) · \(share(points.gsr))",
                    rise: .init(referenceStart: evidence.gsrReferenceStart, from: evidence.gsrReferenceRaw, to: evidence.gsrPeakRaw)
                ))
            }
            if enabledSensors.contains(.pulse), points.heart >= 0.5 {
                for (i, beat) in evidence.fastBeats.enumerated() {
                    highlights.append(ChartHighlight(
                        id: "\(record.id)-beat\(i)", channel: .pulse, start: beat.start, end: beat.end,
                        color: color, strength: points.heart / total,
                        label: i == evidence.fastBeats.count - 1
                            ? "Q\(record.number) heart \(Self.signed(score.heartRateDelta, unit: "bpm")) · \(share(points.heart))"
                            : "fast beat"
                    ))
                }
            }
            if enabledSensors.contains(.resp), points.breathing >= 0.5, let span = evidence.breathing {
                highlights.append(ChartHighlight(
                    id: "\(record.id)-resp", channel: .resp, start: span.start, end: span.end,
                    color: color, strength: points.breathing / total,
                    label: "Q\(record.number) breathing \(Int((score.breathingSuppression * 100).rounded()))% shallower · \(share(points.breathing))"
                ))
            }
            return highlights
        }
    }

    var experimentChartMarkers: [ChartMarker] {
        guard experimentRecording else { return [] }
        var markers = experimentPhases.map { phase in
            ChartMarker(id: "phase-\(phase.id)", sample: experimentStart + phase.start, label: phase.name, color: .secondary)
        }
        markers += experimentMarkers.map { marker in
            ChartMarker(id: "\(marker.id)", sample: experimentStart + marker.sample, label: marker.label, color: .pink)
        }
        return markers
    }
}
