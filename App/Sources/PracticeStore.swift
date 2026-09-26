import Foundation
import Observation
import ShotGeometry

/// Practice mode's own state (`docs/DESIGN-PRACTICE-MODE-2026-09-15.md`).
///
/// A practice session is a list of **blocks**. A block is a spot, a number of shots, a role in the
/// plan, and — once it has been recorded and analysed — the one number the active plan is scored on.
/// Every block's spot is explicit: nothing is ever defaulted to "wherever the last clip was", because
/// a free throw and a three are different shots.
///
/// This file owns `practice.json` next to `sessions.json`. It never invents a number: a block's
/// measure is read back out of `FixLibrary.check` against the block's own saved session, and when the
/// measure cannot be computed the block carries the reason instead of a value (CLAUDE.md rule 1).
/// No network (rule 6).

// MARK: - What a block is

enum PracticeRole: String, Codable, Sendable, CaseIterable {
    /// Un-cued shots that set the number everything else is compared against.
    case baseline
    /// The fix's drill, one block per spot or per set.
    case drill
    /// Un-cued shots that test whether the change survived the cue being taken away.
    case retention
}

/// A `FixLibrary.PassCheckResult`/`RetentionResult` in a form that can be written to disk.
/// `passed` is `Bool?` on purpose: "not enough shots to tell" is a first-class outcome, never a fail.
struct PracticeCheck: Codable, Sendable {
    /// "check" (the follow-up) or "retention" (the session after).
    var kind: String
    var passed: Bool?
    var baselineValue: Double?
    var followUpValue: Double?
    var target: Double?
    var n: Int?
    var sentence: String
}

struct PracticeBlock: Codable, Identifiable, Sendable {
    var id: UUID
    var role: PracticeRole
    /// Always stated, never inferred from the previous block.
    var spot: ShotSpot
    var intendedShots: Int
    /// What to do, in one or two sentences.
    var instruction: String
    /// The fix's external-focus cue, or nil for an un-cued block (baseline and retention are un-cued
    /// by design — a cued retention test measures the cue, not the learning).
    var cue: String?

    // Filled in as the block runs.
    var recordingFile: String?
    var savedSessionID: UUID?
    var measuredShots: Int?
    var acceptedShots: Int?
    /// "release speed 7.02 ± 0.21 m/s (n 9)" — this block's own numbers, every one with its n.
    var summaryLine: String?

    // The plan's measure for this block.
    var measureName: String?
    var measureUnit: String?
    var measureDecimals: Int?
    var measureValue: Double?
    var measureN: Int?
    var measureUnavailableReason: String?
    /// Non-nil once the block has been scored against the plan (drill and retention blocks only).
    var check: PracticeCheck?
    /// Non-nil when the block produced no saved session, and says why.
    var blockNote: String?
    var completedAt: Date?

    // Curriculum blocks (`Learn`). A block started from a curriculum drill is scored on that
    // module's own gate rather than on the active plan's measure — a Learn drill is not the plan,
    // and scoring it as though it were would move the wrong number.
    /// `CurriculumModuleID.rawValue` when this block came from a Learn module. Optional so every
    /// practice.json written before Learn existed still decodes.
    var moduleID: String?
    /// The curriculum drill's name, so the block card can say which drill it was.
    var drillName: String?

    // Game-like blocks (added 2026-09-19, 1.4 "game"). A block shot under one condition of a game —
    // shuffled spots, a call at the catch, straight after running, with a hand up. The app measures
    // exactly the same numbers; what it cannot see is the defender, the clock and the call, so the
    // condition is recorded as the shooter's word and labelled that way everywhere it is shown.
    /// `NextBlock.GameLikeVariant.rawValue`, or nil for an ordinary block.
    var gameLike: String?
    /// For a shuffled block: the order the app generated, one `ShotSpot.rawValue` a shot. Empty or
    /// nil for every other kind of block.
    var spotSequence: [String]?
    /// For a called-catch block: what the partner called, in order, as the shooter typed it in
    /// afterwards. Nil when they did not, which is the normal case and not a gap.
    var calls: [String]?

    var isDone: Bool { completedAt != nil }

    /// The game-like condition, or nil. Written as the raw value so an unknown one from a future
    /// build decodes as "no condition" rather than failing the whole file.
    var gameLikeVariant: NextBlock.GameLikeVariant? {
        gameLike.flatMap { NextBlock.GameLikeVariant(rawValue: $0) }
    }

