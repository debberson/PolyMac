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
            HStack(spacing: 0) {
                ChartsPanel(
                    buffer: model.buffer,
                    windowSamples: model.windowSeconds * AppModel.nominalSampleRate,
                    isRunning: model.isRunning,
                    source: model.source,
                    displayName: model.displayName(for:),
                    readouts: Dictionary(uniqueKeysWithValues: Channel.allCases.map { ($0, model.readout(for: $0)) }),
                    markers: model.chartMarkers,
                    regions: model.chartRegions
                )
                Divider()
                Sidebar(model: model)
                    .frame(width: 360)
            }
        }
        .sheet(isPresented: $model.showingCalibration) {
            CalibrationSheet(model: model)
        }
        .sheet(isPresented: $model.showingSessionEnd) {
            SessionEndSheet(model: model)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    var body: some View {
        // Pull a snapshot each display frame; when stopped, the last trace stays frozen on screen.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isRunning)) { _ in
            let snapshot = buffer.snapshot(last: windowSamples)
            VStack(spacing: 0) {
                ForEach(Channel.displayOrder) { channel in
                    StripChart(
                        channel: channel,
                        values: snapshot.channels[channel.rawValue],
                        total: snapshot.total,
                        windowSamples: windowSamples,
                        readout: readouts[channel] ?? ChannelReadout(value: "—", unit: "", details: []),
                        markers: markers,
                        regions: regions,
                        showMarkerLabels: channel == Channel.displayOrder.first
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
