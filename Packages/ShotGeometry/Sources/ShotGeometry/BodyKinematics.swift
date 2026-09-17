import Foundation
import simd

// BodyKinematics — the per-shot body model: true 3-D joint angles, shot phases, the kinetic chain,
// stance, head and hand metrics, computed from a `BodyTimeline` (filled by `ShotVideo.BodyTracker`,
// or by hand in tests). Foundation + simd only, per CLAUDE.md rule 2.
//
// Conventions
//  * Radians in code, degrees only at a printed boundary (`BodyMeasure.degrees`), per rule 4.
//  * Every number is a `BodyMeasure`: either a value, or nil **with a reason**, per rule 1.
//  * 3-D positions are metres in **camera space**: +x camera-right, +y up, +z toward the camera
//    (Vision's `cameraRelativePosition` convention). "Up" is therefore the camera's up, which is
//    true vertical only for a level camera; `BodyModel.warnings` says so when the torso disagrees.
//  * Image points are full-frame pixels, top-left origin, **v increasing downwards** (NOTATION.md).

// MARK: - One number, or a reason there is none

/// A single measurement. `value == nil` always carries `unavailableReason` — the type makes the
/// CLAUDE.md rule structural rather than a convention.
public struct BodyMeasure: Sendable, Codable, Equatable {
    public enum Unit: String, Sendable, Codable {
        case radians, metres, seconds, milliseconds, pixels
        case radiansPerSecond, pixelsPerSecond, metresPerSecond, ratio, count
    }
    public var value: Double?
    public var unit: Unit
    public var unavailableReason: String?

    public init(value: Double?, unit: Unit, unavailableReason: String?) {
        precondition(value != nil || unavailableReason != nil, "a nil measurement must carry a reason")
        self.value = value; self.unit = unit; self.unavailableReason = unavailableReason
    }
    public static func ok(_ v: Double, _ u: Unit) -> BodyMeasure {
        v.isFinite ? .init(value: v, unit: u, unavailableReason: nil)
                   : .init(value: nil, unit: u, unavailableReason: "the computation produced a non-finite number")
    }
    public static func missing(_ u: Unit, _ reason: String) -> BodyMeasure { .init(value: nil, unit: u, unavailableReason: reason) }

    public var isAvailable: Bool { value != nil }
    /// Degrees at the boundary. Nil for units that are not angular — never a silent reinterpretation.
    public var degrees: Double? {
        switch unit {
        case .radians, .radiansPerSecond: return value.map(Angle.degrees)
        default: return nil
        }
    }
    /// Printable: degrees for angular units, the raw value otherwise, or the reason.
    public func describe(_ format: String = "%.2f") -> String {
        guard let v = value else { return "nil (\(unavailableReason ?? "no reason recorded"))" }
        switch unit {
        case .radians: return String(format: format + "°", Angle.degrees(v))
        case .radiansPerSecond: return String(format: format + "°/s", Angle.degrees(v))
        case .metres: return String(format: format + " m", v)
        case .metresPerSecond: return String(format: format + " m/s", v)
        case .seconds: return String(format: format + " s", v)
        case .milliseconds: return String(format: format + " ms", v)
        case .pixels: return String(format: format + " px", v)
        case .pixelsPerSecond: return String(format: format + " px/s", v)
        case .ratio, .count: return String(format: format, v)
        }
    }
}

// MARK: - Canonical joint names (what `BodyTracker` writes and `BodyKinematics` looks up)

/// The 17 joints of Apple's 3-D body model. Names are the canonical ArcLab spelling; `BodyTracker`
/// maps Vision's own names onto these so the two can never drift silently.
public enum Body3DJoint {
    public static let topHead = "topHead", centerHead = "centerHead", centerShoulder = "centerShoulder"
    public static let leftShoulder = "leftShoulder", rightShoulder = "rightShoulder"
    public static let leftElbow = "leftElbow", rightElbow = "rightElbow"
    public static let leftWrist = "leftWrist", rightWrist = "rightWrist"
    public static let leftHip = "leftHip", rightHip = "rightHip"
    public static let leftKnee = "leftKnee", rightKnee = "rightKnee"
    public static let leftAnkle = "leftAnkle", rightAnkle = "rightAnkle"
    public static let root = "root", spine = "spine"
    public static let all = [topHead, centerHead, centerShoulder, leftShoulder, rightShoulder,
                             leftElbow, rightElbow, leftWrist, rightWrist, leftHip, rightHip,
                             leftKnee, rightKnee, leftAnkle, rightAnkle, root, spine]

    // --- appendage joints (1.3) ---------------------------------------------------------------
    // Not Apple's: the hand plate's two front corners, written by `HandTriangleFit` and carrying the
    // same names as their 2-D points so a reader never has to map between two spellings. Feet
    // (heel / big toe / little toe) belong in this block when they arrive.
    public static let leftIndexMCP = Body2DPoint.leftIndexMCP, rightIndexMCP = Body2DPoint.rightIndexMCP
    public static let leftLittleMCP = Body2DPoint.leftLittleMCP, rightLittleMCP = Body2DPoint.rightLittleMCP
    public static let handCorners = [leftIndexMCP, rightIndexMCP, leftLittleMCP, rightLittleMCP]
    public static let appendages = handCorners
    public static let allIncludingAppendages = all + appendages
}

/// The 19 points of Apple's 2-D body model — the four face points are the head-direction cues.
public enum Body2DPoint {
    public static let nose = "nose", neck = "neck", root = "root"
    public static let leftEye = "leftEye", rightEye = "rightEye", leftEar = "leftEar", rightEar = "rightEar"
    public static let leftShoulder = "leftShoulder", rightShoulder = "rightShoulder"
    public static let leftElbow = "leftElbow", rightElbow = "rightElbow"
    public static let leftWrist = "leftWrist", rightWrist = "rightWrist"
    public static let leftHip = "leftHip", rightHip = "rightHip"
    public static let leftKnee = "leftKnee", rightKnee = "rightKnee"
    public static let leftAnkle = "leftAnkle", rightAnkle = "rightAnkle"
    public static let all = [nose, neck, root, leftEye, rightEye, leftEar, rightEar,
                             leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist,
                             leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle]

    // --- appendage points (1.3, 2026-09-16) ---------------------------------------------------
    // Not Vision's body model: these come from a *second* detector and are lifted into the same
    // name space so the fit, the coverage table, the export and the form all see them the way they
    // see a shoulder. `all` stays the 19 Apple returns, so nothing that means "the body pose"
    // silently changes meaning; `allIncludingAppendages` is the list to iterate when the question is
    // "every 2-D point this timeline could carry".
    //
    // The hand triangle: the wrist at the back, the index MCP at the front-inner (thumb side) and
    // the little MCP at the front-outer corner. `…HandWrist` is the *hand* detector's own wrist
    // landmark, kept beside `…Wrist` rather than merged into it, so the two detectors never
    // overwrite each other silently (`HandPoints.lift` is the one place a hand-pose wrist may stand
    // in for a missing body-pose one, and it stamps the provenance when it does).
    //
    // Feet come next (heel / big toe / little toe, a new detector): add them here, add them to
    // `appendages`, and every consumer below picks them up without another edit.
    public static let leftIndexMCP = "leftIndexMCP", rightIndexMCP = "rightIndexMCP"
    public static let leftLittleMCP = "leftLittleMCP", rightLittleMCP = "rightLittleMCP"
    public static let leftHandWrist = "leftHandWrist", rightHandWrist = "rightHandWrist"
    /// The hand triangle's two front corners, the points a fitted plate needs beyond the wrist.
    public static let handCorners = [leftIndexMCP, rightIndexMCP, leftLittleMCP, rightLittleMCP]
    /// Every appendage point, hands today and feet when they arrive.
    public static let appendages = handCorners + [leftHandWrist, rightHandWrist]
    public static let allIncludingAppendages = all + appendages
}

/// The 21 landmarks of Apple's hand model.
public enum HandLandmark {
    public static let wrist = "wrist"
    public static let thumbCMC = "thumbCMC", thumbMP = "thumbMP", thumbIP = "thumbIP", thumbTip = "thumbTip"
    public static let indexMCP = "indexMCP", indexPIP = "indexPIP", indexDIP = "indexDIP", indexTip = "indexTip"
    public static let middleMCP = "middleMCP", middlePIP = "middlePIP", middleDIP = "middleDIP", middleTip = "middleTip"
    public static let ringMCP = "ringMCP", ringPIP = "ringPIP", ringDIP = "ringDIP", ringTip = "ringTip"
    public static let littleMCP = "littleMCP", littlePIP = "littlePIP", littleDIP = "littleDIP", littleTip = "littleTip"
    public static let fingertips = [thumbTip, indexTip, middleTip, ringTip, littleTip]
    public static let all = [wrist, thumbCMC, thumbMP, thumbIP, thumbTip,
                             indexMCP, indexPIP, indexDIP, indexTip, middleMCP, middlePIP, middleDIP, middleTip,
                             ringMCP, ringPIP, ringDIP, ringTip, littleMCP, littlePIP, littleDIP, littleTip]
}

// MARK: - Timeline (what the tracker produces, what the kinematics consume)

/// The pixel rectangle of the full frame that was actually handed to the detector.
public struct BodyCrop: Sendable, Codable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// One 3-D joint. `confidence` is nil whenever the source model does not publish a per-joint
/// confidence — Apple's `Joint3D` has none, and inventing one would be fabricating a number.
public struct BodyJoint3D: Sendable, Codable {
    public var name: String
    public var position: SIMD3<Double>        // metres, relative to the root joint (model space)
    public var cameraPosition: SIMD3<Double>  // metres, camera space (+x right, +y up, +z toward camera)
    public var imageU: Double?
    public var imageV: Double?
    public var confidence: Double?
    public init(name: String, position: SIMD3<Double>, cameraPosition: SIMD3<Double>,
                imageU: Double? = nil, imageV: Double? = nil, confidence: Double? = nil) {
        self.name = name; self.position = position; self.cameraPosition = cameraPosition
        self.imageU = imageU; self.imageV = imageV; self.confidence = confidence
    }
}

public struct BodyPoint2D: Sendable, Codable {
    public var name: String
    public var u: Double, v: Double, confidence: Double
    /// How this point came to be here, when it is anything other than "the detector that owns this
    /// name returned it". Nil is the ordinary case and means exactly that. Set by `HandPoints.lift`
    /// for a wrist taken from the hand pose, for a point carried across one sampled frame, and for a
    /// hand sided by proximity rather than by the detector's chirality. Optional, so a timeline
    /// written before 1.3 decodes unchanged.
    public var provenance: String?
    public init(name: String, u: Double, v: Double, confidence: Double, provenance: String? = nil) {
        self.name = name; self.u = u; self.v = v; self.confidence = confidence; self.provenance = provenance
    }
    public var uv: SIMD2<Double> { SIMD2(u, v) }
}

public struct BodyHandFrame: Sendable, Codable {
    /// Vision's chirality as reported ("left"/"right"), or nil when the detector did not say.
    public var chirality: String?
    /// "shooting" / "guide" when the tracker could tell them apart, else nil.
    public var role: String?
    public var confidence: Double
    public var landmarks: [String: BodyPoint2D]
    public init(chirality: String?, role: String?, confidence: Double, landmarks: [String: BodyPoint2D]) {
        self.chirality = chirality; self.role = role; self.confidence = confidence; self.landmarks = landmarks
    }
}

public struct BodyFrame: Sendable, Codable {
    public var frameIndex: Int
    public var fileTime: Double        // seconds on the file clock (the `BallDetection.pts` clock)
    public var realTime: Double        // fileTime / timeScale
    public var joints3D: [String: BodyJoint3D]
    public var points2D: [String: BodyPoint2D]
    public var hands: [BodyHandFrame]
    public var crop: BodyCrop?
    public var bodyHeightMetres: Double?
    /// "measured" (a depth sensor set the scale) or "reference" (a population prior did).
    public var heightEstimationTechnique: String?
    public var confidence3D: Double?
    public var confidence2D: Double?
    public init(frameIndex: Int, fileTime: Double, realTime: Double,
                joints3D: [String: BodyJoint3D] = [:], points2D: [String: BodyPoint2D] = [:],
                hands: [BodyHandFrame] = [], crop: BodyCrop? = nil, bodyHeightMetres: Double? = nil,
                heightEstimationTechnique: String? = nil, confidence3D: Double? = nil, confidence2D: Double? = nil) {
        self.frameIndex = frameIndex; self.fileTime = fileTime; self.realTime = realTime
        self.joints3D = joints3D; self.points2D = points2D; self.hands = hands; self.crop = crop
        self.bodyHeightMetres = bodyHeightMetres; self.heightEstimationTechnique = heightEstimationTechnique
        self.confidence3D = confidence3D; self.confidence2D = confidence2D
    }
}

/// How long each part of the tracker pass took, in seconds of wall time. Every field is measured;
/// nothing here is apportioned or estimated, so the parts need not add up to `wallSeconds` (the
/// decode and the requests overlap when the tracker runs them concurrently).
public struct BodyStageCost: Sendable, Codable, Equatable {
    public var decodeSeconds: Double = 0
    public var cropSeconds: Double = 0
    public var body2DSeconds: Double = 0
    public var body3DSeconds: Double = 0
    public var handsSeconds: Double = 0
    /// How many frames each request actually ran on (they can be decimated independently).
    public var body2DFrames: Int = 0
    public var body3DFrames: Int = 0
    public var handsFrames: Int = 0
    /// When the requests run concurrently their individual times cannot be separated, so the whole
    /// block is timed once here and the per-request fields carry only the frame counts.
    public var concurrentSeconds: Double = 0
    public var concurrentFrames: Int = 0
    public init() {}
    public func msPerFrame(_ seconds: Double, _ frames: Int) -> Double? {
        frames > 0 ? 1000 * seconds / Double(frames) : nil
    }
}

public struct BodyTimeline: Sendable, Codable {
    public var frames: [BodyFrame]
    public var timeScale: Double          // file seconds per real second (4 for a 120 fps clip written at 30)
    public var imageWidth: Int
    public var imageHeight: Int
    public var everyNthFrame: Int
    public var decodedFrames: Int
    public var analysedFrames: Int
    public var wallSeconds: Double        // how long the pass took
    public var notes: [String]
    /// Per-request wall time (iteration 3). Nil when the producer did not measure it — an older
    /// timeline read back from JSON has no such key, and `nil` says so rather than printing zeros.
    public var cost: BodyStageCost?
    public init(frames: [BodyFrame], timeScale: Double, imageWidth: Int, imageHeight: Int,
                everyNthFrame: Int, decodedFrames: Int, analysedFrames: Int, wallSeconds: Double, notes: [String],
                cost: BodyStageCost? = nil) {
        self.frames = frames; self.timeScale = timeScale; self.imageWidth = imageWidth; self.imageHeight = imageHeight
        self.everyNthFrame = everyNthFrame; self.decodedFrames = decodedFrames; self.analysedFrames = analysedFrames
        self.wallSeconds = wallSeconds; self.notes = notes; self.cost = cost
    }
    /// Analysed frames per second of wall time on this machine.
    public var framesPerSecondAchieved: Double { wallSeconds > 0 ? Double(analysedFrames) / wallSeconds : 0 }
}

/// One ball sample on the **real** clock, in full-frame pixels.
public struct BodyBallSample: Sendable, Codable {
    public var t: Double, u: Double, v: Double, diameterPx: Double
    public init(t: Double, u: Double, v: Double, diameterPx: Double) { self.t = t; self.u = u; self.v = v; self.diameterPx = diameterPx }
}

// MARK: - Angle primitives