    /// The measure as a sentence with its n, or nil.
    var measureText: String? {
        guard let value = measureValue, let name = measureName else { return nil }
        let decimals = measureDecimals ?? 2
        let number = String(format: "%.\(decimals)f", value)
        let unit = (measureUnit ?? "").isEmpty ? "" : " \(measureUnit ?? "")"
        let n = measureN.map { " (n \($0))" } ?? ""
        return "\(name) \(number)\(unit)\(n)"
    }

    init(id: UUID = UUID(), role: PracticeRole, spot: ShotSpot, intendedShots: Int,
         instruction: String, cue: String?, moduleID: String? = nil, drillName: String? = nil,
         gameLike: String? = nil, spotSequence: [String]? = nil) {
        self.id = id
        self.role = role
        self.spot = spot
        self.intendedShots = intendedShots
        self.instruction = instruction
        self.cue = cue
        self.moduleID = moduleID
        self.drillName = drillName
        self.gameLike = gameLike
        self.spotSequence = spotSequence
    }
}

/// One proposal from the next-block engine (`NextBlock.decide`), written into the session so the
/// day's sequence survives a relaunch.
///
/// A proposal is never a second kind of block: when it is for today it materialises an ordinary
/// `PracticeBlock` in `blocks` and keeps that block's id here, alongside the words that say why the
/// block was proposed. When the day's cap is reached no block is created and the proposal carries
/// `dayDoneReason` instead — it is then tomorrow's first block.
struct PracticeProposal: Codable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    /// `NextBlock.ReasonKey.rawValue`. Logged, never shown in a `Text`.
    var reasonKey: String
    var role: PracticeRole
    var spot: ShotSpot
    var shots: Int
    /// The one line of why: which number, from how many shots, and the grade of the rule.
    var reason: String
    /// What the extra shots will let the app tell.
    var whatItBuys: String
    var instruction: String
    /// Non-nil when the cap was reached: this proposal is tomorrow's first block, not today's.
    var dayDoneReason: String?
    /// The scored block this proposal was made after — one proposal per scored block.
    var afterBlockID: UUID?
    /// The block created for it in today's session. Nil when the proposal is for tomorrow.
    var blockID: UUID?
    /// Set the moment the shooter starts recording the block this proposed.
    var acceptedAt: Date?
}

struct PracticeSession: Codable, Identifiable, Sendable {
    var id: UUID
    var date: Date
    /// The active plan this was built from, when there was one.
    var planID: UUID?
    var planHypothesis: String?
    var blocks: [PracticeBlock]
    /// The day's proposed sequence, oldest first. Optional so every practice.json written before the
    /// next-block engine existed still decodes.
    var proposals: [PracticeProposal]?

    var isComplete: Bool { !blocks.isEmpty && blocks.allSatisfy(\.isDone) }
    var nextBlock: PracticeBlock? { blocks.first { !$0.isDone } }
    var doneCount: Int { blocks.filter(\.isDone).count }
    /// The block that was scored most recently today.
    var lastScoredBlock: PracticeBlock? {
        blocks.filter(\.isDone).max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
    }
    /// What each block actually put through the analyser, falling back to what it asked for.
    var shotsToday: Int { blocks.filter(\.isDone).reduce(0) { $0 + ($1.measuredShots ?? $1.intendedShots) } }
    func proposal(forBlock id: UUID) -> PracticeProposal? { proposals?.first { $0.blockID == id } }
}

/// The one thing to do next, for the Today card and for practice home. There is always one of these
/// once a session exists: a block to record, or a finished day with tomorrow's first block named.
enum PracticeNextAction {
    /// Record this block now. `number` is its place in today's list, 1-based.
    case record(block: PracticeBlock, number: Int, proposal: PracticeProposal?)
    /// The day's cap is reached — or the ladder ran out. `tomorrow` is the first block of the next day.
    case dayDone(reason: String, tomorrow: PracticeProposal)
}

// MARK: - Plain names for the engine's identifiers

enum PracticeNames {
    static func role(_ r: PracticeRole) -> String {
        switch r {
        case .baseline: return "Warm-up baseline"
        case .drill: return "Drill"
        case .retention: return "Retention"
        }
    }

