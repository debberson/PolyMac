import Foundation
import SwiftUI

enum QuestionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case irrelevant, control, relevant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .irrelevant: "Irrelevant"
        case .control: "Control"
        case .relevant: "Relevant"
        }
    }

    var explanation: String {
        switch self {
        case .irrelevant: "A neutral fact (\"Are you sitting down?\"). Shows the subject's resting reaction."
        case .control: "A broad question most people fudge (\"Ever lied to get out of trouble?\"). Sets the bar a real lie should beat."
        case .relevant: "The question you actually care about. Only these get a verdict."
        }
    }

    var color: Color {
        switch self {
        case .irrelevant: .gray
        case .control: .orange
        case .relevant: .purple
        }
    }
}

struct Question: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var kind: QuestionKind
    /// Set on generated card-test questions ("Is your number 4?").
    var cardNumber: Int? = nil

    static let starterSet: [Question] = [
        Question(text: "Are you sitting down right now?", kind: .irrelevant),
        Question(text: "Have you ever lied to get out of trouble?", kind: .control),
        Question(text: "Did you eat the last slice of pizza?", kind: .relevant),
        Question(text: "Is the light on in this room?", kind: .irrelevant),
        Question(text: "Before you were 18, did you ever take something that wasn't yours?", kind: .control),
        Question(text: "Have you read someone else's messages this week?", kind: .relevant),
    ]
}

enum Answer: String, Codable, Sendable {
    case yes, no, none

    var title: String {
        switch self {
        case .yes: "Yes"
        case .no: "No"
        case .none: "No answer"
        }
    }

    var shortTitle: String {
        switch self {
        case .yes: "YES"
        case .no: "NO"
        case .none: "—"
        }
    }
}

struct QuestionRecord: Identifiable, Equatable {
    let id = UUID()
    let number: Int
    let question: Question
    let askSample: Int
    let stabilityAtAsk: StabilityReport.Level
    var answer: Answer?
    var answerSample: Int?
    var responseEndSample: Int?
    var score: ReactionScore?
    var verdict: Verdict?
    var interrupted = false
    /// Measurements exported for training and fed to the trained model.
    var features: FeatureVector?
    /// The trained model's probability that this answer was a lie.
    var mlProbability: Double?
    /// What was actually true, entered after a training session.
    var label: GroundTruth?
    /// In simulator mode, whether the fake subject was "lying", used to pre-fill labels.
    var simulatedTruth: GroundTruth?

    var latency: Double? { answerSample.map { Double($0 - askSample) / Signal.sampleRate } }
}

struct SubjectProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var baseline: Baseline?
    /// Grove GSR: more sweat → lower reading.
    var gsrInverted = true
    /// 0 = cautious (more "inconclusive"), 1 = decisive.
    var sensitivity = 0.5
    /// Seconds after the answer that count toward the reaction.
    var responseSeconds = 8.0
}

/// How the simulator's fake subject reacts to relevant questions.
enum SimulatedSubject: String, CaseIterable, Identifiable {
    case honest, random, lying

    var id: String { rawValue }

    var title: String {
        switch self {
        case .honest: "Honest"
        case .random: "Random"
        case .lying: "Lying"
        }
    }
}

extension Verdict {
    var title: String {
        switch self {
        case .truthful: "Likely truthful"
        case .inconclusive: "Inconclusive"
        case .deceptive: "Likely deceptive"
        }
    }

    var shortTitle: String {
        switch self {
        case .truthful: "Truthful"
        case .inconclusive: "Unclear"
        case .deceptive: "Deceptive"
        }
    }

    var color: Color {
        switch self {
        case .truthful: .green
        case .inconclusive: .yellow
        case .deceptive: .red
        }
    }
}

enum Persistence {
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
