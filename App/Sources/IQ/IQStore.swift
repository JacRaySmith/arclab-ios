import Foundation
import Observation

// ================================================================================================
// MARK: - What the IQ trainer remembers
// ================================================================================================
//
// One JSON file next to `practice.json` and `sessions.json` in Application Support. It holds two
// things and no opinions: the plays, each with whether the chosen read matched the authored one
// and how many milliseconds the choice took, and the quiz answers.
//
// Everything the progress card shows is derived from these rows at read time, with the n stated.
// There is no rating, no score out of 100 and no "basketball IQ" number: a fraction of authored
// answers matched and a median reaction time are what was actually measured, and turning those
// into a single number would be inventing one (CLAUDE.md rule 1).

struct IQPlay: Codable, Identifiable, Sendable {
    var id: UUID
    var scenarioID: String
    var principle: IQPrinciple
    var correct: Bool
    /// From the freeze to the tap. Measured with a monotonic clock, not wall time.
    var decisionMs: Int
    var at: Date
}

struct IQSessionRecord: Codable, Identifiable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var plays: [IQPlay]

    var correctCount: Int { plays.filter(\.correct).count }
}

struct IQQuizAnswer: Codable, Identifiable, Sendable {
    var id: UUID
    var questionID: String
    var topic: IQQuizTopic
    var correct: Bool
    var at: Date
}

private struct IQLogFile: Codable {
    var sessions: [IQSessionRecord] = []
    var quiz: [IQQuizAnswer] = []
}

// MARK: - Summaries

/// One principle's record. `medianMs` is nil when there is nothing to take a median of; `enough`
/// is the only thing that decides whether the card is allowed to say anything about it.
struct IQPrincipleSummary: Identifiable, Sendable {
    var principle: IQPrinciple
    var n: Int
    var correct: Int
    var medianMs: Int?
    var id: String { principle.rawValue }

    /// Ten plays. Below that a fraction moves by ten points every time you tap, and a median of
    /// four reaction times is noise with a decimal point on it.
    static let floor = 10
    var enough: Bool { n >= IQPrincipleSummary.floor }
}

struct IQSessionSummary: Identifiable, Sendable {
    var id: UUID
    var date: Date
    var n: Int
    var correct: Int
    var medianMs: Int?
}

enum IQMaths {
    /// The middle value, or the mean of the two middle values. Nil for an empty list — there is no
    /// median of nothing, and 0 would be a lie.
    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        if s.count % 2 == 1 { return s[mid] }
        return (s[mid - 1] + s[mid]) / 2
    }

    /// Empty means it passed, like the other self-checks in the app.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        func eq(_ a: Int?, _ b: Int?, _ what: String) {
            if a != b { failures.append("\(what): \(a.map(String.init) ?? "nil") ≠ \(b.map(String.init) ?? "nil")") }
        }
        eq(median([]), nil, "median of nothing is nothing")
        eq(median([7]), 7, "median of one")
        eq(median([3, 1, 2]), 2, "median of three, unsorted")
        eq(median([4, 1, 3, 2]), 2, "median of four is the mean of the middle pair")
        eq(median([10, 10, 10]), 10, "median of equal values")
        return failures
    }
}

// MARK: - The store

@MainActor
@Observable
final class IQStore {
    private(set) var sessions: [IQSessionRecord] = []
    private(set) var quiz: [IQQuizAnswer] = []
    private(set) var loadError: String?

    static let fileName = "iq.json"

    init() { load() }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ArcLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    func load() {
        let url = IQStore.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { sessions = []; quiz = []; return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(IQLogFile.self, from: Data(contentsOf: url))
            sessions = file.sessions.sorted { $0.startedAt > $1.startedAt }
            quiz = file.quiz
            loadError = nil
        } catch {
            loadError = "could not read the IQ log: \(error)"
            sessions = []; quiz = []
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(IQLogFile(sessions: sessions, quiz: quiz))
            try data.write(to: IQStore.fileURL, options: .atomic)
        } catch {
            loadError = "could not save the IQ log: \(error)"
        }
    }

    // MARK: Writing