    /// The pass measure in a shooter's words, with the unit it is actually in and how many decimals
    /// are worth showing. Nothing in the UI shows the engine's camelCase identifier.
    static func measure(_ m: PassMeasure) -> (name: String, unit: String, decimals: Int) {
        switch m {
        case .releaseSpeedSD: return ("release-speed spread", "m/s", 3)
        case .releaseSpeedSDRatioAcrossDistance: return ("far ÷ near release-speed spread", "×", 2)
        case .entryAngleMeanDegrees: return ("mean entry angle", "°", 1)
        case .depthMeanCm: return ("mean depth past the front rim", "cm", 1)
        case .depthSDCm: return ("depth spread", "cm", 1)
        case .lateralMeanCm: return ("mean left–right offset", "cm", 1)
        case .lateralSDCm: return ("left–right spread", "cm", 1)
        case .dipToReleaseMean: return ("mean rhythm time (lowest wrist → release)", "s", 3)
        case .dipToReleaseChangeAcrossDistance: return ("change in rhythm time across distance", "s", 3)
        case .spinAxisTiltDegrees: return ("spin-axis tilt", "°", 1)
        case .forearmFromVerticalDegrees: return ("forearm away from vertical", "°", 1)
        case .kneeDriveChangeAcrossDistance: return ("change in knee-drive rate across distance", "°/s", 0)
        case .proximalToDistalRate: return ("share of shots with the legs leading the arm", "", 2)
        case .headStabilityNormalised: return ("head movement through the shot", "", 3)
        case .depthTotalChangeOverSession: return ("depth drift across the session", "cm", 1)
        case .speedShareOfDepthVariance: return ("speed's share of the depth spread", "", 2)
        }
    }
}

// MARK: - Storage

@MainActor
@Observable
final class PracticeStore {
    /// Newest first.
    private(set) var sessions: [PracticeSession] = []
    private(set) var loadError: String?
    private(set) var saveError: String?

    static let fileName = "practice.json"

