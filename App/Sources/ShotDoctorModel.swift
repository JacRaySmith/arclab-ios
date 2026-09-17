import Foundation
import Observation
import ShotGeometry

/// The App side of the shot doctor (`docs/DESIGN-SHOT-DOCTOR-2026-09-14.md`).
///
/// It does four things and nothing else: it bridges saved sessions into `[ShotRecord]` (per spot,
/// never pooling two spots), runs `ShotDoctor.diagnose`, answers a complaint through
/// `SymptomEngine`, and scores the one active plan against the sessions saved after it was chosen.
/// No I/O beyond `SessionStore`, no network (CLAUDE.md rule 6).
///
/// Everything is nil with a reason. With no saved session there is no diagnosis at all, and the
/// reason says what to do about it rather than showing an empty screen.
@MainActor
@Observable
final class ShotDoctorModel {
    let store: SessionStore

    // MARK: Complaint intake

    /// What the shooter typed. Free text runs the deterministic matcher.
    var complaint = ""
    /// Set when the shooter picked a row instead of typing, or picked another symptom after a match.
    var pickedSymptom: SymptomID?
    /// The last answer produced, so the ranked list survives a redraw.
    var answer: ComplaintAnswer?

    init(store: SessionStore) { self.store = store }

    // MARK: No data

    /// The one sentence shown wherever a number would otherwise be, when nothing has been saved.
    static let noSessionsReason =
        "Save a session first, with its spot. The shot doctor reads only saved sessions, and it never mixes two spots: a free throw and a three are different shots."

    /// Non-nil when there is nothing at all to diagnose.
    var unavailableReason: String? {
        if store.sessions.isEmpty { return ShotDoctorModel.noSessionsReason }
        if records.isEmpty {
            return "There are \(store.sessions.count) saved session(s) but no accepted shot in any of them, so there is nothing to diagnose. A window the shot gate rejected has no numbers."
        }
        return nil
    }

    // MARK: Bridging — SavedSession/SavedShot → ShotRecord

    /// One record per saved shot. Radians, metres and seconds in; the engine turns them back into
    /// degrees only inside the sentences it hands back. Anything not measured stays nil.
    static func records(from sessions: [SavedSession]) -> [ShotRecord] {
        var out: [ShotRecord] = []
        var nextID = 0
        for session in sessions.sorted(by: { $0.date < $1.date }) {
            for (i, s) in session.shots.sorted(by: { $0.id < $1.id }).enumerated() {
                nextID += 1
                out.append(ShotRecord(
                    id: nextID,
                    sessionID: session.id.uuidString,
                    sessionDate: session.date,
                    sequence: i,
                    spot: DoctorSpot(rawValue: session.spot.rawValue) ?? .other,
                    outcome: ShotOutcomeLabel(rawValue: s.outcome) ?? .unknown,
                    accepted: s.verdict == "accept",
                    releaseSpeed: s.releaseSpeed,
                    releaseAngle: s.releaseAngleDegrees.map(Angle.radians),
                    releaseHeight: s.releaseHeight,
                    releaseDistance: s.releaseDistance,
                    entryAngle: s.entryAngleDegrees.map(Angle.radians),
                    depthPastFrontRim: s.depthPastFrontRim,
                    lateralDeviation: s.lateralDeviation,
                    dipToRelease: s.dipToReleaseSeconds,
                    viewClass: ViewClass(rawValue: s.viewClass),
                    kneeExtensionPeakDegreesPerSecond: s.kneeExtensionPeakDegreesPerSecond,
                    proximalToDistal: s.proximalToDistal,
                    elbowAtReleaseDegrees: s.fittedElbowAtReleaseDegrees ?? s.elbowAtReleaseDegrees,
                    headStabilityNormalised: s.headStabilityNormalised,
                    shoulderLineYawDegrees: s.shoulderLineYawDegrees))
            }
        }
        return out
    }

    // MARK: Diagnosis, cached per store change

    /// Changes whenever a session is saved, edited or deleted — the only thing the cache keys on.
    private var storeSignature: String {
        store.sessions.map { "\($0.id.uuidString)#\($0.shots.count)" }.sorted().joined(separator: "|")
    }

    private var cachedSignature: String?
    private var cachedRecords: [ShotRecord] = []
    private var cachedDiagnosis: Diagnosis?
    private var perSessionDiagnosis: [UUID: Diagnosis] = [:]

    private func refreshIfNeeded() {
        let signature = storeSignature
        guard signature != cachedSignature else { return }
        cachedSignature = signature
        cachedRecords = ShotDoctorModel.records(from: store.sessions)
        cachedDiagnosis = cachedRecords.isEmpty ? nil : ShotDoctor.diagnose(records: cachedRecords)
        perSessionDiagnosis = [:]
    }

