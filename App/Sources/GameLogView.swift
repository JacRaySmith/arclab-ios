import Observation
import ShotGeometry
import SwiftUI

// MARK: - The game log
//
// Added 2026-09-19 for 1.4 "game", from: *"There is often a big split between practice shooting and
// game shooting. Try to address this."*
//
// ArcLab never sees a game, so the only way it can address that split is to let the shooter tell it
// what happened and then be extremely careful about what it says back. Three rules, all from
// CLAUDE.md rule 1, and all visible on the screen rather than in this comment:
//
//  1. A practice make is the app watching the ball resolve at the ring (`RimOutcome.infer`). A game
//     make is a person remembering. Two different measurement processes, shown side by side and
//     never added together.
//  2. Nothing is compared below `GameTransfer.floor` counted shots on each side, and the sentence
//     says how many more it needs.
//  3. Above the floor the smallest gap the two counts can tell from chance is printed every time,
//     and a gap smaller than it is reported as exactly that — never as "you shoot worse in games".
//
// No streaks, no form rating, no "clutch". The arithmetic lives in `ShotGeometry/GameTransfer.swift`
// and is tested there; this file is the screen and the file on disk.

/// One game's worth of shots, as the shooter remembers it.
struct LoggedGame: Codable, Identifiable, Sendable {
    var id: UUID
    var date: Date
    /// Who it was against, or anything else worth remembering. Never used in a calculation.
    var note: String
    var tallies: [GameShotTally]

    var attempts: Int { tallies.reduce(0) { $0 + $1.attempts } }
    var makes: Int { tallies.reduce(0) { $0 + $1.makes } }

    init(id: UUID = UUID(), date: Date, note: String, tallies: [GameShotTally]) {
        self.id = id
        self.date = date
        self.note = note
        self.tallies = tallies
    }
}

/// `games.json`, next to `sessions.json` and `practice.json`.
///
/// Shared rather than per-view: the log is reachable from You and from a plan, and two instances
/// would both hold a stale copy of the same file and quietly overwrite each other.
@MainActor
@Observable
final class GameLog {
    static let shared = GameLog()

    /// Newest first.
    private(set) var games: [LoggedGame] = []
    private(set) var loadError: String?
    private(set) var saveError: String?

    static let fileName = "games.json"

    init() { load() }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ArcLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    func load() {
        let url = GameLog.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { games = []; return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            games = try decoder.decode([LoggedGame].self, from: Data(contentsOf: url)).sorted { $0.date > $1.date }
            loadError = nil
        } catch {
            loadError = "could not read the game log: \(error)"
            games = []
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(games).write(to: GameLog.fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "could not write the game log: \(error)"
        }
    }

    @discardableResult
    func add(date: Date, note: String, tallies: [GameShotTally]) -> LoggedGame? {
        let kept = tallies.filter { $0.attempts > 0 }
        guard !kept.isEmpty else { return nil }
        let game = LoggedGame(date: date, note: note.trimmingCharacters(in: .whitespacesAndNewlines), tallies: kept)
        games.insert(game, at: 0)
        games.sort { $0.date > $1.date }
        persist()
        ActivityLog.shared.event("game.logged", [
            "lines": kept.count, "attempts": game.attempts, "makes": game.makes,
            "zones": Set(kept.map(\.zone.rawValue)).sorted().joined(separator: ", "),
            "contested": kept.filter(\.contested).reduce(0) { $0 + $1.attempts },
            "lateGame": kept.filter(\.lateGame).reduce(0) { $0 + $1.attempts },
            "games": games.count,
        ])
        return game
    }

    func delete(_ id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        let removed = games.remove(at: i)
        persist()
        ActivityLog.shared.event("game.deleted", ["attempts": removed.attempts])
    }

    /// Every logged shot, flattened. The population every comparison is drawn from.
    var allTallies: [GameShotTally] { games.flatMap(\.tallies) }

    // MARK: The practice side

    /// Practice makes and misses, from the saved sessions' inferred outcomes.
    ///
    /// Form clips are left out: they are filmed with no rim in frame, so no shot in one ever had an
    /// outcome to infer. `unknown` is carried and never folded into either column — a shot the app
    /// did not see resolve is not half a make.
    static func practiceCounts(_ store: SessionStore) -> (overall: MakeCount, bySpot: [DoctorSpot: MakeCount]) {
        var overall = MakeCount.none
        var bySpot: [DoctorSpot: MakeCount] = [:]
        for session in store.sessions where !session.isFormClip {
            let s = session.summary
            let count = MakeCount(makes: s.makes, misses: s.misses, unknown: s.unknownOutcomes)
            guard count.makes + count.misses + count.unknown > 0 else { continue }
            overall = overall + count
            if let spot = DoctorSpot(rawValue: session.spot.rawValue) {
                bySpot[spot] = (bySpot[spot] ?? .none) + count
            }
        }
        return (overall, bySpot)
    }
}

// MARK: - The screen

/// **Games** — log what happened, then see it beside your practice.
struct GameLogView: View {
    var store: SessionStore
    @State private var log = GameLog.shared
    @State private var showingEntry = false

