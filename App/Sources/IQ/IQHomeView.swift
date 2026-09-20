import SwiftUI

/// **IQ** — the tab. Two things to do and one card that says what has been measured so far.
///
/// The card never shows a rating. A fraction of authored reads matched, and a median decision time,
/// each with the n they came from; below ten plays in a principle it says there is not enough to
/// tell and stops. "Basketball IQ" is not a quantity anything here can measure, so the app does not
/// print a number for it (CLAUDE.md rule 1).
struct IQHomeView: View {
    var store: IQStore
    /// `-iq-trainer` on launch opens the trainer without anyone tapping anything, the same
    /// unattended hook as `-tab` in `ContentView`: it exists so the rendered play can be looked at
    /// from the Mac, in the simulator, without touching a phone.
    @State private var openTrainer = ProcessInfo.processInfo.arguments.contains("-iq-trainer")

    var body: some View {
        List {
            Section {
                NavigationLink {
                    IQTrainerView(store: store)
                } label: {
                    card(title: "Trainer",
                         subtitle: "Eight plays from your own eyes. The film stops; you pick the read.",
                         detail: "Times you from the freeze to the tap.",
                         symbol: "eye.fill")
                }
                NavigationLink {
                    IQQuizView(store: store)
                } label: {
                    card(title: "Quiz",
                         subtitle: "Ten questions on rules, situations, and the clock.",
                         detail: "\(IQQuizBank.all.count) questions, each with the reason and where it comes from.",
                         symbol: "text.book.closed.fill")
                }
            }

            progressSection
            trendSection

            Section {
                Text("""
                The right answers in the trainer are what coaches teach — conventions, not results \
                measured from tracking data, and good coaches disagree about some of them. The one \
                number here the app measured itself is how long you took to decide.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("IQ")
        .navigationDestination(isPresented: $openTrainer) {
            IQTrainerView(store: store)
        }
        .onAppear {
            ActivityLog.shared.event("screen", ["name": "iq.home",
                                                "plays": store.totalPlays, "quiz": store.quizCount])
        }
    }

    private func card(title: String, subtitle: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: The progress card

    private var progressSection: some View {
        Section("What you have done") {
            if store.totalPlays == 0 {
                Text("No plays yet. One session is eight.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Reads") {
                    Text(IQWording.fraction(correct: store.totalCorrect, of: store.totalPlays))
                        .monospacedDigit()
                }
                LabeledContent("Median decision") {
                    Text("\(IQWording.time(ms: store.overallMedianMs)) (n \(store.totalPlays))")
                        .monospacedDigit()
                }
                if store.totalPlays < IQPrincipleSummary.floor {
                    Text("Those two lines are real, but they come from \(store.totalPlays) \(store.totalPlays == 1 ? "play" : "plays") — too few to compare against anything yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.principleSummaries) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.principle.title).font(.subheadline)
                        Text(IQWording.line(for: s))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(s.enough ? .secondary : Color.secondary.opacity(0.7))
                    }
                    .padding(.vertical, 1)
                }
            }
            if store.quizCount > 0 {
                LabeledContent("Quiz") {
                    Text(IQWording.fraction(correct: store.quizCorrect, of: store.quizCount))
                        .monospacedDigit()
                }
            }
        }
    }

    private var trendSection: some View {
        let rows = store.sessionSummaries()
        return Group {
            if rows.count >= 2 {
                Section("Session by session") {
                    ForEach(rows.reversed()) { row in
                        HStack {
                            Text(row.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                            Spacer()
                            Text(IQWording.fraction(correct: row.correct, of: row.n))
                                .font(.caption.monospacedDigit())
                            Text(IQWording.time(ms: row.medianMs))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 66, alignment: .trailing)
                        }
                    }
                    Text("Each row is one session: reads right out of the plays in it, then the median decision time for that session. Two sessions is not a trend — it is two points.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if !store.sessions.isEmpty {
                Section("Session by session") {
                    Text("Not enough sessions to show a trend yet. A session counts here once it has five plays in it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
