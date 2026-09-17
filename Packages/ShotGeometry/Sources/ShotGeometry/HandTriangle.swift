import Foundation
import simd

// ================================================================================================
// MARK: - The hand as a rigid triangle (1.3, 2026-09-16)
// ================================================================================================
//
// Vision's hand pose gives 21 landmarks **in the image only** — there is no depth in it — so until
// now the hand reached the app as 2-D and was drawn flat (SceneBody.swift's header says so). This
// file turns three of those landmarks into an oriented 3-D plate:
//
//     wrist (back)  ·  index MCP (front, thumb side)  ·  little MCP (front, outer side)
//
// The three are a rigid triangle whose **size is a declared prior**, not a measurement: a single
// camera cannot recover the size of a 40-pixel hand. The triangle is attached at the wrist the
// skeleton fit already solved for, and only its *orientation* is fitted, from the two knuckles'
// own view rays. Each knuckle then lies where its ray meets a sphere of the prior's radius about
// the fitted wrist — a construction, and everything derived from it inherits that provenance.
//
// What that buys, and what it does not:
//   · buys — palm normal (which way the palm faces), pointing direction (wrist → mid-knuckle) and
//     roll, per frame; at the release, the palm's angle to the rim bearing and to vertical, the
//     wrist's flexion against the forearm, and the guide hand's contact plane.
//   · does not buy — hand *size*, finger joint angles in 3-D, or any depth the two knuckles do not
//     separate. With only one knuckle confident the roll is refused, not guessed.
//
// Radians in code, degrees at the boundary (CLAUDE.md rule 4). Foundation + simd only (rule 2).
// Every number is a `BodyMeasure`: a value, or nil with a reason (rule 1).
//
// Frames of reference. Positions here are **camera space in Vision's convention** — +x right,
// +y up, +z toward the camera — the same as `BodyJoint3D.cameraPosition`, because that is what the
// skeleton fit writes and what the export reads. The pinhole algebra (rays, projection) runs in the
// +y down, +z away convention, and `pinhole(_:)` / `visionCamera(_:)` (the same map, its own
// inverse) are the only two places the two meet.

// MARK: - The size prior

/// Where the hand's size comes from. It is a population figure, declared as one everywhere it is
/// used: in `HandTriangleTrack.prior`, in the exported record and in the viewer's legend.
///
/// **Hand breadth across the metacarpals (index MCP ↔ little MCP) ≈ 0.048–0.050 × stature.**
///   · Pheasant, *Bodyspace: Anthropometry, Ergonomics and the Design of Work*, 2nd ed., Table 2
///     (British adults 19–65): hand breadth at the metacarpals, 50th percentile, male 87 mm against
///     a stature of 1740 mm (0.0500 H), female 76 mm against 1610 mm (0.0472 H).
///   · NASA RP-1024, *Anthropometric Source Book* vol. II (1978), USAF male survey: hand breadth
///     90 mm against a stature of 1755 mm (0.0513 H).
/// 0.049 is the middle of that, and the spread (±2 %) is smaller than this fit's own reprojection
/// noise on a 40-pixel hand, which is why one fraction is used rather than a per-shooter number.
///
/// **Palm length (wrist crease → the MCP row) ≈ 0.058 × stature.** Hand length (wrist crease to the
/// tip of the middle finger) is 0.108 H in Drillis & Contini's segment table — the one Winter,
/// *Biomechanics and Motor Control of Human Movement*, reproduces — and the palm is 0.53–0.56 of
/// hand length in Pheasant's Table 2 (male 189 mm hand, 107 mm palm = 0.566; female 174 / 95 =
/// 0.546). 0.108 × 0.54 = 0.058 H.
///
/// The triangle is taken as **isoceles** about the wrist: the index and little MCPs are the same
/// distance from the wrist crease. They are not, quite (the index MCP sits a few millimetres
/// further out), but the difference is under 4 % of the palm length and far inside what two view
/// rays through a 40-pixel hand can separate. The simplification is part of the prior and is said
/// in `note`.
public struct HandSizePrior: Sendable, Codable, Equatable {
    /// Index MCP ↔ little MCP, in the caller's length unit.
    public var breadth: Double
    /// Wrist → the midpoint of the two MCPs, same unit.
    public var palmLength: Double
    /// Wrist → either MCP, same unit. `hypot(palmLength, breadth/2)` by the isoceles construction.
    public var wristToMCP: Double
    /// The stature the two lengths were taken from, same unit, and where that stature came from.
    public var stature: Double
    public var statureProvenance: String
    public var breadthFractionOfStature: Double
    public var palmLengthFractionOfStature: Double
    /// Always true. The field exists so a reader of the file never has to know this comment.
    public var isPopulationPrior: Bool { true }
    public var note: String

    public static let breadthFraction = 0.049
    public static let breadthFractionRange = 0.048...0.050
    public static let palmLengthFraction = 0.058

    public init(stature: Double, statureProvenance: String,
                breadthFraction: Double = HandSizePrior.breadthFraction,
                palmLengthFraction: Double = HandSizePrior.palmLengthFraction) {
        self.stature = stature
        self.statureProvenance = statureProvenance
        self.breadthFractionOfStature = breadthFraction
        self.palmLengthFractionOfStature = palmLengthFraction
        self.breadth = stature * breadthFraction
        self.palmLength = stature * palmLengthFraction
        self.wristToMCP = (pow(stature * palmLengthFraction, 2) + pow(stature * breadthFraction / 2, 2)).squareRoot()
        self.note = String(format:
            "the hand's size is a **population prior**, not a measurement: breadth across the metacarpals %.3f × stature (Pheasant, Bodyspace 2nd ed. Table 2: 87 mm / 1740 mm male, 76 mm / 1610 mm female; NASA RP-1024 vol. II: 90 mm / 1755 mm — the range is %.3f–%.3f H) and palm length %.3f × stature (hand length 0.108 H, Drillis & Contini via Winter, × the 0.54 palm fraction of Pheasant Table 2), taken as an isoceles triangle about the wrist. Stature here is %@. A single camera cannot measure a 40-pixel hand, so its size is borrowed and its orientation alone is fitted.",
            breadthFraction, HandSizePrior.breadthFractionRange.lowerBound, HandSizePrior.breadthFractionRange.upperBound,
            palmLengthFraction, statureProvenance)
    }
}

// MARK: - Pinhole ↔ Vision camera space

@inlinable public func pinhole(_ cameraSpace: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(cameraSpace.x, -cameraSpace.y, -cameraSpace.z)
}
/// The same map. It is its own inverse, which is why there is one function and not two.
@inlinable public func visionCamera(_ pinholePoint: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(pinholePoint.x, -pinholePoint.y, -pinholePoint.z)
}

// MARK: - One frame of one hand

/// The fitted plate on one frame. Positions are camera space (Vision's convention) in the fit's
/// own length unit; directions are unit vectors in the same frame.
public struct HandTriangleFrame: Sendable, Codable, Equatable {
    public var realTime: Double
    public var frameIndex: Int
    /// "left" / "right" — the shooter's own side.
    public var side: String
    /// "shooting" / "guide", or nil when nothing said which.
    public var role: String?