    private var tallies: [GameShotTally] { log.allTallies }

    var body: some View {
        List {
            if let why = log.loadError { errorRow(why) }
            if let why = log.saveError { errorRow(why) }
            entrySection
            compareSection
            splitSection
            gamesSection
            honestySection
        }
        .navigationTitle("Games")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEntry) {
            NavigationStack { GameEntryView(log: log) }
        }
        .onAppear {
            ActivityLog.shared.event("screen", ["name": "game.log",
                                                "games": log.games.count,
                                                "shots": tallies.reduce(0) { $0 + $1.attempts }])
            logComparison()
        }
    }

    /// What the comparison card actually showed, including when it showed a refusal — the refusals
    /// are the interesting half of this feature and are worth knowing the count of.
    private func logComparison() {
        let p = practice
        let overall = GameTransfer.overall(practice: p.overall, game: tallies)
        let zones = GameTransfer.byZone(practiceBySpot: p.bySpot, game: tallies)
        ActivityLog.shared.event("game.compare.shown", [
            "practiceN": overall.practice.n, "gameN": overall.game.n,
            "practiceUnknown": overall.practice.unknown,
            "aboveFloor": overall.isAboveFloor, "floor": overall.floor,
            "zones": zones.count, "zonesAboveFloor": zones.filter(\.isAboveFloor).count,
            "verdict": overall.gapIsBiggerThanLuck,
        ])
    }

