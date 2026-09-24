import Foundation
import Observation
import ShotGeometry

// MARK: - What a saved session keeps

/// One measured shot, flattened to numbers that survive a relaunch. The clip itself is not kept:
/// a saved shot is the block row the summary and the coaching card need, plus where in the clip it
/// came from so the shooter can find it again.
struct SavedShot: Codable, Sendable, Identifiable {
    var id: Int
    var windowStart: Double
    var windowEnd: Double
    var verdict: String              // "accept", "low confidence", "reject"
    var verdictReason: String?
    var outcome: String              // InferredOutcome.rawValue
    var outcomeReason: String
    var outcomeStrength: String?
    var gFit: Double
    var releaseAngleDegrees: Double?
    var releaseHeight: Double?
    var releaseSpeed: Double?
    var entryAngleDegrees: Double?
    var depthPastFrontRim: Double?
    var lateralDeviation: Double?
    var viewClass: String
    var elbowAtReleaseDegrees: Double?
    var elbowMaxNearReleaseDegrees: Double?
    var kneeMinimumDegrees: Double?
    var dipToReleaseSeconds: Double?
    var ballTopMarginPx: Double?
    /// Added 2026-09-14. Every field below is optional, so a file written before this build still
    /// decodes — an older saved session simply has no body row, and says so.
    var releaseDistance: Double?
    var bodyUnavailableReason: String?
    var fittedElbowAtReleaseDegrees: Double?
    var fittedElbowJitterDegrees: Double?
    var elbowExtensionPeakDegreesPerSecond: Double?
    var kneeExtensionPeakDegreesPerSecond: Double?
    var fittedKneeMinimumDegrees: Double?
    var jumpHeightMetres: Double?
    var dipDepthMetres: Double?
    var dipDepthNormalised: Double?
    var bodyDipToReleaseMilliseconds: Double?
    var chainOrder: [String]?
    var chainLagsMilliseconds: [Double]?
    var chainFrameFloorMilliseconds: Double?
    var proximalToDistal: Bool?
    var headStabilityPx: Double?
    var headStabilityNormalised: Double?
    var handRateAtRelease: Double?
    var shoulderLineYawDegrees: Double?
    /// The shooter's ankle-to-nose pixel span. Without it a metre from this shot can never be pooled
    /// with another session's, because there would be no way to tell the camera had moved.
    var shooterPixelHeight: Double?
    /// Added 2026-09-15. The shot's 3-D form — joints in the shooter's own frame on the
    /// phase-normalised clock (`ShotGeometry.ShotForm`). Kept only for shots the block rule
    /// **accepted**, because that is the population a `FormModel` may be built from, and because one
    /// form is about 10 kB. Optional, so every session written before this build still decodes.
    var form: ShotForm?
    var formUnavailableReason: String?

