import Foundation
import simd

// ================================================================================================
// MARK: - Footwork: the feet, the gather, and what one camera can and cannot see of them
// ================================================================================================
//
// Track C of `docs/PLAN-1.1-2026-09-15.md`. The user's ask: "if I was shooting off the dribble in a
// drill ... then it should be able to tell me if I'm stepping wrong."
//
// The measurement plane. Every length here is measured **in the image**, in the shooter's own
// *stature units* — the ankle-to-nose image span, the same ruler `ShotBodyResult.dipDepthNormalised`
// uses. That is deliberate: the ankles' *image row* is the one thing a single camera measures well
// (1–2 px of jitter), while their separation *in depth* is the thing it cannot measure at all. A
// footwork metric built on the fitted 3-D depth would look precise and be fiction.
//
// What follows from that (`FootworkMetrics.viewFrontalProjection`):
//
//   body frame: x toward the rim, y across (the shooter's left), z up   (FormModel.swift header)
//
//   Let θ be the ground-plane angle between the camera and the shooter's facing direction. The
//   image's horizontal axis then carries  y·cos θ  and  −x·sin θ. So
//     * a **near-frontal** camera (|cos θ| → 1) sees the side-to-side axis: stance *width*, lateral
//       drift. It is blind to the front-back axis: stagger, travel toward the rim.
//     * a **near-side** camera (|sin θ| → 1) sees the front-back axis: stagger, drift toward the
//       rim, forward travel on the jump. It is blind to stance width.
//     * a **45° front-side** camera — the one you want for the foot's *yaw* — is the worst of both
//       for separating width from stagger: one image-horizontal number mixes them in equal measure
//       and no single camera can split it. That is a filming fact, not a modelling choice, and it is
//       why `docs/DESIGN-FOOTWORK-2026-09-15.md` asks for two camera positions rather than one.
//
// θ is not assumed. It is measured each shot from the hip line's image span against Winter's
// population biiliac breadth (0.191 H), the same prior `BodySkeletonOptions` already carries. Only
// |cos θ| is recoverable that way (front and back look alike), which is all these rules need.
//
// CLAUDE.md rule 1 throughout: a number a view cannot carry is `nil` with the reason, and the reason
// says which camera position would carry it.

// MARK: - A measured value

/// A `BodyMeasure` plus where the number came from. `BodyMeasure` has no provenance field and
/// `BodyKinematics.swift` is not this file's to change, so provenance rides alongside.
///
/// `BodyMeasure.Unit` likewise has no "stature" case; stature-unit lengths are carried as `.ratio`
/// and the provenance string names the ruler. Convert with `FootworkMetrics.metresPerStatureUnit`,
/// which is itself `nil` with a reason unless a standing height was stated.
public struct FootworkValue: Sendable, Codable, Equatable {
    public var measure: BodyMeasure
    public var provenance: String

    public init(measure: BodyMeasure, provenance: String) {
        self.measure = measure; self.provenance = provenance
    }
    public static func ok(_ v: Double, _ u: BodyMeasure.Unit, _ provenance: String) -> FootworkValue {
        .init(measure: .ok(v, u), provenance: provenance)
    }
    public static func missing(_ u: BodyMeasure.Unit, _ reason: String, _ provenance: String = "not measured") -> FootworkValue {
        .init(measure: .missing(u, reason), provenance: provenance)
    }
    public var value: Double? { measure.value }
    public var unit: BodyMeasure.Unit { measure.unit }
    public var unavailableReason: String? { measure.unavailableReason }
    public var isAvailable: Bool { measure.isAvailable }
    /// Degrees at the boundary, and nil for anything that is not an angle — `BodyMeasure`'s rule.
    public var degrees: Double? { measure.degrees }
    public func describe(_ format: String = "%.3f") -> String { measure.describe(format) }
}

// MARK: - Feet, contacts, patterns

public enum FootSide: String, Sendable, Codable, CaseIterable {
    case left, right
    public var other: FootSide { self == .left ? .right : .left }
    /// The 2-D ankle landmark for this foot.
    public var ankle2D: String { self == .left ? Body2DPoint.leftAnkle : Body2DPoint.rightAnkle }
    public var knee2D: String { self == .left ? Body2DPoint.leftKnee : Body2DPoint.rightKnee }
}

/// One interval the foot spent on the floor, read from the ankle's image row.
public struct FootContact: Sendable, Codable, Equatable {
    public var foot: FootSide
    public var startRealTime: Double
    public var endRealTime: Double
    /// True when a flight was seen *before* this contact — i.e. the start is a real touchdown and not
    /// merely the first frame of the analysis window.
    public var isTouchdown: Bool
    /// True when that preceding flight was *fully contained* in the window, take-off included. A
    /// landing whose take-off happened before the window opened is a real landing but not evidence
    /// of a step into this shot — the shooter may simply have been walking in — so only these count
    /// toward `FootworkMetrics.stepCount`.
    public var precedingFlightFullySeen: Bool
    /// True when a flight was seen *after* it — the end is a real take-off.
    public var isTakeoff: Bool
    public var samples: Int
    /// Mean ankle height above this foot's own floor over the interval, stature units.
    public var meanHeightStature: Double
    public var durationSeconds: Double { endRealTime - startRealTime }
}

public enum FootworkPattern: String, Sendable, Codable, CaseIterable {
    /// Both feet were already on the floor when the window opened and neither touched down again
    /// before the lift: a spot-up or a free throw.
    case stationary
    /// Both feet touched down within `FootworkOptions.hopSimultaneitySeconds` of each other.
    case hop
    /// Two touchdowns, separated: the 1-2.
    case oneTwo
    /// One foot touched down; the other never left the floor inside the window.
    case singleStep
    case unknown

    public var title: String {
        switch self {
        case .stationary: return "stationary"
        case .hop: return "hop"
        case .oneTwo: return "1-2 step"
        case .singleStep: return "single step"
        case .unknown: return "not determined"
        }
    }
}

// MARK: - Options

public struct FootworkOptions: Sendable {
    /// A 2-D point below this confidence is not used. Matches `BodyKinematicsOptions`.
    public var minimumConfidence2D: Double = 0.3
    /// Centred moving-average half-window on the ankle height series, samples. 2 → 5 samples, which
    /// at the phone's ~79 analysed frames per second is 63 ms — shorter than any real flight phase.
    public var smoothingHalfWindow: Int = 2
    /// How far the ankle must rise above its own floor to count as airborne, stature units.
    /// 0.02 stature ≈ 3.4 cm on a 1.70 m shooter, and 5–10× the 1–2 px of ankle jitter the pose
    /// stage shows. An in-house threshold tied to the measured noise, not a coaching number.
    public var liftHeightStature: Double = 0.020
    /// A candidate flight must also reach this vertical ankle speed somewhere inside it, stature
    /// units per second. Rejects a slow upward creep (the shooter rising on the toes, or the crop
    /// drifting) being read as a step.
    public var flightSpeedStaturePerSecond: Double = 0.30
    public var minimumContactSeconds: Double = 0.05
    public var minimumFlightSeconds: Double = 0.05
    /// Two touchdowns closer together than this are one hop rather than a 1-2. A coaching
    /// convention (Dr Dish: "a hop is a really quick 1-2"), graded C in `FootworkNorms`.
    public var hopSimultaneitySeconds: Double = 0.06
    /// |cos θ| at or above which the side-to-side axis is taken as measurable (θ ≤ 26°).
    public var frontalProjectionForWidth: Double = 0.90
    /// |sin θ| at or above which the front-back axis is taken as measurable (θ ≥ 64°).
    public var sideProjectionForDepth: Double = 0.90
    /// An ankle within this many pixels of a frame border is clipped: its row is the border's, not
    /// the joint's. Matches `BodyKinematicsOptions.edgeMarginPx`.
    public var edgeMarginPixels: Double = 6
    /// Above this clipped fraction the foot's contacts are refused outright.
    public var maximumClippedFraction: Double = 0.20
    /// Winter's segment table, as `BodySkeletonOptions` carries them.
    public var biiliacFractionOfHeight: Double = 0.191
    public var biacromialFractionOfHeight: Double = 0.245
    public var ankleToNoseFractionOfHeight: Double = 0.891
    /// "left" or "right". Rules that talk about the shooting-side foot need it.
    public var shootingSide: String?
    /// The rim's image column, pixels. Gives every along-the-line number its sign (toward the rim
    /// positive, as `docs/reference/digest-ch12-13-angles-errorbudget.md` §12.8 defines `drift_m`).
    public var rimImageU: Double?
    /// The same thing when only the *direction* survives and not the column: +1 = the rim lies
    /// camera-right of the shooter, −1 = camera-left. A `BodyShot` export carries this — its body
    /// frame's x axis is "the camera's horizontal toward the rim's image column" — but not the
    /// column itself, so the reader recovers the sign and passes it here. Takes precedence over
    /// `rimImageU`; the provenance says which of the two a number was signed by.
    public var rimBearingSign: Double?
    /// The rim must sit at least this far from the shooter's own column, stature units, before the
    /// image horizontal is taken to point at it. A rim directly behind the shooter's head in the
    /// image gives no bearing.
    public var minimumRimOffsetStature: Double = 0.5
    /// A physical ceiling on how fast the mid-hip may move across the image, stature units per
    /// second. A hip that exceeds it between the plant and the release did not move — the tracker
    /// lost it — so the drift measured over that interval is refused. `BodyKinematicsOptions`
    /// carries the same idea as `maximumHipSpeedMetresPerSecond`.
    public var maximumHipSpeedStaturePerSecond: Double = 4.0
    /// How far from an instant a frame may sit and still stand in for it, real seconds. ~6 frames at
    /// the phone's analysed rate.
    public var hipMatchToleranceSeconds: Double = 0.08
    /// The hip line's image span must be this steady across the set window — median absolute
    /// deviation ÷ median — before the camera's angle is taken from it. A hip point that jumps makes
    /// a side view look frontal, and then every de-projected number divides by the wrong factor.
    public var maximumHipSpanRelativeMAD: Double = 0.35
    /// The shooter's standing height in metres, when one was stated, and whether it was *measured*
    /// rather than typed in. Only ever used to publish `metresPerStatureUnit`.
    public var standingHeightMetres: Double?
    public var heightIsMeasured: Bool = false

