// The per-shot half of the form-evaluation harness (Track D, 1.3).
//
// What this answers, and what it cannot. Without a mocap lab there is no ground-truth 3-D position
// for any joint, so nothing here measures 3-D accuracy in metres. What *is* available is:
//
//   1. the picture — where the fitted skeleton lands in the image against the 2-D points the
//      detector produced, both for joints the fit was driven by (a consistency check) and for joints
//      whose pixels were taken away first (a held-out *prediction*, which is the honest one);
//   2. the body — bone lengths that must not change through a shot and limbs that must match their
//      mirror, which need no ground truth at all to be falsified;
//   3. the gaps — which joints exist at all at the four phase instants, per shot;
//   4. repeatability — the same movement measured twice, which bounds what any later change is
//      allowed to claim.
//
// Every number below is one of those four. Nothing is averaged across camera distances silently:
// the shot rows carry their own session and framing, and the report prints them.
import Foundation
import simd
import ShotGeometry

// MARK: - options

public struct FormEvalOptions: Sendable {
    /// The same gate the fit uses. A point below it is not an observation.
    public var minimumConfidence2D: Double = 0.3
    /// Joints to re-fit without, one at a time. Empty = skip the held-out pass.
    public var heldOutJoints: [String] = BodySkeletonFit.joints
    /// The "blink" held-out pass drops a joint's 2-D on every `heldOutStride`-th frame and scores the
    /// fit on exactly those frames. It is the failure the footage actually produces — the detector
    /// losing a joint for a few frames — and unlike the whole-joint pass it leaves the skeleton
    /// enough observations to carry the joint at all.
    public var heldOutStride: Int = 4
    /// Refit each shot twice on disjoint halves of its frames (even/odd), for the repeatability table.
    public var runRetest: Bool = true
    public var boneSDGatePercent: Double = 3.0
    public var asymmetryGatePercent: Double = 4.0
    public var hfovOverride: Double? = nil
    public var heightOverride: Double? = nil
    public var bootstrapSamples: Int = 2000
    /// Drop files whose 2-D input is byte-for-byte the same shot as one already loaded. The phone
    /// directory holds several *exports* of one session; counting them as separate shots would
    /// triple every N in the report for no new information.
    public var dedupe: Bool = true
    public init() {}
}

// MARK: - the four phase instants

public enum EvalPhase: String, Sendable, CaseIterable, Codable {
    case set, dip, release, followThrough
    public var label: String {
        switch self {
        case .set: return "set"
        case .dip: return "dip"
        case .release: return "release"
        case .followThrough: return "follow"
        }
    }
}

// MARK: - one shot's evaluation

public struct ShotEval: Sendable {
    public var id: String
    public var session: String
    public var path: String
    /// Identity of the *input*, not of the file: the 2-D points and their confidences. Two exports of
    /// one session share it.
    public var inputDigest: String
    public var frameCount: Int
    public var fps: Double
    public var releaseRealTime: Double
    public var shootingSide: String
    public var statureMetres: Double
    public var scaleProvenance: String
    /// Winter's biacromial breadth expressed in this shot's pixels (see `shoulderWidthNote`).
    public var shoulderWidthPixels: Double?
    public var shoulderWidthNote: String
    public var fitReprojectionRMS: Double?
    /// Per joint, the per-frame reprojection error in pixels, for joints the fit was driven by.
    public var drivenError: [String: [Double]]
    /// Error on the frames whose observation of that joint was hidden from the fit (every Nth).
    public var blinkError: [String: [Double]]
    /// Error for a refit that never saw that joint's pixels on any frame.
    public var absentError: [String: [Double]]
    /// Joints the whole-joint refit declined to place at all — it dropped them rather than predicting.
    public var absentProducedNoPoint: Set<String>
    /// Held-out joints the refit could only reach by mirroring the other side — a prior, not a prediction.
    public var heldOutBySymmetry: Set<String>
    public var fitBoneSDPercent: [String: Double]
    public var visionBoneSDPercent: [String: Double]
    public var fitAsymmetryPercent: [String: Double]
    public var visionAsymmetryPercent: [String: Double]
    public var pooledBones: Set<String>
    public var priorBones: Set<String>
    public var phaseTimes: [EvalPhase: Double]
    public var phaseUnavailable: [EvalPhase: String]
    /// phase → 2-D point name → was there an observation on the frame nearest that instant.
    public var coverage: [EvalPhase: [String: Bool]]
    /// phase → was a hand (any) / the shooting-side hand present.
    public var handCoverage: [EvalPhase: Bool]
    public var shootingHandCoverage: [EvalPhase: Bool]
    public var measures: [String: Double]
    public var measuresEven: [String: Double]
    public var measuresOdd: [String: Double]
    public var warnings: [String]
}

