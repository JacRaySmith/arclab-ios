import Foundation
import simd

// ================================================================================================
// MARK: - The foot as a rigid triangle (1.3 Track C, 2026-09-16)
// ================================================================================================
//
// Vision's body pose stops at the ankle: there is no heel and no toe in it, on any view, at any
// camera angle, which is why `FootworkMetrics.footAngleToRim` has been nil since it was written.
// `ShotVideo.FootPoseDetector` now supplies six new 2-D points per frame from an RTMPose-m Halpe-26
// model — heel, big toe and little toe per foot — and this file turns three of them at a time into
// an oriented 3-D plate:
//
//     heel (back)  ·  big toe (front, inner)  ·  little toe (front, outer)
//
// The construction is deliberately the same one `HandTriangle.swift` uses for the hand, for the
// same reason: a single camera cannot measure the *size* of a 50-pixel foot, so the size is a
// declared population prior, the plate is anchored at the ankle the skeleton fit already solved,
// and only its **orientation** is fitted — each vertex lands where its own view ray meets a sphere
// of the prior's radius about that ankle. Everything derived from the plate inherits that
// provenance and says so.
//
// What it buys:
//   · the foot's pointing direction — and so the **foot angle** against the rim bearing, the metric
//     `FootworkMetrics` has been refusing;
//   · heel and toe *height* separately, and so heel-first / toe-first contact order per step;
//   · the foot's roll — but only when the two toes are actually separated in the image. At ArcLab's
//     own framing the toe pair is 12–15 px apart (measured, see docs/PHASE2-PREP.md "Feet"), and
//     under ~4 px the roll is refused rather than reported as noise.
//
// This file is a **separate pass**: it takes a finished `BodySkeletonFitResult` (or a plain
// `BodyTimeline`) and returns foot triangles. It does not modify `BodyKinematics.swift`,
// `FormModel.swift` or `BodyShotExport.swift`.
//
// Radians in code, degrees at the boundary (rule 4). Foundation + simd only (rule 2). Every number
// is a `BodyMeasure`: a value, or nil with a reason (rule 1).
//
// Frames of reference: positions are **camera space in Vision's convention** — +x right, +y up,
// +z toward the camera — the same as `BodyJoint3D.cameraPosition`. `pinhole(_:)` / `visionCamera(_:)`
// (defined in HandTriangle.swift; the same map, its own inverse) are the only places the pinhole
// algebra and that convention meet.

// MARK: - The six new 2-D point names

/// The foot landmarks `ShotVideo.FootPoseDetector` writes into `BodyFrame.points2D`. They are a
/// separate extension, not new cases in `Body2DPoint.all`, because `Body2DPoint.all` means "the 19
/// points Apple's 2-D body model returns" and these six come from a different detector entirely.
extension Body2DPoint {
    public static let leftHeel = "leftHeel"
    public static let rightHeel = "rightHeel"
    public static let leftBigToe = "leftBigToe"
    public static let rightBigToe = "rightBigToe"
    public static let leftLittleToe = "leftLittleToe"
    public static let rightLittleToe = "rightLittleToe"

    /// The six, in a fixed order: left heel, big toe, little toe, then the right.
    public static let footPoints = [leftHeel, leftBigToe, leftLittleToe,
                                    rightHeel, rightBigToe, rightLittleToe]

    /// True for a point this file owns — so a consumer that means "Apple's 19" can exclude them.
    public static func isFootPoint(_ name: String) -> Bool { footPoints.contains(name) }
}

// MARK: - The size prior

/// Where the foot's size comes from. A population figure, declared as one everywhere it is used.
///
/// **Foot length ≈ 0.152 × stature and foot breadth ≈ 0.055 × stature.** Both are Drillis &
/// Contini's body-segment table — Drillis, R. and Contini, R., *Body Segment Parameters*, Office of
/// Vocational Rehabilitation report 1166-03, New York University, 1966 — as reproduced in Winter,
/// D. A., *Biomechanics and Motor Control of Human Movement*, 4th ed. (2009), Fig. 4.1. The same
/// figure gives the **ankle (lateral malleolus) height, 0.039 × stature**, which is what puts the
/// plate's anchor above the floor rather than on it. `BodySkeletonOptions` already carries two other
/// rows of this same table (biiliac 0.191 H, biacromial 0.245 H), so the foot is not a new source.
///
/// Three further numbers are **declared shape ratios, not citations**, and are named as such in
/// `note` and in the export. They place the three *landmarks* on a foot whose length and breadth the
/// table gives:
///   · heel landmark → ankle, along the foot: **0.19 × foot length**;
///   · big-toe landmark: **0.95 × foot length** from the heel (the big toe is all but the tip);
///   · little-toe landmark: **0.78 × foot length** (the fifth toe is the short one).
/// They are round numbers from foot outlines, and the fit reports how badly each frame's two rays
/// disagree with them (`lengthResidual`, `widthResidual`) rather than asking to be believed.
public struct FootSizePrior: Sendable, Codable, Equatable {
    public var footLength: Double          // heel → the tip of the longest toe
    public var ballWidth: Double           // across the metatarsal heads
    public var ankleHeight: Double         // lateral malleolus above the floor
    public var stature: Double
    public var statureProvenance: String
    public var footLengthFractionOfStature: Double
    public var ballWidthFractionOfStature: Double
    public var ankleHeightFractionOfStature: Double
    public var heelToAnkleAlongFoot: Double
    public var bigToeAlongFoot: Double
    public var littleToeAlongFoot: Double
    /// Always true. The field exists so a reader of the exported file never has to know this comment.
    public var isPopulationPrior: Bool { true }
    public var note: String

    public static let footLengthFraction = 0.152
    public static let ballWidthFraction = 0.055
    public static let ankleHeightFraction = 0.039
    public static let heelToAnkleFraction = 0.19
    public static let bigToeFraction = 0.95
    public static let littleToeFraction = 0.78

    public init(stature: Double, statureProvenance: String,
                footLengthFraction: Double = FootSizePrior.footLengthFraction,
                ballWidthFraction: Double = FootSizePrior.ballWidthFraction,
                ankleHeightFraction: Double = FootSizePrior.ankleHeightFraction) {
        self.stature = stature
        self.statureProvenance = statureProvenance
        self.footLengthFractionOfStature = footLengthFraction
        self.ballWidthFractionOfStature = ballWidthFraction
        self.ankleHeightFractionOfStature = ankleHeightFraction
        self.footLength = stature * footLengthFraction
        self.ballWidth = stature * ballWidthFraction
        self.ankleHeight = stature * ankleHeightFraction
        self.heelToAnkleAlongFoot = FootSizePrior.heelToAnkleFraction
        self.bigToeAlongFoot = FootSizePrior.bigToeFraction
        self.littleToeAlongFoot = FootSizePrior.littleToeFraction
        self.note = String(format:
            "the foot's size is a **population prior**, not a measurement: foot length %.3f × stature and foot breadth %.3f × stature from Drillis & Contini's segment table (1966) as reproduced in Winter, Biomechanics and Motor Control of Human Movement 4th ed. Fig. 4.1, with the ankle %.3f × stature above the floor from the same figure. Where the three landmarks sit on that foot — heel→ankle %.2f, big toe %.2f, little toe %.2f of foot length — is a declared shape ratio, not a citation. Stature here is %@. A single camera cannot measure a 50-pixel foot, so its size is borrowed and its orientation alone is fitted.",
            footLengthFraction, ballWidthFraction, ankleHeightFraction,
            FootSizePrior.heelToAnkleFraction, FootSizePrior.bigToeFraction, FootSizePrior.littleToeFraction,
            statureProvenance)
    }

    // ---- the triangle in the foot's own frame -------------------------------------------------
    // x forward (heel → toe), y to the foot's left, z up; the origin at the heel landmark on the floor.

