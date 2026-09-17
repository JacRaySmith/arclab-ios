import Foundation
import ShotGeometry
import simd

// MARK: - Make / miss, inferred from the ball at the rim

enum InferredOutcome: String, Sendable {
    case make, miss, unknown
}

struct OutcomeInference: Sendable {
    var outcome: InferredOutcome
    /// The sentence that justifies the label. Always shown: this is an inference, not a score.
    var reason: String
    /// "inferred" when the ball was tracked through the rim zone; "inferred-weak" when it vanished
    /// there (net occlusion) and only its last direction is evidence; nil when the outcome is unknown.
    var strength: String?
}

/// `infer_outcome` from `tools/pytrack/report.py`, ported.
///
/// After the ball first comes within 2 diameters of the rim centre: tracked below the ring and inside
/// its width → make; tracked leaving the zone → miss. When the ball vanishes at the rim (the net eats
/// it) the last four tracked points decide, and the label is marked weak. Anything else stays
/// **unknown** — a shot whose outcome was not seen is not a coin flip to be guessed.
enum RimOutcome {
    /// How long after the arrival the ball's behaviour still counts, in **real** seconds.
    static let postArrivalSeconds = 1.2
    static let zoneDiameters = 2.0
    static let belowDiameters = 1.5
    static let awayDiameters = 2.5

    /// - Parameters:
    ///   - samples: the detections the fit used, `t` in real seconds, `uv` in image pixels.
    ///   - ballDiameterPx: the median detection diameter is the usual choice.
    static func infer(samples: [ImageSample], rimCenterPx: SIMD2<Double>, ballDiameterPx D: Double) -> OutcomeInference {
        guard D > 0 else { return OutcomeInference(outcome: .unknown, reason: "no ball diameter was measured, so the rim zone has no scale", strength: nil) }
        let det = samples.sorted { $0.t < $1.t }
        func distance(_ s: ImageSample) -> Double {
            ((((s.uv.x - rimCenterPx.x) * (s.uv.x - rimCenterPx.x)) + ((s.uv.y - rimCenterPx.y) * (s.uv.y - rimCenterPx.y)))).squareRoot()
        }
        guard let arrival = det.first(where: { distance($0) < zoneDiameters * D }) else {
            return OutcomeInference(outcome: .unknown, reason: "the ball was never tracked within 2 diameters of the rim", strength: nil)
        }
        let tArrival = arrival.t
        let after = det.filter { $0.t > tArrival && $0.t <= tArrival + postArrivalSeconds }
        let below = after.filter { $0.uv.y > rimCenterPx.y + belowDiameters * D && abs($0.uv.x - rimCenterPx.x) < belowDiameters * D }
        let away = after.filter { abs($0.uv.x - rimCenterPx.x) > awayDiameters * D || $0.uv.y < rimCenterPx.y - D }
        if below.count >= 3 && away.count < 2 {
            return OutcomeInference(outcome: .make, reason: "the ball was tracked \(below.count) frames below the ring, inside its width", strength: "inferred")
        }
        if away.count >= 3 && below.count < 2 {
            return OutcomeInference(outcome: .miss, reason: "the ball was tracked \(away.count) frames leaving the rim zone", strength: "inferred")
        }
        // Vanished at the rim: the direction of the last four tracked points is all the evidence there is.
        let last = Array(det.filter { $0.t <= tArrival + 0.4 }.suffix(4))
        if last.count >= 3, let first = last.first, let end = last.last {
            let dv = end.uv.y - first.uv.y
            let inside = abs(end.uv.x - rimCenterPx.x) < 0.8 * D && end.uv.y > rimCenterPx.y - 0.5 * D
            if dv > 0 && inside {
                return OutcomeInference(outcome: .make, reason: "the ball vanished at the rim heading down inside the ring's width (net occlusion)", strength: "inferred-weak")
            }
            if dv < 0 || abs(end.uv.x - rimCenterPx.x) > 1.2 * D {
                return OutcomeInference(outcome: .miss, reason: "the ball vanished at the rim heading up or outside the ring", strength: "inferred-weak")
            }
        }
        return OutcomeInference(outcome: .unknown,
                                reason: "the ball's behaviour at the rim was ambiguous (\(below.count) frames below, \(away.count) leaving)",
                                strength: nil)
    }
}

