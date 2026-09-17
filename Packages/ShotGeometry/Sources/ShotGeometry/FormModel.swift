import Foundation
import simd

// ================================================================================================
// MARK: - The 3-D form model
// ================================================================================================
//
// `BodySkeletonFit` gives one shot's skeleton: fitted 3-D joints per frame, in camera metres, with
// constant bone lengths (`docs/PHASE2-PREP.md`, "Body model, iteration 2"). That is a *shot*. This
// file turns it into a **form**: the same shot expressed in the shooter's own frame and on a
// phase-normalised clock, so two shots of different tempo can be laid on top of each other, and
// then averages many of them into a `FormModel` — the mean shape of one block, with the spread
// around it.
//
// Three rules it keeps, all of them CLAUDE.md rule 1:
//
//  1. **Nothing is invented.** A joint the tracker never saw is not drawn from the fit's own
//     (unconstrained) guess. It is either mirrored from the other side — and then flagged
//     `inferredBySymmetry` so a viewer can draw it dashed — or refused outright with a reason.
//  2. **Metres only with a stated height.** With one the positions are metres. Without one the form
//     is in *shooter heights* (`FormLengthUnit.shooterHeights`), and `unitNote` says so; every
//     number is then a ratio and nothing pretends to be a measurement.
//  3. **The normalised clock is a convention, not a measurement.** Phase fractions (set 0, dip 0.35,
//     release 0.75, follow-through 1) are the grid two shots are compared on. The real durations
//     never pass through it: they are carried beside it, per shot in `FormPhaseDurations` and per
//     block in `FormTempo`, in milliseconds with their own spread.
//  4. **The mean is a body.** Averaging joint positions across shots shortens every bone whose
//     direction varies between them (iteration 4 measured the block's mean upper arm at 85–100 % of
//     the shooter's own). `FormModel.build` therefore re-integrates the mean skeleton along a
//     kinematic tree from the mid-hip: each bone takes the block's mean *direction* at that instant
//     and the shooter's own *length*, and the variability ellipsoids are the shots' residuals
//     against that rigid mean.

// MARK: Phases

/// The four points of the shot, and where each sits on the normalised axis.
public enum FormPhase: String, Sendable, Codable, CaseIterable {
    case set, dip, release, followThrough

    /// **A convention, not a measurement.** Chosen so that with the default 41 samples every phase
    /// lands exactly on a sample index (0, 14, 30, 40) and no phase time is ever interpolated.
    public var normalisedTime: Double {
        switch self {
        case .set: return 0.00
        case .dip: return 0.35
        case .release: return 0.75
        case .followThrough: return 1.00
        }
    }

    public var label: String {
        switch self {
        case .set: return "Set"
        case .dip: return "Dip"
        case .release: return "Release"
        case .followThrough: return "Follow-through"
        }
    }
}

/// What the numbers in a form are measured in.
public enum FormLengthUnit: String, Sendable, Codable {
    /// The shooter gave their standing height, so the fit's scale is a measurement.
    case metres
    /// No height was given. Every length is divided by the shooter's own fitted standing height, so
    /// the form is a shape and a ratio — never a metre wearing a measurement's clothes.
    case shooterHeights
}

/// How the body frame's forward axis (toward the rim) was established.
public enum FormFacing: Sendable, Equatable {
    /// The caller knows the rim's horizontal direction in camera metres (it has the shot plane).
    case rimDirection(SIMD3<Double>)
    /// Only the rim's image column is known. The forward axis is then the camera's own horizontal,
    /// signed toward the rim — honest on a near-side view, where the depth axis is the one a single
    /// camera cannot see at all (PHASE2-PREP, iteration 2).
    case rimImageColumn(rimU: Double)
    /// Nothing is known about where the rim is. The form is in camera axes and says so.
    case cameraAxes
}

public struct FormOptions: Sendable {
    /// Samples on the normalised axis. 41 puts the four phases exactly on indices 0/14/30/40.
    public var samples: Int = 41
    /// A joint seen on fewer than this fraction of the fitted frames is not trusted from the fit:
    /// with no pixels of its own, its position is held up only by bone lengths and smoothing.
    public var minimumSeenFraction: Double = 0.20
    public var minimumConfidence2D: Double = 0.30
    /// The floor an **appendage** point (a hand plate corner today, a foot's next) counts as seen
    /// against — `HandTriangleOptions.minimumHandLandmarkConfidence`. Its own number because its own
    /// detector: Vision's hand landmarks come back far less confident than its body joints.
    public var minimumAppendageConfidence: Double = 0.20
    /// Fewer fitted frames than this and there is no form to speak of.
    public var minimumFrames: Int = 8
    public var facing: FormFacing = .cameraAxes
    /// Positions are rounded to this many decimals on the way out: 4 is 0.1 mm in metres and about
    /// 0.2 mm of a person in shooter heights, well under the fit's own 1.4–2.4 px reprojection.
    public var decimals: Int = 4
    /// Shots needed before a spread (an SD, an ellipsoid, a deviation in SDs) means anything.
    public var minimumShotsForSpread: Int = 3
    /// An SD at or below this is treated as no spread at all: a millimetre in metres, 1.7 mm of a
    /// 1.7 m shooter in shooter heights — a hundredth of the fit's own depth σ, and the size of the
    /// residual the 4-decimal rounding leaves between identical shots and their rigid mean. The
    /// mid-hip at the set point is exactly the origin in every shot by construction.
    public var minimumSpread: Double = 1e-3
    public init() {}
}

// MARK: Skeleton

/// The joints, the bones between them, and the angles read off them. One list, so the exporter, the
/// averager and the viewer can never disagree about what a form contains.
public enum FormSkeleton {

    /// The joints a form carries: the 13 `BodySkeletonFit` solves for, then the appendage points a
    /// second detector adds and `HandTriangleFit` places in 3-D (1.3: the two hand plates' front
    /// corners; feet next, and they go on the end of `appendagePoints` without another edit here).
    ///
    /// The list is append-only on purpose. Every form file carries its own `joints` array and every
    /// consumer indexes by name through it, so a form written before an appendage existed keeps
    /// working and a form written after it simply has more columns.
    public static let appendagePoints: [String] = Body2DPoint.handCorners
    public static let joints: [String] = BodySkeletonFit.joints + appendagePoints

    /// The bones a viewer draws. Not the fit's bone set: the two trunk diagonals hold the fit's
    /// torso together but are not anatomy, so they are not drawn.
    public static let bones: [(a: String, b: String)] = [
        // The neck is in `BodySkeletonFit.joints` but may not be in an older form's; a bone whose
        // ends are not both in the form's own joint list is simply not drawn.
        (Body2DPoint.nose, Body2DPoint.neck),
        (Body2DPoint.nose, Body2DPoint.leftShoulder),
        (Body2DPoint.nose, Body2DPoint.rightShoulder),
        (Body2DPoint.leftShoulder, Body2DPoint.rightShoulder),
        (Body2DPoint.leftShoulder, Body2DPoint.leftElbow),
        (Body2DPoint.leftElbow, Body2DPoint.leftWrist),
        (Body2DPoint.rightShoulder, Body2DPoint.rightElbow),
        (Body2DPoint.rightElbow, Body2DPoint.rightWrist),
        (Body2DPoint.leftShoulder, Body2DPoint.leftHip),
        (Body2DPoint.rightShoulder, Body2DPoint.rightHip),
        (Body2DPoint.leftHip, Body2DPoint.rightHip),
        (Body2DPoint.leftHip, Body2DPoint.leftKnee),
        (Body2DPoint.leftKnee, Body2DPoint.leftAnkle),
        (Body2DPoint.rightHip, Body2DPoint.rightKnee),
        (Body2DPoint.rightKnee, Body2DPoint.rightAnkle),
    ] + handPlateEdges

    /// The three edges of each hand plate. Drawn as a filled triangle rather than as sticks where the
    /// viewer has a plate rig (`FormLayer`, `SceneBodyRig`); listed here so a viewer that has not got
    /// one still draws the outline, and so the mean form re-integrates the plate like any other bone.
    public static let handPlateEdges: [(a: String, b: String)] = [
        (Body2DPoint.leftWrist, Body2DPoint.leftIndexMCP),
        (Body2DPoint.leftWrist, Body2DPoint.leftLittleMCP),
        (Body2DPoint.leftIndexMCP, Body2DPoint.leftLittleMCP),
        (Body2DPoint.rightWrist, Body2DPoint.rightIndexMCP),
        (Body2DPoint.rightWrist, Body2DPoint.rightLittleMCP),
        (Body2DPoint.rightIndexMCP, Body2DPoint.rightLittleMCP),
    ]

    /// The contralateral joint, for the symmetry inference. The nose has none.
    public static let mirror: [String: String] = [
        Body2DPoint.leftShoulder: Body2DPoint.rightShoulder, Body2DPoint.rightShoulder: Body2DPoint.leftShoulder,
        Body2DPoint.leftElbow: Body2DPoint.rightElbow, Body2DPoint.rightElbow: Body2DPoint.leftElbow,
        Body2DPoint.leftWrist: Body2DPoint.rightWrist, Body2DPoint.rightWrist: Body2DPoint.leftWrist,
        Body2DPoint.leftHip: Body2DPoint.rightHip, Body2DPoint.rightHip: Body2DPoint.leftHip,
        Body2DPoint.leftKnee: Body2DPoint.rightKnee, Body2DPoint.rightKnee: Body2DPoint.leftKnee,
        Body2DPoint.leftAnkle: Body2DPoint.rightAnkle, Body2DPoint.rightAnkle: Body2DPoint.leftAnkle,
    ]

    /// The left/right pairs whose midpoint defines the body's own mid-line.
    public static let pairs: [(String, String)] = [
        (Body2DPoint.leftShoulder, Body2DPoint.rightShoulder),
        (Body2DPoint.leftHip, Body2DPoint.rightHip),
        (Body2DPoint.leftKnee, Body2DPoint.rightKnee),
        (Body2DPoint.leftAnkle, Body2DPoint.rightAnkle),
    ]

