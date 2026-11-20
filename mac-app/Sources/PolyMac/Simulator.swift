import Foundation

/// Generates plausible-looking fake signals at 100 Hz so the app can be tried without hardware.
/// `stimulate` makes the fake subject react to a question roughly the way a real one would:
/// after a ~1.5 s delay, skin conductance rises, heart rate jumps, and breathing gets shallower.
final class Simulator: @unchecked Sendable {
    private let onReading: @Sendable (Reading) -> Void

    // Only touched on `queue`.
    private let queue = DispatchQueue(label: "PolyMac.simulator")
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var pendingStimuli: [(tick: Int, strength: Double)] = []

    private var heartBase = 70.0
    private var heartBoost = 0.0
    private var pulsePhase = 0.0
    private var breathPhase = 0.0
    private var breathSuppression = 0.0
    private var breathTarget = 0.0
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

    /// `strength` 0–1: how much the question "gets to" the fake subject.
    func stimulate(strength: Double) {
        queue.async { [self] in
            pendingStimuli.append((tick + 150, strength))
        }
    }

    private func step() {
        tick += 1

        for stimulus in pendingStimuli where stimulus.tick <= tick {
            let s = stimulus.strength
            gsrDrive += 4 + 90 * s
            heartBoost += 1 + 14 * s
            breathTarget = max(breathTarget, 0.75 * s)
        }
        pendingStimuli.removeAll { $0.tick <= tick }

        // Breathing: ~15 per minute, easing shallower while suppressed (never an instant jump).
        breathTarget *= 0.998
        breathSuppression += (breathTarget - breathSuppression) * 0.01
        breathPhase += 15.0 / 60 / 100
        let depth = 1 - breathSuppression
        let resp = 512 + depth * (140 * sin(2 * .pi * breathPhase) + 25 * sin(4 * .pi * breathPhase + 1)) + noise(4)

        // Pulse: systolic peak plus dicrotic bump, rate drifting slightly and rising with stress.
        heartBoost *= 0.9975
        heartBase = min(max(heartBase + noise(0.02), 64), 76)
        let heartRate = heartBase + heartBoost + 1.5 * sin(2 * .pi * breathPhase)
        pulsePhase += heartRate / 60 / 100
        let phase = pulsePhase.truncatingRemainder(dividingBy: 1)
        let pulse = 500
            + 220 * exp(-pow((phase - 0.15) / 0.05, 2))
            + 70 * exp(-pow((phase - 0.42) / 0.08, 2))
            + noise(5)

        // GSR: rare spontaneous responses plus evoked ones. Like the Grove sensor, more sweat
        // means a lower reading.
        if Double.random(in: 0..<1) < 0.0002 { gsrDrive += Double.random(in: 20...50) }
        gsrDrive *= 0.996
        gsrResponse += (gsrDrive - gsrResponse) * 0.02
        gsrBaseline = min(max(gsrBaseline + noise(0.1), 340), 420)
        let gsr = gsrBaseline - gsrResponse + noise(1.5)

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