    public var wrist: SIMD3<Double>
    public var indexMCP: SIMD3<Double>?
    public var littleMCP: SIMD3<Double>?

    /// Out of the palm: the side the ball sits on. Nil whenever fewer than three points were confident.
    public var palmNormal: SIMD3<Double>?
    /// Wrist → the midpoint of the two MCPs. With one MCP it is wrist → that MCP and `notes` says so.
    public var pointing: SIMD3<Double>?
    /// Rotation of the palm normal about `pointing`, measured from the upward reference (the part of
    /// camera-up perpendicular to `pointing`), positive by the right-hand rule about `pointing`.
    /// 0 = palm up, ±π = palm down, +π/2 = palm toward the shooter's own left in the image.
    public var roll: BodyMeasure
    /// RMS distance, in pixels, between the two constructed knuckles' reprojections and the
    /// landmarks they were built from. Small by construction along the ray; it is the *breadth*
    /// residual that is informative, so `breadthResidual` carries that separately.
    public var reprojectionPixels: BodyMeasure
    /// ‖index − little‖ ÷ the prior's breadth − 1. 0 means the two rays and the prior agree.
    public var breadthResidual: BodyMeasure

    /// How many of the three points were confident on this frame (2 or 3; below 2 there is no frame).
    public var pointsUsed: Int
    /// Where the wrist came from: "body pose (fitted skeleton)" or "hand pose".
    public var wristProvenance: String
    /// Non-nil when a vertex was carried across one sampled frame rather than observed.
    public var interpolatedPoints: [String]
    /// Non-nil when a knuckle's ray missed the prior's sphere and was taken at its closest approach.
    public var clampedPoints: [String]

    public init(realTime: Double, frameIndex: Int, side: String, role: String?, wrist: SIMD3<Double>,
                indexMCP: SIMD3<Double>?, littleMCP: SIMD3<Double>?, palmNormal: SIMD3<Double>?,
                pointing: SIMD3<Double>?, roll: BodyMeasure, reprojectionPixels: BodyMeasure,
                breadthResidual: BodyMeasure, pointsUsed: Int, wristProvenance: String,
                interpolatedPoints: [String] = [], clampedPoints: [String] = []) {
        self.realTime = realTime; self.frameIndex = frameIndex; self.side = side; self.role = role
        self.wrist = wrist; self.indexMCP = indexMCP; self.littleMCP = littleMCP
        self.palmNormal = palmNormal; self.pointing = pointing; self.roll = roll
        self.reprojectionPixels = reprojectionPixels; self.breadthResidual = breadthResidual
        self.pointsUsed = pointsUsed; self.wristProvenance = wristProvenance
        self.interpolatedPoints = interpolatedPoints; self.clampedPoints = clampedPoints
    }
}

/// One hand over the window.
public struct HandTriangleTrack: Sendable, Codable, Equatable {
    public var side: String
    public var role: String?
    public var prior: HandSizePrior
    public var frames: [HandTriangleFrame]
    /// Analysed frames in the window, so a rate can be read off `frames.count`.
    public var framesInWindow: Int
    public var unavailableReason: String?
    public var notes: [String]

    public var framesWithOrientation: Int { frames.filter { $0.pointsUsed >= 3 }.count }

    public func nearest(_ t: Double, within tolerance: Double) -> HandTriangleFrame? {
        guard let f = frames.min(by: { abs($0.realTime - t) < abs($1.realTime - t) }),
              abs(f.realTime - t) <= tolerance else { return nil }
        return f
    }
}

// MARK: - Per-shot measures

/// What the plates say about one shot. Every field is a value or a reason.
public struct HandShotMeasures: Sendable, Codable, Equatable {
    /// Angle between the shooting palm's normal and the rim bearing at release. 0 = the palm faces
    /// the rim square. Only the rim's *bearing* is known on a single view, never its depth, so this
    /// is an angle in the camera's horizontal plane extended by the palm's own vertical component —
    /// the provenance says so.
    public var palmToRimBearingAtRelease: BodyMeasure
    /// Angle between the shooting palm's normal and vertical (camera up). 0 = palm straight up.
    public var palmToVerticalAtRelease: BodyMeasure
    /// Angle between the hand's pointing direction and vertical at release.
    public var pointingToVerticalAtRelease: BodyMeasure
    /// Roll of the shooting palm at release.
    public var rollAtRelease: BodyMeasure
    /// Forearm (elbow → wrist) against the hand's pointing direction at release. + = flexion (the
    /// hand bends toward the palm), − = extension (it bends back). 0 = hand in line with the forearm.
    public var wristFlexionAtRelease: BodyMeasure
    /// The same angle `throughReleaseSeconds` after the release minus its value that far before it —
    /// the snap. + = the wrist flexed through the release.
    public var wristFlexionChangeThroughRelease: BodyMeasure
    /// Minimum and maximum of the flexion angle over the same span, and how many frames carried it.
    public var wristFlexionRangeThroughRelease: BodyMeasure
    public var wristFlexionFramesThroughRelease: Int
    /// The guide hand's palm normal at the last frame it touched the ball, as an angle to the shot's
    /// own plane normal — "how square the guide hand's contact plane was". Needs the ball track.
    public var guideContactPlaneToShotPlane: BodyMeasure
    /// Angle of the guide palm normal to vertical at that same frame.
    public var guideContactPlaneToVertical: BodyMeasure
    /// Real time of that last contact, or the reason there is none.
    public var guideLastContactRealTime: BodyMeasure
    public var notes: [String]

    public static func unavailable(_ why: String) -> HandShotMeasures {
        HandShotMeasures(
            palmToRimBearingAtRelease: .missing(.radians, why), palmToVerticalAtRelease: .missing(.radians, why),
            pointingToVerticalAtRelease: .missing(.radians, why), rollAtRelease: .missing(.radians, why),
            wristFlexionAtRelease: .missing(.radians, why), wristFlexionChangeThroughRelease: .missing(.radians, why),
            wristFlexionRangeThroughRelease: .missing(.radians, why), wristFlexionFramesThroughRelease: 0,
            guideContactPlaneToShotPlane: .missing(.radians, why), guideContactPlaneToVertical: .missing(.radians, why),
            guideLastContactRealTime: .missing(.seconds, why), notes: [])
    }
}

public struct HandTriangleResult: Sendable {
    /// The input timeline with the fitted knuckles added to `joints3D` (and nothing else changed).
    public var timeline: BodyTimeline
    public var tracks: [HandTriangleTrack]
    public var measures: HandShotMeasures
    public var notes: [String]
    public var warnings: [String]
}

// MARK: - Options