    /// The virtual root of the kinematic tree: the mid-hip, which is also the body frame's origin.
    /// Not a joint — it is the midpoint of the two hips on every sample.
    public static let root = "midHip"

    /// The tree the mean form is re-integrated along, parent → child, parents first. One edge per
    /// joint, so every joint's mean position is its parent's plus the shooter's own length of that
    /// bone along the block's mean direction. With no neck in the block (an older form, or a neck
    /// no shot carried) the shoulders and the nose hang off the root instead.
    public static func tree(withNeck: Bool) -> [(parent: String, child: String)] {
        let upper: [(parent: String, child: String)] = withNeck
            ? [(root, Body2DPoint.neck), (Body2DPoint.neck, Body2DPoint.leftShoulder),
               (Body2DPoint.neck, Body2DPoint.rightShoulder), (Body2DPoint.neck, Body2DPoint.nose)]
            : [(root, Body2DPoint.leftShoulder), (root, Body2DPoint.rightShoulder), (root, Body2DPoint.nose)]
        return [
            (root, Body2DPoint.leftHip), (root, Body2DPoint.rightHip),
            (Body2DPoint.leftHip, Body2DPoint.leftKnee), (Body2DPoint.leftKnee, Body2DPoint.leftAnkle),
            (Body2DPoint.rightHip, Body2DPoint.rightKnee), (Body2DPoint.rightKnee, Body2DPoint.rightAnkle),
        ] + upper + [
            (Body2DPoint.leftShoulder, Body2DPoint.leftElbow), (Body2DPoint.leftElbow, Body2DPoint.leftWrist),
            (Body2DPoint.rightShoulder, Body2DPoint.rightElbow), (Body2DPoint.rightElbow, Body2DPoint.rightWrist),
        ] + appendageTree
    }

    /// Appendage edges for the mean form's re-integration: each plate corner hangs off its own wrist
    /// with the shooter's own (prior-sized) plate length, so averaging a block of shots cannot
    /// shrink a hand. An edge whose ends are not both in a form's own joint list is dropped by the
    /// caller, so an older form is unaffected.
    public static let appendageTree: [(parent: String, child: String)] = [
        (Body2DPoint.leftWrist, Body2DPoint.leftIndexMCP), (Body2DPoint.leftWrist, Body2DPoint.leftLittleMCP),
        (Body2DPoint.rightWrist, Body2DPoint.rightIndexMCP), (Body2DPoint.rightWrist, Body2DPoint.rightLittleMCP),
    ]

    /// A joint angle: the angle at `vertex`, between the limbs going to `a` and `b`.
    ///
    /// `b2` (1.3) makes the second arm run to the **midpoint** of `b` and `b2` instead of to `b`.
    /// The wrist needs it: the hand's own pointing direction is wrist → the midpoint of the two
    /// knuckles, and neither knuckle on its own is that axis — the index MCP sits half a hand
    /// breadth off it, which is 8–12° of a straight hand.
    public struct AngleDefinition: Sendable, Equatable {
        public var name: String
        public var a: String, vertex: String, b: String
        public var b2: String? = nil
    }

    public static let angleDefinitions: [AngleDefinition] = [
        .init(name: "leftElbow", a: Body2DPoint.leftShoulder, vertex: Body2DPoint.leftElbow, b: Body2DPoint.leftWrist),
        .init(name: "rightElbow", a: Body2DPoint.rightShoulder, vertex: Body2DPoint.rightElbow, b: Body2DPoint.rightWrist),
        .init(name: "leftKnee", a: Body2DPoint.leftHip, vertex: Body2DPoint.leftKnee, b: Body2DPoint.leftAnkle),
        .init(name: "rightKnee", a: Body2DPoint.rightHip, vertex: Body2DPoint.rightKnee, b: Body2DPoint.rightAnkle),
        .init(name: "leftHip", a: Body2DPoint.leftShoulder, vertex: Body2DPoint.leftHip, b: Body2DPoint.leftKnee),
        .init(name: "rightHip", a: Body2DPoint.rightShoulder, vertex: Body2DPoint.rightHip, b: Body2DPoint.rightKnee),
        .init(name: "leftShoulderElevation", a: Body2DPoint.leftElbow, vertex: Body2DPoint.leftShoulder, b: Body2DPoint.leftHip),
        .init(name: "rightShoulderElevation", a: Body2DPoint.rightElbow, vertex: Body2DPoint.rightShoulder, b: Body2DPoint.rightHip),
        // 1.3: the wrist. Unsigned here — an interior angle between the forearm and the hand — so it
        // reads the same way as every other angle in this list. `HandShotMeasures.wristFlexionAtRelease`
        // is the *signed* version (flexion positive, extension negative) and needs the palm normal,
        // which a form sample does not carry on its own.
        .init(name: "leftWrist", a: Body2DPoint.leftElbow, vertex: Body2DPoint.leftWrist,
              b: Body2DPoint.leftIndexMCP, b2: Body2DPoint.leftLittleMCP),
        .init(name: "rightWrist", a: Body2DPoint.rightElbow, vertex: Body2DPoint.rightWrist,
              b: Body2DPoint.rightIndexMCP, b2: Body2DPoint.rightLittleMCP),
    ]

    /// Every angle track a form carries: the eight joint angles, plus the trunk's lean from vertical
    /// (mid-hip → mid-shoulder against the body frame's up axis).
    public static let trunkLeanName = "trunkLeanFromVertical"
    public static var angleNames: [String] { angleDefinitions.map(\.name) + [trunkLeanName] }

    public static func index(of joint: String) -> Int? { joints.firstIndex(of: joint) }

    /// What `BodySkeletonFit` writes this joint into `BodyFrame.joints3D` under. The fit uses the
    /// 2-D names except for the head and neck, which it files under the 3-D model's own
    /// `centerHead` / `centerShoulder`; a form that looked only for "nose" would silently lose the
    /// head and then refuse the whole shot for want of an ankle-to-nose span.
    public static func joint3DKey(_ name: String) -> String {
        if name == Body2DPoint.nose { return Body3DJoint.centerHead }
        if name == Body2DPoint.neck { return Body3DJoint.centerShoulder }
        return name
    }

    /// The fitted position of one joint on one frame, under either name.
    public static func fitted(_ f: BodyFrame, _ name: String) -> SIMD3<Double>? {
        (f.joints3D[name] ?? f.joints3D[joint3DKey(name)])?.cameraPosition
    }

    /// Every angle in the form, radians, from one sample's body-frame positions.
    /// `nil` where any of the three joints has no position on that sample.
    public static func angles(at p: [SIMD3<Double>?], up: SIMD3<Double> = SIMD3(0, 0, 1)) -> [String: Double] {
        var out: [String: Double] = [:]
        for d in angleDefinitions {
            guard let ia = index(of: d.a), let iv = index(of: d.vertex), let ib = index(of: d.b),
                  let a = p[ia], let v = p[iv], var b = p[ib] else { continue }
            if let second = d.b2 {
                guard let i2 = index(of: second), let q = p[i2] else { continue }
                b = (b + q) / 2
            }
            guard let theta = BodyAngles.angle(a, v, b) else { continue }
            out[d.name] = theta
        }
        if let hip = midpoint(p, Body2DPoint.leftHip, Body2DPoint.rightHip),
           let sh = midpoint(p, Body2DPoint.leftShoulder, Body2DPoint.rightShoulder),
           let theta = BodyAngles.angleBetween(sh - hip, up) {
            out[trunkLeanName] = theta
        }
        return out
    }

    static func midpoint(_ p: [SIMD3<Double>?], _ a: String, _ b: String) -> SIMD3<Double>? {
        guard let ia = index(of: a), let ib = index(of: b), let pa = p[ia], let pb = p[ib] else { return nil }
        return (pa + pb) / 2
    }
}

// MARK: - One shot's form

/// One resampled instant. `xyz` is a flat 3·J array in the body frame, `nil` where that joint has no
/// position at this instant. Flat and rounded because a session keeps one of these per shot.
public struct FormSample: Sendable, Codable, Equatable {
    /// Normalised time, 0 at the set point and 1 at the end of the follow-through.
    public var t: Double
    /// Real seconds relative to the release. Negative before it. The real clock, never normalised.
    public var dt: Double
    public var xyz: [Double?]

    public init(t: Double, dt: Double, xyz: [Double?]) { self.t = t; self.dt = dt; self.xyz = xyz }

    public func position(_ jointIndex: Int) -> SIMD3<Double>? {
        let i = jointIndex * 3
        guard i + 2 < xyz.count, let x = xyz[i], let y = xyz[i + 1], let z = xyz[i + 2] else { return nil }
        return SIMD3(x, y, z)
    }
    public var positions: [SIMD3<Double>?] { (0..<(xyz.count / 3)).map { position($0) } }
}

/// A stretch of the normalised axis a shot has no samples on, and why. A missing phase anchor is
/// never interpolated across: the segment simply is not there, and the reason travels with it.
public struct FormGap: Sendable, Codable, Equatable {
    public var from: Double, to: Double
    public var reason: String
}

/// One shot's real phase durations, in milliseconds. The clock the normalised axis threw away.
public struct FormPhaseDurations: Sendable, Codable, Equatable {
    public var setToDip: BodyMeasure
    public var dipToRelease: BodyMeasure
    public var releaseToFollowThrough: BodyMeasure
    public var total: BodyMeasure
}

/// One shot, in the shooter's own frame, on the normalised clock.
///
/// Body frame: origin the mid-hip at the set point, **x** toward the rim along the shot plane,
/// **z** up, **y** = z × x (the shooter's left-right). Right-handed.
public struct ShotForm: Sendable, Codable, Equatable {
    public static let formatVersion = 1

