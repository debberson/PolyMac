import AppKit
import SwiftUI

/// The subject database: everyone tested, their usual resting values, calibrations and exam history.
struct SubjectsWindow: View {
    @Bindable var model: AppModel
    @State private var selection: UUID?
    @State private var showingNewSubject = false
    @State private var newName = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.profiles) { profile in
                    SubjectRow(profile: profile, history: model.history(for: profile.id), isCurrent: profile.id == model.selectedProfileID)
                        .tag(profile.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItem {
                    Button("New Subject", systemImage: "person.badge.plus") {
                        newName = ""
                        showingNewSubject = true
                    }
                    .disabled(model.subjectLocked)
                }
            }
        } detail: {
            if let id = selection, let profile = model.profiles.first(where: { $0.id == id }) {
                SubjectDetail(model: model, profile: profile)
                    .id(id)
            } else {
                ContentUnavailableView("Pick a subject", systemImage: "person.2", description: Text("Their calibrations, exams and verdicts appear here."))
            }
        }
        .onAppear { selection = selection ?? model.selectedProfileID }
        .alert("New Subject", isPresented: $showingNewSubject) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Add") { selection = model.addProfile(named: newName).id }
        } message: {
            Text("They become the current subject.")
        }
    }
}

private struct SubjectRow: View {
    let profile: SubjectProfile
    let history: SubjectHistory
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(profile.name).fontWeight(isCurrent ? .semibold : .regular)
                if isCurrent {
                    Image(systemName: "record.circle").font(.caption2).foregroundStyle(.secondary).help("Current subject")
                }
            }
            Text("\(history.exams.count) exam\(history.exams.count == 1 ? "" : "s") · \(history.calibrations.count) calibration\(history.calibrations.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct SubjectDetail: View {
    @Bindable var model: AppModel
    let profile: SubjectProfile
    @State private var draftName = ""
    @State private var draftNotes = ""
    @State private var confirmingDelete = false

    private var history: SubjectHistory { model.history(for: profile.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                notes
                usual
                exams
                calibrations
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            draftName = profile.name
            draftNotes = profile.notes
        }
        .onDisappear(perform: commitEdits)
        .confirmationDialog("Delete \(profile.name)?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) { model.deleteProfile(profile.id) }
        } message: {
            Text("Their profile, calibrations and exam history move to the Trash, where you can restore them. Saved training sessions stay in the data folder.")
        }
    }

    private func commitEdits() {
        model.renameProfile(profile.id, to: draftName)
        model.updateNotes(profile.id, draftNotes)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.title.weight(.bold))
                    .onSubmit(commitEdits)
                Text("Added \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if profile.id != model.selectedProfileID {
                Button("Make Current") { model.selectedProfileID = profile.id }
                    .disabled(model.subjectLocked)
            }
            Menu {
                Button("Show in Finder", systemImage: "folder") {
                    let folder = SubjectStore.folder(for: profile.id, in: model.dataDirectory)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                Divider()
                Button("Delete \(profile.name)…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    .disabled(model.profiles.count < 2 || (profile.id == model.selectedProfileID && model.subjectLocked))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.headline)
            TextEditor(text: $draftNotes)
                .font(.callout)
                .frame(minHeight: 54, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: draftNotes) { _, notes in model.updateNotes(profile.id, notes) }
        }
    }

    @ViewBuilder private var usual: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usual at rest").font(.headline)
            if let usual = history.usual {
                HStack(spacing: 24) {
                    stat("Heart rate", usual.heartRate.map { "\(Int($0.rounded())) bpm" })
                    stat("HRV (RMSSD)", usual.hrv.map { "\(Int($0.rounded())) ms" })
                    stat("Breathing", usual.breathingRate.map { String(format: "%.1f/min", $0) })
                    stat("GSR level", usual.gsrRaw.map { "\(Int($0.rounded()))" })
                    stat("GSR noise", usual.gsrNoise.map { String(format: "%.1f", $0) })
                }
                Text("Median of the last \(usual.calibrations) calibration\(usual.calibrations == 1 ? "" : "s"). Used for quick calibrations and to flag a day when they're far from normal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not calibrated yet. Each saved calibration adds to their usual values.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var exams: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exams").font(.headline)
            if history.exams.isEmpty {
                Text("No finished exams yet. Each session is added here when you end it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history.exams.reversed()) { exam in
                    ExamCard(exam: exam) { model.deleteExam(exam.id, for: profile.id) }
                }
            }
        }
    }

    @ViewBuilder private var calibrations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calibrations").font(.headline)
            if history.calibrations.isEmpty {
                Text("None saved.").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["Date", "Method", "Heart rate", "HRV", "Breathing", "GSR level", "Sensors"], id: \.self) {
                            Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(history.calibrations.reversed()) { entry in
                        let b = entry.baseline
                        let on = b.sensors ?? Channel.all
                        GridRow {
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            Text(entry.method.title)
                            Text(on.contains(.pulse) ? "\(Int(b.heartRate.rounded())) bpm" : "off")
                            Text(on.contains(.pulse) ? (b.hrvRmssd.map { "\(Int($0.rounded())) ms" } ?? "—") : "off")
                            Text(on.contains(.resp) ? String(format: "%.1f/min", b.breathingRate) : "off")
                            Text(on.contains(.gsr) ? (b.gsrRaw.map { "\(Int($0.rounded()))" } ?? "—") : "off")
                            Text(Channel.displayOrder.filter(on.contains).map(\.title).joined(separator: ", "))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.title3.monospacedDigit())
        }
    }
}