    init(shot: SessionShot, row: BlockRow) {
        id = row.id
        windowStart = shot.window.start
        windowEnd = shot.window.end
        verdict = row.verdict.label
        verdictReason = row.verdict.reason
        outcome = row.outcome.outcome.rawValue
        outcomeReason = row.outcome.reason
        outcomeStrength = row.outcome.strength
        gFit = row.gFit
        releaseAngleDegrees = row.releaseAngleDegrees
        releaseHeight = row.releaseHeight
        releaseSpeed = row.releaseSpeed
        entryAngleDegrees = row.entryAngleDegrees
        depthPastFrontRim = row.depthPastFrontRim
        lateralDeviation = row.lateralDeviation
        viewClass = row.viewClass.rawValue
        elbowAtReleaseDegrees = row.elbowAtReleaseDegrees
        elbowMaxNearReleaseDegrees = row.elbowMaxNearReleaseDegrees
        kneeMinimumDegrees = row.kneeMinimumDegrees
        dipToReleaseSeconds = row.dipToReleaseSeconds
        ballTopMarginPx = row.ballTopMarginPx
        releaseDistance = row.releaseDistance
        bodyUnavailableReason = row.bodyUnavailableReason
        fittedElbowAtReleaseDegrees = row.fittedElbowAtReleaseDegrees
        fittedElbowJitterDegrees = row.fittedElbowJitterDegrees
        elbowExtensionPeakDegreesPerSecond = row.elbowExtensionPeakDegreesPerSecond
        kneeExtensionPeakDegreesPerSecond = row.kneeExtensionPeakDegreesPerSecond
        fittedKneeMinimumDegrees = row.fittedKneeMinimumDegrees
        jumpHeightMetres = row.jumpHeightMetres
        dipDepthMetres = row.dipDepthMetres
        dipDepthNormalised = row.dipDepthNormalised
        bodyDipToReleaseMilliseconds = row.bodyDipToReleaseMilliseconds
        chainOrder = row.chainOrder
        chainLagsMilliseconds = row.chainLagsMilliseconds
        chainFrameFloorMilliseconds = row.chainFrameFloorMilliseconds
        proximalToDistal = row.proximalToDistal
        headStabilityPx = row.headStabilityPx
        headStabilityNormalised = row.headStabilityNormalised
        handRateAtRelease = row.handRateAtRelease
        shoulderLineYawDegrees = row.shoulderLineYawDegrees
        shooterPixelHeight = row.shooterPixelHeight
        // A shot restored from a crash checkpoint has no live `result` to read a form out of — the form
        // it was measured with is in the restored record itself. Take it from there, with its reason,
        // rather than writing `form: nil` and no explanation, which would be a silent loss.
        if shot.result == nil, let restored = shot.restored {
            form = restored.form
            formUnavailableReason = restored.formUnavailableReason
            return
        }
        // The form is kept for accepted shots only. A rejected window's body is still measured and
        // still shown on its own card; it is simply never pooled into a block's mean form.
        if row.verdict.isAccepted, var f = shot.result?.body?.form {
            f.shotID = row.id
            form = f
            formUnavailableReason = nil
        } else {
            form = nil
            formUnavailableReason = shot.result?.body?.formUnavailableReason
                ?? (row.verdict.isAccepted ? shot.result?.bodyUnavailableReason : "this shot was not accepted by the block rule, so its form is not kept for the block's mean")
        }
    }

    /// Back to the row the summary builder and the coach consume. The verdict keeps its reason so a
    /// saved low-confidence shot is still excluded from the statistics for the same stated reason.
    var row: BlockRow {
        let v: ShotAcceptance.Verdict
        switch verdict {
        case "accept": v = .accepted
        case "low confidence": v = .lowConfidence(verdictReason ?? "saved as low confidence")
        default: v = .rejected(verdictReason ?? "saved as rejected")
        }
        return BlockRow(id: id, verdict: v,
                        outcome: OutcomeInference(outcome: InferredOutcome(rawValue: outcome) ?? .unknown,
                                                  reason: outcomeReason, strength: outcomeStrength),
                        gFit: gFit, releaseAngleDegrees: releaseAngleDegrees, releaseHeight: releaseHeight,
                        releaseSpeed: releaseSpeed, entryAngleDegrees: entryAngleDegrees,
                        depthPastFrontRim: depthPastFrontRim, lateralDeviation: lateralDeviation,
                        viewClass: ViewClass(rawValue: viewClass) ?? .oblique,
                        elbowAtReleaseDegrees: elbowAtReleaseDegrees, elbowMaxNearReleaseDegrees: elbowMaxNearReleaseDegrees,
                        kneeMinimumDegrees: kneeMinimumDegrees, dipToReleaseSeconds: dipToReleaseSeconds,
                        ballTopMarginPx: ballTopMarginPx,
                        releaseDistance: releaseDistance,
                        bodyUnavailableReason: bodyUnavailableReason
                            ?? (fittedElbowAtReleaseDegrees == nil && headStabilityNormalised == nil
                                ? "this session was saved before the app measured the body model" : nil),
                        fittedElbowAtReleaseDegrees: fittedElbowAtReleaseDegrees,
                        fittedElbowJitterDegrees: fittedElbowJitterDegrees,
                        elbowExtensionPeakDegreesPerSecond: elbowExtensionPeakDegreesPerSecond,
                        kneeExtensionPeakDegreesPerSecond: kneeExtensionPeakDegreesPerSecond,
                        fittedKneeMinimumDegrees: fittedKneeMinimumDegrees,
                        jumpHeightMetres: jumpHeightMetres,
                        dipDepthMetres: dipDepthMetres,
                        dipDepthNormalised: dipDepthNormalised,
                        bodyDipToReleaseMilliseconds: bodyDipToReleaseMilliseconds,
                        chainOrder: chainOrder,
                        chainLagsMilliseconds: chainLagsMilliseconds,
                        chainFrameFloorMilliseconds: chainFrameFloorMilliseconds,
                        proximalToDistal: proximalToDistal,
                        headStabilityPx: headStabilityPx,
                        headStabilityNormalised: headStabilityNormalised,
                        handRateAtRelease: handRateAtRelease,
                        shoulderLineYawDegrees: shoulderLineYawDegrees,
                        shooterPixelHeight: shooterPixelHeight)
    }
}

