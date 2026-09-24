import Foundation
import Observation
import PhotosUI
import ShotGeometry
import ShotVideo
import SwiftUI

/// Drives import → probe → rim → shot → results. All decoding and fitting runs off the main actor
/// in detached tasks; only the published state is touched here.
@MainActor
@Observable
final class AnalysisModel {
    enum Phase: Equatable {
        case idle
        case importing
        case probing
        case probed
        case tracking
        case tracked
        case failed(String)
    }

    // MARK: Clip

    var phase: Phase = .idle
    var clip: ImportedClip?
    var probe: VideoProbeResult?
    var run: TrajectoryRun?
    var progressText: String?

    /// How much of the decoded timeline the survey tracker looks at (seconds of *decoded* PTS, which
    /// for a slo-mo file is the stretched timeline, not wall-clock time).
    static let trackingWindowSeconds = 10.0

    // MARK: Timing and lens

    /// Slow-motion factor: file time ÷ this = real time. A 120 fps clip exported with 30 fps
    /// timestamps plays 4× slow, so every timestamp must be divided by 4 before any physics.
    var timeScale: Double = 1
    /// The user's answer to "is this clip slow motion?" — the app cannot tell when the exporter
    /// rewrote the timestamps instead of using an edit list (`sloMoStretch` is then 1.00×).
    var isSloMo = false
    /// True when the file looks like a slo-mo export with rewritten timestamps (≈30 fps, no stretch).
    var sloMoSuspected = false
    /// Horizontal field of view of the lens that shot the clip. 1080p120 slo-mo on this phone ≈ 48°.
    var hfovDegrees: Double = 48

    static let defaultSloMoFactor = 4.0

    var realFrameRate: Double? {
        guard let p = probe, p.decodedFrames >= 2, p.measuredFrameRate > 0 else { return nil }
        return p.measuredFrameRate * timeScale
    }

    var intrinsics: CameraIntrinsics? {
        guard let p = probe, p.width > 0, p.height > 0 else { return nil }
        return CameraIntrinsics(width: p.width, height: p.height, horizontalFOVDegrees: hfovDegrees)
    }

    var fileDuration: Double {
        guard let p = probe else { return 0 }
        return max(p.lastPTS, p.trackDuration)
    }

    /// What identifies *this video* across imports: the temp file name changes every time a clip is
    /// picked from Photos, but its track duration, frame count and size do not. Two different clips of
    /// the same length to the millisecond and the same frame count are, for this purpose, the same.
    var clipFingerprint: String? {
        guard let p = probe, p.decodedFrames > 0 else { return nil }
        return String(format: "%dx%d/%d/%.3f", p.width, p.height, p.decodedFrames, p.trackDuration)
    }

    /// Applies what the probe measured; leaves the slo-mo question to the user when the file hides it.
    private func applyProbeDefaults(_ p: VideoProbeResult) {
        if p.sloMoStretch > 1.05 {
            timeScale = p.sloMoStretch          // an honest edit list: the file says how slow it is
            isSloMo = true
            sloMoSuspected = false
        } else {
            timeScale = 1
            isSloMo = false
            sloMoSuspected = p.measuredFrameRate > 28 && p.measuredFrameRate < 32
        }
        windowStart = 0
    }

    func setSloMo(_ on: Bool) {
        ActivityLog.shared.event("timing.sloMo", ["on": on])
        isSloMo = on
        if on {
            let stretch = probe?.sloMoStretch ?? 1
            timeScale = stretch > 1.05 ? stretch : Self.defaultSloMoFactor
        } else {
            timeScale = max(1, probe?.sloMoStretch ?? 1)
        }
        invalidateAnalysis()
    }

    // MARK: Rim

    /// Boundary points around the ring, in image pixels (top-left origin).
    var rimPoints: [SIMD2<Double>] = []
    var calibration: RimCalibration?
    var calibrationError: String?
    /// The frame time the rim was marked on, so the UI can say which picture the points came from.
    var rimFrameTime: Double?

