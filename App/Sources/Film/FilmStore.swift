import Foundation
import Observation

/// Game film and what the shooter said about it (1.4, 2026-09-19).
///
/// **Every decision in here was typed by a person.** Nothing in this file, and nothing on the screens
/// that read it, is a judgement the app made about a possession. The app can find *where a ball
/// arrived at a rim* when the rim is in view and marked; it cannot tell who had the ball, whether a
/// shot was open, or whether a pass was the right read. Those are the shooter's own tags, and the
/// review screen says so on every line. `docs/DESIGN-FILM-REVIEW-2026-09-19.md` says what it would
/// take to do more than that, and what it would cost in accuracy.

// MARK: - What can be tagged

enum FilmDecision: String, Codable, CaseIterable, Identifiable, Sendable {
    case shotOpen
    case shotContested
    case pass
    case drive
    case passedUpOpenShot
    case turnover

    var id: String { rawValue }

    /// Never the raw identifier on screen (`docs/IMPROVEMENTS-2026-09-16.md` §1.1 item 5).
    var name: String {
        switch self {
        case .shotOpen: return "Open shot"
        case .shotContested: return "Contested shot"
        case .pass: return "Pass"
        case .drive: return "Drive"
        case .passedUpOpenShot: return "Passed up an open shot"
        case .turnover: return "Turnover"
        }
    }

    var symbol: String {
        switch self {
        case .shotOpen: return "basketball"
        case .shotContested: return "hand.raised"
        case .pass: return "arrow.turn.up.right"
        case .drive: return "figure.run"
        case .passedUpOpenShot: return "eye.slash"
        case .turnover: return "xmark.circle"
        }
    }
}

/// Whose possession it was. "Teammate" exists so a whole game can be tagged in one pass without the
/// counts for the shooter's own reads being polluted.
enum FilmActor: String, Codable, CaseIterable, Identifiable, Sendable {
    case me, teammate
    var id: String { rawValue }
    var name: String { self == .me ? "Me" : "A teammate" }
}

/// Where it happened from. Optional, because guessing it would be inventing a fact.
enum FilmRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case unstated, inside, three
    var id: String { rawValue }
    var name: String {
        switch self {
        case .unstated: return "Not said"
        case .inside: return "Inside the arc"
        case .three: return "Three"
        }
    }
    /// The word that goes inside a sentence: "an open three", "an open shot".
    var phrase: String? {
        switch self {
        case .unstated: return nil
        case .inside: return "two"
        case .three: return "three"
        }
    }
}

struct FilmTag: Codable, Identifiable, Sendable {
    var id = UUID()
    /// Seconds into the clip, on the file clock the player scrubs on.
    var possessionStartSeconds: Double
    /// The moment the decision was made — where the review line points.
    var decisionSeconds: Double
    var possessionEndSeconds: Double?
    var decision: FilmDecision
    var who: FilmActor
    var range: FilmRange = .unstated
    var note: String?
    var createdAt = Date()

