import SwiftUI

struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SubjectSection(model: model)
                StabilitySection(model: model)
                if model.appMode == .experiment {
                    ExperimentSection(model: model)
                    SavedExperimentsSection(model: model)
                } else {
                    examSections
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var examSections: some View {
                SectionCard("Question") {
                    CurrentQuestion(model: model)
                } accessory: {
                    SessionControls(model: model)
                }
                VerdictSection(model: model)
                QuestionListSection(model: model)
                TrainingSection(model: model)
    }
}

// MARK: - Building blocks

struct SectionCard<Content: View, Accessory: View>: View {
    let title: String
    let content: Content
    let accessory: Accessory

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

extension SectionCard where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, accessory: { EmptyView() })
    }
}

struct KindBadge: View {
    let kind: QuestionKind

    var body: some View {
        Text(kind.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(kind.color.opacity(0.18)))
            .foregroundStyle(kind.color)
            .help(kind.explanation)
    }
}

extension StabilityReport.Level {
    var title: String {
        switch self {
        case .stable: "Stable"
        case .settling: "Settling"
        case .unstable: "Unstable"
        }
    }

    var color: Color {
        switch self {
        case .stable: .green
        case .settling: .yellow
        case .unstable: .red
        }
    }

    var symbol: String {
        switch self {
        case .stable: "checkmark.circle.fill"
        case .settling: "clock.fill"
        case .unstable: "xmark.octagon.fill"
        }
    }
}

// MARK: - Subject

