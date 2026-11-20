import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Source: Equatable {
        case none
        case serial(String)
        case simulator
    }

    static let baudRate = 115_200
    static let nominalSampleRate = 100  // matches SAMPLE_INTERVAL_US in the firmware
    static let windowChoices = [5, 10, 30]

    var ports: [String] = []
    var selectedPort: String?
    var windowSeconds = 10
    private(set) var source: Source = .none
    var errorMessage: String?

    @ObservationIgnored let buffer = SampleBuffer(capacity: nominalSampleRate * 60)
    @ObservationIgnored private var serial: SerialPort?
    @ObservationIgnored private var simulator: Simulator?

    var isRunning: Bool { source != .none }

    init() {
        refreshPorts()
    }

    func refreshPorts() {
        ports = SerialPort.availablePorts()
        if let selected = selectedPort, ports.contains(selected) { return }
        selectedPort = ports.first(where: SerialPort.looksLikeBoard) ?? ports.first
    }

    func connect() {
        guard let path = selectedPort else { return }
        stop()
        buffer.reset()
        let buffer = buffer
        let port = SerialPort(
            path: path,
            onLine: { line in
                if let reading = SampleParser.parse(line) {
                    buffer.append(reading)
                } else {
                    buffer.noteUnparsedLine()
                }
            },
            onUnexpectedClose: { [weak self] reason in
                Task { @MainActor in self?.serialClosed(path: path, reason: reason) }
            }
        )
        do {
            try port.open(baud: Self.baudRate)
            serial = port
            source = .serial(path)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startSimulation() {
        stop()
        buffer.reset()
        let buffer = buffer
        let simulator = Simulator { buffer.append($0) }
        simulator.start()
        self.simulator = simulator
        source = .simulator
        errorMessage = nil
    }

    func stop() {
        serial?.close()
        serial = nil
        simulator?.stop()
        simulator = nil
        source = .none
    }

    private func serialClosed(path: String, reason: String) {
        guard source == .serial(path) else { return }
        serial = nil
        source = .none
        errorMessage = "\(displayName(for: path)): \(reason)"
        refreshPorts()
    }

    func displayName(for path: String) -> String {
        path.replacingOccurrences(of: "/dev/cu.", with: "")
    }
}