// MARK: - Which shots a block summary is allowed to count

/// The acceptance rule from `tools/pytrack/report.py` (`accepted`), which is the brief's §4.7 gravity
/// gate plus a plausibility gate on the solved release.
///
/// A shot whose fitted gravity is right can still come out of a failed shot-plane solve — the
/// 2026-09-13 three-point block produced 11 gravity-passing shots with a 1.3 m release height, which
/// is impossible for a jump shot. Those numbers are excluded from the block statistics, not reported.
enum ShotAcceptance {
    static let gravityTolerance = GravityGate.acceptTolerance      // 0.08
    static let releaseHeight = 1.6...3.3                           // m
    static let releaseSpeed = 4.5...11.0                           // m/s
    static let depthPastFrontRim = -0.6...1.0                      // m
    /// A fit whose reprojection residual is this large is not a measurement of a ball flight, whatever
    /// its g came out as (a 162 px residual passed the gravity gate on 2026-09-14). Real tracks sit at
    /// 3–12 px on 1080p footage.
    static let maxReprojectionRmsPx = 25.0
    /// A ball released closer than this to the rim centre is a put-back or a tip, not a shot from a spot. On the
    /// 2026-09-15 240 fps recording, throws from under the basket (released 0.25 m out, 85°) were accepted and
    /// widened the block's release angle from 50.9 ± 1.6° to 58.8 ± 15.2°.
    static let minimumReleaseDistance = 2.0                        // m

    enum Verdict: Sendable, Equatable {
        case accepted
        case lowConfidence(String)
        case rejected(String)

        var isAccepted: Bool { if case .accepted = self { return true }; return false }
        var label: String {
            switch self {
            case .accepted: return "accept"
            case .lowConfidence: return "low confidence"
            case .rejected: return "reject"
            }
        }
        var reason: String? {
            switch self {
            case .accepted: return nil
            case .lowConfidence(let r), .rejected(let r): return r
            }
        }
    }

    static func evaluate(_ a: ShotAnalysis) -> Verdict {
        let c = a.confidence, m = a.metrics
        if c.gravityVerdict == .reject { return .rejected(GravityGate.explain(gFit: c.gFit)) }
        var implausible: [String] = []
        if let r = m.release {
            if !releaseHeight.contains(r.height) {
                implausible.append(String(format: "release height %.2f m is outside %.1f–%.1f m", r.height, releaseHeight.lowerBound, releaseHeight.upperBound))
            }
            if r.distance < minimumReleaseDistance {
                implausible.append(String(format: "the ball was released %.2f m from the rim (a put-back or tip, not a shot from a spot; shots need ≥ %.0f m)", r.distance, minimumReleaseDistance))
            }
            if !releaseSpeed.contains(r.speed) {
                implausible.append(String(format: "release speed %.2f m/s is outside %.1f–%.1f m/s", r.speed, releaseSpeed.lowerBound, releaseSpeed.upperBound))
            }
        }
        if let d = m.depthPastFrontRim, !depthPastFrontRim.contains(d) {
            implausible.append(String(format: "the crossing is %.2f m past the front rim, outside %.1f–%.1f m", d, depthPastFrontRim.lowerBound, depthPastFrontRim.upperBound))
        }
        if !implausible.isEmpty {
            return .lowConfidence("the shot-plane solve is not believable: " + implausible.joined(separator: "; "))
        }
        if c.rmsPx > maxReprojectionRmsPx {
            return .lowConfidence(String(format: "the fitted arc misses the tracked ball by %.0f px on average (limit %.0f px): the track is not one clean flight", c.rmsPx, maxReprojectionRmsPx))
        }
        if c.gravityVerdict == .lowConfidence {
            return .lowConfidence(GravityGate.explain(gFit: c.gFit))
        }
        return .accepted
    }
}

// MARK: - Statistics

struct BlockStat: Sendable {
    var mean: Double
    /// Sample standard deviation (n − 1). `nil` at n = 1: one shot has no spread.
    var sd: Double?
    var n: Int