public struct HandTriangleOptions: Sendable {
    public var intrinsics: CameraIntrinsics
    /// Vision's hand-landmark confidences run far lower than its body-pose ones on a hand this small:
    /// measured over 1351 hand observations in the 37-shot free-throw session the median confidence
    /// is 0.31 at the wrist, 0.50 at the index MCP and 0.50 at the little MCP, so the body's 0.3 floor
    /// would throw away half of every hand. 0.2 is the floor used here, and it is a different number
    /// from `BodySkeletonOptions.minimumConfidence2D` on purpose.
    public var minimumHandLandmarkConfidence: Double = 0.20
    /// The body-pose floor, for the fitted wrist and the forearm.
    public var minimumConfidence2D: Double = 0.30
    /// How far apart the two knuckles must be **in the image** before the plate's transverse
    /// direction is a measurement at all. Below it the view is looking down the hand's own width and
    /// the plate is refused outright — corners and orientation — rather than fitted to noise.
    ///
    /// 6 px, and that is the project's own keypoint noise floor, not a guess: Vision's 2-D joints
    /// agree with an independent MediaPipe pose to a median of 4–7 px (PHASE2-PREP, "Body model,
    /// iteration 2") and `BodySkeletonOptions.huberPixels` is set at 12 px for the same reason.
    /// Measured: on the 37-shot phone session the two MCPs are 12 px apart at the median (0.029 ×
    /// stature) and most plates clear it; on the 240 fps clip, where the shooter is 351 px tall and
    /// the whole hand is ~17 px across, they are **3.9 px** apart (0.011 × stature) and almost none
    /// do — which is the honest answer for that view, and is why the breadth residual there was
    /// −73 % before this gate existed.
    public var minimumKnuckleSeparationPx: Double = 6
    /// A knuckle ray that misses the prior's sphere by no more than this fraction of the radius is
    /// taken at its closest approach to the wrist instead — the prior and the fitted wrist's depth
    /// disagree by that much and the closest approach is the least the pair can be wrong by. Beyond
    /// it the knuckle is refused. Every clamped point is named in `HandTriangleFrame.clampedPoints`.
    public var rayMissTolerance: Double = 0.35
    /// Put the plate's apex on the **hand detector's own wrist landmark**, at the fitted wrist's
    /// depth, instead of at the fitted wrist itself. The two detectors do not mark the same point:
    /// measured over 1349 hand observations in the 37-shot free-throw session the hand pose's wrist
    /// sits 0.025 × stature from the body pose's — 43 % of the prior's own palm length — so hanging a
    /// triangle built from hand landmarks on the *body* wrist bends it before it starts. Depth still
    /// comes from the skeleton (it is the only thing that has any), and the image position from the
    /// detector that measured the knuckles, so the plate is internally consistent. Off falls back to
    /// the fitted wrist exactly, and every frame records which it used.
    ///
    /// **Off by default, on measurement.** The argument above is a good one and the pixels refuse it:
    /// over the same 37 shots, moving the apex onto the hand pose's wrist took the plate's
    /// reprojection RMS from 4.35 px to 5.67 px, the breadth residual from −18 % to −27 %, and the
    /// wrist-flexion range through the release from 105° to 175° — i.e. the plate got noisier, not
    /// truer. The likely reason is that the hand-pose wrist landmark is itself the least confident of
    /// the 21 (measured p50 0.31 against 0.50 at the MCPs), so it brings more noise than offset it
    /// removes. The option stays because the measurement is worth keeping reproducible.
    public var apexFromHandPoseWrist = false
    /// The shooter's stature in the timeline's own length unit, for the size prior. Nil refuses every
    /// triangle rather than inventing a hand.
    public var stature: Double?
    public var statureProvenance: String = "the fitted skeleton's own 90th-percentile ankle-to-nose span ÷ 0.891"
    /// Release ± this many real seconds is the span the flexion change is read over.
    public var throughReleaseSeconds: Double = 0.08
    /// A track sample counts as "at" an instant within this many real seconds of it.
    public var instantToleranceSeconds: Double = 0.02
    /// The rim's image column, when known. Without it the palm-to-rim angle is refused.
    public var rimImageU: Double?
    /// The ball track on the real clock, for the guide hand's last contact. Empty refuses it.
    public var ballTrack: [BodyBallSample] = []
    /// A guide-hand landmark within this many ball radii of the ball centre is touching it — the same
    /// rule and the same default `BodyKinematicsOptions.fingertipContactRadii` uses for fingertips.
    public var contactRadii: Double = 1.0
    public var shootingSide: String?
    public init(intrinsics: CameraIntrinsics) { self.intrinsics = intrinsics }
}

// MARK: - The fit

public enum HandTriangleFit {

    /// Depths at which the ray `s·direction` (from the camera at the origin, pinhole frame) meets the
    /// sphere of radius `radius` about `centre`. Zero, one or two of them, nearest first. Pure and
    /// tiny on purpose: it is the whole geometric content of "a knuckle is one hand from the wrist".
    public static func rayMeetsSphere(direction d: SIMD3<Double>, centre c: SIMD3<Double>, radius r: Double) -> [Double] {
        let dd = simd_dot(d, d)
        guard dd > 1e-12, r > 0 else { return [] }
        let b = simd_dot(d, c) / dd                      // depth of the closest approach
        let closest = simd_length(b * d - c)
        if closest > r { return [] }
        let half = ((r * r - closest * closest) / dd).squareRoot()
        let s0 = b - half, s1 = b + half
        return [s0, s1].filter { $0 > 1e-6 }.sorted { abs($0 - b) < abs($1 - b) }
    }

    /// The depth of the ray's closest approach to `centre`, and how far it passes — the fallback the
    /// tolerance admits when the prior and the fitted wrist depth disagree.
    public static func closestApproach(direction d: SIMD3<Double>, centre c: SIMD3<Double>) -> (depth: Double, distance: Double) {
        let dd = max(1e-12, simd_dot(d, d))
        let b = simd_dot(d, c) / dd
        return (b, simd_length(b * d - c))
    }

    /// Place one knuckle: where its view ray meets the sphere of the prior's radius about the wrist.
    /// Two solutions in general — one in front of the wrist's depth plane, one behind — and `prefer`
    /// (the previous frame's answer, or nil) picks between them; with no preference the one nearer
    /// the camera is taken and the frame records that it was a choice, not a measurement.
    static func placeKnuckle(pixel x: SIMD2<Double>, wrist wPin: SIMD3<Double>, radius: Double,
                             K: CameraIntrinsics, prefer: SIMD3<Double>?,
                             tolerance: Double) -> (point: SIMD3<Double>, clamped: Bool)? {
        let d = K.ray(x)
        let hits = rayMeetsSphere(direction: d, centre: wPin, radius: radius)
        if hits.isEmpty {
            let (depth, distance) = closestApproach(direction: d, centre: wPin)
            guard depth > 1e-6, distance <= radius * (1 + tolerance) else { return nil }
            // The ray misses the sphere: the least-wrong point on it is the closest approach, pulled
            // back onto the sphere so the triangle stays rigid.
            let p = depth * d
            let v = p - wPin
            let n = simd_length(v)
            guard n > 1e-9 else { return nil }
            return (wPin + v / n * radius, true)
        }
        // Two intersections: the knuckle in front of the wrist's depth plane and its mirror behind
        // it. A single camera cannot tell them apart — that is the classic two-fold ambiguity, not a
        // shortcoming of this solver — so the choice is made explicitly and the same way every time:
        // follow the previous frame when there is one (a hand does not flip through its own wrist
        // between two samples), and otherwise take the **smaller depth excursion**, the solution
        // that claims the least of the direction the camera cannot see.
        if let prefer {
            let want = prefer.z - wPin.z
            let best = hits.min { abs(($0 * d).z - wPin.z - want) < abs(($1 * d).z - wPin.z - want) } ?? hits[0]
            return (best * d, false)
        }
        let best = hits.min { abs(($0 * d).z - wPin.z) < abs(($1 * d).z - wPin.z) } ?? hits[0]
        return (best * d, false)
    }

