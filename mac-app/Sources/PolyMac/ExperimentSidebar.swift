import SwiftUI

/// Live experiment controls: choose a template, record, step through phases, drop markers.
struct ExperimentSection: View {
    @Bindable var model: AppModel
    @State private var customPhase = ""

    var body: some View {
        SectionCard("Experiment") {
            if model.experimentRecording {
                recordingControls
            } else {
                setup
            }
        } accessory: {
            if model.experimentRecording {
                Label(formatClock(model.experimentElapsed), systemImage: "record.circle.fill")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.red)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Template", selection: $model.experimentTemplateID) {
                ForEach(ExperimentTemplate.all) { Text($0.title).tag($0.id) }
            }
            let template = model.experimentTemplate
            Text(template.instructions)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !template.phases.isEmpty {
                Text(template.phases.map { "\($0.name) \(formatClock(Double($0.seconds)))" }.joined(separator: " → ")
                     + "  (\(formatClock(Double(template.totalSeconds))) total)")
                    .font(.caption.monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Title (optional)", text: $model.experimentTitle)
                .textFieldStyle(.roundedBorder)
            Button {
                model.startExperiment()
            } label: {
                Label("Start Recording", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.experimentBlockedReason != nil)
            Text(model.experimentBlockedReason ?? "Recording is saved to the data folder when you stop. Wait for Stable first for cleaner data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let phase = model.currentExperimentPhase {
                HStack {
                    Text(phase.name).font(.title3.weight(.semibold))
                    Spacer()
                    if let left = model.phaseSecondsLeft {
                        Text("\(formatClock(left)) left")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if model.phaseSecondsLeft != nil {
                    ProgressView(value: model.phaseProgress)
                }
            } else {
                Text("No phase. Start one below to compare conditions later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.experimentTemplate.phases.isEmpty {
                HStack {
                    ForEach(["Rest", "Task", "Recovery"], id: \.self) { name in
                        Button(name) { model.beginPhase(named: name) }
                    }
                }
                .controlSize(.small)
                HStack {
                    TextField("Custom phase name", text: $customPhase)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(startCustom)
                    Button("Start", action: startCustom)
                        .disabled(customPhase.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            } else {
                let isLast = model.experimentPhases.count >= model.experimentTemplate.phases.count
                Button(isLast ? "Finish Now" : "Skip to Next Phase") { model.nextPhase() }
                    .controlSize(.small)
            }

            Divider()

            HStack {
                TextField("Marker label (optional)", text: $model.markerDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addMarker() }
                Button("Add Marker") { model.addMarker() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Text("⌘↩ drops a marker at this moment. You can add more after recording, too.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !model.experimentMarkers.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.experimentMarkers.suffix(5).reversed()) { marker in
                        HStack {
                            Text(formatClock(Double(marker.sample) / Signal.sampleRate))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(marker.label).font(.caption)
                        }
                    }
                    if model.experimentMarkers.count > 5 {
                        Text("+\(model.experimentMarkers.count - 5) more").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Button {
                model.finishExperiment()
            } label: {
                Label("Stop & Review", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        }
    }

    private func startCustom() {
        model.beginPhase(named: customPhase)
        customPhase = ""
    }
}

struct SavedExperimentsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        SectionCard("Saved Experiments") {
            if model.savedExperiments.isEmpty {
                Text("Nothing recorded yet. Finished recordings appear here and can be reopened to review, annotate and interpret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.savedExperiments.prefix(12)) { saved in
                        Button {
                            model.openSavedExperiment(saved)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(saved.title).font(.callout).lineLimit(1)
                                    Text(saved.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(formatClock(saved.duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.experimentRecording)
                    }
                }
            }
        } accessory: {
            Button("Refresh") { model.refreshSavedExperiments() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
