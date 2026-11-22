import SwiftUI

struct CalibrationSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Calibrate Subject").font(.title2.weight(.bold))
                Text("Records a resting baseline so stats, stability and verdicts are judged against this person's normal instead of a generic one.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("Name", text: $model.profile.name)
                Toggle("Lower GSR reading means more sweat (Grove sensor)", isOn: $model.profile.gsrInverted)
                    .help("Grove GSR readings drop as skin conductance rises. Turn off if your sensor reads the other way.")
                Picker("Reaction window", selection: $model.profile.responseSeconds) {
                    ForEach([6.0, 8.0, 12.0], id: \.self) { Text("\(Int($0)) s after answer").tag($0) }
                }
                LabeledContent("Verdict sensitivity") {
                    VStack(spacing: 2) {
                        Slider(value: $model.profile.sensitivity, in: 0...1)
                        HStack {
                            Text("Cautious")
                            Spacer()
                            Text("Decisive")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                Picker("Baseline length", selection: $model.calibrationSeconds) {
                    ForEach(AppModel.calibrationChoices, id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(model.isCalibrating)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 250)

            if let usual = model.usualValues {
                UsualValuesRow(usual: usual, sensors: model.enabledSensors)
            }

            Divider()
            stateContent
            Divider()

            HStack {
                Spacer()
                Button("Done") { model.closeCalibration() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    @ViewBuilder private var stateContent: some View {
        switch model.calibration {
        case .idle:
            VStack(alignment: .leading, spacing: 10) {
                Text("Before you start").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                    }
                }
                .font(.callout)
                HStack {
                    Label(model.stability.level.title, systemImage: model.stability.level.symbol)
                        .foregroundStyle(model.stability.level.color)
                    Spacer()
                    if model.usualValues != nil {
                        Button("Use Usual Baseline") { model.useUsualBaseline() }
                            .help("Skip recording and use \(model.profile.name)'s usual resting values from earlier calibrations. Fastest, but GSR levels shift between sittings.")
                        Button("Quick (\(AppModel.quickCalibrationSeconds) s)", systemImage: "hare") { model.startQuickCalibration() }
                            .disabled(!model.isRunning)
                            .help("A short recording for today's levels, steadied with \(model.profile.name)'s earlier calibrations.")
                    }
                    Button("Start Recording", systemImage: "record.circle") { model.startCalibration() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.isRunning)
                }
                if !model.isRunning {
                    Text("Connect a board or start the simulator first.").font(.caption).foregroundStyle(.secondary)
                }
            }

        case .recording:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: model.calibrationProgress) {
                    Text("Recording baseline… \(model.calibrationSecondsLeft) s left").font(.headline)
                }
                Text("Sit still and breathe normally.").foregroundStyle(.secondary)
                HStack(spacing: 20) {
                    if model.enabledSensors.contains(.pulse) {
                        liveStat("Heart", model.stats.heartRate.map { "\(Int($0)) bpm" })
                    }
                    if model.enabledSensors.contains(.resp) {
                        liveStat("Breathing", model.stats.breathingRate.map { String(format: "%.1f/min", $0) })
                    }
                    if model.enabledSensors.contains(.gsr) {
                        liveStat("GSR", model.stats.gsrRaw.map { "\(Int($0))" })
                    }
                    liveStat("Stability", model.stability.level.title)
                }
                Button("Cancel", role: .destructive) { model.cancelCalibration() }
            }

        case .finished(let result):
            VStack(alignment: .leading, spacing: 10) {
                Text(result.method == .quick ? "Quick baseline recorded" : "Baseline recorded").font(.headline)
                ForEach(result.quality) { quality in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: symbol(quality.level)).foregroundStyle(color(quality.level))
                        Text(quality.channel.title).font(.callout.weight(.medium)).frame(width: 90, alignment: .leading)
                        Text(quality.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !result.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Compared with \(model.profile.name)'s usual").font(.callout.weight(.medium))
                        ForEach(result.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if result.quality.contains(where: { $0.level == .weak || $0.level == .missing }) {
                    Text("Fix the flagged sensors and record again for better results, or save anyway.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Record Again") { model.startCalibration() }
                    Spacer()
                    Button("Save Baseline for \(model.profile.name)") { model.saveCalibration() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Try Again") { model.startCalibration() }
                    .disabled(!model.isRunning)
            }
        }
    }

    private var steps: [String] {
        let on = model.enabledSensors
        var steps: [String] = []
        if on.contains(.pulse) { steps.append("Clip the pulse sensor on a fingertip or earlobe.") }
        if on.contains(.gsr) { steps.append("Put the GSR electrodes on two fingers of the other hand.") }
        if on.contains(.resp) { steps.append("Snug the stretch band around the chest.") }
        steps.append("Sit comfortably, rest your hands, breathe normally and don't talk.")
        return steps
    }

    private func liveStat(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.title3.monospacedDigit())
        }
    }

    private func symbol(_ level: ChannelQuality.Level) -> String {
        switch level {
        case .good: "checkmark.circle.fill"
        case .weak: "exclamationmark.circle.fill"
        case .missing: "xmark.circle.fill"
        case .off: "minus.circle"
        }
    }

    private func color(_ level: ChannelQuality.Level) -> Color {
        switch level {
        case .good: .green
        case .weak: .yellow
        case .missing: .red
        case .off: .secondary
        }
    }
}

/// The subject's typical resting values from earlier calibrations.
struct UsualValuesRow: View {
    let usual: UsualValues
    let sensors: Set<Channel>

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            Text("Usual at rest (\(usual.calibrations) calibration\(usual.calibrations == 1 ? "" : "s")): ")
                .foregroundStyle(.secondary)
                + Text(parts.joined(separator: " · "))
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var parts: [String] {
        var parts: [String] = []
        if sensors.contains(.pulse) {
            if let hr = usual.heartRate { parts.append("\(Int(hr.rounded())) bpm") }
            if let hrv = usual.hrv { parts.append("HRV \(Int(hrv.rounded())) ms") }
        }
        if sensors.contains(.resp), let br = usual.breathingRate { parts.append(String(format: "%.1f breaths/min", br)) }
        if sensors.contains(.gsr), let gsr = usual.gsrRaw { parts.append("GSR level \(Int(gsr.rounded()))") }
        return parts.isEmpty ? ["no measurements for the sensors that are on"] : parts
    }
}