    public var version: Int
    public var shotID: Int?
    public var joints: [String]
    public var unit: FormLengthUnit
    public var unitNote: String
    /// The grid length the samples were laid on, so a form with gaps still averages on the right axis.
    public var sampleCount: Int
    public var samples: [FormSample]
    public var gaps: [FormGap]
    /// Per joint, the fraction of fitted frames on which the tracker had a confident 2-D point.
    public var seenFraction: [Double]
    /// Per joint: this position is the other side of the body mirrored across the shooter's own
    /// mid-line, because the tracker never saw this one. Draw it dashed; never quote a number off it.
    public var inferredBySymmetry: [Bool]
    /// Joints with neither pixels of their own nor a mirror to borrow from, and why.
    public var refusedJoints: [String: String]
    public var durations: FormPhaseDurations
    /// Real seconds, on the shot's own clock, for each phase that was found.
    public var phaseRealTimes: [String: Double]
    public var releaseRealTime: Double
    public var facingNote: String
    public var scaleNote: String
    public var shootingSide: String?
    public var notes: [String]
    public var warnings: [String]

    public var jointCount: Int { joints.count }

    /// The sample nearest a phase, or nil when that phase's segment is one of the `gaps`.
    public func sample(at phase: FormPhase) -> FormSample? {
        samples.min(by: { abs($0.t - phase.normalisedTime) < abs($1.t - phase.normalisedTime) })
            .flatMap { abs($0.t - phase.normalisedTime) <= 1e-6 ? $0 : nil }
    }
}

extension ShotForm {

    /// Build one shot's form from its fitted skeleton.
    ///
    /// The phase times are **inputs**, not re-derived here: the caller has already decided which of
    /// `BodyKinematics.phases`'s values survived its own edge checks (a dip that sat on the first
    /// frame of the lookback is the window's length, not a dip), and a form must never quietly
    /// re-admit a number the body model refused.
    ///
    /// Returns `(nil, reason)` when there is no form to make.
    public static func make(fit: BodySkeletonFitResult,
                            setRealTime: Double?, dipRealTime: Double?,
                            releaseRealTime: Double, followThroughRealTime: Double?,
                            shootingSide: String? = nil,
                            shotID: Int? = nil,
                            options o: FormOptions = .init()) -> (form: ShotForm?, unavailableReason: String?) {
        make(timeline: fit.timeline, scaleIsMeasured: fit.scaleIsMeasured && fit.standingHeightMetres.value != nil,
             scaleNote: fit.scaleProvenance, setRealTime: setRealTime, dipRealTime: dipRealTime,
             releaseRealTime: releaseRealTime, followThroughRealTime: followThroughRealTime,
             shootingSide: shootingSide, shotID: shotID, options: o)
    }

    /// The same thing, without the fit result around it: a fitted timeline, and the two facts about
    /// its scale. Everything the form needs, and nothing it does not — so it can be tested on a
    /// synthetic skeleton, and so a change to the fit's own reporting cannot move a form.
    ///
    /// (`BodySkeletonFitResult.jointCoverage` reports the same never-seen joints from the fit's side.
    /// The form recomputes them from the 2-D points rather than depending on it, so the two are an
    /// independent check on each other.)
    public static func make(timeline: BodyTimeline, scaleIsMeasured: Bool, scaleNote: String,
                            setRealTime: Double?, dipRealTime: Double?,
                            releaseRealTime: Double, followThroughRealTime: Double?,
                            shootingSide: String? = nil,
                            shotID: Int? = nil,
                            options o: FormOptions = .init()) -> (form: ShotForm?, unavailableReason: String?) {
        let J = FormSkeleton.joints.count
        let frames = timeline.frames
            .filter { f in FormSkeleton.joints.contains { FormSkeleton.fitted(f, $0) != nil } }
            .sorted { $0.realTime < $1.realTime }
        guard frames.count >= o.minimumFrames else {
            return (nil, "only \(frames.count) frames of this shot carried a fitted skeleton, fewer than the \(o.minimumFrames) a form needs")
        }
        guard o.samples >= 5 else { return (nil, "a form needs at least 5 samples on the normalised axis") }

        // ---- what the tracker actually saw -------------------------------------------------------
        var seen = [Double](repeating: 0, count: J)
        for (j, name) in FormSkeleton.joints.enumerated() {
            // Appendage points come from a second detector whose confidences run much lower than the
            // body pose's (measured p50 0.50 at the MCPs against 0.9+ at a shoulder), so they are
            // counted against their own floor. One rule per detector, each of them stated.
            let floor = FormSkeleton.appendagePoints.contains(name) ? o.minimumAppendageConfidence : o.minimumConfidence2D
            let n = frames.filter { ($0.points2D[name]?.confidence ?? 0) >= floor }.count
            seen[j] = Double(n) / Double(frames.count)
        }

        // ---- scale -------------------------------------------------------------------------------
        // The fit's positions are metres *under whatever scale it was given*. With a stated height
        // that is a measurement; without one it is a 1.80 m population prior, and a metre off it
        // would be a population number wearing a measurement's clothes. So: divide by the shooter's
        // own fitted standing height and call the unit what it is.
        let standing = fittedStandingHeight(frames: frames)
        var unit: FormLengthUnit = .shooterHeights
        var divisor = 1.0
        var unitNote = ""
        if scaleIsMeasured {
            unit = .metres
            unitNote = "metres, from " + scaleNote
        } else if let h = standing, h > 0 {
            divisor = h
            unitNote = "shooter heights: no standing height was given, so every length here is divided by the shooter's own fitted ankle-to-nose span (\(scaleNote)); they are ratios, not metres"
        } else {
            return (nil, "no frame carried both an ankle and the nose, so the form has no length unit to be expressed in")
        }

        // ---- the body frame ----------------------------------------------------------------------
        let up = SIMD3<Double>(0, 1, 0)                          // camera space: +y is up
        var forward = SIMD3<Double>(1, 0, 0)
        var facingNote = ""
        switch o.facing {
        case .rimDirection(let d):
            let flat = d - simd_dot(d, up) * up
            guard simd_length(flat) > 1e-9 else {
                return (nil, "the rim direction given is vertical, so it cannot orient the body frame")
            }
            forward = simd_normalize(flat)
            facingNote = "x points at the rim, from the shot plane the caller supplied"
        case .rimImageColumn(let rimU):
            let bodyU = meanMidHipColumn(frames: frames, minimumConfidence: o.minimumConfidence2D)
            let sign: Double = (bodyU.map { rimU >= $0 } ?? true) ? 1 : -1
            forward = SIMD3(sign, 0, 0)
            facingNote = "x points along the camera's horizontal, toward the rim's image column (the rim is \(sign > 0 ? "right" : "left") of the shooter). Only the bearing is known, not the depth: on a near-side view the depth axis is the one a single camera cannot see"
        case .cameraAxes:
            facingNote = "x is the camera's own right: nothing was supplied about where the rim is, so this form is in camera axes and two clips filmed from different sides do not share an x"
        }
        let zAxis = up
        let xAxis = simd_normalize(forward - simd_dot(forward, up) * up)
        let yAxis = simd_cross(zAxis, xAxis)

        // Origin: the mid-hip at the set point — the pose the whole shot is measured from.
        var notes: [String] = [], warnings: [String] = []
        let originTime = setRealTime ?? frames.first!.realTime
        if setRealTime == nil {
            notes.append("no set point was found in this window, so the body frame's origin is the mid-hip on the first fitted frame instead")
        }
        guard let origin = midHip(interpolate(frames: frames, at: originTime)) else {
            return (nil, "the mid-hip had no fitted position at the set point, so the body frame has no origin")
        }
        func toBody(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let d = (p - origin) / divisor
            return SIMD3(simd_dot(d, xAxis), simd_dot(d, yAxis), simd_dot(d, zAxis))
        }

        // ---- the normalised axis -----------------------------------------------------------------
        var anchors: [(phase: FormPhase, time: Double?)] = [
            (.set, setRealTime), (.dip, dipRealTime), (.release, releaseRealTime), (.followThrough, followThroughRealTime),
        ]
        // Anchors must increase: a phase out of order is a detection failure, not a shot.
        for i in 1..<anchors.count {
            if let a = anchors[i - 1].time, let b = anchors[i].time, b <= a {
                warnings.append("the \(anchors[i].phase.label.lowercased()) was not after the \(anchors[i - 1].phase.label.lowercased()) on this shot, so it is treated as not found")
                anchors[i].time = nil
            }
        }
        var gaps: [FormGap] = []
        // The seen-fraction gate asks "is this joint held up by pixels, or only by bone lengths and
        // smoothing?". That question does not apply to an appendage point: a hand plate corner is
        // written into the fit **only on the frames its landmark was observed on** and is simply
        // absent elsewhere, so there is no frame on which it could be an unsupported inference. Gating
        // it on how much of the *window* it covers would throw away the instants where it was
        // genuinely measured — measured on the 37-shot free-throw session, the shooting hand is on
        // the ball for most of the window and the MCPs cover 18 % of it, so the 20 % gate refused
        // every plate the release itself had. Appendages are therefore gated per sample, by presence.
        func threshold(_ j: Int, _ name: String) -> Double {
            FormSkeleton.appendagePoints.contains(name) ? 0 : o.minimumSeenFraction
        }
        var samples: [FormSample] = []
        let n = o.samples
        for i in 0..<n {
            let tau = Double(i) / Double(n - 1)
            guard let real = realTime(forNormalised: tau, anchors: anchors) else { continue }
            let p = interpolate(frames: frames, at: real)
            var body = [SIMD3<Double>?](repeating: nil, count: J)
            for (j, name) in FormSkeleton.joints.enumerated() where seen[j] >= threshold(j, name) {
                if let q = p[name] { body[j] = toBody(q) }
            }
            samples.append(FormSample(t: round(tau, 6), dt: round(real - releaseRealTime, 5),
                                      xyz: flatten(body, decimals: o.decimals)))
        }
        guard !samples.isEmpty else {
            return (nil, "no phase pair in this shot was found on both ends, so there is no normalised axis to resample onto")
        }
        // Say which stretches are missing, and why.
        for k in 0..<(anchors.count - 1) {
            let lo = anchors[k], hi = anchors[k + 1]
            if lo.time == nil || hi.time == nil {
                let which = lo.time == nil ? lo.phase : hi.phase
                gaps.append(FormGap(from: lo.phase.normalisedTime, to: hi.phase.normalisedTime,
                                    reason: "the \(which.label.lowercased()) was not found in this window, so \(lo.phase.label.lowercased()) → \(hi.phase.label.lowercased()) has no samples"))
            }
        }

        // ---- the far side of the body -------------------------------------------------------------
        var inferred = [Bool](repeating: false, count: J)
        var refused: [String: String] = [:]
        for (j, name) in FormSkeleton.joints.enumerated() where seen[j] < threshold(j, name) {
            guard let partner = FormSkeleton.mirror[name], let pj = FormSkeleton.index(of: partner),
                  seen[pj] >= o.minimumSeenFraction else {
                refused[name] = String(format: "the tracker saw this joint on %.0f %% of the frames and there is no confident joint on the other side to mirror, so it has no position", 100 * seen[j])
                continue
            }
            var mirroredAny = false
            for (si, s) in samples.enumerated() {
                guard let q = s.position(pj), let mid = midLine(s, joints: J) else { continue }
                // Mirror across the shooter's own sagittal plane: y is the left-right axis.
                let m = SIMD3(q.x, 2 * mid - q.y, q.z)
                var xyz = samples[si].xyz
                xyz[j * 3] = round(m.x, o.decimals); xyz[j * 3 + 1] = round(m.y, o.decimals); xyz[j * 3 + 2] = round(m.z, o.decimals)
                samples[si].xyz = xyz
                mirroredAny = true
            }
            if mirroredAny {
                inferred[j] = true
                notes.append(String(format: "%@ was seen on %.0f %% of the frames, so it is mirrored from %@ across the shooter's own mid-line: it is inferred by symmetry, not measured",
                                    name, 100 * seen[j], partner))
            } else {
                refused[name] = "neither this joint nor its mirror had a position on any sample of the normalised axis"
            }
        }

        // ---- the real clock the normalised axis threw away -----------------------------------------
        func ms(_ a: Double?, _ b: Double?, _ why: String) -> BodyMeasure {
            guard let a, let b else { return .missing(.milliseconds, why) }
            return .ok(1000 * (b - a), .milliseconds)
        }
        // From the **vetted** anchors, not the arguments: a phase the ordering check above threw out
        // is gone from the durations too, or the form would publish a negative one.
        func anchor(_ p: FormPhase) -> Double? { anchors.first { $0.phase == p }?.time }
        let vSet = anchor(.set), vDip = anchor(.dip), vRel = anchor(.release), vFollow = anchor(.followThrough)
        let durations = FormPhaseDurations(
            setToDip: ms(vSet, vDip, reasonFor(vSet, vDip, "set point", "dip")),
            dipToRelease: ms(vDip, vRel, reasonFor(vDip, vRel, "dip", "release")),
            releaseToFollowThrough: ms(vRel, vFollow, reasonFor(vRel, vFollow, "release", "follow-through")),
            total: ms(vSet, vFollow, reasonFor(vSet, vFollow, "set point", "follow-through")))

        var phaseTimes: [String: Double] = [:]
        for a in anchors { if let t = a.time { phaseTimes[a.phase.rawValue] = round(t, 5) } }

        let form = ShotForm(version: formatVersion, shotID: shotID, joints: FormSkeleton.joints,
                            unit: unit, unitNote: unitNote, sampleCount: n, samples: samples, gaps: gaps,
                            seenFraction: seen.map { round($0, 3) }, inferredBySymmetry: inferred,
                            refusedJoints: refused, durations: durations, phaseRealTimes: phaseTimes,
                            releaseRealTime: round(releaseRealTime, 5),
                            facingNote: facingNote, scaleNote: scaleNote,
                            shootingSide: shootingSide, notes: notes, warnings: warnings)
        return (form, nil)
    }