    func calibrateRim() {
        guard let k = intrinsics else {
            calibrationError = "no clip has been probed yet, so the frame size is unknown"
            return
        }
        // Whichever way the rim is solved, the comparison is made against the *free* solve, so the
        // number the shooter and the log see means the same thing in both cases.
        let agreement = RimGravity.compare(boundaryPoints: rimPoints, intrinsics: k,
                                           measuredUp: measuredCameraUp,
                                           measuredUnavailableReason: measuredUpUnavailableReason)
        rimUpAgreement = agreement

        // Gravity arbitrates between the shooter's active points and a remembered auto-found
        // candidate, when both exist and differ. This is a different question from `agreement` above,
        // which is only ever about whatever is currently active — see RimGravity.arbitrate.
        var autoFoundAgreement: RimUpAgreement?
        var arbitration: RimGravity.Arbitration?
        var pointsToCalibrate = rimPoints
        if let autoFoundRimPoints, autoFoundRimPoints != rimPoints, autoFoundRimPoints.count >= 6 {
            let a = RimGravity.compare(boundaryPoints: autoFoundRimPoints, intrinsics: k,
                                       measuredUp: measuredCameraUp,
                                       measuredUnavailableReason: measuredUpUnavailableReason)
            autoFoundAgreement = a
            let decision = RimGravity.arbitrate(tracedDisagreement: agreement.disagreement,
                                                autoFoundDisagreement: a.disagreement)
            arbitration = decision
            if decision.winner == .autoFound, !rimArbitrationOverriddenByShooter {
                pointsToCalibrate = autoFoundRimPoints
            }
        }
        rimArbitration = arbitration

        do {
            var options = RimCalibrationOptions()
            // The shooter's trace is the default and is never overridden without their say-so; the
            // measured direction is used only after they have chosen it.
            if rimUpSolvedWithGravity, let up = measuredCameraUp { options.knownUp = up }
            let c = try RimCalibrator.calibrate(boundaryPoints: pointsToCalibrate, intrinsics: k, options: options)
            calibration = c
            calibrationError = nil
            logRimCalibrated(c, agreement: agreement, autoFoundAgreement: autoFoundAgreement, arbitration: arbitration)
        } catch {
            calibration = nil
            calibrationError = "\(error)"
            ActivityLog.shared.event("rim.failed", ["points": rimPoints.count, "error": "\(error)",
                                                    "upSource": rimUpSolvedWithGravity ? "gravity" : "trace"])
        }
        invalidateAnalysis()
    }

    func clearRim() {
        rimPoints = []
        calibration = nil
        calibrationError = nil
        rimFindNote = nil
        rimUpAgreement = nil
        rimUpSolvedWithGravity = false
        rimTrustAnswered = false
        rimArbitration = nil
        rimArbitrationOverriddenByShooter = false
        invalidateAnalysis()
    }

    /// A truly new clip has no rim-finder history at all — unlike `clearRim()` (called whenever the
    /// shooter only wants to retrace the *same* clip), this drops the remembered auto-found candidate
    /// too, so an old clip's finder result can never be arbitrated against a new clip's trace.
    private func forgetRimFinderHistory() {
        autoFoundRimPoints = nil
        rimFinderHasRun = false
        rimArbitration = nil
        rimArbitrationOverriddenByShooter = false
    }

    // MARK: Which way is down

    /// Up (away from the floor) in *this clip's* camera frame, as the phone's own sensors measured
    /// it while the clip was being filmed — the thing `RimCalibrationOptions.knownUp` wants.
    ///
    /// It comes from the recording, not from the moment the trace is made: the trace happens
    /// afterwards, with the phone in the shooter's hand, and gravity then says which way *the hand*
    /// is pointing, which is nothing to do with how the camera stood on its tripod. A clip that came
    /// from Photos was filmed by something that recorded no such thing, so it has none.
    private(set) var measuredCameraUp: SIMD3<Double>?
    /// Why `measuredCameraUp` is nil — always a sentence, never a silent default (CLAUDE.md rule 1).
    private(set) var measuredUpUnavailableReason: String?
    /// What the trace and the phone say about each other, refreshed by every `calibrateRim()`.
    private(set) var rimUpAgreement: RimUpAgreement?
    /// True once the shooter has chosen to solve the rim with the measured direction instead of
    /// their own trace. Only they can set it.
    private(set) var rimUpSolvedWithGravity = false
    /// True once the shooter has answered a large disagreement one way or the other, so the warning
    /// stops asking. Their trace is never discarded or overridden until they answer.
    private(set) var rimTrustAnswered = false