// MARK: - the evaluator

public enum FormEvaluator {

    /// The 2-D points the coverage table asks about: the 14 the fit solves for, plus the hand-plate
    /// corners 1.3 is adding. A point that does not exist yet reports 0 %, which is the correct
    /// answer and the reason the row is here before the detector is.
    public static var coveragePoints: [String] {
        BodySkeletonFit.joints + Body2DPoint.appendages
    }

    /// Limb pairs whose lengths a real body matches. `trunk` and `head` are reported but **not
    /// gated**: they span articulations (see `rigidSegments`), so a lean or a head turn changes them
    /// on a perfectly tracked body.
    public static let mirroredPairs: [(name: String, left: String, right: String, gated: Bool)] = [
        ("upperArm", "upperArmLeft", "upperArmRight", true),
        ("forearm", "forearmLeft", "forearmRight", true),
        ("thigh", "thighLeft", "thighRight", true),
        ("shin", "shinLeft", "shinRight", true),
        ("trunk", "trunkLeft", "trunkRight", false),
        ("head", "headLeft", "headRight", false),
    ]

    /// The `BodySkeletonFit.bones` entries that are one anatomical segment between two joints, so a
    /// length that changes is an error and nothing else. Everything *not* in this set — the
    /// biacromial (the clavicles rotate), the trunk edges and diagonals (the spine flexes), the head
    /// and neck spans (the neck rotates) — legitimately changes length on a real body, which is why
    /// the constancy gate is applied to this set only. Measured on Vision's own rigged 3-D skeleton
    /// (2026-09-16): the segments below sit at 0.01–0.02 % SD, the articulated spans at 3.6–13 %.
    public static let rigidSegments: Set<String> = [
        "upperArmLeft", "upperArmRight", "forearmLeft", "forearmRight",
        "thighLeft", "thighRight", "shinLeft", "shinRight", "biiliac",
    ]

    /// Winter's segment table, the two fractions this harness needs:
    /// biacromial breadth 0.245 H (`BodySkeletonOptions.biacromialFractionOfHeight`) and the
    /// ankle-to-nose span 0.891 H (`BodyShotOptions.ankleToNoseFractionOfHeight`).
    public static let biacromialFractionOfHeight = 0.245
    public static let ankleToNoseFractionOfHeight = 0.891

    /// Vision's 3-D name for a 2-D point, where the two name spaces differ.
    public static func joint3DKey(_ name: String) -> String {
        name == Body2DPoint.nose ? Body3DJoint.centerHead
            : name == Body2DPoint.neck ? Body3DJoint.centerShoulder : name
    }