    // ---- helpers ---------------------------------------------------------------------------------

    static func reasonFor(_ a: Double?, _ b: Double?, _ an: String, _ bn: String) -> String {
        if a == nil && b == nil { return "neither the \(an) nor the \(bn) was found in this window" }
        return "the \(a == nil ? an : bn) was not found in this window"
    }

    static func round(_ x: Double, _ decimals: Int) -> Double {
        let s = pow(10.0, Double(decimals))
        return (x * s).rounded() / s
    }

    static func flatten(_ p: [SIMD3<Double>?], decimals: Int) -> [Double?] {
        var out: [Double?] = []
        out.reserveCapacity(p.count * 3)
        for q in p {
            guard let q else { out.append(contentsOf: [nil, nil, nil] as [Double?]); continue }
            out.append(round(q.x, decimals)); out.append(round(q.y, decimals)); out.append(round(q.z, decimals))
        }
        return out
    }

    /// The shooter's own mid-line, in the body frame's y: the mean of every left/right pair that has
    /// both ends on this sample. Nil when no pair does — and then nothing is mirrored.
    static func midLine(_ s: FormSample, joints J: Int) -> Double? {
        var mids: [Double] = []
        for (a, b) in FormSkeleton.pairs {
            guard let ia = FormSkeleton.index(of: a), let ib = FormSkeleton.index(of: b),
                  let pa = s.position(ia), let pb = s.position(ib) else { continue }
            mids.append((pa.y + pb.y) / 2)
        }
        guard !mids.isEmpty else { return nil }
        return mids.reduce(0, +) / Double(mids.count)
    }

    /// Piecewise-linear map from the normalised axis back to the shot's own clock. A segment whose
    /// anchors are not both known has no map, and the sample is dropped rather than guessed.
    ///
    /// **An anchor's own τ needs no segment (fixed 2026-09-16).** τ 0.75 *is* the release, and the
    /// release time is measured on every shot the body model accepts — but the old loop reached the
    /// dip → release segment first (0.75 is its upper end), found the dip missing and returned nil,
    /// so a shot with no dip had no sample at its own release. Measured over the 37-shot free-throw
    /// session, where this shooter's free throw genuinely has no dip: 33 of 37 forms carried nothing
    /// at τ 0.75 — not the wrist, not the elbow, not anything — and that, not any hand detector, is
    /// why the release instant looked empty. An anchor with a time is now that time, and only the
    /// stretches *between* two anchors still need both ends.
    static func realTime(forNormalised tau: Double, anchors: [(phase: FormPhase, time: Double?)]) -> Double? {
        for a in anchors where abs(tau - a.phase.normalisedTime) <= 1e-9 {
            if let t = a.time { return t }
        }
        for k in 0..<(anchors.count - 1) {
            let lo = anchors[k], hi = anchors[k + 1]
            let a = lo.phase.normalisedTime, b = hi.phase.normalisedTime
            guard tau >= a - 1e-9, tau <= b + 1e-9 else { continue }
            // A segment missing an end cannot place this τ — but a *later* segment sharing this one's
            // upper anchor still might, so the search goes on instead of giving up here.
            guard let ta = lo.time, let tb = hi.time else { continue }
            let f = b > a ? (tau - a) / (b - a) : 0
            return ta + f * (tb - ta)
        }
        return nil
    }

    /// Fitted joint positions at a real time, linearly interpolated between the bracketing frames.
    static func interpolate(frames: [BodyFrame], at t: Double) -> [String: SIMD3<Double>] {
        guard let first = frames.first, let last = frames.last else { return [:] }
        func positions(_ f: BodyFrame) -> [String: SIMD3<Double>] {
            var out: [String: SIMD3<Double>] = [:]
            for name in FormSkeleton.joints { if let p = FormSkeleton.fitted(f, name) { out[name] = p } }
            return out
        }
        if t <= first.realTime { return positions(first) }
        if t >= last.realTime { return positions(last) }
        var lo = frames[0], hi = frames[frames.count - 1]
        for i in 1..<frames.count where frames[i].realTime >= t { lo = frames[i - 1]; hi = frames[i]; break }
        let span = hi.realTime - lo.realTime
        let f = span > 1e-12 ? (t - lo.realTime) / span : 0
        let a = positions(lo), b = positions(hi)
        var out: [String: SIMD3<Double>] = [:]
        for (name, pa) in a {
            if let pb = b[name] { out[name] = pa + f * (pb - pa) } else { out[name] = pa }
        }
        for (name, pb) in b where out[name] == nil { out[name] = pb }
        return out
    }

    static func midHip(_ p: [String: SIMD3<Double>]) -> SIMD3<Double>? {
        guard let l = p[Body2DPoint.leftHip], let r = p[Body2DPoint.rightHip] else { return nil }
        return (l + r) / 2
    }

    /// The shooter's standing height in the fit's own units: the 90th-percentile ankle-to-nose
    /// distance of the fitted skeleton, divided by Winter's 0.891 H span.
    static func fittedStandingHeight(frames: [BodyFrame], ankleToNoseFraction: Double = 0.891) -> Double? {
        var spans: [Double] = []
        for f in frames {
            guard let nose = FormSkeleton.fitted(f, Body2DPoint.nose) else { continue }
            let ankles = [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle].compactMap { FormSkeleton.fitted(f, $0) }
            guard !ankles.isEmpty else { continue }
            spans.append(ankles.map { simd_length($0 - nose) }.max() ?? 0)
        }
        guard spans.count >= 3 else { return nil }
        let s = spans.sorted()
        let p90 = s[min(s.count - 1, Int((0.9 * Double(s.count - 1)).rounded()))]
        return p90 > 0 ? p90 / ankleToNoseFraction : nil
    }

    static func meanMidHipColumn(frames: [BodyFrame], minimumConfidence: Double) -> Double? {
        var us: [Double] = []
        for f in frames {
            guard let l = f.points2D[Body2DPoint.leftHip], l.confidence >= minimumConfidence,
                  let r = f.points2D[Body2DPoint.rightHip], r.confidence >= minimumConfidence else { continue }
            us.append((l.u + r.u) / 2)
        }
        guard !us.isEmpty else { return nil }
        return us.reduce(0, +) / Double(us.count)
    }
}

// MARK: - Many shots: the block's form

/// A mean ± SD with the n behind it, in one place.
public struct FormStat: Sendable, Codable, Equatable {
    public var mean: BodyMeasure
    public var sd: BodyMeasure
    public var n: Int
}