    public var heelLocal: SIMD3<Double> { SIMD3(0, 0, 0) }
    public var ankleLocal: SIMD3<Double> { SIMD3(heelToAnkleAlongFoot * footLength, 0, ankleHeight) }
    /// The big toe is **medial**: on the foot's right for the left foot, on its left for the right.
    public func bigToeLocal(side: FootSide) -> SIMD3<Double> {
        SIMD3(bigToeAlongFoot * footLength, side == .left ? -ballWidth / 2 : ballWidth / 2, 0)
    }
    public func littleToeLocal(side: FootSide) -> SIMD3<Double> {
        SIMD3(littleToeAlongFoot * footLength, side == .left ? ballWidth / 2 : -ballWidth / 2, 0)
    }

    /// Distance from the ankle to each vertex — the three sphere radii the fit places rays on.
    public func radii(side: FootSide) -> (heel: Double, bigToe: Double, littleToe: Double) {
        (simd_length(heelLocal - ankleLocal),
         simd_length(bigToeLocal(side: side) - ankleLocal),
         simd_length(littleToeLocal(side: side) - ankleLocal))
    }
    /// The two edge lengths the residuals are measured against.
    public func edges(side: FootSide) -> (heelToBigToe: Double, toeSpan: Double) {
        (simd_length(bigToeLocal(side: side) - heelLocal),
         simd_length(bigToeLocal(side: side) - littleToeLocal(side: side)))
    }
}

// MARK: - One frame of one foot

/// The fitted plate on one frame. Positions are camera space (Vision's convention) in the fit's own
/// length unit; directions are unit vectors in the same frame.
public struct FootTriangleFrame: Sendable, Codable, Equatable {
    public var realTime: Double
    public var frameIndex: Int
    public var side: String                      // "left" / "right"

    public var ankle: SIMD3<Double>
    public var heel: SIMD3<Double>?
    public var bigToe: SIMD3<Double>?
    public var littleToe: SIMD3<Double>?

    /// Heel → the midpoint of the two toes: the foot's long axis. With one toe only it is
    /// heel → that toe and `notes` says so.
    public var pointing: SIMD3<Double>?
    /// Out of the **top** of the foot. Nil whenever fewer than three points were confident, or when
    /// the two toes are too close together in the image to define an across-axis.
    public var footUp: SIMD3<Double>?
    /// Rotation of `footUp` about `pointing`, measured from the part of camera-up perpendicular to
    /// `pointing`, positive by the right-hand rule about `pointing`. 0 = the foot is flat.
    public var roll: BodyMeasure
    /// The foot's yaw in the camera's horizontal plane, measured **from the camera's optical axis**
    /// (0 = the foot points straight away from the camera, +ve toward camera-right). Needs no rim
    /// and no assumption beyond a level camera, which is why it is published separately from the
    /// rim-relative angle that `FootShotMeasures` carries.
    public var yawFromCameraAxis: BodyMeasure
    /// Height of the heel and of the mid-toe above this foot's own floor, in the fit's length unit —
    /// the pair whose *difference* is heel-first vs toe-first.
    public var heelHeight: BodyMeasure
    public var toeHeight: BodyMeasure

    /// Image separation of the two toe landmarks, pixels. Under `FootTriangleOptions.
    /// minimumToePairPixels` the roll is refused, and this is the number in that refusal.
    public var toePairPixels: BodyMeasure
    /// RMS distance, pixels, between the **rigid** triangle's reprojections and the three landmarks.
    ///
    /// Reprojecting the *placed* vertices is worthless — each one sits on its own view ray by
    /// construction, so that number is identically zero and says nothing. What is reported instead
    /// is the rigid prior triangle, rotated onto the three placed points about the fitted ankle and
    /// then reprojected: it is the pixels by which a foot of the prior's shape, hung on the fitted
    /// ankle, fails to explain what the detector saw. That is the number worth reading.
    public var reprojectionPixels: BodyMeasure
    /// The image-plane length of heel → mid-toe, pixels. The foot's yaw is conditioned on this: a
    /// foot pointing at the camera projects short, and a short projection makes the yaw sensitive.
    public var pointingImagePixels: BodyMeasure
    /// 1σ on `yawFromCameraAxis` **propagated from a ±1 px error on each landmark** — the whole
    /// triangle refitted with each of the three observations moved one pixel each way, and half the
    /// peak-to-peak yaw taken. This is the number that says whether a foot angle is worth reading;
    /// the frame-to-frame spread over a window is a different (and smaller) thing.
    public var yawSigmaFromPixelNoise: BodyMeasure
    /// ‖heel − big toe‖ ÷ the prior's own heel-to-big-toe − 1. 0 means rays and prior agree.
    public var lengthResidual: BodyMeasure
    /// ‖big toe − little toe‖ ÷ the prior's own toe span − 1.
    public var widthResidual: BodyMeasure

    /// How many of the three vertices were confident on this frame (2 or 3).
    public var pointsUsed: Int
    /// Detector confidence of each point that was used, by landmark name.
    public var confidences: [String: Double]
    /// Vertices whose ray missed the prior's sphere and were taken at closest approach.
    public var clampedPoints: [String]
    /// Points the detector saw but the gate refused, with the number that refused them.
    public var refusedPoints: [String: String]

    public init(realTime: Double, frameIndex: Int, side: String, ankle: SIMD3<Double>,
                heel: SIMD3<Double>?, bigToe: SIMD3<Double>?, littleToe: SIMD3<Double>?,
                pointing: SIMD3<Double>?, footUp: SIMD3<Double>?, roll: BodyMeasure,
                yawFromCameraAxis: BodyMeasure, heelHeight: BodyMeasure, toeHeight: BodyMeasure,
                toePairPixels: BodyMeasure, reprojectionPixels: BodyMeasure,
                pointingImagePixels: BodyMeasure = .missing(.pixels, "not measured"),
                yawSigmaFromPixelNoise: BodyMeasure = .missing(.radians, "not measured"),
                lengthResidual: BodyMeasure, widthResidual: BodyMeasure, pointsUsed: Int,
                confidences: [String: Double] = [:], clampedPoints: [String] = [],
                refusedPoints: [String: String] = [:]) {
        self.realTime = realTime; self.frameIndex = frameIndex; self.side = side; self.ankle = ankle
        self.heel = heel; self.bigToe = bigToe; self.littleToe = littleToe
        self.pointing = pointing; self.footUp = footUp; self.roll = roll
        self.yawFromCameraAxis = yawFromCameraAxis
        self.heelHeight = heelHeight; self.toeHeight = toeHeight
        self.toePairPixels = toePairPixels; self.reprojectionPixels = reprojectionPixels
        self.pointingImagePixels = pointingImagePixels
        self.yawSigmaFromPixelNoise = yawSigmaFromPixelNoise
        self.lengthResidual = lengthResidual; self.widthResidual = widthResidual
        self.pointsUsed = pointsUsed; self.confidences = confidences
        self.clampedPoints = clampedPoints; self.refusedPoints = refusedPoints
    }
}

/// One foot over the window.
public struct FootTriangleTrack: Sendable, Codable, Equatable {
    public var side: String
    public var prior: FootSizePrior
    public var frames: [FootTriangleFrame]
    /// Analysed frames in the window, so a rate can be read off `frames.count`.
    public var framesInWindow: Int
    /// How many frames the **detector** returned this foot's three points on, before any fit.
    public var framesDetected: Int
    public var unavailableReason: String?
    public var notes: [String]

    public var framesWithOrientation: Int { frames.filter { $0.pointsUsed >= 3 }.count }
    public var framesWithRoll: Int { frames.filter { $0.roll.isAvailable }.count }

    public func nearest(_ t: Double, within tolerance: Double) -> FootTriangleFrame? {
        guard let f = frames.min(by: { abs($0.realTime - t) < abs($1.realTime - t) }),
              abs(f.realTime - t) <= tolerance else { return nil }
        return f
    }
}

// MARK: - Per-shot measures

/// Which part of the foot reached the floor first on one touchdown.
public enum FootStrike: String, Sendable, Codable {
    case heelFirst, toeFirst, flat, unknown
    public var title: String {
        switch self {
        case .heelFirst: return "heel first"
        case .toeFirst: return "toe first"
        case .flat: return "flat"
        case .unknown: return "not determined"
        }
    }
}