public enum BodyAngles {
    /// Angle between two 3-D vectors, radians in [0, π]. Uses `atan2(|u×w|, u·w)`: no `arccos`,
    /// therefore no NaN from a dot product a few ULP outside [−1, 1] (digest Ch 12 §12.5).
    public static func angleBetween(_ u: SIMD3<Double>, _ w: SIMD3<Double>) -> Double? {
        let cross = simd_cross(u, w)
        let s = simd_length(cross), c = simd_dot(u, w)
        guard simd_length(u) > 1e-9, simd_length(w) > 1e-9, (s.isFinite && c.isFinite) else { return nil }
        return atan2(s, c)
    }
    /// Angle at `b` between `b→a` and `b→c`, radians in [0, π].
    public static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Double? {
        angleBetween(a - b, c - b)
    }
    /// Signed angle from `u` to `w` about the axis `n`, radians in (−π, π].
    public static func signedAngle(_ u: SIMD3<Double>, _ w: SIMD3<Double>, about n: SIMD3<Double>) -> Double? {
        guard simd_length(u) > 1e-9, simd_length(w) > 1e-9, simd_length(n) > 1e-9 else { return nil }
        let axis = simd_normalize(n)
        return atan2(simd_dot(simd_cross(u, w), axis), simd_dot(u, w))
    }
    /// Angle at `b` in the image plane, radians in [0, π]. A camera-plane projection of a 3-D angle —
    /// only equal to the true angle when the limb lies in the image plane (digest Ch 12 §12.3).
    public static func imageAngle(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double? {
        let u = a - b, w = c - b
        let cross = u.x * w.y - u.y * w.x, dot = u.x * w.x + u.y * w.y
        guard (u * u).sum() > 1e-12, (w * w).sum() > 1e-12 else { return nil }
        return abs(atan2(cross, dot))
    }
}

// MARK: - Options

public struct BodyKinematicsOptions: Sendable {
    /// A 2-D point below this confidence is not used.
    public var minimumConfidence2D: Double = 0.3
    /// Samples either side of a frame for the local-least-squares (zero-phase) derivative.
    public var rateHalfWindow: Int = 2
    /// Real seconds before release searched for the dip and the set point.
    public var dipLookbackSeconds: Double = 1.5
    /// How the dip is picked inside that lookback.
    ///
    /// `false` (the default, and what every existing test asserts): the **lowest** frame in the
    /// lookback. That is right for a window that opens at the dip, and wrong for a longer one — over
    /// 1.5 s of a free-throw routine the lowest hand is the shooter still holding the ball at the
    /// waist, so the dip lands on the first frame of the span and `dipToRelease` comes back as the
    /// length of the window (measured on IMG_1765: 1500, 1500 and 1454 ms on the three labelled
    /// free throws, against a hand that visibly turns 0.40 s before release).
    ///
    /// `true`: the **last turning point** before release — the last frame at which the hand stops
    /// descending and starts to rise, found from the same smoothed rate the set point uses. On the
    /// same three windows that is 0.40 / 0.44 / 0.36 s before release, and it no longer depends on
    /// where the window was opened. Falls back to the lowest frame, with a note, when the hand only
    /// ever rose inside the span.
    public var dipIsLastTurningPoint: Bool = false
    /// Real seconds after release searched for the follow-through.
    public var followWindowSeconds: Double = 1.0
    /// "Quiet" for the set point: |rate| below this fraction of the window's peak |rate|.
    public var quietRateFraction: Double = 0.08
    /// How long the hand must stay quiet for that stillness to be the **set position** rather than a
    /// zero-crossing (iteration 3). Measured on the 240 fps free throws: the shooter holds the ball
    /// still for 0.45–0.55 s before the drive, while a turning point is quiet for one or two frames.
    /// Without this the set point landed **one frame** before the dip on every shot, because the
    /// rate is zero at a turning point by construction — that was the "set→dip 8 ± 0 ms" bug.
    public var minimumSetPlateauSeconds: Double = 0.08
    /// How far the hand must actually descend into the dip for it to be a dip, as a fraction of the
    /// dip→release rise. Measured on the same five shots: the "dip" the old rule found was a 0.005 m
    /// wobble inside the set plateau against a 0.386 m rise to release — 1.3 %. This shooter's free
    /// throw has no dip at all, and the model now says so instead of naming a wobble.
    public var minimumDipDescentFraction: Double = 0.05
    /// How far the hand must rise after the release for a follow-through **peak** to exist, as a
    /// fraction of the set→release rise. Measured: the wrist's highest point is the release itself
    /// on all five shots (rise 0.000 to −0.009 m), so the peak is refused, not reported at +8 ms.
    public var minimumFollowRiseFraction: Double = 0.05
    /// Follow-through ends once the hand has fallen this fraction of its release→peak rise.
    public var followDropFraction: Double = 0.25
    /// "left"/"right" (the subject's own side). Inferred from the ball track when nil.
    public var shootingSide: String?
    /// Camera axes. Vision's camera space: +x right, +y up, +z toward the camera.
    public var up = SIMD3<Double>(0, 1, 0)
    public var cameraRight = SIMD3<Double>(1, 0, 0)
    public var towardCamera = SIMD3<Double>(0, 0, 1)
    /// The torso must lie within this angle of `up`, else the axis convention is reported as suspect.
    public var maximumTorsoTiltFromUp: Double = Angle.radians(50)
    /// A fingertip counts as "on the ball" within this many ball radii of the centre.
    public var fingertipContactRadii: Double = 1.0
    /// Minimum nose-to-head-centre offset (px) before a facing direction is claimed.
    public var minimumFacingOffsetPx: Double = 3.0
    /// A body line that is the *same vector* on every frame of the window to better than this (metres)
    /// is a rigid segment of the skeleton prior, not a measurement, so its yaw is refused. A real line
    /// always wobbles: only a constant one is refused, so a genuinely square-to-camera shooter is fine.
    public var rigidSegmentToleranceMetres: Double = 1e-4
    /// The mid-hip's 75th-percentile frame-to-frame speed ceiling. Above it the 3-D translation is not
    /// tracking the body and every metre derived from it is refused.
    public var maximumHipSpeedMetresPerSecond: Double = 4.0
    /// Set by the caller (from `BodySkeletonFitResult.transverseYawUnavailableReason`) when the view
    /// cannot see the shoulder line's depth. Refuses the two line yaws and every quantity measured
    /// against the facing direction, which is derived from that line.
    public var transverseYawUnavailableReason: String?
    /// A 2-D point this close to a frame border is clipped: the frame ends there, so the detector
    /// has nowhere to put the joint but the edge. Used by `BodyCoverage` and by the ankle gate.
    public var edgeMarginPx: Double = 6
    /// A joint seen on fewer than this fraction of frames, whose mirror partner *is* seen, is flagged
    /// `symmetryInferred`: the skeleton carries it on the other side's bone length.
    public var symmetrySeenFraction: Double = 0.05
    public init(shootingSide: String? = nil) { self.shootingSide = shootingSide }
}

// MARK: - Outputs

public struct JointAngles3D: Sendable, Codable {
    public var realTime: Double
    public var leftElbow: BodyMeasure, rightElbow: BodyMeasure
    public var leftKnee: BodyMeasure, rightKnee: BodyMeasure
    public var leftHip: BodyMeasure, rightHip: BodyMeasure
    public var leftShoulderElevation: BodyMeasure, rightShoulderElevation: BodyMeasure
    public var leftShoulderAbduction: BodyMeasure, rightShoulderAbduction: BodyMeasure
    public var leftAnkle: BodyMeasure, rightAnkle: BodyMeasure
    public var shootingWristFlexion: BodyMeasure
}

public struct ShotPhases: Sendable, Codable {
    /// The moment the hand **leaves** the set position: the last frame of the last stretch of
    /// stillness before the drive. Real seconds.
    public var setPoint: BodyMeasure
    /// The lowest point of a genuine downward move before the release, or nil with the reason when
    /// the hand never descends — which is the case on this shooter's free throw.
    public var dip: BodyMeasure
    public var release: BodyMeasure
    /// The wrist's highest point after the release, when it rises at all after it (iteration 3).
    public var followThroughPeak: BodyMeasure
    /// The moment the hand has come back down out of the follow-through.
    public var followThroughEnd: BodyMeasure
    public var dipToReleaseMilliseconds: BodyMeasure
    /// Set point → release. The tempo number that survives when a shot has no dip (iteration 3).
    public var setToReleaseMilliseconds: BodyMeasure
    public var signalSource: String           // which signal the phases were read from
    public var notes: [String]
}

public struct KineticChainEvent: Sendable, Codable {
    public var joint: String
    public var realTime: Double
    public var peakRateRadPerSecond: Double
    public var peakRateDegreesPerSecond: Double { Angle.degrees(peakRateRadPerSecond) }
}

public struct KineticChain: Sendable, Codable {
    /// Peak-extension-velocity events in time order.
    public var events: [KineticChainEvent]
    /// Joint names in the order their peaks occurred.
    public var order: [String]
    /// Lags between consecutive events, milliseconds of real time.
    public var lagsMilliseconds: [Double]
    /// True when the order matches knee → hip → shoulder → elbow → wrist over the joints that were found.
    public var proximalToDistal: Bool?
    public var unavailableReason: String?
    /// Joints that could not contribute, with the reason.
    public var missing: [String: String]
}

public struct StanceMetrics: Sendable, Codable {
    public var feetSeparation: BodyMeasure           // metres, horizontal, between ankles
    public var feetStagger: BodyMeasure              // metres, + = the subject's right foot is in front
    public var feetStaggerFromToes: BodyMeasure      // always nil from Vision: no toe landmark
    public var shoulderLineYaw: BodyMeasure          // radians, 0 = shoulder line in the image plane, ±π/2 = side-on
    public var hipLineYaw: BodyMeasure
    public var torsoLeanSagittal: BodyMeasure        // radians, + = leaning the way the shooter faces
    public var torsoLeanFrontal: BodyMeasure         // radians, + = leaning toward the subject's right
    public var jumpHeight: BodyMeasure               // metres, peak hip rise above the set/dip hip height
    public var hipDriftLateral: BodyMeasure          // metres, dip→release, + = camera-right
    public var hipDriftDepth: BodyMeasure            // metres, dip→release, + = toward the camera
    public var hipDriftMagnitude: BodyMeasure
    public var squarenessRatio: BodyMeasure          // Ch 12 §12.7, from the 2-D points, for comparison
}

public struct HeadMetrics: Sendable, Codable {
    public var yaw: BodyMeasure                      // radians, 0 = facing the camera
    public var pitchRelative: BodyMeasure            // radians, relative: carries an anatomical offset
    public var stabilityPx: BodyMeasure              // RMS nose displacement about its mean, dip→release
    public var maximumDisplacementPx: BodyMeasure
    public var facesRimDirection: Bool?
    public var facesRimUnavailableReason: String?
    public var noseOffsetPx: BodyMeasure             // nose u − head-centre u at release; sign = facing
    public var approximationNote: String
}

/// Neck and trunk attitude, measured **in the image plane** (iteration 3).
///
/// Why the image plane and not the true 3-D body: on a side view the depth of the shoulder and hip
/// *lines* is unobservable (see `BodySkeletonOptions.minimumBreadthProjectionFraction`), so every
/// transverse angle is refused. The trunk's lean *within* the viewing plane is the opposite case —
/// it is the direction a single camera measures best, at the 2-D points' own 1–2 px of noise. On a
/// side-on clip that plane is the shot plane to within the camera's azimuth from the shot line, so
/// the note says which plane the number is in and never claims more.
public struct PostureMetrics: Sendable, Codable {
    /// Trunk (mid-hip → neck) from image vertical, radians. + = the neck is camera-right of the hips.
    public var trunkToVerticalAtRelease: BodyMeasure
    /// Per-frame noise of that angle, SD of consecutive differences ÷ √2 (digest Ch 10 §10.5.1).
    /// This *is* the precision of the measure: read any trunk difference against it.
    public var trunkToVerticalJitter: BodyMeasure
    /// Extreme lean over dip → release, and the time it happened.
    public var trunkToVerticalMaximum: BodyMeasure
    /// Head (neck → head centre) from the trunk axis, radians. 0 = head stacked on the trunk.
    public var headToTrunkAtRelease: BodyMeasure
    public var headToTrunkJitter: BodyMeasure
    /// Head (neck → head centre) from the **perpendicular of the shoulder line**, radians, in the
    /// image plane: the head's tilt across the shoulders rather than along the trunk.
    public var headToShoulderLineAtRelease: BodyMeasure
    public var headToShoulderLineJitter: BodyMeasure
    /// Which 2-D points stood in for the neck and the head centre on this window.
    public var neckSource: String
    public var headSource: String
    public var frames: Int
    public var note: String
}

/// How much of one joint the window actually saw (iteration 3). Nothing here is inferred: a joint
/// the detector never returned has `framesSeen == 0` and every derived number nil.
public struct BodyJointCoverage: Sendable, Codable, Equatable {
    public var name: String
    /// "body2D", "hand" or "fitted" — which stage produced it.
    public var source: String
    public var framesSeen: Int
    public var framesTotal: Int
    public var seenFraction: Double
    public var medianConfidence: BodyMeasure
    /// Per-frame image noise, pixels: SD of consecutive differences ÷ √2 (digest Ch 10 §10.5.1).
    public var jitterPixels: BodyMeasure
    /// Of the frames it *was* seen on, the fraction where it sat within the edge margin of a frame
    /// border. The feet at the bottom of the frame are the case this exists for: a clipped ankle is
    /// reported at the border whatever the detector believes, so its position is not a measurement.
    public var clippedFraction: Double
    /// True when the joint was seen too rarely to be measured and the skeleton is carrying it only
    /// through its mirror partner's bone length. Its position is an inference; say so before showing it.
    public var symmetryInferred: Bool
    public var note: String?
    public init(name: String, source: String, framesSeen: Int, framesTotal: Int, seenFraction: Double,
                medianConfidence: BodyMeasure, jitterPixels: BodyMeasure, clippedFraction: Double,
                symmetryInferred: Bool, note: String? = nil) {
        self.name = name; self.source = source; self.framesSeen = framesSeen; self.framesTotal = framesTotal
        self.seenFraction = seenFraction; self.medianConfidence = medianConfidence; self.jitterPixels = jitterPixels
        self.clippedFraction = clippedFraction; self.symmetryInferred = symmetryInferred; self.note = note
    }
}

public struct HandMetrics: Sendable, Codable {
    public var shootingHandChirality: String?
    public var lastFingertipsOnBall: [String]
    public var fingertipLastContactRealTime: [String: Double]
    public var fingertipsUnavailableReason: String?
    public var wristSnapRate: BodyMeasure            // radians/s of real time, image-plane projection
    public var guideThumbTowardBall: BodyMeasure     // px/s of real time, + = moving toward the ball
    public var handsSeenFrames: Int
}

public struct BodyModel: Sendable, Codable {
    public var angles: [JointAngles3D]
    public var anglesAtRelease: JointAngles3D?
    public var phases: ShotPhases
    public var chain: KineticChain
    public var stance: StanceMetrics
    public var head: HeadMetrics
    public var hands: HandMetrics
    /// Neck and trunk attitude in the image plane (iteration 3).
    public var posture: PostureMetrics
    /// One row per joint the window could have carried: how often it was seen, how much it jitters,
    /// how often it sat on a frame border, and whether the far side is being carried by symmetry.
    public var coverage: [BodyJointCoverage]
    public var shootingSide: String?
    public var framesWith3D: Int
    public var framesWith2D: Int
    public var framesWithHands: Int
    public var scaleIsMeasured: Bool?        // nil when unknown; false when a body-height prior set the metres
    public var warnings: [String]
}

// MARK: - The model

public enum BodyKinematics {

    // ---- small helpers -------------------------------------------------------------------

    static func p3(_ f: BodyFrame, _ name: String) -> SIMD3<Double>? { f.joints3D[name]?.cameraPosition }
    static func p2(_ f: BodyFrame, _ name: String, _ minimumConfidence: Double) -> SIMD2<Double>? {
        guard let j = f.points2D[name], j.confidence >= minimumConfidence else { return nil }
        return SIMD2(j.u, j.v)
    }
    static func midpoint(_ a: SIMD3<Double>?, _ b: SIMD3<Double>?) -> SIMD3<Double>? {
        guard let a, let b else { return nil }
        return (a + b) / 2
    }
    /// Zero-phase derivative: the slope of a least-squares line over ±`halfWindow` samples.
    /// (Digest Ch 11 §11.3: differentiate a smoothed signal, and never with a causal filter.)
    public static func slope(times: [Double], values: [Double], at i: Int, halfWindow: Int) -> Double? {
        guard times.count == values.count, i >= 0, i < times.count else { return nil }
        let lo = max(0, i - halfWindow), hi = min(times.count - 1, i + halfWindow)
        guard hi - lo >= 1 else { return nil }
        return PolyFit.linear(Array(times[lo...hi]), Array(values[lo...hi]))?.c1
    }
    static func nearestIndex(_ times: [Double], _ t: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        return times.indices.min(by: { abs(times[$0] - t) < abs(times[$1] - t) })
    }
    /// Fold an orientation into (−π/2, π/2]: a line has no head or tail.
    static func foldLine(_ a: Double) -> Double {
        var x = a
        while x > .pi / 2 { x -= .pi }
        while x <= -.pi / 2 { x += .pi }
        return x
    }

    // ---- per-frame joint angles ---------------------------------------------------------

    /// True 3-D joint angles for one frame. Each is nil with the named missing joint when it cannot
    /// be computed. Ankle angles are always nil: Apple's 3-D body model has no toe landmark.
    public static func angles(frame f: BodyFrame, options o: BodyKinematicsOptions = .init(),
                              shootingSide: String? = nil) -> JointAngles3D {
        func limb(_ a: String, _ b: String, _ c: String, _ label: String) -> BodyMeasure {
            guard let A = p3(f, a) else { return .missing(.radians, "no 3-D \(a) on this frame (\(label))") }
            guard let B = p3(f, b) else { return .missing(.radians, "no 3-D \(b) on this frame (\(label))") }
            guard let C = p3(f, c) else { return .missing(.radians, "no 3-D \(c) on this frame (\(label))") }
            guard let angle = BodyAngles.angle(A, B, C) else { return .missing(.radians, "the \(label) segments are degenerate on this frame") }
            return .ok(angle, .radians)
        }
        // Trunk axis: mid-hip → mid-shoulder. Shoulder elevation is measured from the trunk's *down*
        // direction, so 0 = arm hanging at the side and π = arm straight overhead.
        let midShoulder = midpoint(p3(f, Body3DJoint.leftShoulder), p3(f, Body3DJoint.rightShoulder))
        let midHip = midpoint(p3(f, Body3DJoint.leftHip), p3(f, Body3DJoint.rightHip))
        let trunk: SIMD3<Double>? = (midShoulder != nil && midHip != nil) ? (midShoulder! - midHip!) : nil
        let shoulderLine: SIMD3<Double>? = {
            guard let l = p3(f, Body3DJoint.leftShoulder), let r = p3(f, Body3DJoint.rightShoulder) else { return nil }
            return r - l
        }()

        func shoulder(_ side: String) -> (elevation: BodyMeasure, abduction: BodyMeasure) {
            let sName = side == "left" ? Body3DJoint.leftShoulder : Body3DJoint.rightShoulder
            let eName = side == "left" ? Body3DJoint.leftElbow : Body3DJoint.rightElbow
            guard let S = p3(f, sName), let E = p3(f, eName) else {
                let why = "no 3-D \(p3(f, sName) == nil ? sName : eName) on this frame (\(side) shoulder)"
                return (.missing(.radians, why), .missing(.radians, why))
            }
            guard let trunk else {
                let why = "the trunk axis needs both shoulders and both hips in 3-D"
                return (.missing(.radians, why), .missing(.radians, why))
            }
            let upperArm = E - S
            let elevation = BodyAngles.angleBetween(upperArm, -trunk).map { BodyMeasure.ok($0, .radians) }
                ?? .missing(.radians, "the upper arm or trunk segment is degenerate on this frame")
            guard let shoulderLine, let lateral = normalizedOrNil(shoulderLine), let trunkUnit = normalizedOrNil(trunk) else {
                return (elevation, .missing(.radians, "the shoulder line is degenerate, so the frontal plane is undefined"))
            }
            // Frontal plane = span(trunk, shoulder line). Abduction is the elevation of the arm's
            // projection into that plane, measured from the trunk's down direction.
            let inPlane = simd_dot(upperArm, trunkUnit) * trunkUnit + simd_dot(upperArm, lateral) * lateral
            let abduction = BodyAngles.angleBetween(inPlane, -trunk).map { BodyMeasure.ok($0, .radians) }
                ?? .missing(.radians, "the arm's frontal-plane projection vanished on this frame")
            return (elevation, abduction)
        }
        let ls = shoulder("left"), rs = shoulder("right")

        // Wrist flexion: the hand's 21-landmark model is 2-D, so this is an image-plane angle at the
        // wrist between the forearm and the hand (wrist → middle-finger knuckle). Documented as an
        // approximation; it equals the true flexion only when the hand lies in the image plane.
        var wristFlexion = BodyMeasure.missing(.radians, "no shooting side was determined, so no hand could be chosen")
        if let side = shootingSide {
            let elbowName = side == "left" ? Body2DPoint.leftElbow : Body2DPoint.rightElbow
            let wristName = side == "left" ? Body2DPoint.leftWrist : Body2DPoint.rightWrist
            let hand = f.hands.first(where: { $0.role == "shooting" })
                ?? f.hands.first(where: { $0.chirality == side })
            if let hand, let mcp = hand.landmarks[HandLandmark.middleMCP],
               let elbow = p2(f, elbowName, o.minimumConfidence2D), let wrist = p2(f, wristName, o.minimumConfidence2D) {
                wristFlexion = BodyAngles.imageAngle(elbow, wrist, mcp.uv).map { BodyMeasure.ok($0, .radians) }
                    ?? .missing(.radians, "the forearm and hand segments are degenerate on this frame")
            } else if hand == nil {
                wristFlexion = .missing(.radians, "no hand was detected on this frame")
            } else {
                wristFlexion = .missing(.radians, "the \(side) elbow, wrist or middle knuckle was not confident on this frame")
            }
        }

        let noToe = "no toe landmark in the Vision body model"
        return JointAngles3D(
            realTime: f.realTime,
            leftElbow: limb(Body3DJoint.leftShoulder, Body3DJoint.leftElbow, Body3DJoint.leftWrist, "left elbow"),
            rightElbow: limb(Body3DJoint.rightShoulder, Body3DJoint.rightElbow, Body3DJoint.rightWrist, "right elbow"),
            leftKnee: limb(Body3DJoint.leftHip, Body3DJoint.leftKnee, Body3DJoint.leftAnkle, "left knee"),
            rightKnee: limb(Body3DJoint.rightHip, Body3DJoint.rightKnee, Body3DJoint.rightAnkle, "right knee"),
            leftHip: limb(Body3DJoint.leftShoulder, Body3DJoint.leftHip, Body3DJoint.leftKnee, "left hip"),
            rightHip: limb(Body3DJoint.rightShoulder, Body3DJoint.rightHip, Body3DJoint.rightKnee, "right hip"),
            leftShoulderElevation: ls.elevation, rightShoulderElevation: rs.elevation,
            leftShoulderAbduction: ls.abduction, rightShoulderAbduction: rs.abduction,
            leftAnkle: .missing(.radians, noToe), rightAnkle: .missing(.radians, noToe),
            shootingWristFlexion: wristFlexion)
    }

    static func normalizedOrNil(_ v: SIMD3<Double>) -> SIMD3<Double>? {
        let n = simd_length(v)
        return n > 1e-9 ? v / n : nil
    }

    // ---- phases --------------------------------------------------------------------------

    /// Set point, dip, release and follow-through end from a vertical signal (up-positive).
    /// `release` is supplied by the caller — the physics release (digest Ch 10 §10.3) is a ball
    /// measurement, not a pose one, and this function never second-guesses it.
    public static func phases(times: [Double], height: [Double], releaseRealTime: Double,
                              signalSource: String, options o: BodyKinematicsOptions = .init()) -> ShotPhases {
        var notes: [String] = []
        let release = BodyMeasure.ok(releaseRealTime, .seconds)
        guard times.count >= 5, times.count == height.count else {
            let why = "the vertical signal has \(times.count) usable samples; at least 5 are needed"
            return ShotPhases(setPoint: .missing(.seconds, why), dip: .missing(.seconds, why), release: release,
                              followThroughPeak: .missing(.seconds, why), followThroughEnd: .missing(.seconds, why),
                              dipToReleaseMilliseconds: .missing(.milliseconds, why),
                              setToReleaseMilliseconds: .missing(.milliseconds, why),
                              signalSource: signalSource, notes: notes)
        }
        let lookStart = releaseRealTime - o.dipLookbackSeconds
        let before = times.indices.filter { times[$0] >= lookStart && times[$0] <= releaseRealTime }
        let releaseIndex = nearestIndex(times, releaseRealTime)

        // Rates once, for both the set point and the dip. Zero-phase (digest Ch 11 §11.3).
        let rates = times.indices.map { slope(times: times, values: height, at: $0, halfWindow: o.rateHalfWindow) }
        let peakRate = rates.compactMap { $0.map(abs) }.max() ?? 0
        let quiet = peakRate * o.quietRateFraction

        // ---- set point -------------------------------------------------------------------------
        // The set position is a **plateau**, not a single quiet frame: the shooter holds the ball
        // still, then drives. Taking "the last quiet frame" put the set point one frame before the
        // dip on every shot of the 240 fps clip, because the rate is zero at a turning point by
        // construction. So: the last run of consecutive quiet frames before the release that lasts
        // at least `minimumSetPlateauSeconds`, and the set point is that run's **last** frame — the
        // moment the hand leaves the set. Measured on this clip: the plateau is 0.45–0.55 s long and
        // ends 190–240 ms before release; a turning point is quiet for one or two frames.
        var setPoint = BodyMeasure.missing(.seconds, "no frame in the lookback carried the vertical signal")
        var setIndex: Int? = nil
        if peakRate <= 0 {
            setPoint = .missing(.seconds, "the vertical signal has no measurable rate, so 'quiet' is undefined")
        } else {
            var runs: [(lo: Int, hi: Int)] = []
            var open: Int? = nil
            for (k, i) in before.enumerated() {
                let isQuiet = rates[i].map { abs($0) <= quiet } ?? false
                if isQuiet {
                    if open == nil { open = k }
                } else if let o0 = open {
                    runs.append((before[o0], before[k - 1])); open = nil
                }
            }
            if let o0 = open, !before.isEmpty { runs.append((before[o0], before[before.count - 1])) }
            let long = runs.filter { times[$0.hi] - times[$0.lo] >= o.minimumSetPlateauSeconds }
            if let last = long.last {
                setIndex = last.hi
                setPoint = .ok(times[last.hi], .seconds)
                notes.append(String(format: "the set position is a %.0f ms plateau of stillness ending %.0f ms before the release; the set point is where the hand leaves it",
                                    1000 * (times[last.hi] - times[last.lo]), 1000 * (releaseRealTime - times[last.hi])))
            } else {
                setPoint = .missing(.seconds, String(format: "the hand was never still for %.0f ms together inside the lookback, so there is no set position to time from",
                                                     1000 * o.minimumSetPlateauSeconds))
            }
        }

        // ---- dip -------------------------------------------------------------------------------
        // A dip is a *descent*, so it has to be gated on how far the hand actually fell to reach it.
        // Without the gate the rule named a 0.005 m wobble inside the set plateau on a shot whose
        // rise to release is 0.386 m, and reported a 350 ms "dip → release" that was not a dip.
        var dip = BodyMeasure.missing(.seconds, "no frame in the \(String(format: "%.1f", o.dipLookbackSeconds)) s before release carried the vertical signal")
        var dipIndex: Int? = nil
        var candidate: Int? = nil
        if o.dipIsLastTurningPoint, before.count >= 2 * o.rateHalfWindow + 2 {
            // Scanning back from the release, the last frame whose smoothed rate is at or below zero
            // with the next one above it — the hand stopping its descent.
            for i in stride(from: before.count - 2, through: 0, by: -1) {
                guard let r0 = rates[before[i]], let r1 = rates[before[i + 1]] else { continue }
                if r0 <= 0 && r1 > 0 { candidate = before[i]; break }
            }
            if candidate == nil {
                notes.append("the hand only rose inside the lookback, so there is no turning point in it")
            }
        }
        if candidate == nil { candidate = before.min(by: { height[$0] < height[$1] }) }
        if let k = candidate, let ri = releaseIndex {
            // How far did the hand fall to reach it, and how far does it rise from it to the release?
            let descent = (before.filter { $0 < k }.map { height[$0] }.max() ?? height[k]) - height[k]
            let rise = height[ri] - height[k]
            if rise > 0 && descent >= o.minimumDipDescentFraction * rise {
                dipIndex = k
                dip = .ok(times[k], .seconds)
                if k == before.first { notes.append("the dip is the first frame of the lookback: the window may start after the real dip") }
            } else {
                dip = .missing(.seconds, String(format: "the hand descended only %.3f into its lowest point before the release against a %.3f rise out of it (%.1f %%, floor %.0f %%): this shot has no dip — the hand rises from the set position straight into the release",
                                                descent, rise, rise > 0 ? 100 * descent / rise : 0, 100 * o.minimumDipDescentFraction))
            }
        }

        // ---- follow-through ----------------------------------------------------------------------
        // Two numbers, because they are two different things and the old rule conflated them. The
        // **peak** is the wrist's highest point after the release — which on this shooter's free throw
        // is the release itself, so it is refused rather than reported at +8 ms of noise. The **end**
        // is the hand coming down out of the follow-through, measured against the shot's own rise
        // (set → release) rather than against a post-release rise that may not exist.
        var followPeak = BodyMeasure.missing(.seconds, "no frame after release carried the vertical signal")
        var follow = BodyMeasure.missing(.seconds, "no frame after release carried the vertical signal")
        let after = times.indices.filter { times[$0] >= releaseRealTime && times[$0] <= releaseRealTime + o.followWindowSeconds }
        if let ri = releaseIndex, let peakIndex = after.max(by: { height[$0] < height[$1] }) {
            let floorIndex = setIndex ?? dipIndex ?? before.min(by: { height[$0] < height[$1] })
            let shotRise = max(0, height[ri] - (floorIndex.map { height[$0] } ?? height[ri]))
            let peakRise = height[peakIndex] - height[ri]
            if peakRise >= o.minimumFollowRiseFraction * shotRise && peakRise > 0 {
                followPeak = .ok(times[peakIndex], .seconds)
            } else {
                followPeak = .missing(.seconds, String(format: "the wrist's highest point is the release itself: it rises %.3f after it against a %.3f rise into it (floor %.0f %%), so there is no follow-through peak to time",
                                                       peakRise, shotRise, 100 * o.minimumFollowRiseFraction))
            }
            let scale = max(peakRise, shotRise)
            if scale <= 0 {
                follow = .missing(.seconds, "the hand neither rose into the release nor after it, so there is no follow-through to measure a drop against")
            } else if let k = after.first(where: { $0 >= peakIndex && height[$0] <= height[peakIndex] - o.followDropFraction * scale }) {
                follow = .ok(times[k], .seconds)
            } else {
                follow = .missing(.seconds, "the hand had not dropped \(Int(o.followDropFraction * 100))% of its rise before the window ended")
            }
        }

        var dipToRelease = BodyMeasure.missing(.milliseconds, dip.unavailableReason ?? "the dip is unavailable")
        if let d = dip.value { dipToRelease = .ok((releaseRealTime - d) * 1000, .milliseconds) }
        var setToRelease = BodyMeasure.missing(.milliseconds, setPoint.unavailableReason ?? "the set point is unavailable")
        if let sp = setPoint.value { setToRelease = .ok((releaseRealTime - sp) * 1000, .milliseconds) }
        return ShotPhases(setPoint: setPoint, dip: dip, release: release,
                          followThroughPeak: followPeak, followThroughEnd: follow,
                          dipToReleaseMilliseconds: dipToRelease, setToReleaseMilliseconds: setToRelease,
                          signalSource: signalSource, notes: notes)
    }

