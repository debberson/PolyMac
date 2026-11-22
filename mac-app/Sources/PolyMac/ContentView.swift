import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ControlBar(model: model)
            Divider()
            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.errorMessage = nil }
                Divider()
            }
            if model.appMode == .experiment, model.review != nil {
                ReviewView(model: model)
            } else {
                liveView
            }
        }
        .sheet(isPresented: $model.showingCalibration) {
            CalibrationSheet(model: model)
        }
        .sheet(isPresented: $model.showingSessionEnd) {
            SessionEndSheet(model: model)
        }
    }

    private var liveView: some View {
            HStack(spacing: 0) {
                ChartsPanel(
                    buffer: model.buffer,
                    windowSamples: model.windowSeconds * AppModel.nominalSampleRate,
                    isRunning: model.isRunning,
                    source: model.source,
                    displayName: model.displayName(for:),
                    readouts: Dictionary(uniqueKeysWithValues: Channel.allCases.map { ($0, model.readout(for: $0)) }),
                    markers: model.chartMarkers,
                    regions: model.chartRegions,
                    channels: model.shownChannels,
                    scales: model.chartScales,
                    autoScale: model.autoScale
                )
                Divider()
                Sidebar(model: model)
                    .frame(width: 360)
            }
    }
}

private struct ControlBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("Port", selection: $model.selectedPort) {
                if model.ports.isEmpty {
                    Text("No serial ports").tag(String?.none)
                }
                ForEach(model.ports, id: \.self) { port in
                    Text(model.displayName(for: port)).tag(String?.some(port))
                }
            }
            .labelsHidden()
            .frame(width: 240)
            .disabled(model.isRunning)

            Button {
                model.refreshPorts()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan serial ports")
            .disabled(model.isRunning)

            if case .serial = model.source {
                Button("Disconnect", systemImage: "stop.fill") { model.stop() }
            } else {
                Button("Connect", systemImage: "cable.connector") { model.connect() }
                    .disabled(model.selectedPort == nil)
            }

            if model.source == .simulator {
                Button("Stop Simulation", systemImage: "stop.fill") { model.stop() }
            } else {
                Button("Simulate", systemImage: "waveform.path.ecg") { model.startSimulation() }
                    .help("Generate fake signals to try the app without an Arduino")
            }

            Spacer()

            Picker("Mode", selection: $model.appMode) {
                ForEach(AppMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .disabled(model.modeLocked)
            .help(model.modeLocked
                ? "Finish the current session or recording to switch modes"
                : "Exam: questions and verdicts. Experiment: record phases and markers, then review and interpret.")

            SensorsMenu(model: model)

            Toggle(isOn: $model.autoScale) {
                Label("Auto Scale", systemImage: model.autoScale ? "arrow.up.and.down" : "lock")
            }
            .toggleStyle(.button)
            .help(model.autoScale
                ? "Auto Scale is on: chart scales follow the signal. Turn off to hold them still so changes are easy to compare."
                : "Auto Scale is off: chart scales are held. Use Fit and the zoom buttons beside each chart to adjust.")

            if model.review == nil || model.appMode != .experiment {
            Picker("Window", selection: $model.windowSeconds) {
                ForEach(AppModel.windowChoices, id: \.self) { seconds in
                    Text("\(seconds)s").tag(seconds)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            .help("Seconds of signal shown on screen")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Turn sensors on and off, for example when the breathing band isn't set up yet.
private struct SensorsMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Section("Sensors in use") {
                ForEach(Channel.displayOrder) { channel in
                    Toggle(channel.sensorName, isOn: Binding(
                        get: { model.enabledSensors.contains(channel) },
                        set: { model.setSensor(channel, on: $0) }
                    ))
                    .disabled(model.enabledSensors == [channel])
                }
            }
            Text("Sensors that are off are hidden and left out of stability checks, calibration, scoring and experiment analysis.")
        } label: {
            Label(label, systemImage: "sensor")
        }
        .fixedSize()
        .disabled(model.sensorsLocked)
        .help(model.sensorsLocked
            ? "Finish the current session, recording or calibration to change sensors"
            : "Choose which sensors are connected")
    }

    private var label: String {
        model.enabledSensors.count == 3 ? "Sensors" : "Sensors \(model.enabledSensors.count)/3"
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12))
    }
}

private struct ChartsPanel: View {
    let buffer: SampleBuffer
    let windowSamples: Int
    let isRunning: Bool
    let source: AppModel.Source
    let displayName: (String) -> String
    let readouts: [Channel: ChannelReadout]
    let markers: [ChartMarker]
    let regions: [ChartRegion]
    let channels: [Channel]
    let scales: ChartScales
    let autoScale: Bool

    var body: some View {
        let _ = scales.revision  // redraw after Fit/zoom even while stopped
        // Pull a snapshot each display frame; when stopped, the last trace stays frozen on screen.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isRunning)) { _ in
            let snapshot = buffer.snapshot(last: windowSamples)
            VStack(spacing: 0) {
                ForEach(channels) { channel in
                    StripChart(
                        channel: channel,
                        values: snapshot.channels[channel.rawValue],
                        total: snapshot.total,
                        windowSamples: windowSamples,
                        readout: readouts[channel] ?? ChannelReadout(value: "—", unit: "", details: []),
                        markers: markers,
                        regions: regions,
                        showMarkerLabels: channel == channels.first,
                        range: scales.range(for: channel, values: snapshot.channels[channel.rawValue], auto: autoScale),
                        autoScale: autoScale,
                        onFit: { scales.fitNow(channel) },
                        onZoom: { scales.zoom(channel, by: $0) }
                    )
                    Divider()
                }
                StatusBar(snapshot: snapshot, source: source, displayName: displayName)
            }
        }
    }
}

private struct StatusBar: View {
    let snapshot: SampleBuffer.Snapshot
    let source: AppModel.Source
    let displayName: (String) -> String

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
            Spacer()
            Text("\(Int(snapshot.samplesPerSecond.rounded())) samples/s")
            Text("\(snapshot.total) total")
            if snapshot.unparsedLines > 0 {
                Text("\(snapshot.unparsedLines) unreadable lines")
                    .foregroundStyle(.orange)
                    .help("Lines that weren't CSV or Serial Plotter format. A few right after connecting is normal: the Uno resets when the port opens.")
            }
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch source {
        case .none: "Not connected"
        case .serial(let path): "Connected to \(displayName(path)) at \(AppModel.baudRate) baud"
        case .simulator: "Simulated signals"
        }
    }

    private var statusColor: Color {
        switch source {
        case .none: .gray
        case .serial: snapshot.samplesPerSecond > 0 ? .green : .yellow
        case .simulator: .purple
        }
    }
}