/// One touchdown, and what struck first.
public struct FootStrikeEvent: Sendable, Codable, Equatable {
    public var foot: String                 // FootSide.rawValue
    public var touchdownRealTime: Double
    public var strike: String               // FootStrike.rawValue
    /// Heel image row minus toe image row at the instant the foot first reached its floor, in the
    /// shooter's own stature units. Negative = the heel was higher (toe-first); positive = heel-first.
    public var heelMinusToeStature: BodyMeasure
    public var unavailableReason: String?
    public init(foot: String, touchdownRealTime: Double, strike: String,
                heelMinusToeStature: BodyMeasure, unavailableReason: String?) {
        self.foot = foot; self.touchdownRealTime = touchdownRealTime; self.strike = strike
        self.heelMinusToeStature = heelMinusToeStature; self.unavailableReason = unavailableReason
    }
}

public struct FootShotMeasures: Sendable, Codable, Equatable {
    /// The shooting-side foot's yaw against the rim's bearing at the **set**, radians. 0 = the foot
    /// points at the rim. Sign: positive = the toe is turned toward the shooting side.
    public var footAngleToRimAtSet: BodyMeasure
    /// The same for the other foot.
    public var otherFootAngleToRimAtSet: BodyMeasure
    /// The angle between the two feet's pointing directions at the set — how open the stance is.
    public var stanceOpennessAtSet: BodyMeasure
    /// 1σ on `footAngleToRimAtSet`, from the frame-to-frame spread of the same angle over the set
    /// window: the fit's own repeatability, not a claim about accuracy.
    public var footAngleSigmaAtSet: BodyMeasure
    /// The **propagated** 1σ: the median over the set window of each frame's own
    /// `yawSigmaFromPixelNoise`. This is the honest error bar — it is what a one-pixel landmark
    /// error does to this shot's foot angle, and on a near-side view it is much the larger of the
    /// two. Read the foot angle as `value ± this`, not ± the frame-to-frame spread.
    public var footAnglePixelNoiseSigmaAtSet: BodyMeasure
    /// Median image-plane length of the shooting foot's own axis over the set window, pixels — what
    /// the yaw above is conditioned on.
    public var footPointingPixelsAtSet: BodyMeasure
    /// How far the camera's bearing to the rim differs from its bearing to the shooter. The
    /// rim-relative foot angle is exact only when this is zero; it is published so a reader can see
    /// how much of the number is parallax. See `footAngleProvenance`.
    public var rimBearingParallax: BodyMeasure
    public var footAngleProvenance: String
    /// One entry per touchdown before the lift.
    public var strikes: [FootStrikeEvent]
    public var notes: [String]

    public static func unavailable(_ why: String) -> FootShotMeasures {
        FootShotMeasures(footAngleToRimAtSet: .missing(.radians, why),
                         otherFootAngleToRimAtSet: .missing(.radians, why),
                         stanceOpennessAtSet: .missing(.radians, why),
                         footAngleSigmaAtSet: .missing(.radians, why),
                         footAnglePixelNoiseSigmaAtSet: .missing(.radians, why),
                         footPointingPixelsAtSet: .missing(.pixels, why),
                         rimBearingParallax: .missing(.radians, why),
                         footAngleProvenance: why, strikes: [], notes: [])
    }
}

public struct FootTriangleResult: Sendable {
    /// The input timeline with the fitted vertices added to `joints3D` under the six foot names,
    /// and nothing else changed.
    public var timeline: BodyTimeline
    public var tracks: [FootTriangleTrack]
    public var measures: FootShotMeasures
    public var notes: [String]
    public var warnings: [String]
}

// MARK: - Options

public struct FootTriangleOptions: Sendable {
    public var intrinsics: CameraIntrinsics
    /// The detector's SimCC confidence floor for a foot landmark. Measured on the 240 fps clip the
    /// six points come back at 0.65–0.90 on a clearly seen foot, so 0.35 refuses the genuinely
    /// unseen without throwing away ordinary frames. A point below it is **absent with the number**
    /// in `FootTriangleFrame.refusedPoints`, never interpolated.
    public static let defaultMinimumFootConfidence: Double = 0.35
    public var minimumFootConfidence: Double = defaultMinimumFootConfidence
    /// The body-pose floor, for the fitted ankle.
    public var minimumConfidence2D: Double = 0.30
    /// A vertex ray that misses the prior's sphere by no more than this fraction of the radius is
    /// taken at its closest approach instead; beyond it the vertex is refused.
    public var rayMissTolerance: Double = 0.35
    /// Under this image separation between the two toe landmarks the **roll** is refused: the two
    /// rays are then closer together than the detector's own error and any roll read from them is
    /// noise with a number attached. 4 px, against the 12–15 px the 240 fps clip actually gives.
    public var minimumToePairPixels: Double = 4.0
    /// The shooter's stature in the timeline's own length unit. Nil refuses every triangle.
    public var stature: Double?
    public var statureProvenance: String = "the fitted skeleton's own standing height"
    /// The rim's image column, when known. Without it the rim-relative foot angle is refused and
    /// only `yawFromCameraAxis` survives.
    public var rimImageU: Double?
    /// A track sample counts as "at" an instant within this many real seconds of it.
    public var instantToleranceSeconds: Double = 0.02
    /// Half-width of the window the set-instant foot angle and its σ are read over, real seconds.
    public var setWindowSeconds: Double = 0.06
    public var shootingSide: String?
    public init(intrinsics: CameraIntrinsics) { self.intrinsics = intrinsics }
}

// MARK: - The fit

public enum FootTriangleFit {

    /// Depths at which the ray `s·direction` (from the camera at the origin, pinhole frame) meets
    /// the sphere of radius `r` about `c`; zero, one or two, nearest the closest approach first.
    /// Deliberately a local copy of the same three lines `HandTriangle.swift` carries, so the two
    /// appendage fits can be worked on independently.
    public static func rayMeetsSphere(direction d: SIMD3<Double>, centre c: SIMD3<Double>, radius r: Double) -> [Double] {
        let dd = simd_dot(d, d)
        guard dd > 1e-12, r > 0 else { return [] }
        let b = simd_dot(d, c) / dd
        let closest = simd_length(b * d - c)
        if closest > r { return [] }
        let half = ((r * r - closest * closest) / dd).squareRoot()
        return [b - half, b + half].filter { $0 > 1e-6 }.sorted { abs($0 - b) < abs($1 - b) }
    }

    public static func closestApproach(direction d: SIMD3<Double>, centre c: SIMD3<Double>) -> (depth: Double, distance: Double) {
        let dd = max(1e-12, simd_dot(d, d))
        let b = simd_dot(d, c) / dd
        return (b, simd_length(b * d - c))
    }

    /// **Both** places a vertex could be: a view ray meets a sphere twice, once in front of the
    /// ankle's depth plane and once behind it, and a single camera cannot tell the two apart. For a
    /// hand the convention is to take the smaller depth excursion; for a foot that is wrong often
    /// enough to matter — a foot pointing away from the camera has its toes genuinely deeper than
    /// its ankle — so the choice is made once for the whole triangle, by `chooseTriangle` below,
    /// using the only thing that can settle it: which combination the prior's own *shape* explains.
    static func candidates(pixel x: SIMD2<Double>, ankle aPin: SIMD3<Double>, radius: Double,
                           K: CameraIntrinsics, tolerance: Double) -> [(point: SIMD3<Double>, clamped: Bool)] {
        let d = K.ray(x)
        let hits = rayMeetsSphere(direction: d, centre: aPin, radius: radius)
        if !hits.isEmpty { return hits.map { ($0 * d, false) } }
        let (depth, distance) = closestApproach(direction: d, centre: aPin)
        guard depth > 1e-6, distance <= radius * (1 + tolerance) else { return [] }
        let v = depth * d - aPin
        let n = simd_length(v)
        guard n > 1e-9 else { return [] }
        return [(aPin + v / n * radius, true)]
    }