private struct ExamCard: View {
    let exam: ExamEntry
    let onDelete: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exam.startedAt.formatted(date: .abbreviated, time: .shortened)).fontWeight(.medium)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let verdict = exam.verdict {
                        Text(verdict.title)
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(verdict.color.opacity(0.18), in: Capsule())
                            .foregroundStyle(verdict.color)
                    } else {
                        Text("No verdict").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["#", "Question", "Type", "Answer", "Reaction", "Result"], id: \.self) {
                            Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(exam.questions) { q in
                        GridRow {
                            Text("\(q.number)").foregroundStyle(.secondary)
                            Text(q.text).lineLimit(2)
                            Text(q.kind.title).foregroundStyle(q.kind.color)
                            Text(q.answer?.title ?? "—")
                            Text(q.reactionIndex.map { "\(Int($0.rounded()))" } ?? "—").monospacedDigit()
                                .help(detail(q))
                            result(q)
                        }
                        .font(.callout)
                    }
                }
                .padding(.leading, 22)
                HStack {
                    Text(footer).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete Exam", role: .destructive, action: onDelete)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.leading, 22)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var subtitle: String {
        var parts = ["\(exam.questions.count) question\(exam.questions.count == 1 ? "" : "s")", "\(exam.relevantCount) relevant"]
        if exam.trainingProtocol != nil { parts.append("training") }
        if exam.source == "simulator" { parts.append("simulated") }
        return parts.joined(separator: " · ")
    }

    private var footer: String {
        var parts = ["Verdict from \(exam.verdictSource == "model" ? "the trained model" : "the rule-based score")"]
        parts.append("sensors: " + Channel.displayOrder.filter(exam.sensors.contains).map(\.title).joined(separator: ", "))
        if let folder = exam.savedSession { parts.append("saved as sessions/\(folder)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func result(_ q: ExamQuestionEntry) -> some View {
        HStack(spacing: 6) {
            if let verdict = q.verdict {
                Text(verdict.shortTitle).foregroundStyle(verdict.color)
            } else {
                Text(q.kind == .relevant ? "—" : "reference").foregroundStyle(.secondary)
            }
            if let label = q.label, label == .truth || label == .lie {
                Text("(was \(label == .lie ? "a lie" : "true"))").foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ q: ExamQuestionEntry) -> String {
        var parts: [String] = []
        if let gsr = q.gsrDelta { parts.append("skin \(AppModel.signed(gsr, unit: nil))") }
        if let hr = q.heartRateDelta { parts.append("heart \(AppModel.signed(hr, unit: "bpm"))") }
        if let br = q.breathingSuppression { parts.append("breathing \(Int((br * 100).rounded()))% shallower") }
        if let p = q.mlProbability { parts.append("model \(Int((p * 100).rounded()))% lie") }
        return parts.joined(separator: ", ")
    }
}

extension CalibrationEntry.Method {
    var title: String {
        switch self {
        case .recorded: "Recorded"
        case .quick: "Quick"
        case .usual: "Usual values"
        }
    }
}
