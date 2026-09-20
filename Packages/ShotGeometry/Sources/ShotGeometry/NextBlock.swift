import Foundation

/// What to shoot **next**, decided from what the block just shot actually measured.
///
/// A practice day is a sequence, not one block: when a block is scored, this table says which block
/// comes after it, why (which number, from how many shots, and the grade of the rule behind it), and
/// what the extra shots will let the app tell. It never returns "nothing": when the day's cap is
/// reached it returns the same shape with `dayDoneReason` set and the plan becomes tomorrow's first
/// block.
///
/// Pure: Foundation only, no store, no view, no clock. Everything it knows arrives in
/// `NextBlockState`, which is why the table can be tested on its own (`NextBlockTests`).
///
/// Honesty (CLAUDE.md rule 1) shapes the copy as much as the rules do. A measure that could not be
/// computed is quoted with the reason the scorer gave, never replaced by a guess; a check below its
/// shot floor is "not enough shots to tell", never a fail; and the only number this file invents is
/// the count of shots it is asking for, which is arithmetic on the floor the check itself published.
public enum NextBlock {

    // MARK: - What a block can be

    /// The three block roles a proposal can take. Same spelling as the app's own role so a proposal
    /// turns into an ordinary practice block rather than a second block model.
    public enum Role: String, Sendable, Codable, Equatable, CaseIterable {
        case baseline, drill, retention
    }

    /// Why this block was proposed. Logged, never shown: the sentences are what the shooter reads.
    public enum ReasonKey: String, Sendable, Codable, Equatable {
        /// Nothing is saved at all yet.
        case firstBlock
        /// A plan exists and the day has not started.
        case startOfDay
        /// A warm-up baseline produced the number; the drill is what should move it.
        case baselineToDrill
        /// The baseline carried no number, so the reference does not exist yet.
        case baselineNeedsShots
        /// The check ran but the shot count was under its floor.
        case notEnoughShots
        /// The block produced no value for the measure at all, and said why.
        case measureUnavailable
        /// The check ran and the number did not move.
        case measureFlat
        /// The spread widens with distance, so the next block is a step-in block farther out.
        case rangeExtension
        /// The number moved and the drill's ladder still has a spot left today.
        case ladderNextSpot
        /// The number moved and the ladder is done: take the cue away and see what is left.
        case drillMovedToRetention
        /// An un-cued block kept the change.
        case retentionHeld
        /// The change went when the cue went.
        case retentionNotHeld
        /// The last block came from a Learn module, which is scored on its own gate.
        case afterLearnBlock
        /// There is a plan, but the session it was measured against is gone, so nothing can be scored.
        case planNeedsNewBaseline
        /// No plan yet: more shots at one spot is what makes a finding possible.
        case noPlanMoreShots
        /// The last block was shot under a game-like condition, which the plan's check cannot read.
        case afterGameLikeBlock
        // Added 2026-09-19 (1.4 "game"). These four are never the main proposal: they arrive as
        // `Decision.alternatives` once a change has been measured, because a change that only
        // exists in an empty gym has not been shown to exist anywhere else.
        case gameLikeRandomSpot
        case gameLikeDecisionCalled
        case gameLikeFatigued
        case gameLikeContested
    }

    // MARK: - Game-like block variants
    //
    // Added 2026-09-19 for 1.4 "game": *"There is often a big split between practice shooting and
    // game shooting."* Research: `docs/research/ball-handling-and-transfer-2026-09-19.md`.
    //
    // Each variant puts one condition of a game on the ordinary block. The app records exactly the
    // same shot numbers it always does — it cannot see a defender, a clock or a score — and each
    // variant carries that limit in its own words rather than in a footnote.