    /// "46.6 ± 3.6° (n 12)", or "46.6° (n 1, no spread from one shot)".
    func text(unit: String, decimals: Int = 1) -> String {
        let f = "%.\(decimals)f"
        if let sd {
            return String(format: "\(f) ± \(f) \(unit) (n %d)", mean, sd, n)
        }
        return String(format: "\(f) \(unit) (n %d, one shot has no spread)", mean, n)
    }
}

enum Stats {
    static func summarize(_ values: [Double]) -> BlockStat? {
        let v = values.filter { $0.isFinite }
        guard !v.isEmpty else { return nil }
        let mean = v.reduce(0, +) / Double(v.count)
        guard v.count > 1 else { return BlockStat(mean: mean, sd: nil, n: 1) }
        let variance = v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count - 1)
        return BlockStat(mean: mean, sd: variance.squareRoot(), n: v.count)
    }
}

/// One row of the block summary: the numbers for one measured shot, plus what the block rule made of it.
struct BlockRow: Sendable {
    var id: Int
    var verdict: ShotAcceptance.Verdict
    var outcome: OutcomeInference
    var gFit: Double
    var releaseAngleDegrees: Double?
    var releaseHeight: Double?
    var releaseSpeed: Double?
    var entryAngleDegrees: Double?
    var depthPastFrontRim: Double?
    var lateralDeviation: Double?
    var viewClass: ViewClass
    var elbowAtReleaseDegrees: Double?
    var elbowMaxNearReleaseDegrees: Double?
    var kneeMinimumDegrees: Double?
    var dipToReleaseSeconds: Double?
    /// How close the highest tracked ball came to the top edge of the frame, in pixels of its own
    /// upper edge (`v − diameter/2`). ≤ 0 means the ball's top was at or above the edge, which is the
    /// evidence for "the apex left the frame".
    var ballTopMarginPx: Double?

    // MARK: The analyzer's own release distance
    /// Horizontal release point → rim centre, straight from `ShotMetrics.release?.distance`. The
    /// coaching card used to re-derive this from θ, v, h and the depth; it no longer has to.
    var releaseDistance: Double? = nil

    // MARK: The body model (fitted skeleton, `ShotBodyResult`)
    /// Why there is no body row for this shot. Nil when there is one.
    var bodyUnavailableReason: String? = nil
    /// The fitted 3-D elbow at release, degrees. Absolute accuracy is about ±25° (the fitted and the
    /// MediaPipe-world estimates bracket that wide), so this is a within-shooter number only.
    var fittedElbowAtReleaseDegrees: Double? = nil
    /// Frame-to-frame noise of that angle, degrees — the caveat it travels with.
    var fittedElbowJitterDegrees: Double? = nil
    var elbowExtensionPeakDegreesPerSecond: Double? = nil
    var kneeExtensionPeakDegreesPerSecond: Double? = nil
    var fittedKneeMinimumDegrees: Double? = nil
    /// Metres. Only ever present when the shooter stated their height.
    var jumpHeightMetres: Double? = nil
    var dipDepthMetres: Double? = nil
    /// Dip depth as a fraction of the shooter's own ankle-to-nose pixel span: no pixels left in it,
    /// so it survives a change of camera position.
    var dipDepthNormalised: Double? = nil
    /// Dip bottom → release from the fitted wrist path, milliseconds of real time.
    var bodyDipToReleaseMilliseconds: Double? = nil
    var chainOrder: [String]? = nil
    var chainLagsMilliseconds: [Double]? = nil
    /// One sampled frame of real time. A lag at or below it is quantisation, not a measurement.
    var chainFrameFloorMilliseconds: Double? = nil
    var proximalToDistal: Bool? = nil
    /// RMS nose displacement about its mean, dip → release, in pixels.
    var headStabilityPx: Double? = nil
    /// The same, divided by the shooter's pixel height: the comparable-across-setups version.
    var headStabilityNormalised: Double? = nil
    /// Fraction of analysed frames within ±0.4 s of release that carried a hand.
    var handRateAtRelease: Double? = nil
    /// 3-D shoulder-line yaw, degrees. Refused on a near-side view — the shoulder line's depth is not
    /// observable there — so this is normally nil, and the body card says why.
    var shoulderLineYawDegrees: Double? = nil
    /// The shooter's 90th-percentile ankle-to-nose span in pixels: the scale bar behind every
    /// normalised number, and the key the metre-pooling rule compares across sessions.
    var shooterPixelHeight: Double? = nil
}