    /// The boundary points `RimFinder` most recently proposed for this clip, kept even after the
    /// shooter starts hand-tracing over them — gravity needs both candidates in hand to arbitrate
    /// between them (`RimGravity.arbitrate`). Nil until `findRimAutomatically()` succeeds once for
    /// this clip; cleared only by a fresh clip or a fresh find, never by `clearRim()` alone.
    private(set) var autoFoundRimPoints: [SIMD2<Double>]?
    /// True once `findRimAutomatically()` has completed at least once for the current clip, whether
    /// or not it found anything — logged so the fleet's data says whether the finder was even tried.
    private(set) var rimFinderHasRun = false
    /// What gravity decided between the shooter's active points and `autoFoundRimPoints` the last
    /// time `calibrateRim()` ran. Nil when there was nothing to arbitrate: no second candidate, or no
    /// measured gravity for this clip.
    private(set) var rimArbitration: RimGravity.Arbitration?
    /// True once the shooter has explicitly chosen to keep their own trace after gravity favoured the
    /// auto-found candidate over it. Persists across recalibration so the choice sticks; a fresh clip
    /// or a fresh find gives gravity another look.
    private(set) var rimArbitrationOverriddenByShooter = false

    /// True when the trace and the phone disagree by more than `RimUpAgreement.tolerance` and the
    /// shooter has not yet said what to do about it. Never true when gravity has already resolved the
    /// disagreement by picking the auto-found candidate (`rimArbitrationHasSomethingToSay` covers
    /// that case instead) — the shooter is never asked the same question twice.
    var rimNeedsGravityDecision: Bool {
        guard (rimUpAgreement?.disagrees ?? false), !rimTrustAnswered, calibration != nil else { return false }
        if rimArbitration?.usedRimTheShooterDidNotDraw == true, !rimArbitrationOverriddenByShooter { return false }
        return true
    }

    /// The shooter chose the phone's measured direction. Re-solves; their points are untouched.
    func useMeasuredUpForRim() {
        guard measuredCameraUp != nil else { return }
        rimUpSolvedWithGravity = true
        rimTrustAnswered = true
        ActivityLog.shared.event("rim.upChoice", ["choice": "gravity",
                                                  "disagreementDeg": rimUpAgreement?.disagreement.map(ShotGeometry.Angle.degrees)])
        calibrateRim()
    }

    /// The shooter looked at the warning and kept their trace. Nothing is re-solved except to put
    /// the trace's own normal back if the measured one had been chosen before.
    func keepTracedUpForRim() {
        rimTrustAnswered = true
        ActivityLog.shared.event("rim.upChoice", ["choice": "trace",
                                                  "disagreementDeg": rimUpAgreement?.disagreement.map(ShotGeometry.Angle.degrees)])
        if rimUpSolvedWithGravity {
            rimUpSolvedWithGravity = false
            calibrateRim()
        }
    }

    /// One line saying which of the two the current calibration was solved with, for the session
    /// record and for anywhere the session's numbers are shown. Never "unknown".
    var rimUpProvenance: String {
        guard calibration != nil else { return "no rim has been calibrated yet" }
        if rimArbitration?.usedRimTheShooterDidNotDraw == true, !rimArbitrationOverriddenByShooter {
            let gap = rimArbitration?.tracedDisagreement.map { String(format: "%.1f°", ShotGeometry.Angle.degrees($0)) }
            return gap.map { "Measured from the ring ArcLab found automatically; your traced ring was \($0) from the phone's own sense of down." }
                ?? "Measured from the ring ArcLab found automatically."
        }
        let a = rimUpAgreement
        let gap = a?.disagreement.map { String(format: "%.1f°", ShotGeometry.Angle.degrees($0)) }
        if rimUpSolvedWithGravity {
            return gap.map { "Measured with the phone's own sense of down; the traced ring was \($0) away from it." }
                ?? "Measured with the phone's own sense of down."
        }
        if let gap, a?.disagrees == true {
            return "Measured from the ring as traced, which is \(gap) from the phone's own sense of down — shots far from the ring may read low."
        }
        if let gap {
            return "Measured from the ring as traced; it agrees with the phone's own sense of down to \(gap)."
        }
        let why = measuredUpUnavailableReason ?? a?.measuredUnavailableReason
            ?? "nothing recorded which way was down while this clip was filmed"
        return "Measured from the ring as traced; \(why), so nothing independent checked it."
    }