/// Where on the floor a block was shot from. The cell the brief's n ≥ 30 rule counts in: shots from
/// different spots are different populations and are never pooled.
enum ShotSpot: String, Codable, CaseIterable, Identifiable, Sendable {
    case freeThrow = "Free throws"
    case elbow = "Elbow"
    case midRange = "Mid-range"
    case three = "Three"
    case collegeThree = "College three"
    case other = "Other"

    var id: String { rawValue }
}

struct SavedSession: Codable, Identifiable, Sendable {
    var id: UUID
    var date: Date
    var clipName: String
    var spot: ShotSpot
    var note: String
    var timeScale: Double
    var hfovDegrees: Double
    var rimAxisRatio: Double?
    var viewClass: String?
    var windows: Int
    var failed: Int
    var shots: [SavedShot]
    /// Added 2026-09-15. True when this session came from a **form clip** — the close-up with no rim
    /// in frame, where the shots were found by the body's own rise-and-release pattern and every ball
    /// number is unavailable by construction. Optional, so every session written before this build
    /// still decodes as what it is: a shot session.
    var formClip: Bool?
    /// `AnalysisModel.clipFingerprint` of the video this came from, so picking the same clip again is
    /// recognised. Optional: sessions saved before this build carry none and are never matched.
    var clipFingerprint: String?
    /// Added 2026-09-24. Which "up" the rim was solved with — the shooter's own trace, or the
    /// direction the phone measured while the clip was filmed — and how far apart the two were.
    /// Every number in this session is read along that direction, so its provenance is part of the
    /// record. Optional: sessions saved before this build carry none and say so rather than guess.
    var rimUpProvenance: String?

    var isFormClip: Bool { formClip == true }

    var rows: [BlockRow] { shots.map(\.row) }
    var summary: BlockSummary { BlockSummary.build(windows: windows, failed: failed, rows: rows) }
    var accepted: Int { shots.filter { $0.verdict == "accept" }.count }
}

// MARK: - The block's 3-D form

extension SavedSession {
    /// The mean form of this session's accepted shots, or a `FormModel` carrying the reason there
    /// is none. Built from the stored per-shot forms — never recomputed from video.
    var formModel: FormModel {
        let forms = shots.compactMap(\.form)
        guard !forms.isEmpty else {
            let why = shots.isEmpty
                ? "this session has no shots"
                : (shots.contains { $0.verdict == "accept" }
                   ? "this session was saved before the app measured the 3-D form, so its shots carry none"
                   : "no shot in this session was accepted by the block rule, so there is no form to average")
            return FormModel.unavailable(why, label: formLabel)
        }
        return FormModel.build(forms: forms, label: formLabel, spot: spot.rawValue,
                               sessionID: id.uuidString, date: date.timeIntervalSince1970)
    }

    var formLabel: String {
        let d = DateFormatter(); d.dateFormat = "d MMM"
        return "\(spot.rawValue), \(d.string(from: date))"
    }
}

extension SessionStore {
    /// Every saved session at one spot that has a form, newest first — what the viewer's
    /// "compare with an earlier session" picker offers.
    func sessionsWithForms(spot: ShotSpot? = nil, excluding id: UUID? = nil) -> [SavedSession] {
        sessions
            .filter { $0.id != id }
            .filter { spot == nil || $0.spot == spot }
            .filter { $0.shots.contains { $0.form != nil } }
            .sorted { $0.date > $1.date }
    }
}

// MARK: - The one active plan

/// The single fix the app is scoring right now (`docs/DESIGN-SHOT-DOCTOR-2026-09-14.md` §6: one fix
/// at a time, because two changes at once means neither can be scored).
///
/// It stores *which* fix, *where*, and the session its baseline numbers were read from — the fix
/// package itself is never stored, only looked up from `hypothesis`, so a package that improves
/// improves for a plan already running. The follow-up and retention session ids are written back
/// once those sessions exist, so the plan carries its own history.
struct ActivePlan: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    /// `HypothesisID.rawValue`.
    var hypothesis: String
    /// `SymptomID.rawValue` when the shooter came in through the Ask screen; nil otherwise.
    var symptom: String?
    var spot: ShotSpot
    /// The session the baseline was read from, and when that session was filmed.
    var baselineSessionID: UUID
    var baselineSessionDate: Date
    /// When the shooter chose the plan.
    var chosenDate: Date
    /// `PassMeasure.rawValue` — what the check will compare.
    var baselineMeasure: String
    /// The baseline number in that measure's own unit, or nil with the reason below.
    var baselineValue: Double?
    var baselineUnavailableReason: String?
    /// Accepted shots at the spot in the baseline session — the n every baseline sentence carries.
    var baselineAcceptedShots: Int
    /// Written back once the sessions exist.
    var followUpSessionID: UUID?
    var retentionSessionID: UUID?
}

