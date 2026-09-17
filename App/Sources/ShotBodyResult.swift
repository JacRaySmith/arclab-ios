import Foundation
import ShotGeometry
import simd

/// The four points of the shot the app names, with the fitted 3-D angles at each.
///
/// The angles are the per-shot fitted skeleton's (`BodySkeletonFit`), not Vision's 3-D request: the
/// measurement in `docs/PHASE2-PREP.md` "Body model, iteration 2" is that Vision's own 3-D joints
/// reproject 55–72 px from Vision's own 2-D joints, while the fitted skeleton reprojects at 1.4–2.4 px
/// and its elbow jitters 1.4–1.6°/frame instead of 2.4–8.8°.
struct BodyPhaseAngles: Sendable, Codable, Identifiable {
    var name: String
    var id: String { name }
    /// Real seconds, or nil when the phase was not found in this window.
    var realTime: Double?
    var unavailableReason: String?
    var elbow: BodyMeasure
    var knee: BodyMeasure
    var hip: BodyMeasure
    var shoulderElevation: BodyMeasure
}

/// One shot's body model, flattened to what the app is allowed to show.
///
/// Every field is a `BodyMeasure`: a value, or nil **with a reason** (CLAUDE.md rule 1). Nothing here
/// is computed twice — the numbers come from `BodyKinematics.model` over `BodySkeletonFit`'s fitted
/// timeline; this type only names them, converts at the boundary, and carries the trust notes.
struct ShotBodyResult: Sendable, Codable {
    // Coverage and cost
    var framesAnalysed: Int
    var framesWith2D: Int
    var framesWithHands: Int
    var everyNthFrame: Int
    var visionSeconds: Double
    var fitSeconds: Double
    var windowStartReal: Double
    var windowEndReal: Double
    var shootingSide: String?

    // Phases
    var phases: [BodyPhaseAngles]
    var phaseSignal: String
    var phaseNotes: [String]
    var dipToReleaseMilliseconds: BodyMeasure

    // The trustworthy angles
    var elbowAtRelease: BodyMeasure             // radians
    var elbowExtensionPeakRate: BodyMeasure     // radians/s
    var kneeExtensionPeakRate: BodyMeasure      // radians/s
    var kneeMinimum: BodyMeasure                // radians
    /// Frame-to-frame noise of the fitted elbow over the window, degrees (SD of differences ÷ √2).
    /// The caveat every absolute elbow angle travels with.
    var elbowJitterDegrees: Double?

    // Metres — only ever with a stated shooter height
    var jumpHeight: BodyMeasure                 // metres
    var dipDepthMetres: BodyMeasure
    /// Dip depth as a fraction of the shooter's own ankle-to-nose pixel span: the version that
    /// survives a change of camera position, because it has no pixels left in it.
    var dipDepthNormalised: BodyMeasure

    // Head and hands
    var headStabilityPx: BodyMeasure
    var headStabilityNormalised: BodyMeasure
    var handRateAtRelease: BodyMeasure          // ratio of frames within ±0.4 s real carrying a hand
    /// Shoulder-line yaw, radians. Normally nil on a near-side view, with the fit's own sentence about
    /// why the shoulder line's depth is not observable there. Carried so the app can say that, not
    /// so it can print a number.
    var shoulderLineYaw: BodyMeasure

    // Sequencing
    var chainOrder: [String]
    var chainLagsMilliseconds: [Double]
    var chainProximalToDistal: Bool?
    var chainUnavailableReason: String?
    var chainMissing: [String: String]
    /// One sampled frame of real time. A lag at or below it is quantisation, not a measurement.
    var frameFloorMilliseconds: Double

    /// The shot in the shooter's own frame on the phase-normalised clock, ready for the 3-D viewer
    /// and for pooling into a `FormModel` across a block. Nil with `formUnavailableReason`.
    var form: ShotForm?
    var formUnavailableReason: String?

    /// The full per-frame biometric record (docs/BIOMETRIC-SCHEMA.md): every processed frame with its
    /// 2-D points, raw and fitted 3-D joints and hands, the skeleton, the angle tracks and the summary.
    /// `BodyShotWriter` files it for accepted shots; nothing in the UI reads it. Nil only when the
    /// runner no longer had the fit (an older result decoded from disk).
    var bodyShot: BodyShot?

