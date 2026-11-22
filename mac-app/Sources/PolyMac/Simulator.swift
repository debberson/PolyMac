import Foundation

/// Generates plausible-looking fake signals at 100 Hz so the app can be tried without hardware.
/// - `stimulate` makes the fake subject react to a question or event roughly the way a real one
///   would: after a ~1.5 s delay, skin conductance rises, heart rate jumps, breathing gets shallower.
/// - `setStress` and `setBreathingRate` drive experiment phases: stress raises heart rate, sweat
///   and skin responses and damps heart-rate variability; slow breathing deepens the heart-rate
///   swing with each breath (respiratory sinus arrhythmia).
final class Simulator: @unchecked Sendable {
    private let onReading: @Sendable (Reading) -> Void

    // Only touched on `queue`.
    private let queue = DispatchQueue(label: "PolyMac.simulator")
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var pendingStimuli: [(tick: Int, strength: Double)] = []

    private var stress = 0.0
    private var stressTarget = 0.0
    private var breathingRate = 15.0
    private var breathingTarget = 15.0

    private var heartBase = 70.0
    private var heartBoost = 0.0
    private var beatJitter = 0.0
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

    /// `strength` 0–1: how much the question or event "gets to" the fake subject.
    func stimulate(strength: Double) {
        queue.async { [self] in
            pendingStimuli.append((tick + 150, strength))
        }
    }

    /// 0 = relaxed, 1 = maximal effort. Changes ease in over several seconds.
    func setStress(_ level: Double) {
        queue.async { [self] in stressTarget = min(max(level, 0), 1) }
    }

    func setBreathingRate(_ perMinute: Double) {
        queue.async { [self] in breathingTarget = min(max(perMinute, 4), 30) }
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

        stress += (stressTarget - stress) * 0.0015
        breathingRate += (breathingTarget - breathingRate) * 0.002

        // Breathing: easing shallower while suppressed (never an instant jump).
        breathTarget *= 0.998
        breathSuppression += (breathTarget - breathSuppression) * 0.01
        breathPhase += breathingRate / 60 / 100
        let depth = (1 - breathSuppression) * (1 + 0.3 * (15 - breathingRate) / 15)
        let resp = 512 + depth * (140 * sin(2 * .pi * breathPhase) + 25 * sin(4 * .pi * breathPhase + 1)) + noise(4)

        // Pulse: systolic peak plus dicrotic bump. Rate = stress-dependent base + reactions +
        // breathing-linked swing (bigger when breathing is slow, smaller under stress) + per-beat jitter.
        heartBoost *= 0.9975
        let heartTarget = 70 + 28 * stress
        heartBase += (heartTarget - heartBase) * 0.002 + noise(0.02)
        let swing = 4.5 * pow(15 / breathingRate, 0.8) * (1 - 0.75 * stress)
        let heartRate = heartBase + heartBoost + swing * sin(2 * .pi * breathPhase) + beatJitter
        let previousBeat = floor(pulsePhase)
        pulsePhase += heartRate / 60 / 100
        if floor(pulsePhase) != previousBeat {
            beatJitter = noise(2.5 * (1 - 0.7 * stress) + 0.4)
        }
        let phase = pulsePhase.truncatingRemainder(dividingBy: 1)
        let pulse = 500
            + 220 * exp(-pow((phase - 0.15) / 0.05, 2))
            + 70 * exp(-pow((phase - 0.42) / 0.08, 2))
            + noise(5)

        // GSR: spontaneous responses (more frequent under stress) plus evoked ones. Like the Grove
        // sensor, more sweat means a lower reading.
        if Double.random(in: 0..<1) < 0.0002 + 0.003 * stress { gsrDrive += Double.random(in: 20...50) }
        gsrDrive *= 0.996
        gsrResponse += (gsrDrive - gsrResponse) * 0.02
        gsrBaseline = min(max(gsrBaseline + noise(0.1), 340), 420)
        let gsr = gsrBaseline - 35 * stress - gsrResponse + noise(1.5)

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