// MARK: - Storage

/// Saved sessions, as one JSON file in the app's Application Support directory. No cloud, no
/// network (CLAUDE.md rule 6): the file never leaves the phone unless the shooter exports it.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [SavedSession] = []

    /// Saved shot sessions made from the same video, newest first (form clips excluded: a form clip
    /// and a shot session from one video are different analyses).
    func sessions(fromClip fingerprint: String?) -> [SavedSession] {
        guard let fingerprint else { return [] }
        return sessions.filter { $0.clipFingerprint == fingerprint && !$0.isFormClip }
    }

    /// The same question with form clips in the answer, newest first. The form-clip screen asks it
    /// this way because the duplicate it is trying to avoid *is* a form clip: the same recording was
    /// saved three times on 2026-09-14, 39 forms each time.
    func sessions(fromClip fingerprint: String?, includingFormClips: Bool) -> [SavedSession] {
        guard includingFormClips else { return sessions(fromClip: fingerprint) }
        guard let fingerprint else { return [] }
        return sessions.filter { $0.clipFingerprint == fingerprint }.sorted { $0.date > $1.date }
    }
    /// The one fix being scored, or nil. Kept in its own file so a session file written by an older
    /// build still decodes untouched.
    private(set) var activePlan: ActivePlan?
    private(set) var loadError: String?
    private(set) var saveError: String?

    static let fileName = "sessions.json"
    static let planFileName = "active-plan.json"

    init() { load(); loadPlan() }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ArcLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static var planFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(planFileName)
    }

    func load() {
        let url = SessionStore.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { sessions = []; return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([SavedSession].self, from: data).sorted { $0.date > $1.date }
            loadError = nil
        } catch {
            loadError = "could not read saved sessions: \(error)"
            sessions = []
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(sessions).write(to: SessionStore.fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "could not save sessions: \(error)"
        }
    }

    /// Save a session's measured shots. Only measured windows are kept (queued and failed ones have
    /// no numbers), and the count of failed windows is kept so the provenance line stays honest.
    ///
    /// This writes a **shot session** (`formClip` nil). A form clip must never come through here: it
    /// carries no ball numbers and would join the per-spot pooling that `sessions(at:)` does. Form
    /// clips have their own door, `saveFormClip`.
    @discardableResult
    func save(session: SessionModel, spot: ShotSpot, note: String, clipName: String, hfovDegrees: Double,
              clipFingerprint: String? = nil) -> SavedSession {
        let shots = session.shots.compactMap { shot -> SavedShot? in
            guard let row = shot.row else { return nil }
            return SavedShot(shot: shot, row: row)
        }
        let failed = session.shots.filter { if case .failed = $0.status { return true }; return false }.count
        var saved = SavedSession(id: UUID(), date: Date(), clipName: clipName, spot: spot, note: note,
                                 timeScale: session.timeScale, hfovDegrees: hfovDegrees,
                                 rimAxisRatio: session.rimAxisRatio, viewClass: session.dominantViewClass?.rawValue,
                                 windows: session.shots.count, failed: failed, shots: shots)
        saved.clipFingerprint = clipFingerprint
        saved.rimUpProvenance = session.rimUpProvenance
        sessions.insert(saved, at: 0)
        persist()
        ActivityLog.shared.event("session.saved", ["spot": spot.rawValue, "shots": shots.count, "accepted": saved.accepted, "note": note, "clip": clipName,
                                                   "rimUp": session.rimUpProvenance])
        return saved
    }

    /// Delete one saved session, and — when an `impact` is handed in — the files it owns.
    ///
    /// `impact` is the thing the shooter was shown and agreed to (`SessionDeletionImpact`). Without
    /// one the numbers go and every file stays, and the log says so: a delete never removes a
    /// recording or a 3-D export that nobody was told about.
    func delete(_ id: UUID, impact: SessionDeletionImpact? = nil) {
        let session = sessions.first { $0.id == id }
        var recordingDeleted = false
        var bodyFilesDeleted = 0
        if let impact {
            if impact.canDeleteRecording, let clip = impact.recording {
                clip.delete()
                recordingDeleted = !clip.fileExists
            }
            if impact.canDeleteBodyFiles {
                for dir in impact.bodyDirectories {
                    let json = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.pathExtension == "json" }
                    guard (try? FileManager.default.removeItem(at: dir)) != nil else { continue }
                    bodyFilesDeleted += json.count
                }
            }
        }
        ActivityLog.shared.event("session.deleted", [
            "id": id.uuidString,
            "spot": session?.spot.rawValue,
            "shots": session?.shots.count,
            "accepted": session?.accepted,
            "formClip": session?.isFormClip,
            "clip": session?.clipName,
            "hadRecording": impact?.recording != nil,
            "recordingDeleted": recordingDeleted,
            "recordingKeptReason": impact?.recordingKeptReason,
            "bodyFiles": impact?.bodyFileCount ?? 0,
            "bodyFilesDeleted": bodyFilesDeleted,
            "bodyKeptReason": impact?.bodyKeptReason,
            "practiceBlocksAffected": impact?.practiceBlocks.count ?? 0,
            "wasPlanBaseline": impact?.planBaselineNote != nil,
            "confirmedWithImpact": impact != nil,
        ])
        sessions.removeAll { $0.id == id }
        persist()
    }

    func update(_ session: SavedSession) {
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[i] = session
        persist()
    }

    // MARK: The active plan

    func loadPlan() {
        let url = SessionStore.planFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { activePlan = nil; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let plan = try? decoder.decode(ActivePlan.self, from: data) else {
            activePlan = nil
            return
        }
        activePlan = plan
    }

    private func persistPlan() {
        let url = SessionStore.planFileURL
        guard let plan = activePlan else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(plan).write(to: url, options: .atomic)
            saveError = nil
        } catch {
            saveError = "could not save the active plan: \(error)"
        }
    }

    /// Replaces whatever was active. One fix at a time is the rule, so this is a replacement, never
    /// an addition, and the screen that calls it says so first.
    func startPlan(_ plan: ActivePlan) {
        let previous = activePlan?.hypothesis
        activePlan = plan
        persistPlan()
        ActivityLog.shared.event("doctor.plan.started", [
            "hypothesis": plan.hypothesis, "symptom": plan.symptom, "spot": plan.spot.rawValue,
            "baselineMeasure": plan.baselineMeasure, "baselineValue": plan.baselineValue,
            "baselineN": plan.baselineAcceptedShots, "replaced": previous,
        ])
    }

    func clearPlan() {
        ActivityLog.shared.event("doctor.plan.cleared", ["hypothesis": activePlan?.hypothesis])
        activePlan = nil
        persistPlan()
    }

    /// Record which sessions the pass check and the retention rule actually used.
    func recordPlanSessions(followUp: UUID?, retention: UUID?) {
        guard var plan = activePlan else { return }
        guard plan.followUpSessionID != followUp || plan.retentionSessionID != retention else { return }
        plan.followUpSessionID = followUp
        plan.retentionSessionID = retention
        activePlan = plan
        persistPlan()
    }

    // MARK: Pooling across sessions — the only way the 30-shot floor is ever reached

    /// Shot sessions at one spot. **Form clips are not in here**: they carry no ball numbers at all,
    /// so pooling them with shot sessions would change the denominator of every release-speed, entry
    /// angle and depth statistic while adding nothing to the numerator. They pool separately
    /// (`formClipSessions(at:)`).
    func sessions(at spot: ShotSpot) -> [SavedSession] {
        sessions.filter { $0.spot == spot && !$0.isFormClip }.sorted { $0.date < $1.date }
    }

    /// Every saved shot from one spot as one block, oldest session first, ids renumbered so the
    /// drift rule's "shot order" means chronological order across sessions.
    func pooled(at spot: ShotSpot) -> PooledBlock {
        let ordered = sessions(at: spot)
        var rows: [BlockRow] = []
        var boundaries: [(sessionID: UUID, firstRowID: Int)] = []
        for s in ordered {
            boundaries.append((s.id, rows.count + 1))
            for shot in s.shots.sorted(by: { $0.id < $1.id }) {
                var r = shot.row
                r.id = rows.count + 1
                rows.append(r)
            }
        }
        let summary = BlockSummary.build(windows: ordered.map(\.windows).reduce(0, +),
                                         failed: ordered.map(\.failed).reduce(0, +), rows: rows)
        let classes = ordered.compactMap(\.viewClass).compactMap(ViewClass.init(rawValue:))
        let dominant = Dictionary(grouping: classes, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        let ratios = ordered.compactMap(\.rimAxisRatio)
        return PooledBlock(spot: spot, sessions: ordered, summary: summary, viewClass: dominant,
                           rimAxisRatio: ratios.isEmpty ? nil : ratios.min(), boundaries: boundaries)
    }
}