    /// Place one vertex: where its view ray meets the sphere of the prior's radius about the fitted
    /// ankle. `prefer` (the previous frame's answer) picks between the two branches; with none, the
    /// smaller depth excursion wins. Used for the two-vertex case, where there is no triangle whose
    /// shape could decide it. With three vertices `chooseTriangle` is used instead.
    static func place(pixel x: SIMD2<Double>, ankle aPin: SIMD3<Double>, radius: Double,
                      K: CameraIntrinsics, prefer: SIMD3<Double>?, tolerance: Double)
        -> (point: SIMD3<Double>, clamped: Bool)?
    {
        let d = K.ray(x)
        let hits = rayMeetsSphere(direction: d, centre: aPin, radius: radius)
        if hits.isEmpty {
            let (depth, distance) = closestApproach(direction: d, centre: aPin)
            guard depth > 1e-6, distance <= radius * (1 + tolerance) else { return nil }
            let v = depth * d - aPin
            let n = simd_length(v)
            guard n > 1e-9 else { return nil }
            return (aPin + v / n * radius, true)
        }
        if let prefer {
            let want = prefer.z - aPin.z
            let best = hits.min { abs(($0 * d).z - aPin.z - want) < abs(($1 * d).z - aPin.z - want) } ?? hits[0]
            return (best * d, false)
        }
        let best = hits.min { abs(($0 * d).z - aPin.z) < abs(($1 * d).z - aPin.z) } ?? hits[0]
        return (best * d, false)
    }