    public static func evaluate(shot: BodyShot, id: String, session: String, path: String,
                                options o: FormEvalOptions) -> ShotEval? {
        let timeline = BodyShotLoading.timeline(shot, hfovOverride: o.hfovOverride)
        guard timeline.frames.count >= 4 else { return nil }
        let fitOptions = BodyShotLoading.fitOptions(shot, hfovOverride: o.hfovOverride, heightOverride: o.heightOverride)
        let fit = BodySkeletonFit.fit(timeline: timeline, options: fitOptions)
        var warnings: [String] = []

        // ---- scale rulers -----------------------------------------------------------------------
        let stature = statureMetres(fit: fit, frames: fit.timeline.frames)
        let (shoulderPx, shoulderNote) = shoulderWidthPixels(frames: timeline.frames, gate: o.minimumConfidence2D)

        // ---- 1. reprojection, driven ------------------------------------------------------------
        var driven: [String: [Double]] = [:]
        for name in BodySkeletonFit.joints {
            driven[name] = reprojectionErrors(joint: name, fitted: fit.timeline.frames,
                                              observedIn: timeline.frames, gate: o.minimumConfidence2D)
        }

        // ---- 2. reprojection, held out ----------------------------------------------------------
        //
        // Two passes, because they answer different questions and the second one turned out to
        // answer a question about the *fit* rather than about the footage.
        //
        //   blink — the joint's 2-D is removed on every Nth frame and the fit is scored on exactly
        //           those frames. This is the real failure mode (the detector loses a wrist for a
        //           few frames) and the skeleton still has enough of that joint to carry it.
        //   absent — the joint's 2-D is removed on *every* frame. Measured here: this build's fit
        //           does not place a joint it never observed unless the mirror side can stand in for
        //           it, so most of these rows come back empty. That emptiness is the finding, not a
        //           gap in the harness, and it is reported as `producedNoPoint`.
        var blink: [String: [Double]] = [:]
        var absent: [String: [Double]] = [:]
        var heldBySymmetry: Set<String> = []
        var producedNoPoint: Set<String> = []
        let stride = max(2, o.heldOutStride)
        for name in o.heldOutJoints {
            var holes = timeline
            var heldFrames: Set<Int> = []
            for i in holes.frames.indices where i % stride == stride / 2 {
                if holes.frames[i].points2D.removeValue(forKey: name) != nil { heldFrames.insert(i) }
            }
            if !heldFrames.isEmpty {
                let refit = BodySkeletonFit.fit(timeline: holes, options: fitOptions)
                blink[name] = reprojectionErrors(joint: name, fitted: refit.timeline.frames,
                                                 observedIn: timeline.frames, gate: o.minimumConfidence2D,
                                                 onlyFrames: heldFrames)
            }
            var stripped = timeline
            for i in stripped.frames.indices { stripped.frames[i].points2D.removeValue(forKey: name) }
            let refit = BodySkeletonFit.fit(timeline: stripped, options: fitOptions)
            let e = reprojectionErrors(joint: name, fitted: refit.timeline.frames,
                                       observedIn: timeline.frames, gate: o.minimumConfidence2D)
            absent[name] = e
            if e.isEmpty, !(driven[name] ?? []).isEmpty { producedNoPoint.insert(name) }
            if refit.symmetryInferredJoints.contains(name) { heldBySymmetry.insert(name) }
        }

        // ---- 3. bones ---------------------------------------------------------------------------
        let fitBoneSD = boneSDPercent(frames: fit.timeline.frames)
        let visionBoneSD = boneSDPercent(frames: timeline.frames)
        let fitAsym = asymmetryPercent(frames: fit.timeline.frames)
        let visionAsym = asymmetryPercent(frames: timeline.frames)

        // ---- 4. phase-instant coverage ----------------------------------------------------------
        var phaseTimes: [EvalPhase: Double] = [:], phaseWhy: [EvalPhase: String] = [:]
        phaseTimes[.release] = shot.timing.releaseRealTime
        for (phase, m) in [(EvalPhase.set, shot.timing.set), (.dip, shot.timing.dip), (.followThrough, shot.timing.followThroughPeak)] {
            if let v = m.value { phaseTimes[phase] = v }
            else { phaseWhy[phase] = m.unavailableReason ?? "the export did not carry this instant" }
        }
        let spacing = medianFrameSpacing(timeline.frames)
        var coverage: [EvalPhase: [String: Bool]] = [:]
        var handCover: [EvalPhase: Bool] = [:], shootingHandCover: [EvalPhase: Bool] = [:]
        let side = shot.shootingSide ?? "right"
        for (phase, t) in phaseTimes {
            guard let f = nearestFrame(timeline.frames, t, tolerance: 1.5 * spacing) else {
                phaseWhy[phase] = "no analysed frame within \(String(format: "%.0f", 1500 * spacing)) ms of the instant"
                continue
            }
            var row: [String: Bool] = [:]
            for p in coveragePoints { row[p] = (f.points2D[p]?.confidence ?? 0) >= o.minimumConfidence2D }
            coverage[phase] = row
            handCover[phase] = !f.hands.isEmpty
            shootingHandCover[phase] = f.hands.contains { ($0.chirality ?? $0.role) == side || $0.role == "shooting" }
        }

        // ---- 5. repeatability inputs ------------------------------------------------------------
        let full = FormMeasures.all(frames: fit.timeline.frames, side: side, phases: phaseTimes, stature: stature)
        var even: [String: Double] = [:], odd: [String: Double] = [:]
        if o.runRetest {
            for (parity, target) in [(0, 0), (1, 1)] {
                var half = timeline
                half.frames = timeline.frames.enumerated().filter { $0.offset % 2 == parity }.map(\.element)
                guard half.frames.count >= 4 else {
                    warnings.append("too few frames to split for the retest"); continue
                }
                let r = BodySkeletonFit.fit(timeline: half, options: fitOptions)
                let m = FormMeasures.all(frames: r.timeline.frames, side: side, phases: phaseTimes,
                                     stature: statureMetres(fit: r, frames: r.timeline.frames))
                if target == 0 { even = m } else { odd = m }
            }
        }

        if let rms = fit.reprojectionRMSPixels.value, rms > 10 {
            warnings.append(String(format: "the fit reprojects %.1f px RMS: this shot's depths are unresolved", rms))
        }

        return ShotEval(id: id, session: session, path: path,
                        inputDigest: digest(shot),
                        frameCount: timeline.frames.count, fps: shot.source.format.fps,
                        releaseRealTime: shot.timing.releaseRealTime, shootingSide: side,
                        statureMetres: stature, scaleProvenance: shot.skeleton.scaleProvenance,
                        shoulderWidthPixels: shoulderPx, shoulderWidthNote: shoulderNote,
                        fitReprojectionRMS: fit.reprojectionRMSPixels.value,
                        drivenError: driven, blinkError: blink, absentError: absent,
                        absentProducedNoPoint: producedNoPoint, heldOutBySymmetry: heldBySymmetry,
                        fitBoneSDPercent: fitBoneSD, visionBoneSDPercent: visionBoneSD,
                        fitAsymmetryPercent: fitAsym, visionAsymmetryPercent: visionAsym,
                        pooledBones: Set(fit.symmetricBones), priorBones: Set(fit.priorBones),
                        phaseTimes: phaseTimes, phaseUnavailable: phaseWhy,
                        coverage: coverage, handCoverage: handCover, shootingHandCoverage: shootingHandCover,
                        measures: full, measuresEven: even, measuresOdd: odd,
                        warnings: warnings + fit.warnings)
    }

