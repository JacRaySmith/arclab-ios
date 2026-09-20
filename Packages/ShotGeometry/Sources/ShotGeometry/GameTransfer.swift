import Foundation

// MARK: - Practice against games
//
// Added 2026-09-19 for 1.4 "game", from: *"There is often a big split between practice shooting and
// game shooting. Try to address this."*
//
// The split is real and has been measured — practice free-throw percentage sat significantly above
// game percentage for one NCAA team across two seasons (Kozar, Vaughn, Lord & Whitfield 1995,
// J Sport Behavior 18(2):123–129, grade B; the magnitude is UNVERIFIED). What is **not** known is
// how big it is for any individual, so the only honest thing the app can do is measure it on the
// shooter and say loudly how few shots it is working from.
//
// Three rules this file exists to enforce (CLAUDE.md rule 1):
//  1. A practice make is **inferred** from the ball at the ring; a game make is **typed from
//     memory**. Two different measurement processes: shown side by side, never pooled.
//  2. Below the floor there is no comparison, only a sentence saying how many more shots it needs.
//  3. Above the floor the verdict is bounded by arithmetic: the smallest difference two counts can
//     tell from chance is computed and printed, and a gap smaller than it is reported as a gap that
//     cannot be told from luck — never as "you shoot worse in games".
//
// Foundation only (CLAUDE.md rule 2).

/// Where a game shot was taken from. The cases that also exist as practice spots carry the
/// `DoctorSpot` they map to, so a comparison is always spot-against-the-same-spot; `atTheRim` maps
/// to nothing on purpose, because ArcLab has never measured a shot at the rim and there is nothing
/// in practice to compare it with.
public enum GameShotZone: String, Sendable, Codable, CaseIterable, Identifiable {
    case atTheRim, freeThrow, elbow, midRange, collegeThree, three, other

    public var id: String { rawValue }

    /// How a person says it.
    public var name: String {
        switch self {
        case .atTheRim: return "At the rim"
        case .freeThrow: return "Free throws"
        case .elbow: return "Elbow"
        case .midRange: return "Mid-range"
        case .collegeThree: return "College three"
        case .three: return "Three"
        case .other: return "Somewhere else"
        }
    }

    /// The practice spot this zone can be compared against, or nil when there is none.
    public var practiceSpot: DoctorSpot? {
        switch self {
        case .atTheRim: return nil
        case .freeThrow: return .freeThrow
        case .elbow: return .elbow
        case .midRange: return .midRange
        case .collegeThree: return .collegeThree
        case .three: return .three
        case .other: return .other
        }
    }

    /// Why a zone cannot be compared, when it cannot. Nil when it can.
    public var noPracticeReason: String? {
        switch self {
        case .atTheRim:
            return "ArcLab has never measured a shot at the rim — it is built around a jump shot with the ring in frame — so there is nothing in your practice to compare these with."
        default:
            return nil
        }
    }
}

/// How the shot came about. Practice blocks carry no label of this kind, which the comparison says
/// out loud rather than quietly matching them up.
public enum GameShotKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case catchAndShoot, offTheDribble, freeThrow

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .catchAndShoot: return "Catch and shoot"
        case .offTheDribble: return "Off the dribble"
        case .freeThrow: return "Free throw"
        }
    }
}

/// One line of a game log: a zone, a kind, open or contested, and how many went in out of how many.
///
/// A line can be one shot (`attempts == 1`) or a whole game's worth of the same kind of shot. Both
/// are the same shape, because "I took six threes off the catch and made two" is exactly as much
/// information as six separate rows and is what a person can actually remember after a game.
public struct GameShotTally: Sendable, Codable, Equatable {
    public var zone: GameShotZone
    public var kind: GameShotKind
    /// True when somebody was close enough to contest. Typed by the shooter; the app never sees it.
    public var contested: Bool
    public var attempts: Int
    public var makes: Int
    /// 1–4, or nil when the shooter did not say. Overtime is 5 and up.
    public var quarter: Int?
    /// The shooter's own mark for "this was late and it mattered". A label, not a measurement.
    public var lateGame: Bool