/// The block's tempo: the real durations the normalised axis abstracted away, back again.
public struct FormTempo: Sendable, Codable, Equatable {
    public var setToDip: FormStat
    public var dipToRelease: FormStat
    public var releaseToFollowThrough: FormStat
    public var total: FormStat
}

/// One instant of the mean form: where each joint sits on average, and the 1σ box around it.
public struct FormModelSample: Sendable, Codable, Equatable {
    public var t: Double
    /// Mean real seconds from release, and its spread across the block.
    public var dt: Double
    public var dtSD: Double?
    /// Flat 3·J, nil where no shot had that joint here.
    public var mean: [Double?]
    /// Flat 3·J: the SD along each body axis. Together they are the joint's variability ellipsoid's
    /// semi-axes at 1σ. Nil where fewer than `minimumShotsForSpread` shots contributed.
    public var sd: [Double?]
    /// Per joint, how many shots had a position here.
    public var n: [Int]

    public func position(_ j: Int) -> SIMD3<Double>? {
        let i = j * 3
        guard i + 2 < mean.count, let x = mean[i], let y = mean[i + 1], let z = mean[i + 2] else { return nil }
        return SIMD3(x, y, z)
    }
    public func spread(_ j: Int) -> SIMD3<Double>? {
        let i = j * 3
        guard i + 2 < sd.count, let x = sd[i], let y = sd[i + 1], let z = sd[i + 2] else { return nil }
        return SIMD3(x, y, z)
    }
}

/// One bone of the mean form, with the shooter's own length for it: the mean over the block's shots
/// of each shot's median joint distance (the fit holds a bone constant within a shot, so the median
/// is that shot's bone). `a` is `FormSkeleton.root` for the bones that leave the mid-hip.
public struct FormBone: Sendable, Codable, Equatable {
    public var a: String, b: String
    /// In the model's unit.
    public var length: Double
    /// Across the block's shots; nil under `FormOptions.minimumShotsForSpread`.
    public var sd: Double?
    public var n: Int
}

/// One joint angle over the normalised axis: mean and SD at every sample, in **degrees** — this is
/// the boundary, and the name says so.
public struct FormAngleTrack: Sendable, Codable, Equatable {
    public var name: String
    public var meanDegrees: [Double?]
    public var sdDegrees: [Double?]
    public var n: [Int]
    /// True when any shot's contribution came from a joint mirrored across the mid-line.
    public var usesInferredJoints: Bool
    public var unavailableReason: String?
}

/// The mean form of one block of shots, with the spread around it.
public struct FormModel: Sendable, Codable, Equatable {
    public static let formatVersion = 1

    public var version: Int
    public var label: String
    public var spot: String?
    public var sessionID: String?
    /// Seconds since 1970, so the export needs no date formatter.
    public var date: Double?
    public var joints: [String]
    public var unit: FormLengthUnit
    public var unitNote: String
    public var sampleCount: Int
    public var samples: [FormModelSample]
    public var angles: [FormAngleTrack]
    public var tempo: FormTempo
    /// The shooter's own bone lengths the mean form is built with, one per edge of the kinematic
    /// tree. Every bone of the mean form has exactly this length on every sample.
    public var bones: [FormBone]
    public var shots: Int
    public var shotIDs: [Int]
    /// Per joint, the mean fraction of frames the tracker saw it on, across the block.
    public var seenFraction: [Double]
    /// Per joint: every contributing shot had this one mirrored from the other side. Dashed, never
    /// quoted.
    public var inferredBySymmetry: [Bool]
    public var refusedJoints: [String: String]
    public var notes: [String]
    public var warnings: [String]
    public var unavailableReason: String?

    public var isAvailable: Bool { unavailableReason == nil && !samples.isEmpty }

    /// The model sample sitting exactly on a phase.
    public func sample(at phase: FormPhase) -> FormModelSample? {
        samples.first { abs($0.t - phase.normalisedTime) <= 1e-6 }
    }

    public static func unavailable(_ reason: String, label: String = "") -> FormModel {
        FormModel(version: formatVersion, label: label, spot: nil, sessionID: nil, date: nil,
                  joints: FormSkeleton.joints, unit: .shooterHeights, unitNote: "", sampleCount: 0,
                  samples: [], angles: [], tempo: FormTempo(setToDip: .empty, dipToRelease: .empty,
                                                            releaseToFollowThrough: .empty, total: .empty),
                  bones: [], shots: 0, shotIDs: [], seenFraction: [], inferredBySymmetry: [], refusedJoints: [:],
                  notes: [], warnings: [], unavailableReason: reason)
    }

