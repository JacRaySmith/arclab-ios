import Foundation

// ================================================================================================
// MARK: - Is this analysis a measurement of a basketball shot?
// ================================================================================================
//
// One rule, in one place. Until 2026-09-27 there were three copies of it — `App/Sources/BlockSummary.swift`
// (what the phone shows), `Packages/ShotVideo/Sources/TrajectoryProbe/Probe.swift` (`case "session":`)
// and `Packages/ShotGeometry/Sources/ShotBenchKit/Acceptance.swift` (what every `ShotBench` number and
// every `docs/EXPERIMENTS.md` row was scored with) — and the app's copy had drifted away from the other
// two in two ways:
//
//   1. `minimumReleaseDistance` (2.0 m) existed only in the app, so the bench counted put-backs and tips
//      as shots that the phone refuses.
//   2. A window with no `depthPastFrontRim` (arc not tracked past apex, frontal view, or an arc that
//      never reaches rim height) was **refused** by the bench and **accepted** by the app, because the
//      bench's `plausible` opened with `guard let depth … else { return false }` and the app's checked
//      the depth only `if let`.
//
// Both copies claimed in their own doc comments to mirror the app. The rule now lives here, the other
// three import it, and `ShotAcceptanceTests` pins both behaviours so the divergence cannot come back.
//
// `Policy.legacyBench` reproduces the pre-2026-09-27 bench rule exactly, so every number already in
// `docs/EXPERIMENTS.md` and `docs/BENCH-RESULTS-*.md` stays reproducible instead of becoming
// unexplainable.

/// The thresholds that decide whether an analysis is reported as a measurement.
///
/// Every bound here is a **stated convention**, not a derived constant: it is the range outside which a
/// number is more likely to be a failed solve than a real shot by a real shooter. Each carries the
/// evidence that set it.
public struct ShotAcceptancePolicy: Sendable, Equatable {
    /// Relative |g_fit − 9.81| / 9.81 still called a measurement. `GravityGate.acceptTolerance`.
    public var gravityTolerance: Double
    /// Plausible release height for a jump shot, metres.
    public var releaseHeight: ClosedRange<Double>
    /// Plausible release speed, m/s.
    public var releaseSpeed: ClosedRange<Double>
    /// Plausible rim-plane crossing relative to the front rim, metres.
    public var depthPastFrontRim: ClosedRange<Double>
    /// A fit whose reprojection residual is this large is not a measurement of a ball flight, whatever
    /// its g came out as (a 162 px residual passed the gravity gate on 2026-09-14). Real tracks sit at
    /// 3–12 px on 1080p footage.
    public var maxReprojectionRmsPx: Double
    /// A ball released closer than this to the rim centre is a put-back or a tip, not a shot from a
    /// spot. On the 2026-09-15 240 fps recording, throws from under the basket (released 0.25 m out,
    /// 85°) were accepted and widened the block's release angle from 50.9 ± 1.6° to 58.8 ± 15.2°.
    /// `nil` disables the check (what the bench did before 2026-09-27).
    public var minimumReleaseDistance: Double?
    /// When true, a window whose `depthPastFrontRim` could not be computed is refused rather than
    /// having the depth check skipped. The shipping app skips it: CLAUDE.md rule 1 says an
    /// unavailable metric is `nil` with a reason, and "unavailable" is not the same claim as
    /// "implausible". The pre-2026-09-27 bench refused it.
    public var requireDepth: Bool

    public init(gravityTolerance: Double, releaseHeight: ClosedRange<Double>, releaseSpeed: ClosedRange<Double>,
                depthPastFrontRim: ClosedRange<Double>, maxReprojectionRmsPx: Double,
                minimumReleaseDistance: Double?, requireDepth: Bool) {
        self.gravityTolerance = gravityTolerance
        self.releaseHeight = releaseHeight
        self.releaseSpeed = releaseSpeed
        self.depthPastFrontRim = depthPastFrontRim
        self.maxReprojectionRmsPx = maxReprojectionRmsPx
        self.minimumReleaseDistance = minimumReleaseDistance
        self.requireDepth = requireDepth
    }

    /// What the phone applies, and therefore what every bench number should be measuring.
    public static let shipping = ShotAcceptancePolicy(
        gravityTolerance: GravityGate.acceptTolerance,
        releaseHeight: 1.6...3.3,
        releaseSpeed: 4.5...11.0,
        depthPastFrontRim: -0.6...1.0,
        maxReprojectionRmsPx: 25.0,
        minimumReleaseDistance: 2.0,
        requireDepth: false)

    /// A short name for the scorecard, so a run always records which rule produced its numbers.
    public var name: String {
        if self == .shipping { return "shipping" }
        if self == .legacyBench { return "legacyBench" }
        return "custom"
    }

    /// The rule `ShotBench` applied before 2026-09-27. Kept so the existing ledger stays reproducible.
    public static let legacyBench = ShotAcceptancePolicy(
        gravityTolerance: GravityGate.acceptTolerance,
        releaseHeight: 1.6...3.3,
        releaseSpeed: 4.5...11.0,
        depthPastFrontRim: -0.6...1.0,
        maxReprojectionRmsPx: 25.0,
        minimumReleaseDistance: nil,
        requireDepth: true)
}