    // ---- kinetic chain --------------------------------------------------------------------

    /// The canonical proximal-to-distal order the sequence is scored against.
    public static let chainOrder = ["knee", "hip", "shoulder", "elbow", "wrist"]

    /// Times of peak extension velocity for knee, hip, shoulder, elbow and wrist, and the lags between them.
    /// Each drive signal is an angle that **increases as the joint extends**, so "peak extension
    /// velocity" is the maximum of the signed derivative. The wrist's signal is the image-plane hand
    /// direction, so its peak is the maximum |rate| (a snap is flexion, not extension).
    public static func kineticChain(angles: [JointAngles3D], from startTime: Double, to endTime: Double,
                                    side: String?, options o: BodyKinematicsOptions = .init()) -> KineticChain {
        var missing: [String: String] = [:]
        guard angles.count >= 2 * o.rateHalfWindow + 2 else {
            return KineticChain(events: [], order: [], lagsMilliseconds: [], proximalToDistal: nil,
                                unavailableReason: "only \(angles.count) pose frames carry joint angles; the derivative needs at least \(2 * o.rateHalfWindow + 2)",
                                missing: [:])
        }
        let times = angles.map(\.realTime)
        func pick(_ f: (JointAngles3D) -> BodyMeasure) -> (values: [Double], indices: [Int])? {
            var values: [Double] = [], indices: [Int] = []
            for (i, a) in angles.enumerated() { if let v = f(a).value { values.append(v); indices.append(i) } }
            return values.count >= 2 * o.rateHalfWindow + 2 ? (values, indices) : nil
        }
        func peak(_ label: String, signed: Bool, _ f: @escaping (JointAngles3D) -> BodyMeasure) -> KineticChainEvent? {
            guard let (values, indices) = pick(f) else {
                missing[label] = "fewer than \(2 * o.rateHalfWindow + 2) frames carried the \(label) angle"
                return nil
            }
            let t = indices.map { times[$0] }
            var best: (Double, Double)? = nil
            for i in t.indices where t[i] >= startTime && t[i] <= endTime {
                guard let s = slope(times: t, values: values, at: i, halfWindow: o.rateHalfWindow) else { continue }
                let score = signed ? s : abs(s)
                if best == nil || score > best!.1 { best = (t[i], score) }
            }
            guard let b = best, b.1 > 0 else {
                missing[label] = "the \(label) angle never extended inside the search window"
                return nil
            }
            return KineticChainEvent(joint: label, realTime: b.0, peakRateRadPerSecond: b.1)
        }
        let s = side ?? "right"
        var events: [KineticChainEvent] = []
        if let e = peak("knee", signed: true, { s == "left" ? $0.leftKnee : $0.rightKnee }) { events.append(e) }
        if let e = peak("hip", signed: true, { s == "left" ? $0.leftHip : $0.rightHip }) { events.append(e) }
        if let e = peak("shoulder", signed: true, { s == "left" ? $0.leftShoulderElevation : $0.rightShoulderElevation }) { events.append(e) }
        if let e = peak("elbow", signed: true, { s == "left" ? $0.leftElbow : $0.rightElbow }) { events.append(e) }
        if let e = peak("wrist", signed: false, { $0.shootingWristFlexion }) { events.append(e) }
        guard events.count >= 2 else {
            return KineticChain(events: events, order: events.map(\.joint), lagsMilliseconds: [], proximalToDistal: nil,
                                unavailableReason: "fewer than two joints produced a peak, so there is no sequence",
                                missing: missing)
        }
        let sorted = events.sorted { $0.realTime < $1.realTime }
        var lags: [Double] = []
        for i in 1..<sorted.count { lags.append((sorted[i].realTime - sorted[i - 1].realTime) * 1000) }
        let expected = chainOrder.filter { name in sorted.contains { $0.joint == name } }
        return KineticChain(events: sorted, order: sorted.map(\.joint), lagsMilliseconds: lags,
                            proximalToDistal: sorted.map(\.joint) == expected, unavailableReason: nil, missing: missing)
    }

    // ---- stance --------------------------------------------------------------------------

    public static func stance(frames: [BodyFrame], dipTime: Double?, setTime: Double?, releaseTime: Double,
                              options o: BodyKinematicsOptions = .init()) -> (StanceMetrics, [String]) {
        var warnings: [String] = []
        let with3D = frames.filter { !$0.joints3D.isEmpty }
        guard let releaseFrame = with3D.min(by: { abs($0.realTime - releaseTime) < abs($1.realTime - releaseTime) }) else {
            let why = "no frame in this window carried a 3-D body"
            let m = BodyMeasure.missing(.metres, why), a = BodyMeasure.missing(.radians, why)
            return (StanceMetrics(feetSeparation: m, feetStagger: m,
                                  feetStaggerFromToes: .missing(.metres, "no toe landmark in the Vision body model"),
                                  shoulderLineYaw: a, hipLineYaw: a, torsoLeanSagittal: a, torsoLeanFrontal: a,
                                  jumpHeight: m, hipDriftLateral: m, hipDriftDepth: m, hipDriftMagnitude: m,
                                  squarenessRatio: .missing(.ratio, why)), [why])
        }
        let f = releaseFrame
        let up = o.up, right = o.cameraRight, toward = o.towardCamera

        // Trunk and the body frame at release.
        let midShoulder = midpoint(p3(f, Body3DJoint.leftShoulder), p3(f, Body3DJoint.rightShoulder))
        let midHip = midpoint(p3(f, Body3DJoint.leftHip), p3(f, Body3DJoint.rightHip))
        let shoulderLine: SIMD3<Double>? = {
            guard let l = p3(f, Body3DJoint.leftShoulder), let r = p3(f, Body3DJoint.rightShoulder) else { return nil }
            return r - l
        }()
        let hipLine: SIMD3<Double>? = {
            guard let l = p3(f, Body3DJoint.leftHip), let r = p3(f, Body3DJoint.rightHip) else { return nil }
            return r - l
        }()
        // Anterior (the way the shooter faces) = up × (right shoulder − left shoulder).
        // The facing direction comes from the shoulder line, so it inherits that line's observability.
        let anterior: SIMD3<Double>? = o.transverseYawUnavailableReason != nil ? nil
            : shoulderLine.flatMap { normalizedOrNil(simd_cross(up, $0)) }
        let noAnterior = o.transverseYawUnavailableReason ?? "the facing direction needs both 3-D shoulders"

        var torsoSag = BodyMeasure.missing(.radians, o.transverseYawUnavailableReason ?? "the trunk needs both shoulders and both hips in 3-D")
        var torsoFront = torsoSag
        if let ms = midShoulder, let mh = midHip, let a = anterior, let lateral = shoulderLine.flatMap(normalizedOrNil) {
            let trunk = ms - mh
            if let unit = normalizedOrNil(trunk) {
                let tilt = acos(min(1, max(-1, simd_dot(unit, up))))
                if tilt > o.maximumTorsoTiltFromUp {
                    warnings.append(String(format: "the trunk sits %.0f° from the assumed camera up axis: either the shooter is far from upright or the camera is not level, so lean and jump height are suspect", Angle.degrees(tilt)))
                }
            }
            torsoSag = .ok(atan2(simd_dot(trunk, a), simd_dot(trunk, up)), .radians)
            torsoFront = .ok(atan2(simd_dot(trunk, lateral), simd_dot(trunk, up)), .radians)
        }

        // A segment that is the identical vector on every frame is a rigid piece of Vision's skeleton
        // prior. Measured on IMG_1765: the hip line is (-0.3130, 0, 5e-6) m on every single frame.
        var rigid: [String: String] = [:]
        func rigidity(_ a: String, _ b: String, _ what: String) {
            let vectors = with3D.compactMap { fr -> SIMD3<Double>? in
                guard let l = p3(fr, a), let r = p3(fr, b) else { return nil }
                return r - l
            }
            guard vectors.count >= 5 else { return }
            let mean = vectors.reduce(SIMD3<Double>(repeating: 0), +) / Double(vectors.count)
            let spread = vectors.map { simd_length($0 - mean) }.max() ?? 0
            if spread < o.rigidSegmentToleranceMetres {
                rigid[what] = String(format: "the 3-D %@ is the identical vector on all %d frames (spread %.1e m): Vision is holding it on a rigid segment of its skeleton prior, so its yaw is not a measurement", what, vectors.count, spread)
            }
        }
        rigidity(Body3DJoint.leftHip, Body3DJoint.rightHip, "hip line")
        rigidity(Body3DJoint.leftShoulder, Body3DJoint.rightShoulder, "shoulder line")
        for why in rigid.values { warnings.append(why) }

        func yaw(_ line: SIMD3<Double>?, _ what: String) -> BodyMeasure {
            if let why = o.transverseYawUnavailableReason { return .missing(.radians, why) }
            guard let line else { return .missing(.radians, "the \(what) needs both 3-D \(what == "shoulder line" ? "shoulders" : "hips")") }
            let x = simd_dot(line, right), z = simd_dot(line, toward)
            guard abs(x) + abs(z) > 1e-6 else { return .missing(.radians, "the \(what) is vertical in camera space, so its yaw is undefined") }
            if let why = rigid[what] { return .missing(.radians, why) }
            return .ok(foldLine(atan2(z, x)), .radians)
        }

        var separation = BodyMeasure.missing(.metres, "the stance needs both 3-D ankles")
        var stagger = separation
        if let la = p3(f, Body3DJoint.leftAnkle), let ra = p3(f, Body3DJoint.rightAnkle) {
            let d = ra - la
            let horizontal = d - simd_dot(d, up) * up
            separation = .ok(simd_length(horizontal), .metres)
            if let a = anterior { stagger = .ok(simd_dot(horizontal, a), .metres) }
            else { stagger = .missing(.metres, noAnterior) }
        }

        // Is the 3-D translation tracking the body at all? A mid-hip that teleports between frames means
        // the metric positions are a per-frame guess, and every metre derived from them is refused.
        var hipTrackingFailure: String? = nil
        var hipSteps: [Double] = []
        for i in 1..<max(1, with3D.count) {
            guard let a = midpoint(p3(with3D[i - 1], Body3DJoint.leftHip), p3(with3D[i - 1], Body3DJoint.rightHip)),
                  let b = midpoint(p3(with3D[i], Body3DJoint.leftHip), p3(with3D[i], Body3DJoint.rightHip)) else { continue }
            let dt = with3D[i].realTime - with3D[i - 1].realTime
            if dt > 1e-6 { hipSteps.append(simd_length(b - a) / dt) }
        }
        if hipSteps.count >= 8 {
            // The 75th percentile, not the median: on IMG_1765 shot05 the median hip speed was 3.6 m/s
            // while the 75th was 7.6 and the maximum 177 — a quarter of the frames teleporting is still
            // a broken track, and one dropout must not condemn a good one.
            let sorted = hipSteps.sorted()
            let speed = sorted[min(sorted.count - 1, Int(0.75 * Double(sorted.count)))]
            if speed > o.maximumHipSpeedMetresPerSecond {
                hipTrackingFailure = String(format: "the 3-D mid-hip moves at %.0f m/s between frames on a quarter of them (ceiling %.0f m/s): the body model's camera-relative translation is not tracking the body, so no metre derived from it is a measurement", speed, o.maximumHipSpeedMetresPerSecond)
                warnings.append(hipTrackingFailure!)
            }
        }
        // Jump height: mid-hip rise above the set (or dip) height. Ch 12's registry uses the set height.
        var jump = BodyMeasure.missing(.metres, "no 3-D mid-hip was available at the reference frame")
        let referenceTime = setTime ?? dipTime
        func hipHeight(_ fr: BodyFrame) -> Double? { midpoint(p3(fr, Body3DJoint.leftHip), p3(fr, Body3DJoint.rightHip)).map { simd_dot($0, up) } }
        if let referenceTime, let ref = with3D.min(by: { abs($0.realTime - referenceTime) < abs($1.realTime - referenceTime) }),
           let base = hipHeight(ref) {
            let span = with3D.filter { $0.realTime >= referenceTime && $0.realTime <= releaseTime + o.followWindowSeconds }
            if let peak = span.compactMap(hipHeight).max() { jump = .ok(peak - base, .metres) }
            else { jump = .missing(.metres, "no 3-D mid-hip between the reference frame and the follow-through") }
        } else if referenceTime == nil {
            jump = .missing(.metres, "neither the set point nor the dip was found, so there is no reference height")
        }

        var driftLat = BodyMeasure.missing(.metres, "the drift needs the dip time and a 3-D mid-hip at the dip and at release")
        var driftDepth = driftLat, driftMag = driftLat
        if let dipTime, let dipFrame = with3D.min(by: { abs($0.realTime - dipTime) < abs($1.realTime - dipTime) }),
           let a = midpoint(p3(dipFrame, Body3DJoint.leftHip), p3(dipFrame, Body3DJoint.rightHip)),
           let b = midpoint(p3(f, Body3DJoint.leftHip), p3(f, Body3DJoint.rightHip)) {
            let d = b - a
            let horizontal = d - simd_dot(d, up) * up
            driftLat = .ok(simd_dot(horizontal, right), .metres)
            driftDepth = .ok(simd_dot(horizontal, toward), .metres)
            driftMag = .ok(simd_length(horizontal), .metres)
        }

        // Ch 12 §12.7 squareness, from the 2-D points, as the independent cross-check on the 3-D yaw.
        var squareness = BodyMeasure.missing(.ratio, "the squareness ratio needs both 2-D shoulders and both 2-D hips")
        if let ls = p2(f, Body2DPoint.leftShoulder, o.minimumConfidence2D), let rs = p2(f, Body2DPoint.rightShoulder, o.minimumConfidence2D),
           let lh = p2(f, Body2DPoint.leftHip, o.minimumConfidence2D), let rh = p2(f, Body2DPoint.rightHip, o.minimumConfidence2D) {
            let shoulderSpan = simd_length(rs - ls)
            let torso = simd_length((rs + ls) / 2 - (rh + lh) / 2)
            squareness = torso > 1e-6 ? .ok(shoulderSpan / torso, .ratio) : .missing(.ratio, "the 2-D torso has zero length on this frame")
        }

        if let why = hipTrackingFailure {
            jump = .missing(.metres, why); driftLat = .missing(.metres, why)
            driftDepth = .missing(.metres, why); driftMag = .missing(.metres, why)
            separation = .missing(.metres, why); stagger = .missing(.metres, why)
        }
        return (StanceMetrics(feetSeparation: separation, feetStagger: stagger,
                              feetStaggerFromToes: .missing(.metres, "no toe landmark in the Vision body model"),
                              shoulderLineYaw: yaw(shoulderLine, "shoulder line"), hipLineYaw: yaw(hipLine, "hip line"),
                              torsoLeanSagittal: torsoSag, torsoLeanFrontal: torsoFront, jumpHeight: jump,
                              hipDriftLateral: driftLat, hipDriftDepth: driftDepth, hipDriftMagnitude: driftMag,
                              squarenessRatio: squareness), warnings)
    }

    // ---- head ------------------------------------------------------------------------------

    /// Head yaw and pitch from the 2-D eyes/ears/nose.
    ///
    /// Approximation: the head is a sphere of radius R centred on the ear midpoint, with the ears at
    /// ±90° from the nose about the vertical axis. Under weak perspective the image offsets are then
    /// `u_nose − u_earMid = R·sinψ` and `(u_leftEar − u_rightEar)/2 = R·cosψ`, so
    /// `ψ = atan2(u_nose − u_earMid, (u_leftEar − u_rightEar)/2)` and `R = hypot` of the two.
    /// Valid to roughly |ψ| ≤ 60°: real ears sit nearer ±80° than ±90° and the nose protrudes past R,
    /// both of which inflate |ψ|; past 60° the far ear is occluded and its confidence collapses, and
    /// `cosψ → 0` makes the denominator vanish. Pitch carries the anatomical nose-below-ear offset
    /// (roughly 10–20° on a neutral head), so only **changes** in pitch are meaningful.
    public static func head(frames: [BodyFrame], dipTime: Double?, releaseTime: Double, rimImageU: Double?,
                            options o: BodyKinematicsOptions = .init()) -> HeadMetrics {
        let note = "head yaw/pitch use a spherical-head weak-perspective model (ears at ±90°, nose on the sphere); valid to about |yaw| ≤ 60°, and pitch is relative because of the anatomical nose-below-ear offset"
        guard let f = frames.min(by: { abs($0.realTime - releaseTime) < abs($1.realTime - releaseTime) }) else {
            let why = "this window has no pose frames"
            return HeadMetrics(yaw: .missing(.radians, why), pitchRelative: .missing(.radians, why),
                               stabilityPx: .missing(.pixels, why), maximumDisplacementPx: .missing(.pixels, why),
                               facesRimDirection: nil, facesRimUnavailableReason: why,
                               noseOffsetPx: .missing(.pixels, why), approximationNote: note)
        }
        let nose = p2(f, Body2DPoint.nose, o.minimumConfidence2D)
        let leftEar = p2(f, Body2DPoint.leftEar, o.minimumConfidence2D)
        let rightEar = p2(f, Body2DPoint.rightEar, o.minimumConfidence2D)
        var yaw = BodyMeasure.missing(.radians, "head yaw needs a confident nose and **both** ears; on a side view the far ear is occluded")
        var pitch = BodyMeasure.missing(.radians, "head pitch needs a confident nose and both ears")
        var headCentreU: Double? = nil
        if let nose, let leftEar, let rightEar {
            let earMid = (leftEar + rightEar) / 2
            headCentreU = earMid.x
            let halfSpan = (leftEar.x - rightEar.x) / 2
            let dU = nose.x - earMid.x
            if abs(halfSpan) < 1e-6 && abs(dU) < 1e-6 {
                yaw = .missing(.radians, "the nose and both ears project onto the same point; the head model is degenerate")
            } else {
                yaw = .ok(atan2(dU, halfSpan), .radians)
                let radius = (halfSpan * halfSpan + dU * dU).squareRoot()
                if radius > 1e-6 {
                    let s = (earMid.y - nose.y) / radius       // v grows downwards: nose above ear mid → positive
                    pitch = .ok(asin(min(1, max(-1, s))), .radians)
                } else {
                    pitch = .missing(.radians, "the head radius implied by the ear span is zero")
                }
            }
        }
        if headCentreU == nil, let neck = p2(f, Body2DPoint.neck, o.minimumConfidence2D) { headCentreU = neck.x }

        var noseOffset = BodyMeasure.missing(.pixels, "the facing cue needs a confident nose and either both ears or the neck")
        var faces: Bool? = nil
        var facesWhy: String? = "the facing cue needs a confident nose and either both ears or the neck"
        if let nose, let centre = headCentreU {
            let offset = nose.x - centre
            noseOffset = .ok(offset, .pixels)
            if let rimImageU {
                if abs(offset) < o.minimumFacingOffsetPx {
                    facesWhy = String(format: "the nose is only %.1f px from the head centre, inside the keypoint jitter, so the facing direction cannot be claimed", abs(offset))
                } else {
                    faces = (offset > 0) == (rimImageU > centre)
                    facesWhy = nil
                }
            } else {
                facesWhy = "no rim image position was supplied"
            }
        }

        // Head stability: RMS nose displacement about its mean over dip → release, in pixels (Tier C).
        var stability = BodyMeasure.missing(.pixels, "the dip time is unavailable, so the stability window has no start")
        var maxDisplacement = stability
        if let dipTime {
            let span = frames.compactMap { fr -> SIMD2<Double>? in
                guard fr.realTime >= dipTime, fr.realTime <= releaseTime else { return nil }
                return p2(fr, Body2DPoint.nose, o.minimumConfidence2D)
            }
            if span.count >= 3 {
                let mean = span.reduce(SIMD2<Double>(0, 0), +) / Double(span.count)
                let squares = span.map { simd_length_squared($0 - mean) }
                stability = .ok((squares.reduce(0, +) / Double(span.count)).squareRoot(), .pixels)
                maxDisplacement = .ok(squares.map { $0.squareRoot() }.max() ?? 0, .pixels)
            } else {
                let why = "only \(span.count) frame(s) between the dip and release carried a confident nose"
                stability = .missing(.pixels, why); maxDisplacement = .missing(.pixels, why)
            }
        }
        return HeadMetrics(yaw: yaw, pitchRelative: pitch, stabilityPx: stability, maximumDisplacementPx: maxDisplacement,
                           facesRimDirection: faces, facesRimUnavailableReason: facesWhy,
                           noseOffsetPx: noseOffset, approximationNote: note)
    }

    // ---- hands -------------------------------------------------------------------------------