    /// Average many shots' forms into one.
    ///
    /// Refuses rather than pools when the forms are not commensurable: metres and shooter heights do
    /// not average, and neither do two different normalised grids.
    public static func build(forms: [ShotForm], label: String, spot: String? = nil,
                             sessionID: String? = nil, date: Double? = nil,
                             options o: FormOptions = .init()) -> FormModel {
        guard let first = forms.first else {
            return .unavailable("no shot in this block carried a form", label: label)
        }
        guard forms.allSatisfy({ $0.unit == first.unit }) else {
            return .unavailable("some of these shots are in metres and some in shooter heights (a standing height was given for only part of the block), and the two do not average", label: label)
        }
        guard forms.allSatisfy({ $0.sampleCount == first.sampleCount && $0.joints == first.joints }) else {
            return .unavailable("these forms were built on different normalised grids, so they cannot be laid on top of one another", label: label)
        }
        let n = first.sampleCount, J = first.joints.count
        var notes: [String] = [], warnings: [String] = []
        if forms.count < o.minimumShotsForSpread {
            warnings.append("\(forms.count) shot\(forms.count == 1 ? "" : "s") in this block: the mean form is drawn, but a spread needs at least \(o.minimumShotsForSpread), so every SD here is unavailable")
        }

        // ---- the rigid mean -----------------------------------------------------------------------
        // A mean of positions is not a body: two shots whose forearms point in different directions
        // average to a forearm shorter than either. So the mean skeleton is re-integrated along the
        // kinematic tree from the mid-hip: each bone takes the block's mean *direction* at that
        // instant (the mean on the sphere — the normalised resultant of the shots' unit vectors) and
        // the shooter's own *length*. The ellipsoids are the shots' residuals against that mean,
        // including whatever the re-lengthening moved.
        func jIndex(_ name: String) -> Int? { first.joints.firstIndex(of: name) }
        func midHip(_ s: FormSample) -> SIMD3<Double>? {
            guard let l = jIndex(Body2DPoint.leftHip), let r = jIndex(Body2DPoint.rightHip),
                  let pl = s.position(l), let pr = s.position(r) else { return nil }
            return (pl + pr) / 2
        }
        let neckIndex = jIndex(Body2DPoint.neck)
        let blockHasNeck = neckIndex.map { ni in forms.contains { f in f.samples.contains { $0.position(ni) != nil } } } ?? false
        struct Edge { var parent: Int?; var child: Int }          // parent nil = the root
        let edges: [Edge] = FormSkeleton.tree(withNeck: blockHasNeck).compactMap { e in
            guard let c = jIndex(e.child) else { return nil }
            if e.parent == FormSkeleton.root { return Edge(parent: nil, child: c) }
            guard let p = jIndex(e.parent) else { return nil }
            return Edge(parent: p, child: c)
        }
        func parentPosition(_ s: FormSample, _ e: Edge) -> SIMD3<Double>? {
            if let p = e.parent { return s.position(p) }
            return midHip(s)
        }
        // The shooter's own bone lengths: per shot the median over its samples, then the mean over
        // the block. A bone no shot had both ends of has no length, and its joint no mean position.
        var bones: [FormBone] = []
        var lengths: [Int: Double] = [:]                          // child joint → the shooter's length
        for e in edges {
            let perShot: [Double] = forms.compactMap { f in
                let ls = f.samples.compactMap { s -> Double? in
                    guard let p = parentPosition(s, e), let c = s.position(e.child) else { return nil }
                    return simd_length(c - p)
                }
                return ls.isEmpty ? nil : Stats.median(ls)
            }
            guard !perShot.isEmpty else { continue }
            let length = Stats.mean(perShot)
            lengths[e.child] = length
            bones.append(FormBone(a: e.parent.map { first.joints[$0] } ?? FormSkeleton.root, b: first.joints[e.child],
                                  length: ShotForm.round(length, o.decimals),
                                  sd: perShot.count >= o.minimumShotsForSpread ? ShotForm.round(Stats.sd(perShot), o.decimals) : nil,
                                  n: perShot.count))
        }
        if !edges.isEmpty {
            notes.append("the mean form is rigid: every bone runs along the block's mean direction with the shooter's own length (the mean over shots of each shot's median), so averaging shortens nothing; each ellipsoid is the shots' residual against that mean")
        }

        var samples: [FormModelSample] = []
        var angleValues: [String: [[Double]]] = [:]     // name → per sample → radians across shots
        for name in FormSkeleton.angleNames { angleValues[name] = Array(repeating: [], count: n) }

        for i in 0..<n {
            let tau = Double(i) / Double(n - 1)
            let here = forms.compactMap { f in f.samples.first { abs($0.t - tau) <= 1e-6 } }
            // The root is the mean mid-hip; every joint is then parent + length × mean direction,
            // parents first. A joint whose parent has no mean here has none either.
            var meanPos = [SIMD3<Double>?](repeating: nil, count: J)
            let roots = here.compactMap(midHip)
            let rootMean: SIMD3<Double>? = roots.isEmpty ? nil : roots.reduce(.zero, +) / Double(roots.count)
            for e in edges {
                let parentMean: SIMD3<Double>? = e.parent.map { meanPos[$0] } ?? rootMean
                guard let length = lengths[e.child], let parentMean else { continue }
                var resultant = SIMD3<Double>.zero
                for s in here {
                    guard let p = parentPosition(s, e), let c = s.position(e.child) else { continue }
                    let d = c - p, l = simd_length(d)
                    if l > 1e-9 { resultant += d / l }
                }
                let r = simd_length(resultant)
                guard r > 1e-9 else { continue }
                meanPos[e.child] = parentMean + length * (resultant / r)
            }
            var mean = [Double?](repeating: nil, count: 3 * J)
            var sd = [Double?](repeating: nil, count: 3 * J)
            var counts = [Int](repeating: 0, count: J)
            for j in 0..<J {
                let xs = here.compactMap { $0.position(j) }
                counts[j] = xs.count
                guard let m = meanPos[j] else { continue }
                for axis in 0..<3 {
                    mean[j * 3 + axis] = ShotForm.round(m[axis], o.decimals)
                    guard xs.count >= o.minimumShotsForSpread else { continue }
                    let ss = xs.reduce(0.0) { $0 + ($1[axis] - m[axis]) * ($1[axis] - m[axis]) }
                    sd[j * 3 + axis] = ShotForm.round((ss / Double(xs.count - 1)).squareRoot(), o.decimals)
                }
            }
            let dts = here.map(\.dt)
            samples.append(FormModelSample(t: ShotForm.round(tau, 6),
                                           dt: dts.isEmpty ? .nan : ShotForm.round(Stats.mean(dts), 4),
                                           dtSD: dts.count >= o.minimumShotsForSpread ? ShotForm.round(Stats.sd(dts), 4) : nil,
                                           mean: mean, sd: sd, n: counts))
            // Angles are computed per shot and then averaged — never off the mean skeleton: even a
            // rigid mean's angle is the angle between mean directions, not the mean of the angles.
            for s in here {
                for (name, theta) in FormSkeleton.angles(at: s.positions) {
                    angleValues[name]?[i].append(theta)
                }
            }
        }

        // ---- angle tracks ---------------------------------------------------------------------------
        var inferred = [Bool](repeating: false, count: J)
        for j in 0..<J { inferred[j] = forms.allSatisfy { $0.inferredBySymmetry.indices.contains(j) && $0.inferredBySymmetry[j] } }
        var tracks: [FormAngleTrack] = []
        for name in FormSkeleton.angleNames {
            let per = angleValues[name] ?? []
            let usesInferred = FormSkeleton.angleDefinitions.first { $0.name == name }.map { d in
                [d.a, d.vertex, d.b].contains { j in FormSkeleton.index(of: j).map { inferred[$0] } ?? false }
            } ?? false
            let anyN = per.reduce(0) { $0 + $1.count }
            tracks.append(FormAngleTrack(name: name,
                                         meanDegrees: per.map { $0.isEmpty ? nil : ShotForm.round(Angle.degrees(Stats.mean($0)), 3) },
                                         sdDegrees: per.map { $0.count >= o.minimumShotsForSpread ? ShotForm.round(Angle.degrees(Stats.sd($0)), 3) : nil },
                                         n: per.map(\.count), usesInferredJoints: usesInferred,
                                         unavailableReason: anyN == 0 ? "no shot in this block had all of this angle's joints on any sample" : nil))
        }

        // ---- tempo -----------------------------------------------------------------------------------
        func stat(_ get: (FormPhaseDurations) -> BodyMeasure, _ what: String) -> FormStat {
            let xs = forms.compactMap { get($0.durations).value }
            let reasons = Set(forms.compactMap { get($0.durations).unavailableReason })
            guard !xs.isEmpty else {
                return FormStat(mean: .missing(.milliseconds, reasons.sorted().first ?? "no shot in this block measured \(what)"),
                                sd: .missing(.milliseconds, reasons.sorted().first ?? "no shot in this block measured \(what)"), n: 0)
            }
            return FormStat(mean: .ok(Stats.mean(xs), .milliseconds),
                            sd: xs.count >= o.minimumShotsForSpread ? .ok(Stats.sd(xs), .milliseconds)
                                : .missing(.milliseconds, "only \(xs.count) shot\(xs.count == 1 ? "" : "s") measured \(what), fewer than the \(o.minimumShotsForSpread) a spread needs"),
                            n: xs.count)
        }
        let tempo = FormTempo(setToDip: stat({ $0.setToDip }, "set → dip"),
                              dipToRelease: stat({ $0.dipToRelease }, "dip → release"),
                              releaseToFollowThrough: stat({ $0.releaseToFollowThrough }, "release → follow-through"),
                              total: stat({ $0.total }, "the whole shot"))

        // ---- coverage ---------------------------------------------------------------------------------
        var seen = [Double](repeating: 0, count: J)
        for j in 0..<J {
            let xs = forms.compactMap { $0.seenFraction.indices.contains(j) ? $0.seenFraction[j] : nil }
            seen[j] = xs.isEmpty ? 0 : ShotForm.round(Stats.mean(xs), 3)
        }
        var refused: [String: String] = [:]
        for f in forms { for (k, v) in f.refusedJoints where refused[k] == nil { refused[k] = v } }
        // A joint refused on *some* shots but present on others is not refused for the block.
        for (j, name) in first.joints.enumerated() where samples.contains(where: { $0.n[j] > 0 }) { refused[name] = nil }

        for (j, name) in first.joints.enumerated() where inferred[j] {
            notes.append("\(name) was never seen on any shot in this block: it is mirrored from the other side of the body, so draw it dashed and read no number off it")
        }
        let gapReasons = Set(forms.flatMap { $0.gaps.map(\.reason) })
        for r in gapReasons.sorted() { notes.append(r) }

        return FormModel(version: formatVersion, label: label, spot: spot, sessionID: sessionID, date: date,
                         joints: first.joints, unit: first.unit, unitNote: first.unitNote,
                         sampleCount: n, samples: samples, angles: tracks, tempo: tempo, bones: bones,
                         shots: forms.count, shotIDs: forms.compactMap(\.shotID),
                         seenFraction: seen, inferredBySymmetry: inferred, refusedJoints: refused,
                         notes: notes, warnings: warnings, unavailableReason: nil)
    }
}

extension FormStat {
    public static var empty: FormStat {
        FormStat(mean: .missing(.milliseconds, "no shots"), sd: .missing(.milliseconds, "no shots"), n: 0)
    }
}

// MARK: - Comparison: one shot against the block

/// How far one joint sat from the block's mean at one phase, in the block's own SDs.
public struct FormJointDeviation: Sendable, Codable, Equatable {
    public var joint: String
    public var phase: String
    /// Root-mean-square of the per-axis z-scores. In SDs, so it is comparable across joints.
    public var deviationSDs: BodyMeasure
    /// The same difference as a length, in the model's unit.
    public var displacement: BodyMeasure
    /// Per body axis (x toward the rim, y across the body, z up), the z-score, or nil where that
    /// axis had no spread to divide by.
    public var axisSDs: [Double?]
    public var inferredBySymmetry: Bool
}

public struct FormAngleDeviation: Sendable, Codable, Equatable {
    public var name: String
    public var phase: String
    public var shotDegrees: Double?
    public var modelMeanDegrees: Double?
    public var modelSDDegrees: Double?
    public var deviationSDs: BodyMeasure
    public var unavailableReason: String?
}

public struct FormComparison: Sendable, Codable, Equatable {
    public var label: String
    public var joints: [FormJointDeviation]
    public var angles: [FormAngleDeviation]
    /// Tempo: this shot's durations against the block's, in the block's SDs.
    public var tempo: [String: BodyMeasure]
    public var notes: [String]
    public var unavailableReason: String?

    /// The joints that sat furthest from the block, worst first. Only ones with a real number.
    public var ranked: [FormJointDeviation] {
        joints.filter { $0.deviationSDs.value != nil }.sorted { ($0.deviationSDs.value ?? 0) > ($1.deviationSDs.value ?? 0) }
    }
}

extension FormModel {

