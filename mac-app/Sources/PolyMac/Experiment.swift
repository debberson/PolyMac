import Foundation
import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case exam, experiment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exam: "Exam"
        case .experiment: "Experiment"
        }
    }
}

/// One timed step of an experiment template.
struct PhasePlan: Equatable, Sendable {
    var name: String
    var seconds: Int
    /// How stressed the simulator's fake subject becomes in this phase (0–1).
    var simulatedStress: Double = 0
    /// Breathing rate the simulator follows in this phase (default 15/min).
    var simulatedBreathing: Double = 15
}

struct ExperimentTemplate: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let instructions: String
    let phases: [PhasePlan]

    var totalSeconds: Int { phases.reduce(0) { $0 + $1.seconds } }

    static let free = ExperimentTemplate(
        id: "free",
        title: "Free recording",
        instructions: "Record anything. Start labeled phases with the buttons and drop markers whenever something happens. Stop when you're done.",
        phases: []
    )

    static let all: [ExperimentTemplate] = [
        free,
        ExperimentTemplate(
            id: "paced-breathing",
            title: "Paced breathing",
            instructions: "During the middle phase, breathe in for 5 s and out for 5 s (6 breaths a minute). Heart rate should swing with each breath and HRV should rise: respiratory sinus arrhythmia.",
            phases: [
                PhasePlan(name: "Rest", seconds: 120),
                PhasePlan(name: "Paced breathing", seconds: 180, simulatedBreathing: 6),
                PhasePlan(name: "Recovery", seconds: 120),
            ]
        ),
        ExperimentTemplate(
            id: "mental-arithmetic",
            title: "Mental arithmetic",
            instructions: "During Task, the subject counts backwards from 1000 in steps of 7, out loud and as fast as they can. Expect heart rate and skin responses to rise and HRV to fall, then recover.",
            phases: [
                PhasePlan(name: "Rest", seconds: 120),
                PhasePlan(name: "Task", seconds: 120, simulatedStress: 0.7, simulatedBreathing: 18),
                PhasePlan(name: "Recovery", seconds: 120, simulatedStress: 0.1),
            ]
        ),
        ExperimentTemplate(
            id: "exercise-recovery",
            title: "Exercise recovery",
            instructions: "During Exercise, do jumping jacks or step-ups (sensors stay on, so move carefully), then sit still for Recovery. How far heart rate drops in the first minute of recovery is a standard fitness measure.",
            phases: [
                PhasePlan(name: "Rest", seconds: 60),
                PhasePlan(name: "Exercise", seconds: 60, simulatedStress: 1, simulatedBreathing: 24),
                PhasePlan(name: "Recovery", seconds: 180, simulatedStress: 0.15, simulatedBreathing: 16),
            ]
        ),
        ExperimentTemplate(
            id: "habituation",
            title: "Habituation",
            instructions: "During Stimuli, make the same sudden sound (a clap or a beep) about 10 times at random intervals, adding a marker each time (⌘↩). Skin responses should shrink with repetition.",
            phases: [
                PhasePlan(name: "Rest", seconds: 60),
                PhasePlan(name: "Stimuli", seconds: 240),
                PhasePlan(name: "Recovery", seconds: 60),
            ]
        ),
    ]

    static func find(_ id: String) -> ExperimentTemplate { all.first { $0.id == id } ?? free }
}

struct ExperimentMarker: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    /// Sample index from the start of the recording.
    var sample: Int
    var label: String
    var addedLive: Bool
}

struct ExperimentPhase: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// Sample range from the start of the recording.
    var start: Int
    var end: Int
}

/// A finished (or reopened) experiment recording.
struct ExperimentRecording: Identifiable {
    var id = UUID()
    var title: String
    var templateID: String
    var subjectID: UUID
    var subjectName: String
    var startedAt: Date
    var source: String
    var gsrInverted: Bool
    var baseline: Baseline?
    var channels: [[Double]]
    var markers: [ExperimentMarker]
    var phases: [ExperimentPhase]
    var notes = ""
    var folder: URL?

    var sampleCount: Int { channels[0].count }
    var duration: Double { Double(sampleCount) / Signal.sampleRate }
}

/// A saved experiment found in the data folder.
struct SavedExperiment: Identifiable, Equatable {
    var folder: URL
    var title: String
    var startedAt: Date
    var duration: Double
    var id: URL { folder }
}

/// Colors cycled for phase shading.
enum PhasePalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

func formatClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
}