    /// Takes the measured direction from a clip recorded by the app, or the reason there is none.
    /// `noRecordReason` is used when there is no ArcLab recording behind this clip at all, and must
    /// say *why* there is none — the two cases read very differently to a shooter.
    private func adoptGravity(from recorded: RecordedClip?, noRecordReason: String) {
        measuredCameraUp = recorded?.measuredCameraUp
        measuredUpUnavailableReason = recorded.map { $0.measuredUpUnavailableReason } ?? noRecordReason
        rimUpSolvedWithGravity = false
        rimTrustAnswered = false
        rimUpAgreement = nil
    }

    /// True when `RimTrustCard` has anything at all to show. Screens built out of list rows ask
    /// first, so an empty row is never laid out.
    var rimTrustHasSomethingToSay: Bool {
        if rimTrustHeadline != nil, !rimTrustAnswered { return true }
        if rimArbitrationHasSomethingToSay { return true }
        if !rimTrustWarnings.isEmpty { return true }
        return rimTrustAnswered && calibration != nil
    }

    private func logRimCalibrated(_ c: RimCalibration, agreement: RimUpAgreement,
                                  autoFoundAgreement: RimUpAgreement?, arbitration: RimGravity.Arbitration?) {
        func deg(_ r: Double?) -> Double? { r.map(ShotGeometry.Angle.degrees) }
        // Logged on every calibration, warned about or not: this is how the next sessions answer
        // whether bad traces are what refuses two thirds of the three-point shots.
        ActivityLog.shared.event("rim.calibrated", [
            "points": rimPoints.count, "distance": c.distanceToRim, "axisRatio": c.ellipse.axisRatio,
            "residualPx": c.ellipseResidualPx, "warnings": c.warnings.joined(separator: " | "),
            "frameTime": rimFrameTime, "hfov": hfovDegrees,
            "tracedRollDeg": deg(agreement.tracedRoll), "tracedPitchDeg": deg(agreement.tracedPitch),
            "tracedUnavailable": agreement.tracedUnavailableReason,
            "gravityRollDeg": deg(agreement.measuredRoll), "gravityPitchDeg": deg(agreement.measuredPitch),
            "upDisagreementDeg": deg(agreement.disagreement),
            "motionData": agreement.measuredUp != nil,
            "motionUnavailable": agreement.measuredUnavailableReason,
            "upSource": rimUpSolvedWithGravity ? "gravity" : "trace",
            "implausibleRoll": abs(c.roll) > RimGravity.implausibleTripodRoll,
            "clipSource": clip?.source == .recordedInApp ? "recordedInApp" : "imported",
            // Gravity arbitration: the auto-found candidate's own disagreement, whether the finder
            // ran and produced one at all, the margin used, and which candidate actually reached
            // `RimCalibrator.calibrate` — logged every time, shown to the shooter or not, so the
            // fleet's next sessions can measure whether hand traces are the cause of the three-point
            // acceptance rate (docs/research/three-point-acceptance-2026-09-24.md).
            "rimFinderRan": rimFinderHasRun,
            "autoFoundCandidateAvailable": autoFoundRimPoints != nil,
            "autoFoundDiffersFromActiveTrace": autoFoundRimPoints != nil && autoFoundRimPoints != rimPoints,
            "autoFoundUpDisagreementDeg": deg(autoFoundAgreement?.disagreement),
            "arbitrationMarginDeg": ShotGeometry.Angle.degrees(RimGravity.arbitrationMargin),
            "arbitrationWinner": arbitration?.winner.rawValue,
            "arbitrationOverriddenByShooter": rimArbitrationOverriddenByShooter,
        ])
    }

    // MARK: What the shooter is told

    /// The plain-language warnings about the calibration that `RimCalibrator` cannot make, because
    /// they need either a sensor or a convention. Empty when there is nothing to say.
    var rimTrustWarnings: [String] {
        guard let c = calibration else { return [] }
        var out: [String] = []
        if abs(c.roll) > RimGravity.implausibleTripodRoll, !rimUpSolvedWithGravity {
            out.append(String(format:
                "This trace says the phone was rolled %.0f° over while it filmed. A phone on a tripod normally stands within a few degrees of level, so that is usually a sign the trace has caught something that is not the ring — the backboard bracket, or a loop of net. Nothing was measured to fix the %.0f° line: it is a convention chosen because tripods stand near level, not evidence that your trace is wrong.",
                abs(ShotGeometry.Angle.degrees(c.roll)), ShotGeometry.Angle.degrees(RimGravity.implausibleTripodRoll)))
        }
        return out
    }