    var records: [ShotRecord] {
        refreshIfNeeded()
        return cachedRecords
    }

    /// Every saved session at once. Nil when nothing has been saved — see `unavailableReason`.
    var diagnosis: Diagnosis? {
        refreshIfNeeded()
        return cachedDiagnosis
    }

    /// One session on its own — what a pass check compares. Cached alongside the pooled diagnosis.
    func diagnosis(for session: SavedSession) -> Diagnosis {
        refreshIfNeeded()
        if let d = perSessionDiagnosis[session.id] { return d }
        let d = ShotDoctor.diagnose(records: ShotDoctorModel.records(from: [session]))
        perSessionDiagnosis[session.id] = d
        return d
    }

    /// Spots with at least one accepted shot, near to far.
    var spotsWithData: [ShotSpot] {
        guard let d = diagnosis else { return [] }
        return d.perSpot.compactMap { p in ShotSpot(rawValue: p.spot.rawValue) }
    }

    /// The spot with the most accepted shots — the one a screen should open on.
    var busiestSpot: ShotSpot? {
        guard let d = diagnosis, let top = d.perSpot.max(by: { $0.n < $1.n }) else { return nil }
        return ShotSpot(rawValue: top.spot.rawValue)
    }

    // MARK: Answering a complaint

    /// Runs the deterministic matcher on free text. Returns nil when there is no data to answer with.
    @discardableResult
    func answerFreeText() -> ComplaintAnswer? {
        guard let d = diagnosis else { answer = nil; return nil }
        pickedSymptom = nil
        let a = SymptomEngine.answer(complaint: complaint, diagnosis: d, records: records, spot: nil)
        answer = a
        ActivityLog.shared.event("doctor.ask", [
            "mode": "text", "complaint": complaint, "matched": a.symptom?.id.rawValue,
            "unmatched": a.unmatchedReason != nil, "ranked": a.ranked.count, "plan": a.plan?.hypothesis.rawValue,
        ])
        return a
    }

    /// Runs a picked symptom, bypassing the matcher entirely.
    @discardableResult
    func ask(symptom id: SymptomID) -> ComplaintAnswer? {
        guard let d = diagnosis else { answer = nil; return nil }
        pickedSymptom = id
        let a = SymptomEngine.answer(symptom: id, diagnosis: d, records: records, spot: nil)
        answer = a
        ActivityLog.shared.event("doctor.ask", [
            "mode": "picked", "symptom": id.rawValue, "ranked": a.ranked.count, "plan": a.plan?.hypothesis.rawValue,
        ])
        return a
    }

    func clearAnswer() {
        answer = nil
        pickedSymptom = nil
    }

    // MARK: The most recent session at a spot, for the per-shot miss list

    func latestSession(at spot: ShotSpot) -> SavedSession? {
        store.sessions(at: spot).last
    }

    // MARK: The one active plan

    /// Everything the plan screen needs, already scored. `check` and `retention` are nil until the
    /// sessions they need exist, and their reasons say which session is missing.
    struct PlanProgress {
        var plan: ActivePlan
        var package: FixPackage
        var spot: ShotSpot
        var baseline: SavedSession?
        var baselineUnavailableReason: String?
        var followUp: SavedSession?
        var followUpUnavailableReason: String?
        var retention: SavedSession?
        var retentionUnavailableReason: String?
        var check: FixLibrary.PassCheckResult?
        var retentionResult: FixLibrary.RetentionResult?
    }

    /// The sessions saved at the plan's spot *after* the baseline, oldest first.
    private func sessionsAfterBaseline(_ plan: ActivePlan) -> [SavedSession] {
        guard let baseline = store.sessions.first(where: { $0.id == plan.baselineSessionID }) else { return [] }
        return store.sessions(at: plan.spot).filter { $0.date > baseline.date }
    }