    // Provenance
    /// The shooter's 90th-percentile ankle-to-nose span in pixels: the scale bar behind every
    /// normalised number, and the key the pooling rule compares across sessions.
    var shooterPixelHeight: Double?
    var reprojectionRMSPx: BodyMeasure
    var scaleNote: String
    var warnings: [String]
    var notes: [String]

    /// Footwork: the ground contacts, the step pattern, the gather and the drift, with each number
    /// refused by name when this camera position cannot carry it (Track C,
    /// `docs/DESIGN-FOOTWORK-2026-09-15.md`). Optional with a default so results saved before 1.1
    /// still decode.
    var footwork: FootworkMetrics? = nil

    /// The foot detector runs unless the shooter switched it off (You › Advanced). Read once per shot.
    static var feetEnabled: Bool {
        UserDefaults.standard.object(forKey: "feet.enabled") as? Bool ?? true
    }

    /// The lags, with the frame floor said out loud. Never a bare millisecond number.
    var chainText: String? {
        guard chainUnavailableReason == nil, chainOrder.count >= 2 else { return nil }
        var parts: [String] = [chainOrder[0]]
        for (i, lag) in chainLagsMilliseconds.enumerated() where i + 1 < chainOrder.count {
            let floored = lag <= frameFloorMilliseconds + 1e-9
            parts.append(String(format: "→ %@%.0f ms → %@", floored ? "≤" : "+",
                                floored ? frameFloorMilliseconds : lag, chainOrder[i + 1]))
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Building it from the model

extension ShotBodyResult {

    /// How many real seconds either side of release the hand pass covers, and the span the hand rate
    /// is measured over. `BodyTracker.Options.handFocusRealTimeRange` uses the same number.
    static let handFocusRealSeconds = 0.4

    /// The shooter's ankle-to-nose span in pixels, 90th percentile over the window.
    ///
    /// The 90th percentile, not the maximum or the median, for the reason `BodySkeletonFit` gives:
    /// the ankle *joint* does not move when the shooter rises on the toes, so the largest spans are
    /// the frames where the legs and trunk are straight — the standing pose a height refers to.
    static func ankleToNosePixels(_ timeline: BodyTimeline, minimumConfidence: Double = 0.3) -> Double? {
        var spans: [Double] = []
        for f in timeline.frames {
            guard let nose = f.points2D[Body2DPoint.nose], nose.confidence >= minimumConfidence else { continue }
            let ankles = [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle]
                .compactMap { f.points2D[$0] }
                .filter { $0.confidence >= minimumConfidence }
            guard let a = ankles.max(by: { $0.v < $1.v }) else { continue }
            spans.append(simd_length(SIMD2(a.u, a.v) - SIMD2(nose.u, nose.v)))
        }
        guard spans.count >= 5 else { return nil }
        let sorted = spans.sorted()
        return sorted[min(sorted.count - 1, Int((0.9 * Double(sorted.count - 1)).rounded()))]
    }

    /// SD of the frame-to-frame difference ÷ √2 (digest Ch 10 §10.5.1: differencing doubles the
    /// variance). The number a finding has to clear twice over before it is worth reporting.
    static func jitter(_ values: [Double]) -> Double? {
        guard values.count >= 6 else { return nil }
        var diffs: [Double] = []
        for i in 1..<values.count { diffs.append(values[i] - values[i - 1]) }
        let mean = diffs.reduce(0, +) / Double(diffs.count)
        let variance = diffs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(diffs.count - 1)
        return (variance / 2).squareRoot()
    }

    /// Assemble the app-facing result. Pure: given a fitted timeline, its fit and the model, there is
    /// nothing left to decide, which is what makes it testable without a video.
    static func make(model: BodyModel, fit: BodySkeletonFitResult, timeline: BodyTimeline,
                     releaseRealTime: Double, realFrameRate: Double,
                     visionSeconds: Double, fitSeconds: Double,
                     heightMetres: Double?, rimImageU: Double? = nil,
                     shotID: Int? = nil,
                     rawTimeline: BodyTimeline? = nil, handTriangles: HandTriangleResult? = nil,
                     footTriangles: FootTriangleResult? = nil,
                     source: BodyShotSource? = nil) -> ShotBodyResult {
        let side = model.shootingSide ?? "right"
        let left = side == "left"
        func elbow(_ a: JointAngles3D) -> BodyMeasure { left ? a.leftElbow : a.rightElbow }
        func knee(_ a: JointAngles3D) -> BodyMeasure { left ? a.leftKnee : a.rightKnee }
        func hip(_ a: JointAngles3D) -> BodyMeasure { left ? a.leftHip : a.rightHip }
        func shoulder(_ a: JointAngles3D) -> BodyMeasure { left ? a.leftShoulderElevation : a.rightShoulderElevation }

        let span = ankleToNosePixels(timeline)
        let frames = timeline.frames.sorted { $0.realTime < $1.realTime }
        let step = max(1, timeline.everyNthFrame)
        let floorMs = realFrameRate > 0 ? 1000 * Double(step) / realFrameRate : .nan

        // Phase angles: the fitted frame nearest each phase time.
        func anglesAt(_ t: Double?, name: String, reason: String?) -> BodyPhaseAngles {
            guard let t, let a = model.angles.min(by: { abs($0.realTime - t) < abs($1.realTime - t) }) else {
                let why = reason ?? "this phase was not found inside the window the body pass covered"
                return BodyPhaseAngles(name: name, realTime: nil, unavailableReason: why,
                                       elbow: .missing(.radians, why), knee: .missing(.radians, why),
                                       hip: .missing(.radians, why), shoulderElevation: .missing(.radians, why))
            }
            return BodyPhaseAngles(name: name, realTime: a.realTime, unavailableReason: nil,
                                   elbow: elbow(a), knee: knee(a), hip: hip(a), shoulderElevation: shoulder(a))
        }
        let ph = model.phases
        // A dip that sat at the edge of the searched span is the window's length, not a measurement.
        // `phases` says so in its notes; the number is refused here rather than shown with a caveat.
        let edgeNote = ph.notes.first { $0.hasPrefix("the dip is the first frame of the lookback")
                                     || $0.hasPrefix("the hand only rose inside the lookback") }
        let dipToRelease: BodyMeasure = edgeNote.map { .missing(.milliseconds, $0) } ?? ph.dipToReleaseMilliseconds
        let dipTime: Double? = edgeNote == nil ? ph.dip.value : nil
        let phaseRows = [
            anglesAt(ph.setPoint.value, name: "Set", reason: ph.setPoint.unavailableReason),
            anglesAt(dipTime, name: "Dip", reason: edgeNote ?? ph.dip.unavailableReason),
            anglesAt(releaseRealTime, name: "Release", reason: nil),
            anglesAt(ph.followThroughEnd.value, name: "Follow-through", reason: ph.followThroughEnd.unavailableReason),
        ]

        // Knee minimum over the dip→release span: the deepest bend, from the fitted knee.
        let searchFrom = dipTime ?? (releaseRealTime - 1.5)
        let kneeValues = model.angles.filter { $0.realTime >= searchFrom && $0.realTime <= releaseRealTime + 0.10 }
            .compactMap { knee($0).value }
        let kneeMin: BodyMeasure = kneeValues.min().map { .ok($0, .radians) }
            ?? .missing(.radians, "the fitted knee angle was not available on any frame between the dip and release")

        // Peak extension rates, from the chain's own events — the same peaks the sequence is read from.
        func peak(_ joint: String) -> BodyMeasure {
            if let e = model.chain.events.first(where: { $0.joint == joint }) {
                return .ok(e.peakRateRadPerSecond, .radiansPerSecond)
            }
            return .missing(.radiansPerSecond, model.chain.missing[joint]
                            ?? model.chain.unavailableReason
                            ?? "the \(joint) produced no peak extension velocity in this window")
        }

        // Dip depth, from the mid-hip's image row, and hand-independent: the hips' lowest point
        // anywhere before the release, and how far they fell to reach it. Pixels first, because the
        // image plane is the direction a single camera can actually see (the fit reports a σ on the
        // other one and refuses lengths below it). It is measured on the hips, not the hands: on this
        // shooter's free throw the hand rises through the whole span with only a hesitation in it,
        // while the legs make a clear lowering, and that is what a dip depth is usually taken to mean.
        var dipPx: Double? = nil
        var dipWhy = "the hips were never confident on both sides before the release in this window"
        func midHipV(_ f: BodyFrame) -> Double? {
            guard let l = f.points2D[Body2DPoint.leftHip], l.confidence >= 0.3,
                  let r = f.points2D[Body2DPoint.rightHip], r.confidence >= 0.3 else { return nil }
            return (l.v + r.v) / 2
        }
        let hipRows = frames.filter { $0.realTime <= releaseRealTime + 1e-9 }
            .compactMap { f -> (t: Double, v: Double)? in midHipV(f).map { (f.realTime, $0) } }
        if let low = hipRows.max(by: { $0.v < $1.v }),                 // v grows downwards
           let top = hipRows.filter({ $0.t <= low.t }).map(\.v).min() {
            let drop = low.v - top
            if drop > 0 { dipPx = drop }
            else { dipWhy = "the hips never came down before the release inside this window, so there is no drop to measure" }
        }

        // Metres, and the one gate in front of them. With no stated height `BodySkeletonFit` still
        // needs *a* working scale for its numerics (it uses a 1.80 m prior, which changes no angle),
        // so a metre could be produced here that is a population prior wearing a measurement's
        // clothes. It is refused instead — nothing in the app shows a metre without a stated height.
        let mpp = fit.metresPerPixelAtBody
        let scaleReason: String? = heightMetres == nil
            ? ShooterProfile.missingReason
            : (mpp.value == nil ? (mpp.unavailableReason ?? "the stated height had no pixel span to sit on in this window") : nil)
        func metres(from px: Double?, _ why: String) -> BodyMeasure {
            if let scaleReason { return .missing(.metres, scaleReason) }
            guard let px else { return .missing(.metres, why) }
            guard let s = mpp.value else { return .missing(.metres, ShooterProfile.missingReason) }
            return .ok(px * s, .metres)
        }
        func normalised(from px: Double?, _ why: String) -> BodyMeasure {
            guard let px else { return .missing(.ratio, why) }
            guard let span, span > 1 else {
                return .missing(.ratio, "no frame in this window carried both the nose and an ankle, so there is no shooter pixel height to divide by")
            }
            return .ok(px / span, .ratio)
        }

        let headStability = model.head.stabilityPx
        let headNormalised: BodyMeasure = headStability.value.map { normalised(from: $0, "") }
            ?? .missing(.ratio, headStability.unavailableReason ?? "head stability was not measured")

        // Hand detection rate across the release window the hand pass was aimed at.
        let lo = releaseRealTime - handFocusRealSeconds, hi = releaseRealTime + handFocusRealSeconds
        let inWindow = frames.filter { $0.realTime >= lo && $0.realTime <= hi }
        let handRate: BodyMeasure = inWindow.isEmpty
            ? .missing(.ratio, "no analysed frame fell within ±0.4 s of release")
            : .ok(Double(inWindow.filter { !$0.hands.isEmpty }.count) / Double(inWindow.count), .ratio)

        var warnings = model.warnings + fit.warnings
        if heightMetres == nil {
            warnings.append("no shooter height was given, so every metre here is unavailable; the angles, the timings and the normalised numbers are unaffected")
        }
        if let j = jitter(model.angles.compactMap { elbow($0).value }.map(Angle.degrees)), j > 0 {
            warnings.append(String(format: "the fitted elbow moves %.1f° between sampled frames, and one camera can only bracket an absolute elbow angle to about 25°: read this shooter's shot-to-shot change, not the number itself", j))
        }

        // The 3-D form. Built from the same fitted skeleton and the same vetted phase times as every
        // number above — a phase this result refuses (the edge-note dip) is refused to the form too,
        // so the normalised axis can never be anchored on a number the body model would not print.
        var formOptions = FormOptions()
        if let rimImageU { formOptions.facing = .rimImageColumn(rimU: rimImageU) }
        let (form, formWhy) = ShotForm.make(fit: fit,
                                            setRealTime: ph.setPoint.value,
                                            dipRealTime: dipTime,
                                            releaseRealTime: releaseRealTime,
                                            followThroughRealTime: ph.followThroughEnd.value,
                                            shootingSide: model.shootingSide,
                                            shotID: shotID,
                                            options: formOptions)

        // The full record, from the same fit, model and vetted phase times as everything above. The
        // source is what the runner knows (frame size, lens); the writer fills in the device and build.
        let bodyShot = BodyShot.make(
            rawTimeline: rawTimeline, fit: fit, model: model, releaseRealTime: releaseRealTime,
            setRealTime: ph.setPoint, dipRealTime: BodyShot.vettedDip(ph),
            followThroughPeakRealTime: ph.followThroughPeak, realFrameRate: realFrameRate,
            source: source ?? BodyShotSource(kind: "app", build: nil, device: nil,
                                             format: BodyShotFormat(w: timeline.imageWidth, h: timeline.imageHeight, fps: realFrameRate,
                                                                    hfovDegrees: .nan, provenance: "unstated")),
            rimImageU: rimImageU, shotID: shotID, handTriangles: handTriangles, footTriangles: footTriangles)

        // Footwork. Reads the 2-D points of the same window, not the fitted depth: the axis these
        // metrics live on is the one a single camera cannot see, and the fit cannot rescue it.
        var footworkOptions = FootworkOptions(shootingSide: model.shootingSide,
                                              rimImageU: rimImageU,
                                              standingHeightMetres: heightMetres,
                                              heightIsMeasured: fit.scaleIsMeasured)
        footworkOptions.minimumConfidence2D = 0.3
        // With the feet (1.3): the contacts come from the ankles first, the strike order is read at
        // those contacts from the fitted heel and toes, and the second pass carries the foot angle.
        var feetMeasures = footTriangles?.measures
        if var fm = feetMeasures {
            let first = FootworkMetrics.compute(timeline: timeline, releaseRealTime: releaseRealTime,
                                                setRealTime: ph.setPoint.value, options: footworkOptions)
            if let stature = first.statureImagePixels {
                fm.strikes = FootTriangleFit.strikes(timeline: timeline, contacts: first.contacts,
                                                     statureImagePixels: stature, liftRealTime: first.liftRealTime,
                                                     releaseRealTime: releaseRealTime,
                                                     minimumConfidence: FootTriangleOptions.defaultMinimumFootConfidence)
            }
            feetMeasures = fm
        }
        let footwork = FootworkMetrics.compute(timeline: timeline,
                                               releaseRealTime: releaseRealTime,
                                               setRealTime: ph.setPoint.value,
                                               options: footworkOptions,
                                               feet: feetMeasures)

        return ShotBodyResult(
            framesAnalysed: timeline.analysedFrames,
            framesWith2D: model.framesWith2D,
            framesWithHands: model.framesWithHands,
            everyNthFrame: step,
            visionSeconds: visionSeconds,
            fitSeconds: fitSeconds,
            windowStartReal: frames.first?.realTime ?? releaseRealTime,
            windowEndReal: frames.last?.realTime ?? releaseRealTime,
            shootingSide: model.shootingSide,
            phases: phaseRows,
            phaseSignal: ph.signalSource,
            phaseNotes: ph.notes,
            dipToReleaseMilliseconds: dipToRelease,
            elbowAtRelease: model.anglesAtRelease.map(elbow)
                ?? .missing(.radians, "no analysed frame carried a fitted arm at the release instant"),
            elbowExtensionPeakRate: peak("elbow"),
            kneeExtensionPeakRate: peak("knee"),
            kneeMinimum: kneeMin,
            elbowJitterDegrees: jitter(model.angles.compactMap { elbow($0).value }.map(Angle.degrees)),
            jumpHeight: scaleReason.map { BodyMeasure.missing(.metres, $0) } ?? model.stance.jumpHeight,
            dipDepthMetres: metres(from: dipPx, dipWhy),
            dipDepthNormalised: normalised(from: dipPx, dipWhy),
            headStabilityPx: headStability,
            headStabilityNormalised: headNormalised,
            handRateAtRelease: handRate,
            shoulderLineYaw: model.stance.shoulderLineYaw,
            chainOrder: model.chain.order,
            chainLagsMilliseconds: model.chain.lagsMilliseconds,
            chainProximalToDistal: model.chain.proximalToDistal,
            chainUnavailableReason: model.chain.unavailableReason,
            chainMissing: model.chain.missing,
            frameFloorMilliseconds: floorMs,
            form: form,
            formUnavailableReason: formWhy,
            bodyShot: bodyShot,
            shooterPixelHeight: span,
            reprojectionRMSPx: fit.reprojectionRMSPixels,
            scaleNote: fit.scaleProvenance,
            warnings: warnings,
            notes: timeline.notes + fit.notes,
            footwork: footwork)
    }
}