/// One spot's shots across every saved session, plus the per-session numbers a progress view lists.
struct PooledBlock {
    var spot: ShotSpot
    var sessions: [SavedSession]
    var summary: BlockSummary
    var viewClass: ViewClass?
    var rimAxisRatio: Double?
    var boundaries: [(sessionID: UUID, firstRowID: Int)]

    var coaching: CoachingCard {
        SessionCoach.card(summary: summary, viewClass: viewClass, rimAxisRatio: rimAxisRatio)
    }

    /// The per-session line of the progress table: accepted n, release speed mean ± SD, entry angle
    /// mean ± SD, misses long/short. Every value is `nil` with a reason when the session had nothing.
    struct SessionLine: Identifiable {
        var id: UUID
        var date: Date
        var accepted: Int
        var releaseSpeed: BlockStat?
        var entryAngle: BlockStat?
        var depth: BlockStat?
        var makes: Int
        var misses: Int
    }

    var lines: [SessionLine] {
        sessions.map { s in
            let sum = s.summary
            return SessionLine(id: s.id, date: s.date, accepted: sum.accepted, releaseSpeed: sum.releaseSpeed,
                               entryAngle: sum.entryAngleDegrees, depth: sum.depthPastFrontRim,
                               makes: sum.makes, misses: sum.misses)
        }
    }
}

