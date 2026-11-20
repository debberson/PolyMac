import Foundation

/// Generates plausible-looking fake signals at 100 Hz so the app can be tried without hardware.
final class Simulator: @unchecked Sendable {
    private let onReading: @Sendable (Reading) -> Void

    // Only touched on `queue`.
    private let queue = DispatchQueue(label: "PolyMac.simulator")
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var gsrBaseline = 380.0
    private var gsrDrive = 0.0
    private var gsrResponse = 0.0

    init(onReading: @escaping @Sendable (Reading) -> Void) {
        self.onReading = onReading
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.step() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func step() {
        let t = Double(tick) / 100
        tick += 1

        // ~15 breaths per minute.
        let resp = 512 + 140 * sin(2 * .pi * 0.25 * t) + 25 * sin(2 * .pi * 0.5 * t + 1) + noise(4)

        // ~72 bpm pulse wave: systolic peak plus a smaller dicrotic bump.
        let phase = (t * 1.2).truncatingRemainder(dividingBy: 1)
        let pulse = 500
            + 220 * exp(-pow((phase - 0.15) / 0.05, 2))
            + 70 * exp(-pow((phase - 0.42) / 0.08, 2))
            + noise(5)

        // Slow tonic drift with an occasional phasic skin-conductance response.
        if Double.random(in: 0..<1) < 0.0015 { gsrDrive += Double.random(in: 40...110) }
        gsrDrive *= 0.996
        gsrResponse += (gsrDrive - gsrResponse) * 0.02
        gsrBaseline = min(max(gsrBaseline + Double.random(in: -0.3...0.3), 300), 460)
        let gsr = gsrBaseline + gsrResponse + noise(1.5)

        onReading(Reading(
            deviceMillis: UInt32(tick * 10),
            resp: clamp(resp),
            pulse: clamp(pulse),
            gsr: clamp(gsr)
        ))
    }

    private func noise(_ amplitude: Double) -> Double { Double.random(in: -amplitude...amplitude) }
    private func clamp(_ value: Double) -> Double { min(max(value.rounded(), 0), 1023) }
}