    /// The headline of the disagreement card, or nil when there is no disagreement to report.
    ///
    /// Never fires when gravity has already resolved the disagreement itself by switching to the
    /// auto-found candidate (`rimArbitrationHeadline` covers that instead) — the two cards would
    /// otherwise say the same thing about the same trace in two different voices.
    var rimTrustHeadline: String? {
        guard rimUpAgreement?.disagrees == true else { return nil }
        if rimArbitrationHasSomethingToSay { return nil }
        return "Your trace and the phone disagree about which way is down"
    }

    /// What is wrong and what it costs, in the shooter's words rather than in geometry.
    var rimTrustMessage: String? {
        guard let a = rimUpAgreement, a.disagrees, let gap = a.disagreement else { return nil }
        if rimArbitrationHasSomethingToSay { return nil }
        let three = a.heightErrorMetres(atDistance: RimUpAgreement.threePointReleaseDistance) ?? 0
        let free = a.heightErrorMetres(atDistance: RimUpAgreement.freeThrowReleaseDistance) ?? 0
        return String(format: """
        The ring you traced is tilted %.0f° away from the direction the phone itself says is down. Both cannot be right, and it is nearly always the trace: one tap that lands on the backboard bracket or on a loop of net tips the ring over without looking wrong on screen.

        Right at the ring this costs nothing — which is why the ring still looks right — and the cost grows with every step you take back. A shot from the three-point line would have its release height measured about %.1f m out, a free throw about %.1f m, and shots that far out are thrown away as impossible.

        Tracing the ring again is the surer fix. Otherwise ArcLab can measure this clip using the phone's own sense of down and keep the size and position your trace gave.
        """, ShotGeometry.Angle.degrees(gap), three, free)
    }

    // MARK: Gravity choosing between a hand trace and an auto-found trace

    /// True when this calibration is using boundary points the shooter did not draw themselves —
    /// gravity picked the auto-found candidate over their active trace — and they have not yet said
    /// to keep their own trace instead. False the instant either side stops being true: the trace
    /// wins the tie, or the shooter has already answered.
    var rimArbitrationHasSomethingToSay: Bool {
        rimArbitration?.usedRimTheShooterDidNotDraw == true && !rimArbitrationOverriddenByShooter
    }

    /// The headline for the "gravity used a rim you didn't draw" card, or nil when there is nothing
    /// to report — including the good-trace case, where `RimTrustCard` says nothing at all.
    var rimArbitrationHeadline: String? {
        guard rimArbitrationHasSomethingToSay else { return nil }
        return "This shot uses the ring ArcLab found on its own, not the one you traced"
    }

    /// One short line saying why, plus the cost — reusing `RimTrustCard`'s voice for the same
    /// underlying question ("which way is down") rather than inventing a second one.
    var rimArbitrationMessage: String? {
        guard rimArbitrationHasSomethingToSay,
              let tracedDeg = rimArbitration?.tracedDisagreement.map(ShotGeometry.Angle.degrees),
              let autoDeg = rimArbitration?.autoFoundDisagreement.map(ShotGeometry.Angle.degrees) else { return nil }
        return String(format: "Your traced ring was %.0f° from the phone's own sense of down; the ring ArcLab found on its own was only %.0f°, so this shot uses that one instead.",
                     tracedDeg, autoDeg)
    }

    /// The margin explanation, always shown under the arbitration card. States plainly, in both code
    /// and here, that the number is a convention rather than a measured result — CLAUDE.md rule 1's
    /// "never fabricate a number" cuts the other way too: never dress up a convention as a finding.
    var rimArbitrationMarginCaption: String {
        String(format: "ArcLab only makes this swap when the two disagree by more than %.0f° — a convention chosen to avoid switching over a close call, not a measured finding.",
              ShotGeometry.Angle.degrees(RimGravity.arbitrationMargin))
    }

    /// The shooter looked at the swap and wants their own trace back. The trace was never touched —
    /// this only changes which candidate `calibrateRim()` picks.
    func useTracedRimOverArbitration() {
        rimArbitrationOverriddenByShooter = true
        ActivityLog.shared.event("rim.arbitrationChoice", ["choice": "trace",
                                                            "tracedDisagreementDeg": rimArbitration?.tracedDisagreement.map(ShotGeometry.Angle.degrees),
                                                            "autoFoundDisagreementDeg": rimArbitration?.autoFoundDisagreement.map(ShotGeometry.Angle.degrees)])
        calibrateRim()
    }