// MARK: - Form clips (2026-09-15)

extension SessionStore {
    /// Save a **form clip**: the close-up with no rim in frame, whose shots were found by the body's
    /// own rise-and-release pattern and measured by the body model alone.
    ///
    /// It goes into the same file as every other session, with `formClip` true, because a shooter's
    /// history is one history — but it never joins a shot session's pooling: `sessions(at:)` leaves
    /// form clips out, so no release-speed, entry-angle or depth statistic can quietly acquire a
    /// denominator from a clip that measured none of them.
    @discardableResult
    func saveFormClip(shots: [SavedShot], spot: ShotSpot, note: String, clipName: String,
                      hfovDegrees: Double, timeScale: Double, windows: Int, failed: Int,
                      clipFingerprint: String? = nil) -> SavedSession {
        var saved = SavedSession(id: UUID(), date: Date(), clipName: clipName, spot: spot, note: note,
                                 timeScale: timeScale, hfovDegrees: hfovDegrees,
                                 rimAxisRatio: nil, viewClass: nil,
                                 windows: windows, failed: failed, shots: shots, formClip: true)
        saved.clipFingerprint = clipFingerprint
        sessions.insert(saved, at: 0)
        persist()
        ActivityLog.shared.event("formclip.saved", ["spot": spot.rawValue, "shots": shots.count,
                                                    "forms": shots.filter { $0.form != nil }.count,
                                                    "note": note, "clip": clipName,
                                                    "fingerprint": clipFingerprint])
        return saved
    }

    /// Every saved form clip at one spot, oldest first. The pool the form-clip progress row counts,
    /// kept apart from `sessions(at:)` on purpose.
    func formClipSessions(at spot: ShotSpot) -> [SavedSession] {
        sessions.filter { $0.spot == spot && $0.isFormClip }.sorted { $0.date < $1.date }
    }

    /// Every form clip, newest first.
    var formClipSessions: [SavedSession] { sessions.filter(\.isFormClip).sorted { $0.date > $1.date } }

    /// The mean form of every form clip saved at one spot, or a `FormModel` carrying the reason
    /// there is none. Built from the stored per-shot forms; no video is read.
    func formClipFormModel(at spot: ShotSpot) -> FormModel {
        let forms = formClipSessions(at: spot).flatMap { $0.shots.compactMap(\.form) }
        guard !forms.isEmpty else {
            return FormModel.unavailable("no form clip saved at \(spot.rawValue) has a shot with a 3-D form yet",
                                         label: spot.rawValue)
        }
        return FormModel.build(forms: forms, label: "\(spot.rawValue), form clips", spot: spot.rawValue)
    }
}