    /// The rotation that carries the prior's own triangle onto the three placed vertices, about the
    /// fitted ankle. Orthogonal Procrustes done by Gram–Schmidt rather than an SVD (ShotGeometry is
    /// Foundation + simd, and simd has no SVD): build an orthonormal frame from ankle→heel and
    /// ankle→mid-toe in both the prior's coordinates and the placed points', and `R = B · Aᵀ`.
    /// Exact when the three points really are the prior's triangle, and the least-squares answer to
    /// first order when they are not — which is the case this exists to measure.
    static func rigidRotation(localHeel: SIMD3<Double>, localMidToe: SIMD3<Double>,
                              heel: SIMD3<Double>, midToe: SIMD3<Double>) -> simd_double3x3? {
        func frame(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> simd_double3x3? {
            let la = simd_length(a)
            guard la > 1e-9 else { return nil }
            let e1 = a / la
            let r = b - simd_dot(b, e1) * e1
            let lr = simd_length(r)
            guard lr > 1e-9 else { return nil }
            let e2 = r / lr
            return simd_double3x3(columns: (e1, e2, simd_cross(e1, e2)))
        }
        guard let A = frame(localHeel, localMidToe), let B = frame(heel, midToe) else { return nil }
        return B * A.transpose
    }

    /// Resolve the three vertices' two-fold depth ambiguities **together**, by the prior's shape.
    ///
    /// Each vertex has at most two candidate depths, so there are at most eight triangles. Seven of
    /// them are reflections that no rigid foot of the prior's shape can be, and the eighth is the
    /// answer: score each by the rigid triangle's own reprojection (the prior's shape rotated onto
    /// the candidate and projected back at the three landmarks) and keep the best. An upside-down
    /// foot is rejected outright — a foot on a court has its sole toward the floor — and the previous
    /// frame breaks a tie, because a foot does not flip through its own ankle in 4 ms.
    ///
    /// This is what makes `reprojectionPixels` mean something: it is minimised over a *discrete*
    /// ambiguity the camera genuinely cannot see, and what is left is the prior's shape being wrong.
    static func chooseTriangle(heel: [(point: SIMD3<Double>, clamped: Bool)],
                               bigToe: [(point: SIMD3<Double>, clamped: Bool)],
                               littleToe: [(point: SIMD3<Double>, clamped: Bool)],
                               ankle: SIMD3<Double>, prior: FootSizePrior, side: FootSide,
                               pixels: (h: SIMD2<Double>, b: SIMD2<Double>, l: SIMD2<Double>),
                               K: CameraIntrinsics,
                               previous: (heel: SIMD3<Double>?, big: SIMD3<Double>?, little: SIMD3<Double>?))
        -> (heel: (point: SIMD3<Double>, clamped: Bool), bigToe: (point: SIMD3<Double>, clamped: Bool),
            littleToe: (point: SIMD3<Double>, clamped: Bool), reprojection: Double)?
    {
        let aL = prior.ankleLocal
        let lh = prior.heelLocal, lb = prior.bigToeLocal(side: side), ll = prior.littleToeLocal(side: side)
        var best: (h: (point: SIMD3<Double>, clamped: Bool), b: (point: SIMD3<Double>, clamped: Bool),
                   l: (point: SIMD3<Double>, clamped: Bool), score: Double, rms: Double)? = nil
        for h in heel {
            for b in bigToe {
                for l in littleToe {
                    guard let R = rigidRotation(localHeel: lh - aL, localMidToe: (lb + ll) / 2 - aL,
                                                heel: h.point - ankle, midToe: (b.point + l.point) / 2 - ankle)
                    else { continue }
                    // An upside-down foot is not a foot. `axes` works in the pinhole frame here, so
                    // "up" is −y; the test is on the Vision-space vector.
                    if let a = axes(heel: h.point, bigToe: b.point, littleToe: l.point, side: side),
                       visionCamera(a.footUp).y < -0.5 { continue }
                    var sq = 0.0, n = 0
                    for (local, seen) in [(lh, pixels.h), (lb, pixels.b), (ll, pixels.l)] {
                        let p = ankle + R * (local - aL)
                        guard p.z > 1e-6 else { continue }
                        sq += simd_length_squared(K.pixel(fromNormalized: SIMD2(p.x / p.z, p.y / p.z)) - seen); n += 1
                    }
                    guard n == 3 else { continue }
                    let rms = (sq / 3).squareRoot()
                    // The rigid reprojection alone is **not** enough to choose by: the rigid triangle
                    // is built from the heel and the *mid*-toe, so splitting the two toes onto
                    // opposite depth branches leaves it unchanged while pulling them metres apart.
                    // Measured on the 240 fps clip that degenerate minimum won on every frame and
                    // reported a 31 cm toe span. So the candidate's own edges are scored too, against
                    // the prior's, and everything is scored in **metres** so the three terms are
                    // commensurate: pixels are converted at the ankle's own depth.
                    let edges = prior.edges(side: side)
                    let shapeError = abs(simd_length(b.point - l.point) - edges.toeSpan)
                                   + abs(simd_length(b.point - h.point) - edges.heelToBigToe)
                    let metresPerPixel = ankle.z / max(1e-9, K.fx)
                    var score = rms * metresPerPixel + shapeError
                    // Continuity: a foot does not flip through its own ankle in 4 ms.
                    if let ph = previous.heel, let pb = previous.big, let pl = previous.little {
                        score += 0.25 * (simd_length(h.point - ph) + simd_length(b.point - pb) + simd_length(l.point - pl)) / 3
                    }
                    if best == nil || score < best!.score { best = (h, b, l, score, rms) }
                }
            }
        }
        guard let best else { return nil }
        return (best.h, best.b, best.l, best.rms)
    }

    /// The foot's own axes from the three vertices, in **camera space** (Vision's convention).
    ///
    /// Build a right-handed foot frame: `f` forward (heel → mid-toe), `ℓ` to the foot's own left,
    /// `u` out of the top of the foot, with `u = f × ℓ`. The big toe is **medial** — on the foot's
    /// right for the left foot, on its left for the right — so `across = bigToe − littleToe` is
    /// `−ℓ` on the left foot and `+ℓ` on the right. Hence the two cases below. Returns nil when the
    /// three points are collinear: a triangle seen exactly edge-on has no up, and saying so is the
    /// honest answer.
    public static func axes(heel h: SIMD3<Double>, bigToe b: SIMD3<Double>, littleToe l: SIMD3<Double>,
                            side: FootSide) -> (pointing: SIMD3<Double>, footUp: SIMD3<Double>)? {
        let mid = (b + l) / 2
        let f = mid - h
        let across = b - l
        let up = side == .left ? simd_cross(across, f) : simd_cross(f, across)
        let lf = simd_length(f), lu = simd_length(up), la = simd_length(across)
        guard lf > 1e-9, lu > 1e-9, la > 1e-9, lu / (la * lf) > 1e-3 else { return nil }
        return (f / lf, up / lu)
    }

    /// Roll: the rotation of `footUp` about `pointing`, measured from the part of `up` perpendicular
    /// to `pointing`. Nil when the foot points along `up` — straight at the sky — where there is no
    /// such reference and a roll would be an artefact of the convention.
    public static func roll(pointing f: SIMD3<Double>, footUp n: SIMD3<Double>,
                            up: SIMD3<Double> = SIMD3(0, 1, 0)) -> BodyMeasure {
        let upPerp = up - simd_dot(up, f) * f
        let m = simd_length(upPerp)
        guard m > 1e-3 else {
            return .missing(.radians, "the foot points within 0.06° of the camera's up axis, where a roll about that axis has no reference direction to be measured from")
        }
        let r = upPerp / m
        let s = simd_cross(r, f)
        return .ok(atan2(simd_dot(n, s), simd_dot(n, r)), .radians)
    }

    /// The foot's yaw in the camera's horizontal plane, measured from the camera's optical axis
    /// (0 = pointing straight away from the camera, positive toward camera-right). In Vision camera
    /// space the optical axis away from the camera is −z and camera-right is +x.
    ///
    /// The horizontal plane here is the camera's, which is the world's only for a level camera —
    /// the same caveat `BodyKinematics` carries for every "up".
    public static func yawFromCameraAxis(pointing f: SIMD3<Double>) -> BodyMeasure {
        let horizontal = SIMD2(f.x, -f.z)
        guard simd_length(horizontal) > 1e-3 else {
            return .missing(.radians, "the foot points within 0.06° of vertical in the camera's frame, so it has no horizontal bearing to measure a yaw with")
        }
        return .ok(atan2(horizontal.x, horizontal.y), .radians)
    }

    /// The bearing, as the same kind of yaw, of a point at image column `u` — the direction from the
    /// **camera** to it, in the camera's horizontal plane.
    public static func bearingFromCameraAxis(imageU u: Double, K: CameraIntrinsics) -> Double {
        atan2((u - K.cx) / K.fx, 1)
    }

    // MARK: - The pass

    /// Foot triangles for one window, from a finished skeleton fit.
    ///
    /// - Parameters:
    ///   - timeline: the fitted timeline (`BodySkeletonFitResult.timeline`). `joints3D` supplies the
    ///     ankle the plate hangs on; `points2D` supplies the six foot landmarks.
    ///   - releaseRealTime / setRealTime: the instants the per-shot measures are read at.
    public static func run(timeline: BodyTimeline, releaseRealTime: Double, setRealTime: Double?,
                           options o: FootTriangleOptions) -> FootTriangleResult {
        var notes: [String] = [], warnings: [String] = []
        let frames = timeline.frames.sorted { $0.realTime < $1.realTime }

        guard let stature = o.stature, stature > 0 else {
            let why = "no stature was given, and the foot triangle's size is a stature-scaled population prior: without one there is nothing to scale it by"
            return FootTriangleResult(timeline: timeline, tracks: [], measures: .unavailable(why),
                                      notes: [], warnings: [why])
        }
        let prior = FootSizePrior(stature: stature, statureProvenance: o.statureProvenance)
        notes.append(prior.note)

        var tracks: [FootTriangleTrack] = []
        var fittedJoints: [Int: [String: SIMD3<Double>]] = [:]     // frame index → name → camera space

        for side in FootSide.allCases {
            let radii = prior.radii(side: side)
            let edges = prior.edges(side: side)
            let ankleName = side == .left ? Body3DJoint.leftAnkle : Body3DJoint.rightAnkle
            let heelName = side == .left ? Body2DPoint.leftHeel : Body2DPoint.rightHeel
            let bigName = side == .left ? Body2DPoint.leftBigToe : Body2DPoint.rightBigToe
            let littleName = side == .left ? Body2DPoint.leftLittleToe : Body2DPoint.rightLittleToe

            var out: [FootTriangleFrame] = []
            var detected = 0
            var previous: (heel: SIMD3<Double>?, big: SIMD3<Double>?, little: SIMD3<Double>?) = (nil, nil, nil)

            for f in frames {
                let saw = [heelName, bigName, littleName].filter { f.points2D[$0] != nil }
                if saw.count == 3 { detected += 1 }
                guard let ankleJoint = f.joints3D[ankleName] else { continue }
                let ankleCam = ankleJoint.cameraPosition
                let ankle = pinhole(ankleCam)

                var refused: [String: String] = [:]
                var confidences: [String: Double] = [:]
                func observation(_ name: String) -> SIMD2<Double>? {
                    guard let p = f.points2D[name] else { return nil }
                    confidences[name] = p.confidence
                    guard p.confidence >= o.minimumFootConfidence else {
                        refused[name] = String(format: "the foot detector's confidence was %.2f, under the %.2f floor", p.confidence, o.minimumFootConfidence)
                        return nil
                    }
                    return p.uv
                }
                let xh = observation(heelName), xb = observation(bigName), xl = observation(littleName)

                var clamped: [String] = []
                func vertex(_ x: SIMD2<Double>?, _ r: Double, _ name: String, _ prefer: SIMD3<Double>?) -> SIMD3<Double>? {
                    guard let x else { return nil }
                    guard let p = place(pixel: x, ankle: ankle, radius: r, K: o.intrinsics,
                                        prefer: prefer, tolerance: o.rayMissTolerance) else {
                        refused[name] = String(format: "its view ray passed more than %.0f %% of the prior's %.3f radius away from the fitted ankle, so no point on the prior's sphere lies on it", 100 * o.rayMissTolerance, r)
                        return nil
                    }
                    if p.clamped { clamped.append(name) }
                    return p.point
                }
                // With all three landmarks the depth ambiguity is settled once for the whole
                // triangle, by the prior's shape (`chooseTriangle`); with two there is no shape to
                // settle it with and each falls back on the previous frame.
                var ph: SIMD3<Double>?, pb: SIMD3<Double>?, pl: SIMD3<Double>?
                var chosenRMS: Double? = nil
                if let xh, let xb, let xl,
                   case let ch = candidates(pixel: xh, ankle: ankle, radius: radii.heel, K: o.intrinsics, tolerance: o.rayMissTolerance),
                   case let cb = candidates(pixel: xb, ankle: ankle, radius: radii.bigToe, K: o.intrinsics, tolerance: o.rayMissTolerance),
                   case let cl = candidates(pixel: xl, ankle: ankle, radius: radii.littleToe, K: o.intrinsics, tolerance: o.rayMissTolerance),
                   let pick = chooseTriangle(heel: ch, bigToe: cb, littleToe: cl, ankle: ankle,
                                             prior: prior, side: side, pixels: (xh, xb, xl),
                                             K: o.intrinsics, previous: previous) {
                    ph = pick.heel.point; pb = pick.bigToe.point; pl = pick.littleToe.point
                    chosenRMS = pick.reprojection
                    if pick.heel.clamped { clamped.append(heelName) }
                    if pick.bigToe.clamped { clamped.append(bigName) }
                    if pick.littleToe.clamped { clamped.append(littleName) }
                } else {
                    ph = vertex(xh, radii.heel, heelName, previous.heel)
                    pb = vertex(xb, radii.bigToe, bigName, previous.big)
                    pl = vertex(xl, radii.littleToe, littleName, previous.little)
                }
                let used = [ph, pb, pl].compactMap { $0 }.count
                guard used >= 2 else { continue }
                previous = (ph ?? previous.heel, pb ?? previous.big, pl ?? previous.little)

                // ---- orientation ----------------------------------------------------------------
                // `axes` and `place` work in the pinhole frame; `roll` and `yawFromCameraAxis` are
                // defined in Vision's. Convert here, once, and every angle below is in one frame.
                var pointing: SIMD3<Double>? = nil
                var footUp: SIMD3<Double>? = nil
                var roll: BodyMeasure = .missing(.radians, "fewer than three foot landmarks were confident on this frame, so the foot has no across-axis and no roll")
                if let ph, let pb, let pl, let a = axes(heel: ph, bigToe: pb, littleToe: pl, side: side) {
                    pointing = visionCamera(a.pointing); footUp = visionCamera(a.footUp)
                } else if let ph, let pb {
                    pointing = visionCamera(simd_normalize(pb - ph))
                } else if let ph, let pl {
                    pointing = visionCamera(simd_normalize(pl - ph))
                }

                // ---- the toe pair in the image, which is what roll actually costs ----------------
                var toePair: BodyMeasure = .missing(.pixels, "one of the two toe landmarks was not confident on this frame")
                if let xb, let xl {
                    let sep = simd_length(xb - xl)
                    toePair = .ok(sep, .pixels)
                    if sep < o.minimumToePairPixels {
                        roll = .missing(.radians, String(format: "the big and little toe landmarks are %.1f px apart in the image, under the %.1f px floor: at that separation the two view rays are closer together than the detector's own error and any roll read from them would be noise", sep, o.minimumToePairPixels))
                        footUp = nil
                    } else if let pointing, let footUp {
                        roll = self.roll(pointing: pointing, footUp: footUp)
                    }
                } else if let pointing, let footUp {
                    roll = self.roll(pointing: pointing, footUp: footUp)
                }

                // ---- reprojection of the **rigid** triangle ------------------------------------
                // Not of the placed points: those sit on their own rays by construction and would
                // report 0.00 px on every frame, which is a tautology, not a measurement.
                var reprojection: BodyMeasure = .missing(.pixels, "the rigid triangle needs all three vertices placed before it can be reprojected")
                if let chosenRMS { reprojection = .ok(chosenRMS, .pixels) }
                else if let ph, let pb, let pl, let xh, let xb, let xl {
                    let aL = prior.ankleLocal
                    let lh = prior.heelLocal - aL
                    let lmid = (prior.bigToeLocal(side: side) + prior.littleToeLocal(side: side)) / 2 - aL
                    if let R = rigidRotation(localHeel: lh, localMidToe: lmid,
                                             heel: ph - ankle, midToe: (pb + pl) / 2 - ankle) {
                        var sq = 0.0, n = 0
                        for (local, seen) in [(prior.heelLocal, xh),
                                              (prior.bigToeLocal(side: side), xb),
                                              (prior.littleToeLocal(side: side), xl)] {
                            let p = ankle + R * (local - aL)
                            guard p.z > 1e-6 else { continue }
                            let q = o.intrinsics.pixel(fromNormalized: SIMD2(p.x / p.z, p.y / p.z))
                            sq += simd_length_squared(q - seen); n += 1
                        }
                        if n > 0 { reprojection = .ok((sq / Double(n)).squareRoot(), .pixels) }
                    }
                }
                let lengthResidual: BodyMeasure = (ph != nil && pb != nil && edges.heelToBigToe > 0)
                    ? .ok(simd_length(pb! - ph!) / edges.heelToBigToe - 1, .ratio)
                    : .missing(.ratio, "the heel and the big toe were not both placed on this frame")
                let widthResidual: BodyMeasure = (pb != nil && pl != nil && edges.toeSpan > 0)
                    ? .ok(simd_length(pb! - pl!) / edges.toeSpan - 1, .ratio)
                    : .missing(.ratio, "the two toes were not both placed on this frame")

                let yaw = pointing.map { yawFromCameraAxis(pointing: $0) }
                    ?? .missing(.radians, "the foot's long axis was not recovered on this frame")

                // How long the foot's own axis is *in the image*, and what a ±1 px landmark error
                // does to the yaw. A foot pointing at the camera projects short, and a short
                // projection is what makes a yaw swing; this is the number that says so.
                var pointingPixels: BodyMeasure = .missing(.pixels, "the heel and at least one toe must both be seen before the foot's axis has an image length")
                if let xh, let xb0 = xb ?? xl {
                    let midImage = (xb != nil && xl != nil) ? (xb! + xl!) / 2 : xb0
                    pointingPixels = .ok(simd_length(midImage - xh), .pixels)
                }
                var yawSigma: BodyMeasure = .missing(.radians, "the yaw's own uncertainty needs all three landmarks, so the whole triangle can be refitted with each of them moved")
                if let xh, let xb, let xl, yaw.isAvailable {
                    var lo = Double.infinity, hi = -Double.infinity
                    for (i, delta) in [SIMD2(1.0, 0.0), SIMD2(-1.0, 0.0), SIMD2(0.0, 1.0), SIMD2(0.0, -1.0)].enumerated() {
                        _ = i
                        for which in 0..<3 {
                            let ah = which == 0 ? xh + delta : xh
                            let ab = which == 1 ? xb + delta : xb
                            let al = which == 2 ? xl + delta : xl
                            guard let pick = chooseTriangle(
                                    heel: candidates(pixel: ah, ankle: ankle, radius: radii.heel, K: o.intrinsics, tolerance: o.rayMissTolerance),
                                    bigToe: candidates(pixel: ab, ankle: ankle, radius: radii.bigToe, K: o.intrinsics, tolerance: o.rayMissTolerance),
                                    littleToe: candidates(pixel: al, ankle: ankle, radius: radii.littleToe, K: o.intrinsics, tolerance: o.rayMissTolerance),
                                    ankle: ankle, prior: prior, side: side, pixels: (ah, ab, al),
                                    K: o.intrinsics, previous: (ph, pb, pl)),
                                  let a = axes(heel: pick.heel.point, bigToe: pick.bigToe.point,
                                               littleToe: pick.littleToe.point, side: side),
                                  let y = yawFromCameraAxis(pointing: visionCamera(a.pointing)).value else { continue }
                            lo = min(lo, y); hi = max(hi, y)
                        }
                    }
                    if lo.isFinite, hi > lo {
                        yawSigma = .ok(wrapToPi(hi - lo) / 2, .radians)
                    }
                }

                // ---- heel and toe height, in camera-up above the ankle --------------------------
                // Heights above *the floor* need the floor, which the per-shot pass supplies; what a
                // frame can say on its own is each vertex's height relative to the fitted ankle.
                let heelHeight: BodyMeasure = ph.map { .ok(visionCamera($0).y - ankleCam.y, .metres) }
                    ?? .missing(.metres, "the heel was not placed on this frame")
                let midToe: SIMD3<Double>? = (pb != nil && pl != nil) ? (pb! + pl!) / 2 : (pb ?? pl)
                let toeHeight: BodyMeasure = midToe.map { .ok(visionCamera($0).y - ankleCam.y, .metres) }
                    ?? .missing(.metres, "neither toe was placed on this frame")

                out.append(FootTriangleFrame(
                    realTime: f.realTime, frameIndex: f.frameIndex, side: side.rawValue,
                    ankle: ankleCam,
                    heel: ph.map(visionCamera), bigToe: pb.map(visionCamera), littleToe: pl.map(visionCamera),
                    // Already Vision-space: converted the moment they were built, so that every
                    // angle derived from them is measured in one frame.
                    pointing: pointing, footUp: footUp,
                    roll: roll, yawFromCameraAxis: yaw,
                    heelHeight: heelHeight, toeHeight: toeHeight,
                    toePairPixels: toePair, reprojectionPixels: reprojection,
                    pointingImagePixels: pointingPixels, yawSigmaFromPixelNoise: yawSigma,
                    lengthResidual: lengthResidual, widthResidual: widthResidual,
                    pointsUsed: used, confidences: confidences, clampedPoints: clamped, refusedPoints: refused))

                var add3D: [String: SIMD3<Double>] = [:]
                if let ph { add3D[heelName] = visionCamera(ph) }
                if let pb { add3D[bigName] = visionCamera(pb) }
                if let pl { add3D[littleName] = visionCamera(pl) }
                if !add3D.isEmpty { fittedJoints[f.frameIndex, default: [:]].merge(add3D) { a, _ in a } }
            }

            var why: String? = nil
            if out.isEmpty {
                why = detected == 0
                    ? "the foot detector returned no \(side.rawValue) heel/toe landmark on any frame of this window"
                    : "the \(side.rawValue) foot's landmarks were seen on \(detected) frame(s) but never with both a confident pair and a fitted ankle to hang the triangle on"
            }
            tracks.append(FootTriangleTrack(side: side.rawValue, prior: prior, frames: out,
                                            framesInWindow: frames.count, framesDetected: detected,
                                            unavailableReason: why, notes: []))
        }

        // ---- write the fitted vertices back into the timeline's 3-D joints ----------------------
        var fitted = timeline
        for i in fitted.frames.indices {
            guard let add = fittedJoints[fitted.frames[i].frameIndex] else { continue }
            for (name, p) in add {
                let px = o.intrinsics.pixel(fromNormalized: SIMD2(pinhole(p).x / max(1e-9, pinhole(p).z),
                                                                  pinhole(p).y / max(1e-9, pinhole(p).z)))
                fitted.frames[i].joints3D[name] = BodyJoint3D(
                    name: name, position: p - (fitted.frames[i].joints3D[Body3DJoint.root]?.cameraPosition ?? .zero),
                    cameraPosition: p, imageU: px.x, imageV: px.y,
                    confidence: fitted.frames[i].points2D[name]?.confidence)
            }
        }

        let measures = shotMeasures(tracks: tracks, timeline: fitted, releaseRealTime: releaseRealTime,
                                    setRealTime: setRealTime, o: o, notes: &notes, warnings: &warnings)
        let withOrientation = tracks.reduce(0) { $0 + $1.framesWithOrientation }
        let withRoll = tracks.reduce(0) { $0 + $1.framesWithRoll }
        notes.append("foot triangles: \(tracks.map { "\($0.side) \($0.frames.count)/\($0.framesInWindow)" }.joined(separator: ", ")) frames fitted; \(withOrientation) carried all three vertices and \(withRoll) carried a roll")
        return FootTriangleResult(timeline: fitted, tracks: tracks, measures: measures,
                                  notes: notes, warnings: warnings)
    }

    // MARK: - Per-shot measures

    static func shotMeasures(tracks: [FootTriangleTrack], timeline: BodyTimeline,
                             releaseRealTime: Double, setRealTime: Double?,
                             o: FootTriangleOptions, notes: inout [String], warnings: inout [String]) -> FootShotMeasures {
        guard let set = setRealTime else {
            return .unavailable("the body model found no set instant, and the foot angle is defined at the set — the last frame before the lift, when the stance is what the shooter chose")
        }
        guard let rimU = o.rimImageU else {
            return .unavailable("no rim image column was given, so the foot's yaw is known (FootTriangleFrame.yawFromCameraAxis) but the direction it should be measured against is not")
        }
        let rimBearing = bearingFromCameraAxis(imageU: rimU, K: o.intrinsics)

        // Parallax: the rim's bearing from the camera is the shot line only when the shooter stands
        // on the camera→rim line. Publish the gap rather than pretend it is zero.
        var shooterBearing: Double? = nil
        if let f = timeline.frames.min(by: { abs($0.realTime - set) < abs($1.realTime - set) }),
           abs(f.realTime - set) <= max(o.instantToleranceSeconds, o.setWindowSeconds) {
            let us = [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle].compactMap { f.points2D[$0]?.u }
            if !us.isEmpty { shooterBearing = bearingFromCameraAxis(imageU: us.reduce(0, +) / Double(us.count), K: o.intrinsics) }
        }
        let parallax: BodyMeasure = shooterBearing.map { .ok(abs(rimBearing - $0), .radians) }
            ?? .missing(.radians, "no confident ankle at the set, so the shooter's own bearing — and with it the parallax between it and the rim's — could not be measured")

        func angles(_ track: FootTriangleTrack) -> [Double] {
            track.frames
                .filter { abs($0.realTime - set) <= o.setWindowSeconds }
                .compactMap { $0.yawFromCameraAxis.value }
                .map { wrapToPi($0 - rimBearing) }
        }
        let shooting: FootSide? = o.shootingSide?.lowercased() == "left" ? .left
            : (o.shootingSide?.lowercased() == "right" ? .right : nil)

        func measure(_ side: FootSide?) -> (BodyMeasure, BodyMeasure, [Double]) {
            guard let side, let track = tracks.first(where: { $0.side == side.rawValue }) else {
                return (.missing(.radians, "no shooting side was stated, so which foot is the shooting-side foot is unknown"),
                        .missing(.radians, "no shooting side was stated"), [])
            }
            let xs = angles(track)
            guard !xs.isEmpty else {
                let why = track.unavailableReason
                    ?? String(format: "no %@ foot triangle fell within %.0f ms of the set", side.rawValue, 1000 * o.setWindowSeconds)
                return (.missing(.radians, why), .missing(.radians, why), [])
            }
            let mean = xs.reduce(0, +) / Double(xs.count)
            let sigma = xs.count >= 2
                ? (xs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(xs.count - 1)).squareRoot()
                : Double.nan
            return (.ok(mean, .radians),
                    sigma.isFinite ? .ok(sigma, .radians)
                                   : .missing(.radians, "only one frame fell inside the set window, so there is no spread to take a σ from"),
                    xs)
        }
        let (a1, s1, xs1) = measure(shooting)
        let (a2, _, xs2) = measure(shooting?.other)
        let openness: BodyMeasure = (!xs1.isEmpty && !xs2.isEmpty)
            ? .ok(abs(wrapToPi(xs1.reduce(0, +) / Double(xs1.count) - xs2.reduce(0, +) / Double(xs2.count))), .radians)
            : .missing(.radians, "both feet need a triangle at the set before the stance's openness is defined")

        let provenance = "the foot's long axis (heel → mid-toe) from the fitted triangle, against the **camera's** bearing to the rim's image column. The two agree exactly only when the shooter stands on the camera→rim line; `rimBearingParallax` is how far this shot is from that. Both are read in the camera's horizontal plane, which is the world's only for a level camera. The foot's size is a population prior (see FootSizePrior.note), so this is an orientation fitted to two view rays, not a measured foot."

        // The propagated σ, and the image length the yaw is conditioned on, over the same window.
        func medianOverSet(_ pick: (FootTriangleFrame) -> Double?) -> Double? {
            guard let side = shooting, let track = tracks.first(where: { $0.side == side.rawValue }) else { return nil }
            let xs = track.frames.filter { abs($0.realTime - set) <= o.setWindowSeconds }.compactMap(pick).sorted()
            guard !xs.isEmpty else { return nil }
            return xs[xs.count / 2]
        }
        let pixelSigma: BodyMeasure = medianOverSet { $0.yawSigmaFromPixelNoise.value }
            .map { .ok($0, .radians) }
            ?? .missing(.radians, "no frame in the set window carried all three landmarks, so the yaw's own ±1 px uncertainty could not be propagated")
        let pointingPx: BodyMeasure = medianOverSet { $0.pointingImagePixels.value }
            .map { .ok($0, .pixels) }
            ?? .missing(.pixels, "no frame in the set window carried a heel and a toe, so the foot's axis has no image length")

        return FootShotMeasures(footAngleToRimAtSet: a1, otherFootAngleToRimAtSet: a2,
                                stanceOpennessAtSet: openness, footAngleSigmaAtSet: s1,
                                footAnglePixelNoiseSigmaAtSet: pixelSigma,
                                footPointingPixelsAtSet: pointingPx,
                                rimBearingParallax: parallax, footAngleProvenance: provenance,
                                strikes: [], notes: [])
    }

    static func wrapToPi(_ a: Double) -> Double {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x < -.pi { x += 2 * .pi }
        return x
    }
}

// MARK: - Heel-first / toe-first, from the image alone

extension FootTriangleFit {