    public static func hands(frames: [BodyFrame], ballTrack: [BodyBallSample], releaseTime: Double,
                             shootingSide: String?, options o: BodyKinematicsOptions = .init()) -> HandMetrics {
        let withHands = frames.filter { !$0.hands.isEmpty }
        func shootingHand(_ f: BodyFrame) -> BodyHandFrame? {
            f.hands.first(where: { $0.role == "shooting" }) ?? (shootingSide.flatMap { s in f.hands.first(where: { $0.chirality == s }) })
        }
        func guideHand(_ f: BodyFrame) -> BodyHandFrame? {
            f.hands.first(where: { $0.role == "guide" }) ?? (shootingSide.flatMap { s in f.hands.first(where: { $0.chirality != s }) })
        }
        var out = HandMetrics(shootingHandChirality: nil, lastFingertipsOnBall: [], fingertipLastContactRealTime: [:],
                              fingertipsUnavailableReason: nil,
                              wristSnapRate: .missing(.radiansPerSecond, "no hand was detected near release"),
                              guideThumbTowardBall: .missing(.pixelsPerSecond, "no guide hand was detected near release"),
                              handsSeenFrames: withHands.count)
        guard !withHands.isEmpty else {
            out.fingertipsUnavailableReason = "Vision detected no hands anywhere in this window"
            return out
        }
        out.shootingHandChirality = withHands.compactMap { shootingHand($0)?.chirality }.first

        // Release fingers: the last fingertip(s) within one ball radius of the ball centre.
        if ballTrack.isEmpty {
            out.fingertipsUnavailableReason = "no ball track was supplied, so fingertip contact cannot be measured"
        } else {
            let ball = ballTrack.sorted { $0.t < $1.t }
            var last: [String: Double] = [:]
            var closest = Double.infinity
            for f in withHands where f.realTime <= releaseTime + 0.05 {
                guard let hand = shootingHand(f) else { continue }
                guard let b = ball.min(by: { abs($0.t - f.realTime) < abs($1.t - f.realTime) }),
                      abs(b.t - f.realTime) < 0.02, b.diameterPx > 0 else { continue }
                let centre = SIMD2(b.u, b.v), radius = b.diameterPx / 2 * o.fingertipContactRadii
                for tip in HandLandmark.fingertips {
                    guard let p = hand.landmarks[tip] else { continue }
                    let d = simd_length(p.uv - centre)
                    closest = min(closest, d / (b.diameterPx / 2))
                    if d <= radius { last[tip] = max(last[tip] ?? -.infinity, f.realTime) }
                }
            }
            out.fingertipLastContactRealTime = last
            if last.isEmpty {
                out.fingertipsUnavailableReason = closest.isFinite
                    ? "no fingertip came within \(String(format: "%.1f", o.fingertipContactRadii)) ball radii of the ball centre up to release; the closest approach was \(String(format: "%.1f", closest)) radii"
                    : "no frame carried both a shooting-hand fingertip and a ball sample within 20 ms of each other"
            } else if let latest = last.values.max() {
                let gaps = withHands.map(\.realTime).sorted()
                var frameGap = 0.01
                if gaps.count >= 2 { frameGap = max(0.001, (gaps[gaps.count - 1] - gaps[0]) / Double(gaps.count - 1)) }
                out.lastFingertipsOnBall = last.filter { latest - $0.value <= frameGap * 1.5 }.keys.sorted()
            }
        }

        // Wrist snap: the rate of the image-plane hand direction (wrist → middle knuckle) at release.
        var times: [Double] = [], phase: [Double] = []
        var unwrap = 0.0, previous: Double? = nil
        for f in withHands.sorted(by: { $0.realTime < $1.realTime }) {
            guard let hand = shootingHand(f), let w = hand.landmarks[HandLandmark.wrist], let m = hand.landmarks[HandLandmark.middleMCP] else { continue }
            var a = atan2(-(m.v - w.v), m.u - w.u)          // image v grows downwards; flip to a maths angle
            if let p = previous {
                while a + unwrap - p > .pi { unwrap -= 2 * .pi }
                while a + unwrap - p < -.pi { unwrap += 2 * .pi }
            }
            a += unwrap
            previous = a
            times.append(f.realTime); phase.append(a)
        }
        if times.count < 2 * o.rateHalfWindow + 2 {
            out.wristSnapRate = .missing(.radiansPerSecond, "only \(times.count) frame(s) carried the shooting hand's wrist and middle knuckle; the derivative needs \(2 * o.rateHalfWindow + 2)")
        } else if let i = nearestIndex(times, releaseTime), abs(times[i] - releaseTime) < 0.05,
                  let rate = slope(times: times, values: phase, at: i, halfWindow: o.rateHalfWindow) {
            out.wristSnapRate = .ok(rate, .radiansPerSecond)
        } else {
            out.wristSnapRate = .missing(.radiansPerSecond, "no hand detection fell within 50 ms of release")
        }

        // Guide-hand thumb: the component of the thumb tip's image velocity toward the ball, at release.
        if ballTrack.isEmpty {
            out.guideThumbTowardBall = .missing(.pixelsPerSecond, "no ball track was supplied, so 'toward the ball' has no direction")
        } else {
            let ball = ballTrack.sorted { $0.t < $1.t }
            var t: [Double] = [], us: [Double] = [], vs: [Double] = []
            for f in withHands.sorted(by: { $0.realTime < $1.realTime }) {
                guard let hand = guideHand(f), let tip = hand.landmarks[HandLandmark.thumbTip] else { continue }
                t.append(f.realTime); us.append(tip.u); vs.append(tip.v)
            }
            if t.count < 2 * o.rateHalfWindow + 2 {
                out.guideThumbTowardBall = .missing(.pixelsPerSecond, "only \(t.count) frame(s) carried a guide-hand thumb tip")
            } else if let i = nearestIndex(t, releaseTime), abs(t[i] - releaseTime) < 0.05,
                      let du = slope(times: t, values: us, at: i, halfWindow: o.rateHalfWindow),
                      let dv = slope(times: t, values: vs, at: i, halfWindow: o.rateHalfWindow),
                      let b = ball.min(by: { abs($0.t - t[i]) < abs($1.t - t[i]) }) {
                let toBall = SIMD2(b.u - us[i], b.v - vs[i])
                let n = simd_length(toBall)
                out.guideThumbTowardBall = n > 1e-6 ? .ok(simd_dot(SIMD2(du, dv), toBall / n), .pixelsPerSecond)
                                                    : .missing(.pixelsPerSecond, "the thumb tip and the ball centre coincide")
            } else {
                out.guideThumbTowardBall = .missing(.pixelsPerSecond, "no guide-hand detection fell within 50 ms of release")
            }
        }
        return out
    }

    // ---- the whole model -----------------------------------------------------------------------

    /// The per-shot body model. `releaseRealTime` comes from the caller (the ball physics, or
    /// `ReleaseFromPose`) — this function never invents a release.
    public static func model(timeline: BodyTimeline, releaseRealTime: Double,
                             ballTrack: [BodyBallSample] = [], rimImageU: Double? = nil,
                             options o: BodyKinematicsOptions = .init()) -> BodyModel {
        var warnings: [String] = []
        let frames = timeline.frames.sorted { $0.realTime < $1.realTime }
        let with3D = frames.filter { !$0.joints3D.isEmpty }
        let with2D = frames.filter { !$0.points2D.isEmpty }
        let withHands = frames.filter { !$0.hands.isEmpty }

        // Which side shoots: the caller's answer, else the wrist nearest the ball at release.
        var side = o.shootingSide
        if side == nil, !ballTrack.isEmpty,
           let f = with2D.min(by: { abs($0.realTime - releaseRealTime) < abs($1.realTime - releaseRealTime) }),
           let b = ballTrack.min(by: { abs($0.t - releaseRealTime) < abs($1.t - releaseRealTime) }) {
            let l = p2(f, Body2DPoint.leftWrist, o.minimumConfidence2D).map { simd_length($0 - SIMD2(b.u, b.v)) }
            let r = p2(f, Body2DPoint.rightWrist, o.minimumConfidence2D).map { simd_length($0 - SIMD2(b.u, b.v)) }
            if let l, let r { side = l < r ? "left" : "right" } else if l != nil { side = "left" } else if r != nil { side = "right" }
        }
        if side == nil {
            side = frames.compactMap { $0.hands.first(where: { $0.role == "shooting" })?.chirality }.first
        }
        if side == nil { warnings.append("the shooting side could not be determined, so the kinetic chain defaults to the right side and the wrist metrics are unavailable") }

        // Scale provenance: without a depth sensor the metres come from a body-height prior.
        let techniques = Set(frames.compactMap(\.heightEstimationTechnique))
        var scaleIsMeasured: Bool? = nil
        if techniques.contains("measured") && techniques.count == 1 { scaleIsMeasured = true }
        else if techniques == ["reference"] {
            scaleIsMeasured = false
            let heights = frames.compactMap(\.bodyHeightMetres)
            let h = heights.isEmpty ? nil : Stats.median(heights)
            warnings.append("every 3-D frame used the *reference* height estimate\(h.map { String(format: " (%.2f m)", $0) } ?? ""): there was no depth, so every metre below is a length scaled by a population prior, not a measurement — treat all metric stance and jump numbers as relative")
        }

        let allAngles = frames.map { angles(frame: $0, options: o, shootingSide: side) }

        // Vertical signal for the phases: the shooting wrist in 3-D if there is one, else its image
        // row (up-positive as −v). Unit differs, which is why the "quiet" threshold is a fraction.
        var times: [Double] = [], height: [Double] = [], source = ""
        let wrist3D = side == "left" ? Body3DJoint.leftWrist : Body3DJoint.rightWrist
        let wrist2D = side == "left" ? Body2DPoint.leftWrist : Body2DPoint.rightWrist
        for f in frames {
            if let p = p3(f, wrist3D) { times.append(f.realTime); height.append(simd_dot(p, o.up)) }
        }
        if times.count >= 5 { source = "3-D \(wrist3D) height (metres)" }
        else {
            times.removeAll(); height.removeAll()
            for f in frames { if let p = p2(f, wrist2D, o.minimumConfidence2D) { times.append(f.realTime); height.append(-p.y) } }
            source = "2-D \(wrist2D) image height (−v, pixels)"
            if times.count < 5, !ballTrack.isEmpty {
                times = ballTrack.map(\.t); height = ballTrack.map { -$0.v }
                source = "ball image height (−v, pixels)"
            }
        }
        let ph = phases(times: times, height: height, releaseRealTime: releaseRealTime, signalSource: source, options: o)
        let searchStart = ph.dip.value ?? (releaseRealTime - o.dipLookbackSeconds)
        let chain = kineticChain(angles: allAngles, from: searchStart, to: releaseRealTime + 0.10, side: side, options: o)
        let (st, stanceWarnings) = stance(frames: frames, dipTime: ph.dip.value, setTime: ph.setPoint.value,
                                          releaseTime: releaseRealTime, options: o)
        warnings.append(contentsOf: stanceWarnings)
        let hd = head(frames: frames, dipTime: ph.dip.value, releaseTime: releaseRealTime, rimImageU: rimImageU, options: o)
        let hn = hands(frames: frames, ballTrack: ballTrack, releaseTime: releaseRealTime, shootingSide: side, options: o)
        let atRelease = allAngles.min(by: { abs($0.realTime - releaseRealTime) < abs($1.realTime - releaseRealTime) })
        if with3D.isEmpty { warnings.append("no frame in this window carried a 3-D body, so every true 3-D angle is unavailable") }

        let po = posture(frames: frames, dipTime: ph.dip.value, releaseTime: releaseRealTime, options: o)
        let cov = BodyCoverage.perJoint(timeline: timeline, minimumConfidence: o.minimumConfidence2D,
                                        edgeMarginPx: o.edgeMarginPx, symmetryThreshold: o.symmetrySeenFraction)
        for c in cov where c.clippedFraction > 0.5 && c.framesSeen > 0 {
            warnings.append(String(format: "the %@ sat within %.0f px of a frame border on %.0f %% of the frames it was seen on: it is clipped, so its position is where the frame ends, not where the joint is",
                                   c.name, o.edgeMarginPx, 100 * c.clippedFraction))
        }

        return BodyModel(angles: allAngles, anglesAtRelease: atRelease, phases: ph, chain: chain, stance: st,
                         head: hd, hands: hn, posture: po, coverage: cov, shootingSide: side,
                         framesWith3D: with3D.count, framesWith2D: with2D.count, framesWithHands: withHands.count,
                         scaleIsMeasured: scaleIsMeasured, warnings: warnings)
    }

    // ---- neck and trunk attitude, in the image plane (iteration 3) -------------------------

    /// Where the neck is on a frame, and what stood in for it. Vision's 2-D model has a `neck` point;
    /// when it is missing or unconfident the mid-shoulder is the fallback, and the caller is told which.
    static func neck2D(_ f: BodyFrame, _ minimumConfidence: Double) -> (uv: SIMD2<Double>, source: String)? {
        if let n = p2(f, Body2DPoint.neck, minimumConfidence) { return (n, "neck") }
        if let l = p2(f, Body2DPoint.leftShoulder, minimumConfidence),
           let r = p2(f, Body2DPoint.rightShoulder, minimumConfidence) { return ((l + r) / 2, "mid-shoulder") }
        return nil
    }

    /// The head centre on a frame: the ears when both are seen (the most stable pair on the skull),
    /// then the eyes, then the nose. Never a blend of whichever happened to be found — that would
    /// move the point when the set changes and manufacture head motion out of detector coverage.
    static func head2D(_ f: BodyFrame, _ minimumConfidence: Double) -> (uv: SIMD2<Double>, source: String)? {
        if let l = p2(f, Body2DPoint.leftEar, minimumConfidence), let r = p2(f, Body2DPoint.rightEar, minimumConfidence) {
            return ((l + r) / 2, "mid-ear")
        }
        if let l = p2(f, Body2DPoint.leftEye, minimumConfidence), let r = p2(f, Body2DPoint.rightEye, minimumConfidence) {
            return ((l + r) / 2, "mid-eye")
        }
        if let n = p2(f, Body2DPoint.nose, minimumConfidence) { return (n, "nose") }
        return nil
    }

    static func posture(frames: [BodyFrame], dipTime: Double?, releaseTime: Double,
                        options o: BodyKinematicsOptions) -> PostureMetrics {
        let why = "no frame in this window carried both a neck (or two shoulders) and two hips"
        var trunk: [(t: Double, a: Double)] = []
        var headTrunk: [(t: Double, a: Double)] = []
        var headLine: [(t: Double, a: Double)] = []
        var neckSources = Set<String>(), headSources = Set<String>()
        for f in frames {
            guard let neck = neck2D(f, o.minimumConfidence2D),
                  let lh = p2(f, Body2DPoint.leftHip, o.minimumConfidence2D),
                  let rh = p2(f, Body2DPoint.rightHip, o.minimumConfidence2D) else { continue }
            neckSources.insert(neck.source)
            let hip = (lh + rh) / 2
            // Image coordinates have v increasing downward, so "up the trunk" is −v.
            let up = SIMD2(neck.uv.x - hip.x, -(neck.uv.y - hip.y))
            guard simd_length(up) > 4 else { continue }
            trunk.append((f.realTime, atan2(up.x, up.y)))
            guard let head = head2D(f, o.minimumConfidence2D) else { continue }
            headSources.insert(head.source)
            let neckUp = SIMD2(head.uv.x - neck.uv.x, -(head.uv.y - neck.uv.y))
            guard simd_length(neckUp) > 4 else { continue }
            headTrunk.append((f.realTime, foldLine(atan2(neckUp.x, neckUp.y) - atan2(up.x, up.y))))
            if let ls = p2(f, Body2DPoint.leftShoulder, o.minimumConfidence2D),
               let rs = p2(f, Body2DPoint.rightShoulder, o.minimumConfidence2D) {
                let line = SIMD2(rs.x - ls.x, -(rs.y - ls.y))
                guard simd_length(line) > 4 else { continue }
                // The perpendicular of the shoulder line, taken on the upward side.
                var perp = SIMD2(-line.y, line.x)
                if perp.y < 0 { perp = -perp }
                headLine.append((f.realTime, foldLine(atan2(neckUp.x, neckUp.y) - atan2(perp.x, perp.y))))
            }
        }
        func at(_ s: [(t: Double, a: Double)], _ t: Double) -> BodyMeasure {
            guard let i = nearestIndex(s.map(\.t), t) else { return .missing(.radians, why) }
            return .ok(s[i].a, .radians)
        }
        func jitter(_ s: [(t: Double, a: Double)]) -> BodyMeasure {
            guard s.count >= 6 else { return .missing(.radians, "fewer than six frames carried the angle, so its per-frame noise is not estimable") }
            var d: [Double] = []
            for i in 1..<s.count { d.append(foldLine(s[i].a - s[i - 1].a)) }
            return .ok(Stats.sd(d) / 2.0.squareRoot(), .radians)
        }
        let from = dipTime ?? (releaseTime - o.dipLookbackSeconds)
        let span = trunk.filter { $0.t >= from && $0.t <= releaseTime }
        let extreme = span.max(by: { abs($0.a) < abs($1.a) })
        return PostureMetrics(
            trunkToVerticalAtRelease: trunk.isEmpty ? .missing(.radians, why) : at(trunk, releaseTime),
            trunkToVerticalJitter: jitter(trunk),
            trunkToVerticalMaximum: extreme.map { BodyMeasure.ok($0.a, .radians) }
                ?? .missing(.radians, "no frame between the dip and the release carried the trunk"),
            headToTrunkAtRelease: headTrunk.isEmpty
                ? .missing(.radians, "no frame carried a neck and a head cue (ears, eyes or nose) together") : at(headTrunk, releaseTime),
            headToTrunkJitter: jitter(headTrunk),
            headToShoulderLineAtRelease: headLine.isEmpty
                ? .missing(.radians, "no frame carried a head cue and both shoulders together") : at(headLine, releaseTime),
            headToShoulderLineJitter: jitter(headLine),
            neckSource: neckSources.sorted().joined(separator: "+").isEmpty ? "none" : neckSources.sorted().joined(separator: "+"),
            headSource: headSources.sorted().joined(separator: "+").isEmpty ? "none" : headSources.sorted().joined(separator: "+"),
            frames: trunk.count,
            note: "image-plane angles: the lean the camera can see. On a side-on clip this plane is the shot plane to within the camera's azimuth from the shot line; nothing here is a true 3-D lean, and the transverse component is refused elsewhere.")
    }
}

// MARK: - Per-joint coverage (iteration 3)

/// Which joints this window actually saw, how noisy each one is, and which are being carried by
/// their mirror partner rather than observed. Pure: it reads a timeline and nothing else.
public enum BodyCoverage {

    /// Left ↔ right, for the symmetry flag and the symmetric-limb prior.
    public static let mirror: [String: String] = [
        Body2DPoint.leftShoulder: Body2DPoint.rightShoulder, Body2DPoint.rightShoulder: Body2DPoint.leftShoulder,
        Body2DPoint.leftElbow: Body2DPoint.rightElbow, Body2DPoint.rightElbow: Body2DPoint.leftElbow,
        Body2DPoint.leftWrist: Body2DPoint.rightWrist, Body2DPoint.rightWrist: Body2DPoint.leftWrist,
        Body2DPoint.leftHip: Body2DPoint.rightHip, Body2DPoint.rightHip: Body2DPoint.leftHip,
        Body2DPoint.leftKnee: Body2DPoint.rightKnee, Body2DPoint.rightKnee: Body2DPoint.leftKnee,
        Body2DPoint.leftAnkle: Body2DPoint.rightAnkle, Body2DPoint.rightAnkle: Body2DPoint.leftAnkle,
        Body2DPoint.leftEye: Body2DPoint.rightEye, Body2DPoint.rightEye: Body2DPoint.leftEye,
        Body2DPoint.leftEar: Body2DPoint.rightEar, Body2DPoint.rightEar: Body2DPoint.leftEar,
        Body2DPoint.leftIndexMCP: Body2DPoint.rightIndexMCP, Body2DPoint.rightIndexMCP: Body2DPoint.leftIndexMCP,
        Body2DPoint.leftLittleMCP: Body2DPoint.rightLittleMCP, Body2DPoint.rightLittleMCP: Body2DPoint.leftLittleMCP,
        Body2DPoint.leftHandWrist: Body2DPoint.rightHandWrist, Body2DPoint.rightHandWrist: Body2DPoint.leftHandWrist,
    ]

    /// The head-direction cues, kept together because they are reported as a group.
    public static let headCues = [Body2DPoint.nose, Body2DPoint.leftEye, Body2DPoint.rightEye,
                                  Body2DPoint.leftEar, Body2DPoint.rightEar]