    /// What the automatic finder said about its proposal (confidence, warnings) or why it found nothing.
    var rimFindNote: String?
    var rimFinding = false

    /// Propose the rim from the clip itself: try a few ball-free-looking frames spread over the clip, keep
    /// the proposal with the highest confidence, calibrate from it. The user confirms on the marking screen.
    /// `RimFinder` (Packages/ShotVideo) works on one frame: orange-chroma ring, RANSAC ellipse with the rim
    /// priors, inner-edge refinement; it returns a confidence and plain-language warnings, never a guess.
    func findRimAutomatically(frameTimes: [Double]? = nil) async {
        guard let clip, !rimFinding else { return }
        rimFinding = true
        defer { rimFinding = false }
        rimFinderHasRun = true
        rimArbitrationOverriddenByShooter = false   // a fresh find deserves a fresh look from gravity
        let duration = fileDuration
        let times = (frameTimes ?? [3, 15, 45, 90, 180].map { min($0, max(0, duration - 0.5)) })
            .reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }
        let url = clip.url
        var best: (result: RimFindResult, time: Double)? = nil
        var failures: [String] = []
        let t0 = Date()
        for t in times {
            let outcome: (RimFindOutcome, Double)? = await Task.detached(priority: .userInitiated) {
                guard let f = try? await FrameLoader.frame(url: url, time: t), let cg = f.image.cgImage else { return nil }
                return (RimFinder.findWithDiagnosis(in: cg), f.pts)
            }.value
            guard let (o, pts) = outcome else { failures.append(String(format: "%.0f s: frame could not be decoded", t)); continue }
            switch o {
            case .found(let r):
                if best == nil || r.confidence > best!.result.confidence { best = (r, pts) }
                if r.confidence >= 0.85 { break }
            case .notFound(let reason):
                failures.append(String(format: "%.0f s: %@", t, reason))
            }
            if let b = best, b.result.confidence >= 0.85 { break }
        }
        let seconds = Date().timeIntervalSince(t0)
        if let b = best {
            rimPoints = b.result.boundaryPoints
            autoFoundRimPoints = b.result.boundaryPoints
            rimFrameTime = b.time
            let conf = b.result.confidence
            var note = String(format: "Ring found on the frame at %.1f s (confidence %.2f, %d of the ring's boundary measured, residual %.1f px).",
                              b.time, conf, b.result.rawInwardEdgePoints.count, b.result.rmsResidualPx)
            if conf < 0.6 { note += " Low confidence: treat this as a starting point — open the marking screen and check both ends of the ring." }
            if !b.result.warnings.isEmpty { note += " " + b.result.warnings.joined(separator: " ") }
            rimFindNote = note
            calibrateRim()
            ActivityLog.shared.event("rim.found", ["confidence": conf, "frameTime": b.time, "residualPx": b.result.rmsResidualPx,
                                                  "warnings": b.result.warnings.joined(separator: " | "), "tried": times.count, "seconds": seconds])
        } else {
            rimFindNote = "The ring was not found automatically (" + (failures.first ?? "no frame examined") + "). Mark it by hand: tap 6 or more points around the inside of the ring."
            // This attempt found nothing to arbitrate with; an earlier candidate (if any) is stale for
            // this frame too, so it is dropped rather than left to be compared against a new trace.
            autoFoundRimPoints = nil
            ActivityLog.shared.event("rim.notFound", ["reasons": failures.joined(separator: " | "), "tried": times.count, "seconds": seconds])
        }
    }

    // MARK: Shot window (file time)

    var windowStart: Double = 0
    var windowLength: Double = 7
    var windowEnd: Double { windowStart + windowLength }

    // MARK: Analysis

    var analysisBusy = false
    var analysisStage: String?
    var analysisError: String?
    var analysis: ShotAnalysis?
    var analysisSamples: [ImageSample] = []
    var analysisNotes: [String] = []
    var analysisPose: ShotPoseResult?
    var analysisBody: ShotBodyResult?
    var analysisBodyUnavailableReason: String?
    /// Window the current result was produced from, so results can never be read as belonging to
    /// a window the user has since moved.
    var analysedWindow: ClosedRange<Double>?

    private func invalidateAnalysis() {
        analysis = nil
        analysisSamples = []
        analysisNotes = []
        analysisPose = nil
        analysisBody = nil
        analysisBodyUnavailableReason = nil
        analysisError = nil
        analysedWindow = nil
    }

    /// The analysed shot packaged for `ResultsView`, or nil when nothing has been analysed.
    var resultContext: ShotResultContext? {
        guard let clip, let analysis, let k = intrinsics else { return nil }
        return ShotResultContext(title: "Shot", clipURL: clip.url, timeScale: timeScale, intrinsics: k,
                                 rimPoints: rimPoints, analysis: analysis, samples: analysisSamples,
                                 notes: analysisNotes, pose: analysisPose,
                                 body: analysisBody, bodyUnavailableReason: analysisBodyUnavailableReason,
                                 window: analysedWindow, verdict: nil, outcome: nil)
    }

    var canAnalyse: Bool { clip != nil && calibration != nil && !analysisBusy }

    // MARK: Actions

    func importAndProbe(_ item: PhotosPickerItem) {
        phase = .importing
        clip = nil; probe = nil; run = nil; progressText = nil
        probeRetryNote = nil
        clearRim()
        forgetRimFinderHistory()
        adoptGravity(from: nil, noRecordReason: "this clip came from Photos, so nothing recorded which way was down while it was filmed — only a clip filmed in ArcLab carries that")
        let log = ActivityLog.shared
        Task {
            do {
                let imported = try await log.timed("clip.import") { try await Task.detached { try await ClipImporter.importClip(from: item) }.value }
                clip = imported
                phase = .probing
                let url = imported.url
                let result = try await probeWithRetry(url: url, source: imported.source.rawValue, log: log)
                probe = result
                applyProbeDefaults(result)
                log.event("clip.ready", ["file": url.lastPathComponent, "width": result.width, "height": result.height, "fps": result.measuredFrameRate,
                                         "frames": result.decodedFrames, "stretch": result.sloMoStretch, "timeScale": timeScale, "sloMoSuspected": sloMoSuspected,
                                         "fileSeconds": fileDuration])
                phase = .probed
            } catch {
                log.event("clip.failed", ["error": "\(error)"])
                if SessionModel.isDecodingInterruption(error) {
                    phase = .failed("iOS interrupted the video decoder while the clip was being read — it does that when ArcLab is not on screen. The clip is fine: pick it again with the app in front.")
                } else {
                    phase = .failed("Import/probe failed: \(error)")
                }
            }
        }
    }

    /// Set when the first read of a clip was interrupted and the retry succeeded, so the screen can
    /// say what happened rather than silently hiding a −11847.
    var probeRetryNote: String?

    /// The probe, retried once automatically after AVFoundation's −11847 "Operation Interrupted".
    /// The phone log has five of those in two days, every one of them retried by hand: the file was
    /// never the problem, the app had simply left the screen while the decoder was running.
    private func probeWithRetry(url: URL, source: String, log: ActivityLog) async throws -> VideoProbeResult {
        do {
            return try await log.timed("clip.probe", ["source": source]) { try await Task.detached { try await VideoReader(url: url).probe() }.value }
        } catch {
            guard SessionModel.isDecodingInterruption(error) else { throw error }
            log.event("clip.probe.interrupted", ["error": "\(error)"])
            try? await Task.sleep(for: .milliseconds(500))
            let result = try await log.timed("clip.probe.retry", ["source": source]) { try await Task.detached { try await VideoReader(url: url).probe() }.value }
            probeRetryNote = "The first read of this clip was interrupted by iOS (ArcLab was not on screen). It was read again and the numbers below come from that second read."
            return result
        }
    }

    /// A clip already on disk (the on-device benchmark): the caller states the timing and the lens.
    func useLocalClip(url: URL, timeScale scale: Double, hfovDegrees hfov: Double) {
        phase = .probing
        clip = ImportedClip(url: url, source: .recordedInApp)
        probe = nil; run = nil; progressText = nil
        clearRim()
        forgetRimFinderHistory()
        adoptGravity(from: try? RecordedClip.load(url: url),
                     noRecordReason: "this clip has no ArcLab recording record beside it, so nothing says which way was down while it was filmed")
        hfovDegrees = hfov
        Task {
            do {
                let result = try await ActivityLog.shared.timed("clip.probe", ["source": "local"]) { try await Task.detached { try await VideoReader(url: url).probe() }.value }
                probe = result
                applyProbeDefaults(result)
                timeScale = scale
                isSloMo = scale > 1.05
                sloMoSuspected = false
                ActivityLog.shared.event("clip.ready", ["file": url.lastPathComponent, "width": result.width, "height": result.height, "fps": result.measuredFrameRate,
                                                        "frames": result.decodedFrames, "timeScale": timeScale, "fileSeconds": fileDuration])
                phase = .probed
            } catch {
                phase = .failed("Could not read the clip: \(error)")
            }
        }
    }

    /// A clip recorded in the app: the file carries real high-frame-rate timestamps (factor 1) and the
    /// sidecar carries the lens's horizontal field of view, so neither is asked of the user.
    func useRecordedClip(_ recorded: RecordedClip) {
        phase = .probing
        clip = ImportedClip(url: recorded.url, source: .recordedInApp)
        probe = nil; run = nil; progressText = nil
        clearRim()
        forgetRimFinderHistory()
        adoptGravity(from: recorded, noRecordReason: "")
        hfovDegrees = recorded.videoFieldOfViewDegrees
        let url = recorded.url
        Task {
            do {
                let result = try await Task.detached { try await VideoReader(url: url).probe() }.value
                probe = result
                applyProbeDefaults(result)
                ActivityLog.shared.event("clip.ready", ["file": url.lastPathComponent, "source": "recordedInApp", "width": result.width, "height": result.height,
                                                        "fps": result.measuredFrameRate, "frames": result.decodedFrames, "hfov": hfovDegrees, "fileSeconds": fileDuration])
                // Real timestamps: the probe's measured rate is the recording rate. Never treat as a 30 fps export.
                timeScale = max(1, result.sloMoStretch)
                isSloMo = result.sloMoStretch > 1.05
                sloMoSuspected = false
                phase = .probed
            } catch {
                phase = .failed("Could not read the recording: \(error)")
            }
        }
    }

    /// The original survey pass: Vision over the first 10 s, listing whatever tracks exist.
    func track() {
        guard let clip else { return }
        phase = .tracking
        progressText = "starting…"
        let url = clip.url
        var options = TrajectoryTrackerOptions()
        options.startTime = 0
        options.endTime = Self.trackingWindowSeconds
        let opts = options
        Task {
            do {
                let result = try await Task.detached { [opts] in
                    try await TrajectoryTracker.run(url: url, options: opts) { frames, pts in
                        Task { @MainActor in
                            self.progressText = String(format: "%d frames, t = %.2f s", frames, pts)
                        }
                    }
                }.value
                run = result
                progressText = nil
                phase = .tracked
            } catch {
                progressText = nil
                phase = .failed("Tracking failed: \(error)")
            }
        }
    }

    /// Analyse the current window. Errors are shown exactly as the pipeline worded them.
    func analyseWindow() {
        guard let clip, let calibration, let k = intrinsics, !analysisBusy else { return }
        let url = clip.url
        let start = windowStart
        let end = windowStart + windowLength
        let scale = timeScale
        invalidateAnalysis()
        analysisBusy = true
        analysisStage = "starting…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { [calibration, k] in
                    // The single-shot flow has no scanner behind it, so the window is wherever the user put it and
                    // there is nothing to seed the detector with. Here — and only here — the Vision trajectory pass
                    // still runs: it costs a few seconds on one shot, and it is also the fallback when the detector
                    // finds too little. The session flow seeds from the scan instead and skips it.
                    try await ShotAnalysisRunner.run(url: url, start: start, end: end, timeScale: scale,
                                                     calibration: calibration, intrinsics: k,
                                                     useVisionSeed: true) { text in
                        Task { @MainActor in self.analysisStage = text }
                    }
                }.value
                analysis = result.analysis
                analysisSamples = result.samples
                analysisNotes = result.notes
                analysisPose = result.pose
                analysisBody = result.body
                analysisBodyUnavailableReason = result.bodyUnavailableReason
                analysedWindow = start...end
                analysisError = nil
            } catch {
                analysis = nil
                analysisSamples = []
                analysisPose = nil
                analysisBody = nil
                analysisBodyUnavailableReason = nil
                analysisError = "\(error)"
            }
            analysisBusy = false
            analysisStage = nil
        }
    }

    var isBusy: Bool {
        switch phase {
        case .importing, .probing, .tracking: return true
        default: return analysisBusy
        }
    }
}
