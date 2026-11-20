import SwiftUI

struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SubjectSection(model: model)
                StabilitySection(model: model)
                SectionCard("Question") {
                    CurrentQuestion(model: model)
                }
                VerdictSection(model: model)
                QuestionListSection(model: model)
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    var body: some View {
        SectionCard("Subject") {
            HStack {
                Picker("Subject", selection: $model.selectedProfileID) {
                    ForEach(model.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .disabled(model.phase != .idle || model.isCalibrating)

                Menu {
                    Button("New Subject", systemImage: "person.badge.plus") { model.addProfile() }
                    Button("Delete \(model.profile.name)", systemImage: "trash", role: .destructive) {
                        model.deleteSelectedProfile()
                    }
                    .disabled(model.profiles.count < 2)
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
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                .font(.callout)
                Text("Baseline \(Int(baseline.heartRate)) bpm · \(String(format: "%.1f", baseline.breathingRate)) breaths/min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Not calibrated: judged against generic defaults", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Calibrate…", systemImage: "tuningfork") { model.showingCalibration = true }
                    .disabled(model.phase != .idle)
                Button("Subject Window", systemImage: "rectangle.on.rectangle") { openWindow(id: "subject") }
                    .help("A second window that shows the subject each question with Yes/No buttons. Drag it to another display.")
            }
            .controlSize(.small)
        }
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

private struct QuestionListSection: View {
    @Bindable var model: AppModel

    var body: some View {
        SectionCard("Question List") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.questions) { question in
                    QuestionRow(
                        question: question,
                        isSelected: question.id == model.selectedQuestionID,
                        timesAsked: model.timesAsked(question)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedQuestionID = question.id }
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) { model.deleteQuestion(question.id) }
                    }
                }
            }
            AddQuestionRow(model: model)
        } accessory: {
            if !model.records.isEmpty {
                Button("New Session") { model.resetSession() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
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
                    ReactionMeter(score: model.liveReaction)
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
                    ReactionMeter(score: model.liveReaction)
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
                Text("GSR \(score.map { AppModel.signed($0.gsrDelta, unit: nil) } ?? "—")")
                Spacer()
                Text("HR \(score.map { AppModel.signed($0.heartRateDelta, unit: "bpm") } ?? "—")")
                Spacer()
                Text("Breath \(score.map { "−\(Int($0.breathingSuppression * 100))%" } ?? "—")")
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
        return "\(record.question.text)\nReaction \(Int(score.index)): GSR \(AppModel.signed(score.gsrDelta, unit: nil)), heart \(AppModel.signed(score.heartRateDelta, unit: "bpm")), breathing −\(Int(score.breathingSuppression * 100))%"
    }
}