    /// One shot against this block's mean form: per joint, per phase, how many SDs out it sat.
    public func compare(shot: ShotForm, options o: FormOptions = .init()) -> FormComparison {
        guard isAvailable else {
            return FormComparison(label: label, joints: [], angles: [], tempo: [:], notes: [],
                                  unavailableReason: unavailableReason ?? "this block has no form to compare against")
        }
        guard shot.unit == unit else {
            return FormComparison(label: label, joints: [], angles: [], tempo: [:], notes: [],
                                  unavailableReason: "this shot is in \(shot.unit.rawValue) and the block's form is in \(unit.rawValue): they are not comparable")
        }
        guard shots >= o.minimumShotsForSpread else {
            return FormComparison(label: label, joints: [], angles: [], tempo: [:], notes: [],
                                  unavailableReason: "this block has \(shots) shot\(shots == 1 ? "" : "s"): a deviation in SDs needs at least \(o.minimumShotsForSpread) to have an SD at all")
        }
        var out: [FormJointDeviation] = []
        var angleOut: [FormAngleDeviation] = []
        let unitName = unit == .metres ? BodyMeasure.Unit.metres : .ratio

        for phase in FormPhase.allCases {
            guard let ms = sample(at: phase) else { continue }
            guard let ss = shot.sample(at: phase) else { continue }
            for (j, name) in joints.enumerated() {
                let inferredHere = (inferredBySymmetry.indices.contains(j) && inferredBySymmetry[j])
                    || (shot.inferredBySymmetry.indices.contains(j) && shot.inferredBySymmetry[j])
                guard let p = ss.position(j), let m = ms.position(j) else {
                    let why = "neither the shot nor the block had \(name) at the \(phase.label.lowercased())"
                    out.append(FormJointDeviation(joint: name, phase: phase.rawValue,
                                                  deviationSDs: .missing(.ratio, why),
                                                  displacement: .missing(unitName, why),
                                                  axisSDs: [nil, nil, nil], inferredBySymmetry: inferredHere))
                    continue
                }
                let d = p - m
                var zs: [Double?] = [nil, nil, nil]
                var squares: [Double] = []
                if let s = ms.spread(j) {
                    for axis in 0..<3 {
                        let sa = s[axis]
                        guard sa > o.minimumSpread else { continue }
                        let z = d[axis] / sa
                        zs[axis] = ShotForm.round(z, 3)
                        squares.append(z * z)
                    }
                }
                let dev: BodyMeasure
                if squares.isEmpty {
                    let why = phase == .set && (name == Body2DPoint.leftHip || name == Body2DPoint.rightHip)
                        ? "the body frame's origin is the mid-hip at the set point, so the hips have no spread there by construction"
                        : "the block's \(ms.n[j]) shot\(ms.n[j] == 1 ? "" : "s") at this phase give no spread for \(name) to be measured against"
                    dev = .missing(.ratio, why)
                } else {
                    dev = .ok((squares.reduce(0, +) / Double(squares.count)).squareRoot(), .ratio)
                }
                out.append(FormJointDeviation(joint: name, phase: phase.rawValue, deviationSDs: dev,
                                              displacement: .ok(simd_length(d), unitName),
                                              axisSDs: zs, inferredBySymmetry: inferredHere))
            }
            // Angles at this phase.
            let idx = Int((phase.normalisedTime * Double(sampleCount - 1)).rounded())
            let shotAngles = FormSkeleton.angles(at: ss.positions)
            for track in angles {
                let mean = track.meanDegrees.indices.contains(idx) ? track.meanDegrees[idx] : nil
                let sd = track.sdDegrees.indices.contains(idx) ? track.sdDegrees[idx] : nil
                let v = shotAngles[track.name].map(Angle.degrees)
                var dev: BodyMeasure
                var why: String? = nil
                if let v, let mean, let sd, sd > o.minimumSpread {
                    dev = .ok((v - mean) / sd, .ratio)
                } else {
                    why = v == nil ? "this shot had no \(track.name) at the \(phase.label.lowercased())"
                        : (mean == nil ? "the block had no \(track.name) at the \(phase.label.lowercased())"
                                       : "the block's \(track.name) has no spread at the \(phase.label.lowercased()) to measure against")
                    dev = .missing(.ratio, why!)
                }
                angleOut.append(FormAngleDeviation(name: track.name, phase: phase.rawValue,
                                                   shotDegrees: v.map { ShotForm.round($0, 2) },
                                                   modelMeanDegrees: mean, modelSDDegrees: sd,
                                                   deviationSDs: dev, unavailableReason: why))
            }
        }

        // Tempo, in the block's SDs.
        func tempoZ(_ shotValue: BodyMeasure, _ stat: FormStat, _ what: String) -> BodyMeasure {
            guard let v = shotValue.value else { return .missing(.ratio, shotValue.unavailableReason ?? "this shot did not measure \(what)") }
            guard let m = stat.mean.value else { return .missing(.ratio, stat.mean.unavailableReason ?? "the block did not measure \(what)") }
            guard let s = stat.sd.value, s > o.minimumSpread else { return .missing(.ratio, stat.sd.unavailableReason ?? "the block's \(what) has no spread") }
            return .ok((v - m) / s, .ratio)
        }
        let tempoOut: [String: BodyMeasure] = [
            "setToDip": tempoZ(shot.durations.setToDip, tempo.setToDip, "set → dip"),
            "dipToRelease": tempoZ(shot.durations.dipToRelease, tempo.dipToRelease, "dip → release"),
            "releaseToFollowThrough": tempoZ(shot.durations.releaseToFollowThrough, tempo.releaseToFollowThrough, "release → follow-through"),
            "total": tempoZ(shot.durations.total, tempo.total, "the whole shot"),
        ]

        var notes: [String] = []
        if shotIDs.contains(where: { shot.shotID == $0 }) {
            notes.append("this shot is one of the \(shots) in the block, so it is being compared with a mean it is itself part of")
        }
        return FormComparison(label: label, joints: out, angles: angleOut, tempo: tempoOut, notes: notes, unavailableReason: nil)
    }
}

// MARK: - Comparison: block against block

public struct FormModelDifference: Sendable, Codable, Equatable {
    public var joint: String
    public var phase: String
    /// Difference of the two means, in the pooled SD. Positive means B sits further along that axis.
    public var differenceSDs: BodyMeasure
    public var displacement: BodyMeasure
    public var axisSDs: [Double?]
}

public struct FormModelComparison: Sendable, Codable, Equatable {
    public var a: String, b: String
    public var joints: [FormModelDifference]
    /// Per angle, per phase: (B − A) in degrees, with each block's own SD beside it.
    public var angles: [FormAngleDifference]
    public var tempo: [String: FormStatDifference]
    public var notes: [String]
    public var unavailableReason: String?

    public var ranked: [FormModelDifference] {
        joints.filter { $0.differenceSDs.value != nil }
            .sorted { abs($0.differenceSDs.value ?? 0) > abs($1.differenceSDs.value ?? 0) }
    }
}

public struct FormAngleDifference: Sendable, Codable, Equatable {
    public var name: String
    public var phase: String
    public var aMeanDegrees: Double?, aSDDegrees: Double?, aN: Int
    public var bMeanDegrees: Double?, bSDDegrees: Double?, bN: Int
    public var differenceDegrees: Double?
    public var differenceSDs: BodyMeasure
}

public struct FormStatDifference: Sendable, Codable, Equatable {
    public var aMilliseconds: BodyMeasure
    public var bMilliseconds: BodyMeasure
    public var differenceMilliseconds: BodyMeasure
    public var differenceSDs: BodyMeasure
}

extension FormModel {

    /// Two blocks against each other — the progress comparison. Differences are in the **pooled** SD
    /// of the two blocks, so "1.2 SDs" means the same thing whichever block is noisier.
    public static func compare(_ a: FormModel, with b: FormModel, options o: FormOptions = .init()) -> FormModelComparison {
        guard a.isAvailable, b.isAvailable else {
            return FormModelComparison(a: a.label, b: b.label, joints: [], angles: [], tempo: [:], notes: [],
                                       unavailableReason: (a.unavailableReason ?? b.unavailableReason) ?? "one of these blocks has no form")
        }
        guard a.unit == b.unit else {
            return FormModelComparison(a: a.label, b: b.label, joints: [], angles: [], tempo: [:], notes: [],
                                       unavailableReason: "\(a.label) is in \(a.unit.rawValue) and \(b.label) in \(b.unit.rawValue): a height was given for one session and not the other, so they do not compare")
        }
        guard a.joints == b.joints, a.sampleCount == b.sampleCount else {
            return FormModelComparison(a: a.label, b: b.label, joints: [], angles: [], tempo: [:], notes: [],
                                       unavailableReason: "these two blocks were built on different grids")
        }
        let unitName = a.unit == .metres ? BodyMeasure.Unit.metres : .ratio
        var joints: [FormModelDifference] = []
        for phase in FormPhase.allCases {
            guard let sa = a.sample(at: phase), let sb = b.sample(at: phase) else { continue }
            for (j, name) in a.joints.enumerated() {
                guard let pa = sa.position(j), let pb = sb.position(j) else {
                    let why = "\(name) is missing at the \(phase.label.lowercased()) in \(sa.position(j) == nil ? a.label : b.label)"
                    joints.append(FormModelDifference(joint: name, phase: phase.rawValue,
                                                      differenceSDs: .missing(.ratio, why),
                                                      displacement: .missing(unitName, why), axisSDs: [nil, nil, nil]))
                    continue
                }
                let d = pb - pa
                var zs: [Double?] = [nil, nil, nil]
                var squares: [Double] = []
                if let va = sa.spread(j), let vb = sb.spread(j) {
                    for axis in 0..<3 {
                        let pooled = ((va[axis] * va[axis] + vb[axis] * vb[axis]) / 2).squareRoot()
                        guard pooled > o.minimumSpread else { continue }
                        let z = d[axis] / pooled
                        zs[axis] = ShotForm.round(z, 3)
                        squares.append(z * z)
                    }
                }
                let dev: BodyMeasure = squares.isEmpty
                    ? .missing(.ratio, "one of the two blocks has no spread for \(name) at the \(phase.label.lowercased()), so a difference in SDs cannot be formed")
                    : .ok((squares.reduce(0, +) / Double(squares.count)).squareRoot(), .ratio)
                joints.append(FormModelDifference(joint: name, phase: phase.rawValue, differenceSDs: dev,
                                                  displacement: .ok(simd_length(d), unitName), axisSDs: zs))
            }
        }

        var angles: [FormAngleDifference] = []
        for phase in FormPhase.allCases {
            let idx = Int((phase.normalisedTime * Double(a.sampleCount - 1)).rounded())
            for ta in a.angles {
                guard let tb = b.angles.first(where: { $0.name == ta.name }) else { continue }
                func at(_ xs: [Double?]) -> Double? { xs.indices.contains(idx) ? xs[idx] : nil }
                let am = at(ta.meanDegrees), bm = at(tb.meanDegrees)
                let asd = at(ta.sdDegrees), bsd = at(tb.sdDegrees)
                let an = ta.n.indices.contains(idx) ? ta.n[idx] : 0
                let bn = tb.n.indices.contains(idx) ? tb.n[idx] : 0
                var dev: BodyMeasure = .missing(.ratio, "one of the two blocks has no spread for \(ta.name) at the \(phase.label.lowercased())")
                var diff: Double? = nil
                if let am, let bm {
                    diff = ShotForm.round(bm - am, 3)
                    if let asd, let bsd {
                        let pooled = ((asd * asd + bsd * bsd) / 2).squareRoot()
                        if pooled > o.minimumSpread { dev = .ok((bm - am) / pooled, .ratio) }
                    }
                } else {
                    dev = .missing(.ratio, "\(ta.name) is missing at the \(phase.label.lowercased()) in \(am == nil ? a.label : b.label)")
                }
                angles.append(FormAngleDifference(name: ta.name, phase: phase.rawValue,
                                                  aMeanDegrees: am, aSDDegrees: asd, aN: an,
                                                  bMeanDegrees: bm, bSDDegrees: bsd, bN: bn,
                                                  differenceDegrees: diff, differenceSDs: dev))
            }
        }

        func tempoDiff(_ sa: FormStat, _ sb: FormStat, _ what: String) -> FormStatDifference {
            var diff: BodyMeasure = .missing(.milliseconds, "one of the two blocks did not measure \(what)")
            var dev: BodyMeasure = .missing(.ratio, "one of the two blocks has no spread on \(what)")
            if let ma = sa.mean.value, let mb = sb.mean.value {
                diff = .ok(mb - ma, .milliseconds)
                if let da = sa.sd.value, let db = sb.sd.value {
                    let pooled = ((da * da + db * db) / 2).squareRoot()
                    if pooled > o.minimumSpread { dev = .ok((mb - ma) / pooled, .ratio) }
                }
            }
            return FormStatDifference(aMilliseconds: sa.mean, bMilliseconds: sb.mean,
                                      differenceMilliseconds: diff, differenceSDs: dev)
        }
        let tempo: [String: FormStatDifference] = [
            "setToDip": tempoDiff(a.tempo.setToDip, b.tempo.setToDip, "set → dip"),
            "dipToRelease": tempoDiff(a.tempo.dipToRelease, b.tempo.dipToRelease, "dip → release"),
            "releaseToFollowThrough": tempoDiff(a.tempo.releaseToFollowThrough, b.tempo.releaseToFollowThrough, "release → follow-through"),
            "total": tempoDiff(a.tempo.total, b.tempo.total, "the whole shot"),
        ]

        var notes: [String] = []
        if a.unit == .shooterHeights {
            notes.append("both blocks are in shooter heights, so this compares shapes and ratios; with a standing height the same comparison would be in metres")
        }
        for (j, name) in a.joints.enumerated() where (a.inferredBySymmetry.indices.contains(j) && a.inferredBySymmetry[j]) || (b.inferredBySymmetry.indices.contains(j) && b.inferredBySymmetry[j]) {
            notes.append("\(name) was never seen in one of these blocks and is mirrored there: its difference is between a measurement and an inference")
        }
        return FormModelComparison(a: a.label, b: b.label, joints: joints, angles: angles, tempo: tempo,
                                   notes: notes, unavailableReason: nil)
    }
}