    private func errorRow(_ why: String) -> some View {
        Text(why).font(.footnote).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Logging

    private var entrySection: some View {
        Section {
            Button {
                showingEntry = true
            } label: {
                Label("Log a game", systemImage: "plus.circle")
            }
            Text("After a game, put in what you took and what went in — one line per kind of shot is enough. Where from, off the catch or off the dribble, open or with a hand in your face.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Your games")
        } footer: {
            Text("This is your memory of the game, not a measurement. The app never saw it, so everything built on it is only as good as what you put in.")
        }
    }

    // MARK: Practice against games

    private var practice: (overall: MakeCount, bySpot: [DoctorSpot: MakeCount]) {
        GameLog.practiceCounts(store)
    }

    @ViewBuilder private var compareSection: some View {
        let p = practice
        let overall = GameTransfer.overall(practice: p.overall, game: tallies)
        let zones = GameTransfer.byZone(practiceBySpot: p.bySpot, game: tallies)
        Section {
            comparisonRow(overall)
            ForEach(Array(zones.enumerated()), id: \.offset) { _, row in
                comparisonRow(row)
            }
            if zones.isEmpty && overall.game.n == 0 {
                Text("Nothing logged yet. Two games' worth of shots is usually the point where the comparison starts to mean anything.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tallies.contains(where: { $0.zone == .atTheRim }), let why = GameShotZone.atTheRim.noPracticeReason {
                VStack(alignment: .leading, spacing: 3) {
                    Text(GameShotZone.atTheRim.name).font(.subheadline.bold())
                    Text(why).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("Practice vs game")
        } footer: {
            Text("A practice make is the app watching the ball go through the ring; some shots it never resolves and those are left out of both columns. A game make is you remembering. They sit side by side and are never added together.")
        }
    }

    private func comparisonRow(_ c: MakeRateComparison) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(c.label).font(.subheadline.bold())
                Spacer()
                if c.isAboveFloor, let verdict = c.gapIsBiggerThanLuck {
                    Text(verdict ? "a real gap" : "inside the noise")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((verdict ? Color.orange : Color.secondary).opacity(0.15), in: Capsule())
                        .foregroundStyle(verdict ? .orange : .secondary)
                } else {
                    Text("cannot tell yet")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            if c.isAboveFloor, let p = c.practiceRate, let g = c.gameRate {
                HStack(spacing: 14) {
                    rate("Practice", GameTransfer.percent(p), n: c.practice.n)
                    rate("Games", GameTransfer.percent(g), n: c.game.n)
                }
            }
            Text(c.sentence).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rate(_ title: String, _ value: String, n: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text("n = \(n)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: Game-only splits

    @ViewBuilder private var splitSection: some View {
        let splits = GameTransfer.gameSplits(tallies)
        if !splits.isEmpty {
            Section {
                ForEach(Array(splits.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.label).font(.subheadline.bold())
                        Text(s.sentence).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Inside your games")
            } footer: {
                Text("These two are game against game, not practice against game: a practice block carries no record of whether the shot came off a catch or whether anybody was near you, so there is nothing on the practice side to line them up with.")
            }
        }
    }

    // MARK: The list

    @ViewBuilder private var gamesSection: some View {
        if !log.games.isEmpty {
            Section {
                ForEach(log.games) { game in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(game.date, format: .dateTime.day().month().year())
                                .font(.subheadline)
                            Spacer()
                            Text("\(game.makes) of \(game.attempts)")
                                .font(.subheadline.monospacedDigit())
                        }
                        if !game.note.isEmpty {
                            Text(game.note).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(game.tallies.map { "\($0.makes)/\($0.attempts) \($0.zone.name.lowercased())\($0.contested ? ", contested" : "")" }
                            .joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onDelete { offsets in
                    for i in offsets { log.delete(log.games[i].id) }
                }
            } header: {
                Text("Logged")
            }
        }
    }

    private var honestySection: some View {
        Section {
            ForEach(GameTransfer.honestyRules, id: \.self) { rule in
                Text(rule).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("What this can and cannot tell you")
        }
    }
}

// MARK: - Putting a game in

/// One game, entered as lines. A line is "six threes off the catch, two went in", because that is
/// what a person can actually remember afterwards — and it carries exactly as much information as
/// six separate rows would.
struct GameEntryView: View {
    var log: GameLog
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var note = ""
    @State private var lines: [Line] = []

    @State private var zone: GameShotZone = .three
    @State private var kind: GameShotKind = .catchAndShoot
    @State private var contested = false
    @State private var quarter = 0
    @State private var lateGame = false
    @State private var attempts = 1
    @State private var makes = 0

    struct Line: Identifiable {
        var id = UUID()
        var tally: GameShotTally
    }

    var body: some View {
        List {
            Section {
                DatePicker("When", selection: $date, displayedComponents: .date)
                TextField("Against who (optional)", text: $note)
            }
            addSection
            if !lines.isEmpty { linesSection }
            Section {
                Button {
                    save()
                } label: {
                    Label("Save this game", systemImage: "checkmark.circle")
                }
                .disabled(lines.isEmpty)
            } footer: {
                Text("Nothing is compared until you have \(GameTransfer.floor) game shots on the same side as \(GameTransfer.floor) practice shots. Below that the app says how many more it needs rather than drawing a conclusion.")
            }
        }
        .navigationTitle("Log a game")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private var addSection: some View {
        Section {
            Picker("Where from", selection: $zone) {
                ForEach(GameShotZone.allCases) { z in Text(z.name).tag(z) }
            }
            Picker("How it came", selection: $kind) {
                ForEach(GameShotKind.allCases) { k in Text(k.name).tag(k) }
            }
            Toggle("Somebody was contesting", isOn: $contested)
            Stepper("Shots taken: \(attempts)", value: $attempts, in: 1...40)
                .onChange(of: attempts) { _, new in if makes > new { makes = new } }
            Stepper("Went in: \(makes)", value: $makes, in: 0...attempts)
            Picker("Quarter", selection: $quarter) {
                Text("Not sure").tag(0)
                ForEach(1...4, id: \.self) { q in Text("\(q)").tag(q) }
                Text("Overtime").tag(5)
            }
            Toggle("Late and it mattered", isOn: $lateGame)
            Button {
                addLine()
            } label: {
                Label("Add these shots", systemImage: "plus")
            }
        } header: {
            Text("Add a line")
        } footer: {
            Text("Contested and late are your own labels — the app never saw the defender or the clock, so it stores them as your word and says so wherever they are used.")
        }
    }

    private var linesSection: some View {
        Section {
            ForEach(lines) { line in
                Text("\(line.tally.makes) of \(line.tally.attempts) · \(line.tally.zone.name) · \(line.tally.kind.name)\(line.tally.contested ? " · contested" : "")\(line.tally.lateGame ? " · late" : "")")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onDelete { lines.remove(atOffsets: $0) }
        } header: {
            Text("This game so far: \(lines.reduce(0) { $0 + $1.tally.makes }) of \(lines.reduce(0) { $0 + $1.tally.attempts })")
        }
    }

    private func addLine() {
        let tally = GameShotTally(zone: zone, kind: kind, contested: contested,
                                  attempts: attempts, makes: makes,
                                  quarter: quarter == 0 ? nil : quarter, lateGame: lateGame)
        lines.append(Line(tally: tally))
        makes = 0
        attempts = 1
    }

    private func save() {
        log.add(date: date, note: note, tallies: lines.map(\.tally))
        dismiss()
    }
}