    /// Starts a session and returns its id. The row exists from the first play, so a session that
    /// is abandoned half way still counts the plays that really happened.
    func startSession() -> UUID {
        let record = IQSessionRecord(id: UUID(), startedAt: Date(), endedAt: nil, plays: [])
        sessions.insert(record, at: 0)
        ActivityLog.shared.event("iq.session.start", ["session": record.id.uuidString])
        persist()
        return record.id
    }

    func record(play: IQPlay, in sessionID: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[i].plays.append(play)
        ActivityLog.shared.event("iq.play", [
            "session": sessionID.uuidString, "scenario": play.scenarioID,
            "principle": play.principle.rawValue, "correct": play.correct, "decisionMs": play.decisionMs,
        ])
        persist()
    }

    func endSession(_ sessionID: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[i].endedAt = Date()
        let plays = sessions[i].plays
        ActivityLog.shared.event("iq.session.end", [
            "session": sessionID.uuidString, "plays": plays.count,
            "correct": plays.filter(\.correct).count,
            "medianDecisionMs": IQMaths.median(plays.map(\.decisionMs)),
        ])
        persist()
    }

    func record(questionID: String, topic: IQQuizTopic, correct: Bool) {
        quiz.append(IQQuizAnswer(id: UUID(), questionID: questionID, topic: topic, correct: correct, at: Date()))
        ActivityLog.shared.event("iq.quiz", ["question": questionID, "topic": topic.rawValue, "correct": correct])
        persist()
    }

    // MARK: Reading

    var allPlays: [IQPlay] { sessions.flatMap(\.plays) }

    var totalPlays: Int { allPlays.count }
    var totalCorrect: Int { allPlays.filter(\.correct).count }
    var overallMedianMs: Int? { IQMaths.median(allPlays.map(\.decisionMs)) }

    func summary(for principle: IQPrinciple) -> IQPrincipleSummary {
        let plays = allPlays.filter { $0.principle == principle }
        return IQPrincipleSummary(principle: principle, n: plays.count,
                                  correct: plays.filter(\.correct).count,
                                  medianMs: IQMaths.median(plays.map(\.decisionMs)))
    }

    var principleSummaries: [IQPrincipleSummary] {
        IQPrinciple.allCases.map { summary(for: $0) }.sorted { $0.n > $1.n }
    }

    /// Finished sessions, oldest first, for the trend line. A session of fewer than five plays is
    /// left out: it is not a session, it is a glance.
    func sessionSummaries(minimumPlays: Int = 5, limit: Int = 8) -> [IQSessionSummary] {
        let rows = sessions
            .filter { $0.plays.count >= minimumPlays }
            .sorted { $0.startedAt < $1.startedAt }
            .map { s in
                IQSessionSummary(id: s.id, date: s.startedAt, n: s.plays.count,
                                 correct: s.correctCount, medianMs: IQMaths.median(s.plays.map(\.decisionMs)))
            }
        return Array(rows.suffix(limit))
    }

    var quizCount: Int { quiz.count }
    var quizCorrect: Int { quiz.filter(\.correct).count }

    func quizSummary(for topic: IQQuizTopic) -> (n: Int, correct: Int) {
        let rows = quiz.filter { $0.topic == topic }
        return (rows.count, rows.filter(\.correct).count)
    }
}

// MARK: - Saying it in words

enum IQWording {
    /// "14 of 22 right" — never a percentage on its own, because a percentage hides the n.
    static func fraction(correct: Int, of n: Int) -> String {
        n == 0 ? "no plays yet" : "\(correct) of \(n) right"
    }

    /// Milliseconds as the measurement it is: "1.42 s" once it is over a second, "840 ms" below.
    static func time(ms: Int?) -> String {
        guard let ms else { return "no time yet" }
        if ms >= 1000 { return String(format: "%.2f s", Double(ms) / 1000) }
        return "\(ms) ms"
    }

    /// The one sentence a principle is allowed to say. Below the floor it says so and stops.
    static func line(for s: IQPrincipleSummary) -> String {
        guard s.enough else {
            return s.n == 0
                ? "no plays yet"
                : "not enough plays to tell (n \(s.n) of \(IQPrincipleSummary.floor))"
        }
        return "\(fraction(correct: s.correct, of: s.n)) · median \(time(ms: s.medianMs)) (n \(s.n))"
    }
}
