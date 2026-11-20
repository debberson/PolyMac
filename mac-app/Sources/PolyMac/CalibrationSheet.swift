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
                    Text("1. Clip the pulse sensor on a fingertip or earlobe.")
                    Text("2. Put the GSR electrodes on two fingers of the other hand.")
                    Text("3. Snug the stretch band around the chest.")
                    Text("4. Sit comfortably, rest your hands, breathe normally and don't talk.")
                }
                .font(.callout)
                HStack {
                    Label(model.stability.level.title, systemImage: model.stability.level.symbol)
                        .foregroundStyle(model.stability.level.color)
                    Spacer()
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
                    liveStat("Heart", model.stats.heartRate.map { "\(Int($0)) bpm" })
                    liveStat("Breathing", model.stats.breathingRate.map { String(format: "%.1f/min", $0) })
                    liveStat("Stability", model.stability.level.title)
                }
                Button("Cancel", role: .destructive) { model.cancelCalibration() }
            }

        case .finished(let result):
            VStack(alignment: .leading, spacing: 10) {
                Text("Baseline recorded").font(.headline)
                ForEach(result.quality) { quality in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: symbol(quality.level)).foregroundStyle(color(quality.level))
                        Text(quality.channel.title).font(.callout.weight(.medium)).frame(width: 90, alignment: .leading)
                        Text(quality.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if result.quality.contains(where: { $0.level != .good }) {
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
        }
    }

    private func color(_ level: ChannelQuality.Level) -> Color {
        switch level {
        case .good: .green
        case .weak: .yellow
        case .missing: .red
        }
    }
}
