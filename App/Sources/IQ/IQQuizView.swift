import SwiftUI

/// The quiz: ten questions a round, drawn from `IQQuizBank` across rules, situations and clock
/// management. The options are shuffled every round — the answer is stored first in the data, so a
/// screen that showed them in order would be a quiz about which button is on top.
///
/// Every answer shows one sentence of reasoning and where it came from. Where FIBA and the NBA
/// differ, the question says which book it is asking about rather than pretending there is one
/// answer.
struct IQQuizView: View {
    var store: IQStore

    private struct Item: Identifiable {
        let question: IQQuestion
        let options: [String]
        let correctIndex: Int
        var id: String { question.id }
    }

    @State private var items: [Item] = []
    @State private var index = 0
    @State private var picked: Int?
    @State private var roundCorrect = 0
    @State private var done = false

    var body: some View {
        Group {
            if done {
                summary
            } else if items.indices.contains(index) {
                question(items[index])
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Quiz")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard items.isEmpty else { return }
            var generator = SystemRandomNumberGenerator()
            items = IQQuizBank.round(count: 10, using: &generator).map { q in
                let shuffled = q.options.shuffled(using: &generator)
                let answer = shuffled.firstIndex(of: q.correctAnswer) ?? 0
                return Item(question: q, options: shuffled, correctIndex: answer)
            }
            ActivityLog.shared.event("screen", ["name": "iq.quiz", "questions": items.count])
        }
    }

    private func question(_ item: Item) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Question \(index + 1) of \(items.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(item.question.topic.title)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }

                Text(item.question.question)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { offset, option in
                        Button {
                            answer(offset, item: item)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: symbol(for: offset, item: item))
                                    .foregroundStyle(tint(for: offset, item: item))
                                Text(option)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(picked == nil ? 0.10 : 0.06),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .disabled(picked != nil)
                    }
                }

                if picked != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.question.rationale)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.question.source.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

                    Button {
                        advance()
                    } label: {
                        Text(index + 1 >= items.count ? "Finish" : "Next question")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
    }

    private func symbol(for offset: Int, item: Item) -> String {
        guard picked != nil else { return "circle" }
        if offset == item.correctIndex { return "checkmark.circle.fill" }
        if offset == picked { return "xmark.circle.fill" }
        return "circle"
    }

    private func tint(for offset: Int, item: Item) -> Color {
        guard picked != nil else { return .secondary }
        if offset == item.correctIndex { return .green }
        if offset == picked { return .red }
        return .secondary
    }

    private func answer(_ offset: Int, item: Item) {
        guard picked == nil else { return }
        picked = offset
        let correct = offset == item.correctIndex
        if correct { roundCorrect += 1 }
        store.record(questionID: item.question.id, topic: item.question.topic, correct: correct)
    }

    private func advance() {
        picked = nil
        if index + 1 >= items.count { done = true } else { index += 1 }
    }

    private var summary: some View {
        List {
            Section("This round") {
                LabeledContent("Right", value: IQWording.fraction(correct: roundCorrect, of: items.count))
            }
            Section("All rounds") {
                LabeledContent("Right", value: IQWording.fraction(correct: store.quizCorrect, of: store.quizCount))
                ForEach(IQQuizTopic.allCases, id: \.self) { topic in
                    let s = store.quizSummary(for: topic)
                    LabeledContent(topic.title, value: IQWording.fraction(correct: s.correct, of: s.n))
                }
            }
            Section {
                Text("""
                Rules questions come from the FIBA and NBA rulebooks and say which one they mean. \
                Clock-and-score questions are what most coaches do, not a proven best answer — \
                coaches argue about several of them.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Round finished")
    }
}