    public init(shootingSide: String? = nil, rimImageU: Double? = nil,
                standingHeightMetres: Double? = nil, heightIsMeasured: Bool = false) {
        self.shootingSide = shootingSide
        self.rimImageU = rimImageU
        self.standingHeightMetres = standingHeightMetres
        self.heightIsMeasured = heightIsMeasured
    }
}

// MARK: - The metrics

public struct FootworkMetrics: Sendable, Codable, Equatable {

    // -- contacts and the pattern ------------------------------------------------------------
    public var contacts: [FootContact]
    public var contactsUnavailable: [String: String]      // foot raw value → why it has no contacts
    public var pattern: FootworkPattern
    /// Why that label — in words, always, including for `.unknown`.
    public var patternReason: String
    public var stepCount: FootworkValue                   // touchdowns before the lift
    public var firstFootDown: FootSide?
    /// True when the first foot down is the shooting-side foot (right foot for a right-handed
    /// shooter). Nil when either the order or the shooting side is unknown.
    public var firstFootDownIsShootingSide: Bool?
    public var firstFootDownUnavailableReason: String?
    public var stepSeparationSeconds: FootworkValue       // second touchdown − first

    // -- the gather -----------------------------------------------------------------------------
    /// Time of the last take-off before the release (the second foot to leave the floor).
    public var liftRealTime: Double?
    public var liftUnavailableReason: String?
    /// Time of the last touchdown before the lift — the plant the shot is gathered off.
    public var lastPlantRealTime: Double?
    /// Last plant → release. Undefined on a shot with no step into it, and then `nil` with that said.
    public var gatherSeconds: FootworkValue
    /// Take-off → release. Defined on any shot that leaves the floor, stationary ones included.
    public var liftToReleaseSeconds: FootworkValue

    // -- the stance -----------------------------------------------------------------------------
    /// What the camera actually measured: the ankles' separation along the image horizontal at the
    /// set, stature units. A mixture of width and stagger in proportions the view sets.
    public var ankleSeparationImage: FootworkValue
    /// Side-to-side separation. Near-frontal views only.
    public var stanceWidth: FootworkValue
    /// Front-back offset, + = the shooting-side foot nearer the rim. Near-side views only.
    public var stanceStagger: FootworkValue
    /// The shooting-side foot's yaw against the rim bearing at the set. Available **only** when a
    /// foot triangle was fitted for this shot (1.3 Track C); without one it is nil with
    /// `footAngleWithoutDetectorReason`, which is what it was on every shot before 2026-09-16.
    public var footAngleToRim: FootworkValue
    /// The other foot's, and the angle between the two — how open the stance is.
    public var otherFootAngleToRim: FootworkValue
    public var stanceOpenness: FootworkValue
    public var footAngleNote: String
    /// Which part of each foot reached the floor first, per touchdown before the lift. Empty when
    /// no foot detector ran, and each entry carries its own reason when it could not be read.
    public var footStrikes: [FootStrikeEvent]

    // -- drift and travel -----------------------------------------------------------------------
    /// Mid-hip displacement along the image horizontal, last plant (or the set) → release, stature
    /// units, signed toward the rim when the rim column is known.
    public var hipDriftImage: FootworkValue
    /// Across the shot line. Near-frontal views only.
    public var hipDriftLateral: FootworkValue
    /// Along the shot line, + = toward the rim. Near-side views only.
    public var hipDriftTowardRim: FootworkValue
    /// Mid-hip rise, lift → release, stature units.
    public var jumpRise: FootworkValue
    /// Mid-hip travel toward the rim over the same interval. Near-side views only.
    public var jumpForwardTravel: FootworkValue
    /// Mid-hip travel across the shot line over the same interval. Near-frontal views only.
    public var jumpLateralTravel: FootworkValue

    // -- the view -------------------------------------------------------------------------------
    /// |cos θ|: 1 = the camera is square in front of (or behind) the shooter, 0 = square to the side.
    public var viewFrontalProjection: FootworkValue
    /// θ itself, radians, unsigned: the hip line's foreshortening cannot tell front from back.
    public var viewAzimuth: FootworkValue
    public var rimBearingSign: Double?                    // +1 rim camera-right, −1 camera-left
    public var rimBearingUnavailableReason: String?

    // -- provenance -----------------------------------------------------------------------------
    public var setRealTime: Double?
    public var releaseRealTime: Double
    public var statureImagePixels: Double?
    /// Metres per stature unit, so any length above can be taken to metres — and refused with a
    /// reason when no standing height was stated.
    public var metresPerStatureUnit: FootworkValue
    public var framesUsed: Int
    public var shootingSide: String?
    public var warnings: [String]
    public var notes: [String]
    /// Set when nothing at all could be computed.
    public var unavailableReason: String?

    /// Kept under its old name so every existing reader and test still compiles, and reworded: as of
    /// 1.3 Track C the foot angle *is* measurable, but only on a pass that ran the foot detector.
    public static let footAngleAlwaysUnavailable = footAngleWithoutDetectorReason
    public static let footAngleWithoutDetectorReason =
        "Vision's body pose returns no toe and no heel landmark — only the ankle joint — so the foot's long axis is not in this timeline. ArcLab can now measure it: run the pass with `BodyTracker.Options.detectFeet`, which adds the six Halpe-26 foot points, then `FootTriangleFit.run`, and pass the tracks in. Without that this number has no observation behind it."
}

// MARK: - Computing them

extension FootworkMetrics {

    /// An all-refused record, so a caller never has to handle a missing value.
    public static func unavailable(_ why: String, releaseRealTime: Double = .nan,
                                   shootingSide: String? = nil) -> FootworkMetrics {
        func m(_ u: BodyMeasure.Unit) -> FootworkValue { .missing(u, why) }
        return FootworkMetrics(
            contacts: [], contactsUnavailable: ["left": why, "right": why],
            pattern: .unknown, patternReason: why,
            stepCount: m(.count), firstFootDown: nil, firstFootDownIsShootingSide: nil,
            firstFootDownUnavailableReason: why, stepSeparationSeconds: m(.seconds),
            liftRealTime: nil, liftUnavailableReason: why, lastPlantRealTime: nil,
            gatherSeconds: m(.seconds), liftToReleaseSeconds: m(.seconds),
            ankleSeparationImage: m(.ratio), stanceWidth: m(.ratio), stanceStagger: m(.ratio),
            footAngleToRim: .missing(.radians, footAngleWithoutDetectorReason),
            otherFootAngleToRim: .missing(.radians, footAngleWithoutDetectorReason),
            stanceOpenness: .missing(.radians, footAngleWithoutDetectorReason),
            footAngleNote: footAngleWithoutDetectorReason, footStrikes: [],
            hipDriftImage: m(.ratio), hipDriftLateral: m(.ratio), hipDriftTowardRim: m(.ratio),
            jumpRise: m(.ratio), jumpForwardTravel: m(.ratio), jumpLateralTravel: m(.ratio),
            viewFrontalProjection: m(.ratio), viewAzimuth: m(.radians),
            rimBearingSign: nil, rimBearingUnavailableReason: why,
            setRealTime: nil, releaseRealTime: releaseRealTime, statureImagePixels: nil,
            metresPerStatureUnit: m(.metres), framesUsed: 0, shootingSide: shootingSide,
            warnings: [], notes: [], unavailableReason: why)
    }