// MARK: - The shooter's own best reps (the self-model ghost)

/// One rep the best-rep rule may choose from: the shot's form and the two ball numbers the rule
/// reads. Nothing is derived here — every field is a number the pipeline already measured, or nil
/// with the pipeline's own silence.
public struct FormRep: Sendable, Equatable {
    public var shotID: Int?
    public var form: ShotForm
    /// Only shots the block rule accepted may be chosen: a rejected window's form is not evidence.
    public var accepted: Bool
    /// Where the ball crossed the rim plane, metres past the front rim. Nil on a clip with no rim.
    public var depthPastFrontRim: Double?
    /// Release speed, m/s. Nil where the fit refused it.
    public var releaseSpeed: Double?

    public init(shotID: Int?, form: ShotForm, accepted: Bool,
                depthPastFrontRim: Double?, releaseSpeed: Double?) {
        self.shotID = shotID
        self.form = form
        self.accepted = accepted
        self.depthPastFrontRim = depthPastFrontRim
        self.releaseSpeed = releaseSpeed
    }
}

/// The thresholds the rule is written against. The make band is the one the app already uses for a
/// shot that goes in off the middle of the rim (docs/reference/digest-constants-and-corrections.md);
/// the speed band is the shooter's own, one SD of their own block.
public struct FormBestRepOptions: Sendable, Equatable {
    /// Metres past the front rim. A shot crossing here is one of the shooter's own good ones.
    public var makeBand: ClosedRange<Double> = 0.25...0.28
    /// How far from the pool's mean release speed a rep may sit, in the pool's own SDs.
    public var speedSDs: Double = 1.0
    /// Below this many qualifying reps the ghost is the pool's mean instead, and says so.
    public var minimumReps: Int = 5
    public init() {}
}

/// What the rule chose, and everything it looked at — so the screen can print a sentence rather
/// than a silent fallback.
public struct FormBestReps: Sendable, Equatable {
    /// The forms the ghost should be built from: the best reps when `isBestRepGhost`, otherwise
    /// every accepted form in the pool (the block mean), or empty when there is nothing to draw.
    public var forms: [ShotForm]
    public var shotIDs: [Int]
    /// True only when the full rule was satisfied by `minimumReps` reps or more.
    public var isBestRepGhost: Bool
    /// The one line the legend prints.
    public var legend: String
    /// How many accepted forms the rule started from.
    public var accepted: Int
    /// How many of those crossed inside the make band.
    public var inMakeBand: Int
    /// How many of the make-band reps were also inside the speed band.
    public var chosen: Int
    /// The pool's own release speed, m/s, when it could be formed at all.
    public var speedMeanMetresPerSecond: Double?
    public var speedSDMetresPerSecond: Double?
    /// Set when there is not even a mean to ghost.
    public var unavailableReason: String?

    public var isAvailable: Bool { unavailableReason == nil && !forms.isEmpty }
}

extension FormModel {

    /// Choose the shooter's own best reps out of a pool of their measured shots.
    ///
    /// The rule is deliberately made of numbers that already exist, so nothing here is a new
    /// measurement: **accepted** shots whose **crossing depth past the front rim** is inside the make
    /// band and whose **release speed** is inside one SD of the pool's own mean. Fewer than
    /// `minimumReps` of those and the caller is told to ghost the pool's mean instead — the sentence
    /// to print comes back in `legend`, with the counts in it.
    ///
    /// Pure: no clock, no I/O, no ordering assumptions. The forms come back in the order given.
    public static func bestReps(_ reps: [FormRep], options o: FormBestRepOptions = .init()) -> FormBestReps {
        let accepted = reps.filter(\.accepted)
        let bandCm = (lo: o.makeBand.lowerBound * 100, hi: o.makeBand.upperBound * 100)

        func fallback(_ why: String) -> FormBestReps {
            FormBestReps(forms: accepted.map(\.form), shotIDs: accepted.compactMap(\.shotID),
                         isBestRepGhost: false, legend: why, accepted: accepted.count,
                         inMakeBand: 0, chosen: 0,
                         speedMeanMetresPerSecond: nil, speedSDMetresPerSecond: nil,
                         unavailableReason: accepted.isEmpty
                            ? (reps.isEmpty
                               ? "no measured shot was handed to the ghost, so there is nothing of your own to draw"
                               : "none of these \(reps.count) shot\(reps.count == 1 ? " was" : "s were") accepted by the block rule, so there is no form of yours to ghost")
                            : nil)
        }

        guard !accepted.isEmpty else { return fallback("nothing to ghost") }

        // ---- the pool's own release speed ----
        let speeds = accepted.compactMap(\.releaseSpeed)
        guard speeds.count >= 2 else {
            return fallback("ghost = block mean; a best-rep ghost needs a release-speed spread to measure against and this block has \(speeds.count) speed\(speeds.count == 1 ? "" : "s")")
        }
        let mean = Stats.mean(speeds), sd = Stats.sd(speeds)
        guard sd.isFinite, sd > 1e-9 else {
            return fallback("ghost = block mean; every accepted shot here has the same release speed, so \"within 1 SD\" picks nothing out")
        }

        // ---- the make band ----
        let depths = accepted.compactMap(\.depthPastFrontRim)
        guard !depths.isEmpty else {
            var r = fallback("ghost = block mean; no shot in this block has a crossing depth (a clip with no rim in it measures none), so the best reps cannot be picked")
            r.speedMeanMetresPerSecond = mean
            r.speedSDMetresPerSecond = sd
            return r
        }
        let inBand = accepted.filter { rep in
            guard let d = rep.depthPastFrontRim else { return false }
            return o.makeBand.contains(d)
        }
        let chosen = inBand.filter { rep in
            guard let v = rep.releaseSpeed else { return false }
            return abs(v - mean) <= o.speedSDs * sd
        }

        if chosen.count >= o.minimumReps {
            return FormBestReps(forms: chosen.map(\.form), shotIDs: chosen.compactMap(\.shotID),
                                isBestRepGhost: true,
                                legend: String(format: "ghost = your %d best reps: crossed %.0f–%.0f cm past the front rim, released within 1 SD of your own %.1f ± %.1f m/s",
                                               chosen.count, bandCm.lo, bandCm.hi, mean, sd),
                                accepted: accepted.count, inMakeBand: inBand.count, chosen: chosen.count,
                                speedMeanMetresPerSecond: mean, speedSDMetresPerSecond: sd,
                                unavailableReason: nil)
        }

        // ---- not enough: the mean, and why ----
        var why = "ghost = block mean, best-rep ghost needs \(o.minimumReps) make-band shots; you have \(inBand.count)"
        if inBand.count >= o.minimumReps {
            why = "ghost = block mean, best-rep ghost needs \(o.minimumReps) make-band shots released within 1 SD of your own speed; \(inBand.count) landed in the band but only \(chosen.count) of those were on speed"
        }
        var r = fallback(why)
        r.inMakeBand = inBand.count
        r.chosen = chosen.count
        r.speedMeanMetresPerSecond = mean
        r.speedSDMetresPerSecond = sd
        return r
    }
}

// MARK: - The export

/// The one JSON the app, the CLI and the viewer all read and write. Compact (no pretty printing,
/// positions already rounded on the way in) and versioned: `version` is `ShotForm.formatVersion` /
/// `FormModel.formatVersion`, and a reader that does not know a version refuses rather than guesses.
public enum FormJSON {
    public static let version = FormModel.formatVersion

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    public enum Failure: Error, CustomStringConvertible {
        case unknownVersion(Int)
        public var description: String {
            switch self {
            case .unknownVersion(let v):
                return "this form was written by format version \(v) and this build reads version \(FormJSON.version): it is not decoded rather than guessed at"
            }
        }
    }

    public static func decodeForm(_ data: Data) throws -> ShotForm {
        let f = try decode(ShotForm.self, from: data)
        guard f.version == version else { throw Failure.unknownVersion(f.version) }
        return f
    }

    public static func decodeModel(_ data: Data) throws -> FormModel {
        let m = try decode(FormModel.self, from: data)
        guard m.version == version else { throw Failure.unknownVersion(m.version) }
        return m
    }
}