    /// Which part of the foot reached the floor first, per touchdown.
    ///
    /// This one is **not** read off the 3-D plate on purpose. `FootworkMetrics`' file header sets
    /// out why: the ankle's *image row* is the thing a single camera measures to 1–2 px, while its
    /// depth is the thing it cannot measure at all, so a contact order taken from fitted depth would
    /// look precise and be fiction. What is used instead is the heel's and the mid-toe's own image
    /// rows at the touchdown instant, differenced, in the shooter's own stature units — exactly the
    /// ruler every other footwork length uses.
    ///
    /// Sign: image v increases **downwards**, so `heel v − toe v` positive means the heel is *lower*
    /// in the image, i.e. the heel was down first.
    public static func strikes(timeline: BodyTimeline, contacts: [FootContact],
                               statureImagePixels: Double, liftRealTime: Double?,
                               releaseRealTime: Double,
                               flatBandStature: Double = 0.006,
                               minimumConfidence: Double = 0.35) -> [FootStrikeEvent] {
        let cutoff = liftRealTime ?? releaseRealTime
        let frames = timeline.frames.sorted { $0.realTime < $1.realTime }
        var out: [FootStrikeEvent] = []
        for c in contacts where c.isTouchdown && c.startRealTime <= cutoff + 1e-9 {
            let side: FootSide = c.foot
            let heelName = side == .left ? Body2DPoint.leftHeel : Body2DPoint.rightHeel
            let bigName = side == .left ? Body2DPoint.leftBigToe : Body2DPoint.rightBigToe
            let littleName = side == .left ? Body2DPoint.leftLittleToe : Body2DPoint.rightLittleToe
            guard let f = frames.min(by: { abs($0.realTime - c.startRealTime) < abs($1.realTime - c.startRealTime) }),
                  abs(f.realTime - c.startRealTime) <= 0.02 else {
                out.append(FootStrikeEvent(foot: side.rawValue, touchdownRealTime: c.startRealTime,
                                           strike: FootStrike.unknown.rawValue,
                                           heelMinusToeStature: .missing(.ratio, "no analysed frame fell within 20 ms of this touchdown"),
                                           unavailableReason: "no analysed frame fell within 20 ms of this touchdown"))
                continue
            }
            func v(_ n: String) -> Double? {
                guard let p = f.points2D[n], p.confidence >= minimumConfidence else { return nil }
                return p.v
            }
            guard let heelV = v(heelName) else {
                let why = "the foot detector did not return a confident \(side.rawValue) heel at this touchdown, so which part of the foot landed first cannot be read"
                out.append(FootStrikeEvent(foot: side.rawValue, touchdownRealTime: c.startRealTime,
                                           strike: FootStrike.unknown.rawValue,
                                           heelMinusToeStature: .missing(.ratio, why), unavailableReason: why))
                continue
            }
            let toes = [v(bigName), v(littleName)].compactMap { $0 }
            guard !toes.isEmpty else {
                let why = "the foot detector did not return a confident \(side.rawValue) toe at this touchdown"
                out.append(FootStrikeEvent(foot: side.rawValue, touchdownRealTime: c.startRealTime,
                                           strike: FootStrike.unknown.rawValue,
                                           heelMinusToeStature: .missing(.ratio, why), unavailableReason: why))
                continue
            }
            let d = (heelV - toes.reduce(0, +) / Double(toes.count)) / statureImagePixels
            let strike: FootStrike = abs(d) <= flatBandStature ? .flat : (d > 0 ? .heelFirst : .toeFirst)
            out.append(FootStrikeEvent(foot: side.rawValue, touchdownRealTime: c.startRealTime,
                                       strike: strike.rawValue, heelMinusToeStature: .ok(d, .ratio),
                                       unavailableReason: nil))
        }
        return out
    }
}

// MARK: - The export record (additive: BodyShotExport.swift needs two lines, listed below)

/// One foot's plate on one frame, in the BodyShot schema's own vocabulary — the exact mirror of
/// `BodyShotHandTriangle`, so a reader that already handles hand plates handles these unchanged.
///
/// **This type lives here, not in `BodyShotExport.swift`, on purpose**: Track B was editing that
/// file for the hand triangle while this was written. Folding the feet into the export needs
/// precisely two edits there, and nothing else:
///
///   1. in `BodyShotFrame`, next to `handTriangles`:
///        `public var footTriangles: [BodyShotFootTriangle]?`
///      plus the matching `footTriangles: [BodyShotFootTriangle]? = nil` init parameter and
///      `self.footTriangles = footTriangles`;
///   2. where the frame is built, next to where `handTriangles` is filled:
///        `footTriangles: footTracks.compactMap { BodyShotFootTriangle($0.nearest(f.realTime, within: tol)) }`
///      (or, equivalently, a per-frame lookup on the `[FootTriangleTrack]` that `FootTriangleFit.run`
///      returned for this shot).
///
/// Schema note for whoever makes that edit: this is additive, so the schema minor version goes up
/// and no existing reader breaks.
public struct BodyShotFootTriangle: Sendable, Codable, Equatable {
    /// left | right — the shooter's own side.
    public var side: String
    public var ankle: BodyShotFitted3D
    public var heel: BodyShotFitted3D?
    public var bigToe: BodyShotFitted3D?
    public var littleToe: BodyShotFitted3D?
    /// Heel → the midpoint of the toes. Absent when the foot's long axis was not recovered.
    public var pointing: [Double]?
    /// Out of the **top** of the foot. Absent whenever fewer than three points were confident, or
    /// the two toes were too close together in the image to define an across-axis.
    public var footUp: [Double]?
    /// Radians. Absent with a reason — including "the toes are N px apart", which is the usual one.
    public var roll: BodyShotMeasure
    /// The foot's yaw from the camera's optical axis, radians. Needs no rim.
    public var yawFromCameraAxis: BodyShotMeasure
    /// 3 = heel and both toes; 2 = heel and one toe, pointing only, no roll.
    public var pointsUsed: Int
    /// Vertices whose view ray missed the size prior's sphere and were taken at its surface.
    public var clamped: [String]
    /// Landmarks the detector returned but the confidence gate refused, with the number that did it.
    public var refused: [String: String]
    /// RMS pixels between the **rigid** prior triangle and the three landmarks. Not of the placed
    /// points: those sit on their own rays and would be identically zero.
    public var reprojectionPixels: BodyShotMeasure
    /// Image separation of the two toe landmarks, pixels — what the roll is conditioned on.
    public var toePairPixels: BodyShotMeasure
    /// ‖heel − big toe‖ ÷ the prior's own edge − 1, and the same across the toes.
    public var lengthResidual: BodyShotMeasure
    public var widthResidual: BodyShotMeasure