private struct SubjectSection: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showingNamePrompt = false
    @State private var namingNewSubject = true
    @State private var draftName = ""
    @State private var confirmingDelete = false

    var body: some View {
        SectionCard("Subject") {
            HStack {
                Picker("Subject", selection: $model.selectedProfileID) {
                    ForEach(model.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .disabled(model.subjectLocked)
                .help(model.subjectLocked ? "Finish the current session to switch subjects" : "Who is being tested")

                Menu {
                    Button("New Subject…", systemImage: "person.badge.plus") { promptForName(new: true) }
                        .disabled(model.subjectLocked)
                    Button("Rename \(model.profile.name)…", systemImage: "pencil") { promptForName(new: false) }
                    Button("Subject Database…", systemImage: "person.2") { openWindow(id: "subjects") }
                    Divider()
                    Button("Delete \(model.profile.name)…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        .disabled(model.profiles.count < 2 || model.subjectLocked)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let baseline = model.profile.baseline {
                Label {
                    Text("Calibrated \(Text(baseline.recordedAt, style: .relative)) ago")
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(model.calibrationAgeWarning == nil ? .green : .yellow)
                }
                .font(.callout)
                Text(baselineSummary(baseline))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let warning = model.calibrationAgeWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
            } else {
                Label("Not calibrated: judged against generic defaults", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if let summary = historySummary {
                Button {
                    openWindow(id: "subjects")
                } label: {
                    Label(summary, systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Open \(model.profile.name)'s exams, verdicts and calibrations")
            }

            HStack {
                Button("Calibrate…", systemImage: "tuningfork") { model.showingCalibration = true }
                    .disabled(model.phase != .idle)
                Button("Subject Window", systemImage: "rectangle.on.rectangle") { openWindow(id: "subject") }
                    .help("A second window that shows the subject each question with Yes/No buttons. Drag it to another display.")
            }
            .controlSize(.small)
        }
        .alert(namingNewSubject ? "New Subject" : "Rename Subject", isPresented: $showingNamePrompt) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button(namingNewSubject ? "Add" : "Rename") {
                if namingNewSubject {
                    model.addProfile(named: draftName)
                } else {
                    model.renameProfile(model.selectedProfileID, to: draftName)
                }
            }
        } message: {
            Text(namingNewSubject ? "Their calibrations, exams and verdicts are kept under this name." : "Their history stays with them.")
        }
        .confirmationDialog("Delete \(model.profile.name)?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) { model.deleteProfile(model.selectedProfileID) }
        } message: {
            Text("Their profile, calibrations and exam history move to the Trash, where you can restore them. Saved training sessions stay in the data folder.")
        }
    }

    private func promptForName(new: Bool) {
        namingNewSubject = new
        draftName = new ? "" : model.profile.name
        showingNamePrompt = true
    }

    private func baselineSummary(_ baseline: Baseline) -> String {
        let measured = baseline.sensors ?? Channel.all
        var parts: [String] = []
        if model.enabledSensors.contains(.pulse), measured.contains(.pulse) {
            parts.append("\(Int(baseline.heartRate)) bpm")
            if let hrv = baseline.hrvRmssd { parts.append("HRV \(Int(hrv.rounded())) ms") }
        }
        if model.enabledSensors.contains(.resp), measured.contains(.resp) {
            parts.append(String(format: "%.1f breaths/min", baseline.breathingRate))
        }
        if model.enabledSensors.contains(.gsr), measured.contains(.gsr), let gsr = baseline.gsrRaw {
            parts.append("GSR \(Int(gsr.rounded()))")
        }
        return "Baseline " + (parts.isEmpty ? "recorded" : parts.joined(separator: " · "))
    }

    private var historySummary: String? {
        let exams = model.history.exams
        guard let last = exams.last else { return nil }
        let date = last.startedAt.formatted(date: .abbreviated, time: .omitted)
        let verdict = last.verdict.map { $0.title } ?? "no verdict"
        return "\(exams.count) exam\(exams.count == 1 ? "" : "s") on record · last \(date): \(verdict)"
    }
}

// MARK: - Stability

private struct StabilitySection: View {
    @Bindable var model: AppModel
    @State private var showAll = false

    var body: some View {
        SectionCard("Stability") {
            let level = model.stability.level
            let problems = model.stability.checks.filter { $0.level != .stable }
            HStack {
                Label(level.title, systemImage: level.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(level.color)
                Spacer()
                if level == .stable {
                    Text("for \(Int(model.stableSeconds)) s")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Only what needs attention, so the verdict stays on screen; everything on request.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(showAll ? model.stability.checks : problems) { check in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: check.level.symbol)
                            .foregroundStyle(check.level.color)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.name).font(.callout.weight(.medium))
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Toggle("Only ask while stable", isOn: $model.requireStability)
                    .toggleStyle(.checkbox)
                Spacer()
                Button(showAll ? "Hide checks" : "All \(model.stability.checks.count) checks") { showAll.toggle() }
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
    }
}

// MARK: - Questions

private struct SessionControls: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isRecordingSession {
                Label("REC", systemImage: "record.circle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
                    .help("This session is being recorded. It's saved to the data folder when you end it.")
            }
            if model.sessionInProgress {
                Button(model.recordSessions ? (model.trainingMode ? "End & Label" : "End & Save") : "New Session") {
                    model.endSession()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}

private struct QuestionListSection: View {
    @Bindable var model: AppModel

    var body: some View {
        SectionCard(model.isCardTest ? "Card Test" : "Question List") {
            if model.isCardTest {
                Text(TrainingProtocol.cardTest.instructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.activeQuestions) { question in
                    QuestionRow(
                        question: question,
                        isSelected: question.id == model.selectedQuestionID,
                        timesAsked: model.timesAsked(question)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedQuestionID = question.id }
                    .contextMenu {
                        if !model.isCardTest {
                            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteQuestion(question.id) }
                        }
                    }
                }
            }
            if !model.isCardTest {
                AddQuestionRow(model: model)
            }
        } accessory: {
            if model.isCardTest && !model.sessionInProgress {
                Button("Reshuffle") { model.regenerateCardTest() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Recording & training

private struct TrainingSection: View {
    @Bindable var model: AppModel

    var body: some View {
        SectionCard("Recording & Training") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Record sessions", isOn: $model.recordSessions)
                Text("Saves each session's questions, results, measurements and raw signals to the data folder when you end it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Training session (labeled data)", isOn: $model.trainingMode)
                    .disabled(model.sessionInProgress || !model.recordSessions)
                Text("Structured sessions where the truth is known, so they can train the model. You confirm what was true before saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.trainingMode && model.recordSessions {
                    Picker("Protocol", selection: $model.trainingProtocol) {
                        ForEach(TrainingProtocol.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(model.sessionInProgress)
                    if model.trainingProtocol == .cardTest {
                        Stepper("Numbers 1–\(model.cardTestNumbers), asked \(AppModel.cardTestRounds)× each", value: $model.cardTestNumbers, in: 3...9)
                            .font(.caption)
                            .disabled(model.sessionInProgress)
                    } else {
                        Text(TrainingProtocol.labelAfter.instructions)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Data folder").font(.callout.weight(.medium))
                    Spacer()
                    Text("\(model.savedSessionCount) session\(model.savedSessionCount == 1 ? "" : "s") saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(model.dataDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack {
                    Button("Show in Finder") { revealDataFolder() }
                    Button("Change…") { chooseDataFolder() }
                }
                .controlSize(.small)
                if let message = model.lastSaveMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Trained model").font(.callout.weight(.medium))
                    Spacer()
                    Button("Reload") { model.loadModel() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Text(model.modelStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let beats = model.modelBeatsRules {
                    Label(
                        beats ? "Beats the rule-based score on held-out subjects" : "Doesn't beat the rule-based score yet. Collect more data.",
                        systemImage: beats ? "arrow.up.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(beats ? .green : .orange)
                }
                Toggle("Use trained model for verdicts", isOn: $model.useModel)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!model.modelLoaded)
            }
        }
    }

    private func revealDataFolder() {
        try? FileManager.default.createDirectory(at: model.dataDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(model.dataDirectory)
    }

    private func chooseDataFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = model.dataDirectory
        if panel.runModal() == .OK, let url = panel.url {
            model.dataDirectory = url
        }
    }
}

private struct CurrentQuestion: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                if let question = model.selectedQuestion {
                    KindBadge(kind: question.kind)
                    Text(question.text).font(.title3.weight(.semibold))
                } else {
                    Text("No question selected").foregroundStyle(.secondary)
                }
                Button {
                    model.ask()
                } label: {
                    Label("Ask Question", systemImage: "questionmark.bubble.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canAsk)
                .keyboardShortcut(.return, modifiers: .command)
                if let reason = model.askBlockedReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Read the question aloud, then press Ask (⌘↩).").font(.caption).foregroundStyle(.secondary)
                }
                if model.source == .simulator {
                    Picker("Simulated subject", selection: $model.simulatedSubject) {
                        ForEach(SimulatedSubject.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .font(.caption)
                    .help("How the fake subject reacts to relevant questions")
                }
            }

        case .awaitingAnswer:
            if let record = model.activeRecord {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Q\(record.number)").font(.headline)
                        KindBadge(kind: record.question.kind)
                        Spacer()
                        Text(String(format: "%.1f s", model.secondsSinceAsk))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(record.question.text).font(.title3.weight(.semibold))
                    Text("Waiting for the answer…").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button { model.answer(.yes) } label: { Text("Yes").frame(maxWidth: .infinity) }
                            .tint(.green)
                            .keyboardShortcut("y", modifiers: [])
                        Button { model.answer(.no) } label: { Text("No").frame(maxWidth: .infinity) }
                            .tint(.red)
                            .keyboardShortcut("n", modifiers: [])
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    HStack {
                        Button("No Answer") { model.answer(.none) }
                        Spacer()
                        Button("Cancel", role: .destructive) { model.cancelQuestion() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    ReactionMeter(score: model.liveReaction, sensors: model.enabledSensors)
                }
            }

        case .responseWindow:
            if let record = model.activeRecord {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Q\(record.number)").font(.headline)
                        KindBadge(kind: record.question.kind)
                        Spacer()
                        Text("\(record.answer?.title ?? "—") after \(String(format: "%.1f", record.latency ?? 0)) s")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(record.question.text).font(.callout).foregroundStyle(.secondary)
                    ProgressView(value: model.responseProgress) {
                        Text("Recording reaction… \(model.responseSecondsLeft) s").font(.caption)
                    }
                    ReactionMeter(score: model.liveReaction, sensors: model.enabledSensors)
                    Button("Cancel", role: .destructive) { model.cancelQuestion() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }
}

private struct QuestionRow: View {
    let question: Question
    let isSelected: Bool
    let timesAsked: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(question.kind.color).frame(width: 7, height: 7)
            Text(question.text)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 4)
            if timesAsked > 0 {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Asked \(timesAsked)× this session")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.15) : .clear))
        .help("\(question.kind.title): \(question.kind.explanation)")
    }
}

private struct AddQuestionRow: View {
    @Bindable var model: AppModel
    @State private var text = ""
    @State private var kind = QuestionKind.relevant

    var body: some View {
        HStack(spacing: 6) {
            Picker("Type", selection: $kind) {
                ForEach(QuestionKind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)
            TextField("New question…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button(action: add) { Image(systemName: "plus") }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
    }

    private func add() {
        model.addQuestion(text, kind: kind)
        text = ""
    }
}

struct ReactionMeter: View {
    let score: ReactionScore?
    var sensors: Set<Channel> = Channel.all

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Live reaction").font(.caption.weight(.medium))
                Spacer()
                Text(score.map { "\(Int($0.index))" } ?? "—")
                    .font(.callout.weight(.bold).monospacedDigit())
            }
            ProgressView(value: (score?.index ?? 0) / 100)
                .tint(color)
            HStack {
                if sensors.contains(.gsr) {
                    Text("GSR \(score.map { AppModel.signed($0.gsrDelta, unit: nil) } ?? "—")")
                    Spacer()
                }
                if sensors.contains(.pulse) {
                    Text("HR \(score.map { AppModel.signed($0.heartRateDelta, unit: "bpm") } ?? "—")")
                    Spacer()
                }
                if sensors.contains(.resp) {
                    Text("Breath \(score.map { "−\(Int($0.breathingSuppression * 100))%" } ?? "—")")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        guard let index = score?.index else { return .gray }
        return index < 35 ? .green : index < 60 ? .yellow : .red
    }
}

// MARK: - Verdict

private struct VerdictSection: View {
    @Bindable var model: AppModel

    var body: some View {
        SectionCard("Verdict") {
            let displayed = model.displayedVerdict
            VerdictGauge(reading: displayed.reading, isLive: displayed.isLive)
                .frame(height: 170)

            Text(explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.records.isEmpty {
                Divider()
                VStack(spacing: 4) {
                    ForEach(model.records.reversed()) { record in
                        ResultRow(record: record)
                    }
                }
            }
        }
    }

    private var explanation: String {
        if model.useModel && model.modelLoaded {
            return "Verdicts come from your trained model (\(model.modelStatus)). It can only be as good as the labeled sessions it learned from. It measures arousal, not honesty."
        }
        let basis = model.controlMean == nil
            ? "Relevant answers are compared with this subject's baseline. Ask a control question for a fairer comparison."
            : "Relevant answers are compared with this subject's reactions to control questions."
        return basis + " This measures arousal, not honesty: it's a party game, not a lie detector."
    }
}

private struct ResultRow: View {
    let record: QuestionRecord

    var body: some View {
        HStack(spacing: 6) {
            Text("Q\(record.number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 26, alignment: .leading)
            Circle().fill(record.question.kind.color).frame(width: 6, height: 6)
            Text(record.question.text)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if record.stabilityAtAsk != .stable && !record.interrupted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("Asked while the subject was \(record.stabilityAtAsk.title.lowercased()). Take this reading with a grain of salt.")
            }
            Text(record.answer?.shortTitle ?? "…")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            trailing
        }
        .help(detail)
    }

    @ViewBuilder private var trailing: some View {
        if record.interrupted {
            Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
        } else if let score = record.score {
            Text("\(Int(score.index))")
                .font(.caption.monospacedDigit())
                .frame(width: 24, alignment: .trailing)
            if let verdict = record.verdict {
                Text(verdict.shortTitle)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(verdict.color.opacity(0.2)))
                    .foregroundStyle(verdict.color)
                    .frame(width: 66, alignment: .trailing)
            } else {
                Text(record.question.kind.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 66, alignment: .trailing)
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    private var detail: String {
        guard let score = record.score else { return record.question.text }
        var text = "\(record.question.text)\nReaction \(Int(score.index)): GSR \(AppModel.signed(score.gsrDelta, unit: nil)), heart \(AppModel.signed(score.heartRateDelta, unit: "bpm")), breathing −\(Int(score.breathingSuppression * 100))%"
        if let p = record.mlProbability { text += "\nTrained model: \(Int((p * 100).rounded()))% likely a lie" }
        return text
    }
}