    /// Both knuckles at once. Each ray meets the prior's sphere about the wrist 0, 1 or 2 times; the
    /// combination kept is the one whose two points sit closest to the prior's breadth apart — the
    /// triangle's third side, and the one piece of information the two rays have not already used.
    /// Ties (a plate seen exactly face-on, where both branches are equally good) go to whichever
    /// agrees with the previous frame: a hand does not flip through its own wrist between two samples.
    static func placePair(index xi: SIMD2<Double>, little xl: SIMD2<Double>, wrist wPin: SIMD3<Double>,
                          prior: HandSizePrior, K: CameraIntrinsics,
                          previousIndex: SIMD3<Double>?, previousLittle: SIMD3<Double>?,
                          tolerance: Double) -> (index: SIMD3<Double>, little: SIMD3<Double>, clamped: Bool)? {
        let di = K.ray(xi), dl = K.ray(xl)
        let hi = rayMeetsSphere(direction: di, centre: wPin, radius: prior.wristToMCP)
        let hl = rayMeetsSphere(direction: dl, centre: wPin, radius: prior.wristToMCP)
        if hi.isEmpty || hl.isEmpty {
            // One or both rays miss the prior's sphere. Fall back to each ray's own closest approach,
            // which is the least either can be wrong by, and say the point was clamped.
            guard let a = placeKnuckle(pixel: xi, wrist: wPin, radius: prior.wristToMCP, K: K,
                                       prefer: previousIndex, tolerance: tolerance),
                  let b = placeKnuckle(pixel: xl, wrist: wPin, radius: prior.wristToMCP, K: K,
                                       prefer: previousLittle, tolerance: tolerance) else { return nil }
            return (a.point, b.point, a.clamped || b.clamped)
        }
        var best: (index: SIMD3<Double>, little: SIMD3<Double>, score: Double)? = nil
        for si in hi {
            for sl in hl {
                let pi = si * di, pl = sl * dl
                var score = abs(simd_length(pi - pl) - prior.breadth) / prior.breadth
                // Continuity, at a tenth of the weight: it breaks ties, it does not overrule the breadth.
                if let p = previousIndex { score += 0.1 * simd_length(pi - p) / prior.breadth }
                if let p = previousLittle { score += 0.1 * simd_length(pl - p) / prior.breadth }
                if best == nil || score < best!.score { best = (pi, pl, score) }
            }
        }
        guard let best else { return nil }
        return (best.index, best.little, false)
    }

    /// The hand's own axes from the three points, in **camera space** (Vision's convention).
    ///
    /// `side` is the shooter's own hand. With the right hand held palm-away and fingers up, the index
    /// MCP is to the image-left of the little MCP, so (index − little) × (midMCP − wrist) points out
    /// of the palm; the left hand is its mirror. Returns nil when the three points are collinear —
    /// a triangle seen exactly edge-on has no normal, and saying so is the honest answer.
    public static func axes(wrist w: SIMD3<Double>, indexMCP i: SIMD3<Double>, littleMCP l: SIMD3<Double>,
                            side: String) -> (pointing: SIMD3<Double>, palmNormal: SIMD3<Double>)? {
        let mid = (i + l) / 2
        let f = mid - w
        let across = side == "left" ? (l - i) : (i - l)
        let n = simd_cross(across, f)
        let lf = simd_length(f), ln = simd_length(n)
        guard lf > 1e-9, ln > 1e-9, ln / (simd_length(across) * lf) > 1e-3 else { return nil }
        return (f / lf, n / ln)
    }

    /// Roll: the rotation of the palm normal about the pointing axis, measured from the part of `up`
    /// that is perpendicular to the pointing axis. Nil when the hand points along `up`, where there
    /// is no such reference and a roll would be an artefact of the convention.
    public static func roll(pointing f: SIMD3<Double>, palmNormal n: SIMD3<Double>,
                            up: SIMD3<Double> = SIMD3(0, 1, 0)) -> BodyMeasure {
        let upPerp = up - simd_dot(up, f) * f
        let m = simd_length(upPerp)
        guard m > 0.15 else {
            return .missing(.radians, String(format: "the hand points within %.0f° of vertical, so 'up' gives no reference direction to measure a roll from", Angle.degrees(asin(min(1, m)))))
        }
        let r0 = upPerp / m
        let s = simd_dot(simd_cross(r0, n), f)
        let c = simd_dot(r0, n)
        return .ok(atan2(s, c), .radians)
    }

    /// Signed wrist flexion: the angle between the forearm's direction (elbow → wrist) and the hand's
    /// pointing direction, positive when the hand has bent toward its own palm.
    public static func wristFlexion(forearm: SIMD3<Double>, pointing: SIMD3<Double>,
                                    palmNormal: SIMD3<Double>?) -> BodyMeasure {
        guard let theta = BodyAngles.angleBetween(forearm, pointing) else {
            return .missing(.radians, "the forearm or the hand direction had no length on this frame")
        }
        guard let n = palmNormal else {
            return .missing(.radians, "flexion and extension are the same angle without the palm's normal to give it a sign, and this frame had fewer than three confident hand points")
        }
        let lf = simd_length(forearm), lp = simd_length(pointing)
        guard lf > 1e-9, lp > 1e-9 else { return .missing(.radians, "the forearm or the hand direction had no length on this frame") }
        let sign: Double = simd_dot(pointing / lp - forearm / lf, n) >= 0 ? 1 : -1
        return .ok(sign * theta, .radians)
    }
}

// MARK: - Lifting the hand landmarks into the timeline's own 2-D points

/// Turns `BodyFrame.hands` (Vision's 21 landmarks, as the detector returned them) into the three
/// triangle points under the canonical `Body2DPoint` names, so that everything downstream — the
/// skeleton fit, the coverage table, the export, the form — sees them the way it sees a shoulder.
///
/// It does three things and nothing else, and each of them is declared per point in
/// `BodyPoint2D.provenance`:
///
///   1. **Names the side.** Vision's chirality when it gave one; otherwise the body wrist the hand's
///      own wrist landmark is nearest in the image, and the provenance says which.
///   2. **Fills the body wrist from the hand pose** when the body pose had none on that frame. The
///      hand's wrist landmark is the same anatomical point, measured by a different detector, so it
///      is an observation — not an interpolation — and it carries "wrist from hand pose".
///   3. **Carries a point across at most one sampled frame.** A gap of one sample (at 79 samples per
///      second, 13 ms) between two observations is bridged by their midpoint in time; a gap of two
///      or more is left empty. The bridged point says so and its confidence is the smaller of the
///      two it came from, so it can never pull harder than the evidence behind it.
public enum HandPoints {

    public struct Options: Sendable {
        public var minimumHandLandmarkConfidence: Double = 0.20
        public var minimumConfidence2D: Double = 0.30
        /// Fill `leftWrist`/`rightWrist` from the hand pose where the body pose has no confident one.
        public var wristFromHandPose = true
        /// Bridge a gap of at most this many *sampled* frames. 1 by default; 0 switches it off.
        public var interpolateAcrossSamples = 1
        /// A hand whose wrist landmark is further than this many hand breadths from a body wrist is
        /// not that wrist's hand. Only used when the detector gave no chirality.
        public var maximumWristDistanceInPalms: Double = 3.0
        public init() {}
    }

