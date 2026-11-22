import SwiftUI

/// Saved question lists, grouped by who they were for, newest first.
struct SavedQuestionsWindow: View {
    @Bindable var model: AppModel
    @State private var selection: UUID?

    /// Subjects in order of their most recent list, under their current name if they were renamed.
    private var groups: [(name: String, sets: [SavedQuestionSet])] {
        var order: [String] = []
        var bySubject: [String: [SavedQuestionSet]] = [:]
        for set in model.savedQuestionSets {
            let name = model.currentName(for: set)
            if bySubject[name] == nil { order.append(name) }
            bySubject[name, default: []].append(set)
        }
        return order.map { ($0, bySubject[$0] ?? []) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.sets) { set in
                            SavedSetRow(set: set).tag(set.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .toolbar {
                ToolbarItem {
                    Button("Show in Finder", systemImage: "folder") {
                        model.revealQuestionSet(model.savedQuestionSets.first { $0.id == selection })
                    }
                }
            }
        } detail: {
            if let set = model.savedQuestionSets.first(where: { $0.id == selection }) {
                SavedSetDetail(model: model, set: set)
            } else if model.savedQuestionSets.isEmpty {
                ContentUnavailableView(
                    "No saved questions",
                    systemImage: "tray",
                    description: Text("Use Save or Save & Clear in the question list's ⋯ menu. Each save becomes a file here, with who the questions were for and the date.")
                )
            } else {
                ContentUnavailableView("Pick a saved list", systemImage: "list.bullet.rectangle")
            }
        }
        .onAppear {
            model.refreshQuestionSets()
            selection = selection ?? model.savedQuestionSets.first?.id
        }
    }
}

private struct SavedSetRow: View {
    let set: SavedQuestionSet

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(set.date.formatted(date: .abbreviated, time: .shortened))
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let count = "\(set.questions.count) question\(set.questions.count == 1 ? "" : "s")"
        return set.askedCount > 0 ? "\(count), \(set.askedCount) asked" : "\(count), not asked"
    }
}

private struct SavedSetDetail: View {
    @Bindable var model: AppModel
    let set: SavedQuestionSet
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("#")
                        Text("Question")
                        Text("Type")
                        Text("Answer")
                        Text("Reaction")
                        Text("Verdict")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(set.questions.enumerated()), id: \.element.id) { index, entry in
                        QuestionGridRow(index: index + 1, entry: entry)
                    }
                }
                actions
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Move this saved list to the Trash?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) { model.deleteQuestionSet(set) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Asked to \(model.currentName(for: set))")
                .font(.title2.weight(.semibold))
            Text(set.date.formatted(date: .complete, time: .shortened))
                .foregroundStyle(.secondary)
            if let session = set.session {
                HStack(spacing: 6) {
                    Text("Answers from the exam started \(session.startedAt.formatted(date: .omitted, time: .shortened))")
                    if let verdict = session.verdict {
                        Text("· Overall")
                        Text(verdict.title).foregroundStyle(verdict.color).fontWeight(.medium)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                Text("Saved before any of these were asked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack {
            Group {
                Button("Load into Question List") { model.loadQuestionSet(set, replace: true) }
                    .help("Replaces the current question list with these questions")
                Button("Add to Question List") { model.loadQuestionSet(set, replace: false) }
            }
            .disabled(model.questionListLocked)
            Spacer()
            Button("Show in Finder") { model.revealQuestionSet(set) }
            Button("Delete…", role: .destructive) { confirmingDelete = true }
        }
        .controlSize(.regular)
        .padding(.top, 4)
    }
}

private struct QuestionGridRow: View {
    let index: Int
    let entry: SavedQuestionSet.Entry

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text("\(index)").foregroundStyle(.secondary).monospacedDigit()
            Text(entry.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 4) {
                Circle().fill(entry.kind.color).frame(width: 7, height: 7)
                Text(entry.kind.title)
            }
            .font(.caption)
            if entry.asked.isEmpty {
                Text("Not asked").foregroundStyle(.tertiary)
                Text("")
                Text("")
            } else {
                Text(entry.asked.map { $0.answer?.title ?? "—" }.joined(separator: ", "))
                Text(entry.asked.map { $0.reactionIndex.map { "\(Int($0.rounded()))" } ?? "—" }.joined(separator: ", "))
                    .monospacedDigit()
                entry.asked.enumerated().reduce(Text("")) { text, item in
                    let verdict = item.element.verdict.map { Text($0.title).foregroundStyle($0.color) } ?? Text("—").foregroundStyle(.tertiary)
                    return item.offset == 0 ? verdict : text + Text(", ").foregroundStyle(.secondary) + verdict
                }
            }
        }
        .font(.callout)
    }
}