    public static func perJoint(timeline: BodyTimeline, minimumConfidence: Double = 0.3,
                                edgeMarginPx: Double = 6, symmetryThreshold: Double = 0.05) -> [BodyJointCoverage] {
        let total = timeline.frames.count
        let w = Double(timeline.imageWidth), h = Double(timeline.imageHeight)
        func jitter(_ xs: [SIMD2<Double>]) -> BodyMeasure {
            guard xs.count >= 6 else { return .missing(.pixels, "fewer than six frames carried this joint, so its per-frame noise is not estimable") }
            var d: [Double] = []
            for i in 1..<xs.count { d.append(simd_length(xs[i] - xs[i - 1])) }
            // Isotropic: the SD of the *displacement magnitude* over √2 understates a 2-D noise, so
            // the two axes are done separately and combined, which is what Ch 10 §10.5.1 describes.
            var du: [Double] = [], dv: [Double] = []
            for i in 1..<xs.count { du.append(xs[i].x - xs[i - 1].x); dv.append(xs[i].y - xs[i - 1].y) }
            let su = Stats.sd(du) / 2.0.squareRoot(), sv = Stats.sd(dv) / 2.0.squareRoot()
            return .ok(((su * su + sv * sv) / 2).squareRoot(), .pixels)
        }
        var out: [BodyJointCoverage] = []
        var seenFractions: [String: Double] = [:]
        // Appendage points are counted too, and against the *same* floor, so a coverage table can
        // be read across the body and the hands without two rules. Adding feet adds rows here and
        // nowhere else.
        for name in Body2DPoint.allIncludingAppendages {
            let n = timeline.frames.filter { ($0.points2D[name]?.confidence ?? -1) >= minimumConfidence }.count
            seenFractions[name] = total > 0 ? Double(n) / Double(total) : 0
        }
        for name in Body2DPoint.allIncludingAppendages {
            var pts: [SIMD2<Double>] = [], confs: [Double] = [], clipped = 0
            for f in timeline.frames {
                guard let p = f.points2D[name], p.confidence >= minimumConfidence else { continue }
                pts.append(p.uv); confs.append(p.confidence)
                if p.u <= edgeMarginPx || p.v <= edgeMarginPx || p.u >= w - edgeMarginPx || p.v >= h - edgeMarginPx { clipped += 1 }
            }
            let fraction = seenFractions[name] ?? 0
            let partner = mirror[name]
            let partnerSeen = partner.flatMap { seenFractions[$0] } ?? 0
            let inferred = fraction < symmetryThreshold && partnerSeen >= symmetryThreshold
            var note: String? = nil
            if inferred, let partner {
                note = String(format: "seen on %.0f %% of frames against the %@'s %.0f %%: this is the far side of a side-on view, so the skeleton carries it on the near side's bone length and its position is an inference, not a measurement",
                              100 * fraction, partner, 100 * partnerSeen)
            } else if fraction == 0 {
                note = "the detector never returned this point in this window"
            } else if clipped > 0, Double(clipped) / Double(max(1, pts.count)) > 0.2 {
                note = String(format: "within %.0f px of a frame border on %.0f %% of the frames it was seen on — the frame ends there, so treat the position as a bound, not a measurement",
                              edgeMarginPx, 100 * Double(clipped) / Double(max(1, pts.count)))
            }
            out.append(BodyJointCoverage(
                name: name, source: "body2D", framesSeen: pts.count, framesTotal: total, seenFraction: fraction,
                medianConfidence: confs.isEmpty ? .missing(.ratio, "the point was never returned above the confidence floor") : .ok(Stats.median(confs), .ratio),
                jitterPixels: jitter(pts),
                clippedFraction: pts.isEmpty ? 0 : Double(clipped) / Double(pts.count),
                symmetryInferred: inferred, note: note))
        }
        // Hands, by the chirality the detector reported. A hand with no chirality is counted under
        // "hand(unlabelled)" rather than assigned to a side.
        var byHand: [String: [SIMD2<Double>]] = [:]
        var handConf: [String: [Double]] = [:]
        for f in timeline.frames {
            for hand in f.hands {
                let key = hand.chirality.map { "\($0)Hand" } ?? "hand(unlabelled)"
                guard let anchor = hand.landmarks[HandLandmark.middleMCP] ?? hand.landmarks[HandLandmark.wrist] else { continue }
                byHand[key, default: []].append(anchor.uv)
                handConf[key, default: []].append(hand.confidence)
            }
        }
        for key in byHand.keys.sorted() {
            let pts = byHand[key] ?? []
            out.append(BodyJointCoverage(
                name: key, source: "hand", framesSeen: pts.count, framesTotal: total,
                seenFraction: total > 0 ? Double(pts.count) / Double(total) : 0,
                medianConfidence: (handConf[key]?.isEmpty ?? true) ? .missing(.ratio, "no hand") : .ok(Stats.median(handConf[key]!), .ratio),
                jitterPixels: jitter(pts), clippedFraction: 0, symmetryInferred: false,
                note: "the hand's middle-finger MCP, the landmark that moves least within the hand"))
        }
        return out
    }
}

// MARK: - Shot-to-shot summaries

/// mean / SD / n for one metric across shots, in the style of the existing metric rows: a summary
/// that cannot be computed is nil **with a reason**, and n is always reported (digest Ch 13 §13.3).
public struct BodyMetricSummary: Sendable, Codable {
    public var name: String
    public var unit: BodyMeasure.Unit
    public var n: Int
    public var nMissing: Int
    public var mean: BodyMeasure
    public var sd: BodyMeasure
    public var missingReasons: [String]
}

public enum BodySummaries {
    /// Summarise one metric over a set of shots. `minimumN` is the smallest sample that gets an SD.
    public static func summarise(_ name: String, _ values: [BodyMeasure], minimumN: Int = 2) -> BodyMetricSummary {
        let unit = values.first?.unit ?? .ratio
        let good = values.filter { $0.unit == unit }.compactMap(\.value)
        let reasons = Array(Set(values.compactMap(\.unavailableReason))).sorted()
        let mixed = values.contains { $0.unit != unit }
        let n = good.count
        guard !mixed else {
            let why = "the shots did not agree on a unit for \(name)"
            return BodyMetricSummary(name: name, unit: unit, n: 0, nMissing: values.count,
                                     mean: .missing(unit, why), sd: .missing(unit, why), missingReasons: [why])
        }
        guard n >= 1 else {
            let why = "no shot produced \(name)"
            return BodyMetricSummary(name: name, unit: unit, n: 0, nMissing: values.count,
                                     mean: .missing(unit, why), sd: .missing(unit, why), missingReasons: reasons.isEmpty ? [why] : reasons)
        }
        let sd: BodyMeasure = n >= minimumN ? .ok(Stats.sd(good), unit)
                                            : .missing(unit, "n = \(n): an SD needs at least \(minimumN) shots")
        return BodyMetricSummary(name: name, unit: unit, n: n, nMissing: values.count - n,
                                 mean: .ok(Stats.mean(good), unit), sd: sd, missingReasons: reasons)
    }
}

// ============================================================================================
// MARK: - One skeleton per shot: a 3-D body fitted to the 2-D points (iteration 2, 2026-09-14)
// ============================================================================================
//
// Why this exists. Measured on IMG_1765, Apple's `DetectHumanBodyPose3DRequest` joints reproject
// 21–94 px away from Apple's *own* 2-D joints on the same frame (shooter ≈ 500 px tall), its elbow
// angle jitters 2.4–8.8°/frame, and it disagrees with the 2-D elbow by up to 54°. The 2-D points do
// not have that problem: they jitter 1.0–2.5 px and agree with an independent MediaPipe pose to a
// median of 4–7 px on every joint except the hip (a definition difference, 13–27 px).
//
// So the 3-D body is rebuilt from the part that is precise. One skeleton per shot: bone lengths are
// constant for the whole window, the free variables are the joint positions in camera metres, and the
// cost is
//
//     Σ_frames Σ_joints ‖π(p) − x_observed‖²          reprojection, pixels, Huber-clipped
//   + Σ_frames Σ_bones  w_bone  (|p_a − p_b| − L)²    constant bone lengths
//   + Σ_frames Σ_joints w_smooth ‖p₋ − 2p + p₊‖²      temporal smoothness (second difference)
//
// with the metre terms converted to pixels through the body's own metres-per-pixel so the three are
// commensurable. Holding bone lengths fixed leaves each joint two rotational degrees of freedom about
// its parent, i.e. the unknowns *are* the joint angles; positions are simply an easier chart to solve
// in. Minimised by block coordinate descent: one Gauss-Newton (Levenberg-damped) step per frame over
// that frame's 3·J unknowns, sweeping forwards and backwards, with the neighbouring frames held fixed
// inside a sweep. Foundation + simd only (CLAUDE.md rule 2); `LinAlg.leastSquares` does the 39×39 solve.
//
// What it cannot do. A single camera fixes shape only up to one overall scale, so the metres come from
// outside — `BodyScaleProvenance` — and every result says which. Depth is the weak direction: a joint
// moving along its own view ray changes no pixel, and only the bone lengths and the smoothness term
// pin it down. Treat a fitted depth as an inference, a fitted image-plane position as a measurement.

/// Where the metres came from. Nothing in this file invents one.
public enum BodyScaleProvenance: Sendable, Equatable, Codable {
    /// The shooter told us their standing height.
    case statedHeight(metres: Double)
    /// A ruler of known size at (approximately) the shooter's depth — on a side view, the rim.
    /// `majorAxisPx` is the ellipse's major axis, which is the ring's true diameter in pixels.
    case rimRuler(diameterMetres: Double, majorAxisPx: Double)
    /// Metres per pixel measured some other way; the caller says how.
    case metresPerPixel(Double, note: String)
    /// Nothing trustworthy. Angles are still produced (they are scale-free); every metre is refused.
    case none

    public var note: String {
        switch self {
        case .statedHeight(let m):
            return String(format: "the shooter's stated standing height, %.3f m, against their ankle-to-nose pixel span", m)
        case .rimRuler(let d, let px):
            return String(format: "the rim ruler: %.4f m across %.1f px of ring major axis, assuming the shooter is at the rim's depth (side view)", d, px)
        case .metresPerPixel(let s, let note):
            return String(format: "%.6f m/px supplied by the caller (%@)", s, note)
        case .none:
            return "no scale was supplied, so no length is in metres"
        }
    }
    public var isMeasured: Bool { if case .none = self { return false }; return true }
}

/// Which way the shooter faces **in the image**, from the 2-D points alone.
///
/// The sign is all a single camera can honestly give: the shooter's facing direction has a depth
/// component no monocular view recovers, and on the near-side views this project films the facing is
/// almost exactly along the image's horizontal anyway. Two independent cues are used and they must
/// agree:
///
///   · **head** — the nose sits forward of the neck base. `median(nose.u − neck.u)`.
///   · **legs** — a flexed knee travels forward of the hip-to-ankle line.
///     `median(knee.u − ½(hip.u + ankle.u))`, pooled over both legs.
///
/// They are independent (one is the cervical spine, the other the femur), so agreement is evidence
/// and disagreement is a refusal, not a vote. Nothing here is a yaw *angle*: a sign is what two
/// horizontal offsets support.
public struct BodyFacingCue: Sendable, Equatable {
    /// +1 when the shooter faces image-right (larger u), −1 image-left, nil when the view does not say.
    public var imageSign: Double?
    public var unavailableReason: String?
    /// Median head offset and leg offset in pixels, for the note and for the tests.
    public var headOffsetPx: Double?
    public var legOffsetPx: Double?
    public var note: String
}

public enum BodyFacing {

    /// `minimumOffsetPx` is the keypoint jitter floor: an offset inside it is not a direction.
    public static func fromImage(frames: [BodyFrame], minimumConfidence2D: Double = 0.3,
                                 minimumOffsetPx: Double = 6) -> BodyFacingCue {
        func p(_ f: BodyFrame, _ n: String) -> SIMD2<Double>? {
            guard let q = f.points2D[n], q.confidence >= minimumConfidence2D else { return nil }
            return q.uv
        }
        var headOffsets: [Double] = []
        for f in frames {
            guard let nose = p(f, Body2DPoint.nose) else { continue }
            var centre: Double? = p(f, Body2DPoint.neck)?.x
            if centre == nil, let ls = p(f, Body2DPoint.leftShoulder), let rs = p(f, Body2DPoint.rightShoulder) {
                centre = (ls.x + rs.x) / 2
            }
            guard let c = centre else { continue }
            headOffsets.append(nose.x - c)
        }
        var legOffsets: [Double] = []
        for f in frames {
            for side in ["left", "right"] {
                guard let hip = p(f, side + "Hip"), let knee = p(f, side + "Knee"), let ankle = p(f, side + "Ankle") else { continue }
                legOffsets.append(knee.x - (hip.x + ankle.x) / 2)
            }
        }
        let head: Double? = headOffsets.count >= 3 ? Stats.median(headOffsets) : nil
        let leg: Double? = legOffsets.count >= 3 ? Stats.median(legOffsets) : nil
        func voice(_ x: Double?) -> Double? {
            guard let x, abs(x) >= minimumOffsetPx else { return nil }
            return x > 0 ? 1 : -1
        }
        let hv = voice(head), lv = voice(leg)
        func px(_ x: Double?) -> String { x.map { String(format: "%.1f px", $0) } ?? "unavailable" }
        let seen = "head cue \(px(head)), leg cue \(px(leg)), jitter floor \(String(format: "%.1f", minimumOffsetPx)) px"
        switch (hv, lv) {
        case (nil, nil):
            return BodyFacingCue(imageSign: nil,
                                 unavailableReason: "neither the nose-past-the-neck offset nor the knee-past-the-hip-to-ankle-line offset clears the keypoint jitter floor, so this window does not say which way the shooter faces (\(seen))",
                                 headOffsetPx: head, legOffsetPx: leg, note: seen)
        case (let h?, let l?) where h != l:
            return BodyFacingCue(imageSign: nil,
                                 unavailableReason: "the head and the legs disagree about which way the shooter faces (\(seen)): one of the two is wrong and this window cannot say which, so no facing direction is claimed",
                                 headOffsetPx: head, legOffsetPx: leg, note: seen)
        case (let h?, let l?):
            _ = l
            return BodyFacingCue(imageSign: h, unavailableReason: nil, headOffsetPx: head, legOffsetPx: leg,
                                 note: "the head and the legs agree that the shooter faces image-\(h > 0 ? "right" : "left") (\(seen))")
        case (let h?, nil):
            return BodyFacingCue(imageSign: h, unavailableReason: nil, headOffsetPx: head, legOffsetPx: leg,
                                 note: "the shooter faces image-\(h > 0 ? "right" : "left") on the head cue alone; the legs never cleared the jitter floor (\(seen))")
        case (nil, let l?):
            return BodyFacingCue(imageSign: l, unavailableReason: nil, headOffsetPx: head, legOffsetPx: leg,
                                 note: "the shooter faces image-\(l > 0 ? "right" : "left") on the leg cue alone; the head never cleared the jitter floor (\(seen))")
        }
    }
}

public struct BodyBoneLength: Sendable, Codable, Equatable {
    public var name: String
    public var a: String, b: String
    public var metres: Double
    /// The largest projected length seen in the window, in pixels. A bone can never be shorter than
    /// this once scaled, so it is a hard floor on the fitted length, not a guess.
    public var maximumProjectedPixels: Double
    /// How far the per-frame fitted length wandered from `metres` (median absolute, metres).
    public var madMetres: Double
    public var frames: Int
    /// Where `metres` came from: "projection floor" (the bone's own longest projection — a
    /// measurement), "anthropometric prior" (Winter's fraction of the shooter's fitted stature,
    /// taken because the floor under-read it — a prior, flagged), or "fitted median" (the older
    /// per-sweep refit, used for the torso and head bones). Nil on records older than iteration 4.
    public var source: String?
}

public struct BodySkeletonOptions: Sendable {
    public var intrinsics: CameraIntrinsics
    public var scale: BodyScaleProvenance = .none
    public var minimumConfidence2D: Double = 0.3
    /// Weight on a bone-length error of one pixel-equivalent, relative to a reprojection error of one
    /// pixel. Swept on IMG_1765 t 88.5–95.5 (see PHASE2-PREP "Body model, iteration 2"): 0.3/0.6 puts
    /// the reprojection RMS at 1.8 px — the 2-D input's own per-frame noise — and minimises the elbow
    /// jitter at 1.49°/frame. Heavier bones (4.0) fight the pixels for 20 px of reprojection; lighter
    /// smoothing (0.1) buys reprojection at the cost of 7°/frame of elbow jitter.
    public var boneWeight: Double = 0.3
    /// Weight on a second difference of one pixel-equivalent. 1.0 = "a frame-to-frame acceleration the
    /// size of the pixel noise costs the same as the pixel noise".
    ///
    /// **0.6 → 0.3 in iteration 4, re-swept because its premise changed.** 0.6 was chosen in
    /// iteration 2 when every bone was soft: smoothing was then the only thing holding the elbow
    /// still. With the limb bones rigid (`limbBoneWeight`) the bone constraint does that work, and
    /// 0.6 instead fights the depth swing a rigid arm has to make — the fit buys the smoothness back
    /// by moving joints in the image plane, which shows up as reprojection error. Measured over 36
    /// real free throws from the phone and the 4 labelled 240 fps windows (PHASE2-PREP "Body model,
    /// iteration 4"), reprojection RMS / shooting-elbow jitter at limb weight 3 and 25 sweeps:
    /// 0.6 → 4.06 px / 0.91°; 0.45 → 3.47 / 1.06; **0.3 → 2.65 / 1.27**; 0.2 → 1.95 / 1.55 (phone).
    /// 0.3 is where the reprojection lands back under the old defaults' on both clips while the
    /// elbow jitter stays inside the 1.4–1.9°/frame this project has always reported.
    public var smoothnessWeight: Double = 0.3
    /// End frames have no second difference; they get this much first-difference penalty instead.
    public var endpointWeight: Double = 0.3
    /// Reprojection residuals beyond this many pixels are down-weighted (Huber). Vision-vs-MediaPipe
    /// disagreement is 4–7 px median, so 12 px is comfortably outside the honest range.
    public var huberPixels: Double = 12.0
    /// Block coordinate descent sweeps. **10 → 25 in iteration 4**: with the limb bones rigid the
    /// problem is stiffer and 10 sweeps stopped short of the minimum — on the 240 fps windows 10/25/40
    /// sweeps give 3.96 / 2.75 / 2.56 px of reprojection RMS and 0.83 / 0.63 / 0.61°/frame of elbow
    /// jitter, so 25 takes nearly all of it. The fit is ~0.1 s of a ~2.9 s window, so 25 sweeps cost
    /// about 5 % of the window and buy 1.2 px.
    public var sweeps: Int = 25
    /// Bone lengths are re-estimated from the fit after this many sweeps, then every sweep after.
    public var boneRefitAfterSweep: Int = 3
    public var levenberg: Double = 1e-2
    /// Ankle-to-nose distance as a fraction of standing height. Winter, *Biomechanics and Motor Control
    /// of Human Movement*, segment table: nose ≈ 0.930 H, ankle joint ≈ 0.039 H.
    public var ankleToNoseFractionOfHeight: Double = 0.891
    /// On a side view the shoulder and hip *lines* point almost along the view ray, so their projected
    /// length is a few pixels of a much longer bone and the fit has no way to recover them: measured on
    /// IMG_1765 the free fit collapsed the biacromial breadth to 0.157 m. Pinning the two transverse
    /// breadths to population fractions of the standing height keeps the torso from shearing. It is a
    /// **prior, not a measurement** — the result says so, and anything derived from those two bones
    /// (shoulder-line and hip-line yaw) inherits that provenance.
    ///
    /// **Off by default, on measurement.** On IMG_1765 pinning the biacromial to 0.448 m left a
    /// per-frame spread of 0.148 m around it — the pixels simply do not support any breadth — and cost
    /// 0.5 px of reprojection. The yaw is refused outright by `minimumBreadthProjectionFraction`
    /// instead, which is a statement about what this view can see rather than a borrowed number.
    public var transverseBreadthFromHeight = false
    /// Winter's segment table: biacromial ≈ 0.245 H, biiliac ≈ 0.191 H.
    public var biacromialFractionOfHeight: Double = 0.245
    public var biiliacFractionOfHeight: Double = 0.191
    /// Standing heights a scale may imply. Outside it, the scale is refused, not clamped.
    public var plausibleHeightRange: ClosedRange<Double> = 1.40...2.20
    /// A transverse breadth is observable only if it gets near frontoparallel at some point in the
    /// shot. Below this fraction of a plausible breadth, the shoulder/hip **line** — and therefore the
    /// yaw and everything measured against the facing direction — is refused instead of fitted.
    public var minimumBreadthProjectionFraction: Double = 0.70

    // --- iteration 3 (2026-09-15) ---------------------------------------------------------------
    /// Solve for the **neck** as well, from Vision's own 2-D `neck` point, braced to the nose and to
    /// both shoulders. Without it the head hangs off the two nose→shoulder bones alone and the whole
    /// head/neck attitude is a by-product of the shoulders.
    public var fitNeck = true
    /// Tie left and right bone lengths of the same limb (upper arm, forearm, thigh, shin, trunk side,
    /// nose→shoulder, neck→shoulder) to one length. A person's limbs are symmetric to a per cent or
    /// two, and on a side-on view the far limb is seen rarely and foreshortened, so its own longest
    /// projection is a bad floor. **A prior**: the bones it touches are listed in `symmetricBones`
    /// and the note says so.
    public var symmetricLimbPrior = true
    /// Weight each 2-D observation by the detector's confidence instead of by 1. A point at 0.35
    /// then pulls a third as hard as one at 1.0, which is what the confidence means.
    public var confidenceWeightedObservations = true
    /// How far in **real** seconds the fit will look for a Vision 3-D frame to take a joint's
    /// depth *sign* from, when the 3-D request was run on only every Nth frame. The sign is a
    /// front/back ordering that changes over tens of milliseconds, not one frame, so holding it
    /// across a short gap costs nothing; beyond this the joint starts flat instead.
    public var depthSeedHoldSeconds: Double = 0.10
    /// A 2-D point this close to a frame border is clipped — the frame ends there, so the detector
    /// has nowhere to put the joint but the edge.
    public var edgeMarginPx: Double = 6
    /// Above this fraction of clipped ankle observations the ankle-to-nose span is not a span, so the
    /// stated-height scale is **refused** rather than applied to a truncated shooter.
    public var maximumAnkleClipFraction: Double = 0.30

    // --- iteration 4 (2026-09-15): arms ----------------------------------------------------------
    /// Weight on the eight **limb** bones (upper arm, forearm, thigh, shin) in place of `boneWeight`.
    /// Measured on the 240 fps free throws at the old 0.3: the fitted forearm wandered between 0.07
    /// and 0.15 H *inside one shot* (SD 0.014 H, upper arm 0.13–0.18 H) — "constant bone lengths" was
    /// a soft wish, the drawn arm detached from its joints, and a bone that may shrink in depth at no
    /// pixel cost is then refit to a median that is too short. See PHASE2-PREP "Body model, iteration 4".
    public var limbBoneWeight: Double = 3.0
    /// A limb bone is at least as long as its longest projection (geometry: a projection can only
    /// shorten). With this on it is also at least Winter's population fraction of the shooter's own
    /// fitted stature — a **prior**, taken only when the floor is below it, and every bone says which
    /// it took (`BodyBoneLength.source`). On a near-side view the shooting upper arm never swings
    /// through the image plane: its floor read 0.155 H against 0.170 H for the guide arm of the same
    /// person, so the floor is view-limited there and the prior (0.186 H) is what the pixels cannot give.
    public var limbLengthPriorFromStature = true
    /// Winter's segment fractions of standing height, by bone name.
    public var limbFractionsOfHeight: [String: Double] = [
        "upperArmLeft": 0.186, "upperArmRight": 0.186, "forearmLeft": 0.146, "forearmRight": 0.146,
        "thighLeft": 0.245, "thighRight": 0.245, "shinLeft": 0.246, "shinRight": 0.246,
    ]
    /// The projection floor is the maximum of a running median of the bone's implied length over
    /// this many frames. A percentile (the old 95th) under-reads a bone that is frontoparallel for
    /// only a few frames of the shot; a raw maximum reads one frame's noise, and a maximum is biased
    /// upward by every error under it — 2-D noise, and the perspective magnification of a bone that
    /// is nearer the camera than the depth its pixels were converted at. The projected length is
    /// **stationary at its peak** (that is what frontoparallel means), so a median over ±4 frames
    /// costs almost nothing there and takes the bias out. Measured on the swinging-arm synthetic
    /// (recovered − true, upper arm / forearm): 5 frames +0.8 % / **+3.6 %**; **9 frames −0.1 % /
    /// +2.0 %**; 15 frames −0.8 % / +1.2 %; 21 frames −1.9 % / +0.9 % — past 9 the window starts
    /// smoothing over the peak itself and the well-observed bone pays.
    public var projectionFloorMedianFrames: Int = 9

    // --- iteration 5 (2026-09-15): the torso's transverse axis ----------------------------------
    /// When the shoulder/hip line is **proven unobservable** on this view — when
    /// `minimumBreadthProjectionFraction` has already refused its yaw — give the torso a transverse
    /// axis anyway, built from two separate things:
    ///
    ///   · its **length**, Winter's population breadth of the shooter's own fitted stature (a prior,
    ///     reported as one: `BodyBoneLength.source` says "population breadth (pinned)"), and
    ///   · its **direction**, from the measured facing sign (`BodyFacing`) plus one anatomical fact —
    ///     the shoulder line is across the body, so with the shooter facing image-right their left
    ///     side is the far one. Right-handed anatomy: forward × left = up.
    ///
    /// Why it is worth a prior. Left free, the fit collapses the breadth to what the pixels show —
    /// measured over 107 real phone shots the biacromial came out 0.057 H against an adult's 0.245 H,
    /// wandering 17.5 % inside one shot. That collapsed number was not a refusal, it was a wrong
    /// measurement, and it is what makes the fitted body a cardboard cut-out: both arms hang off the
    /// same point and the shooter has no thickness when the viewer orbits to the front. Everything
    /// derived from the shoulder *line* (yaw, facing, sagittal lean, foot stagger) stays refused —
    /// this changes the skeleton's shape, not what may be read off it.
    public var torsoBreadthWhenUnobservable = true
    /// Jitter floor on the facing cues, as a fraction of the ankle-to-nose pixel span (so it scales
    /// with how big the shooter is in frame). Floored at 3 px.
    public var facingOffsetFractionOfSpan: Double = 0.015
    /// Weight on Vision's own 3-D **placement** — the depth difference it puts across each bone — in
    /// pixel-equivalents per metre, like `boneWeight`. 0 uses only its front/back *sign* at
    /// initialisation, which is all iterations 1–4 did. See PHASE2-PREP "3-D model 1.1" for what it
    /// buys: Vision's 3-D body is itself near-planar on a side view (its own left/right hip depth
    /// separation is 0.0007 H against an adult's 0.191 H), so its placement carries almost no
    /// transverse information to borrow.
    public var visionDepthPriorWeight: Double = 0
    /// Smoothness weight in the **depth** direction, as a multiple of `smoothnessWeight`.
    ///
    /// **1.0 → 0.3 in iteration 5.** Iterations 1–4 smoothed all three axes equally, but the three are
    /// not equal: in the image plane the smoothness competes with a measurement (the reprojection
    /// term, which is strong there), while in depth it competes with nothing, so an isotropic weight
    /// is several times stiffer in depth than it is anywhere the camera can see. The symptom was the
    /// arm: on a near-side view the shooting arm lies in the image plane, so the picture itself says
    /// how far the elbow opens from the set to the release, and the fitted 3-D arm opened *less* —
    /// it was buying depth smoothness by bending into depth, and paying for it in reprojection.
    ///
    /// Measured over 107 real phone shots (PHASE2-PREP "3-D model 1.1"), reprojection RMS /
    /// shooting-elbow jitter / 3-D elbow opening against the image's own 48.5°:
    /// 1.0 → 2.61 px / 1.06 °/frame / 33.0°; 0.5 → 2.10 / 1.31 / 36.1; **0.3 → 1.85 / 1.48 / 35.8**;
    /// 0.2 → 1.79 / 1.56 / 38.6; 0.1 → 1.73 / 1.64 / 38.3. Most of the reprojection is bought by 0.3
    /// and the rest costs jitter; the opening is non-monotone across 0.5–0.3, so the last 3° is
    /// inside this measurement's own noise and not worth tuning to.
    public var depthSmoothnessScale: Double = 0.3