/// Everything the block header states. Geometry statistics use **only** accepted shots; pose
/// statistics use every shot that produced an angle, because they do not depend on the plane solve.
struct BlockSummary: Sendable {
    var windows: Int              // windows the scanner found
    var tracked: Int              // windows the analyzer measured at all
    var failed: Int               // windows the analyzer could not measure
    var accepted: Int
    var rows: [BlockRow]

    var releaseAngleDegrees: BlockStat?
    var releaseHeight: BlockStat?
    var releaseSpeed: BlockStat?
    var entryAngleDegrees: BlockStat?
    var depthPastFrontRim: BlockStat?
    var gFit: BlockStat?
    var elbowAtReleaseDegrees: BlockStat?
    var elbowMaxNearReleaseDegrees: BlockStat?
    var kneeMinimumDegrees: BlockStat?
    var dipToReleaseSeconds: BlockStat?

    // MARK: Body model
    var fittedElbowAtReleaseDegrees: BlockStat?
    var elbowExtensionPeakDegreesPerSecond: BlockStat?
    var kneeExtensionPeakDegreesPerSecond: BlockStat?
    var fittedKneeMinimumDegrees: BlockStat?
    var bodyDipToReleaseMilliseconds: BlockStat?
    var dipDepthNormalised: BlockStat?
    var headStabilityNormalised: BlockStat?
    var handRateAtRelease: BlockStat?
    /// Metres. Pooled only over shots whose shooter pixel height agrees to 10 % — see `metrePoolingNote`.
    var jumpHeightMetres: BlockStat?
    var dipDepthMetres: BlockStat?
    /// Non-nil when a metre statistic left shots out, or when no metre could be pooled at all.
    var metrePoolingNote: String?
    /// How many shots produced a chain order, and how many of those were proximal-to-distal.
    var proximalToDistal: (yes: Int, n: Int)?
    /// The median of the shots' one-sampled-frame floors, milliseconds: the resolution under every lag.
    var chainFrameFloorMilliseconds: Double?
    /// The median frame-to-frame noise of the fitted elbow over the block, degrees.
    var fittedElbowJitterDegrees: Double?

    var makes: Int { rows.filter { $0.outcome.outcome == .make }.count }
    var misses: Int { rows.filter { $0.outcome.outcome == .miss }.count }
    var unknownOutcomes: Int { rows.filter { $0.outcome.outcome == .unknown }.count }

    /// The one sentence a block summary is allowed to say about its own weight.
    var provenance: String {
        String(format: "%d window%@ found, %d measured, %d counted. Statistics use only the %d shot%@ whose fitted gravity is within %.0f %% of 9.81 and whose release and crossing are physically possible; every other window is listed with its reason and left out. No targets are drawn.",
               windows, windows == 1 ? "" : "s", tracked, accepted, accepted, accepted == 1 ? "" : "s",
               ShotAcceptance.gravityTolerance * 100)
    }