    var planProgress: PlanProgress? {
        guard let plan = store.activePlan,
              let id = HypothesisID(rawValue: plan.hypothesis) else { return nil }
        let package = FixLibrary.package(for: id)
        let doctorSpot = DoctorSpot(rawValue: plan.spot.rawValue) ?? .other
        var p = PlanProgress(plan: plan, package: package, spot: plan.spot)

        guard let baseline = store.sessions.first(where: { $0.id == plan.baselineSessionID }) else {
            p.baselineUnavailableReason = "The session this plan was measured against has been deleted, so nothing can be scored against it. Start the plan again from a session that is still saved."
            return p
        }
        p.baseline = baseline
        let later = sessionsAfterBaseline(plan)
        guard let followUp = later.first else {
            p.followUpUnavailableReason = "No session has been saved at \(plan.spot.rawValue) since this plan was chosen. The check runs on the next one."
            return p
        }
        p.followUp = followUp
        let baselineDiagnosis = diagnosis(for: baseline)
        let followUpDiagnosis = diagnosis(for: followUp)
        p.check = FixLibrary.check(package.passCheck, baseline: baselineDiagnosis,
                                   followUp: followUpDiagnosis, spot: doctorSpot)
        guard later.count >= 2 else {
            p.retentionUnavailableReason = "Retention needs the session after the follow-up. One more saved session at \(plan.spot.rawValue) and it appears here."
            return p
        }
        let retention = later[1]
        p.retention = retention
        p.retentionResult = FixLibrary.retention(package.passCheck, baseline: baselineDiagnosis,
                                                 followUp: followUpDiagnosis,
                                                 retention: diagnosis(for: retention), spot: doctorSpot)
        return p
    }

    /// Writes back which sessions the check and the retention actually used, so the saved plan
    /// records its own history rather than recomputing it from dates every time.
    func recordPlanSessions() {
        guard let p = planProgress else { return }
        store.recordPlanSessions(followUp: p.followUp?.id, retention: p.retention?.id)
    }

    /// Start a plan against a baseline session. The baseline number is read out of that session's
    /// own diagnosis with the fix's own pass measure — not invented, and nil with a reason when the
    /// session does not carry it.
    func startPlan(hypothesis: HypothesisID, symptom: SymptomID?, spot: ShotSpot) {
        guard let baseline = store.sessions(at: spot).last else { return }
        let package = FixLibrary.package(for: hypothesis)
        let doctorSpot = DoctorSpot(rawValue: spot.rawValue) ?? .other
        let d = diagnosis(for: baseline)
        // `check` against itself is only used for its `baselineValue` read-out; the verdict is ignored.
        let readBack = FixLibrary.check(package.passCheck, baseline: d, followUp: d, spot: doctorSpot)
        let accepted = d.spot(doctorSpot)?.n ?? 0
        let plan = ActivePlan(
            id: UUID(),
            hypothesis: hypothesis.rawValue,
            symptom: symptom?.rawValue,
            spot: spot,
            baselineSessionID: baseline.id,
            baselineSessionDate: baseline.date,
            chosenDate: Date(),
            baselineMeasure: package.passCheck.measure.rawValue,
            baselineValue: readBack.baselineValue,
            baselineUnavailableReason: readBack.baselineValue == nil
                ? "That session carries no \(package.passCheck.measure.rawValue), so the plan starts with no baseline number and the check will say so rather than guess."
                : nil,
            baselineAcceptedShots: accepted)
        store.startPlan(plan)
    }

    func clearPlan() { store.clearPlan() }
}

// MARK: - Plain names

/// The taxonomy in words a shooter would use. The engine's identifiers are camelCase; nothing in
/// the UI shows an identifier.
enum DoctorNames {
    static func hypothesis(_ id: HypothesisID) -> String {
        switch id {
        case .speedUndershoot: return "Pushing the ball too softly"
        case .speedVariability: return "Release speed varies shot to shot"
        case .rangeStrengthLimit: return "Running out of power at range"
        case .rushedPreparation: return "Getting into the shot too quickly"
        case .armDominantDrive: return "Shooting mostly with the arm"
        case .flatArcGeometry: return "Arc too flat for the ball to fit"
        case .arcVersusTurnover: return "Arc sitting away from its own turnover point"
        case .releaseHeightDrift: return "Release height moving about"
        case .lateralAimBias: return "Aim sitting off to one side"
        case .lateralVariability: return "Left-right spread"
        case .spinAxisTilt: return "Spin axis tilted — diagonal rotation"
        case .forearmFlare: return "Forearm away from vertical"
        case .shoulderSquareness: return "Shoulders not square to the rim"
        case .withinSessionDrift: return "The shot drifting through the session"
        case .fatigueDrift: return "Fading late in the session"
        case .depthBiasShort: return "Landing short of the make band"
        case .depthBiasLong: return "Landing past the make band"
        case .sequencingDistalDominant: return "Arm firing before the legs"
        case .headInstability: return "Head moving through the shot"
        }
    }

    /// Verdict in a shooter's words, and whether it is a green light, a hold, or a dead end.
    static func verdict(_ v: HypothesisVerdict) -> String {
        switch v {
        case .supported: return "supported"
        case .notSupported: return "not supported"
        case .belowFloor: return "not enough shots yet"
        case .needsAnotherClip: return "cannot be measured from this camera position"
        case .noData: return "nothing measured for this"
        case .descriptive: return "reported, never scored"
        }
    }

    static func grade(_ g: ShotEvidenceGrade) -> String { g.letter }
}