    public init(intrinsics: CameraIntrinsics) { self.intrinsics = intrinsics }
}

public struct BodySkeletonFitResult: Sendable {
    /// The input timeline with `joints3D` replaced by the fitted skeleton, so every existing
    /// `BodyKinematics` consumer works unchanged.
    public var timeline: BodyTimeline
    public var bones: [BodyBoneLength]
    public var metresPerPixelAtBody: BodyMeasure
    public var bodyDepthMetres: BodyMeasure
    public var standingHeightMetres: BodyMeasure
    public var scaleProvenance: String
    public var scaleIsMeasured: Bool
    /// RMS reprojection error of the fitted skeleton, pixels, over every observed joint.
    public var reprojectionRMSPixels: BodyMeasure
    /// The same number for Vision's own 3-D joints (its `pointInImage` against its own 2-D points).
    public var visionReprojectionRMSPixels: BodyMeasure
    public var framesFitted: Int
    /// Median 1σ on the mid-hip's **depth** (metres), from the fit's own information matrix scaled by
    /// the reprojection residual. Depth is the direction a single camera cannot see; this says by how
    /// much. Compare any depth-direction length against it before reporting that length.
    public var depthSigmaMetres: BodyMeasure
    /// The same 1σ in the image plane, for comparison — the direction the camera *can* see.
    public var lateralSigmaMetres: BodyMeasure
    /// Bone names whose length is a population prior rather than a fitted quantity.
    public var priorBones: [String]
    /// Bone names whose length was pooled with their mirror partner's (the symmetric-limb prior).
    public var symmetricBones: [String]
    /// One row per joint: seen fraction, jitter, clipping, and the far-side symmetry flag.
    public var jointCoverage: [BodyJointCoverage]
    /// Joints the fit solved for but never observed on any frame — carried by their bones alone.
    public var symmetryInferredJoints: [String]
    /// Non-nil when this view cannot see the shoulder/hip line's depth, which makes the yaw, the
    /// facing direction and everything measured against it unavailable. Pass it into
    /// `BodyKinematicsOptions.transverseYawUnavailableReason`.
    public var transverseYawUnavailableReason: String?
    public var sweepCosts: [Double]
    public var notes: [String]
    public var warnings: [String]
    /// RMS reprojection error per joint (pixels), so a whole-skeleton number can be read: which
    /// joints pay when a constraint is tightened.
    public var reprojectionRMSByJoint: [String: Double] = [:]
    /// Which way the shooter faces in the image, and on what evidence (iteration 5). Nil when the
    /// fit never had to ask — the torso breadth was observable, or the option is off.
    public var facing: BodyFacingCue? = nil
}

public enum BodySkeletonFit {

    /// The joints solved for. Every one of them exists in both the 2-D and the 3-D name spaces, so the
    /// output drops straight into `BodyFrame.joints3D`.
    public static let joints: [String] = [
        Body2DPoint.nose,
        Body2DPoint.leftShoulder, Body2DPoint.rightShoulder,
        Body2DPoint.leftElbow, Body2DPoint.rightElbow,
        Body2DPoint.leftWrist, Body2DPoint.rightWrist,
        Body2DPoint.leftHip, Body2DPoint.rightHip,
        Body2DPoint.leftKnee, Body2DPoint.rightKnee,
        Body2DPoint.leftAnkle, Body2DPoint.rightAnkle,
        Body2DPoint.neck,
    ]

    /// Bones that only exist when `BodySkeletonOptions.fitNeck` is on. Kept separate so the index of
    /// every older bone is unchanged when the neck is switched off.
    static let neckBoneNames: Set<String> = ["neckNose", "neckShoulderLeft", "neckShoulderRight"]

    /// Left/right pairs for the symmetric-limb prior. Each entry is one anatomical bone that a body
    /// has two of.
    static let mirroredBonePairs: [(String, String)] = [
        ("upperArmLeft", "upperArmRight"), ("forearmLeft", "forearmRight"),
        ("thighLeft", "thighRight"), ("shinLeft", "shinRight"),
        ("trunkLeft", "trunkRight"), ("headLeft", "headRight"),
        ("neckShoulderLeft", "neckShoulderRight"),
    ]

    /// The bones held constant over the shot. The two trunk diagonals are what stop the torso shearing
    /// in depth, which is the failure mode of a monocular fit with only the four trunk edges.
    public static let bones: [(name: String, a: String, b: String)] = [
        ("biacromial", Body2DPoint.leftShoulder, Body2DPoint.rightShoulder),
        ("biiliac", Body2DPoint.leftHip, Body2DPoint.rightHip),
        ("trunkLeft", Body2DPoint.leftShoulder, Body2DPoint.leftHip),
        ("trunkRight", Body2DPoint.rightShoulder, Body2DPoint.rightHip),
        ("trunkDiagonalLR", Body2DPoint.leftShoulder, Body2DPoint.rightHip),
        ("trunkDiagonalRL", Body2DPoint.rightShoulder, Body2DPoint.leftHip),
        ("upperArmLeft", Body2DPoint.leftShoulder, Body2DPoint.leftElbow),
        ("upperArmRight", Body2DPoint.rightShoulder, Body2DPoint.rightElbow),
        ("forearmLeft", Body2DPoint.leftElbow, Body2DPoint.leftWrist),
        ("forearmRight", Body2DPoint.rightElbow, Body2DPoint.rightWrist),
        ("thighLeft", Body2DPoint.leftHip, Body2DPoint.leftKnee),
        ("thighRight", Body2DPoint.rightHip, Body2DPoint.rightKnee),
        ("shinLeft", Body2DPoint.leftKnee, Body2DPoint.leftAnkle),
        ("shinRight", Body2DPoint.rightKnee, Body2DPoint.rightAnkle),
        ("headLeft", Body2DPoint.nose, Body2DPoint.leftShoulder),
        ("headRight", Body2DPoint.nose, Body2DPoint.rightShoulder),
        ("neckNose", Body2DPoint.neck, Body2DPoint.nose),
        ("neckShoulderLeft", Body2DPoint.neck, Body2DPoint.leftShoulder),
        ("neckShoulderRight", Body2DPoint.neck, Body2DPoint.rightShoulder),
    ]

    /// `bones` as index pairs into `joints`, resolved once. The solver's inner loops used to call
    /// `joints.firstIndex(of:)` — a linear scan comparing **strings** — 38 times per frame per sweep,
    /// and again in every cost evaluation and every covariance rebuild. Same lookup, same answer,
    /// done once. `-1` means the bone names a joint the fit does not solve for, which every caller
    /// skips exactly as the old `guard let` did.
    static let boneJointIndices: [(a: Int, b: Int)] = bones.map {
        (joints.firstIndex(of: $0.a) ?? -1, joints.firstIndex(of: $0.b) ?? -1)
    }

    /// `mirroredBonePairs` as index pairs into `bones`, for the same reason.
    static let mirroredBoneIndexPairs: [(Int, Int)] = mirroredBonePairs.compactMap { (ln, rn) in
        guard let li = bones.firstIndex(where: { $0.name == ln }),
              let ri = bones.firstIndex(where: { $0.name == rn }) else { return nil }
        return (li, ri)
    }

    /// The leftmost column that can be non-zero in each scalar row of one frame's 3J×3J information
    /// matrix. Reprojection, smoothness and the damping are block-diagonal in the joints; only a bone
    /// (and the Vision depth prior, which lives on the same bones) couples two joints, so this is the
    /// skeleton's own adjacency. Cholesky introduces no fill-in to the left of a row's first non-zero
    /// — the classic envelope/profile theorem — so the factoriser skips those columns. They are exact
    /// zeros, not small ones: the factor, and therefore every fitted position, is unchanged.
    static let envelopeFirstColumn: [Int] = {
        let J = joints.count
        var minAdjacent = Array(0..<J)
        for (a, b) in boneJointIndices where a >= 0 && b >= 0 {
            minAdjacent[a] = min(minAdjacent[a], b)
            minAdjacent[b] = min(minAdjacent[b], a)
        }
        var first = [Int](repeating: 0, count: 3 * J)
        for j in 0..<J { for c in 0..<3 { first[3 * j + c] = 3 * minAdjacent[j] } }
        return first
    }()

    // ---- scale ---------------------------------------------------------------------------------

    /// Metres per pixel at the shooter's depth, and the standing height that implies (or that was
    /// given). Pure, so the choice can be tested without a video.
    /// `ankleToNosePixels` is the window's 90th-percentile ankle-to-nose pixel span: the ankle *joint*
    /// does not move when the shooter rises on the toes, so the largest spans are the frames where the
    /// legs and trunk are straight — the standing pose the height fraction refers to.
    public static func metresPerPixel(scale: BodyScaleProvenance, ankleToNosePixels: Double?,
                                      options o: BodySkeletonOptions,
                                      spanRefusedReason: String? = nil) -> (mpp: BodyMeasure, height: BodyMeasure) {
        if let why = spanRefusedReason {
            // A stated height is still known — it was stated. What is lost is the pixel span that
            // turns it into metres per pixel, so that, and only that, is refused.
            if case .statedHeight(let h) = scale, h > 0.5, h < 2.5 { return (.missing(.metres, why), .ok(h, .metres)) }
            return (.missing(.metres, why), .missing(.metres, why))
        }
        switch scale {
        case .none:
            let why = "no scale provenance was supplied: a single camera cannot recover metres on its own"
            return (.missing(.metres, why), .missing(.metres, why))
        case .statedHeight(let h):
            guard h > 0.5, h < 2.5 else {
                let why = String(format: "the stated height %.3f m is not a plausible standing height", h)
                return (.missing(.metres, why), .missing(.metres, why))
            }
            guard let span = ankleToNosePixels, span > 1 else {
                let why = "no frame carried both an ankle and the nose, so the stated height has no pixel span to sit on"
                return (.missing(.metres, why), .ok(h, .metres))
            }
            return (.ok(h * o.ankleToNoseFractionOfHeight / span, .metres), .ok(h, .metres))
        case .rimRuler(let d, let px):
            guard d > 0, px > 1 else {
                let why = "the rim ruler needs a positive diameter and a major axis of more than one pixel"
                return (.missing(.metres, why), .missing(.metres, why))
            }
            let mpp = d / px
            guard let span = ankleToNosePixels, span > 1 else { return (.ok(mpp, .metres), .missing(.metres, "no ankle-to-nose pixel span in this window")) }
            // The ruler only transfers to the shooter if the shooter is at the ruler's depth. The
            // implied standing height is the test: an impossible one means they are not, and the whole
            // scale goes rather than a wrong metre being published.
            let implied = span * mpp / o.ankleToNoseFractionOfHeight
            guard implied >= o.plausibleHeightRange.lowerBound, implied <= o.plausibleHeightRange.upperBound else {
                let why = String(format: "the rim ruler makes the shooter %.2f m tall, outside %.2f–%.2f m: they are not at the rim's depth on this view, so the ruler does not transfer to them",
                                 implied, o.plausibleHeightRange.lowerBound, o.plausibleHeightRange.upperBound)
                return (.missing(.metres, why), .missing(.metres, why))
            }
            return (.ok(mpp, .metres), .ok(implied, .metres))
        case .metresPerPixel(let s, _):
            guard s > 0 else { return (.missing(.metres, "the supplied metres-per-pixel is not positive"), .missing(.metres, "the supplied metres-per-pixel is not positive")) }
            guard let span = ankleToNosePixels, span > 1 else { return (.ok(s, .metres), .missing(.metres, "no ankle-to-nose pixel span in this window")) }
            return (.ok(s, .metres), .ok(span * s / o.ankleToNoseFractionOfHeight, .metres))
        }
    }

    /// The eight limb bones, whose length takes the projection floor / stature prior and the stiffer weight.
    public static let limbBoneNames: Set<String> = ["upperArmLeft", "upperArmRight", "forearmLeft", "forearmRight",
                                             "thighLeft", "thighRight", "shinLeft", "shinRight"]

    /// Maximum of a centred running median (window `window`, odd) over a time-ordered series with
    /// gaps. Nil where nothing was observed.
    static func robustMaximum(_ xs: [Double?], window: Int) -> Double? {
        let h = max(0, window / 2)
        var best: Double? = nil
        for i in xs.indices where xs[i] != nil {
            let lo = max(0, i - h), hi = min(xs.count - 1, i + h)
            let w = xs[lo...hi].compactMap { $0 }
            guard !w.isEmpty else { continue }
            let m = Stats.median(w)
            if best == nil || m > best! { best = m }
        }
        return best
    }

    static func percentile(_ x: [Double], _ p: Double) -> Double? {
        guard !x.isEmpty else { return nil }
        let s = x.sorted()
        let i = min(s.count - 1, max(0, Int((p * Double(s.count - 1)).rounded())))
        return s[i]
    }

    // ---- the fit -------------------------------------------------------------------------------