    /// Nil in, nil out, so the call site is one `compactMap`.
    public init?(_ f: FootTriangleFrame?) {
        guard let f else { return nil }
        func p(_ v: SIMD3<Double>?) -> BodyShotFitted3D? { v.map { BodyShotFitted3D(x: $0.x, y: $0.y, z: $0.z) } }
        side = f.side
        ankle = BodyShotFitted3D(x: f.ankle.x, y: f.ankle.y, z: f.ankle.z)
        heel = p(f.heel); bigToe = p(f.bigToe); littleToe = p(f.littleToe)
        pointing = f.pointing.map { [$0.x, $0.y, $0.z] }
        footUp = f.footUp.map { [$0.x, $0.y, $0.z] }
        roll = BodyShotMeasure(f.roll, provenance: "the rotation of the foot's up about its long axis, from the camera's up")
        yawFromCameraAxis = BodyShotMeasure(f.yawFromCameraAxis,
                                            provenance: "the foot's bearing in the camera's horizontal plane, 0 = pointing away from the camera",
                                            sigma: f.yawSigmaFromPixelNoise.value)
        pointsUsed = f.pointsUsed
        clamped = f.clampedPoints
        refused = f.refusedPoints
        reprojectionPixels = BodyShotMeasure(f.reprojectionPixels,
                                             provenance: "the prior's own triangle rotated onto the placed vertices and projected back")
        toePairPixels = BodyShotMeasure(f.toePairPixels, provenance: "the two toe landmarks' image separation")
        lengthResidual = BodyShotMeasure(f.lengthResidual, provenance: "against the size prior")
        widthResidual = BodyShotMeasure(f.widthResidual, provenance: "against the size prior")
    }
}