    /// The three triangle point names for one side.
    public static func names(_ side: String) -> (wrist: String, index: String, little: String) {
        side == "left"
            ? (Body2DPoint.leftHandWrist, Body2DPoint.leftIndexMCP, Body2DPoint.leftLittleMCP)
            : (Body2DPoint.rightHandWrist, Body2DPoint.rightIndexMCP, Body2DPoint.rightLittleMCP)
    }

    public struct Report: Sendable, Equatable {
        public var handFramesSeen: Int = 0
        public var sidedByChirality: Int = 0
        public var sidedByNearestWrist: Int = 0
        public var wristsFilledFromHandPose: Int = 0
        public var pointsInterpolated: Int = 0
        public var notes: [String] = []
        public init() {}
    }

    public static func lift(frames: [BodyFrame], options o: Options = Options()) -> (frames: [BodyFrame], report: Report) {
        var out = frames
        var report = Report()

        for t in out.indices {
            let f = out[t]
            guard !f.hands.isEmpty else { continue }
            report.handFramesSeen += 1
            // --- which side is each hand? ---
            var claimed: [String: (hand: BodyHandFrame, howSided: String, score: Double)] = [:]
            for hand in f.hands {
                var side = hand.chirality
                var howSided = "Vision's own chirality"
                if side == nil {
                    guard let hw = hand.landmarks[HandLandmark.wrist] ?? hand.landmarks[HandLandmark.middleMCP] else { continue }
                    let palm = hand.landmarks[HandLandmark.middleMCP].map { simd_length($0.uv - (hand.landmarks[HandLandmark.wrist]?.uv ?? $0.uv)) } ?? 0
                    var best: (String, Double)? = nil
                    for s in ["left", "right"] {
                        guard let q = f.points2D[s + "Wrist"], q.confidence >= o.minimumConfidence2D else { continue }
                        let d = simd_length(q.uv - hw.uv)
                        if best == nil || d < best!.1 { best = (s, d) }
                    }
                    guard let (s, d) = best, palm <= 1e-6 || d <= palm * o.maximumWristDistanceInPalms else { continue }
                    side = s
                    howSided = String(format: "the body wrist it was nearest in the image (%.0f px away); the detector gave no chirality", d)
                    report.sidedByNearestWrist += 1
                } else {
                    report.sidedByChirality += 1
                }
                guard let s = side else { continue }
                // Two hands claiming one side: the more confident observation wins, and nothing is merged.
                if let existing = claimed[s], existing.score >= hand.confidence { continue }
                claimed[s] = (hand, howSided, hand.confidence)
            }

            var points = f.points2D
            for (side, entry) in claimed {
                let n = names(side)
                func put(_ landmark: String, _ name: String) {
                    guard let p = entry.hand.landmarks[landmark], p.confidence >= o.minimumHandLandmarkConfidence else { return }
                    points[name] = BodyPoint2D(name: name, u: p.u, v: p.v, confidence: p.confidence,
                                               provenance: "Vision hand pose, \(landmark); sided by \(entry.howSided)")
                }
                put(HandLandmark.wrist, n.wrist)
                put(HandLandmark.indexMCP, n.index)
                put(HandLandmark.littleMCP, n.little)
                // The body wrist, when the body pose did not give one.
                if o.wristFromHandPose, let hw = entry.hand.landmarks[HandLandmark.wrist],
                   hw.confidence >= o.minimumHandLandmarkConfidence,
                   (points[side + "Wrist"]?.confidence ?? -1) < o.minimumConfidence2D {
                    points[side + "Wrist"] = BodyPoint2D(name: side + "Wrist", u: hw.u, v: hw.v, confidence: hw.confidence,
                                                         provenance: "wrist from hand pose (the body pose returned no confident \(side) wrist on this frame); sided by \(entry.howSided)")
                    report.wristsFilledFromHandPose += 1
                }
            }
            out[t].points2D = points
        }

        // --- bridge single-sample gaps -------------------------------------------------------------
        if o.interpolateAcrossSamples > 0 {
            let bridgeable = ["left", "right"].flatMap { s -> [String] in
                let n = names(s); return [n.wrist, n.index, n.little]
            }
            for name in bridgeable {
                var t = 1
                while t + 1 < out.count {
                    defer { t += 1 }
                    guard out[t].points2D[name] == nil,
                          let a = out[t - 1].points2D[name], let b = out[t + 1].points2D[name],
                          a.confidence >= o.minimumHandLandmarkConfidence,
                          b.confidence >= o.minimumHandLandmarkConfidence else { continue }
                    let span = out[t + 1].realTime - out[t - 1].realTime
                    guard span > 0 else { continue }
                    let w = (out[t].realTime - out[t - 1].realTime) / span
                    let uv = a.uv + (b.uv - a.uv) * w
                    out[t].points2D[name] = BodyPoint2D(
                        name: name, u: uv.x, v: uv.y, confidence: min(a.confidence, b.confidence),
                        provenance: String(format: "interpolated across one sampled frame (%.0f ms between the two observations it sits between); not an observation", 1000 * span))
                    report.pointsInterpolated += 1
                }
            }
        }
        if report.pointsInterpolated > 0 {
            report.notes.append("\(report.pointsInterpolated) hand point(s) were carried across a single sampled frame between two observations; each says so in its provenance and none bridges a gap of two samples or more")
        }
        if report.wristsFilledFromHandPose > 0 {
            report.notes.append("\(report.wristsFilledFromHandPose) frame(s) took the wrist from the hand pose because the body pose returned none above \(String(format: "%.2f", o.minimumConfidence2D)); the two detectors mark the same anatomical point, so this is an observation from a second source, not an inference")
        }
        return (out, report)
    }
}

// MARK: - Fitting the plate over a window

extension HandTriangleFit {

    /// Rebuild an exactly rigid triangle from two independently-placed knuckles. Each raw knuckle sits
    /// on its own view ray at the prior's distance from the wrist, so the pair is generally a little
    /// too wide or too narrow; this puts the prior's triangle in the orientation the pair implies and
    /// keeps the plate rigid — which is the whole point of a rigid plate.
    public static func rigidify(wrist w: SIMD3<Double>, rawIndex ir: SIMD3<Double>, rawLittle lr: SIMD3<Double>,
                                prior: HandSizePrior) -> (index: SIMD3<Double>, little: SIMD3<Double>)? {
        let mid = (ir + lr) / 2
        var f = mid - w
        let lf = simd_length(f)
        guard lf > 1e-9 else { return nil }
        f /= lf
        var a = ir - lr
        a -= simd_dot(a, f) * f
        let la = simd_length(a)
        guard la > 1e-9 else { return nil }
        a /= la
        let c = w + prior.palmLength * f
        return (c + a * (prior.breadth / 2), c - a * (prior.breadth / 2))
    }