    public static func fit(timeline: BodyTimeline, options o: BodySkeletonOptions) -> BodySkeletonFitResult {
        var notes: [String] = [], warnings: [String] = []
        let K = o.intrinsics
        let frames = timeline.frames.sorted { $0.realTime < $1.realTime }

        // Observations: one row per (frame, joint) that has a confident 2-D point.
        let J = joints.count
        let T = frames.count
        var obs = [SIMD2<Double>?](repeating: nil, count: T * J)
        var obsWeight = [Double](repeating: 0, count: T * J)
        for (t, f) in frames.enumerated() {
            for (j, name) in joints.enumerated() {
                if name == Body2DPoint.neck && !o.fitNeck { continue }
                guard let p = f.points2D[name], p.confidence >= o.minimumConfidence2D else { continue }
                obs[t * J + j] = p.uv
                // The detector's confidence is what it means: a 0.35 point pulls a third as hard as a
                // 1.0 one. Weights are √-ed into the normal equations, so this is a variance weight.
                obsWeight[t * J + j] = o.confidenceWeightedObservations ? max(0.05, p.confidence) : 1.0
            }
        }
        let observedJoints = (0..<J).filter { j in (0..<T).contains { obs[$0 * J + j] != nil } }
        guard T >= 3, observedJoints.count >= 8 else {
            let why = "the skeleton fit needs at least three frames and eight distinct 2-D joints; this window has \(T) frames and \(observedJoints.count) joints"
            return empty(timeline: timeline, why: why, scale: o.scale)
        }

        // Standing pixel span, for the scale.
        var spans: [Double] = []
        let ankleIndices = [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle].compactMap { joints.firstIndex(of: $0) }
        for t in 0..<T {
            guard let nose = obs[t * J + 0] else { continue }
            let ankles = ankleIndices.compactMap { obs[t * J + $0] }
            guard let lowest = ankles.map(\.y).max() else { continue }
            spans.append(lowest - nose.y)
        }
        // The feet sit at the bottom of the frame on a side view, and a clipped ankle is reported at
        // the frame border whatever the detector believes. A truncated shooter makes the span short
        // and the metres-per-pixel large, so the span is refused rather than silently shrunk.
        var ankleSeen = 0, ankleClipped = 0
        let bottom = Double(timeline.imageHeight) - o.edgeMarginPx
        for t in 0..<T {
            for j in ankleIndices {
                guard let a = obs[t * J + j] else { continue }
                ankleSeen += 1
                if a.y >= bottom || a.y <= o.edgeMarginPx || a.x <= o.edgeMarginPx
                    || a.x >= Double(timeline.imageWidth) - o.edgeMarginPx { ankleClipped += 1 }
            }
        }
        let ankleClipFraction = ankleSeen > 0 ? Double(ankleClipped) / Double(ankleSeen) : 0
        var spanRefused: String? = nil
        if ankleClipFraction > o.maximumAnkleClipFraction {
            spanRefused = String(format: "an ankle sat within %.0f px of a frame border on %.0f %% of the frames that carried one: the shooter's feet are cut off, so the ankle-to-nose span is not a span and the height scale does not follow from it",
                                 o.edgeMarginPx, 100 * ankleClipFraction)
            warnings.append(spanRefused!)
        }
        let span = spanRefused == nil ? percentile(spans, 0.90) : nil
        let (mppMeasure, heightMeasure) = metresPerPixel(scale: o.scale, ankleToNosePixels: span,
                                                         options: o, spanRefusedReason: spanRefused)
        // Numerics need *some* scale even when no metre may be reported; angles are scale-free, so an
        // internal working scale changes no angle. It is never surfaced as a length.
        let workingMPP: Double
        if let m = mppMeasure.value { workingMPP = m }
        else if let s = span, s > 1 { workingMPP = 1.80 * o.ankleToNoseFractionOfHeight / s }
        else { workingMPP = 1.0 / 200.0 }
        let Z0 = K.fx * workingMPP                    // depth at which one pixel spans `workingMPP` metres
        let pxPerMetre = 1.0 / workingMPP

        // Bone-length floors: a bone's longest projection over the shot. Geometrically a bone is at
        // least this long — projection can only shorten — so this is a floor, and it is tight for any
        // limb that passes through frontoparallel during the shot.
        var maxProjected = [Double](repeating: 0, count: bones.count)
        var boneFrames = [Int](repeating: 0, count: bones.count)
        for bi in bones.indices {
            let (ia, ib) = boneJointIndices[bi]
            guard ia >= 0, ib >= 0 else { continue }
            var lengths = [Double?](repeating: nil, count: T)
            for t in 0..<T {
                guard let pa = obs[t * J + ia], let pb = obs[t * J + ib] else { continue }
                lengths[t] = simd_length(pa - pb)
            }
            boneFrames[bi] = lengths.compactMap { $0 }.count
            maxProjected[bi] = robustMaximum(lengths, window: o.projectionFloorMedianFrames) ?? 0
        }
        var L = maxProjected.map { $0 * workingMPP }
        var boneSource = [String](repeating: "fitted median", count: bones.count)
        let limbBones = Set(bones.indices.filter { limbBoneNames.contains(bones[$0].name) })
        let boneWeights: [Double] = bones.indices.map { limbBones.contains($0) ? o.limbBoneWeight : o.boneWeight }
        // The same prior on the starting floors: the far limb's longest projection is a bad floor
        // because it is never seen frontoparallel, so a mirrored pair starts at the longer of the two.
        var symmetricBones: [String] = []
        if o.symmetricLimbPrior {
            for (ln, rn) in mirroredBonePairs {
                guard let li = bones.firstIndex(where: { $0.name == ln }),
                      let ri = bones.firstIndex(where: { $0.name == rn }), L[li] > 0, L[ri] > 0 else { continue }
                let shared = max(L[li], L[ri])
                L[li] = shared; L[ri] = shared
                symmetricBones.append(ln); symmetricBones.append(rn)
            }
            if !symmetricBones.isEmpty {
                notes.append("symmetric-limb prior: \(symmetricBones.count / 2) left/right bone pairs share one length. A prior, not a measurement — limbs are symmetric to a per cent or two, and on a side-on view the far limb is never seen frontoparallel, so its own longest projection would under-floor it.")
            }
        }
        // Limb bones (iteration 4): held at their projection floor for the whole fit — a measurement
        // and a lower bound — never refit to a per-frame median, which a bone free to shrink in
        // depth at no pixel cost biases short. With the prior on, the stature-scaled population
        // fraction fills in where the view never let the bone reach the image plane; whichever is
        // longer is the length, and the bone says which. The floor starts in pixels at the *hip*
        // depth and is re-expressed at the bone's own fitted depth once the sweeps have one (a
        // forearm 0.2 m nearer the camera than the hips projects 2–4 % longer than it is).
        var held = Set<Int>()
        var priorLength = [Double?](repeating: nil, count: bones.count)
        var limbFloor = [Double](repeating: 0, count: bones.count)       // metres, working units
        let statureWorking: Double? = (span.map { $0 > 1 ? $0 * workingMPP / o.ankleToNoseFractionOfHeight : nil } ?? nil)
        for bi in limbBones where L[bi] > 0 {
            held.insert(bi)
            limbFloor[bi] = L[bi]
            if o.limbLengthPriorFromStature, let H = statureWorking, let f = o.limbFractionsOfHeight[bones[bi].name] {
                priorLength[bi] = f * H
            }
        }
        /// Floor or prior, whichever is longer; a mirrored pair then shares the longer decision.
        func applyLimbLengths() {
            for bi in held {
                if let pr = priorLength[bi], pr > limbFloor[bi] {
                    L[bi] = pr
                    boneSource[bi] = String(format: "anthropometric prior (%.3f H)", o.limbFractionsOfHeight[bones[bi].name] ?? .nan)
                } else {
                    L[bi] = limbFloor[bi]
                    boneSource[bi] = "projection floor"
                }
            }
            guard o.symmetricLimbPrior else { return }
            for (ln, rn) in mirroredBonePairs {
                guard let li = bones.firstIndex(where: { $0.name == ln }), let ri = bones.firstIndex(where: { $0.name == rn }),
                      held.contains(li), held.contains(ri) else { continue }
                if L[li] >= L[ri] { L[ri] = L[li]; boneSource[ri] = boneSource[li] } else { L[li] = L[ri]; boneSource[li] = boneSource[ri] }
            }
        }
        applyLimbLengths()

        // Transverse breadths: pinned to the standing height when one is known (see the option's note).
        var priorBones: [String] = []
        var pinned = Set<Int>()
        if o.transverseBreadthFromHeight, let H = heightMeasure.value, H > 0.5, H < 2.5 {
            let hWorking = H * (mppMeasure.value.map { workingMPP / $0 } ?? 1)   // height in working units
            for (bi, b) in bones.enumerated() {
                let f: Double? = b.name == "biacromial" ? o.biacromialFractionOfHeight
                               : b.name == "biiliac" ? o.biiliacFractionOfHeight : nil
                guard let f else { continue }
                L[bi] = f * hWorking
                pinned.insert(bi)
                priorBones.append(b.name)
            }
            notes.append(String(format: "the biacromial (%.2f H) and biiliac (%.2f H) breadths are pinned to Winter's population fractions of the %.2f m standing height, because a near-side view leaves them unobservable; the shoulder-line and hip-line yaw are therefore prior-scaled, not measured",
                                o.biacromialFractionOfHeight, o.biiliacFractionOfHeight, H))
        }

        // Is the shoulder line ever near frontoparallel in this window? Its longest projection over the
        // shot, as a fraction of the ankle-to-nose span, answers it without needing any metre: an adult
        // biacromial breadth is ≈ 0.245 H and the span is 0.891 H, so a shoulder line that comes within
        // reach of the image plane must project to ≈ 0.275 of the span at some point in the shot.
        var transverseYawWhy: String? = nil
        if let bi = bones.firstIndex(where: { $0.name == "biacromial" }), let sp = span, sp > 1 {
            let expected = o.biacromialFractionOfHeight / o.ankleToNoseFractionOfHeight
            let seen = maxProjected[bi] / sp
            if seen < o.minimumBreadthProjectionFraction * expected {
                transverseYawWhy = String(format: "the shoulder line never projects to more than %.0f %% of the ankle-to-nose span in this window (an adult's is %.0f %% when it faces the camera): on this near-side view its depth — and therefore the shoulder yaw, the facing direction, the sagittal lean and the foot stagger measured against it — is not observable",
                                          100 * seen, 100 * expected)
            }
        }

        // ---- iteration 5: the torso's transverse axis, when the pixels cannot see it -------------
        // Only reached when the breadth has already been *proven* unobservable on this view; a view
        // that shows the shoulder line keeps measuring it. See `torsoBreadthWhenUnobservable`.
        var facingCue: BodyFacingCue? = nil
        var transverseDepthSign: Double? = nil
        if o.torsoBreadthWhenUnobservable, transverseYawWhy != nil, pinned.isEmpty {
            let floorPx = max(3.0, (span ?? 0) * o.facingOffsetFractionOfSpan)
            let cue = BodyFacing.fromImage(frames: frames, minimumConfidence2D: o.minimumConfidence2D,
                                           minimumOffsetPx: floorPx)
            facingCue = cue
            if let H = statureWorking, let sign = cue.imageSign {
                for (bi, b) in bones.enumerated() {
                    let f: Double? = b.name == "biacromial" ? o.biacromialFractionOfHeight
                                   : b.name == "biiliac" ? o.biiliacFractionOfHeight : nil
                    guard let f else { continue }
                    L[bi] = f * H
                    pinned.insert(bi)
                    priorBones.append(b.name)
                }
                transverseDepthSign = sign
                notes.append(String(format: "the shoulder and hip lines are unobservable on this view, so the torso is given a transverse axis: Winter's %.3f H / %.3f H breadths for its length (a prior) and the measured facing for its direction — %@. The shoulder-line yaw and everything measured against it stay refused.",
                                    o.biacromialFractionOfHeight, o.biiliacFractionOfHeight, cue.note))
            } else if cue.imageSign == nil {
                warnings.append("the torso's transverse axis is unobservable on this view and the facing cues cannot orient a prior one either — \(cue.unavailableReason ?? "no facing cue"). The fitted shoulders and hips are therefore as flat as the pixels leave them: treat the body's left/right depth as absent, not as measured.")
            } else {
                warnings.append("the torso's transverse axis is unobservable on this view and there is no ankle-to-nose span to scale a population breadth by, so the fitted shoulders and hips stay as flat as the pixels leave them.")
            }
        }

        // Initial positions: every joint on its own view ray, at the body depth, offset in depth by
        // Vision's *relative* z where there is one. Vision's placement is wrong but its front/back
        // ordering resolves the fold ambiguity (arm toward the camera vs away) that a flat start leaves open.
        var P = [SIMD3<Double>](repeating: .zero, count: T * J)
        let v2v3: [String: String] = [
            Body2DPoint.nose: Body3DJoint.centerHead,
            Body2DPoint.leftShoulder: Body3DJoint.leftShoulder, Body2DPoint.rightShoulder: Body3DJoint.rightShoulder,
            Body2DPoint.leftElbow: Body3DJoint.leftElbow, Body2DPoint.rightElbow: Body3DJoint.rightElbow,
            Body2DPoint.leftWrist: Body3DJoint.leftWrist, Body2DPoint.rightWrist: Body3DJoint.rightWrist,
            Body2DPoint.leftHip: Body3DJoint.leftHip, Body2DPoint.rightHip: Body3DJoint.rightHip,
            Body2DPoint.leftKnee: Body3DJoint.leftKnee, Body2DPoint.rightKnee: Body3DJoint.rightKnee,
            Body2DPoint.leftAnkle: Body3DJoint.leftAnkle, Body2DPoint.rightAnkle: Body3DJoint.rightAnkle,
            Body2DPoint.neck: Body3DJoint.centerShoulder,
        ]
        // The 3-D request can be run on only every Nth frame (it costs about half the tracker's time
        // and is used here for nothing but the front/back *sign*). Each frame therefore takes its
        // sign from the nearest frame that carries a 3-D body, within `depthSeedHoldSeconds`.
        var nearest3D = [Int?](repeating: nil, count: T)
        let has3D = (0..<T).filter { !frames[$0].joints3D.isEmpty }
        if !has3D.isEmpty {
            for t in 0..<T {
                var best: Int? = nil, bestDT = Double.infinity
                // `has3D` is ascending, so a binary search would do; the arrays here are hundreds long.
                for s in has3D {
                    let dt = abs(frames[s].realTime - frames[t].realTime)
                    if dt < bestDT { bestDT = dt; best = s }
                    if frames[s].realTime > frames[t].realTime && dt > bestDT { break }
                }
                if let best, bestDT <= o.depthSeedHoldSeconds { nearest3D[t] = best }
            }
        }
        // Half a breadth, signed by side, for the four joints the pinned bones actually hold — the two
        // shoulders and the two hips. The limbs are deliberately **not** seeded: they are held by
        // their own bones off a shoulder or a hip that is now on the correct side of the body, and
        // seeding them as well was measured to be worse, not better. Over the 107 phone shots,
        // seeding the elbows/wrists/knees/ankles too left the guide wrist 0.31 H behind the pelvis
        // and made the whole body 0.50 H thick (0.82 m for this shooter); seeding only the torso
        // gives 0.33 H, at 1.85 px of reprojection against 1.81. The thinner body is the true one.
        var transverseSeed: [String: Double] = [:]
        if transverseDepthSign != nil, let H = statureWorking {
            let halfShoulder = 0.5 * o.biacromialFractionOfHeight * H
            let halfHip = 0.5 * o.biiliacFractionOfHeight * H
            for (name, half) in [(Body2DPoint.leftShoulder, halfShoulder), (Body2DPoint.leftHip, halfHip)] {
                transverseSeed[name] = half
                transverseSeed[name.replacingOccurrences(of: "left", with: "right")] = -half
            }
        }
        var heldFrames = 0
        var seededFromVision = 0
        var lastKnown = [SIMD2<Double>?](repeating: nil, count: J)
        for (t, f) in frames.enumerated() {
            // Vision's depth is +z toward the camera; ours is +z away from it, hence the sign flip.
            let seedFrame = f.joints3D.isEmpty ? nearest3D[t].map { frames[$0] } : f
            if f.joints3D.isEmpty && seedFrame != nil { heldFrames += 1 }
            let root = seedFrame?.joints3D[Body3DJoint.root]?.cameraPosition
            var used = false
            for (j, name) in joints.enumerated() {
                let uv = obs[t * J + j] ?? lastKnown[j]
                guard let uv else { continue }
                lastKnown[j] = uv
                var dz = 0.0
                if let root, let v3 = v2v3[name], let jp = seedFrame?.joints3D[v3]?.cameraPosition {
                    dz = -(jp.z - root.z); used = true
                }
                // The shooter's **left** is the far side when they face image-right (forward × left =
                // up, with the pinhole frame's +z running away from the camera). Seeding it is what
                // picks one of the two folds the pinned breadth allows; the bone then holds it.
                if let s = transverseDepthSign { dz += s * transverseSeed[name, default: 0] }
                let z = max(0.2 * Z0, Z0 + dz)
                let n = K.normalize(uv)
                P[t * J + j] = SIMD3(n.x * z, n.y * z, z)
            }
            if used { seededFromVision += 1 }
        }
        if seededFromVision == 0 {
            notes.append("no Vision 3-D body in this window: the fit started flat (every joint at the body depth), so a limb pointing at the camera could fold either way")
        } else {
            notes.append("depth initialised from Vision's 3-D front/back ordering on \(seededFromVision)/\(T) frames (its placement is not used, only the sign of each joint's depth relative to the pelvis)")
            if heldFrames > 0 {
                notes.append(String(format: "%d of those frames took the sign from a neighbouring frame up to %.0f ms away, because the 3-D request was run on only some frames; a front/back ordering does not change inside that gap",
                                    heldFrames, 1000 * o.depthSeedHoldSeconds))
            }
        }

        // Vision's own 3-D **placement** as a weak prior, expressed as the depth difference it puts
        // across each bone: two joints per residual, which is the shape the solver's accumulator
        // already takes, and a difference rather than an absolute depth so Vision's (wrong) distance
        // from the camera never enters. Off unless `visionDepthPriorWeight` is set.
        var visionBoneDZ = [Double?](repeating: nil, count: T * bones.count)
        if o.visionDepthPriorWeight > 0 {
            for t in 0..<T {
                let f = frames[t]
                guard !f.joints3D.isEmpty else { continue }
                for (bi, b) in bones.enumerated() {
                    guard let na = v2v3[b.a], let nb = v2v3[b.b],
                          let pa = f.joints3D[na]?.cameraPosition, let pb = f.joints3D[nb]?.cameraPosition else { continue }
                    // Vision's +z runs toward the camera; the solver's runs away from it.
                    visionBoneDZ[t * bones.count + bi] = -(pa.z - pb.z)
                }
            }
        }

        // ---- block coordinate descent ------------------------------------------------------------
        var sweepCosts: [Double] = []
        let wSmooth = o.smoothnessWeight, wEnd = o.endpointWeight
        // One set of normal-equation buffers for the whole fit, reused by every frame of every sweep.
        let scratch = FrameNormalEquations(n: 3 * J, envelope: envelopeFirstColumn)
        // Per-bone fitted-length samples, reused across sweeps instead of rebuilt (19 arrays × 22
        // sweeps of allocation for a quantity that is overwritten every time).
        var fittedLengths = [[Double]](repeating: [], count: bones.count)
        for bi in bones.indices { fittedLengths[bi].reserveCapacity(T) }
        for sweep in 0..<o.sweeps {
            let order: [Int] = sweep % 2 == 0 ? Array(0..<T) : Array((0..<T).reversed())
            for t in order {
                solveFrame(&P, t: t, T: T, J: J, obs: obs, obsWeight: obsWeight, L: L,
                           K: K, pxPerMetre: pxPerMetre, boneWeights: boneWeights, wSmooth: wSmooth, wEnd: wEnd,
                           huber: o.huberPixels, lambda: o.levenberg,
                           depthSmoothnessScale: o.depthSmoothnessScale,
                           visionBoneDZ: visionBoneDZ, visionWeight: o.visionDepthPriorWeight,
                           scratch: scratch)
            }
            sweepCosts.append(cost(P, T: T, J: J, obs: obs, L: L, K: K, pxPerMetre: pxPerMetre,
                                   boneWeights: boneWeights, wSmooth: wSmooth, huber: o.huberPixels))
            // Re-estimate the one skeleton from the fit: the median fitted length, floored at the
            // longest projection (a fitted bone shorter than its own longest projection is impossible).
            if sweep + 1 >= o.boneRefitAfterSweep {
                // Held limb bones: the projection floor at the bone's own depth, not the hip's. At
                // the frame of the longest projection the bone is frontoparallel, so both ends sit
                // at the **proximal** joint's fitted depth (`bones[bi].a`: shoulder, elbow, hip,
                // knee). The proximal depth is what to use — a mean of both ends feeds the bone's
                // own fold back into its length and can run away when the fold points away from
                // the camera; the proximal joint's depth is bounded by the chain above it.
                //
                // **Once, on the first refit.** Re-expressing every sweep is a ratchet: a longer
                // bone pushes its proximal joint deeper, a deeper joint raises the floor, and the
                // two feed each other. Measured on the swinging-arm synthetic, the recovered
                // forearm drifted from +2 % of its true length at 10 sweeps to +3.8 % at 25. One
                // correction, taken when the depths are first worth trusting, is the measurement;
                // the rest was the loop talking to itself.
                for bi in held where sweep + 1 == o.boneRefitAfterSweep {
                    let (ia, ib) = boneJointIndices[bi]
                    guard ia >= 0, ib >= 0 else { continue }
                    var floors = [Double?](repeating: nil, count: T)
                    for t in 0..<T {
                        guard let pa = obs[t * J + ia], let pb = obs[t * J + ib] else { continue }
                        let zProximal = P[t * J + ia].z
                        guard zProximal > 1e-3 else { continue }
                        floors[t] = simd_length(pa - pb) * zProximal / K.fx
                    }
                    if let f = robustMaximum(floors, window: o.projectionFloorMedianFrames), f > 0 { limbFloor[bi] = f }
                }
                applyLimbLengths()
                for bi in bones.indices {
                    let (ia, ib) = boneJointIndices[bi]
                    fittedLengths[bi].removeAll(keepingCapacity: true)
                    guard ia >= 0, ib >= 0 else { continue }
                    for t in 0..<T where obs[t * J + ia] != nil && obs[t * J + ib] != nil {
                        fittedLengths[bi].append(simd_length(P[t * J + ia] - P[t * J + ib]))
                    }
                }
                // The symmetric-limb prior: a left and a right bone of the same limb are one length.
                // Pooling the two sides' samples means the far side, which is seen rarely and always
                // foreshortened, inherits the near side's well-observed length instead of its own
                // short projection floor.
                if o.symmetricLimbPrior {
                    for (li, ri) in mirroredBoneIndexPairs {
                        guard !pinned.contains(li), !pinned.contains(ri),
                              !held.contains(li), !held.contains(ri) else { continue }
                        let pool = fittedLengths[li] + fittedLengths[ri]
                        guard pool.count >= 5 else { continue }
                        let shared = max(Stats.median(pool), max(maxProjected[li], maxProjected[ri]) * workingMPP)
                        if L[li] > 0 { L[li] = shared }
                        if L[ri] > 0 { L[ri] = shared }
                        fittedLengths[li].removeAll(keepingCapacity: true)
                        fittedLengths[ri].removeAll(keepingCapacity: true)   // handled; not refit singly below
                    }
                }
                for bi in bones.indices {
                    guard fittedLengths[bi].count >= 5, !pinned.contains(bi), !held.contains(bi) else { continue }
                    L[bi] = max(Stats.median(fittedLengths[bi]), maxProjected[bi] * workingMPP)
                }
            }
        }

        // What the limb lengths are, now that the sources are final.
        do {
            let tookPrior = held.filter { boneSource[$0].hasPrefix("anthropometric") }.map { bones[$0].name }.sorted()
            let tookFloor = held.filter { !boneSource[$0].hasPrefix("anthropometric") }.map { bones[$0].name }.sorted()
            if !o.limbLengthPriorFromStature {
                notes.append("limb lengths: every limb bone is held at its own longest projection (the stature prior is off); a limb that never swings through the image plane is under-read")
            } else if statureWorking == nil {
                notes.append("no ankle-to-nose span in this window, so the limb bones are held at their longest projection only (no stature to scale a population fraction by)")
            } else if !tookPrior.isEmpty {
                notes.append("limb lengths: \(tookPrior.joined(separator: ", ")) never projected to Winter's fraction of this shooter's fitted stature, so they are held at that population length — a prior, not a measurement; \(tookFloor.joined(separator: ", ")) are held at their own longest projection")
            } else {
                notes.append("limb lengths: every limb bone is held at its own longest projection (all exceeded Winter's fraction of the fitted stature)")
            }
        }

        // ---- residuals and outputs ---------------------------------------------------------------
        var reproj: [Double] = []
        var reprojByJoint = [[Double]](repeating: [], count: J)
        for t in 0..<T {
            for j in 0..<J {
                guard let x = obs[t * J + j] else { continue }
                let p = P[t * J + j]
                guard p.z > 1e-6 else { continue }
                let u = K.fx * p.x / p.z + K.cx, v = K.fy * p.y / p.z + K.cy
                let e = simd_length(SIMD2(u, v) - x)
                reproj.append(e); reprojByJoint[j].append(e)
            }
        }
        var rmsByJoint: [String: Double] = [:]
        for (j, name) in joints.enumerated() where !reprojByJoint[j].isEmpty { rmsByJoint[name] = Stats.rms(reprojByJoint[j]) }
        if !rmsByJoint.isEmpty {
            notes.append("reprojection RMS by joint (px): " + rmsByJoint.sorted { $0.value > $1.value }
                .map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", "))
        }
        var visionReproj: [Double] = []
        for f in frames {
            for (n2, n3) in v2v3 {
                guard let j = f.joints3D[n3], let u = j.imageU, let v = j.imageV,
                      let p = f.points2D[n2], p.confidence >= o.minimumConfidence2D else { continue }
                visionReproj.append(simd_length(SIMD2(u, v) - p.uv))
            }
        }

        var boneOut: [BodyBoneLength] = []
        for (bi, b) in bones.enumerated() {
            let (ia, ib) = boneJointIndices[bi]
            guard ia >= 0, ib >= 0 else { continue }
            var dev: [Double] = []
            for t in 0..<T where obs[t * J + ia] != nil && obs[t * J + ib] != nil {
                dev.append(abs(simd_length(P[t * J + ia] - P[t * J + ib]) - L[bi]))
            }
            let toMetres = mppMeasure.value.map { $0 / workingMPP } ?? Double.nan
            boneOut.append(BodyBoneLength(name: b.name, a: b.a, b: b.b,
                                          metres: L[bi] * (toMetres.isFinite ? toMetres : 1),
                                          maximumProjectedPixels: maxProjected[bi],
                                          madMetres: (dev.isEmpty ? 0 : Stats.median(dev)) * (toMetres.isFinite ? toMetres : 1),
                                          frames: boneFrames[bi],
                                          source: pinned.contains(bi) ? "population breadth (pinned)" : boneSource[bi]))
        }

        // Write the fitted skeleton back as `joints3D`, in the convention the rest of the file uses:
        // camera space, +x right, +y **up**, +z toward the camera (Vision's). The solver works in the
        // pinhole convention (+y down, +z away), hence the two sign flips.
        let outScale = mppMeasure.value.map { $0 / workingMPP } ?? 1.0
        var outFrames: [BodyFrame] = []
        for (t, f) in frames.enumerated() {
            var js: [String: BodyJoint3D] = [:]
            var centreShoulder = SIMD3<Double>.zero, nShoulder = 0
            var root = SIMD3<Double>.zero, nHip = 0
            for (j, name) in joints.enumerated() {
                let p = P[t * J + j] * outScale
                guard p.z.isFinite, simd_length(p) > 0 else { continue }
                let cam = SIMD3(p.x, -p.y, -p.z)
                let uv = p.z > 1e-6 ? SIMD2(K.fx * (p.x / outScale) / (p.z / outScale) + K.cx,
                                            K.fy * (p.y / outScale) / (p.z / outScale) + K.cy) : SIMD2<Double>(.nan, .nan)
                let key = name == Body2DPoint.nose ? Body3DJoint.centerHead
                        : name == Body2DPoint.neck ? Body3DJoint.centerShoulder : name
                js[key] = BodyJoint3D(name: key, position: cam, cameraPosition: cam,
                                      imageU: uv.x.isFinite ? uv.x : nil, imageV: uv.y.isFinite ? uv.y : nil,
                                      confidence: obs[t * J + j] == nil ? nil : 1.0)
                if name == Body2DPoint.leftShoulder || name == Body2DPoint.rightShoulder { centreShoulder += cam; nShoulder += 1 }
                if name == Body2DPoint.leftHip || name == Body2DPoint.rightHip { root += cam; nHip += 1 }
            }
            // The fitted neck, when there is one, *is* the centre-shoulder joint and it was solved for
            // against its own observed 2-D point — so it is not replaced by the shoulders' midpoint.
            if nShoulder == 2, js[Body3DJoint.centerShoulder] == nil {
                let c = centreShoulder / 2
                js[Body3DJoint.centerShoulder] = BodyJoint3D(name: Body3DJoint.centerShoulder, position: c, cameraPosition: c, imageU: nil, imageV: nil, confidence: nil)
            }
            if nHip == 2 {
                let c = root / 2
                js[Body3DJoint.root] = BodyJoint3D(name: Body3DJoint.root, position: c, cameraPosition: c, imageU: nil, imageV: nil, confidence: nil)
                if nShoulder == 2 {
                    let spine = (c + centreShoulder / 2) / 2
                    js[Body3DJoint.spine] = BodyJoint3D(name: Body3DJoint.spine, position: spine, cameraPosition: spine, imageU: nil, imageV: nil, confidence: nil)
                }
            }
            // Model space is relative to the root, matching `BodyJoint3D.position`'s documented meaning.
            if let r = js[Body3DJoint.root]?.cameraPosition {
                for (k, v) in js { js[k] = BodyJoint3D(name: v.name, position: v.cameraPosition - r, cameraPosition: v.cameraPosition, imageU: v.imageU, imageV: v.imageV, confidence: v.confidence) }
            }
            var nf = f
            nf.joints3D = js
            nf.heightEstimationTechnique = o.scale.isMeasured ? "fittedSkeleton" : "fittedSkeletonUnscaled"
            nf.bodyHeightMetres = heightMeasure.value
            outFrames.append(nf)
        }
        var outTimeline = timeline
        outTimeline.frames = outFrames
        outTimeline.notes.append("3-D joints replaced by a per-shot skeleton fitted to the 2-D points (BodySkeletonFit)")

        if let why = transverseYawWhy { warnings.append(why) }
        if !o.scale.isMeasured {
            warnings.append("no scale provenance was supplied: the fitted skeleton's shape and every joint angle are still valid (angles are scale-free), but no length in it is a metre")
        }
        if let r = percentile(reproj, 0.5), r > 6 {
            warnings.append(String(format: "the fitted skeleton reprojects %.1f px from the 2-D points at the median: the constant-bone-length model does not explain these observations, so treat its depths as unresolved", r))
        }
        notes.append(String(format: "scale: %@", o.scale.note))
        if let m = mppMeasure.value {
            notes.append(String(format: "%.5f m/px at the body, i.e. the shooter is %.2f m from the camera at fx = %.0f px", m, K.fx * m, K.fx))
        }