    public enum GameLikeVariant: String, Sendable, Codable, Equatable, CaseIterable, Identifiable {
        /// Spots shuffled, in an order the app generated and therefore knows.
        ///
        /// It shuffles **sets**, not single shots, and that is a limit rather than a preference: a
        /// recording is saved at one spot, and the brief's own rule is that shots from different
        /// spots are different populations and are never pooled. One shot at each of four spots in
        /// one clip would have to label all four with one spot, which would be a made-up number.
        case randomSpot
        /// A partner calls catch-and-shoot, one-dribble pull-up or drive at the moment of the catch.
        case decisionCalled
        /// After a 60–90 s conditioning bout, stated as such.
        case fatigued
        /// A partner closes out with a hand up.
        case contested

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .randomSpot: return "Shuffled spots"
            case .decisionCalled: return "Called on the catch"
            case .fatigued: return "Straight after running"
            case .contested: return "With a hand up"
            }
        }

        /// The grade of the evidence that **this condition is worth practising in**.
        public var grade: ShotEvidenceGrade {
            switch self {
            case .randomSpot: return .b        // Shamshiri 2025, Shoenfelt 2002 — randomised, novices
            case .decisionCalled: return .c    // constraints-led consensus; no mechanics outcome
            case .fatigued: return .a          // Bourdas 2024, Li 2025 meta; Slawinski 2018 the exception
            case .contested: return .c         // A for the measure, D for the closeout standing in for a defender
            }
        }

        /// What the block cannot see. Shown with the block, never hidden behind a disclosure.
        public var limit: String {
            switch self {
            case .randomSpot:
                return "The app measures the same shot numbers as any other block, and it knows the order because it made it. It shuffles sets rather than single shots: one clip is saved at one spot, and shots from different spots are never mixed into one number."
            case .decisionCalled:
                return "The app cannot hear the call. If you type in what was called it will store your word for it; it never measures the decision."
            case .fatigued:
                return "The app cannot tell that you ran. It compares this block with your fresh ones and nothing more, so the running has to have actually happened."
            case .contested:
                return "The app cannot see your partner. A contested block and an open block look identical to it, so which was which is your word."
            }
        }

        public var source: String {
            switch self {
            case .randomSpot:
                return "Shamshiri et al. 2025 (84 novice females, randomised, 3 days): practising in one condition scored best during practice and worst on the test afterwards. Shoenfelt et al. 2002 (94 participants, 3 weeks): varied practice equalled constant on the delayed test. Grade B — novices, short studies."
            case .decisionCalled:
                return "Constraints-led coaching consensus; the nearest study is quasi-experimental with no shooting-mechanics outcome (grade C). Shamshiri et al. 2025 is the randomised evidence for shuffling, one step removed from deciding."
            case .fatigued:
                return "Bourdas et al. 2024: after 12 min of simulated game load in 38 high-level players, makes −14 to −19 %, entry angle −3.1 to −3.9 %. Li et al. 2025 meta, 14 studies, n = 388. Slawinski et al. 2018 found no change in elite U18s, which is why it is measured on you rather than assumed."
            case .contested:
                return "Daly-Grafstein & Bornn 2020 (>50 000 tracked NBA shots): tight contests biased shots short and raised depth spread 56 % and left-right spread 38 % without moving the technique. Amaro et al. 2025: no significant effect of a defender or 105 dBA noise on release in 18 national-level players. That a partner's closeout resembles a game defender is untested."
            }
        }
    }

    /// One proposed block: what to shoot, why, and what it buys.
    public struct Plan: Sendable, Equatable {
        public var reasonKey: ReasonKey
        public var role: Role
        public var spot: DoctorSpot
        public var shots: Int
        /// What to do, in a sentence or two.
        public var instruction: String
        /// The one line of why: which number, how many shots it came from, and the grade.
        public var reason: String
        /// What the app will be able to tell once this block is in.
        public var whatItBuys: String
        /// Whether the block carries the plan's cue. Baseline and retention blocks never do.
        public var cued: Bool
        /// The game-like condition this block is shot under, when it is one. Nil for every ordinary
        /// block, which is every block the table proposes as its main answer.
        public var gameLike: GameLikeVariant?
        /// For `randomSpot` only: the order the app generated, one entry per shot. Empty otherwise.
        /// It is in the plan rather than left to the shooter because the app can only claim to know
        /// the sequence if it is the thing that made it.
        public var spotSequence: [DoctorSpot]

        public init(reasonKey: ReasonKey, role: Role, spot: DoctorSpot, shots: Int,
                    instruction: String, reason: String, whatItBuys: String, cued: Bool,
                    gameLike: GameLikeVariant? = nil, spotSequence: [DoctorSpot] = []) {
            self.reasonKey = reasonKey
            self.role = role
            self.spot = spot
            self.shots = shots
            self.instruction = instruction
            self.reason = reason
            self.whatItBuys = whatItBuys
            self.cued = cued
            self.gameLike = gameLike
            self.spotSequence = spotSequence
        }
    }

    /// There is always a plan. `dayDoneReason` says the plan is for tomorrow rather than for now.
    public struct Decision: Sendable, Equatable {
        public var plan: Plan
        /// Nil while the day is still open.
        public var dayDoneReason: String?
        /// Game-like blocks offered **alongside** `plan`, never instead of it (added 2026-09-19).
        /// Empty until a change has actually been measured: offering game-like practice before the
        /// change exists would be asking a shooter to carry something they have not got yet.
        public var alternatives: [Plan]
        public var isToday: Bool { dayDoneReason == nil }

        public init(plan: Plan, dayDoneReason: String? = nil, alternatives: [Plan] = []) {
            self.plan = plan
            self.dayDoneReason = dayDoneReason
            self.alternatives = alternatives
        }
    }

    /// How much ArcLab will ask for in one day.
    ///
    /// These two numbers are a **convention**, not a research finding: no study in
    /// `docs/research/healthy-shot-model-2026-09-14.md` gives a shots-per-day limit for one shooter.
    /// What the research does say (grade A) is that tiredness changes the shot for some players and
    /// not others, so the honest cap is one that is stated as a choice and can be raised.
    public struct Cap: Sendable, Equatable {
        public var blocks: Int
        public var shots: Int

        public init(blocks: Int, shots: Int) {
            self.blocks = blocks
            self.shots = shots
        }

        public static let `default` = Cap(blocks: 8, shots: 100)
    }

    /// The block that was just scored.
    public struct LastBlock: Sendable, Equatable {
        public var role: Role
        public var spot: DoctorSpot
        /// Counted (accepted) shots in the block, when the block produced any.
        public var countedShots: Int?
        public var measureValue: Double?
        public var measureN: Int?
        /// The scorer's own sentence when the measure could not be computed.
        public var measureUnavailableReason: String?
        /// False for a block that is not scored against anything (a first baseline).
        public var hasCheck: Bool
        /// Nil is "not enough shots to tell", never a fail.
        public var checkPassed: Bool?
        public var checkBaselineValue: Double?
        public var checkTarget: Double?
        /// A block started from a Learn module is scored on that module's gate, not on the plan.
        public var fromLearnModule: Bool
        /// Set when the block was shot under a game-like condition (added 2026-09-19). Such a block
        /// is never scored against the plan's baseline — the baseline was not shot tired, shuffled
        /// or with a hand in the shooter's face, so the check would report the condition as a
        /// failure of the fix.
        public var gameLike: GameLikeVariant?

        public init(role: Role, spot: DoctorSpot, countedShots: Int? = nil,
                    measureValue: Double? = nil, measureN: Int? = nil,
                    measureUnavailableReason: String? = nil, hasCheck: Bool = false,
                    checkPassed: Bool? = nil, checkBaselineValue: Double? = nil,
                    checkTarget: Double? = nil, fromLearnModule: Bool = false,
                    gameLike: GameLikeVariant? = nil) {
            self.role = role
            self.spot = spot
            self.countedShots = countedShots
            self.measureValue = measureValue
            self.measureN = measureN
            self.measureUnavailableReason = measureUnavailableReason
            self.hasCheck = hasCheck
            self.checkPassed = checkPassed
            self.checkBaselineValue = checkBaselineValue
            self.checkTarget = checkTarget
            self.fromLearnModule = fromLearnModule
            self.gameLike = gameLike
        }
    }

    /// Everything the table is allowed to know.
    public struct State: Sendable {
        /// Nil when no block has been scored today.
        public var last: LastBlock?
        public var hasPlan: Bool
        /// A plan can exist with its baseline session deleted; then there is nothing to score against.
        public var hasBaseline: Bool
        public var planSpot: DoctorSpot
        /// The measure in a shooter's words, e.g. "release-speed spread (SD)".
        public var measureName: String
        public var measureUnit: String
        public var measureDecimals: Int
        /// The grade of the evidence that this measure matters.
        public var grade: ShotEvidenceGrade
        /// The check's own shot floor.
        public var minimumN: Int
        /// True when the target is "narrower than before", so a detectable ratio can be quoted.
        public var targetNarrowsSpread: Bool
        public var drillName: String
        public var drillReps: Int
        /// The fix's own ladder of spots. Empty means "wherever the finding was".
        public var drillLadder: [DoctorSpot]
        public var spotsDoneToday: [DoctorSpot]
        public var blocksDoneToday: Int
        public var shotsToday: Int
        /// True when the diagnosis says release-speed spread widens with distance (grade A), nil when
        /// it has not been measured — never assumed either way.
        public var spreadWidensWithDistance: Bool?
        public var cap: Cap

        public init(last: LastBlock? = nil, hasPlan: Bool, hasBaseline: Bool, planSpot: DoctorSpot,
                    measureName: String, measureUnit: String, measureDecimals: Int,
                    grade: ShotEvidenceGrade, minimumN: Int, targetNarrowsSpread: Bool,
                    drillName: String, drillReps: Int, drillLadder: [DoctorSpot],
                    spotsDoneToday: [DoctorSpot], blocksDoneToday: Int, shotsToday: Int,
                    spreadWidensWithDistance: Bool?, cap: Cap = .default) {
            self.last = last
            self.hasPlan = hasPlan
            self.hasBaseline = hasBaseline
            self.planSpot = planSpot
            self.measureName = measureName
            self.measureUnit = measureUnit
            self.measureDecimals = measureDecimals
            self.grade = grade
            self.minimumN = minimumN
            self.targetNarrowsSpread = targetNarrowsSpread
            self.drillName = drillName
            self.drillReps = drillReps
            self.drillLadder = drillLadder
            self.spotsDoneToday = spotsDoneToday
            self.blocksDoneToday = blocksDoneToday
            self.shotsToday = shotsToday
            self.spreadWidensWithDistance = spreadWidensWithDistance
            self.cap = cap
        }
    }

    // MARK: - The ladder

    /// Near to far. `.other` is not on it: a spot with no distance cannot be stepped out from.
    public static let distanceLadder: [DoctorSpot] = [.freeThrow, .elbow, .midRange, .collegeThree, .three]

    /// One step farther from the ring, or nil when there is nowhere farther to go.
    public static func stepOut(from spot: DoctorSpot) -> DoctorSpot? {
        guard let i = distanceLadder.firstIndex(of: spot), i + 1 < distanceLadder.count else { return nil }
        return distanceLadder[i + 1]
    }

    // MARK: - The table

    /// The next block. Never nil: when the cap is reached the same plan comes back as tomorrow's.
    public static func decide(_ s: State) -> Decision {
        let (plan, endsDay) = propose(s)
        if s.blocksDoneToday >= s.cap.blocks || s.shotsToday >= s.cap.shots {
            // The cap is the cap: no alternatives are offered on top of a day that is over.
            return Decision(plan: plan, dayDoneReason: capReason(s))
        }
        let extras = gameLikeVariants(s)
        if let endsDay { return Decision(plan: plan, dayDoneReason: endsDay, alternatives: extras) }
        return Decision(plan: plan, alternatives: extras)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func propose(_ s: State) -> (Plan, String?) {
        guard let last = s.last else { return (openingBlock(s), nil) }

        // A plan whose reference session has been deleted cannot score anything, whatever was just
        // shot. Say that once, here, rather than letting every row below quote a missing number.
        if s.hasPlan, !s.hasBaseline { return (planNeedsNewBaseline(s, last), nil) }

        if last.fromLearnModule { return (afterLearnBlock(s, last), nil) }

        // A block shot tired, shuffled or with a hand up is not a block the plan's check can read:
        // the baseline it would be scored against was shot in none of those conditions. What it
        // needs is its own comparison — the ordinary version of the same block, the same day.
        if let variant = last.gameLike { return (afterGameLikeBlock(s, last, variant: variant), nil) }

        switch last.role {
        case .baseline:
            // With no plan there is no measure for the block to be missing, so the shot count — not
            // a missing number — is what decides the next block.
            guard s.hasPlan else { return (noPlanMoreShots(s, last), nil) }
            if last.measureValue == nil { return (baselineNeedsShots(s, last), nil) }
            return (baselineToDrill(s, last), nil)

        case .drill:
            if last.measureValue == nil, last.measureUnavailableReason != nil {
                return (measureUnavailable(s, last), nil)
            }
            if last.hasCheck, last.checkPassed == nil, let n = last.measureN, n < s.minimumN {
                return (notEnoughShots(s, last), nil)
            }
            if last.checkPassed == false {
                if s.spreadWidensWithDistance == true, let farther = stepOut(from: widest(s, last)) {
                    return (rangeExtension(s, last, spot: farther), nil)
                }
                return (measureFlat(s, last), nil)
            }
            if last.checkPassed == true {
                if let spot = nextLadderSpot(s) { return (ladderNextSpot(s, last, spot: spot), nil) }
                return (drillToRetention(s, last), nil)
            }
            // A drill block with no check at all (no plan, or no baseline to score against).
            return (measureUnavailable(s, last), nil)

        case .retention:
            if last.checkPassed == true {
                if let farther = stepOut(from: s.planSpot), !s.spotsDoneToday.contains(farther) {
                    return (afterRetentionHeld(s, last, spot: farther), nil)
                }
                return (retentionHeldDayDone(s, last))
            }
            if last.checkPassed == false { return (retentionNotHeld(s, last), nil) }
            return (notEnoughShots(s, last), nil)
        }
    }

    // MARK: - Each row of the table

    private static func openingBlock(_ s: State) -> Plan {
        guard s.hasPlan else {
            return Plan(reasonKey: .firstBlock, role: .baseline, spot: s.planSpot, shots: 10,
                        instruction: "Ten shots at \(s.planSpot.rawValue), your normal routine. No cue, nothing to change.",
                        reason: "Nothing is saved to compare against yet, so there is no number to move.",
                        whatItBuys: "One block at one spot is what every later block is read against. ArcLab needs \(ShotDoctor.attributionFloor) counted shots at a spot before it will say where your spread comes from.",
                        cued: false)
        }
        guard s.hasBaseline else {
            return Plan(reasonKey: .planNeedsNewBaseline, role: .baseline, spot: s.planSpot, shots: 10,
                        instruction: "Ten shots at \(s.planSpot.rawValue), your normal routine and no cue.",
                        reason: "Your plan is scored on \(s.measureName) at \(s.planSpot.rawValue), but the session it was measured against is gone, so there is nothing to score against today.",
                        whatItBuys: "An un-cued block becomes the new reference. Start the plan again from it and the check has something to read the next block against.",
                        cued: false)
        }
        let spot = s.drillLadder.first ?? s.planSpot
        return Plan(reasonKey: .startOfDay, role: .drill, spot: spot, shots: max(1, s.drillReps),
                    instruction: "\(s.drillName): \(max(1, s.drillReps)) shots at \(spot.rawValue), with the cue on every shot.",
                    reason: "Your plan is scored on \(s.measureName) at \(s.planSpot.rawValue) (evidence grade \(s.grade.letter)). This is the block that is meant to move it.",
                    whatItBuys: "A drill block gives the check something to compare with your baseline, so today can say whether anything changed.",
                    cued: true)
    }

    /// The plan exists but its reference session has been deleted. Keep shooting the drill — the
    /// blocks are still saved — and say plainly that nothing can be scored until the plan is started
    /// again from a session that still exists.
    private static func planNeedsNewBaseline(_ s: State, _ last: LastBlock) -> Plan {
        let reps = max(1, s.drillReps)
        return Plan(reasonKey: .planNeedsNewBaseline, role: .drill, spot: s.planSpot, shots: reps,
                    instruction: "\(s.drillName): \(reps) shots at \(s.planSpot.rawValue), with the cue on every shot.",
                    reason: "Your plan is scored on \(s.measureName) at \(s.planSpot.rawValue), and the session it was measured against is gone — so nothing shot today can be scored against it yet. The block you just shot at \(last.spot.rawValue) is saved all the same.",
                    whatItBuys: "This block saves another set at \(s.planSpot.rawValue). To get the scoring back, start the plan again: it takes its reference from your newest saved block at that spot.",
                    cued: true)
    }

    private static func afterLearnBlock(_ s: State, _ last: LastBlock) -> Plan {
        guard s.hasPlan, s.hasBaseline else {
            return Plan(reasonKey: .noPlanMoreShots, role: .baseline, spot: last.spot, shots: 10,
                        instruction: "Ten shots at \(last.spot.rawValue), your normal routine and no cue.",
                        reason: "That block came from a Learn drill, so it was scored on that module's own gate. There is no plan running to score it against.",
                        whatItBuys: "Un-cued shots at one spot are what a plan gets picked from.",
                        cued: false)
        }
        let spot = s.drillLadder.first ?? s.planSpot
        return Plan(reasonKey: .afterLearnBlock, role: .drill, spot: spot, shots: max(1, s.drillReps),
                    instruction: "\(s.drillName): \(max(1, s.drillReps)) shots at \(spot.rawValue), with the cue on every shot.",
                    reason: "That block came from a Learn drill and was scored on the module's own gate, not on \(s.measureName).",
                    whatItBuys: "A block at \(s.planSpot.rawValue) with the plan's cue is the one that can move \(s.measureName) (grade \(s.grade.letter)).",
                    cued: true)
    }

    /// After a game-like block: the ordinary version of it, un-cued, same spot, same day.
    ///
    /// Without that comparison the game-like block says nothing at all — a number from a tired block
    /// is only interesting beside a number from a fresh one, and comparing it with a block shot last
    /// week compares two days as much as two conditions.
    private static func afterGameLikeBlock(_ s: State, _ last: LastBlock, variant: GameLikeVariant) -> Plan {
        let value = last.measureValue.map { number($0, s) } ?? "no number"
        let n = last.measureN ?? last.countedShots ?? 0
        return Plan(reasonKey: .afterGameLikeBlock, role: .baseline, spot: last.spot, shots: 10,
                    instruction: "Ten shots at \(last.spot.rawValue), ordinary: no cue, nobody in the way, no running first.",
                    reason: "That block was shot \(variant.title.lowercased()), which your plan's reference block was not — so it is not scored against the plan. It came out at \(s.measureName) \(value) at n = \(n). \(variant.limit)",
                    whatItBuys: "An ordinary block at the same spot on the same day is the only fair comparison for it. Compared with a block from another day, what you would be measuring is mostly the difference between two days.",
                    cued: false)
    }

    private static func baselineNeedsShots(_ s: State, _ last: LastBlock) -> Plan {
        let why = last.measureUnavailableReason
            ?? "That block produced no \(s.measureName), so there is no reference number yet."
        return Plan(reasonKey: .baselineNeedsShots, role: .baseline, spot: last.spot, shots: 10,
                    instruction: "Ten more shots at \(last.spot.rawValue), same as the last block: normal routine, no cue.",
                    reason: why,
                    whatItBuys: "Ten more counted shots at \(last.spot.rawValue) and the number exists. Until it does, nothing today can be scored against it.",
                    cued: false)
    }

    private static func baselineToDrill(_ s: State, _ last: LastBlock) -> Plan {
        let spot = s.drillLadder.first ?? s.planSpot
        let value = last.measureValue.map { number($0, s) } ?? "no number"
        let n = last.measureN.map { "n = \($0)" } ?? "an unknown number of counted shots"
        return Plan(reasonKey: .baselineToDrill, role: .drill, spot: spot, shots: max(1, s.drillReps),
                    instruction: "\(s.drillName): \(max(1, s.drillReps)) shots at \(spot.rawValue), with the cue on every shot.",
                    reason: "Your warm-up at \(last.spot.rawValue) came out at \(s.measureName) \(value), \(n). That is the number this drill is meant to move (grade \(s.grade.letter)).",
                    whatItBuys: "The drill block is the one the check reads against your warm-up, so it is what tells you whether the cue changed anything today.",
                    cued: true)
    }

    private static func noPlanMoreShots(_ s: State, _ last: LastBlock) -> Plan {
        let n = last.measureN ?? last.countedShots ?? 0
        let short = max(0, ShotDoctor.attributionFloor - n)
        return Plan(reasonKey: .noPlanMoreShots, role: .baseline, spot: last.spot, shots: max(5, roundUpToFive(short)),
                    instruction: "\(max(5, roundUpToFive(short))) more shots at \(last.spot.rawValue), normal routine and no cue.",
                    reason: "No plan is running yet, and you have n = \(n) counted shots at \(last.spot.rawValue).",
                    whatItBuys: short > 0
                        ? "ArcLab needs \(ShotDoctor.attributionFloor) counted shots at one spot before it will say where your spread comes from, so about \(short) more gets you there."
                        : "You are past the \(ShotDoctor.attributionFloor)-shot floor at this spot, so you can ask about your shot and start a plan from it.",
                    cued: false)
    }

    private static func notEnoughShots(_ s: State, _ last: LastBlock) -> Plan {
        let n = last.measureN ?? last.countedShots ?? 0
        let short = max(5, roundUpToFive(max(0, s.minimumN - n)))
        let value = last.measureValue.map { " came out at \(number($0, s))" } ?? " has no number yet"
        var buys = "\(short) more at \(last.spot.rawValue) takes you to about n = \(n + short) if every shot counts, which is what the check needs."
        if s.targetNarrowsSpread, let ratio = DoctorStats.detectableSDRatio(n: n + short) {
            buys += String(format: " At n = %d the smallest narrowing ArcLab can honestly see is %.2f×; smaller than that and it would be reading noise.", n + short, ratio)
        }
        return Plan(reasonKey: .notEnoughShots, role: last.role, spot: last.spot, shots: short,
                    instruction: "\(short) more shots at \(last.spot.rawValue), exactly like the last block.",
                    reason: "\(s.measureName)\(value) from only n = \(n) counted shots, and the check needs \(s.minimumN). That is not enough shots to tell — it is not a fail.",
                    whatItBuys: buys,
                    cued: last.role == .drill)
    }

    private static func measureUnavailable(_ s: State, _ last: LastBlock) -> Plan {
        let why = last.measureUnavailableReason
            ?? "That block carries no \(s.measureName), so there is nothing for the check to read."
        return Plan(reasonKey: .measureUnavailable, role: last.role, spot: last.spot, shots: max(1, s.drillReps),
                    instruction: "Shoot that block again at \(last.spot.rawValue): \(max(1, s.drillReps)) shots, same cue, phone in the same place.",
                    reason: why,
                    whatItBuys: "A block ArcLab can measure is the only kind it can score. Same spot and the same camera position is what makes the two blocks comparable.",
                    cued: last.role == .drill)
    }

    private static func measureFlat(_ s: State, _ last: LastBlock) -> Plan {
        let from = last.checkBaselineValue.map { number($0, s) } ?? "the baseline"
        let to = last.measureValue.map { number($0, s) } ?? "no number"
        let target = last.checkTarget.map { " against a target of \(number($0, s))" } ?? ""
        let n = last.measureN ?? last.countedShots ?? 0
        return Plan(reasonKey: .measureFlat, role: .drill, spot: last.spot, shots: max(1, s.drillReps),
                    instruction: "One more set of \(max(1, s.drillReps)) at \(last.spot.rawValue), same cue.",
                    reason: "\(s.measureName) went \(from) → \(to)\(target) at n = \(n): not there yet. One set is not a verdict.",
                    whatItBuys: "A second set at the same spot roughly doubles the shots behind the number, so a real change stops looking like noise and noise stops looking like a change.",
                    cued: true)
    }

    private static func rangeExtension(_ s: State, _ last: LastBlock, spot: DoctorSpot) -> Plan {
        let reps = max(1, s.drillReps)
        return Plan(reasonKey: .rangeExtension, role: .drill, spot: spot, shots: reps,
                    instruction: "Step-in range: \(reps) shots at \(spot.rawValue). Start a step behind, step into the shot and let your legs give the extra distance. Shoot a few standing still afterwards so the two can be compared.",
                    reason: "Your release-speed spread gets wider the farther out you go, and \(s.measureName) did not move at \(last.spot.rawValue) today. A spread that stays the same at every distance is the measured mark of a versatile shooter (grade A).",
                    whatItBuys: "Shooting near and far on the same day gives ArcLab both ends of the ladder at once, which is what it needs before it can say the widening is real and not two different days.",
                    cued: true)
    }

    private static func ladderNextSpot(_ s: State, _ last: LastBlock, spot: DoctorSpot) -> Plan {
        let from = last.checkBaselineValue.map { number($0, s) } ?? "the baseline"
        let to = last.measureValue.map { number($0, s) } ?? "no number"
        let n = last.measureN ?? last.countedShots ?? 0
        return Plan(reasonKey: .ladderNextSpot, role: .drill, spot: spot, shots: max(1, s.drillReps),
                    instruction: "\(s.drillName), next step: \(max(1, s.drillReps)) shots at \(spot.rawValue), same cue.",
                    reason: "\(s.measureName) hit its target at \(last.spot.rawValue): \(from) → \(to) at n = \(n) (grade \(s.grade.letter)).",
                    whatItBuys: "The same cue one step farther out shows whether the change travels with you or only works at one distance.",
                    cued: true)
    }

    private static func drillToRetention(_ s: State, _ last: LastBlock) -> Plan {
        let to = last.measureValue.map { number($0, s) } ?? "no number"
        let n = last.measureN ?? last.countedShots ?? 0
        return Plan(reasonKey: .drillMovedToRetention, role: .retention, spot: s.planSpot, shots: 10,
                    instruction: "Ten shots at \(s.planSpot.rawValue) with no cue at all. Normal routine, nothing to think about.",
                    reason: "\(s.measureName) hit its target at \(last.spot.rawValue): \(to) at n = \(n) (grade \(s.grade.letter)). A cued block on its own only shows the cue works.",
                    whatItBuys: "Ten un-cued shots say how much of the change is yours once the cue is gone. It only counts as learned if it is still there on another day.",
                    cued: false)
    }

    private static func afterRetentionHeld(_ s: State, _ last: LastBlock, spot: DoctorSpot) -> Plan {
        let to = last.measureValue.map { number($0, s) } ?? "no number"
        let n = last.measureN ?? last.countedShots ?? 0
        return Plan(reasonKey: .retentionHeld, role: .drill, spot: spot, shots: max(1, s.drillReps),
                    instruction: "\(max(1, s.drillReps)) shots at \(spot.rawValue), one step farther out, cue back on.",
                    reason: "With the cue taken away \(s.measureName) was still \(to) at n = \(n), so the change survived at \(last.spot.rawValue) (grade \(s.grade.letter)).",
                    whatItBuys: "A farther spot is the next real test: it shows whether what you just learned holds when the shot needs more power.",
                    cued: true)
    }

    private static func retentionHeldDayDone(_ s: State, _ last: LastBlock) -> (Plan, String?) {
        let to = last.measureValue.map { number($0, s) } ?? "no number"
        let n = last.measureN ?? last.countedShots ?? 0
        let plan = Plan(reasonKey: .retentionHeld, role: .retention, spot: s.planSpot, shots: 10,
                        instruction: "Tomorrow: ten shots at \(s.planSpot.rawValue) with no cue, before anything else.",
                        reason: "The change was still there with the cue taken away: \(s.measureName) \(to) at n = \(n) (grade \(s.grade.letter)).",
                        whatItBuys: "A change only counts as learned when it shows up again on a different day, cold. That block is the test.",
                        cued: false)
        return (plan, "You ran the whole ladder and the change held at \(s.planSpot.rawValue). There is no farther spot left today, and a second un-cued block on the same day would only measure today again.")
    }

    private static func retentionNotHeld(_ s: State, _ last: LastBlock) -> Plan {
        let from = last.checkBaselineValue.map { number($0, s) } ?? "the drill block"
        let to = last.measureValue.map { number($0, s) } ?? "no number"
        let n = last.measureN ?? last.countedShots ?? 0
        return Plan(reasonKey: .retentionNotHeld, role: .drill, spot: s.planSpot, shots: max(1, s.drillReps),
                    instruction: "\(max(1, s.drillReps)) shots at \(s.planSpot.rawValue) with the cue back on.",
                    reason: "With the cue gone \(s.measureName) went \(from) → \(to) at n = \(n): practised, not learned yet.",
                    whatItBuys: "More cued reps, then another un-cued block, is the only way to tell whether it starts to stick. Nothing here is a fail — it is where most changes sit for the first few sessions.",
                    cued: true)
    }

    // MARK: - The game-like rows (added 2026-09-19)

    /// True once the plan's number has actually moved — either the drill block passed its check, or
    /// an un-cued block showed the change was still there with the cue taken away.
    ///
    /// Nothing game-like is offered before that point on purpose. A shooter who has not yet changed
    /// anything in an empty gym has nothing to carry into a harder condition, and offering it would
    /// be asking them to practise a change that does not exist yet.
    public static func qualifiesForGameLike(_ s: State) -> Bool {
        guard s.hasPlan, s.hasBaseline, let last = s.last, !last.fromLearnModule else { return false }
        guard last.checkPassed == true else { return false }
        return last.role == .drill || last.role == .retention
    }

    /// The game-like blocks to offer **alongside** the day's next block, or empty.
    ///
    /// Two rows:
    ///  * the drill block passed → shuffled spots and a called catch. Both are practice-schedule
    ///    variants, and neither adds tiredness on the same day the change first appeared.
    ///  * an un-cued block held → all four, because a change that survives the cue going is ready to
    ///    be put against the conditions a game actually has.
    public static func gameLikeVariants(_ s: State) -> [Plan] {
        guard qualifiesForGameLike(s), let last = s.last else { return [] }
        let held = last.role == .retention
        let wanted: [GameLikeVariant] = held
            ? [.randomSpot, .decisionCalled, .contested, .fatigued]
            : [.randomSpot, .decisionCalled]
        return wanted.map { variant(current: $0, s, last, held: held) }
    }

    private static func variant(current v: GameLikeVariant, _ s: State, _ last: LastBlock, held: Bool) -> Plan {
        let reps = max(1, s.drillReps)
        let earned = held
            ? "With the cue taken away \(s.measureName) still passed at \(last.spot.rawValue), so the change is yours and not the cue's."
            : "\(s.measureName) hit its target at \(last.spot.rawValue) today (grade \(s.grade.letter)), which is the point at which it is worth trying somewhere harder."
        let transfer = "A change measured in an empty gym has only been shown to exist in an empty gym. In the one randomised trial of practice order for shooting, practising in a single easy condition scored best while they practised and worst on the test afterwards (grade \(GameLikeVariant.randomSpot.grade.letter))."

        switch v {
        case .randomSpot:
            let spots = randomSpots(s)
            // One short set at each spot, in an order the shooter did not pick. `spotSequence` is
            // one entry per set, not per shot: see `GameLikeVariant.randomSpot`.
            let sequence = randomSpotSequence(spots: spots, shots: spots.count,
                                              seed: UInt64(max(0, s.blocksDoneToday)) &* 31 &+ UInt64(max(0, s.shotsToday)))
            let perSet = max(5, reps / max(1, spots.count))
            let first = sequence.first ?? spots[0]
            return Plan(reasonKey: .gameLikeRandomSpot, role: .drill, spot: first, shots: perSet,
                        instruction: "Shuffled spots: \(perSet) shots at each of these, in this order — \(sequence.map(\.rawValue).joined(separator: ", ")). \(perSet * sequence.count) in all, and the order changes every time.",
                        reason: "\(earned) \(transfer)",
                        whatItBuys: "Same numbers as any block, shot in an order you did not choose. \(GameLikeVariant.randomSpot.limit)",
                        cued: false, gameLike: .randomSpot, spotSequence: sequence)
        case .decisionCalled:
            return Plan(reasonKey: .gameLikeDecisionCalled, role: .drill, spot: s.planSpot, shots: reps,
                        instruction: "Called on the catch: \(reps) shots at \(s.planSpot.rawValue). A partner calls catch-and-shoot, one-dribble pull-up or drive as the ball leaves their hands, and you do what they called. Type in the calls afterwards if you want them kept.",
                        reason: "\(earned) A game never tells you what the shot is before the ball arrives, and this is the cheapest way to put that back (grade \(GameLikeVariant.decisionCalled.grade.letter)).",
                        whatItBuys: "The same shot numbers, taken out of a decision instead of out of a routine. \(GameLikeVariant.decisionCalled.limit)",
                        cued: false, gameLike: .decisionCalled)
        case .fatigued:
            return Plan(reasonKey: .gameLikeFatigued, role: .drill, spot: s.planSpot, shots: reps,
                        instruction: "Straight after running: run hard for 60 to 90 seconds, then shoot \(reps) at \(s.planSpot.rawValue) inside ten seconds of stopping.",
                        reason: "\(earned) Twelve minutes of game-like load cost 38 high-level players 14–19 % of their makes and 3–4 % of their falling angle — and cost elite juniors nothing at all, so this block is how you find out which you are (grade \(GameLikeVariant.fatigued.grade.letter)).",
                        whatItBuys: "Your fresh blocks today are the comparison, so one tired block tells you whether tiredness moves your shot at all. \(GameLikeVariant.fatigued.limit)",
                        cued: false, gameLike: .fatigued)
        case .contested:
            return Plan(reasonKey: .gameLikeContested, role: .drill, spot: s.planSpot, shots: reps,
                        instruction: "With a hand up: \(reps) shots at \(s.planSpot.rawValue), a partner closing out with a hand in front of the ball. Shoot your normal shot.",
                        reason: "\(earned) In NBA tracking a tight contest left the technique alone and scattered the shots about half again as much, so what this block tests is whether your spread survives, not whether your form does (grade \(GameLikeVariant.contested.grade.letter)).",
                        whatItBuys: "A read on your spread with somebody in the way, against your open blocks at the same spot. \(GameLikeVariant.contested.limit)",
                        cued: false, gameLike: .contested)
        }
    }

    /// The spots a shuffled block uses: the drill's own ladder when it has two or more, otherwise
    /// the plan's spot with its neighbours — the spots the shooter already has numbers at.
    static func randomSpots(_ s: State) -> [DoctorSpot] {
        let ladder = s.drillLadder.filter { distanceLadder.contains($0) }
        if ladder.count >= 2 { return ladder }
        guard let i = distanceLadder.firstIndex(of: s.planSpot) else { return Array(distanceLadder.prefix(3)) }
        let lo = max(0, i - 1)
        let hi = min(distanceLadder.count - 1, i + 1)
        return Array(distanceLadder[lo...hi])
    }

    /// A shuffled order the app can claim to know, because it made it.
    ///
    /// Deterministic from `seed` — the same day's state gives the same order, so a relaunch does not
    /// quietly reshuffle a block that is half shot. Each pass through the spots is its own shuffle,
    /// and a spot never lands twice in a row across the join, because two shots from the same place
    /// is the thing the block exists not to be.
    public static func randomSpotSequence(spots: [DoctorSpot], shots: Int, seed: UInt64) -> [DoctorSpot] {
        guard !spots.isEmpty, shots > 0 else { return [] }
        guard spots.count > 1 else { return Array(repeating: spots[0], count: shots) }
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        var out: [DoctorSpot] = []
        while out.count < shots {
            var cycle = spots
            var i = cycle.count - 1
            while i > 0 {
                let j = Int(next() % UInt64(i + 1))
                cycle.swapAt(i, j)
                i -= 1
            }
            if let previous = out.last, cycle[0] == previous { cycle.swapAt(0, 1) }
            for spot in cycle where out.count < shots { out.append(spot) }
        }
        return out
    }

    // MARK: - The cap

    private static func capReason(_ s: State) -> String {
        "That is \(s.blocksDoneToday) block\(s.blocksDoneToday == 1 ? "" : "s") and about \(s.shotsToday) shots today. ArcLab stops proposing at \(s.cap.blocks) blocks or \(s.cap.shots) shots. That cap is our own convention, not a number from research: tiredness does change the shot — 38 high-level players lost 14–19 % of their makes and 3–4 % of entry angle after a 12-minute game (grade A) — but other elite players showed no change at all, so the right limit has to be measured on you rather than assumed."
    }

    // MARK: - Helpers

    private static func number(_ v: Double, _ s: State) -> String {
        let text = String(format: "%.\(max(0, s.measureDecimals))f", v)
        return s.measureUnit.isEmpty ? text : "\(text) \(s.measureUnit)"
    }

    private static func roundUpToFive(_ n: Int) -> Int { n <= 0 ? 0 : (n + 4) / 5 * 5 }

    /// The first spot on the fix's own ladder that today has not been to yet.
    private static func nextLadderSpot(_ s: State) -> DoctorSpot? {
        s.drillLadder.first { !s.spotsDoneToday.contains($0) }
    }

    /// The farther of the block's spot and the plan's spot — where a range extension steps out from.
    private static func widest(_ s: State, _ last: LastBlock) -> DoctorSpot {
        let a = distanceLadder.firstIndex(of: last.spot) ?? -1
        let b = distanceLadder.firstIndex(of: s.planSpot) ?? -1
        return a >= b ? last.spot : s.planSpot
    }
}