    /// The plates for one window, plus what they say about the shot.
    ///
    /// Everything it needs is already in the timeline: the fitted wrist (the skeleton fit's, in
    /// `joints3D`), and the hand triangle's 2-D points (`HandPoints.lift`, which the tracker runs and
    /// which `fit` runs itself when it finds none). Nothing here re-opens the video.
    public static func fit(timeline: BodyTimeline, releaseRealTime: Double?,
                           options o: HandTriangleOptions) -> HandTriangleResult {
        var notes: [String] = [], warnings: [String] = []
        var frames = timeline.frames.sorted { $0.realTime < $1.realTime }

        // The 2-D points, if the producer did not already lift them (an older timeline, or a test).
        let haveLifted = frames.contains { f in Body2DPoint.handCorners.contains { f.points2D[$0] != nil } }
        var liftReport = HandPoints.Report()
        if !haveLifted {
            var lo = HandPoints.Options()
            lo.minimumHandLandmarkConfidence = o.minimumHandLandmarkConfidence
            lo.minimumConfidence2D = o.minimumConfidence2D
            let lifted = HandPoints.lift(frames: frames, options: lo)
            frames = lifted.frames; liftReport = lifted.report
            notes.append(contentsOf: liftReport.notes)
        }

        let statureValue = o.stature ?? ShotForm.fittedStandingHeight(frames: frames)
        guard let stature = statureValue, stature > 1e-6 else {
            let why = "the hand's size is a fraction of the shooter's stature and this window has no stature — no frame carried both an ankle and the nose — so no hand triangle is built rather than one of an invented size"
            warnings.append(why)
            var out = timeline; out.frames = frames
            return HandTriangleResult(timeline: out, tracks: [], measures: .unavailable(why), notes: notes, warnings: warnings)
        }
        let prior = HandSizePrior(stature: stature, statureProvenance: o.statureProvenance)
        notes.append(prior.note)

        let K = o.intrinsics
        var tracks: [HandTriangleTrack] = []
        var joints: [[String: BodyJoint3D]] = frames.map(\.joints3D)

        for side in ["left", "right"] {
            let n = HandPoints.names(side)
            let indexName = side == "left" ? Body3DJoint.leftIndexMCP : Body3DJoint.rightIndexMCP
            let littleName = side == "left" ? Body3DJoint.leftLittleMCP : Body3DJoint.rightLittleMCP
            var rows: [HandTriangleFrame] = []
            var previousIndex: SIMD3<Double>? = nil, previousLittle: SIMD3<Double>? = nil
            var noWrist = 0, noCorner = 0, missedSphere = 0
            var tooNarrow = 0
            var narrowest = Double.infinity
            var role: String? = nil

            for (t, f) in frames.enumerated() {
                func corner(_ name: String) -> BodyPoint2D? {
                    guard let p = f.points2D[name], p.confidence >= o.minimumHandLandmarkConfidence else { return nil }
                    return p
                }
                let xi = corner(n.index), xl = corner(n.little)
                if xi == nil && xl == nil { continue }
                guard let wristCam = f.joints3D[side + "Wrist"]?.cameraPosition else { noWrist += 1; continue }
                if let r = f.hands.first(where: { $0.chirality == side })?.role { role = role ?? r }
                // The apex. Depth from the fitted skeleton; image position from the hand detector when
                // it gave one and the option is on, because that is the frame the knuckles live in.
                var wPin = pinhole(wristCam)
                var apexNote = "the fitted skeleton's wrist"
                if o.apexFromHandPoseWrist, let hw = f.points2D[n.wrist], hw.confidence >= o.minimumHandLandmarkConfidence {
                    let ray = K.ray(hw.uv)
                    if abs(ray.z) > 1e-9 {
                        wPin = ray * (wPin.z / ray.z)
                        apexNote = "the hand pose's own wrist landmark, at the fitted skeleton wrist's depth"
                    }
                }
                var interpolated: [String] = [], clamped: [String] = []
                for (p, label) in [(xi, "indexMCP"), (xl, "littleMCP")] {
                    if let why = p?.provenance, why.hasPrefix("interpolated") { interpolated.append(label) }
                }
                let wristSource = (f.points2D[side + "Wrist"]?.provenance?.hasPrefix("wrist from hand pose") ?? false)
                    ? "wrist from hand pose (the body pose had none on this frame), then fitted by the skeleton"
                    : "body pose, fitted by the skeleton"

                var rawIndex: SIMD3<Double>? = nil, rawLittle: SIMD3<Double>? = nil
                if let xi, let xl, simd_length(xi.uv - xl.uv) < o.minimumKnuckleSeparationPx {
                    // Both knuckles were returned, and they landed on top of each other: this view is
                    // looking along the hand's own width, so nothing about the plate's orientation is
                    // observable here. Refuse the plate rather than fit one to the landmark noise.
                    tooNarrow += 1
                    narrowest = min(narrowest, simd_length(xi.uv - xl.uv))
                    continue
                }
                if let xi, let xl {
                    // Both knuckles: the depth branch is chosen for the **pair**, not one at a time.
                    // Each ray meets the size prior's sphere twice — in front of the wrist's depth
                    // plane and behind it — and a single camera cannot tell those apart on its own.
                    // What it *can* do is ask which of the four combinations leaves the two knuckles
                    // the prior's own breadth apart, which is the third side of the rigid triangle and
                    // the only constraint the image has not already used. Chosen one at a time instead,
                    // the two land on the same branch whenever the plate is near edge-on and the pair
                    // collapses: measured on the 240 fps clip, the breadth residual was −78 % that way
                    // and −8 % this way, with the same pixels.
                    let pair = placePair(index: xi.uv, little: xl.uv, wrist: wPin, prior: prior, K: K,
                                         previousIndex: previousIndex, previousLittle: previousLittle,
                                         tolerance: o.rayMissTolerance)
                    rawIndex = pair?.index; rawLittle = pair?.little
                    if let pair, pair.clamped { clamped.append("indexMCP"); clamped.append("littleMCP") }
                    if pair == nil { missedSphere += 1 }
                } else if let x = xi ?? xl,
                          let placed = placeKnuckle(pixel: x.uv, wrist: wPin, radius: prior.wristToMCP, K: K,
                                                    prefer: xi != nil ? previousIndex : previousLittle,
                                                    tolerance: o.rayMissTolerance) {
                    if xi != nil { rawIndex = placed.point } else { rawLittle = placed.point }
                    if placed.clamped { clamped.append(xi != nil ? "indexMCP" : "littleMCP") }
                } else { missedSphere += 1 }

                var indexCam: SIMD3<Double>? = nil, littleCam: SIMD3<Double>? = nil
                var pointing: SIMD3<Double>? = nil, palmNormal: SIMD3<Double>? = nil
                var rollMeasure: BodyMeasure = .missing(.radians, "no orientation on this frame")
                var reproj: BodyMeasure = .missing(.pixels, "no knuckle was placed on this frame")
                var breadth: BodyMeasure = .missing(.ratio, "the breadth residual needs both knuckles")
                var used = 1

                if let ir = rawIndex, let lr = rawLittle {
                    used = 3
                    let rigid = rigidify(wrist: wPin, rawIndex: ir, rawLittle: lr, prior: prior)
                    let iPin = rigid?.index ?? ir, lPin = rigid?.little ?? lr
                    breadth = .ok(simd_length(ir - lr) / prior.breadth - 1, .ratio)
                    indexCam = visionCamera(iPin); littleCam = visionCamera(lPin)
                    if let ax = axes(wrist: visionCamera(wPin), indexMCP: indexCam!, littleMCP: littleCam!, side: side) {
                        pointing = ax.pointing; palmNormal = ax.palmNormal
                        rollMeasure = roll(pointing: ax.pointing, palmNormal: ax.palmNormal)
                    } else {
                        rollMeasure = .missing(.radians, "the wrist and the two knuckles came out collinear on this frame, so the plate has no normal and no roll")
                    }
                    var errs: [Double] = []
                    for (p, x) in [(iPin, xi), (lPin, xl)] {
                        guard let x, p.z > 1e-6 else { continue }
                        errs.append(simd_length(SIMD2(K.fx * p.x / p.z + K.cx, K.fy * p.y / p.z + K.cy) - x.uv))
                    }
                    reproj = errs.isEmpty ? .missing(.pixels, "neither knuckle projected in front of the camera") : .ok(Stats.rms(errs), .pixels)
                } else if let only = rawIndex ?? rawLittle {
                    used = 2
                    let which = rawIndex != nil ? "index" : "little"
                    let cam = visionCamera(only)
                    if rawIndex != nil { indexCam = cam } else { littleCam = cam }
                    let d = cam - visionCamera(wPin)
                    if simd_length(d) > 1e-9 { pointing = simd_normalize(d) }
                    rollMeasure = .missing(.radians, "only two of the three hand points were confident on this frame (the wrist and the \(which) MCP): two points fix a direction, not an orientation, so the plate's roll about that direction — and with it the palm's normal — is not recoverable here")
                    if let x = (rawIndex != nil ? xi : xl), only.z > 1e-6 {
                        reproj = .ok(simd_length(SIMD2(K.fx * only.x / only.z + K.cx, K.fy * only.y / only.z + K.cy) - x.uv), .pixels)
                    }
                } else {
                    noCorner += 1
                    continue
                }
                previousIndex = rawIndex ?? previousIndex
                previousLittle = rawLittle ?? previousLittle

                rows.append(HandTriangleFrame(
                    realTime: f.realTime, frameIndex: f.frameIndex, side: side, role: f.hands.first(where: { $0.chirality == side })?.role,
                    wrist: visionCamera(wPin), indexMCP: indexCam, littleMCP: littleCam,
                    palmNormal: palmNormal, pointing: pointing, roll: rollMeasure,
                    reprojectionPixels: reproj, breadthResidual: breadth, pointsUsed: used,
                    wristProvenance: wristSource + "; plate apex on " + apexNote,
                    interpolatedPoints: interpolated, clampedPoints: clamped))

                // The fitted corners go back into the timeline under their own joint names, so the
                // export, the form and the viewer pick them up exactly as they pick up an elbow.
                func write(_ name: String, _ cam: SIMD3<Double>?, _ x: BodyPoint2D?) {
                    guard let cam else { return }
                    let p = pinhole(cam)
                    let uv: SIMD2<Double>? = p.z > 1e-6 ? SIMD2(K.fx * p.x / p.z + K.cx, K.fy * p.y / p.z + K.cy) : nil
                    joints[t][name] = BodyJoint3D(name: name, position: cam, cameraPosition: cam,
                                                  imageU: uv?.x, imageV: uv?.y, confidence: x?.confidence)
                }
                write(indexName, indexCam, xi)
                write(littleName, littleCam, xl)
            }

            var trackNotes: [String] = []
            if missedSphere > 0 {
                trackNotes.append("\(missedSphere) knuckle observation(s) were refused because their view ray missed the hand-size sphere about the fitted wrist by more than \(Int(100 * o.rayMissTolerance)) %: the prior's hand and the fitted wrist's depth cannot both be right there, so no point was placed")
            }
            if noWrist > 0 {
                trackNotes.append("\(noWrist) frame(s) carried a knuckle but no fitted \(side) wrist to hang the plate on")
            }
            if tooNarrow > 0 {
                trackNotes.append(String(format: "%d frame(s) had both %@ knuckles but only %.1f px between them at the closest, under the %.0f px keypoint-noise floor: on those frames the camera is looking along the hand's own width, so no plate is claimed — the plate's transverse direction is not observable there",
                                         tooNarrow, side, narrowest.isFinite ? narrowest : 0, o.minimumKnuckleSeparationPx))
            }
            let why: String? = rows.isEmpty
                ? "no frame in this window carried a confident \(side) index or little MCP above \(String(format: "%.2f", o.minimumHandLandmarkConfidence)), so there is no \(side) hand plate"
                : nil
            tracks.append(HandTriangleTrack(side: side, role: role, prior: prior, frames: rows,
                                            framesInWindow: frames.count, unavailableReason: why, notes: trackNotes))
            _ = noCorner
        }

        for (t, js) in joints.enumerated() { frames[t].joints3D = js }
        var out = timeline
        out.frames = frames

        let measures = shotMeasures(tracks: tracks, frames: frames, releaseRealTime: releaseRealTime, options: o)
        for tr in tracks {
            notes.append("\(tr.side) hand: \(tr.frames.count) plate(s) over \(tr.framesInWindow) analysed frames, \(tr.framesWithOrientation) with all three points and therefore with a palm normal" + (tr.unavailableReason.map { " — " + $0 } ?? ""))
            notes.append(contentsOf: tr.notes)
        }
        return HandTriangleResult(timeline: out, tracks: tracks, measures: measures, notes: notes, warnings: warnings)
    }