    static func build(windows: Int, failed: Int, rows: [BlockRow]) -> BlockSummary {
        let acc = rows.filter { $0.verdict.isAccepted }
        func geometry(_ key: (BlockRow) -> Double?) -> BlockStat? { Stats.summarize(acc.compactMap(key)) }
        func pose(_ key: (BlockRow) -> Double?) -> BlockStat? { Stats.summarize(rows.compactMap(key)) }
        var s = BlockSummary(windows: windows, tracked: rows.count, failed: failed, accepted: acc.count, rows: rows)
        s.releaseAngleDegrees = geometry { $0.releaseAngleDegrees }
        s.releaseHeight = geometry { $0.releaseHeight }
        s.releaseSpeed = geometry { $0.releaseSpeed }
        s.entryAngleDegrees = geometry { $0.entryAngleDegrees }
        s.depthPastFrontRim = geometry { $0.depthPastFrontRim }
        s.gFit = geometry { $0.gFit }
        s.elbowAtReleaseDegrees = pose { $0.elbowAtReleaseDegrees }
        s.elbowMaxNearReleaseDegrees = pose { $0.elbowMaxNearReleaseDegrees }
        s.kneeMinimumDegrees = pose { $0.kneeMinimumDegrees }
        s.dipToReleaseSeconds = pose { $0.dipToReleaseSeconds }

        // Body statistics use every shot that produced a body model, accepted or not: the body model
        // does not depend on the shot-plane solve, exactly as the 2-D pose angles do not.
        func body(_ key: (BlockRow) -> Double?) -> BlockStat? { Stats.summarize(rows.compactMap(key)) }
        s.fittedElbowAtReleaseDegrees = body { $0.fittedElbowAtReleaseDegrees }
        s.elbowExtensionPeakDegreesPerSecond = body { $0.elbowExtensionPeakDegreesPerSecond }
        s.kneeExtensionPeakDegreesPerSecond = body { $0.kneeExtensionPeakDegreesPerSecond }
        s.fittedKneeMinimumDegrees = body { $0.fittedKneeMinimumDegrees }
        s.bodyDipToReleaseMilliseconds = body { $0.bodyDipToReleaseMilliseconds }
        s.dipDepthNormalised = body { $0.dipDepthNormalised }
        s.headStabilityNormalised = body { $0.headStabilityNormalised }
        s.handRateAtRelease = body { $0.handRateAtRelease }
        s.fittedElbowJitterDegrees = median(rows.compactMap { $0.fittedElbowJitterDegrees })
        s.chainFrameFloorMilliseconds = median(rows.compactMap { $0.chainFrameFloorMilliseconds })
        let chained = rows.filter { $0.proximalToDistal != nil }
        if !chained.isEmpty { s.proximalToDistal = (chained.filter { $0.proximalToDistal == true }.count, chained.count) }

        // Metres are pooled only across shots filmed at the same scale. On IMG_1765 the shooter's
        // ankle-to-nose span was 505 px on two windows and 275 px on a third: the camera or the
        // station moved mid-clip, and a metre derived from one does not describe the other. So any
        // shot whose shooter pixel height is more than 10 % from the block's median is left out of
        // the metre statistics — and the fact is said, not hidden.
        let (metreRows, note) = metrePool(rows)
        s.metrePoolingNote = note
        s.jumpHeightMetres = Stats.summarize(metreRows.compactMap { $0.jumpHeightMetres })
        s.dipDepthMetres = Stats.summarize(metreRows.compactMap { $0.dipDepthMetres })
        return s
    }