    // ---- small numeric helpers (local: this file owns its own noise handling) ------------------

    static func fwPercentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let i = max(0, min(s.count - 1, Int((Double(s.count - 1) * p).rounded())))
        return s[i]
    }
    static func fwMedian(_ xs: [Double]) -> Double? { fwPercentile(xs, 0.5) }

    static func smoothed(_ xs: [Double], halfWindow: Int) -> [Double] {
        guard halfWindow > 0, xs.count > 2 * halfWindow else { return xs }
        var out = xs
        for i in xs.indices {
            let lo = max(0, i - halfWindow), hi = min(xs.count - 1, i + halfWindow)
            var s = 0.0
            for j in lo...hi { s += xs[j] }
            out[i] = s / Double(hi - lo + 1)
        }
        return out
    }

    /// The shooter's ankle-to-nose image span, 90th percentile — the ruler, as
    /// `ShotBodyResult.ankleToNosePixels` defines it (the tallest frames are the straight-legged ones).
    static func statureImagePixels(_ frames: [BodyFrame], _ minimumConfidence: Double) -> Double? {
        var spans: [Double] = []
        for f in frames {
            guard let nose = f.points2D[Body2DPoint.nose], nose.confidence >= minimumConfidence else { continue }
            var rows: [Double] = []
            for a in [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle] {
                if let p = f.points2D[a], p.confidence >= minimumConfidence { rows.append(p.v) }
            }
            guard let lowest = rows.max() else { continue }
            let span = lowest - nose.v
            if span > 1 { spans.append(span) }
        }
        return fwPercentile(spans, 0.9)
    }

    // ---- the ankle series ----------------------------------------------------------------------

    struct FootSeries {
        var t: [Double] = []
        var u: [Double] = []
        var v: [Double] = []
        var clippedFraction: Double = 0
    }

    static func series(_ frames: [BodyFrame], foot: FootSide, imageHeight: Int,
                       _ o: FootworkOptions) -> FootSeries {
        var s = FootSeries()
        var clipped = 0
        for f in frames {
            guard let p = f.points2D[foot.ankle2D], p.confidence >= o.minimumConfidence2D else { continue }
            s.t.append(f.realTime); s.u.append(p.u); s.v.append(p.v)
            if imageHeight > 0, p.v >= Double(imageHeight) - o.edgeMarginPixels { clipped += 1 }
        }
        s.clippedFraction = s.t.isEmpty ? 1 : Double(clipped) / Double(s.t.count)
        return s
    }

    /// Ground contacts for one foot: the ankle's image row turned into height above its own floor,
    /// smoothed, then split into runs. A run counts as flight only if it both lasts long enough and
    /// reaches a real vertical speed — a height threshold alone would read tracker drift as a step.
    static func contacts(_ s: FootSeries, foot: FootSide, stature: Double,
                         _ o: FootworkOptions) -> (contacts: [FootContact], reason: String?) {
        guard s.t.count >= 5 else {
            return ([], "the \(foot.rawValue) ankle was confident on only \(s.t.count) analysed frames: too few to read a ground contact from")
        }
        guard s.clippedFraction <= o.maximumClippedFraction else {
            return ([], String(format: "the %@ ankle sat on the bottom edge of the frame on %.0f %% of the frames it was seen: a clipped ankle's row is the border's, not the joint's, so its contacts are not a measurement. Frame the shooter with the floor in shot.",
                               foot.rawValue, 100 * s.clippedFraction))
        }
        guard let floorV = fwPercentile(s.v, 0.90) else { return ([], "no ankle row survived") }
        let raw = s.v.map { (floorV - $0) / stature }           // + = higher in the world
        let h = smoothed(raw, halfWindow: o.smoothingHalfWindow)

        var speed = [Double](repeating: 0, count: h.count)
        for i in h.indices {
            let lo = max(0, i - 1), hi = min(h.count - 1, i + 1)
            let dt = s.t[hi] - s.t[lo]
            speed[i] = dt > 0 ? abs((h[hi] - h[lo]) / dt) : 0
        }

        var airborne = h.map { $0 > o.liftHeightStature }
        // Runs, then repair: a flight that is too short or too slow is not a flight; a contact that
        // is too short is not a contact. Interior runs only — the window's own ends are truncated,
        // not short.
        func runs(_ flags: [Bool]) -> [(air: Bool, lo: Int, hi: Int)] {
            var out: [(Bool, Int, Int)] = []
            var i = 0
            while i < flags.count {
                var j = i
                while j + 1 < flags.count && flags[j + 1] == flags[i] { j += 1 }
                out.append((flags[i], i, j)); i = j + 1
            }
            return out.map { (air: $0.0, lo: $0.1, hi: $0.2) }
        }
        for _ in 0..<50 {
            let r = runs(airborne)
            guard r.count > 1 else { break }
            var changed = false
            for (k, run) in r.enumerated() {
                let dur = s.t[run.hi] - s.t[run.lo]
                let interior = k > 0 && k < r.count - 1
                let peak = (run.lo...run.hi).map { speed[$0] }.max() ?? 0
                let bad: Bool
                if run.air {
                    bad = (interior && dur < o.minimumFlightSeconds) || peak < o.flightSpeedStaturePerSecond
                } else {
                    bad = interior && dur < o.minimumContactSeconds
                }
                if bad {
                    for i in run.lo...run.hi { airborne[i] = !run.air }
                    changed = true
                    break
                }
            }
            if !changed { break }
        }

        let r = runs(airborne)
        var out: [FootContact] = []
        for (k, run) in r.enumerated() where !run.air {
            let heights = (run.lo...run.hi).map { h[$0] }
            out.append(FootContact(foot: foot,
                                   startRealTime: s.t[run.lo], endRealTime: s.t[run.hi],
                                   isTouchdown: k > 0, precedingFlightFullySeen: k > 1,
                                   isTakeoff: k < r.count - 1,
                                   samples: run.hi - run.lo + 1,
                                   meanHeightStature: heights.reduce(0, +) / Double(heights.count)))
        }
        if out.isEmpty {
            return ([], "the \(foot.rawValue) ankle never came within \(String(format: "%.3f", o.liftHeightStature)) stature of its own floor for \(String(format: "%.0f", 1000 * o.minimumContactSeconds)) ms: no ground contact was found, which usually means the feet were out of frame or the tracker lost them")
        }
        return (out, nil)
    }

    // ---- the whole thing ------------------------------------------------------------------------

    /// Footwork for one shot.
    ///
    /// - Parameters:
    ///   - timeline: the body pass. Only `points2D` and `realTime` are read; the fitted 3-D skeleton
    ///     is deliberately not used, because the axis these metrics live on is the one the fit
    ///     cannot see (see the file header).
    ///   - releaseRealTime: the release, real seconds, on the timeline's clock.
    ///   - setRealTime: the set point, when the body model found one. The stance is read there.
    ///   - feet: the per-shot foot measures from `FootTriangleFit.run`. Nil (the default) leaves the
    ///     foot angle exactly where it was — refused, with the reason naming what would make it real.
    public static func compute(timeline: BodyTimeline,
                               releaseRealTime: Double,
                               setRealTime: Double?,
                               options o: FootworkOptions = FootworkOptions(),
                               feet: FootShotMeasures? = nil) -> FootworkMetrics {
        let frames = timeline.frames.sorted { $0.realTime < $1.realTime }
        guard frames.count >= 5 else {
            return .unavailable("the body pass returned \(frames.count) frames: too few to read footwork from",
                                releaseRealTime: releaseRealTime, shootingSide: o.shootingSide)
        }
        guard let stature = statureImagePixels(frames, o.minimumConfidence2D), stature > 1 else {
            return .unavailable("no frame carried a confident nose *and* a confident ankle, so the shooter's own ruler (the ankle-to-nose image span) has no value and every length here would be in pixels of an unknown body",
                                releaseRealTime: releaseRealTime, shootingSide: o.shootingSide)
        }

        var warnings: [String] = []
        var notes: [String] = []
        let side = o.shootingSide?.lowercased()
        let shootingFoot: FootSide? = side == "left" ? .left : (side == "right" ? .right : nil)

        // ---- contacts -------------------------------------------------------------------------
        var contacts: [FootContact] = []
        var contactsUnavailable: [String: String] = [:]
        for foot in FootSide.allCases {
            let s = series(frames, foot: foot, imageHeight: timeline.imageHeight, o)
            let (c, why) = self.contacts(s, foot: foot, stature: stature, o)
            contacts += c
            if let why { contactsUnavailable[foot.rawValue] = why }
        }
        contacts.sort { $0.startRealTime < $1.startRealTime }

        let onFloorFraction = contacts.reduce(0.0) { $0 + $1.durationSeconds }
            / max(1e-9, 2 * (frames.last!.realTime - frames.first!.realTime))
        if !contacts.isEmpty && onFloorFraction < 0.4 {
            warnings.append(String(format: "only %.0f %% of the window has a foot on the floor, so the floor level the contacts are measured against is itself uncertain; read the pattern, not the millisecond", 100 * onFloorFraction))
        }

        // ---- the lift: the second foot to leave the floor before the release --------------------
        var liftRealTime: Double?
        var liftWhy: String?
        var takeoffs: [FootSide: Double] = [:]
        for foot in FootSide.allCases where contactsUnavailable[foot.rawValue] == nil {
            let before = contacts.filter { $0.foot == foot && $0.endRealTime <= releaseRealTime && $0.isTakeoff }
            if let last = before.max(by: { $0.endRealTime < $1.endRealTime }) { takeoffs[foot] = last.endRealTime }
        }
        if takeoffs.count == 2 {
            liftRealTime = takeoffs.values.max()
        } else if contactsUnavailable.count == 2 {
            liftWhy = contactsUnavailable["left"] ?? contactsUnavailable["right"]
        } else {
            let missing = FootSide.allCases.filter { takeoffs[$0] == nil }.map(\.rawValue).joined(separator: " and ")
            liftWhy = "the \(missing) foot never left the floor before the release inside this window: either the shot did not leave the ground, or the window opened after the take-off"
        }

        // ---- touchdowns before the lift ----------------------------------------------------------
        let cutoff = liftRealTime ?? releaseRealTime
        let landings = contacts.filter { $0.isTouchdown && $0.startRealTime <= cutoff + 1e-9 }
            .sorted { $0.startRealTime < $1.startRealTime }
        let touchdowns = landings.filter(\.precedingFlightFullySeen)
        let edgeLandings = landings.filter { !$0.precedingFlightFullySeen }
        if !edgeLandings.isEmpty {
            notes.append("\(edgeLandings.count) foot landing\(edgeLandings.count == 1 ? "" : "s") at the start of the window \(edgeLandings.count == 1 ? "is" : "are") not counted as a step: the take-off that produced \(edgeLandings.count == 1 ? "it" : "them") happened before the window opened, so there is no way to tell a step into the shot from the shooter walking in")
        }

        let bothFeetRead = contactsUnavailable.isEmpty
        var pattern: FootworkPattern = .unknown
        var patternReason = ""
        var firstFootDown: FootSide?
        var stepSeparation: FootworkValue = .missing(.seconds, "fewer than two touchdowns were seen before the lift")

        if !bothFeetRead {
            let which = contactsUnavailable.keys.sorted().joined(separator: " and ")
            patternReason = "the \(which) foot's contacts could not be read, so the step pattern is not determined: \(contactsUnavailable.values.sorted().joined(separator: "; "))"
        } else if touchdowns.isEmpty {
            pattern = .stationary
            patternReason = "no foot touched down before the lift: both feet were already planted when the window opened. This is a spot-up or a free throw — or the window is too short to contain the step, which for a 1-2 needs roughly 0.6 s before the release."
        } else if touchdowns.count == 1 {
            pattern = .singleStep
            firstFootDown = touchdowns[0].foot
            patternReason = "one touchdown before the lift, on the \(touchdowns[0].foot.rawValue) foot; the other foot did not leave the floor inside the window"
        } else {
            let a = touchdowns[0], b = touchdowns[1]
            let gap = b.startRealTime - a.startRealTime
            firstFootDown = a.foot
            stepSeparation = .ok(gap, .seconds, "second touchdown − first, from the ankle-row contact intervals")
            if a.foot == b.foot {
                pattern = .unknown
                patternReason = String(format: "the first two touchdowns are both on the %@ foot, %.0f ms apart: that is a bounce in the contact detector, not a step pattern", a.foot.rawValue, 1000 * gap)
            } else if gap <= o.hopSimultaneitySeconds {
                pattern = .hop
                patternReason = String(format: "both feet touched down within %.0f ms of each other (%@ first): a hop", 1000 * gap, a.foot.rawValue)
            } else {
                pattern = .oneTwo
                patternReason = String(format: "%@ foot down, then %@ %.0f ms later: a 1-2", a.foot.rawValue, b.foot.rawValue, 1000 * gap)
            }
        }

        var firstIsShooting: Bool?
        var firstWhy: String?
        if let f = firstFootDown, let sf = shootingFoot { firstIsShooting = (f == sf) }
        else if firstFootDown == nil { firstWhy = patternReason }
        else { firstWhy = "the shooting side is not known for this shot, so 'shooting-side foot first' cannot be decided" }

        let lastPlant = touchdowns.last?.startRealTime
        let gather: FootworkValue = {
            guard let p = lastPlant else {
                return .missing(.seconds, pattern == .stationary
                    ? "there is no gather to time: no foot touched down before this shot, so there is no plant to measure from. Use the take-off-to-release time instead."
                    : "no touchdown was found before the lift")
            }
            return .ok(releaseRealTime - p, .seconds, "release − the last touchdown before the lift, from the ankle-row contact intervals")
        }()
        let liftToRelease: FootworkValue = liftRealTime.map {
            .ok(releaseRealTime - $0, .seconds, "release − the take-off of the second foot to leave the floor")
        } ?? .missing(.seconds, liftWhy ?? "no take-off was found")

        // ---- the view ---------------------------------------------------------------------------
        let stanceTime = setRealTime ?? liftRealTime ?? releaseRealTime
        let near = frames.filter { abs($0.realTime - stanceTime) <= 0.15 }
        let window = near.isEmpty ? [frames.min(by: { abs($0.realTime - stanceTime) < abs($1.realTime - stanceTime) })!] : near

        func spanU(_ a: String, _ b: String, _ fs: [BodyFrame]) -> [Double] {
            fs.compactMap { f in
                guard let pa = f.points2D[a], pa.confidence >= o.minimumConfidence2D,
                      let pb = f.points2D[b], pb.confidence >= o.minimumConfidence2D else { return nil }
                return abs(pa.u - pb.u) / stature
            }
        }
        let hipSpans = spanU(Body2DPoint.leftHip, Body2DPoint.rightHip, window)
        let expectedHipSpan = o.biiliacFractionOfHeight / o.ankleToNoseFractionOfHeight
        var frontal: FootworkValue = .missing(.ratio, "neither hip was confident around the set, so the camera's angle to the shooter could not be measured")
        var azimuth: FootworkValue = .missing(.radians, "neither hip was confident around the set, so the camera's angle to the shooter could not be measured")
        var f: Double?
        // The spread of the hip span across the set window is this measurement's own error bar, so
        // carry it: the question is never "how noisy is the span" but "is it noisy enough to move
        // the view across the threshold that decides what is measurable".
        var widthObservable = false
        var staggerObservable = false
        var ambiguousViewReason: String?
        if let m = fwMedian(hipSpans), let mad = fwMedian(hipSpans.map { abs($0 - m) }) {
            let value = min(1.0, m / expectedHipSpan)
            let lo = max(0.0, (m - 2 * mad) / expectedHipSpan)
            let hi = min(1.0, (m + 2 * mad) / expectedHipSpan)
            widthObservable = lo >= o.frontalProjectionForWidth
            staggerObservable = sqrt(max(0, 1 - hi * hi)) >= o.sideProjectionForDepth
            if widthObservable || staggerObservable {
                f = value
                frontal = .ok(value, .ratio, String(format: "the hip line's image span at the set (%.3f ± %.3f stature, median ± MAD over ±0.15 s) against Winter's biiliac breadth (%.3f H ÷ %.3f H of stature = %.3f): |cos θ| of the camera's ground-plane angle to the shooter's facing direction",
                                                    m, mad, o.biiliacFractionOfHeight, o.ankleToNoseFractionOfHeight, expectedHipSpan))
                azimuth = .ok(acos(max(-1, min(1, value))), .radians, "acos of the hip line's foreshortening; unsigned — a hip line cannot tell a camera in front from one behind")
            } else {
                let loDeg = Angle.degrees(acos(min(1, hi))), hiDeg = Angle.degrees(acos(min(1, lo)))
                ambiguousViewReason = hiDeg - loDeg < 10
                    ? String(format: "this camera is %.0f° off the shooter's facing direction. At that angle one image-horizontal number mixes the feet's side-to-side separation and their front-back stagger in comparable measure, and no single camera can split the two. Film square from the front for width, square from the side for stagger.", (loDeg + hiDeg) / 2)
                    : String(format: "the hip line's image span at the set is %.3f ± %.3f stature, which puts the camera anywhere from %.0f° to %.0f° off the shooter's facing direction — neither reliably square in front (where stance width is measurable) nor reliably square to the side (where stagger is). A hip point that jumps like this makes a side view look frontal, so every number that needs de-projecting is refused on this shot.",
                              m, mad, loDeg, hiDeg)
                frontal = .missing(.ratio, ambiguousViewReason!)
                azimuth = .missing(.radians, ambiguousViewReason!)
            }
        }
        let sideProjection = f.map { sqrt(max(0, 1 - $0 * $0)) }

        // ---- the rim's bearing in the image --------------------------------------------------------
        var rimSign: Double?
        var rimWhy: String?
        if let s = o.rimBearingSign, s != 0 {
            rimSign = s > 0 ? 1 : -1
            notes.append("the rim's bearing is taken as camera-\(s > 0 ? "right" : "left") from the export's own body-frame x axis, not from a rim column measured on this clip")
        } else if let rimU = o.rimImageU {
            let shooterU = fwMedian(window.compactMap { f -> Double? in
                guard let l = f.points2D[Body2DPoint.leftHip], let r = f.points2D[Body2DPoint.rightHip],
                      l.confidence >= o.minimumConfidence2D, r.confidence >= o.minimumConfidence2D else { return nil }
                return (l.u + r.u) / 2
            })
            if let su = shooterU {
                let offset = (rimU - su) / stature
                if abs(offset) >= o.minimumRimOffsetStature { rimSign = offset > 0 ? 1 : -1 }
                else { rimWhy = String(format: "the rim's image column sits only %.2f stature from the shooter's own: the image horizontal does not point at the rim on this view, so no number here can be signed 'toward the rim'", abs(offset)) }
            } else {
                rimWhy = "no confident hip pair around the set, so the shooter's own image column is unknown and the rim's bearing cannot be taken against it"
            }
        } else {
            rimWhy = "no rim image column was supplied for this shot, so 'toward the rim' has no direction; the numbers here are signed camera-right instead"
        }

        // ---- the stance ------------------------------------------------------------------------
        let ankleSpans = spanU(Body2DPoint.leftAnkle, Body2DPoint.rightAnkle, window)
        var separation: FootworkValue = .missing(.ratio, "neither ankle was confident around the set")
        var width: FootworkValue = .missing(.ratio, "the ankles' separation at the set was not measured")
        var stagger: FootworkValue = .missing(.ratio, "the ankles' separation at the set was not measured")
        if let sep = fwMedian(ankleSpans) {
            separation = .ok(sep, .ratio, "median |Δu| between the ankles over ±0.15 s of the set, ÷ the ankle-to-nose image span")
            // Read the separation against its own per-frame noise before believing it. Two ankles a
            // couple of pixels apart on a near-side view are as likely to be one ankle the detector
            // could not separate from the other as they are to be a square stance.
            var diffs: [Double] = []
            for i in 1..<max(1, ankleSpans.count) { diffs.append(abs(ankleSpans[i] - ankleSpans[i - 1])) }
            if let jit = fwMedian(diffs).map({ $0 / 2.0.squareRoot() }), jit > 0, sep < 5 * jit {
                warnings.append(String(format: "the ankles sit %.3f stature apart in the image against %.3f stature of per-frame noise on that separation (%.1f×): on a near-side view the far ankle is partly hidden behind the near one, so this reads as a square stance whether or not it is one. Confirm it from the front before acting on it.", sep, jit, sep / jit))
            }
        }
        if let sep = fwMedian(ankleSpans) {
            if let f {
                if widthObservable {
                    width = .ok(sep / f, .ratio, String(format: "the ankles' image separation ÷ |cos θ| (%.2f): a near-frontal view, so the image horizontal carries the side-to-side axis", f))
                    notes.append("stance width is de-projected by |cos θ|; any front-back stagger still leaks into it by tan θ × its own size, which at this view is at most \(String(format: "%.0f %%", 100 * sqrt(max(0, 1 - f * f)) / f)) of the stagger")
                    stagger = .missing(.ratio, String(format: "this camera is %.0f° off the shooter's facing direction — near-frontal — so the feet's front-back offset lies along the camera's depth axis, which one camera cannot measure. Film from the side for stagger.", Angle.degrees(acos(f))))
                } else if staggerObservable, let sp = sideProjection {
                    var v = sep / sp
                    var prov = String(format: "the ankles' image separation ÷ |sin θ| (%.2f): a near-side view, so the image horizontal carries the front-back axis", sp)
                    if let rs = rimSign, let sf = shootingFoot {
                        // + when the shooting-side foot is the one nearer the rim.
                        let uL = fwMedian(window.compactMap { $0.points2D[Body2DPoint.leftAnkle].flatMap { p in p.confidence >= o.minimumConfidence2D ? p.u : nil } })
                        let uR = fwMedian(window.compactMap { $0.points2D[Body2DPoint.rightAnkle].flatMap { p in p.confidence >= o.minimumConfidence2D ? p.u : nil } })
                        if let uL, let uR {
                            let shootingU = sf == .left ? uL : uR, otherU = sf == .left ? uR : uL
                            v = rs * (shootingU - otherU) / stature / sp
                            prov += "; + = the shooting-side (\(sf.rawValue)) foot is the one nearer the rim"
                        }
                    } else {
                        prov += "; unsigned — " + (rimWhy ?? "no rim bearing")
                    }
                    stagger = .ok(v, .ratio, prov)
                    width = .missing(.ratio, String(format: "this camera is %.0f° off the shooter's facing direction — near-side — so the feet's side-to-side separation lies along the camera's depth axis, which one camera cannot measure. Film from in front for stance width.", Angle.degrees(acos(f))))
                } else {
                    let why = ambiguousViewReason ?? String(format: "this camera is %.0f° off the shooter's facing direction, which separates neither the feet's side-to-side separation nor their front-back stagger from the camera's depth axis", Angle.degrees(acos(f)))
                    width = .missing(.ratio, why); stagger = .missing(.ratio, why)
                }
            } else {
                let why = ambiguousViewReason
                    ?? "neither hip was confident around the set, so the camera's angle to the shooter was not measured and the image separation cannot be attributed to width or to stagger"
                width = .missing(.ratio, why); stagger = .missing(.ratio, why)
            }
        }

        // ---- drift and travel --------------------------------------------------------------------
        func midHip(_ fr: BodyFrame) -> SIMD2<Double>? {
            guard let l = fr.points2D[Body2DPoint.leftHip], l.confidence >= o.minimumConfidence2D,
                  let r = fr.points2D[Body2DPoint.rightHip], r.confidence >= o.minimumConfidence2D else { return nil }
            return SIMD2((l.u + r.u) / 2, (l.v + r.v) / 2)
        }
        /// The mid-hip at one instant. Refused outright when no frame within `hipMatchToleranceSeconds`
        /// of it carried both hips: an earlier version fell back to the *nearest* frame at any
        /// distance, which on a shot that lost the hips read a whole second of walking as drift.
        func hipAt(_ t: Double) -> SIMD2<Double>? {
            frames.filter { abs($0.realTime - t) <= o.hipMatchToleranceSeconds && midHip($0) != nil }
                .min { abs($0.realTime - t) < abs($1.realTime - t) }
                .flatMap(midHip)
        }

        let driftFrom = lastPlant ?? setRealTime
        var driftImage: FootworkValue = .missing(.ratio, "no start time for the drift: neither a plant nor a set point was found")
        var driftDelta: Double?
        /// The fastest single-frame mid-hip step inside an interval, stature units per second.
        func fastestHipStep(_ t0: Double, _ t1: Double) -> Double? {
            let seen = frames.filter { $0.realTime >= min(t0, t1) - 1e-9 && $0.realTime <= max(t0, t1) + 1e-9 }
                .compactMap { fr -> (Double, SIMD2<Double>)? in midHip(fr).map { (fr.realTime, $0) } }
            guard seen.count >= 2 else { return nil }
            var worst = 0.0
            for i in 1..<seen.count {
                let dt = seen[i].0 - seen[i - 1].0
                guard dt > 0 else { continue }
                worst = max(worst, abs(seen[i].1.x - seen[i - 1].1.x) / stature / dt)
            }
            return worst
        }
        if let t0 = driftFrom, let a = hipAt(t0), let b = hipAt(releaseRealTime),
           let worst = fastestHipStep(t0, releaseRealTime), worst <= o.maximumHipSpeedStaturePerSecond {
            let d = (rimSign ?? 1) * (b.x - a.x) / stature
            driftDelta = d
            let anchor = lastPlant != nil ? "the last plant" : "the set"
            driftImage = .ok(d, .ratio, "mid-hip Δu from \(anchor) to release ÷ the ankle-to-nose span"
                             + (rimSign != nil ? "; + = toward the rim" : "; + = camera-right (" + (rimWhy ?? "no rim bearing") + ")"))
        } else if let t0 = driftFrom, let worst = fastestHipStep(t0, releaseRealTime),
                  worst > o.maximumHipSpeedStaturePerSecond {
            let why = String(format: "the mid-hip jumps across the image at up to %.1f of the shooter's own height per second between the plant and the release — no hip moves that fast, so the tracker lost it and the drift over this interval is not a measurement", worst)
            driftImage = .missing(.ratio, why)
            warnings.append(why)
        } else if driftFrom != nil {
            driftImage = .missing(.ratio, "no frame within \(String(format: "%.0f", 1000 * o.hipMatchToleranceSeconds)) ms of the plant or of the release carried both hips confidently")
        }

        func deproject(_ d: Double?, frontal wantFrontal: Bool, what: String) -> FootworkValue {
            guard let d else { return .missing(.ratio, "the image displacement it would be de-projected from was not measured") }
            guard let f else {
                return .missing(.ratio, ambiguousViewReason
                    ?? "neither hip was confident around the set, so the camera's angle to the shooter was not measured")
            }
            let p = wantFrontal ? f : (sideProjection ?? 0)
            guard wantFrontal ? widthObservable : staggerObservable else {
                return .missing(.ratio, String(format: "%@ lies along the camera's depth axis on this view (the camera is %.0f° off the shooter's facing direction), and one camera cannot measure depth. Film %@ for it.",
                                               what, Angle.degrees(acos(f)), wantFrontal ? "square from the front" : "square from the side"))
            }
            return .ok(d / p, .ratio, String(format: "the measured image displacement ÷ %@ (%.2f)", wantFrontal ? "|cos θ|" : "|sin θ|", p))
        }

        let driftLateral = deproject(driftDelta, frontal: true, what: "drift across the shot line")
        let driftTowardRim = deproject(driftDelta, frontal: false, what: "drift along the shot line")

        var rise: FootworkValue = .missing(.ratio, liftWhy ?? "no take-off was found, so there is no jump to measure")
        var travelDelta: Double?
        if let lift = liftRealTime, let a = hipAt(lift), let b = hipAt(releaseRealTime) {
            rise = .ok((a.y - b.y) / stature, .ratio, "mid-hip image rows, take-off − release, ÷ the ankle-to-nose span (image rows run downward, so a rise is positive)")
            travelDelta = (rimSign ?? 1) * (b.x - a.x) / stature
        } else if liftRealTime != nil {
            rise = .missing(.ratio, "no frame around the take-off or the release carried both hips confidently")
        }
        let forward = deproject(travelDelta, frontal: false, what: "travel along the shot line")
        let lateralTravel = deproject(travelDelta, frontal: true, what: "travel across the shot line")

        // ---- the ruler ----------------------------------------------------------------------------
        let mps: FootworkValue = {
            guard let h = o.standingHeightMetres, h.isFinite, h > 0.5, h < 2.5 else {
                return .missing(.metres, "no standing height was given for this shooter, so every length here stays in stature units — a ratio of the shooter's own body, which is what the rules actually use")
            }
            return .ok(h * o.ankleToNoseFractionOfHeight, .metres,
                       o.heightIsMeasured
                       ? "the measured standing height × Winter's ankle-to-nose fraction (0.891 H)"
                       : "the **stated** (not measured) standing height × Winter's ankle-to-nose fraction (0.891 H): a typed number, so treat the metres as a label on the ratio")
        }()

        if contactsUnavailable.count == 2 {
            warnings.append("neither foot's ground contacts could be read on this shot, so every step, gather and lift number is refused")
        }

        // ---- the foot angle, real only when a foot detector ran (1.3 Track C) --------------------
        let footAngle: FootworkValue, otherFootAngle: FootworkValue, openness: FootworkValue
        let footAngleNote: String
        var strikes: [FootStrikeEvent] = []
        if let feet {
            footAngleNote = feet.footAngleProvenance
            footAngle = .init(measure: feet.footAngleToRimAtSet, provenance: feet.footAngleProvenance)
            otherFootAngle = .init(measure: feet.otherFootAngleToRimAtSet, provenance: feet.footAngleProvenance)
            openness = .init(measure: feet.stanceOpennessAtSet, provenance: feet.footAngleProvenance)
            if feet.footAngleToRimAtSet.isAvailable {
                notes.append("foot angle at the set: \(feet.footAngleToRimAtSet.describe("%.1f")) ± \(feet.footAnglePixelNoiseSigmaAtSet.describe("%.1f")) propagated from a ±1 px landmark error, with a frame-to-frame spread of \(feet.footAngleSigmaAtSet.describe("%.1f")) over the set window and the foot's own axis \(feet.footPointingPixelsAtSet.describe("%.0f")) long in the image. Read the ± as the propagated one: the frame-to-frame spread is repeatability, not accuracy, and the foot's *size* is a population prior on top of both.")
            }
            if let p = feet.rimBearingParallax.value, Angle.degrees(p) > 15 {
                warnings.append(String(format: "the camera's bearing to the rim and its bearing to the shooter differ by %.0f°, and the foot angle is measured against the first: on this shot that parallax is a real part of the number. Filming with the rim behind the shooter, or supplying the rim's own 3-D position, removes it.", Angle.degrees(p)))
            }
            strikes = feet.strikes
        } else {
            footAngleNote = footAngleWithoutDetectorReason
            footAngle = .missing(.radians, footAngleWithoutDetectorReason)
            otherFootAngle = .missing(.radians, footAngleWithoutDetectorReason)
            openness = .missing(.radians, footAngleWithoutDetectorReason)
        }

        return FootworkMetrics(
            contacts: contacts, contactsUnavailable: contactsUnavailable,
            pattern: pattern, patternReason: patternReason,
            stepCount: bothFeetRead ? .ok(Double(touchdowns.count), .count, "touchdowns seen before the lift")
                                    : .missing(.count, patternReason),
            firstFootDown: firstFootDown,
            firstFootDownIsShootingSide: firstIsShooting,
            firstFootDownUnavailableReason: firstWhy,
            stepSeparationSeconds: stepSeparation,
            liftRealTime: liftRealTime, liftUnavailableReason: liftWhy, lastPlantRealTime: lastPlant,
            gatherSeconds: gather, liftToReleaseSeconds: liftToRelease,
            ankleSeparationImage: separation, stanceWidth: width, stanceStagger: stagger,
            footAngleToRim: footAngle, otherFootAngleToRim: otherFootAngle, stanceOpenness: openness,
            footAngleNote: footAngleNote, footStrikes: strikes,
            hipDriftImage: driftImage, hipDriftLateral: driftLateral, hipDriftTowardRim: driftTowardRim,
            jumpRise: rise, jumpForwardTravel: forward, jumpLateralTravel: lateralTravel,
            viewFrontalProjection: frontal, viewAzimuth: azimuth,
            rimBearingSign: rimSign, rimBearingUnavailableReason: rimWhy,
            setRealTime: setRealTime, releaseRealTime: releaseRealTime,
            statureImagePixels: stature, metresPerStatureUnit: mps,
            framesUsed: frames.count, shootingSide: o.shootingSide,
            warnings: warnings, notes: notes, unavailableReason: nil)
    }
}