    /// "3:12"
    static func clock(_ seconds: Double) -> String {
        let s = max(0, seconds.rounded())
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    var timeText: String { FilmTag.clock(decisionSeconds) }

    /// One review line, in the second person, built only from what was tagged.
    var reviewLine: String {
        let subject = who == .me ? "you" : "a teammate"
        let thing = range.phrase
        var body: String
        switch decision {
        case .passedUpOpenShot:
            body = thing.map { "\(subject) passed up an open \($0)" } ?? "\(subject) passed up an open shot"
        case .shotOpen:
            body = thing.map { "\(subject) took an open \($0)" } ?? "\(subject) took an open shot"
        case .shotContested:
            body = thing.map { "\(subject) took a contested \($0)" } ?? "\(subject) took a contested shot"
        case .pass:
            body = "\(subject) passed"
        case .drive:
            body = "\(subject) drove"
        case .turnover:
            body = "\(subject) turned it over"
        }
        if who == .me { body = body.replacingOccurrences(of: "you passed", with: "you passed") }
        let note = (self.note?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        return "\(timeText) — " + body.prefix(1).uppercased() + body.dropFirst() + (note.map { " (\($0))" } ?? "")
    }
}

/// A place in the clip where the rim scanner thinks a ball arrived at the marked rim. **A candidate,
/// not a shot**: it is a hint for where to scrub to, and it is labelled that way everywhere.
struct ShotCandidate: Codable, Identifiable, Sendable {
    var id: Int
    var fileSeconds: Double
    var arrivalDistancePx: Double
    var descentCandidates: Int
    var timeText: String { FilmTag.clock(fileSeconds) }
}

// MARK: - One piece of film

struct FilmSession: Codable, Identifiable, Sendable {
    var id = UUID()
    var importedAt: Date
    /// What the shooter called it. Defaults to the date.
    var title: String
    var durationSeconds: Double
    var frameRate: Double
    var tags: [FilmTag] = []
    var candidates: [ShotCandidate] = []
    /// Why the timeline has the candidates it has — or why it has none. Always shown with them.
    var candidateNote: String?
    /// The temp file the clip was copied to. It is in the system temp directory and iOS may delete
    /// it, so the tags are written to survive without it and the screen says when the video is gone.
    var clipPath: String?

    var myTags: [FilmTag] { tags.filter { $0.who == .me }.sorted { $0.decisionSeconds < $1.decisionSeconds } }
    var sortedTags: [FilmTag] { tags.sorted { $0.decisionSeconds < $1.decisionSeconds } }

    /// Counts per decision, for the one actor, newest counts first. Every row carries its n because
    /// three of anything is not a tendency.
    func counts(for who: FilmActor) -> [(decision: FilmDecision, n: Int)] {
        let mine = tags.filter { $0.who == who }
        return FilmDecision.allCases.map { d in (d, mine.filter { $0.decision == d }.count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    /// The one-paragraph summary of the shooter's own tags. Says n every time, and says whose
    /// judgement it is.
    var summarySentence: String {
        let mine = tags.filter { $0.who == .me }
        guard !mine.isEmpty else {
            return "You have not tagged any of your own possessions in this film yet."
        }
        let passedUp = mine.filter { $0.decision == .passedUpOpenShot }.count
        let contested = mine.filter { $0.decision == .shotContested }.count
        let open = mine.filter { $0.decision == .shotOpen }.count
        var parts = ["You tagged \(mine.count) of your own possession\(mine.count == 1 ? "" : "s") in this film."]
        if open + contested > 0 {
            parts.append("Of the \(open + contested) shot\(open + contested == 1 ? "" : "s") you took, you called \(open) open and \(contested) contested.")
        }
        if passedUp > 0 {
            parts.append("You passed up \(passedUp) open shot\(passedUp == 1 ? "" : "s") you thought you should have taken.")
        }
        parts.append("These are your own calls, not the app's — it cannot see who was open.")
        return parts.joined(separator: " ")
    }

    var clipURL: URL? {
        guard let clipPath, FileManager.default.fileExists(atPath: clipPath) else { return nil }
        return URL(fileURLWithPath: clipPath)
    }
}

// MARK: - Storage

@MainActor
@Observable
final class FilmStore {
    /// Newest first.
    private(set) var films: [FilmSession] = []
    private(set) var loadError: String?
    private(set) var saveError: String?

    static let fileName = "film.json"

    init() { load() }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ArcLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    func load() {
        let url = FilmStore.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { films = []; return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            films = try decoder.decode([FilmSession].self, from: Data(contentsOf: url)).sorted { $0.importedAt > $1.importedAt }
            loadError = nil
        } catch {
            loadError = "could not read the film log: \(error)"
            films = []
        }
    }

    func save(_ film: FilmSession) {
        films.removeAll { $0.id == film.id }
        films.append(film)
        films.sort { $0.importedAt > $1.importedAt }
        persist()
    }

    func delete(_ id: UUID) {
        films.removeAll { $0.id == id }
        persist()
    }

    func film(_ id: UUID) -> FilmSession? { films.first { $0.id == id } }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(films).write(to: FilmStore.fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "could not write the film log: \(error)"
        }
    }

    /// Every tag the shooter made about themselves, across every film, with the film it came from.
    var totalMyTags: Int { films.reduce(0) { $0 + $1.myTags.count } }
}