    public init(zone: GameShotZone, kind: GameShotKind, contested: Bool,
                attempts: Int, makes: Int, quarter: Int? = nil, lateGame: Bool = false) {
        self.zone = zone
        self.kind = kind
        self.contested = contested
        self.attempts = max(0, attempts)
        self.makes = min(max(0, makes), max(0, attempts))
        self.quarter = quarter
        self.lateGame = lateGame
    }
}

/// A count of shots that went in, out of shots whose outcome was known. `unknown` is carried
/// separately and never folded into either: a shot whose outcome was not seen is not half a make.
public struct MakeCount: Sendable, Codable, Equatable {
    public var makes: Int
    public var misses: Int
    /// Practice shots the app tracked but could not resolve at the ring. Always 0 for a game log,
    /// which is typed by a person who knows what happened.
    public var unknown: Int

    public init(makes: Int, misses: Int, unknown: Int = 0) {
        self.makes = max(0, makes)
        self.misses = max(0, misses)
        self.unknown = max(0, unknown)
    }

    public static let none = MakeCount(makes: 0, misses: 0, unknown: 0)

    /// Shots whose outcome is known. This is the n every statement is made from.
    public var n: Int { makes + misses }

    /// Nil at n = 0 rather than 0 %, which would be a claim.
    public var rate: Double? { n == 0 ? nil : Double(makes) / Double(n) }

    public static func + (l: MakeCount, r: MakeCount) -> MakeCount {
        MakeCount(makes: l.makes + r.makes, misses: l.misses + r.misses, unknown: l.unknown + r.unknown)
    }
}

/// One practice-against-game comparison, already decided: either it is below the floor and says how
/// far, or it is above and carries the gap together with the smallest gap those counts could tell.
public struct MakeRateComparison: Sendable, Equatable {
    /// What is being compared — "Three", "Off the dribble", "Everything".
    public var label: String
    public var practice: MakeCount
    public var game: MakeCount
    /// The floor each side had to clear.
    public var floor: Int

    public init(label: String, practice: MakeCount, game: MakeCount, floor: Int = GameTransfer.floor) {
        self.label = label
        self.practice = practice
        self.game = game
        self.floor = floor
    }

    public var practiceRate: Double? { practice.rate }
    public var gameRate: Double? { game.rate }

    /// Practice minus game, in make-rate points (0–1). Nil when either side has nothing.
    public var gap: Double? {
        guard let p = practiceRate, let g = gameRate else { return nil }
        return p - g
    }

    /// The smallest gap these two counts can tell from chance, 0–1. Nil when either side is empty.
    public var smallestTellableGap: Double? {
        GameTransfer.detectableMakeRateDifference(practice: practice, game: game)
    }

    /// True only when both sides cleared the floor.
    public var isAboveFloor: Bool { practice.n >= floor && game.n >= floor }

    /// True when the gap is bigger than the smallest gap the counts can resolve. Nil is
    /// "cannot tell", never "no difference".
    public var gapIsBiggerThanLuck: Bool? {
        guard isAboveFloor, let gap, let smallest = smallestTellableGap else { return nil }
        return abs(gap) > smallest
    }

    /// The whole comparison in one paragraph, in the words a shooter uses. Never a verdict the
    /// counts do not support.
    public var sentence: String {
        guard practice.n >= floor else {
            return "Not enough practice shots to tell (n = \(practice.n), needs \(floor)). A practice make is only counted when the app saw the ball resolve at the ring."
        }
        guard game.n >= floor else {
            return "Not enough game shots to tell (n = \(game.n), needs \(floor)). Log a few more games and the two can be compared."
        }
        guard let p = practiceRate, let g = gameRate, let gap, let smallest = smallestTellableGap else {
            return "There is nothing to compare here yet."
        }
        let head = "In practice you made \(GameTransfer.percent(p)) of n = \(practice.n); in games \(GameTransfer.percent(g)) of n = \(game.n)."
        let size = "That is a gap of \(GameTransfer.points(abs(gap))) \(gap > 0 ? "in practice's favour" : "in the game's favour")."
        if abs(gap) > smallest {
            return "\(head) \(size) At these counts the smallest gap that can be told from chance is \(GameTransfer.points(smallest)), so this one is bigger than luck explains."
        }
        return "\(head) \(size) At these counts the smallest gap that can be told from chance is \(GameTransfer.points(smallest)), so this gap is not yet more than luck."
    }
}