// ================================================================================================
// MARK: - "Stepping wrong": the rules, per drill, with their grades
// ================================================================================================

/// One threshold, and what stands behind it. Nothing in the engine compares against a bare number.
public struct FootworkNorm: Sendable, Codable, Equatable {
    public var id: String
    public var value: Double
    public var unit: BodyMeasure.Unit
    public var grade: ShotEvidenceGrade
    public var source: String
    public init(_ id: String, _ value: Double, _ unit: BodyMeasure.Unit, _ grade: ShotEvidenceGrade, _ source: String) {
        self.id = id; self.value = value; self.unit = unit; self.grade = grade; self.source = source
    }
}

/// The thresholds the rules fire on. Every one is graded, and the two that are ArcLab's own guesses
/// say so in their source line rather than hiding behind the others.
public struct FootworkNorms: Sendable, Codable, Equatable {
    public var gatherCeilingSeconds = FootworkNorm(
        "gatherCeiling", 0.35, .seconds, .d,
        "ArcLab's own provisional ceiling (docs/PLAN-1.1-2026-09-15.md, Track C). No measured distribution stands behind it; once ArcLab has 30 of your own off-the-dribble shots it will use your own median instead and this number retires.")
    public var lateralDriftCeilingStature = FootworkNorm(
        "lateralDriftCeiling", 0.10, .ratio, .c,
        "Coaching consensus with a mechanical rationale: lateral travel rotates the shot plane and adds a sideways velocity the release has to cancel. The 0.10-stature figure is ArcLab's, chosen as roughly half a foot length; the *direction* of the claim is what is graded C, not the number.")
    public var forwardTravelCeilingStature = FootworkNorm(
        "forwardTravelCeiling", 0.15, .ratio, .d,
        "ArcLab's own. Travel toward the rim shortens the shot and away lengthens it, which the ball metrics already measure directly as release distance; this threshold only flags when the feet are the cause.")
    public var stanceWidthLowStature = FootworkNorm(
        "stanceWidthLow", 0.20, .ratio, .c,
        "'About shoulder width' in stature units: Winter's biacromial breadth is 0.245 H = 0.275 of the ankle-to-nose span, and the coaching range runs from a little inside shoulder width upward (Physiopedia, Biomechanics of the Basketball Jump Shot).")
    public var stanceWidthHighStature = FootworkNorm(
        "stanceWidthHigh", 0.36, .ratio, .c,
        "The top of the same coaching range, ~1.3× shoulder width, beyond which the knees cannot extend cleanly through the shot.")
    public var staggerTypicalStature = FootworkNorm(
        "staggerTypical", 0.073, .ratio, .b,
        "Measured: jump shooters used a ~12 cm stagger with the shooting-side foot ahead (summarised in Physiopedia from the foot-placement literature); 12 cm on a 1.85 m player is 0.065 H = 0.073 of the ankle-to-nose span. NOTE the counter-evidence: The Sport Journal's NCAA Division I foot-placement study found the staggered stance is not necessary for advanced shooters, so ArcLab reports your stagger and does not tell you to change it.")
    public var hopSimultaneitySeconds = FootworkNorm(
        "hopSimultaneity", 0.06, .seconds, .c,
        "The coaching definition of the hop — 'a really quick 1-2, the inside foot down a fraction of a second before the other' (Dr Dish Basketball, 1-2 vs the Hop). The 60 ms cut is ArcLab's reading of 'a fraction of a second'.")
    public init() {}

