import Foundation
import Observation
import ShotGeometry

/// The vertical jump test's own log (1.4, 2026-09-19): one entry per test day, three jumps in each.
///
/// Persisted exactly like `PracticeStore` — a pretty-printed JSON array in Application Support, ISO
/// dates, newest first — because a jump history is the same kind of thing as a practice history and
/// should be readable off the phone with `devicectl` without a decoder ring.
///
/// Nothing here invents a number. A jump the video could not measure is stored **with its reason**
/// and counted in `n` nowhere: the summary is over the jumps that produced a height, and the screen
/// says how many of the three that was.

// MARK: - What one jump is

struct JumpAttempt: Codable, Identifiable, Sendable {
    var id = UUID()
    /// 1, 2, 3 — the order they were jumped in.
    var index: Int
    var recordedAt: Date

    // Method A, flight time. The headline, and the only one that needs no scale.
    var heightMetres: Double?
    /// ±, from the frame clock (one frame at each edge).
    var uncertaintyMetres: Double?
    /// One-sided: the height reads low by up to this much because the floor is read a little above itself.
    var thresholdBiasMetres: Double?
    var flightSeconds: Double?
    var frameRate: Double?
    /// Non-nil when there is no height, and says exactly why. Never both.
    var unavailableReason: String?

    // Method B, hip rise. A cross-check, and only when a scale exists.
    var hipRiseMetres: Double?
    var hipRiseUncertaintyMetres: Double?
    var hipUnavailableReason: String?
    /// The plain-English verdict when both methods produced a number.
    var comparisonSentence: String?

    /// What the measurement had to say about itself — the threshold, the frame interval, the bias.
    var notes: [String] = []
    /// Wall seconds the phone spent on this jump, so the log can show what the test costs.
    var secondsAnalysed: Double = 0
    /// The clip this came from, when it was recorded in ArcLab (so it can be re-read later).
    var clipFileName: String?

    var measured: Bool { heightMetres != nil }

    /// "52.4 ± 0.7 cm", or the reason there is no number.
    var headline: String {
        guard let h = heightMetres else { return unavailableReason ?? "no reason recorded" }
        let pm = uncertaintyMetres.map { String(format: " ± %.1f", 100 * $0) } ?? ""
        return String(format: "%.1f", 100 * h) + pm + " cm"
    }
}

// MARK: - What one test is

struct JumpTestSession: Codable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var attempts: [JumpAttempt]
    /// Written into the file so a future reader knows which method produced the numbers, even if the
    /// app changes. Plain words, because it is shown on screen too.
    var method = JumpTestSession.flightTimeMethod
    /// Where the metre scale for the hip cross-check came from on this day, or nil if there was none.
    var scaleSource: String?

    static let flightTimeMethod = "flight time, height = g × t² ÷ 8"

    var measured: [JumpAttempt] { attempts.filter(\.measured) }

    var summary: VerticalJump.TestSummary? {
        let heights = measured.compactMap(\.heightMetres)
        let errors = measured.map { ($0.uncertaintyMetres ?? 0) + ($0.thresholdBiasMetres ?? 0) }
        return VerticalJump.summarise(heightsMetres: heights, uncertaintiesMetres: errors)
    }

    var bestMetres: Double? { summary?.bestMetres }

    /// "48.1 cm best of 3 · spread 3.2 cm", or what went wrong.
    var line: String {
        guard let s = summary else { return "No jump in this test could be measured." }
        return String(format: "%.1f cm best of %d · spread %.1f cm", 100 * s.bestMetres, s.n, 100 * s.spreadMetres)
    }
}

// MARK: - Storage

@MainActor
@Observable
final class JumpStore {
    /// Newest first.
    private(set) var tests: [JumpTestSession] = []
    private(set) var loadError: String?
    private(set) var saveError: String?

    static let fileName = "jumps.json"

    init() { load() }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ArcLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    func load() {
        let url = JumpStore.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { tests = []; return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            tests = try decoder.decode([JumpTestSession].self, from: Data(contentsOf: url)).sorted { $0.date > $1.date }
            loadError = nil
        } catch {
            loadError = "could not read the jump log: \(error)"
            tests = []
        }
    }

    func save(_ test: JumpTestSession) {
        tests.removeAll { $0.id == test.id }
        tests.append(test)
        tests.sort { $0.date > $1.date }
        persist()
    }

    func delete(_ id: UUID) {
        tests.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(tests).write(to: JumpStore.fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "could not write the jump log: \(error)"
        }
    }

    // MARK: What the history says

    /// One point per test day, oldest first, for the trend line.
    var trend: [VerticalJump.TrendPoint] {
        tests.compactMap { t in
            guard let s = t.summary else { return nil }
            return VerticalJump.TrendPoint(date: t.date, bestMetres: s.bestMetres, n: s.n)
        }.sorted { $0.date < $1.date }
    }

    var trendSentence: String { VerticalJump.trendSentence(trend) }

    var best: JumpTestSession? {
        tests.max { ($0.bestMetres ?? -1) < ($1.bestMetres ?? -1) }
    }

    var latest: JumpTestSession? { tests.first }
}