    // MARK: - pieces

    /// Distance in pixels between where the fit put a joint and where the detector saw it, on every
    /// frame carrying an observation above the gate.
    public static func reprojectionErrors(joint name: String, fitted: [BodyFrame],
                                          observedIn observed: [BodyFrame], gate: Double,
                                          onlyFrames: Set<Int>? = nil) -> [Double] {
        let key = joint3DKey(name)
        var out: [Double] = []
        for (i, (f, g)) in zip(fitted, observed).enumerated() {
            if let onlyFrames, !onlyFrames.contains(i) { continue }
            guard let p = g.points2D[name], p.confidence >= gate,
                  let j = f.joints3D[key], let u = j.imageU, let v = j.imageV,
                  u.isFinite, v.isFinite else { continue }
            out.append(simd_length(SIMD2(u, v) - SIMD2(p.u, p.v)))
        }
        return out
    }

    /// A shoulder-width ruler that a near-side view cannot collapse.
    ///
    /// The *fitted* biacromial is not usable as one: on a side-on shot the shoulder line points into
    /// depth, the camera cannot see its length, and the fit reads it at ~0.06 H against an adult's
    /// 0.245 H (measured; see PHASE2-PREP "Body model, iteration 5"). So the ruler here is Winter's
    /// **population** breadth carried into this shot's pixels by the one body span a side view *can*
    /// see: ankle-to-nose. shoulderWidthPx = span_px × 0.245 / 0.891. It is a prior-scaled ruler and
    /// every number divided by it inherits that provenance.
    public static func shoulderWidthPixels(frames: [BodyFrame], gate: Double) -> (Double?, String) {
        var spans: [Double] = []
        for f in frames {
            guard let nose = f.points2D[Body2DPoint.nose], nose.confidence >= gate else { continue }
            let ankles = [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle]
                .compactMap { f.points2D[$0] }.filter { $0.confidence >= gate }
            guard let lowest = ankles.max(by: { $0.v < $1.v }) else { continue }
            spans.append(simd_length(SIMD2(lowest.u, lowest.v) - SIMD2(nose.u, nose.v)))
        }
        guard let span = EvalStats.median(spans), span > 1 else {
            return (nil, "no frame carried both the nose and an ankle above the confidence gate, so there is no ankle-to-nose span to scale the population shoulder breadth by")
        }
        return (span * biacromialFractionOfHeight / ankleToNoseFractionOfHeight,
                String(format: "Winter's 0.245 H biacromial breadth scaled by this shot's median ankle-to-nose span (%.0f px = 0.891 H): %.1f px. A prior-scaled ruler, not a measured shoulder.",
                       span, span * biacromialFractionOfHeight / ankleToNoseFractionOfHeight))
    }