    public var all: [FootworkNorm] {
        [gatherCeilingSeconds, lateralDriftCeilingStature, forwardTravelCeilingStature,
         stanceWidthLowStature, stanceWidthHighStature, staggerTypicalStature, hopSimultaneitySeconds]
    }
}

/// The drills the rules know. Handedness enters through `shootingSide`, not through the case.
public enum FootworkDrill: String, Sendable, Codable, CaseIterable {
    /// Spot-up with no step into it: free throws, form shooting, stationary catch.
    case stationaryCatch
    /// Catch on the move and step into it — the 1-2 or the hop.
    case catchAndShoot
    /// Off the dribble, pulling up going toward the shooting hand's side (a right-handed shooter
    /// driving right).
    case pullUpStrongSide
    /// Off the dribble, pulling up going away from the shooting hand (a right-handed shooter
    /// driving left) — the harder one, and the reason this track exists.
    case pullUpWeakSide
    /// Off the dribble, retreating: the step-back.
    case stepBack

    public var title: String {
        switch self {
        case .stationaryCatch: return "Stationary catch"
        case .catchAndShoot: return "Catch and shoot"
        case .pullUpStrongSide: return "Pull-up, strong side"
        case .pullUpWeakSide: return "Pull-up, weak side"
        case .stepBack: return "Step-back"
        }
    }