    init() { load() }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ArcLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    func load() {
        let url = PracticeStore.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { sessions = []; return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([PracticeSession].self, from: data).sorted { $0.date > $1.date }
            loadError = nil
        } catch {
            loadError = "could not read the practice log: \(error)"
            sessions = []
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(sessions).write(to: PracticeStore.fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "could not write the practice log: \(error)"
        }
    }

    // MARK: Today

    var todaysSession: PracticeSession? {
        sessions.first { Calendar.current.isDateInToday($0.date) }
    }

    func session(_ id: UUID) -> PracticeSession? { sessions.first { $0.id == id } }

    /// Today's plan, built once. Call from `onAppear`, never from a view's body.
    @discardableResult
    func ensureToday(doctor: ShotDoctorModel) -> PracticeSession {
        if let existing = todaysSession { return existing }
        let progress = doctor.planProgress
        let blocks = PracticeStore.plannedBlocks(progress: progress)
        let session = PracticeSession(id: UUID(), date: Date(),
                                      planID: progress?.plan.id,
                                      planHypothesis: progress?.plan.hypothesis,
                                      blocks: blocks)
        sessions.insert(session, at: 0)
        persist()
        ActivityLog.shared.event("practice.session.built", [
            "plan": progress?.plan.hypothesis, "blocks": blocks.count,
            "spots": blocks.map(\.spot.rawValue).joined(separator: ", "),
            "shots": blocks.reduce(0) { $0 + $1.intendedShots },
        ])
        return session
    }

    /// Throw away today's plan and build it again — used when the active plan changed after the
    /// session was laid out.
    func rebuildToday(doctor: ShotDoctorModel) {
        if let existing = todaysSession, existing.blocks.contains(where: \.isDone) { return }
        sessions.removeAll { Calendar.current.isDateInToday($0.date) }
        ensureToday(doctor: doctor)
    }

    func replace(_ block: PracticeBlock, in sessionID: UUID) {
        guard let s = sessions.firstIndex(where: { $0.id == sessionID }),
              let b = sessions[s].blocks.firstIndex(where: { $0.id == block.id }) else { return }
        sessions[s].blocks[b] = block
        persist()
    }

    // MARK: Building today's plan

    /// The blocks for one session.
    ///
    /// With an active plan: the drill blocks come out of the fix package's own drill — its spots and
    /// its reps, not a number this file made up — followed by an un-cued retention block at the
    /// plan's spot. Without a plan (or with a plan whose baseline session has been deleted), one
    /// plain baseline block, because there is nothing yet to compare anything against.
    static func plannedBlocks(progress: ShotDoctorModel.PlanProgress?) -> [PracticeBlock] {
        guard let progress else {
            return [PracticeBlock(
                role: .baseline, spot: .freeThrow, intendedShots: 10,
                instruction: "Ten free throws with your normal routine. No cue and nothing to change — this block is the reference every later block is read against.",
                cue: nil)]
        }
        let package = progress.package
        let spot = progress.spot

        guard progress.baseline != nil else {
            return [PracticeBlock(
                role: .baseline, spot: spot, intendedShots: 10,
                instruction: "Ten shots at \(spot.rawValue) with your normal routine. The plan's baseline session is gone, so this block becomes the new reference — un-cued on purpose.",
                cue: nil)]
        }

        var blocks: [PracticeBlock] = []
        let drill = package.drill
        let reps = max(1, drill.reps)
        let drillSpots = drill.spots.compactMap { ShotSpot(rawValue: $0.rawValue) }

        if !drillSpots.isEmpty {
            // The package gives spots × reps. One round through the spots is one session's worth;
            // the package's own `sets` says how many rounds the whole drill is, and the instruction
            // says so rather than quietly shrinking the drill.
            let rounds = max(1, drill.sets / max(1, drillSpots.count))
            let ladder = Array(drillSpots.prefix(5))
            for (i, s) in ladder.enumerated() {
                blocks.append(PracticeBlock(
                    role: .drill, spot: s, intendedShots: reps,
                    instruction: "\(drill.name), step \(i + 1) of \(ladder.count): \(reps) shots at \(s.rawValue). \(drill.constraint) The whole drill is \(rounds) round\(rounds == 1 ? "" : "s") of this ladder; one round is a session's block list. \(drill.schedule)",
                    cue: package.cue))
            }
        } else {
            // No spots in the package means "wherever the finding was". Two sets there, which is
            // what the package's own `sets` allows, and never a spot this file chose on its own.
            let sets = min(max(1, drill.sets), 2)
            for i in 0..<sets {
                blocks.append(PracticeBlock(
                    role: .drill, spot: spot, intendedShots: reps,
                    instruction: "\(drill.name), set \(i + 1) of \(sets): \(reps) shots at \(spot.rawValue). \(drill.constraint) \(drill.schedule)",
                    cue: package.cue))
            }
        }

        blocks.append(PracticeBlock(
            role: .retention, spot: spot, intendedShots: 10,
            instruction: "Ten shots at \(spot.rawValue) with no cue at all — normal routine, nothing to think about. \(package.retentionRule)",
            cue: nil))
        return blocks
    }

    // MARK: The day as a sequence — what comes after the block that was just scored

    /// The one thing to do next. Pure read: views call it from `body`, and `refreshProposal` is what
    /// actually moves anything. Nil only when there is no practice session today at all.
    var nextAction: PracticeNextAction? {
        guard let session = todaysSession else { return nil }
        if let next = session.nextBlock, let i = session.blocks.firstIndex(where: { $0.id == next.id }) {
            return .record(block: next, number: i + 1, proposal: session.proposal(forBlock: next.id))
        }
        if let last = session.proposals?.last, let why = last.dayDoneReason {
            return .dayDone(reason: why, tomorrow: last)
        }
        return nil
    }

    /// Propose the next block, if the day is waiting on one.
    ///
    /// Called after a block is scored and from the screens that show the day. It does nothing while a
    /// block is still waiting to be recorded, and it proposes **once** per scored block — the
    /// proposal is written into the session, so it is the same block after a relaunch.
    @discardableResult
    func refreshProposal(doctor: ShotDoctorModel) -> PracticeProposal? {
        guard let index = sessions.firstIndex(where: { Calendar.current.isDateInToday($0.date) }) else { return nil }
        let session = sessions[index]
        guard !session.blocks.isEmpty, session.nextBlock == nil else { return nil }
        guard let last = session.lastScoredBlock else { return nil }
        if let existing = session.proposals?.last, existing.afterBlockID == last.id { return existing }

        let decision = NextBlock.decide(PracticeStore.engineState(session: session, last: last, doctor: doctor))
        let plan = decision.plan
        let role = PracticeRole(rawValue: plan.role.rawValue) ?? .drill
        let spot = ShotSpot(rawValue: plan.spot.rawValue) ?? .other
        let cue = plan.cued ? doctor.planProgress?.package.cue : nil

        var proposal = PracticeProposal(
            id: UUID(), createdAt: Date(), reasonKey: plan.reasonKey.rawValue, role: role, spot: spot,
            shots: max(1, plan.shots), reason: plan.reason, whatItBuys: plan.whatItBuys,
            instruction: plan.instruction, dayDoneReason: decision.dayDoneReason,
            afterBlockID: last.id, blockID: nil, acceptedAt: nil)

        if decision.isToday {
            let block = PracticeBlock(role: role, spot: spot, intendedShots: proposal.shots,
                                      instruction: plan.instruction, cue: cue)
            proposal.blockID = block.id
            sessions[index].blocks.append(block)
        }
        sessions[index].proposals = (sessions[index].proposals ?? []) + [proposal]
        persist()
        ActivityLog.shared.event("practice.next.proposed", [
            "role": role.rawValue, "spot": spot.rawValue, "reason": plan.reasonKey.rawValue,
            "shots": proposal.shots, "n": last.measureN, "afterRole": last.role.rawValue,
            "afterPassed": last.check?.passed, "dayDone": decision.dayDoneReason != nil,
            "blocksDone": session.doneCount, "shotsToday": session.shotsToday,
        ])
        return proposal
    }

    /// The shooter started recording the block a proposal asked for.
    func markProposalAccepted(blockID: UUID, in sessionID: UUID) {
        guard let s = sessions.firstIndex(where: { $0.id == sessionID }),
              let p = sessions[s].proposals?.firstIndex(where: { $0.blockID == blockID }),
              sessions[s].proposals?[p].acceptedAt == nil else { return }
        sessions[s].proposals?[p].acceptedAt = Date()
        let proposal = sessions[s].proposals?[p]
        persist()
        ActivityLog.shared.event("practice.next.accepted", [
            "role": proposal?.role.rawValue, "spot": proposal?.spot.rawValue,
            "reason": proposal?.reasonKey, "shots": proposal?.shots,
        ])
    }

    /// Everything the decision table is allowed to know, read out of the plan and the day so far.
    /// Nothing here is invented: the measure, its floor and its grade come from the fix package, the
    /// spread-with-distance verdict from the pooled diagnosis (nil when it was never measured).
    private static func engineState(session: PracticeSession, last: PracticeBlock,
                                    doctor: ShotDoctorModel) -> NextBlock.State {
        let progress = doctor.planProgress
        let names = progress.map { PracticeNames.measure($0.package.passCheck.measure) }
        var narrows = false
        if let target = progress?.package.passCheck.target {
            switch target {
            case .narrowByDetectableRatio, .narrowByFraction: narrows = true
            case .insideBand, .moveBy, .reportOnly: narrows = false
            }
        }
        var widens: Bool?
        if let verdict = doctor.diagnosis?.distance.versatility.verdict {
            switch verdict {
            case .spreadWidens: widens = true
            case .spreadStable, .spreadNarrows: widens = false
            case .undecided: widens = nil
            }
        }
        let lastSpot = DoctorSpot(rawValue: last.spot.rawValue) ?? .other
        return NextBlock.State(
            last: NextBlock.LastBlock(
                role: NextBlock.Role(rawValue: last.role.rawValue) ?? .drill,
                spot: lastSpot,
                countedShots: last.acceptedShots,
                attemptedShots: last.measuredShots ?? last.intendedShots,
                measureValue: last.measureValue,
                measureN: last.measureN,
                measureUnavailableReason: last.measureUnavailableReason,
                hasCheck: last.check != nil,
                checkPassed: last.check?.passed,
                checkBaselineValue: last.check?.baselineValue,
                checkTarget: last.check?.target,
                fromLearnModule: last.moduleID != nil,
                gameLike: last.gameLikeVariant),
            hasPlan: progress != nil,
            hasBaseline: progress?.baseline != nil,
            planSpot: progress.flatMap { DoctorSpot(rawValue: $0.spot.rawValue) } ?? lastSpot,
            measureName: names?.name ?? "the number your plan is scored on",
            measureUnit: names?.unit ?? "",
            measureDecimals: names?.decimals ?? 2,
            grade: progress?.package.grade ?? .d,
            minimumN: progress?.package.passCheck.minimumN ?? ShotDoctor.attributionFloor,
            targetNarrowsSpread: narrows,
            drillName: progress?.package.drill.name ?? "Practice block",
            drillReps: max(1, progress?.package.drill.reps ?? 10),
            drillLadder: progress?.package.drill.spots ?? [],
            spotsDoneToday: session.blocks.filter(\.isDone).compactMap { DoctorSpot(rawValue: $0.spot.rawValue) },
            blocksDoneToday: session.doneCount,
            shotsToday: session.shotsToday,
            spreadWidensWithDistance: widens,
            // What the table has already asked for today, so a row that cannot make progress
            // escalates instead of coming back word for word (`NextBlock.escalate`). The proposals
            // are already persisted, so this survives a relaunch along with the rest of the day.
            proposalsToday: (session.proposals ?? []).compactMap { NextBlock.ReasonKey(rawValue: $0.reasonKey) })
    }

    // MARK: Adding a Learn module's drill to today

    /// Put a curriculum drill into today's session as its own blocks (`LearnView`'s "start this
    /// drill as a practice block"). One block per spot on the drill's ladder; when the drill names
    /// no spots it lands at `fallbackSpot`, which the caller states explicitly rather than letting
    /// this file choose one. Returns the blocks that were added, in order.
    @discardableResult
    func addDrill(_ curriculumDrill: CurriculumDrill, module: CurriculumModule,
                  fallbackSpot: ShotSpot, doctor: ShotDoctorModel) -> [PracticeBlock] {
        let session = ensureToday(doctor: doctor)
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return [] }

        let drill = curriculumDrill.drill
        let reps = max(1, drill.reps)
        let ladder = drill.spots.compactMap { ShotSpot(rawValue: $0.rawValue) }
        let spots = ladder.isEmpty ? [fallbackSpot] : Array(ladder.prefix(5))
        let rounds = max(1, drill.sets / max(1, spots.count))

        var added: [PracticeBlock] = []
        for (i, spot) in spots.enumerated() {
            let step = spots.count == 1 ? "" : ", step \(i + 1) of \(spots.count)"
            added.append(PracticeBlock(
                role: .drill, spot: spot, intendedShots: reps,
                instruction: "\(module.title) — \(drill.name)\(step): \(reps) shots at \(spot.rawValue). \(drill.constraint) The whole drill is \(rounds) round\(rounds == 1 ? "" : "s") of this; one round is a session's worth. \(drill.schedule) Film it: \(curriculumDrill.filmFrom.whatToFilm)",
                cue: module.cue,
                moduleID: module.id.rawValue,
                drillName: drill.name))
        }
        sessions[index].blocks.append(contentsOf: added)
        persist()
        ActivityLog.shared.event("learn.drill.added", [
            "module": module.id.rawValue, "drill": drill.name, "blocks": added.count,
            "spots": added.map(\.spot.rawValue).joined(separator: ", "),
            "shots": added.reduce(0) { $0 + $1.intendedShots },
        ])
        return added
    }