        // How well is each direction actually determined? Rebuild one frame's information matrix
        // without damping, invert the mid-hip's 3×3 block and scale it by the reprojection variance.
        // Depth is the direction a single camera cannot see; this is the number that says by how much.
        var depthSigma: [Double] = [], lateralSigma: [Double] = []
        let residualVariance = reproj.isEmpty ? 1.0 : max(1.0, Stats.variance(reproj, ddof: 1))
        let metreScale = mppMeasure.value.map { $0 / workingMPP }
        for t in stride(from: 0, to: T, by: max(1, T / 40)) {
            guard let ia = joints.firstIndex(of: Body2DPoint.leftHip), let ib = joints.firstIndex(of: Body2DPoint.rightHip),
                  let cov = positionCovariance(P, t: t, T: T, J: J, obs: obs, obsWeight: obsWeight, L: L,
                                               K: K, pxPerMetre: pxPerMetre, boneWeights: boneWeights, wSmooth: wSmooth,
                                               wEnd: wEnd, huber: o.huberPixels, joint: ia, other: ib,
                                               scratch: scratch) else { continue }
            let s = (metreScale ?? 1) * residualVariance.squareRoot()
            depthSigma.append(cov.z.squareRoot() * s)
            lateralSigma.append(((cov.x + cov.y) / 2).squareRoot() * s)
        }
        let depthMeasure: BodyMeasure = depthSigma.isEmpty
            ? .missing(.metres, "the information matrix was singular on every sampled frame, so no uncertainty could be computed")
            : (metreScale == nil ? .missing(.metres, "without a scale provenance the depth uncertainty has no unit")
                                 : .ok(Stats.median(depthSigma), .metres))
        let lateralMeasure: BodyMeasure = lateralSigma.isEmpty || metreScale == nil
            ? .missing(.metres, depthMeasure.unavailableReason ?? "no uncertainty")
            : .ok(Stats.median(lateralSigma), .metres)
        if let d = depthMeasure.value, let l = lateralMeasure.value {
            notes.append(String(format: "mid-hip 1σ: %.3f m in depth against %.3f m in the image plane (%.0f× worse) — no depth-direction length below the first number is a measurement",
                                d, l, l > 0 ? d / l : .nan))
        }

        let coverage = BodyCoverage.perJoint(timeline: timeline, minimumConfidence: o.minimumConfidence2D,
                                             edgeMarginPx: o.edgeMarginPx)
        let inferred = coverage.filter { $0.symmetryInferred || ($0.framesSeen == 0 && joints.contains($0.name)) }
            .map(\.name).filter { joints.contains($0) }
        if !inferred.isEmpty {
            warnings.append("these joints were never observed often enough to be measured and are carried by their mirror partner's bone length: \(inferred.joined(separator: ", ")) — their positions are inferences, not measurements")
        }

        return BodySkeletonFitResult(
            timeline: outTimeline, bones: boneOut,
            metresPerPixelAtBody: mppMeasure,
            bodyDepthMetres: mppMeasure.value.map { .ok(K.fx * $0, .metres) } ?? .missing(.metres, mppMeasure.unavailableReason ?? "no scale"),
            standingHeightMetres: heightMeasure,
            scaleProvenance: o.scale.note, scaleIsMeasured: o.scale.isMeasured,
            reprojectionRMSPixels: reproj.isEmpty ? .missing(.pixels, "no joint was observed") : .ok(Stats.rms(reproj), .pixels),
            visionReprojectionRMSPixels: visionReproj.isEmpty ? .missing(.pixels, "no Vision 3-D joint carried an image point in this window") : .ok(Stats.rms(visionReproj), .pixels),
            framesFitted: T, depthSigmaMetres: depthMeasure, lateralSigmaMetres: lateralMeasure,
            priorBones: priorBones, symmetricBones: symmetricBones, jointCoverage: coverage,
            symmetryInferredJoints: inferred, transverseYawUnavailableReason: transverseYawWhy,
            sweepCosts: sweepCosts, notes: notes, warnings: warnings, reprojectionRMSByJoint: rmsByJoint,
            facing: facingCue)
    }

    static func empty(timeline: BodyTimeline, why: String, scale: BodyScaleProvenance) -> BodySkeletonFitResult {
        BodySkeletonFitResult(timeline: timeline, bones: [],
                              metresPerPixelAtBody: .missing(.metres, why), bodyDepthMetres: .missing(.metres, why),
                              standingHeightMetres: .missing(.metres, why), scaleProvenance: scale.note,
                              scaleIsMeasured: false,
                              reprojectionRMSPixels: .missing(.pixels, why), visionReprojectionRMSPixels: .missing(.pixels, why),
                              framesFitted: 0, depthSigmaMetres: .missing(.metres, why),
                              lateralSigmaMetres: .missing(.metres, why), priorBones: [],
                              symmetricBones: [], jointCoverage: [], symmetryInferredJoints: [],
                              transverseYawUnavailableReason: why,
                              sweepCosts: [], notes: [], warnings: [why])
    }

    // ---- one frame's Gauss-Newton step ---------------------------------------------------------

    static func huberWeight(_ r: Double, _ delta: Double) -> Double {
        let a = abs(r)
        return a <= delta ? 1.0 : delta / a
    }

    /// Scratch for one frame's normal equations, allocated **once per fit** rather than once per
    /// frame per sweep. Twenty-five sweeps over a few hundred frames used to allocate the Hessian,
    /// the gradient, a damped copy of the Hessian, a Cholesky factor and two solve vectors on every
    /// call — plus two small arrays for *every single residual*. That allocation traffic, not the
    /// arithmetic, was most of the fit's time. Nothing here changes a number: the same residuals are
    /// accumulated in the same order into the same matrix.
    final class FrameNormalEquations {
        let n: Int
        /// Lower triangle of Jᵀ J. The factoriser reads nothing above the diagonal, so nothing above
        /// it is written.
        let H: UnsafeMutablePointer<Double>
        let g: UnsafeMutablePointer<Double>
        /// Per-row diagonal boost (Levenberg), added inside the factoriser so the damping retry does
        /// not have to copy the matrix.
        let damp: UnsafeMutablePointer<Double>
        let factor: UnsafeMutablePointer<Double>
        let y: UnsafeMutablePointer<Double>
        let x: UnsafeMutablePointer<Double>
        let first: UnsafeMutablePointer<Int>

        init(n: Int, envelope: [Int]) {
            self.n = n
            H = .allocate(capacity: n * n); H.initialize(repeating: 0, count: n * n)
            factor = .allocate(capacity: n * n); factor.initialize(repeating: 0, count: n * n)
            g = .allocate(capacity: n); g.initialize(repeating: 0, count: n)
            damp = .allocate(capacity: n); damp.initialize(repeating: 0, count: n)
            y = .allocate(capacity: n); y.initialize(repeating: 0, count: n)
            x = .allocate(capacity: n); x.initialize(repeating: 0, count: n)
            first = .allocate(capacity: n); first.initialize(repeating: 0, count: n)
            // A wider envelope is always safe (it only costs work); a wrong narrow one would be a
            // silent error, so anything but the solver's own joint count falls back to "dense".
            if envelope.count == n { for i in 0..<n { first[i] = envelope[i] } }
        }
        deinit {
            H.deallocate(); factor.deallocate(); g.deallocate(); damp.deallocate()
            y.deallocate(); x.deallocate(); first.deallocate()
        }
    }

    /// One Levenberg-damped Gauss-Newton step on frame `t`'s 3·J unknowns, neighbours held fixed.
    /// The normal equations are accumulated directly (every residual touches at most two joints, so
    /// the 42×42 Hessian is built from 6×6 blocks) and solved by Cholesky: a dense QR on the same
    /// problem is ~1000× slower and buys nothing here, because the damping keeps it positive definite.
    static func solveFrame(_ P: inout [SIMD3<Double>], t: Int, T: Int, J: Int,
                           obs: [SIMD2<Double>?], obsWeight: [Double], L: [Double],
                           K: CameraIntrinsics, pxPerMetre: Double,
                           boneWeights: [Double], wSmooth: Double, wEnd: Double,
                           huber: Double, lambda: Double,
                           depthSmoothnessScale: Double = 1.0,
                           visionBoneDZ: [Double?] = [], visionWeight: Double = 0,
                           scratch: FrameNormalEquations) {
        let n = 3 * J
        let H = scratch.H, g = scratch.g
        H.update(repeating: 0, count: n * n)
        g.update(repeating: 0, count: n)

        /// One scalar residual `r` whose Jacobian is `ga` on joint `ja` alone.
        @inline(__always)
        func add1(_ r: Double, _ ja: Int, _ ga: SIMD3<Double>) {
            let i0 = 3 * ja
            g[i0] -= ga.x * r; g[i0 + 1] -= ga.y * r; g[i0 + 2] -= ga.z * r
            let r0 = i0 * n, r1 = r0 + n, r2 = r1 + n
            H[r0 + i0] += ga.x * ga.x
            H[r1 + i0] += ga.y * ga.x; H[r1 + i0 + 1] += ga.y * ga.y
            H[r2 + i0] += ga.z * ga.x; H[r2 + i0 + 1] += ga.z * ga.y; H[r2 + i0 + 2] += ga.z * ga.z
        }
        /// A residual on one single axis of one joint — the smoothness terms, whose Jacobian has one
        /// non-zero component. The old code wrote the other eight cells of the block as `+= 0`.
        @inline(__always)
        func addAxis(_ r: Double, _ ja: Int, _ c: Int, _ gc: Double) {
            let i = 3 * ja + c
            g[i] -= gc * r
            H[i * n + i] += gc * gc
        }
        /// A residual touching two joints. Only the lower triangle is filled, so the lower-numbered
        /// joint has to come first; the outer product is symmetric, so swapping changes nothing.
        @inline(__always)
        func add2(_ r: Double, _ ja: Int, _ ga: SIMD3<Double>, _ jb: Int, _ gb: SIMD3<Double>) {
            let flip = jb < ja
            let i0 = 3 * (flip ? jb : ja), i1 = 3 * (flip ? ja : jb)
            let va = flip ? gb : ga, vb = flip ? ga : gb
            g[i0] -= va.x * r; g[i0 + 1] -= va.y * r; g[i0 + 2] -= va.z * r
            g[i1] -= vb.x * r; g[i1 + 1] -= vb.y * r; g[i1 + 2] -= vb.z * r
            for p in 0..<3 {
                let row = (i0 + p) * n, vp = va[p]
                for q in 0...p { H[row + i0 + q] += vp * va[q] }
            }
            for p in 0..<3 {
                let row = (i1 + p) * n, vp = vb[p]
                for q in 0..<3 { H[row + i0 + q] += vp * va[q] }
                for q in 0...p { H[row + i1 + q] += vp * vb[q] }
            }
        }

        // 1. reprojection, pixels
        for j in 0..<J {
            guard let x = obs[t * J + j] else { continue }
            let p = P[t * J + j]
            guard p.z > 1e-3 else { continue }
            let iz = 1.0 / p.z
            let ru = K.fx * p.x * iz + K.cx - x.x, rv = K.fy * p.y * iz + K.cy - x.y
            let w = (obsWeight[t * J + j] * huberWeight(simd_length(SIMD2(ru, rv)), huber)).squareRoot()
            add1(ru * w, j, SIMD3(K.fx * iz, 0, -K.fx * p.x * iz * iz) * w)
            add1(rv * w, j, SIMD3(0, K.fy * iz, -K.fy * p.y * iz * iz) * w)
        }
        // 2. bone lengths (metres scaled into pixel-equivalents so the weights are commensurable)
        for bi in bones.indices {
            let (ia, ib) = boneJointIndices[bi]
            guard L[bi] > 0, ia >= 0, ib >= 0 else { continue }
            let d = P[t * J + ia] - P[t * J + ib]
            let len = simd_length(d)
            guard len > 1e-6 else { continue }
            let w = boneWeights[bi] * pxPerMetre
            let dir = d / len
            add2((len - L[bi]) * w, ia, dir * w, ib, -dir * w)
        }
        // 3. temporal smoothness: the second difference, or a first difference at the two ends.
        // `depthSmoothnessScale` lets the depth axis be smoothed differently from the two the camera
        // can see — in depth the smoothness is not competing with a measurement.
        let sInterior = SIMD3(wSmooth * pxPerMetre, wSmooth * pxPerMetre, wSmooth * pxPerMetre * depthSmoothnessScale)
        let sEnd = SIMD3(wEnd * pxPerMetre, wEnd * pxPerMetre, wEnd * pxPerMetre * depthSmoothnessScale)
        let has0 = t > 0, has2 = t + 1 < T
        if has0 && has2 {
            for j in 0..<J {
                let d = P[(t - 1) * J + j] - 2 * P[t * J + j] + P[(t + 1) * J + j]
                for c in 0..<3 { addAxis(d[c] * sInterior[c], j, c, -2 * sInterior[c]) }
            }
        } else if has0 || has2 {
            let off = has0 ? (t - 1) * J : (t + 1) * J
            for j in 0..<J {
                let d = P[t * J + j] - P[off + j]
                for c in 0..<3 { addAxis(d[c] * sEnd[c], j, c, sEnd[c]) }
            }
        }
        // 3b. Vision's 3-D placement, as a weak prior on each bone's depth difference.
        if visionWeight > 0 && !visionBoneDZ.isEmpty {
            for bi in bones.indices {
                let (ia, ib) = boneJointIndices[bi]
                guard let target = visionBoneDZ[t * bones.count + bi], ia >= 0, ib >= 0 else { continue }
                let w = visionWeight * pxPerMetre
                let r = (P[t * J + ia].z - P[t * J + ib].z - target) * w
                add2(r, ia, SIMD3(0, 0, w), ib, SIMD3(0, 0, -w))
            }
        }
        // 4. Levenberg damping — also what keeps an unobserved, unconstrained joint from drifting.
        // Standard Levenberg scaling (λ·diag H) plus a tiny absolute floor, so a joint that is
        // neither observed nor braced still leaves the matrix positive definite instead of drifting.
        let floor = 1e-6 * pxPerMetre * pxPerMetre
        let damp = scratch.damp
        var scale = 1.0
        for _ in 0..<6 {
            for k in 0..<n { damp[k] = lambda * scale * H[k * n + k] + floor }
            if choleskySolve(A: H, diagonalBoost: damp, b: g, n: n, first: scratch.first,
                             factor: scratch.factor, y: scratch.y, x: scratch.x) {
                let delta = scratch.x
                for j in 0..<J {
                    let step = SIMD3(delta[3 * j], delta[3 * j + 1], delta[3 * j + 2])
                    guard step.x.isFinite, step.y.isFinite, step.z.isFinite else { continue }
                    var p = P[t * J + j] + step
                    if p.z < 1e-3 { p.z = P[t * J + j].z }      // never push a joint behind the camera
                    P[t * J + j] = p
                }
                return
            }
            scale *= 16
        }
    }

    /// Diagonal of the marginal covariance of one joint's position on frame `t`, in working units²,
    /// from the undamped information matrix. `other` is folded in so the pelvis is treated as a unit.
    static func positionCovariance(_ P: [SIMD3<Double>], t: Int, T: Int, J: Int,
                                   obs: [SIMD2<Double>?], obsWeight: [Double], L: [Double],
                                   K: CameraIntrinsics, pxPerMetre: Double,
                                   boneWeights: [Double], wSmooth: Double, wEnd: Double, huber: Double,
                                   joint: Int, other: Int,
                                   scratch: FrameNormalEquations) -> SIMD3<Double>? {
        let n = 3 * J
        let H = scratch.H
        H.update(repeating: 0, count: n * n)
        @inline(__always)
        func add1(_ ja: Int, _ ga: SIMD3<Double>) {
            let i0 = 3 * ja
            let r0 = i0 * n, r1 = r0 + n, r2 = r1 + n
            H[r0 + i0] += ga.x * ga.x
            H[r1 + i0] += ga.y * ga.x; H[r1 + i0 + 1] += ga.y * ga.y
            H[r2 + i0] += ga.z * ga.x; H[r2 + i0 + 1] += ga.z * ga.y; H[r2 + i0 + 2] += ga.z * ga.z
        }
        @inline(__always)
        func add2(_ ja: Int, _ ga: SIMD3<Double>, _ jb: Int, _ gb: SIMD3<Double>) {
            let flip = jb < ja
            let i0 = 3 * (flip ? jb : ja), i1 = 3 * (flip ? ja : jb)
            let va = flip ? gb : ga, vb = flip ? ga : gb
            for p in 0..<3 {
                let row = (i0 + p) * n, vp = va[p]
                for q in 0...p { H[row + i0 + q] += vp * va[q] }
            }
            for p in 0..<3 {
                let row = (i1 + p) * n, vp = vb[p]
                for q in 0..<3 { H[row + i0 + q] += vp * va[q] }
                for q in 0...p { H[row + i1 + q] += vp * vb[q] }
            }
        }
        for j in 0..<J {
            guard obs[t * J + j] != nil else { continue }
            let p = P[t * J + j]
            guard p.z > 1e-3 else { continue }
            let iz = 1.0 / p.z
            let w = obsWeight[t * J + j].squareRoot()
            add1(j, SIMD3(K.fx * iz, 0, -K.fx * p.x * iz * iz) * w)
            add1(j, SIMD3(0, K.fy * iz, -K.fy * p.y * iz * iz) * w)
        }
        for bi in bones.indices {
            let (ia, ib) = boneJointIndices[bi]
            guard L[bi] > 0, ia >= 0, ib >= 0 else { continue }
            let d = P[t * J + ia] - P[t * J + ib]
            let len = simd_length(d)
            guard len > 1e-6 else { continue }
            let w = boneWeights[bi] * pxPerMetre
            add2(ia, d / len * w, ib, -d / len * w)
        }
        for j in 0..<J {
            let sm = (t > 0 && t + 1 < T) ? 2 * wSmooth * pxPerMetre : wEnd * pxPerMetre
            for c in 0..<3 { H[(3 * j + c) * n + 3 * j + c] += sm * sm }
        }
        // The undamped matrix, plus the same 1e-9 ridge the array version added to its diagonal.
        let damp = scratch.damp
        for k in 0..<n { damp[k] = 1e-9 }
        // One factorisation, three right-hand sides: the matrix does not change between the three
        // axes, and re-factorising it was three quarters of this function's cost.
        guard factorise(A: H, diagonalBoost: damp, n: n, first: scratch.first, factor: scratch.factor) else { return nil }
        var out = SIMD3<Double>.zero
        let e = scratch.g
        for c in 0..<3 {
            for k in 0..<n { e[k] = 0 }
            e[3 * joint + c] = 0.5; e[3 * other + c] = 0.5      // the mid-hip, not one hip
            guard substitute(b: e, n: n, first: scratch.first, factor: scratch.factor,
                             y: scratch.y, x: scratch.x) else { return nil }
            let x = scratch.x
            out[c] = 0.5 * x[3 * joint + c] + 0.5 * x[3 * other + c]
            if out[c] < 0 { return nil }
        }
        return out
    }

    /// Cholesky of the symmetric positive-definite matrix whose **lower triangle** is `A` (row-major,
    /// n×n) with `diagonalBoost[i]` added to A[i][i]. `first[i]` is row i's envelope start: Cholesky
    /// introduces no fill-in to the left of a row's first non-zero, so the columns below it are exact
    /// zeros and skipping them changes no bit of the factor. False when the matrix is not SPD — the
    /// same "not SPD" answer the old array version returned as nil, and the damping loop's signal to
    /// try a stiffer λ.
    @discardableResult
    static func factorise(A: UnsafePointer<Double>, diagonalBoost: UnsafePointer<Double>, n: Int,
                          first: UnsafePointer<Int>, factor Lm: UnsafeMutablePointer<Double>) -> Bool {
        for i in 0..<n {
            let fi = first[i], rowI = i * n
            var j = fi
            while j <= i {
                let fj = first[j], rowJ = j * n
                var s = A[rowI + j]
                if i == j { s += diagonalBoost[i] }
                var k = fi > fj ? fi : fj
                while k < j { s -= Lm[rowI + k] * Lm[rowJ + k]; k += 1 }
                if i == j {
                    guard s > 1e-300 else { return false }
                    Lm[rowI + i] = s.squareRoot()
                } else {
                    Lm[rowI + j] = s / Lm[rowJ + j]
                }
                j += 1
            }
        }
        return true
    }

    /// Forward and back substitution against a factor from `factorise`. False if the answer is not
    /// finite, which is the old version's `allSatisfy { $0.isFinite }` guard.
    static func substitute(b: UnsafePointer<Double>, n: Int, first: UnsafePointer<Int>,
                           factor Lm: UnsafePointer<Double>,
                           y: UnsafeMutablePointer<Double>, x: UnsafeMutablePointer<Double>) -> Bool {
        for i in 0..<n {
            let rowI = i * n
            var s = b[i]
            var k = first[i]
            while k < i { s -= Lm[rowI + k] * y[k]; k += 1 }
            y[i] = s / Lm[rowI + i]
        }
        var ok = true
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = y[i]
            var k = i + 1
            // `first[k] > i` means Lʼs (k, i) entry is outside the envelope: a structural zero, and
            // the buffer there still holds the previous frame's value, so it has to be skipped
            // rather than multiplied by.
            while k < n { if first[k] <= i { s -= Lm[k * n + i] * x[k] }; k += 1 }
            let v = s / Lm[i * n + i]
            x[i] = v
            if !v.isFinite { ok = false }
        }
        return ok
    }

    /// `factorise` + `substitute` in one call, for the damping loop.
    static func choleskySolve(A: UnsafePointer<Double>, diagonalBoost: UnsafePointer<Double>,
                              b: UnsafePointer<Double>, n: Int, first: UnsafePointer<Int>,
                              factor: UnsafeMutablePointer<Double>,
                              y: UnsafeMutablePointer<Double>, x: UnsafeMutablePointer<Double>) -> Bool {
        guard factorise(A: A, diagonalBoost: diagonalBoost, n: n, first: first, factor: factor) else { return false }
        return substitute(b: b, n: n, first: first, factor: factor, y: y, x: x)
    }

    /// Solve `A x = b` for a symmetric positive-definite `A` (row-major, n×n). Nil if not SPD.
    /// The array form, kept for anything that is not the per-frame hot path (it allocates).
    static func choleskySolve(_ A: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var Lm = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var s = A[i * n + j]
                for k in 0..<j { s -= Lm[i * n + k] * Lm[j * n + k] }
                if i == j {
                    guard s > 1e-300 else { return nil }
                    Lm[i * n + i] = s.squareRoot()
                } else {
                    Lm[i * n + j] = s / Lm[j * n + j]
                }
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = b[i]
            for k in 0..<i { s -= Lm[i * n + k] * y[k] }
            y[i] = s / Lm[i * n + i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = y[i]
            for k in (i + 1)..<n { s -= Lm[k * n + i] * x[k] }
            x[i] = s / Lm[i * n + i]
        }
        return x.allSatisfy { $0.isFinite } ? x : nil
    }

    static func cost(_ P: [SIMD3<Double>], T: Int, J: Int, obs: [SIMD2<Double>?], L: [Double],
                     K: CameraIntrinsics, pxPerMetre: Double, boneWeights: [Double], wSmooth: Double, huber: Double) -> Double {
        var c = 0.0
        for t in 0..<T {
            for j in 0..<J {
                guard let x = obs[t * J + j] else { continue }
                let p = P[t * J + j]
                guard p.z > 1e-6 else { continue }
                let d = simd_length(SIMD2(K.fx * p.x / p.z + K.cx, K.fy * p.y / p.z + K.cy) - x)
                c += d <= huber ? d * d : huber * (2 * d - huber)
            }
            for bi in bones.indices {
                let (ia, ib) = boneJointIndices[bi]
                guard L[bi] > 0, ia >= 0, ib >= 0,
                      obs[t * J + ia] != nil, obs[t * J + ib] != nil else { continue }
                let e = (simd_length(P[t * J + ia] - P[t * J + ib]) - L[bi]) * boneWeights[bi] * pxPerMetre
                c += e * e
            }
            if t > 0 && t + 1 < T {
                for j in 0..<J {
                    let d = (P[(t - 1) * J + j] - 2 * P[t * J + j] + P[(t + 1) * J + j]) * (wSmooth * pxPerMetre)
                    c += simd_length_squared(d)
                }
            }
        }
        return c
    }
}