    /// Step patterns this drill is asking for. Empty means "no expectation".
    public var expectedPatterns: [FootworkPattern] {
        switch self {
        case .stationaryCatch: return [.stationary]
        case .catchAndShoot, .pullUpStrongSide, .pullUpWeakSide: return [.hop, .oneTwo]
        case .stepBack: return [.hop, .oneTwo]
        }
    }

    /// Whether the drill expects a gather off a plant at all.
    public var expectsAPlant: Bool { self != .stationaryCatch }

    /// What the drill is *for*, in one sentence, for the app.
    public var intent: String {
        switch self {
        case .stationaryCatch: return "the same shot every time, with the feet out of the argument"
        case .catchAndShoot: return "arrive on balance and shoot on the catch"
        case .pullUpStrongSide: return "gather off the dribble going to your hand, square by the set"
        case .pullUpWeakSide: return "gather off the dribble going away from your hand without turning the shoulders past the rim"
        case .stepBack: return "create separation backward and still land the shot on the same line"
        }
    }
}

public enum FootworkSeverity: String, Sendable, Codable {
    /// Measured, and inside what the drill asks for.
    case ok
    /// Measured, and outside it, but by an amount the measurement's own noise could explain.
    case watch
    /// Measured, and clearly outside it: this is the "you're stepping wrong" case.
    case fault
    /// Not measured — the reason says what would have to change to measure it.
    case unmeasured
}