// MARK: - The arithmetic

public enum GameTransfer {

    /// Counted shots needed **on each side** before two make rates are compared at all.
    ///
    /// Reused, not invented: it is `ShotDoctor.attributionFloor`, the count the app already demands
    /// before it will attribute anything at a spot. At 20 a side and rates near half, the smallest
    /// gap distinguishable from chance is about 31 points — which is why the floor is a floor and
    /// not a threshold of usefulness, and why `smallestTellableGap` is printed every time.
    public static let floor = ShotDoctor.attributionFloor

    /// 95 % two-sided z.
    static let z = 1.96

    /// The smallest difference in make rate that these two counts can tell from chance, 0–1.
    ///
    /// A 95 % Wald interval on a difference of two proportions: `z · √(p₁(1−p₁)/n₁ + p₂(1−p₂)/n₂)`.
    /// When either observed rate is 0 or 1 the Wald standard error collapses to something smaller
    /// than the truth — at 3 from 3 it would claim perfect certainty — so the conservative
    /// `p = 0.5` form is used for that side instead. Nil when either side has no resolved shots.
    public static func detectableMakeRateDifference(practice: MakeCount, game: MakeCount) -> Double? {
        guard let a = variance(of: practice), let b = variance(of: game) else { return nil }
        return z * (a + b).squareRoot()
    }

    /// Same thing from two plain counts, for callers that do not have a `MakeCount`.
    public static func detectableMakeRateDifference(nPractice: Int, pPractice: Double,
                                                    nGame: Int, pGame: Double) -> Double? {
        guard nPractice > 0, nGame > 0 else { return nil }
        let a = variance(n: nPractice, p: pPractice)
        let b = variance(n: nGame, p: pGame)
        return z * (a + b).squareRoot()
    }

    private static func variance(of c: MakeCount) -> Double? {
        guard c.n > 0, let p = c.rate else { return nil }
        return variance(n: c.n, p: p)
    }

    private static func variance(n: Int, p: Double) -> Double {
        // A rate of 0 or 1 is not evidence of certainty at these counts; fall back to the widest
        // case rather than printing a difference the data cannot support.
        let pp = (p <= 0 || p >= 1) ? 0.5 : p
        return pp * (1 - pp) / Double(n)
    }

    /// "42 %" — a make rate as a person says it.
    public static func percent(_ rate: Double) -> String {
        "\(Int((rate * 100).rounded())) %"
    }

    /// "14 points" — a difference of two rates, in percentage points.
    public static func points(_ difference: Double) -> String {
        let n = Int((difference * 100).rounded())
        return "\(n) point\(n == 1 ? "" : "s")"
    }

    // MARK: Building the comparisons

    /// Totals from a game log, filtered however the caller wants.
    public static func total(_ tallies: [GameShotTally]) -> MakeCount {
        tallies.reduce(MakeCount.none) { acc, t in
            acc + MakeCount(makes: t.makes, misses: max(0, t.attempts - t.makes))
        }
    }

    /// Practice against games, everything pooled. Zones are pooled here on purpose and the label
    /// says so: it is the one comparison that reaches the floor first.
    public static func overall(practice: MakeCount, game: [GameShotTally]) -> MakeRateComparison {
        MakeRateComparison(label: "Everything", practice: practice, game: total(game))
    }

    /// One comparison per zone that has a practice spot behind it, near to far. Zones with no
    /// practice spot (`atTheRim`) are left out — the caller shows them with `noPracticeReason`.
    public static func byZone(practiceBySpot: [DoctorSpot: MakeCount],
                              game: [GameShotTally]) -> [MakeRateComparison] {
        let zones = GameShotZone.allCases.filter { $0.practiceSpot != nil }
        return zones
            .sorted { ($0.practiceSpot?.order ?? 99) < ($1.practiceSpot?.order ?? 99) }
            .compactMap { zone -> MakeRateComparison? in
                guard let spot = zone.practiceSpot else { return nil }
                let g = total(game.filter { $0.zone == zone })
                let p = practiceBySpot[spot] ?? .none
                guard g.n > 0 || p.n > 0 else { return nil }
                return MakeRateComparison(label: zone.name, practice: p, game: g)
            }
    }