    // MARK: Per-shot measures

    static func shotMeasures(tracks: [HandTriangleTrack], frames: [BodyFrame], releaseRealTime: Double?,
                             options o: HandTriangleOptions) -> HandShotMeasures {
        guard let release = releaseRealTime else {
            return .unavailable("no release instant was supplied, so there is no instant to read the hand at")
        }
        var notes: [String] = []
        // Which hand shoots: the caller's answer, else the role the tracker labelled, else nothing.
        var shootingSide = o.shootingSide
        if shootingSide == nil { shootingSide = tracks.first(where: { $0.role == "shooting" })?.side }
        guard let side = shootingSide, let shooting = tracks.first(where: { $0.side == side }) else {
            let why = "nothing in this window said which hand shoots, so no hand measure is attributed to a shooting hand"
            return .unavailable(why)
        }
        let tol = o.instantToleranceSeconds
        let at = shooting.nearest(release, within: tol)
        let noPlate = String(format: "the %@ hand had no fitted plate within %.0f ms of the release: the shooting hand is on the ball right up to that instant and Vision's hand pose does not see a hand wrapped around a ball", side, 1000 * tol)

        let up = SIMD3<Double>(0, 1, 0)
        func angleTo(_ v: SIMD3<Double>?, _ w: SIMD3<Double>, _ why: String) -> BodyMeasure {
            guard let v else { return .missing(.radians, why) }
            guard let a = BodyAngles.angleBetween(v, w) else { return .missing(.radians, "the two directions had no length") }
            return .ok(a, .radians)
        }
        let normalWhy = at == nil ? noPlate
            : (at!.pointsUsed < 3 ? "only two of the three hand points were confident at the release, so the palm's normal is not recoverable there" : "the plate at the release was collinear")

        // Palm against the rim bearing. Only the rim's image column is known on a single view, so the
        // direction is the camera's horizontal toward it — a bearing, with no depth in it.
        var palmToRim: BodyMeasure = .missing(.radians, normalWhy)
        if let rimU = o.rimImageU {
            let bodyU = ShotForm.meanMidHipColumn(frames: frames, minimumConfidence: o.minimumConfidence2D)
            let sign: Double = (bodyU.map { rimU >= $0 } ?? true) ? 1 : -1
            palmToRim = angleTo(at?.palmNormal, SIMD3(sign, 0, 0), normalWhy)
            if palmToRim.isAvailable {
                notes.append("the palm's angle to the rim is against the rim's **bearing** — the camera's horizontal toward the rim's image column — because a single view knows where the rim is left-to-right and not how far away it is")
            }
        } else if at != nil {
            palmToRim = .missing(.radians, "no rim image column was supplied, so there is no rim bearing to measure the palm against")
        }

        let palmToVertical = angleTo(at?.palmNormal, up, normalWhy)
        let pointingToVertical = angleTo(at?.pointing, up, at == nil ? noPlate : "the plate at the release had no pointing direction")

        // Wrist flexion: forearm against the hand, through the release.
        func flexion(_ row: HandTriangleFrame) -> BodyMeasure {
            guard let frame = frames.min(by: { abs($0.realTime - row.realTime) < abs($1.realTime - row.realTime) }),
                  let elbow = frame.joints3D[side + "Elbow"]?.cameraPosition,
                  let wrist = frame.joints3D[side + "Wrist"]?.cameraPosition else {
                return .missing(.radians, "the fitted \(side) elbow was not available on this frame, so there is no forearm to measure the hand against")
            }
            guard let pointing = row.pointing else { return .missing(.radians, "the plate had no pointing direction on this frame") }
            return wristFlexion(forearm: wrist - elbow, pointing: pointing, palmNormal: row.palmNormal)
        }
        let flexionAtRelease = at.map(flexion) ?? .missing(.radians, noPlate)

        let lo = release - o.throughReleaseSeconds, hi = release + o.throughReleaseSeconds
        let through = shooting.frames.filter { $0.realTime >= lo && $0.realTime <= hi }
        let values = through.compactMap { row -> (t: Double, v: Double)? in flexion(row).value.map { (row.realTime, $0) } }
        var change: BodyMeasure = .missing(.radians, String(format: "fewer than two frames between %.0f ms either side of the release carried both the plate and the forearm", 1000 * o.throughReleaseSeconds))
        var range: BodyMeasure = change
        if values.count >= 2 {
            let first = values.min { $0.t < $1.t }!, last = values.max { $0.t < $1.t }!
            change = .ok(last.v - first.v, .radians)
            range = .ok(values.map(\.v).max()! - values.map(\.v).min()!, .radians)
            if values.allSatisfy({ $0.t >= release - 1e-9 }) {
                notes.append(String(format: "every frame the wrist flexion could be read on between %.0f ms either side of the release fell **after** it: before the release the shooting hand is behind the ball and the hand detector does not return it, so this 'through the release' number is really 'just after it'", 1000 * o.throughReleaseSeconds))
            }
        }

        // ---- the guide hand's contact plane ---------------------------------------------------
        var guidePlane: BodyMeasure = .missing(.radians, "no guide hand")
        var guideVertical: BodyMeasure = guidePlane
        var guideTime: BodyMeasure = .missing(.seconds, "no guide hand")
        let guideSide = side == "left" ? "right" : "left"
        if let guide = tracks.first(where: { $0.side == guideSide }) {
            if o.ballTrack.isEmpty {
                let why = "the guide hand's last contact with the ball needs the ball track, and this record does not carry one — BodyShot has no ball samples in it (schema §3), so this can only be computed in the pass that has both"
                guidePlane = .missing(.radians, why); guideVertical = .missing(.radians, why); guideTime = .missing(.seconds, why)
            } else if guide.frames.isEmpty {
                let why = "no \(guideSide) hand plate was fitted in this window, so there is no contact plane to orient"
                guidePlane = .missing(.radians, why); guideVertical = .missing(.radians, why); guideTime = .missing(.seconds, why)
            } else {
                let ball = o.ballTrack.sorted { $0.t < $1.t }
                var last: HandTriangleFrame? = nil
                for row in guide.frames.sorted(by: { $0.realTime < $1.realTime }) where row.realTime <= release + 1e-9 {
                    guard let b = ball.min(by: { abs($0.t - row.realTime) < abs($1.t - row.realTime) }),
                          abs(b.t - row.realTime) <= 0.020, b.diameterPx > 1 else { continue }
                    let corners = [row.indexMCP, row.littleMCP].compactMap { $0 }
                    guard !corners.isEmpty else { continue }
                    // Contact is judged in the image, where both the ball and the landmarks were measured.
                    let radii = corners.map { c -> Double in
                        let p = pinhole(c)
                        guard p.z > 1e-6 else { return .infinity }
                        let uv = SIMD2(o.intrinsics.fx * p.x / p.z + o.intrinsics.cx, o.intrinsics.fy * p.y / p.z + o.intrinsics.cy)
                        return simd_length(uv - SIMD2(b.u, b.v)) / (b.diameterPx / 2)
                    }
                    if radii.min()! <= o.contactRadii { last = row }
                }
                if let last {
                    guideTime = .ok(last.realTime, .seconds)
                    guideVertical = angleTo(last.palmNormal, up, "the guide plate at the last contact had fewer than three confident points, so it has no normal")
                    // The shot plane's normal is the camera's horizontal across the shot: on a side
                    // view the shot travels in the image plane, so its plane's normal is the view ray.
                    guidePlane = angleTo(last.palmNormal, SIMD3(0, 0, 1),
                                         "the guide plate at the last contact had fewer than three confident points, so it has no normal")
                    if guidePlane.isAvailable {
                        notes.append("the guide hand's contact plane is measured against the **shot plane's normal**, which on a side-on view is the camera's own view ray: 90° means the guide palm lay in the shot plane (square to the ball's path), 0° that it faced across it")
                    }
                } else {
                    let why = String(format: "no %@-hand knuckle came within %.1f ball radii of the ball centre on any frame up to the release that carried both a plate and a ball sample within 20 ms", guideSide, o.contactRadii)
                    guidePlane = .missing(.radians, why); guideVertical = .missing(.radians, why); guideTime = .missing(.seconds, why)
                }
            }
        }

        return HandShotMeasures(
            palmToRimBearingAtRelease: palmToRim, palmToVerticalAtRelease: palmToVertical,
            pointingToVerticalAtRelease: pointingToVertical,
            rollAtRelease: at?.roll ?? .missing(.radians, noPlate),
            wristFlexionAtRelease: flexionAtRelease, wristFlexionChangeThroughRelease: change,
            wristFlexionRangeThroughRelease: range, wristFlexionFramesThroughRelease: values.count,
            guideContactPlaneToShotPlane: guidePlane, guideContactPlaneToVertical: guideVertical,
            guideLastContactRealTime: guideTime, notes: notes)
    }
}