public struct FootworkFinding: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    /// One sentence a coach would say out loud.
    public var headline: String
    /// What the number was and what the rule wanted.
    public var detail: String
    public var severity: FootworkSeverity
    public var grade: ShotEvidenceGrade
    public var source: String
    /// True when the claim is coaching folklore ArcLab is repeating rather than evidence. Shown as
    /// such; never silently dropped.
    public var isFolklore: Bool = false
}

public struct FootworkEvaluation: Sendable, Codable, Equatable {
    public var drill: FootworkDrill
    public var shootingSide: String?
    public var findings: [FootworkFinding]
    public var summary: String
    public var norms: [FootworkNorm]

    public var faults: [FootworkFinding] { findings.filter { $0.severity == .fault } }
    public var unmeasured: [FootworkFinding] { findings.filter { $0.severity == .unmeasured } }
}

extension FootworkEvaluation {

    /// Grade the shot's footwork against what the drill asks for.
    ///
    /// Every rule returns a finding, including the ones that could not be checked: a rule that goes
    /// quiet because the camera could not see it looks exactly like a rule that passed, and that is
    /// the failure mode CLAUDE.md rule 1 exists to prevent.
    public static func evaluate(_ m: FootworkMetrics,
                                drill: FootworkDrill,
                                shootingSide: String? = nil,
                                norms: FootworkNorms = FootworkNorms()) -> FootworkEvaluation {
        let side = (shootingSide ?? m.shootingSide)?.lowercased()
        let shootingFoot: FootSide? = side == "left" ? .left : (side == "right" ? .right : nil)
        var out: [FootworkFinding] = []

        func stature(_ v: FootworkValue) -> String {
            v.value.map { String(format: "%.3f stature", $0) } ?? "nil"
        }

        // ---- 1. the pattern the drill asks for ------------------------------------------------
        if m.pattern == .unknown {
            out.append(.init(id: "pattern", headline: "Your step pattern was not readable on this clip.",
                             detail: m.patternReason, severity: .unmeasured, grade: .a,
                             source: "the contact detector's own refusal"))
        } else if drill.expectedPatterns.isEmpty || drill.expectedPatterns.contains(m.pattern) {
            out.append(.init(id: "pattern", headline: "Step pattern matches the drill: \(m.pattern.title).",
                             detail: m.patternReason, severity: .ok, grade: .c,
                             source: "the drill's own definition"))
        } else {
            let want = drill.expectedPatterns.map(\.title).joined(separator: " or ")
            out.append(.init(id: "pattern",
                             headline: m.pattern == .stationary
                                ? "You never stepped into this one — the drill asks for a \(want)."
                                : "That was a \(m.pattern.title); the drill asks for a \(want).",
                             detail: m.patternReason, severity: .fault, grade: .c,
                             source: "the drill's own definition; that a step pattern should match the drill is definitional, not a claim about shooting"))
        }

        // ---- 2. which foot first --------------------------------------------------------------
        if drill.expectsAPlant && m.pattern == .oneTwo {
            if let first = m.firstFootDown, let sf = shootingFoot {
                let correct = (first == sf)
                out.append(.init(id: "firstFoot",
                                 headline: correct
                                    ? "\(first.rawValue.capitalized) foot down first — the shooting-side foot, as taught."
                                    : "\(first.rawValue.capitalized) foot down first; the common teaching is the \(sf.rawValue) — your shooting-side foot — first on a 1-2.",
                                 detail: m.patternReason,
                                 severity: correct ? .ok : .watch, grade: .c,
                                 source: "Coaching consensus (Dr Dish Basketball, 1-2 vs the Hop; Breakthrough Basketball forum): on the 1-2 the inside/shooting-side foot lands first and turns the hips to the rim. No controlled measurement shows the other order shoots worse, so this is a 'watch', never a fault."))
            } else {
                out.append(.init(id: "firstFoot", headline: "Which foot landed first was not established.",
                                 detail: m.firstFootDownUnavailableReason ?? m.patternReason,
                                 severity: .unmeasured, grade: .a, source: "the contact detector's own refusal"))
            }
        }

        // ---- 3. the gather --------------------------------------------------------------------
        if drill.expectsAPlant {
            let n = norms.gatherCeilingSeconds
            if let g = m.gatherSeconds.value {
                let over = g > n.value
                out.append(.init(id: "gather",
                                 headline: over
                                    ? String(format: "Slow gather: %.0f ms from the plant to the release.", 1000 * g)
                                    : String(format: "Gather %.0f ms — quick enough for this drill.", 1000 * g),
                                 detail: String(format: "the ceiling this fires on is %.0f ms, and it is ArcLab's own guess", 1000 * n.value),
                                 severity: over ? .watch : .ok, grade: n.grade, source: n.source))
            } else {
                out.append(.init(id: "gather", headline: "No gather to time on this shot.",
                                 detail: m.gatherSeconds.unavailableReason ?? "not measured",
                                 severity: .unmeasured, grade: .a, source: "the contact detector's own refusal"))
            }
        }

        // ---- 4. lateral drift -------------------------------------------------------------------
        let dn = norms.lateralDriftCeilingStature
        if let d = m.hipDriftLateral.value {
            let over = abs(d) > dn.value
            out.append(.init(id: "lateralDrift",
                             headline: over ? String(format: "You drift %.2f of your own height sideways into the shot.", abs(d))
                                            : "Hips stay on their line into the release.",
                             detail: "measured \(stature(m.hipDriftLateral)) across the shot line; the ceiling is \(String(format: "%.2f", dn.value))",
                             severity: over ? .fault : .ok, grade: dn.grade, source: dn.source))
        } else {
            out.append(.init(id: "lateralDrift", headline: "Sideways drift is not measurable from this camera position.",
                             detail: m.hipDriftLateral.unavailableReason ?? "not measured",
                             severity: .unmeasured, grade: .a, source: "single-camera geometry"))
        }

        // ---- 5. travel along the shot line -------------------------------------------------------
        let fn = norms.forwardTravelCeilingStature
        if let t = m.jumpForwardTravel.value {
            let over = abs(t) > fn.value
            out.append(.init(id: "forwardTravel",
                             headline: over
                                ? String(format: "You %@ %.2f of your own height on the jump.", t > 0 ? "drift into the rim by" : "fade away by", abs(t))
                                : "You go up, not forward or back.",
                             detail: "measured \(stature(m.jumpForwardTravel)) along the shot line, take-off to release; the ceiling is \(String(format: "%.2f", fn.value))",
                             severity: over ? .watch : .ok, grade: fn.grade, source: fn.source))
        } else {
            out.append(.init(id: "forwardTravel", headline: "Travel toward or away from the rim is not measurable from this camera position.",
                             detail: m.jumpForwardTravel.unavailableReason ?? "not measured",
                             severity: .unmeasured, grade: .a, source: "single-camera geometry"))
        }

        // ---- 6. stance width ----------------------------------------------------------------------
        if let w = m.stanceWidth.value {
            let lo = norms.stanceWidthLowStature.value, hi = norms.stanceWidthHighStature.value
            let inside = w >= lo && w <= hi
            out.append(.init(id: "stanceWidth",
                             headline: inside ? "Base is about shoulder width."
                                              : (w < lo ? "Narrow base." : "Wide base."),
                             detail: "measured \(stature(m.stanceWidth)); the coaching range is \(String(format: "%.2f–%.2f", lo, hi)) stature (shoulder width is 0.275)",
                             severity: inside ? .ok : .watch, grade: norms.stanceWidthLowStature.grade,
                             source: norms.stanceWidthLowStature.source))
        } else {
            out.append(.init(id: "stanceWidth", headline: "Stance width is not measurable from this camera position.",
                             detail: m.stanceWidth.unavailableReason ?? "not measured",
                             severity: .unmeasured, grade: .a, source: "single-camera geometry"))
        }

        // ---- 7. stagger ---------------------------------------------------------------------------
        let sn = norms.staggerTypicalStature
        if let s = m.stanceStagger.value {
            out.append(.init(id: "stagger",
                             headline: s >= 0 ? String(format: "Shooting-side foot %.2f of your height ahead.", abs(s))
                                              : String(format: "Off foot %.2f of your height ahead.", abs(s)),
                             detail: "the measured reference is \(String(format: "%.3f", sn.value)) stature with the shooting-side foot ahead. ArcLab reports this and does not ask you to change it — see the source.",
                             severity: .ok, grade: sn.grade, source: sn.source))
        } else {
            out.append(.init(id: "stagger", headline: "Stagger is not measurable from this camera position.",
                             detail: m.stanceStagger.unavailableReason ?? "not measured",
                             severity: .unmeasured, grade: .a, source: "single-camera geometry"))
        }

        // ---- 8. the foot angle rule — folklore, stated as folklore ---------------------------------
        out.append(.init(id: "footAngle",
                         headline: "Whether your feet point at the rim: ArcLab cannot see it, on any camera it ships with.",
                         detail: FootworkMetrics.footAngleAlwaysUnavailable
                            + " The rule it would test — 'turn both feet to the rim', or its opposite, the 'ten-and-two' turned stance — is coaching folklore on both sides: shooters at every level do both and no measurement separates them.",
                         severity: .unmeasured, grade: .d,
                         source: "opinion on both sides of the claim; listed so you know ArcLab is not quietly ignoring it",
                         isFolklore: true))

        let faults = out.filter { $0.severity == .fault }
        let unmeasured = out.filter { $0.severity == .unmeasured }
        let summary: String
        if !faults.isEmpty {
            summary = faults.map(\.headline).joined(separator: " ")
        } else if out.contains(where: { $0.severity == .watch }) {
            summary = out.first { $0.severity == .watch }!.headline
        } else if unmeasured.count >= out.count - 1 {
            summary = "This camera position carried almost none of the footwork rules. \(unmeasured.count) of \(out.count) could not be checked."
        } else {
            summary = "Footwork is doing what the drill asks."
        }
        return FootworkEvaluation(drill: drill, shootingSide: shootingSide ?? m.shootingSide,
                                  findings: out, summary: summary, norms: norms.all)
    }
}