    /// Per bone, the SD of its 3-D length over the shot as a percentage of its own median length.
    public static func boneSDPercent(frames: [BodyFrame]) -> [String: Double] {
        var out: [String: Double] = [:]
        for b in BodySkeletonFit.bones {
            let ls = lengths(frames, b.a, b.b)
            guard ls.count >= 3, let m = EvalStats.median(ls), m > 1e-9, let s = EvalStats.sd(ls) else { continue }
            out[b.name] = 100 * s / m
        }
        return out
    }

    /// Per mirrored pair, the median over frames of |left − right| ÷ their mean, as a percentage.
    public static func asymmetryPercent(frames: [BodyFrame]) -> [String: Double] {
        var byName: [String: (String, String)] = [:]
        for b in BodySkeletonFit.bones { byName[b.name] = (b.a, b.b) }
        var out: [String: Double] = [:]
        for pair in mirroredPairs {
            guard let l = byName[pair.left], let r = byName[pair.right] else { continue }
            _ = pair.gated
            var ratios: [Double] = []
            for f in frames {
                guard let a = length(f, l.0, l.1), let b = length(f, r.0, r.1), a + b > 1e-9 else { continue }
                ratios.append(200 * abs(a - b) / (a + b))
            }
            if let m = EvalStats.median(ratios) { out[pair.name] = m }
        }
        return out
    }

    static func length(_ f: BodyFrame, _ a: String, _ b: String) -> Double? {
        guard let pa = f.joints3D[joint3DKey(a)]?.cameraPosition,
              let pb = f.joints3D[joint3DKey(b)]?.cameraPosition else { return nil }
        let d = simd_length(pa - pb)
        return d.isFinite && d > 0 ? d : nil
    }

    static func lengths(_ frames: [BodyFrame], _ a: String, _ b: String) -> [Double] {
        frames.compactMap { length($0, a, b) }
    }

    public static func medianFrameSpacing(_ frames: [BodyFrame]) -> Double {
        guard frames.count >= 2 else { return 1.0 / 30 }
        var d: [Double] = []
        for i in 1..<frames.count { d.append(frames[i].realTime - frames[i - 1].realTime) }
        return EvalStats.median(d.filter { $0 > 0 }) ?? 1.0 / 30
    }

    public static func nearestFrame(_ frames: [BodyFrame], _ t: Double, tolerance: Double) -> BodyFrame? {
        guard let f = frames.min(by: { abs($0.realTime - t) < abs($1.realTime - t) }) else { return nil }
        return abs(f.realTime - t) <= tolerance ? f : nil
    }

    /// The shooter's stature in the unit the fit worked in: the stated height when there is one, else
    /// the fitted skeleton's own 90th-percentile ankle-to-nose span ÷ 0.891 — the convention the fit
    /// and the export both use, so a ratio means the same thing in all three.
    public static func statureMetres(fit: BodySkeletonFitResult, frames: [BodyFrame]) -> Double {
        if let h = fit.standingHeightMetres.value, h > 0 { return h }
        var spans: [Double] = []
        for f in frames {
            guard let head = f.joints3D[Body3DJoint.centerHead]?.cameraPosition else { continue }
            let ankles = [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle].compactMap { f.joints3D[$0]?.cameraPosition }
            guard !ankles.isEmpty else { continue }
            spans.append(ankles.map { simd_length($0 - head) }.max() ?? 0)
        }
        guard let p90 = EvalStats.percentile(spans, 0.9), p90 > 0 else { return 1 }
        return p90 / ankleToNoseFractionOfHeight
    }

    /// A stable identity for the *input* of a shot: its 2-D points and confidences, to 2 decimals,
    /// plus its release time. Two exports of the same session produce the same digest and only one of
    /// them is counted.
    public static func digest(_ shot: BodyShot) -> String {
        // FNV-1a, not `Hasher`: Swift's `Hasher` is seeded per process, so a digest printed in one
        // run would not match the same shot's digest in the next and the report would not be
        // reproducible.
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func feed(_ s: String) {
            for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        }
        feed(String(Int((shot.timing.releaseRealTime * 1000).rounded())))
        feed(String(shot.frames.count))
        for f in shot.frames {
            feed(String(f.frameIndex))
            for k in f.points2D.keys.sorted() {
                let p = f.points2D[k]!
                feed(k)
                feed(String(Int((p.u * 100).rounded())))
                feed(String(Int((p.v * 100).rounded())))
            }
        }
        return String(format: "%016llx", h)
    }
}