/// The acceptance rule: the brief's §4.7 gravity gate, a plausibility gate on the solved release, and a
/// ceiling on the fit's reprojection residual.
///
/// A shot whose fitted gravity is right can still come out of a failed shot-plane solve — the
/// 2026-09-13 three-point block produced 11 gravity-passing shots with a 1.3 m release height, which is
/// impossible for a jump shot. Those numbers are excluded from the block statistics, not reported.
public enum ShotAcceptance {
    // Kept as the names the app already reads, so call sites do not have to change.
    public static var gravityTolerance: Double { ShotAcceptancePolicy.shipping.gravityTolerance }
    public static var releaseHeight: ClosedRange<Double> { ShotAcceptancePolicy.shipping.releaseHeight }
    public static var releaseSpeed: ClosedRange<Double> { ShotAcceptancePolicy.shipping.releaseSpeed }
    public static var depthPastFrontRim: ClosedRange<Double> { ShotAcceptancePolicy.shipping.depthPastFrontRim }
    public static var maxReprojectionRmsPx: Double { ShotAcceptancePolicy.shipping.maxReprojectionRmsPx }
    public static var minimumReleaseDistance: Double { ShotAcceptancePolicy.shipping.minimumReleaseDistance ?? 0 }

    public enum Verdict: Sendable, Equatable {
        case accepted
        case lowConfidence(String)
        case rejected(String)

        public var isAccepted: Bool { if case .accepted = self { return true }; return false }
        public var label: String {
            switch self {
            case .accepted: return "accept"
            case .lowConfidence: return "low confidence"
            case .rejected: return "reject"
            }
        }
        public var reason: String? {
            switch self {
            case .accepted: return nil
            case .lowConfidence(let r), .rejected(let r): return r
            }
        }
    }

    /// The full verdict, with the user-facing sentence for anything that is not an accept.
    public static func evaluate(_ a: ShotAnalysis, policy: ShotAcceptancePolicy = .shipping) -> Verdict {
        let c = a.confidence, m = a.metrics
        if c.gravityVerdict == .reject { return .rejected(GravityGate.explain(gFit: c.gFit)) }
        var implausible: [String] = []
        if let r = m.release {
            if !policy.releaseHeight.contains(r.height) {
                implausible.append(String(format: "release height %.2f m is outside %.1f–%.1f m", r.height,
                                          policy.releaseHeight.lowerBound, policy.releaseHeight.upperBound))
            }
            if let minD = policy.minimumReleaseDistance, r.distance < minD {
                implausible.append(String(format: "the ball was released %.2f m from the rim (a put-back or tip, not a shot from a spot; shots need ≥ %.0f m)", r.distance, minD))
            }
            if !policy.releaseSpeed.contains(r.speed) {
                implausible.append(String(format: "release speed %.2f m/s is outside %.1f–%.1f m/s", r.speed,
                                          policy.releaseSpeed.lowerBound, policy.releaseSpeed.upperBound))
            }
        } else if policy.requireDepth {
            // The legacy bench rule refused a window with no release at all, via the same `guard let`.
            implausible.append("release unavailable: " + (m.releaseUnavailableReason ?? "not observed"))
        }
        if let d = m.depthPastFrontRim {
            if !policy.depthPastFrontRim.contains(d) {
                implausible.append(String(format: "the crossing is %.2f m past the front rim, outside %.1f–%.1f m", d,
                                          policy.depthPastFrontRim.lowerBound, policy.depthPastFrontRim.upperBound))
            }
        } else if policy.requireDepth {
            implausible.append("depth past front rim unavailable: " + (m.entryAngleUnavailableReason ?? "not computed"))
        }
        if !implausible.isEmpty {
            return .lowConfidence("the shot-plane solve is not believable: " + implausible.joined(separator: "; "))
        }
        if c.rmsPx > policy.maxReprojectionRmsPx {
            return .lowConfidence(String(format: "the fitted arc misses the tracked ball by %.0f px on average (limit %.0f px): the track is not one clean flight", c.rmsPx, policy.maxReprojectionRmsPx))
        }
        if c.gravityVerdict == .lowConfidence {
            return .lowConfidence(GravityGate.explain(gFit: c.gFit))
        }
        return .accepted
    }

    /// Whether this analysis counts as a measurement.
    public static func accepted(_ a: ShotAnalysis, policy: ShotAcceptancePolicy = .shipping) -> Bool {
        evaluate(a, policy: policy).isAccepted
    }

    /// Why `accepted` returned false, for a window that *did* produce an analysis (as opposed to one
    /// where `ShotAnalyzer.analyze` threw — that reason is the thrown error's description).
    public static func refusalReason(_ a: ShotAnalysis, policy: ShotAcceptancePolicy = .shipping) -> String? {
        evaluate(a, policy: policy).reason
    }

    /// The plausibility half of the rule on its own, for callers that only have metrics.
    public static func plausible(_ m: ShotMetrics, policy: ShotAcceptancePolicy = .shipping) -> Bool {
        guard let r = m.release else { return !policy.requireDepth }
        if !policy.releaseHeight.contains(r.height) { return false }
        if !policy.releaseSpeed.contains(r.speed) { return false }
        if let minD = policy.minimumReleaseDistance, r.distance < minD { return false }
        if let d = m.depthPastFrontRim { return policy.depthPastFrontRim.contains(d) }
        return !policy.requireDepth
    }
}