    // MARK: Game-like blocks (added 2026-09-19)

    /// The game-like conditions the engine will offer right now, or empty.
    ///
    /// Empty is the normal answer and is not a failure: nothing game-like is offered until the
    /// plan's number has actually moved, because a change that does not exist yet cannot be carried
    /// anywhere. Pure read — `addGameLikeBlock` is what puts one in the day.
    func gameLikeOffers(doctor: ShotDoctorModel) -> [NextBlock.Plan] {
        guard let session = todaysSession, let last = session.lastScoredBlock else { return [] }
        return NextBlock.gameLikeVariants(PracticeStore.engineState(session: session, last: last, doctor: doctor))
    }

    /// Put one of those offers into today's session. Returns the first block, or nil when there is
    /// no session to put it in.
    ///
    /// A shuffled offer becomes **one block per set**, in the app's own order, because a recording
    /// is saved at one spot: a single block spanning four spots would have to label every shot in it
    /// with one of them, which would be a number nobody measured. Every other variant is one block.
    @discardableResult
    func addGameLikeBlock(_ plan: NextBlock.Plan, doctor: ShotDoctorModel) -> PracticeBlock? {
        guard let variant = plan.gameLike else { return nil }
        let session = ensureToday(doctor: doctor)
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return nil }
        let sequence = plan.spotSequence.isEmpty ? [plan.spot] : plan.spotSequence
        let order = sequence.map(\.rawValue)
        var added: [PracticeBlock] = []
        for (i, doctorSpot) in sequence.enumerated() {
            let spot = ShotSpot(rawValue: doctorSpot.rawValue) ?? .other
            let step = sequence.count == 1 ? "" : " — set \(i + 1) of \(sequence.count)"
            added.append(PracticeBlock(
                role: PracticeRole(rawValue: plan.role.rawValue) ?? .drill,
                spot: spot,
                intendedShots: max(1, plan.shots),
                instruction: "\(variant.title)\(step): \(plan.instruction) \(variant.limit)",
                // A game-like block is deliberately un-cued: the condition is the constraint, and a
                // cue on top of it would mean two changes at once and neither one scorable.
                cue: nil,
                gameLike: variant.rawValue,
                spotSequence: sequence.count == 1 ? nil : order))
        }
        sessions[index].blocks.append(contentsOf: added)
        persist()
        ActivityLog.shared.event("game.block.added", [
            "variant": variant.rawValue, "blocks": added.count,
            "spots": order.joined(separator: ", "),
            "shots": added.reduce(0) { $0 + $1.intendedShots },
            "grade": variant.grade.letter,
        ])
        return added.first
    }

    /// Record what the partner called on a called-catch block, in the shooter's own words. Stored as
    /// their word: the app never heard the call and the screen says so.
    func recordCalls(_ calls: [String], for blockID: UUID, in sessionID: UUID) {
        guard let s = sessions.firstIndex(where: { $0.id == sessionID }),
              let b = sessions[s].blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let cleaned = calls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        sessions[s].blocks[b].calls = cleaned.isEmpty ? nil : cleaned
        persist()
        ActivityLog.shared.event("game.block.calls", [
            "variant": sessions[s].blocks[b].gameLike, "calls": cleaned.count,
        ])
    }

    /// Every game-like block ever recorded, newest session first.
    func gameLikeBlocks() -> [PracticeBlock] {
        sessions.reversed().flatMap(\.blocks).filter { $0.gameLike != nil }
    }

    /// The session a block belongs to. Nil for a block that is not in the log.
    func sessionID(forBlock id: UUID) -> UUID? {
        sessions.first { $0.blocks.contains { $0.id == id } }?.id
    }

    /// Every block recorded from a Learn module, oldest first. The Learn screen's progress is read
    /// out of these and out of nothing else: it is what was actually shot, never a self-assessment.
    func blocks(forModule id: CurriculumModuleID) -> [PracticeBlock] {
        sessions.reversed()
            .flatMap(\.blocks)
            .filter { $0.moduleID == id.rawValue }
    }

    // MARK: Scoring a block once its session is saved

    /// Fill a block in from the session that was just saved for it. Every number here is read out of
    /// the engine against that session; nothing is estimated and nothing is carried over from another
    /// block. Returns the block to hand back to `replace(_:in:)`.
    func scored(_ block: PracticeBlock, saved: SavedSession, measuredShots: Int,
                doctor: ShotDoctorModel, earlierDrillSession: SavedSession?) -> PracticeBlock {
        var b = block
        b.savedSessionID = saved.id
        b.measuredShots = measuredShots
        b.acceptedShots = saved.accepted
        b.summaryLine = PracticeStore.summaryLine(for: saved)
        b.completedAt = Date()

        // A block started from Learn is scored on its own module's gate. The active plan measures a
        // different thing, and reading the plan's number off a curriculum drill would score a change
        // nobody practised.
        if let moduleID = block.moduleID.flatMap(CurriculumModuleID.init(rawValue:)) {
            return scoredAgainstModule(b, module: Curriculum.module(moduleID), saved: saved, doctor: doctor)
        }

        guard let progress = doctor.planProgress, let baseline = progress.baseline else {
            b.measureUnavailableReason = "No active plan with a baseline session, so there is no pass measure to score this block on. The block's own numbers are above, and every one carries its n."
            return b
        }

        let package = progress.package
        // The pass check resolves its own scope (the finding's spot, the far spot, or across
        // distance) from the *plan's* spot, not the block's.
        let planSpot = DoctorSpot(rawValue: progress.spot.rawValue) ?? .other
        let blockDiagnosis = doctor.diagnosis(for: saved)
        let baselineDiagnosis = doctor.diagnosis(for: baseline)
        let names = PracticeNames.measure(package.passCheck.measure)
        b.measureName = names.name
        b.measureUnit = names.unit
        b.measureDecimals = names.decimals

        // Read this block's own value for the measure: `check` against itself is only used for the
        // read-out, exactly as `ShotDoctorModel.startPlan` does. The verdict is ignored here.
        let readBack = FixLibrary.check(package.passCheck, baseline: blockDiagnosis,
                                        followUp: blockDiagnosis, spot: planSpot)
        b.measureValue = readBack.baselineValue
        b.measureN = readBack.n ?? blockDiagnosis.spot(planSpot)?.n
        if readBack.baselineValue == nil {
            b.measureUnavailableReason = "This block carries no \(names.name): \(readBack.sentence)"
        }

        // A game-like block is shot under a condition the plan's reference block was not — tired,
        // shuffled, or with somebody in the way. Running the plan's check on it would report the
        // condition as a failure of the fix, so the numbers are read out and the check is not run.
        // The comparison it actually needs is an ordinary block at the same spot on the same day,
        // which is what `NextBlock` proposes next.
        if let variant = block.gameLikeVariant {
            b.blockNote = "\(variant.title): shot under a condition your plan's reference block was not, so it is not scored against the plan. \(variant.limit) Compare it with an ordinary block at \(block.spot.rawValue) on the same day."
            ActivityLog.shared.event("game.block.scored", [
                "variant": variant.rawValue, "spot": block.spot.rawValue,
                "measure": package.passCheck.measure.rawValue,
                "value": b.measureValue, "n": b.measureN, "accepted": b.acceptedShots,
            ])
            return b
        }

        switch block.role {
        case .baseline:
            break
        case .drill:
            let r = FixLibrary.check(package.passCheck, baseline: baselineDiagnosis,
                                     followUp: blockDiagnosis, spot: planSpot)
            b.check = PracticeCheck(kind: "check", passed: r.passed, baselineValue: r.baselineValue,
                                    followUpValue: r.followUpValue, target: r.target, n: r.n,
                                    sentence: r.sentence)
        case .retention:
            // Retention needs the session the change was practised in. Prefer the plan's own
            // follow-up; fall back to the first drill block of this session. Without either, say so.
            let practised = progress.followUp ?? earlierDrillSession
            if let practised {
                let r = FixLibrary.retention(package.passCheck, baseline: baselineDiagnosis,
                                             followUp: doctor.diagnosis(for: practised),
                                             retention: blockDiagnosis, spot: planSpot)
                b.check = PracticeCheck(kind: "retention", passed: r.held, baselineValue: nil,
                                        followUpValue: b.measureValue, target: nil, n: b.measureN,
                                        sentence: r.sentence)
            } else {
                b.check = PracticeCheck(kind: "retention", passed: nil, baselineValue: nil,
                                        followUpValue: b.measureValue, target: nil, n: b.measureN,
                                        sentence: "Retention compares this block against the session the cue was practised in, and no drill session has been saved at \(progress.spot.rawValue) since the plan started. Record a drill block first and this block scores it.")
            }
        }

        if let c = b.check {
            ActivityLog.shared.event("practice.check", [
                "kind": c.kind, "role": block.role.rawValue, "spot": block.spot.rawValue,
                "measure": package.passCheck.measure.rawValue, "passed": c.passed,
                "value": c.followUpValue, "target": c.target, "n": c.n,
            ])
        }
        return b
    }

    /// Score a Learn block against its module's first measurable gate. The reference is this
    /// module's own earliest recorded block at the same spot — a module's first block cannot pass
    /// anything, and says so rather than being marked done.
    private func scoredAgainstModule(_ block: PracticeBlock, module: CurriculumModule,
                                     saved: SavedSession, doctor: ShotDoctorModel) -> PracticeBlock {
        var b = block
        guard let gate = module.doneWhen.first(where: { $0.check != nil }), let check = gate.check else {
            let why = module.doneWhen.first?.unavailableReason
                ?? "This module has no gate ArcLab can measure yet."
            b.measureUnavailableReason = "\(module.title) cannot be scored from a block today: \(why)"
            return b
        }

        let spot = DoctorSpot(rawValue: block.spot.rawValue) ?? .other
        let blockDiagnosis = doctor.diagnosis(for: saved)
        let names = PracticeNames.measure(check.measure)
        b.measureName = names.name
        b.measureUnit = names.unit
        b.measureDecimals = names.decimals

        let readBack = FixLibrary.check(check, baseline: blockDiagnosis, followUp: blockDiagnosis, spot: spot)
        b.measureValue = readBack.baselineValue
        b.measureN = readBack.n ?? blockDiagnosis.spot(spot)?.n
        if readBack.baselineValue == nil {
            b.measureUnavailableReason = "This block carries no \(names.name): \(readBack.sentence)"
        }

        // The module's own first block at this spot is the reference. `blocks(forModule:)` is oldest
        // first, so the first match is the earliest.
        let earlier = blocks(forModule: module.id).first {
            $0.id != block.id && $0.spot == block.spot && $0.savedSessionID != nil && $0.measureValue != nil
        }
        let earlierSaved = earlier?.savedSessionID.flatMap { id in doctor.store.sessions.first { $0.id == id } }

        if let earlierSaved {
            let r = FixLibrary.check(check, baseline: doctor.diagnosis(for: earlierSaved),
                                     followUp: blockDiagnosis, spot: spot)
            b.check = PracticeCheck(kind: "module", passed: r.passed, baselineValue: r.baselineValue,
                                    followUpValue: r.followUpValue, target: r.target, n: r.n,
                                    sentence: "\(module.title): \(gate.plainWords) \(r.sentence)")
        } else {
            b.check = PracticeCheck(kind: "module", passed: nil, baselineValue: nil,
                                    followUpValue: b.measureValue, target: nil, n: b.measureN,
                                    sentence: "First block recorded for \(module.title) at \(block.spot.rawValue). Its number becomes the reference the next block from this module is read against — one block cannot pass a gate on its own.")
        }
        ActivityLog.shared.event("learn.block.scored", [
            "module": module.id.rawValue, "spot": block.spot.rawValue,
            "measure": check.measure.rawValue, "passed": b.check?.passed, "n": b.measureN,
        ])
        return b
    }

    /// The block's own numbers, each with its n. Nothing here is a target and nothing is a promise.
    static func summaryLine(for saved: SavedSession) -> String? {
        let s = saved.summary
        var parts: [String] = []
        if let speed = s.releaseSpeed { parts.append("release speed \(speed.text(unit: "m/s", decimals: 2))") }
        if let entry = s.entryAngleDegrees { parts.append("entry angle \(entry.text(unit: "°", decimals: 1))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
