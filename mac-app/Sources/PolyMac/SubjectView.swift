import SwiftUI

/// The subject-facing window: shows only the current question and Yes/No buttons, never stats or verdicts.
struct SubjectView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            content
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        if model.isCalibrating {
            Image(systemName: "lungs.fill").font(.system(size: 64)).foregroundStyle(.blue)
            Text("Sit still and breathe normally").font(.largeTitle.weight(.semibold))
            Text("\(model.calibrationSecondsLeft) s").font(.title.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            switch model.phase {
            case .awaitingAnswer:
                if let record = model.activeRecord {
                    Text("Question \(record.number)").font(.title3).foregroundStyle(.secondary)
                    Text(record.question.text)
                        .font(.system(size: 40, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 24) {
                        answerButton("Yes", color: .green, key: "y") { model.answer(.yes) }
                        answerButton("No", color: .red, key: "n") { model.answer(.no) }
                    }
                }
            case .responseWindow:
                Image(systemName: "hand.raised.fill").font(.system(size: 56)).foregroundStyle(.secondary)
                Text("Thank you").font(.largeTitle.weight(.semibold))
                Text("Please stay still…").font(.title2).foregroundStyle(.secondary)
            case .idle:
                Image(systemName: "figure.mind.and.body").font(.system(size: 64)).foregroundStyle(.secondary)
                Text("Relax and sit still").font(.largeTitle.weight(.semibold))
                Text("The next question will appear here.").font(.title3).foregroundStyle(.secondary)
            }
        }
    }

    private func answerButton(_ title: String, color: Color, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 32, weight: .bold))
                .frame(width: 180, height: 90)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .keyboardShortcut(key, modifiers: [])
    }
}
