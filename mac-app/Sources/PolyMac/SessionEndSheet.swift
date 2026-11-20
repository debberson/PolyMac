import SwiftUI

/// Shown when a training session ends: confirm what was really true for each answer, then save.
struct SessionEndSheet: View {
    @Bindable var model: AppModel
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Label This Session").font(.title2.weight(.bold))
                Text("Mark what was actually true. Only answers labeled Truth or Lie are used for training; leave anything you're unsure of as \"?\".")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isCardTest {
                HStack {
                    Text("Which number did the subject pick?").font(.headline)
                    Spacer()
                    Picker("Picked number", selection: $model.chosenCard) {
                        Text("Choose…").tag(Int?.none)
                        ForEach(1...model.cardTestNumbers, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                Text("Every answer is labeled from this automatically. You can still override individual rows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.records.filter { !$0.interrupted }) { record in
                        HStack(spacing: 8) {
                            Text("Q\(record.number)")
                                .font(.callout.weight(.bold).monospacedDigit())
                                .frame(width: 34, alignment: .leading)
                            Circle().fill(record.question.kind.color).frame(width: 7, height: 7)
                            Text(record.question.text).lineLimit(2)
                            Spacer()
                            Text(record.answer?.title ?? "—")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .trailing)
                            Picker("Label", selection: labelBinding(for: record)) {
                                ForEach(GroundTruth.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 150)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 360)

            if model.source == .simulator || model.records.contains(where: { $0.simulatedTruth != nil }) {
                Label("Simulated session: labels are pre-filled from the fake subject. Simulated sessions are excluded from training unless you pass --include-simulated.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Discard Session", role: .destructive) { confirmingDiscard = true }
                Spacer()
                Text("\(model.labeledCount) labeled")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Keep Asking") { model.showingSessionEnd = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save Session") { model.saveSession() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
        .confirmationDialog("Discard this session without saving?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { model.discardSession() }
        }
    }

    private func labelBinding(for record: QuestionRecord) -> Binding<GroundTruth> {
        Binding(
            get: { model.records.first { $0.id == record.id }?.label ?? .unknown },
            set: { model.setLabel($0, for: record.id) }
        )
    }
}