    static func median(_ values: [Double]) -> Double? {
        let v = values.filter(\.isFinite).sorted()
        guard !v.isEmpty else { return nil }
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    /// The shots a metre statistic may pool, and the sentence that says who was left out.
    static let shooterPixelHeightTolerance = 0.10

    static func metrePool(_ rows: [BlockRow]) -> ([BlockRow], String?) {
        let withMetre = rows.filter { $0.jumpHeightMetres != nil || $0.dipDepthMetres != nil }
        guard !withMetre.isEmpty else { return ([], nil) }
        let heights = withMetre.compactMap { $0.shooterPixelHeight }
        guard let m = median(heights), m > 1 else {
            return (withMetre, "these metres are not pooled by camera scale: no shot recorded the shooter's pixel height, so there is no way to tell whether the camera moved between them")
        }
        let keep = withMetre.filter { r in
            guard let h = r.shooterPixelHeight else { return false }
            return abs(h - m) <= shooterPixelHeightTolerance * m
        }
        let dropped = withMetre.count - keep.count
        guard dropped > 0 else { return (keep, nil) }
        return (keep, String(format: "%d of %d shots with a metre were left out of the metre means: the shooter measured %.0f %% different in pixels from the block's median (%.0f px), so the camera or the station moved and the two scales are not the same shot.",
                             dropped, withMetre.count, 100 * shooterPixelHeightTolerance, m))
    }

    /// Why a statistic is missing, in the block's own terms. Never a blank.
    func unavailableReason(for stat: BlockStat?, geometry: Bool) -> String {
        if stat != nil { return "" }
        if geometry {
            if accepted == 0 { return tracked == 0 ? "no window was measured yet" : "no measured shot passed the gravity and plausibility gate" }
            return "no accepted shot produced this value (the analyzer said why on each shot)"
        }
        return tracked == 0 ? "no window was measured yet" : "no shot produced this pose angle"
    }

    /// Why a body-model statistic is missing. When every shot failed the body stage for the same
    /// reason, that reason is the answer; otherwise the per-shot body cards carry the detail.
    func bodyUnavailableReason(for stat: BlockStat?) -> String {
        if stat != nil { return "" }
        if tracked == 0 { return "no window was measured yet" }
        let reasons = rows.compactMap(\.bodyUnavailableReason)
        if reasons.count == rows.count,
           let common = Dictionary(grouping: reasons, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key {
            return common
        }
        return "no shot produced this body measure; each shot's own body card says why"
    }
}

extension BlockRow {
    /// Build a row from one analysed shot. `rimCenterPx` and `ballDiameterPx` drive the outcome inference.
    init(id: Int, result: ShotRunResult, rimCenterPx: SIMD2<Double>) {
        let a = result.analysis, m = a.metrics
        let diameters = result.samples.compactMap(\.diameterPx).sorted()
        let D = diameters.isEmpty ? 0 : diameters[diameters.count / 2]
        self.init(id: id,
                  verdict: ShotAcceptance.evaluate(a),
                  outcome: RimOutcome.infer(samples: result.samples, rimCenterPx: rimCenterPx, ballDiameterPx: D),
                  gFit: a.confidence.gFit,
                  releaseAngleDegrees: m.release?.angleDegrees,
                  releaseHeight: m.release?.height,
                  releaseSpeed: m.release?.speed,
                  entryAngleDegrees: m.entryAngleDegrees,
                  depthPastFrontRim: m.depthPastFrontRim,
                  lateralDeviation: m.lateralDeviation,
                  viewClass: a.confidence.viewClass,
                  elbowAtReleaseDegrees: result.pose?.angles?.elbowAtReleaseDegrees,
                  elbowMaxNearReleaseDegrees: result.pose?.angles?.elbowMaxNearReleaseDegrees,
                  kneeMinimumDegrees: result.pose?.angles?.kneeMinimumDegrees,
                  dipToReleaseSeconds: result.pose?.dipToReleaseSeconds,
                  ballTopMarginPx: result.samples.map { $0.uv.y - ($0.diameterPx ?? D) / 2 }.min(),
                  releaseDistance: m.release?.distance)
        apply(body: result.body, reason: result.bodyUnavailableReason)
    }

    /// Copy the trustworthy half of the body model onto the row. Degrees at the boundary: every angle
    /// below leaves `BodyKinematics` in radians and arrives here in degrees, once.
    mutating func apply(body: ShotBodyResult?, reason: String?) {
        guard let body else {
            bodyUnavailableReason = reason ?? "the body stage did not run for this shot"
            return
        }
        bodyUnavailableReason = nil
        fittedElbowAtReleaseDegrees = body.elbowAtRelease.degrees
        fittedElbowJitterDegrees = body.elbowJitterDegrees
        elbowExtensionPeakDegreesPerSecond = body.elbowExtensionPeakRate.degrees
        kneeExtensionPeakDegreesPerSecond = body.kneeExtensionPeakRate.degrees
        fittedKneeMinimumDegrees = body.kneeMinimum.degrees
        jumpHeightMetres = body.jumpHeight.value
        dipDepthMetres = body.dipDepthMetres.value
        dipDepthNormalised = body.dipDepthNormalised.value
        bodyDipToReleaseMilliseconds = body.dipToReleaseMilliseconds.value
        chainOrder = body.chainUnavailableReason == nil && !body.chainOrder.isEmpty ? body.chainOrder : nil
        chainLagsMilliseconds = chainOrder == nil ? nil : body.chainLagsMilliseconds
        chainFrameFloorMilliseconds = body.frameFloorMilliseconds.isFinite ? body.frameFloorMilliseconds : nil
        proximalToDistal = body.chainProximalToDistal
        headStabilityPx = body.headStabilityPx.value
        headStabilityNormalised = body.headStabilityNormalised.value
        handRateAtRelease = body.handRateAtRelease.value
        shoulderLineYawDegrees = body.shoulderLineYaw.degrees
        shooterPixelHeight = body.shooterPixelHeight
    }
}