    /// Game-only splits: catch-and-shoot against off the dribble, open against contested.
    ///
    /// These are **not** practice-against-game comparisons and the type says so by not being one.
    /// A practice block carries no label for how the shot came about or whether anybody was near it,
    /// so there is nothing on the practice side to line them up with.
    public struct GameSplit: Sendable, Equatable {
        public var label: String
        public var left: (name: String, count: MakeCount)
        public var right: (name: String, count: MakeCount)
        public var floor: Int

        public var isAboveFloor: Bool { left.count.n >= floor && right.count.n >= floor }

        /// The smallest gap these two counts can tell from chance, 0–1.
        public var smallestTellableGap: Double? {
            GameTransfer.detectableMakeRateDifference(practice: left.count, game: right.count)
        }

        public var sentence: String {
            guard let l = left.count.rate, let r = right.count.rate, let smallest = smallestTellableGap else {
                return "Nothing logged for one of these yet."
            }
            let head = "\(left.name): \(GameTransfer.percent(l)) of n = \(left.count.n). \(right.name): \(GameTransfer.percent(r)) of n = \(right.count.n)."
            guard isAboveFloor else {
                return "\(head) Not enough game shots to tell (needs \(floor) of each)."
            }
            let gap = abs(l - r)
            return abs(l - r) > smallest
                ? "\(head) The \(GameTransfer.points(gap)) between them is bigger than the \(GameTransfer.points(smallest)) these counts could put down to luck."
                : "\(head) The \(GameTransfer.points(gap)) between them is inside the \(GameTransfer.points(smallest)) these counts could put down to luck."
        }

        public static func == (l: GameSplit, r: GameSplit) -> Bool {
            l.label == r.label && l.left.name == r.left.name && l.left.count == r.left.count
                && l.right.name == r.right.name && l.right.count == r.right.count && l.floor == r.floor
        }
    }

    /// Catch-and-shoot against off the dribble, and open against contested — both game-only.
    public static func gameSplits(_ game: [GameShotTally]) -> [GameSplit] {
        var out: [GameSplit] = []
        let catchAndShoot = total(game.filter { $0.kind == .catchAndShoot })
        let offDribble = total(game.filter { $0.kind == .offTheDribble })
        if catchAndShoot.n > 0 || offDribble.n > 0 {
            out.append(GameSplit(label: "How the shot came about",
                                 left: (GameShotKind.catchAndShoot.name, catchAndShoot),
                                 right: (GameShotKind.offTheDribble.name, offDribble),
                                 floor: floor))
        }
        // Free throws sit in neither column: they are their own kind, and mixing them in would move
        // whichever column they landed in for a reason that has nothing to do with the dribble.
        let open = total(game.filter { !$0.contested && $0.kind != .freeThrow })
        let contested = total(game.filter { $0.contested && $0.kind != .freeThrow })
        if open.n > 0 || contested.n > 0 {
            out.append(GameSplit(label: "Open or contested",
                                 left: ("Open", open), right: ("Contested", contested), floor: floor))
        }
        return out
    }

    // MARK: What the shooter is told about all of this

    /// Shown with every comparison. These are the limits, not small print.
    public static let honestyRules: [String] = [
        "A practice make is the app watching the ball go through the ring. A game make is you remembering. They are two different ways of counting, so they sit side by side and are never added together.",
        "Nothing is compared below \(floor) counted shots on each side, and even above it the app prints the smallest gap those counts could tell from chance — a gap smaller than that is reported as exactly that.",
        "Shooting better in practice than in games is a real finding, but only for the direction: one college team shot significantly better at the line in practice than in games across two seasons (grade B), and how big the gap is for any one player has never been published.",
        "There are no streaks here. A run of makes is what a coin does too, and the counts in a game log are far too small to tell the two apart.",
        "The app cannot see a defender, a clock or a score. Contested, late and off-the-dribble are labels you type, and everything built on them is only as good as your memory of the game.",
    ]
}
