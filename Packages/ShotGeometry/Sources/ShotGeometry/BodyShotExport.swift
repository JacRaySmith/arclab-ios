import Foundation
import simd

// MARK: - BodyShot: the per-shot biometric record (docs/BIOMETRIC-SCHEMA.md v1)
//
// One `BodyShot` per analysed window, with every processed frame in it. It is the input to the future
// 3-D skeletal / mesh model, so the rules are the schema's: a value is measured or absent with a reason;
// nothing is filled in by symmetry or a prior without being flagged; every quantity says its unit and its
// frame of reference; the schema is versioned and additive.
//
// Field names follow `docs/BIOMETRIC-SCHEMA.md` §2–§3. Where the code has more to say than the schema
// (per-bone MAD, the fit's σ, the frame conventions), the extra fields are additive and never change the
// meaning of a schema field.

/// The schema version this file writes, and the versions it reads.
///
/// **v2 (1.3, 2026-09-16) is additive.** Everything v1 carried is still there, spelled the same way;
/// v2 adds the hand plates (`BodyShotFrame.handTriangles`, `BodyShot.hands`) and an optional
/// `provenance` string on a 2-D point. A v1 file decodes unchanged — the new keys are absent and
/// come back nil — and `BodyShotExportTests` holds that to a test.
public enum BodyShotSchema {
    public static let version = 2
    /// Every version this reader accepts, oldest first.
    public static let readableVersions = [1, 2]
}

/// `{ value, unit, sigma?, provenance } | { unavailableReason }` (schema §3). `value == nil` always
/// carries `unavailableReason`, as `BodyMeasure` does.
public struct BodyShotMeasure: Sendable, Codable, Equatable {
    public var value: Double?
    public var unit: String?
    public var sigma: Double?
    public var provenance: String?
    public var unavailableReason: String?

    public init(value: Double?, unit: String?, sigma: Double? = nil, provenance: String? = nil, unavailableReason: String? = nil) {
        precondition(value != nil || unavailableReason != nil, "a nil measurement must carry a reason")
        self.value = value; self.unit = unit; self.sigma = sigma; self.provenance = provenance; self.unavailableReason = unavailableReason
    }
    public init(_ m: BodyMeasure, provenance: String? = nil, sigma: Double? = nil) {
        self.init(value: m.value, unit: m.unit.rawValue, sigma: m.value == nil ? nil : sigma,
                  provenance: m.value == nil ? nil : provenance, unavailableReason: m.unavailableReason)
    }
    public static func missing(_ reason: String, unit: String? = nil) -> BodyShotMeasure {
        .init(value: nil, unit: unit, unavailableReason: reason)
    }
    public var isAvailable: Bool { value != nil }
}

public struct BodyShotPoint2D: Sendable, Codable, Equatable {
    public var u: Double, v: Double, confidence: Double
    /// v2, optional: how this point came to be here when it is not simply what the detector that owns
    /// the name returned — a wrist taken from the hand pose, a point carried across one sampled
    /// frame, a hand sided by proximity. Absent on every v1 file and on every ordinary point.
    public var provenance: String?
    public init(u: Double, v: Double, confidence: Double, provenance: String? = nil) {
        self.u = u; self.v = v; self.confidence = confidence; self.provenance = provenance
    }
}

/// One hand plate on one frame (schema v2 §2.1). Positions are in the body frame and in
/// `BodyShotSkeleton.unit`; directions are unit vectors in the same frame, rotated but not scaled.
public struct BodyShotHandTriangle: Sendable, Codable, Equatable {
    /// left | right — the shooter's own side.
    public var side: String
    /// shooting | guide | unknown
    public var role: String
    public var wrist: BodyShotFitted3D
    public var indexMCP: BodyShotFitted3D?
    public var littleMCP: BodyShotFitted3D?
    /// Out of the palm. Absent whenever fewer than three points were confident.
    public var palmNormal: [Double]?
    /// Wrist → the midpoint of the MCPs (→ the single MCP when only one was confident; `pointsUsed`
    /// says which).
    public var pointing: [Double]?
    /// Radians. Absent with a reason when the plate has no roll (fewer than three points, or the
    /// hand pointing along the reference axis).
    public var roll: BodyShotMeasure
    /// 3 = wrist and both knuckles; 2 = wrist and one knuckle, orientation only up to a roll.
    public var pointsUsed: Int
    public var wristProvenance: String
    /// Landmarks on this frame that were carried across one sampled frame rather than observed.
    public var interpolated: [String]
    /// Landmarks whose view ray missed the size prior's sphere and were taken at its surface.
    public var clamped: [String]
    public var reprojectionPixels: BodyShotMeasure
    /// ‖index − little‖ ÷ the prior's breadth − 1: how far the two rays and the prior disagree.
    public var breadthResidual: BodyShotMeasure
}

/// Raw Vision 3-D joint, camera frame: metres, x right, y down, z forward, origin at the lens (schema §4).
public struct BodyShotJoint3D: Sendable, Codable, Equatable {
    public var x: Double, y: Double, z: Double
    public var confidence: Double?
    public init(x: Double, y: Double, z: Double, confidence: Double? = nil) { self.x = x; self.y = y; self.z = z; self.confidence = confidence }
}

/// Skeleton-fit joint in the body frame (schema §4), in `BodyShotSkeleton.unit`.
public struct BodyShotFitted3D: Sendable, Codable, Equatable {
    public var x: Double, y: Double, z: Double
    public var sigma: Double?
    public init(x: Double, y: Double, z: Double, sigma: Double? = nil) { self.x = x; self.y = y; self.z = z; self.sigma = sigma }
}

/// One detected hand. Keyed as an array rather than `{left|right: …}` because Vision does not always
/// report chirality, and two hands of unknown side must not overwrite each other.
public struct BodyShotHand: Sendable, Codable, Equatable {
    /// "left" / "right" as the detector reported it, or nil when it did not say.
    public var chirality: String?
    /// shooting | guide | unknown
    public var role: String
    public var confidence: Double
    public var landmarks: [String: BodyShotPoint2D]
    public init(chirality: String?, role: String, confidence: Double, landmarks: [String: BodyShotPoint2D]) {
        self.chirality = chirality; self.role = role; self.confidence = confidence; self.landmarks = landmarks
    }
}

public struct BodyShotCrop: Sendable, Codable, Equatable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

/// Schema §2. Absent joints are absent keys, never zeros.
public struct BodyShotFrame: Sendable, Codable, Equatable {
    public var frameIndex: Int
    public var t_file: Double
    public var t_real: Double
    /// Image pixels, full frame, top-left origin.
    public var points2D: [String: BodyShotPoint2D]
    /// Raw Vision 3-D, camera frame (x right, y down, z forward).
    public var joints3D: [String: BodyShotJoint3D]
    /// Skeleton fit, body frame.
    public var fitted3D: [String: BodyShotFitted3D]
    public var hands: [BodyShotHand]
    /// v2: the fitted hand plates on this frame, one per hand that had one. Absent on a v1 file and
    /// on a frame where no hand had two confident triangle points.
    public var handTriangles: [BodyShotHandTriangle]?
    /// v2.1: the fitted foot triangles (heel · big toe · little toe on the fitted ankle), one per foot
    /// that had one. Absent on older files and on frames where no foot had two confident vertices.
    public var footTriangles: [BodyShotFootTriangle]?
    /// Observed on this frame (a 2-D point at or above the confidence floor) vs carried by the fit alone.
    public var seen: [String: Bool]
    public var crop: BodyShotCrop?

    public init(frameIndex: Int, t_file: Double, t_real: Double,
                points2D: [String: BodyShotPoint2D] = [:], joints3D: [String: BodyShotJoint3D] = [:],
                fitted3D: [String: BodyShotFitted3D] = [:], hands: [BodyShotHand] = [],
                handTriangles: [BodyShotHandTriangle]? = nil,
                footTriangles: [BodyShotFootTriangle]? = nil,
                seen: [String: Bool] = [:], crop: BodyShotCrop? = nil) {
        self.frameIndex = frameIndex; self.t_file = t_file; self.t_real = t_real
        self.points2D = points2D; self.joints3D = joints3D; self.fitted3D = fitted3D
        self.hands = hands; self.handTriangles = handTriangles; self.footTriangles = footTriangles
        self.seen = seen; self.crop = crop
    }
}

public struct BodyShotFormat: Sendable, Codable, Equatable {
    public var w: Int, h: Int
    /// Real frames per second of the capture (file fps × time scale).
    public var fps: Double
    public var hfovDegrees: Double
    /// sidecar | assumed | gravity-calibrated | unstated
    public var provenance: String
    public init(w: Int, h: Int, fps: Double, hfovDegrees: Double, provenance: String) {
        self.w = w; self.h = h; self.fps = fps; self.hfovDegrees = hfovDegrees; self.provenance = provenance
    }
}

public struct BodyShotSource: Sendable, Codable, Equatable {
    /// app | cli
    public var kind: String
    public var build: String?
    public var device: String?
    public var format: BodyShotFormat
    public init(kind: String, build: String?, device: String?, format: BodyShotFormat) {
        self.kind = kind; self.build = build; self.device = device; self.format = format
    }
}

public struct BodyShotTiming: Sendable, Codable, Equatable {
    public var releaseRealTime: Double
    public var set: BodyShotMeasure
    public var dip: BodyShotMeasure
    public var followThroughPeak: BodyShotMeasure
    /// One *sampled* frame of real time: `everyNthFrame / fps`. A lag at or below it is quantisation.
    public var quantisationFloor: Double
    public var everyNthFrame: Int
    public var phaseSignal: String
    public var notes: [String]
}

public struct BodyShotBone: Sendable, Codable, Equatable {
    public var a: String, b: String
    /// In `BodyShotSkeleton.unit`.
    public var length: Double
    public var mad: Double
    public var frames: Int
    /// A population prior rather than a fitted quantity.
    public var prior: Bool
    /// Pooled with its mirror partner (the symmetric-limb prior).
    public var symmetricPooled: Bool
    /// Where the length came from (`BodyBoneLength.source`): "projection floor", "anthropometric
    /// prior (0.186 H)", "fitted median", … Absent on files written before iteration 4.
    public var source: String?
}

public struct BodyShotSkeleton: Sendable, Codable, Equatable {
    public var boneLengths: [String: BodyShotBone]
    /// metres | unitHeight
    public var unit: String
    /// statedHeight | unitHeight
    public var scaleProvenance: String
    public var scaleNote: String
    public var symmetricPrior: Bool
    public var priorBones: [String]
    public var symmetricBones: [String]
    public var standingHeight: BodyShotMeasure
    /// Median 1σ on the mid-hip in the depth direction and in the image plane (metres of the fit's scale).
    public var depthSigma: BodyShotMeasure
    public var lateralSigma: BodyShotMeasure
    public var reprojectionRMSPixels: BodyShotMeasure
    public var joints: [String]
}

public struct BodyShotAngleSample: Sendable, Codable, Equatable {
    public var t_real: Double
    public var radians: Double
    public var sigma: Double?
}

public struct BodyShotAngleTrack: Sendable, Codable, Equatable {
    public var samples: [BodyShotAngleSample]
    public var unavailableReason: String?
    public init(samples: [BodyShotAngleSample], unavailableReason: String? = nil) {
        self.samples = samples; self.unavailableReason = samples.isEmpty ? (unavailableReason ?? "no frame carried this angle") : nil
    }
}

public struct BodyShotChainEvent: Sendable, Codable, Equatable {
    public var joint: String
    public var peakVelocityTime: Double
    /// radians per second of real time
    public var peakVelocity: Double
}

public struct BodyShotEvents: Sendable, Codable, Equatable {
    public var kineticChain: [BodyShotChainEvent]
    public var order: [String]
    public var lagsMs: [Double]
    public var lagFloorMs: Double
    public var proximalToDistal: Bool?
    public var unavailableReason: String?
    public var missing: [String: String]
}

public struct BodyShotSummary: Sendable, Codable, Equatable {
    public var jumpHeight: BodyShotMeasure
    public var dipDepth: BodyShotMeasure
    public var stanceWidth: BodyShotMeasure
    public var stanceStagger: BodyShotMeasure
    public var hipDrift: BodyShotMeasure
    public var headStability: BodyShotMeasure
    public var handRateAtRelease: BodyShotMeasure
}

/// v2 §3.2: the hand plates' declared size prior, what they measured at the release, and how much
/// of the window they covered. One block per shot; the per-frame plates are on the frames.
public struct BodyShotHands: Sendable, Codable, Equatable {
    /// The size prior, **declared as a prior**: the fractions of stature, the lengths they imply in
    /// `BodyShotSkeleton.unit`, and the sources. Nothing in the hand block is a measured length.
    public var sizePrior: BodyShotHandPrior
    public var shootingSide: String?
    /// Fraction of the window's analysed frames that carried a plate, per side.
    public var plateFraction: [String: Double]
    /// Fraction that carried all three points, i.e. a palm normal, per side.
    public var orientedFraction: [String: Double]
    public var palmToRimBearingAtRelease: BodyShotMeasure
    public var palmToVerticalAtRelease: BodyShotMeasure
    public var pointingToVerticalAtRelease: BodyShotMeasure
    public var rollAtRelease: BodyShotMeasure
    public var wristFlexionAtRelease: BodyShotMeasure
    public var wristFlexionChangeThroughRelease: BodyShotMeasure
    public var wristFlexionRangeThroughRelease: BodyShotMeasure
    public var wristFlexionFramesThroughRelease: Int
    public var guideContactPlaneToShotPlane: BodyShotMeasure
    public var guideContactPlaneToVertical: BodyShotMeasure
    public var guideLastContactRealTime: BodyShotMeasure
    public var notes: [String]
}

public struct BodyShotHandPrior: Sendable, Codable, Equatable {
    public var isPopulationPrior: Bool
    public var breadthFractionOfStature: Double
    public var palmLengthFractionOfStature: Double
    /// In `BodyShotSkeleton.unit`.
    public var breadth: Double
    public var palmLength: Double
    public var wristToMCP: Double
    public var stature: Double
    public var statureProvenance: String
    public var note: String
}

/// Schema §3.
public struct BodyShot: Sendable, Equatable {
    public var version: Int
    public var shotID: Int?
    public var source: BodyShotSource
    public var timing: BodyShotTiming
    public var frames: [BodyShotFrame]
    public var skeleton: BodyShotSkeleton
    public var angles: [String: BodyShotAngleTrack]
    public var events: BodyShotEvents
    public var summary: BodyShotSummary
    public var seenFractions: [String: Double]
    public var symmetryInferred: [String]
    public var warnings: [String]
    public var notes: [String]
    public var shootingSide: String?
    /// v2: the hand plates. Nil on a v1 file, and nil on a v2 file whose window never carried a hand.
    public var hands: BodyShotHands?
    /// The frames of reference, said in the file so a reader never has to guess.
    public var conventions: [String: String]

    public init(version: Int = BodyShotSchema.version, shotID: Int?, source: BodyShotSource, timing: BodyShotTiming,
                frames: [BodyShotFrame], skeleton: BodyShotSkeleton, angles: [String: BodyShotAngleTrack],
                events: BodyShotEvents, summary: BodyShotSummary, seenFractions: [String: Double],
                symmetryInferred: [String], warnings: [String], notes: [String], shootingSide: String?,
                hands: BodyShotHands? = nil, conventions: [String: String]) {
        self.version = version; self.shotID = shotID; self.source = source; self.timing = timing; self.frames = frames
        self.skeleton = skeleton; self.angles = angles; self.events = events; self.summary = summary
        self.seenFractions = seenFractions; self.symmetryInferred = symmetryInferred; self.warnings = warnings
        self.notes = notes; self.shootingSide = shootingSide; self.hands = hands; self.conventions = conventions
    }

    public static let angleTrackNames = ["elbowLeft", "elbowRight", "kneeLeft", "kneeRight",
                                         "shoulderElevationLeft", "shoulderElevationRight",
                                         "hipLeft", "hipRight", "ankleLeft", "ankleRight", "wristFlexion",
                                         "trunkLean", "neckFlexion", "headYaw", "headPitch"]
}

public enum BodyShotError: Error, CustomStringConvertible, Equatable {
    case unsupportedVersion(Int)
    public var description: String {
        switch self {
        case .unsupportedVersion(let v): return "BodyShot schema version \(v) is not supported (this reader knows version \(BodyShotSchema.version))"
        }
    }
}

extension BodyShot: Codable {
    enum CodingKeys: String, CodingKey {
        case version, shotID, source, timing, frames, skeleton, angles, events, summary
        case seenFractions, symmetryInferred, warnings, notes, shootingSide, hands, conventions
    }

    /// Refuses any version this reader does not know, before it reads anything else. v1 and v2 are
    /// both readable: v2 only *adds* keys, so a v1 file decodes with the new ones nil.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .version)
        guard BodyShotSchema.readableVersions.contains(v) else { throw BodyShotError.unsupportedVersion(v) }
        version = v
        shotID = try c.decodeIfPresent(Int.self, forKey: .shotID)
        source = try c.decode(BodyShotSource.self, forKey: .source)
        timing = try c.decode(BodyShotTiming.self, forKey: .timing)
        frames = try c.decode([BodyShotFrame].self, forKey: .frames)
        skeleton = try c.decode(BodyShotSkeleton.self, forKey: .skeleton)
        angles = try c.decode([String: BodyShotAngleTrack].self, forKey: .angles)
        events = try c.decode(BodyShotEvents.self, forKey: .events)
        summary = try c.decode(BodyShotSummary.self, forKey: .summary)
        seenFractions = try c.decode([String: Double].self, forKey: .seenFractions)
        symmetryInferred = try c.decode([String].self, forKey: .symmetryInferred)
        warnings = try c.decode([String].self, forKey: .warnings)
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        shootingSide = try c.decodeIfPresent(String.self, forKey: .shootingSide)
        hands = try c.decodeIfPresent(BodyShotHands.self, forKey: .hands)
        conventions = try c.decodeIfPresent([String: String].self, forKey: .conventions) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(shotID, forKey: .shotID)
        try c.encode(source, forKey: .source)
        try c.encode(timing, forKey: .timing)
        try c.encode(frames, forKey: .frames)
        try c.encode(skeleton, forKey: .skeleton)
        try c.encode(angles, forKey: .angles)
        try c.encode(events, forKey: .events)
        try c.encode(summary, forKey: .summary)
        try c.encode(seenFractions, forKey: .seenFractions)
        try c.encode(symmetryInferred, forKey: .symmetryInferred)
        try c.encode(warnings, forKey: .warnings)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(shootingSide, forKey: .shootingSide)
        try c.encodeIfPresent(hands, forKey: .hands)
        try c.encode(conventions, forKey: .conventions)
    }

    /// Compact JSON with sorted keys (stable diffs). Nothing is pretty-printed: a 200-frame shot with
    /// hands is about 1 MB this way and would be twice that indented.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> BodyShot {
        try JSONDecoder().decode(BodyShot.self, from: data)
    }
}

// MARK: - Building it from the model

public struct BodyShotOptions: Sendable {
    /// The 2-D confidence at or above which a joint counts as *seen* on a frame (`BodyKinematicsOptions.minimumConfidence2D`).
    public var minimumConfidence2D: Double = 0.3
    /// The floor an **appendage** point is counted as seen against (`HandTriangleOptions
    /// .minimumHandLandmarkConfidence`). Vision's hand landmarks come back far less confident than
    /// its body joints on a 40-pixel hand, so they get their own floor and the file says so.
    public var minimumHandLandmarkConfidence: Double = 0.20
    /// Real seconds either side of release the hand rate is measured over (the hand pass's own focus range).
    public var handFocusRealSeconds: Double = 0.4
    /// Decimals kept in the file. Pixels to 0.01 px, metres to 0.1 mm, unit-height to 1e-4, times to 10 µs.
    public var pixelDecimals: Int = 2
    public var lengthDecimals: Int = 4
    public var confidenceDecimals: Int = 3
    public var timeDecimals: Int = 5
    /// Ankle-to-nose as a fraction of standing height (`BodySkeletonOptions.ankleToNoseFractionOfHeight`).
    public var ankleToNoseFractionOfHeight: Double = 0.891
    public init() {}
}

extension BodyShot {

    /// Assemble the record. Pure: the tracker's raw timeline, the fit over it, the kinematic model over
    /// the fit, and the phase times the caller has already vetted (a dip the body model refused stays
    /// refused here — the record never re-admits a number upstream would not print).
    ///
    /// - Parameters:
    ///   - rawTimeline: what `BodyTracker` produced, before the fit replaced `joints3D`. Nil when the
    ///     caller no longer has it; `joints3D` is then empty on every frame and a note says why.
    ///   - fit: the skeleton fit; `fit.timeline` carries the fitted joints.
    ///   - model: `BodyKinematics.model` over `fit.timeline`.
    ///   - setRealTime / dipRealTime / followThroughPeakRealTime: real seconds, or the reason there is none.
    ///   - realFrameRate: real frames per second of the capture (file fps × time scale).
    ///   - rimImageU: the rim's image column, when known — orients the body frame's x toward the rim.
    public static func make(rawTimeline: BodyTimeline?, fit: BodySkeletonFitResult, model: BodyModel,
                            releaseRealTime: Double, setRealTime: BodyMeasure, dipRealTime: BodyMeasure,
                            followThroughPeakRealTime: BodyMeasure, realFrameRate: Double,
                            source: BodyShotSource, rimImageU: Double?, shotID: Int?,
                            handTriangles: HandTriangleResult? = nil,
                            footTriangles: FootTriangleResult? = nil,
                            options o: BodyShotOptions = .init()) -> BodyShot {
        let timeline = fit.timeline
        let frames = timeline.frames.sorted { $0.realTime < $1.realTime }
        let step = max(1, timeline.everyNthFrame)
        var notes: [String] = timeline.notes + fit.notes
        var warnings: [String] = model.warnings + fit.warnings
        func r(_ x: Double, _ d: Int) -> Double { let p = pow(10.0, Double(d)); return (x * p).rounded() / p }

        // ---- scale: metres with a stated height, else the shooter's own fitted standing height = 1 ----
        let measured = fit.scaleIsMeasured && fit.standingHeightMetres.value != nil
        let fittedStanding = ShotForm.fittedStandingHeight(frames: frames, ankleToNoseFraction: o.ankleToNoseFractionOfHeight)
        var unit = "metres", scaleProvenance = "statedHeight", divisor = 1.0
        var scaleNote = "metres, from " + fit.scaleProvenance
        var lengthsAvailable = true
        if !measured {
            unit = "unitHeight"; scaleProvenance = "unitHeight"
            if let h = fittedStanding, h > 0 {
                divisor = h
                scaleNote = "unit height: no standing height was stated, so every length is divided by the shooter's own fitted standing height (ankle-to-nose span ÷ \(o.ankleToNoseFractionOfHeight); the fit has no top-of-head joint). Lengths are ratios, not metres (\(fit.scaleProvenance))"
            } else {
                lengthsAvailable = false
                scaleNote = "no length unit: no standing height was stated and no frame carried both an ankle and the nose, so there is nothing to divide by; fitted positions are omitted"
                warnings.append("fitted 3-D positions omitted: " + scaleNote)
            }
        }
        func lengthMeasure(_ m: BodyMeasure, _ provenance: String) -> BodyShotMeasure {
            guard let v = m.value else { return BodyShotMeasure(m, provenance: provenance) }
            guard lengthsAvailable else { return .missing(scaleNote, unit: unit) }
            return BodyShotMeasure(value: r(v / divisor, o.lengthDecimals), unit: unit, provenance: provenance + (measured ? "" : "; ÷ fitted standing height"))
        }

        // ---- the body frame (schema §4): origin mid-hip at the set point, x toward the rim, z up ----
        // Camera space here is Vision's (+x right, +y up, +z toward the camera).
        let up = SIMD3<Double>(0, 1, 0)
        var forward = SIMD3<Double>(1, 0, 0)
        var facingNote: String
        if let rimImageU {
            let bodyU = ShotForm.meanMidHipColumn(frames: frames, minimumConfidence: o.minimumConfidence2D)
            let sign: Double = (bodyU.map { rimImageU >= $0 } ?? true) ? 1 : -1
            forward = SIMD3(sign, 0, 0)
            facingNote = "x along the camera's horizontal toward the rim's image column (rim \(sign > 0 ? "right" : "left") of the shooter); only the bearing is known, not the depth"
        } else {
            facingNote = "x is the camera's own right: nothing was supplied about where the rim is"
        }
        let zAxis = up, xAxis = simd_normalize(forward), yAxis = simd_cross(zAxis, xAxis)
        let originTime = setRealTime.value ?? frames.first?.realTime ?? releaseRealTime
        if setRealTime.value == nil, !frames.isEmpty {
            notes.append("no set point in this window: the body frame's origin is the mid-hip on the first fitted frame")
        }
        let origin = ShotForm.midHip(ShotForm.interpolate(frames: frames, at: originTime))
        if origin == nil, lengthsAvailable {
            warnings.append("fitted 3-D positions omitted: the mid-hip had no fitted position at the set point, so the body frame has no origin")
        }
        func toBody(_ p: SIMD3<Double>) -> SIMD3<Double>? {
            guard lengthsAvailable, let origin else { return nil }
            let d = (p - origin) / divisor
            return SIMD3(simd_dot(d, xAxis), simd_dot(d, yAxis), simd_dot(d, zAxis))
        }
        /// A **direction** into the body frame: rotated, never translated and never scaled, so a unit
        /// vector stays a unit vector and needs no length unit at all.
        func toBodyDirection(_ v: SIMD3<Double>) -> [Double] {
            [r(simd_dot(v, xAxis), 5), r(simd_dot(v, yAxis), 5), r(simd_dot(v, zAxis), 5)]
        }

        // ---- frames ------------------------------------------------------------------------------
        let rawByIndex: [Int: BodyFrame] = Dictionary((rawTimeline?.frames ?? []).map { ($0.frameIndex, $0) }, uniquingKeysWith: { a, _ in a })
        if rawTimeline == nil { notes.append("raw Vision 3-D joints are not in this record: the caller no longer had the tracker's timeline") }
        var out: [BodyShotFrame] = []
        out.reserveCapacity(frames.count)
        for f in frames {
            var pts: [String: BodyShotPoint2D] = [:]
            var seen: [String: Bool] = [:]
            for (name, p) in f.points2D {
                pts[name] = BodyShotPoint2D(u: r(p.u, o.pixelDecimals), v: r(p.v, o.pixelDecimals),
                                            confidence: r(p.confidence, o.confidenceDecimals), provenance: p.provenance)
                // The hand's landmarks are returned at confidences the body pose never sees (measured
                // p50 0.31 at the wrist, 0.50 at the MCPs), so an appendage point is "seen" against
                // the hand floor, not the body's. One rule per detector, each of them stated.
                let floor = Body2DPoint.appendages.contains(name) ? o.minimumHandLandmarkConfidence : o.minimumConfidence2D
                seen[name] = p.confidence >= floor
            }
            var raw: [String: BodyShotJoint3D] = [:]
            if let rf = rawByIndex[f.frameIndex] {
                for (name, j) in rf.joints3D {
                    // As stored by `BodyTracker`, Vision's `cameraRelativePosition` has +y up and the subject at
                    // positive z (measured: a wrist at release sits at y ≈ +1.6, z ≈ +4.7 m), so only y flips.
                    let c = j.cameraPosition
                    raw[name] = BodyShotJoint3D(x: r(c.x, o.lengthDecimals), y: r(-c.y, o.lengthDecimals), z: r(c.z, o.lengthDecimals),
                                                confidence: j.confidence.map { r($0, o.confidenceDecimals) })
                }
            }
            var fitted: [String: BodyShotFitted3D] = [:]
            for (name, j) in f.joints3D {
                guard let b = toBody(j.cameraPosition) else { continue }
                fitted[name] = BodyShotFitted3D(x: r(b.x, o.lengthDecimals), y: r(b.y, o.lengthDecimals), z: r(b.z, o.lengthDecimals))
                if seen[name] == nil { seen[name] = false }
            }
            let hands = f.hands.map { h in
                BodyShotHand(chirality: h.chirality, role: h.role ?? "unknown", confidence: r(h.confidence, o.confidenceDecimals),
                             landmarks: h.landmarks.mapValues { BodyShotPoint2D(u: r($0.u, o.pixelDecimals), v: r($0.v, o.pixelDecimals), confidence: r($0.confidence, o.confidenceDecimals)) })
            }
            // v2: the fitted plates. Positions go through the same body-frame map every fitted joint
            // does; directions are rotated only.
            var plates: [BodyShotHandTriangle] = []
            for track in handTriangles?.tracks ?? [] {
                guard let row = track.frames.first(where: { $0.frameIndex == f.frameIndex }) else { continue }
                guard let w = toBody(row.wrist) else { continue }
                func fitted(_ p: SIMD3<Double>?) -> BodyShotFitted3D? {
                    guard let p, let b = toBody(p) else { return nil }
                    return BodyShotFitted3D(x: r(b.x, o.lengthDecimals), y: r(b.y, o.lengthDecimals), z: r(b.z, o.lengthDecimals))
                }
                plates.append(BodyShotHandTriangle(
                    side: row.side, role: row.role ?? "unknown",
                    wrist: BodyShotFitted3D(x: r(w.x, o.lengthDecimals), y: r(w.y, o.lengthDecimals), z: r(w.z, o.lengthDecimals)),
                    indexMCP: fitted(row.indexMCP), littleMCP: fitted(row.littleMCP),
                    palmNormal: row.palmNormal.map(toBodyDirection), pointing: row.pointing.map(toBodyDirection),
                    roll: BodyShotMeasure(row.roll, provenance: "rotation of the palm normal about the hand's pointing axis, from the upward reference"),
                    pointsUsed: row.pointsUsed, wristProvenance: row.wristProvenance,
                    interpolated: row.interpolatedPoints, clamped: row.clampedPoints,
                    reprojectionPixels: BodyShotMeasure(row.reprojectionPixels, provenance: "the constructed knuckles against the hand-pose landmarks they were built from"),
                    breadthResidual: BodyShotMeasure(row.breadthResidual, provenance: "the two view rays' own separation against the size prior's breadth")))
            }
            // v2.1: the foot triangles, through the same body-frame map. A track's nearest fitted
            // frame within half a sampled step is this frame's; otherwise the foot is absent here.
            var feet: [BodyShotFootTriangle] = []
            let footTolerance = 0.5 * Double(step) / max(realFrameRate, 1)
            for track in footTriangles?.tracks ?? [] {
                guard var rec = BodyShotFootTriangle(track.nearest(f.realTime, within: footTolerance)) else { continue }
                func mapped(_ v: BodyShotFitted3D?) -> BodyShotFitted3D? {
                    guard let v, let b = toBody(SIMD3(v.x, v.y, v.z)) else { return nil }
                    return BodyShotFitted3D(x: r(b.x, o.lengthDecimals), y: r(b.y, o.lengthDecimals), z: r(b.z, o.lengthDecimals))
                }
                guard let ankle = mapped(rec.ankle) else { continue }
                rec.ankle = ankle
                rec.heel = mapped(rec.heel); rec.bigToe = mapped(rec.bigToe); rec.littleToe = mapped(rec.littleToe)
                rec.pointing = rec.pointing.map { toBodyDirection(SIMD3($0[0], $0[1], $0[2])) }
                rec.footUp = rec.footUp.map { toBodyDirection(SIMD3($0[0], $0[1], $0[2])) }
                feet.append(rec)
            }
            out.append(BodyShotFrame(frameIndex: f.frameIndex, t_file: r(f.fileTime, o.timeDecimals), t_real: r(f.realTime, o.timeDecimals),
                                     points2D: pts, joints3D: raw, fitted3D: fitted, hands: hands,
                                     handTriangles: plates.isEmpty ? nil : plates,
                                     footTriangles: feet.isEmpty ? nil : feet, seen: seen,
                                     crop: f.crop.map { BodyShotCrop(x: r($0.x, 1), y: r($0.y, 1), w: r($0.width, 1), h: r($0.height, 1)) }))
        }

        // ---- skeleton ----------------------------------------------------------------------------
        var bones: [String: BodyShotBone] = [:]
        if lengthsAvailable {
            let priors = Set(fit.priorBones), pooled = Set(fit.symmetricBones)
            for b in fit.bones {
                bones[b.name] = BodyShotBone(a: b.a, b: b.b, length: r(b.metres / divisor, o.lengthDecimals), mad: r(b.madMetres / divisor, o.lengthDecimals),
                                             frames: b.frames, prior: priors.contains(b.name), symmetricPooled: pooled.contains(b.name),
                                             source: b.source)
            }
        }
        let skeleton = BodyShotSkeleton(
            boneLengths: bones, unit: unit, scaleProvenance: scaleProvenance, scaleNote: scaleNote,
            symmetricPrior: !fit.symmetricBones.isEmpty, priorBones: fit.priorBones, symmetricBones: fit.symmetricBones,
            standingHeight: measured ? BodyShotMeasure(fit.standingHeightMetres, provenance: fit.scaleProvenance)
                                     : .missing("no standing height was stated; the fit's own value is a population prior", unit: "metres"),
            depthSigma: BodyShotMeasure(fit.depthSigmaMetres, provenance: "median 1σ of the mid-hip depth from the fit's information matrix, in the fit's metres"),
            lateralSigma: BodyShotMeasure(fit.lateralSigmaMetres, provenance: "median 1σ of the mid-hip in the image plane, in the fit's metres"),
            reprojectionRMSPixels: BodyShotMeasure(fit.reprojectionRMSPixels, provenance: "fitted skeleton against Vision's 2-D points"),
            joints: BodySkeletonFit.joints + (handTriangles == nil ? [] : Body3DJoint.handCorners))

        // ---- angle tracks ------------------------------------------------------------------------
        func track(_ pick: (JointAngles3D) -> BodyMeasure) -> BodyShotAngleTrack {
            var samples: [BodyShotAngleSample] = []
            var reasons: [String: Int] = [:]
            for a in model.angles {
                let m = pick(a)
                if let v = m.value { samples.append(BodyShotAngleSample(t_real: r(a.realTime, o.timeDecimals), radians: r(v, 5), sigma: nil)) }
                else if let why = m.unavailableReason { reasons[why, default: 0] += 1 }
            }
            let top = reasons.max { $0.value < $1.value }?.key
            return BodyShotAngleTrack(samples: samples, unavailableReason: top ?? (model.angles.isEmpty ? "no analysed frame carried a fitted skeleton" : nil))
        }
        let summaryOnly = "not a per-frame track in schema v1: the body model reports this quantity as a summary (PostureMetrics / HeadMetrics), see `notes`"
        var angles: [String: BodyShotAngleTrack] = [
            "elbowLeft": track { $0.leftElbow }, "elbowRight": track { $0.rightElbow },
            "kneeLeft": track { $0.leftKnee }, "kneeRight": track { $0.rightKnee },
            "shoulderElevationLeft": track { $0.leftShoulderElevation }, "shoulderElevationRight": track { $0.rightShoulderElevation },
            "hipLeft": track { $0.leftHip }, "hipRight": track { $0.rightHip },
            "ankleLeft": track { $0.leftAnkle }, "ankleRight": track { $0.rightAnkle },
            "wristFlexion": track { $0.shootingWristFlexion },
        ]
        for name in ["trunkLean", "neckFlexion", "headYaw", "headPitch"] { angles[name] = BodyShotAngleTrack(samples: [], unavailableReason: summaryOnly) }
        notes.append("trunk to vertical at release \(model.posture.trunkToVerticalAtRelease.describe("%.1f")), jitter \(model.posture.trunkToVerticalJitter.describe("%.1f")); head to trunk at release \(model.posture.headToTrunkAtRelease.describe("%.1f")); head yaw \(model.head.yaw.describe("%.1f")), head pitch (relative) \(model.head.pitchRelative.describe("%.1f"))")

        // ---- timing ------------------------------------------------------------------------------
        let floorSeconds = realFrameRate > 0 ? Double(step) / realFrameRate : .nan
        let timing = BodyShotTiming(
            releaseRealTime: r(releaseRealTime, o.timeDecimals),
            set: BodyShotMeasure(setRealTime, provenance: model.phases.signalSource),
            dip: BodyShotMeasure(dipRealTime, provenance: model.phases.signalSource),
            followThroughPeak: BodyShotMeasure(followThroughPeakRealTime, provenance: model.phases.signalSource),
            quantisationFloor: floorSeconds, everyNthFrame: step, phaseSignal: model.phases.signalSource, notes: model.phases.notes)

        // ---- events ------------------------------------------------------------------------------
        let events = BodyShotEvents(
            kineticChain: model.chain.events.map { BodyShotChainEvent(joint: $0.joint, peakVelocityTime: r($0.realTime, o.timeDecimals), peakVelocity: r($0.peakRateRadPerSecond, 4)) },
            order: model.chain.order, lagsMs: model.chain.lagsMilliseconds.map { r($0, 2) }, lagFloorMs: floorSeconds * 1000,
            proximalToDistal: model.chain.proximalToDistal, unavailableReason: model.chain.unavailableReason, missing: model.chain.missing)

        // ---- summary -----------------------------------------------------------------------------
        // Dip depth from the mid-hip's image row before release (the same rule as the app's result):
        // pixels first, then metres only with a stated height, else a fraction of the shooter's own
        // ankle-to-nose pixel span.
        var dipPx: Double? = nil
        var dipWhy = "the hips were never confident on both sides before the release in this window"
        let hipRows = frames.filter { $0.realTime <= releaseRealTime + 1e-9 }.compactMap { f -> (t: Double, v: Double)? in
            guard let l = f.points2D[Body2DPoint.leftHip], l.confidence >= o.minimumConfidence2D,
                  let rr = f.points2D[Body2DPoint.rightHip], rr.confidence >= o.minimumConfidence2D else { return nil }
            return (f.realTime, (l.v + rr.v) / 2)
        }
        if let low = hipRows.max(by: { $0.v < $1.v }), let top = hipRows.filter({ $0.t <= low.t }).map(\.v).min() {
            if low.v - top > 0 { dipPx = low.v - top } else { dipWhy = "the hips never came down before the release inside this window, so there is no drop to measure" }
        }
        let span = ankleToNosePixels(frames: frames, minimumConfidence: o.minimumConfidence2D)
        let dipDepth: BodyShotMeasure
        if let dipPx {
            if measured, let mpp = fit.metresPerPixelAtBody.value {
                dipDepth = BodyShotMeasure(value: r(dipPx * mpp, o.lengthDecimals), unit: "metres", provenance: "mid-hip image-row drop before release × metres per pixel at the body (\(fit.scaleProvenance))")
            } else if let span, span > 1 {
                dipDepth = BodyShotMeasure(value: r(dipPx / span, o.lengthDecimals), unit: "ankleToNoseSpans", provenance: "mid-hip image-row drop before release ÷ the shooter's 90th-percentile ankle-to-nose pixel span (no stated height, so no metres)")
            } else {
                dipDepth = .missing("no frame carried both the nose and an ankle, so there is no shooter pixel height to divide the \(Int(dipPx)) px hip drop by")
            }
        } else {
            dipDepth = .missing(dipWhy)
        }
        let lo = releaseRealTime - o.handFocusRealSeconds, hi = releaseRealTime + o.handFocusRealSeconds
        let inWindow = frames.filter { $0.realTime >= lo && $0.realTime <= hi }
        let handRate: BodyShotMeasure = inWindow.isEmpty
            ? .missing(String(format: "no analysed frame fell within ±%.1f s of release", o.handFocusRealSeconds))
            : BodyShotMeasure(value: r(Double(inWindow.filter { !$0.hands.isEmpty }.count) / Double(inWindow.count), 3), unit: "ratio",
                              provenance: String(format: "fraction of analysed frames within ±%.1f s of release carrying at least one hand", o.handFocusRealSeconds))
        let summary = BodyShotSummary(
            jumpHeight: measured ? BodyShotMeasure(model.stance.jumpHeight, provenance: "peak fitted mid-hip rise above its set/dip height")
                                 : .missing("no standing height was stated, so the fit's metres are a population prior and no metre is reported", unit: "metres"),
            dipDepth: dipDepth,
            stanceWidth: lengthMeasure(model.stance.feetSeparation, "horizontal distance between the fitted ankles"),
            stanceStagger: lengthMeasure(model.stance.feetStagger, "fitted ankle stagger along the facing direction, + = right foot in front"),
            hipDrift: lengthMeasure(model.stance.hipDriftMagnitude, "fitted mid-hip displacement dip→release"),
            headStability: BodyShotMeasure(model.head.stabilityPx, provenance: "RMS nose displacement about its mean, dip→release, image pixels"),
            handRateAtRelease: handRate)

        // ---- coverage ----------------------------------------------------------------------------
        var seenFractions: [String: Double] = [:]
        for c in fit.jointCoverage { seenFractions[c.name] = r(c.seenFraction, 3) }

        // ---- v2: the hand plates -------------------------------------------------------------
        var handsBlock: BodyShotHands? = nil
        if let ht = handTriangles, let prior = ht.tracks.first?.prior {
            let m = ht.measures
            func angle(_ x: BodyMeasure, _ provenance: String) -> BodyShotMeasure { BodyShotMeasure(x, provenance: provenance) }
            var plateFraction: [String: Double] = [:], orientedFraction: [String: Double] = [:]
            for t in ht.tracks {
                let n = Double(max(1, t.framesInWindow))
                plateFraction[t.side] = r(Double(t.frames.count) / n, 3)
                orientedFraction[t.side] = r(Double(t.framesWithOrientation) / n, 3)
            }
            handsBlock = BodyShotHands(
                sizePrior: BodyShotHandPrior(
                    isPopulationPrior: true,
                    breadthFractionOfStature: prior.breadthFractionOfStature,
                    palmLengthFractionOfStature: prior.palmLengthFractionOfStature,
                    breadth: r(prior.breadth / divisor, o.lengthDecimals),
                    palmLength: r(prior.palmLength / divisor, o.lengthDecimals),
                    wristToMCP: r(prior.wristToMCP / divisor, o.lengthDecimals),
                    stature: r(prior.stature / divisor, o.lengthDecimals),
                    statureProvenance: prior.statureProvenance, note: prior.note),
                shootingSide: model.shootingSide,
                plateFraction: plateFraction, orientedFraction: orientedFraction,
                palmToRimBearingAtRelease: angle(m.palmToRimBearingAtRelease, "angle between the shooting palm's normal and the rim's bearing (the camera's horizontal toward the rim's image column); a bearing, with no depth in it"),
                palmToVerticalAtRelease: angle(m.palmToVerticalAtRelease, "angle between the shooting palm's normal and camera-up"),
                pointingToVerticalAtRelease: angle(m.pointingToVerticalAtRelease, "angle between wrist → mid-MCP and camera-up"),
                rollAtRelease: angle(m.rollAtRelease, "rotation of the palm normal about the pointing axis from the upward reference"),
                wristFlexionAtRelease: angle(m.wristFlexionAtRelease, "fitted forearm (elbow → wrist) against the plate's pointing direction; + = flexion toward the palm"),
                wristFlexionChangeThroughRelease: angle(m.wristFlexionChangeThroughRelease, "last minus first flexion inside the release window"),
                wristFlexionRangeThroughRelease: angle(m.wristFlexionRangeThroughRelease, "max − min flexion inside the release window"),
                wristFlexionFramesThroughRelease: m.wristFlexionFramesThroughRelease,
                guideContactPlaneToShotPlane: angle(m.guideContactPlaneToShotPlane, "guide palm normal at the last frame a guide knuckle was within one ball radius of the ball centre, against the shot plane's normal"),
                guideContactPlaneToVertical: angle(m.guideContactPlaneToVertical, "the same frame's guide palm normal against camera-up"),
                guideLastContactRealTime: BodyShotMeasure(m.guideLastContactRealTime, provenance: "last frame a guide-hand knuckle was within one ball radius of the ball centre"),
                notes: m.notes + ht.notes)
            notes.append(contentsOf: ht.notes)
            warnings.append(contentsOf: ht.warnings)
        }

        let conventions = [
            "image": "pixels, full frame, top-left origin, u right, v down",
            "camera": "metres, x right, y down, z forward (subject at positive z), origin at the lens (raw Vision 3-D as stored by BodyTracker, with its +y up flipped to y down)",
            "body": "origin at the mid-hip at the set point; z up; " + facingNote + "; y = z × x (right-handed); unit: " + unit,
            "angles": "radians of real time; interior joint angles from the fitted skeleton",
            "time": "t_file = file clock; t_real = t_file ÷ timeScale (\(timeline.timeScale)); phases in real seconds",
            "handPlate": "wrist · index MCP · little MCP, a rigid triangle whose **size is a population prior** (see hands.sizePrior) attached at the fitted wrist; only its orientation is fitted, from the two knuckles' view rays. palmNormal points out of the palm; pointing runs wrist → mid-MCP; roll is the rotation of the normal about pointing from the upward reference. Positions in the body frame and in the skeleton's unit; directions are unit vectors, rotated only.",
        ]

        return BodyShot(shotID: shotID, source: source, timing: timing, frames: out, skeleton: skeleton, angles: angles,
                        events: events, summary: summary, seenFractions: seenFractions,
                        symmetryInferred: fit.symmetryInferredJoints, warnings: warnings, notes: notes,
                        shootingSide: model.shootingSide, hands: handsBlock, conventions: conventions)
    }

    /// The shooter's 90th-percentile ankle-to-nose span in pixels (the scale bar behind every normalised number).
    public static func ankleToNosePixels(frames: [BodyFrame], minimumConfidence: Double = 0.3) -> Double? {
        var spans: [Double] = []
        for f in frames {
            guard let nose = f.points2D[Body2DPoint.nose], nose.confidence >= minimumConfidence else { continue }
            let ankles = [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle].compactMap { f.points2D[$0] }.filter { $0.confidence >= minimumConfidence }
            guard let a = ankles.max(by: { $0.v < $1.v }) else { continue }
            spans.append(simd_length(SIMD2(a.u, a.v) - SIMD2(nose.u, nose.v)))
        }
        guard spans.count >= 5 else { return nil }
        let sorted = spans.sorted()
        return sorted[min(sorted.count - 1, Int((0.9 * Double(sorted.count - 1)).rounded()))]
    }

    /// The dip the app's result prints: `BodyKinematics.phases` marks a dip that sat on the edge of the
    /// lookback in its notes, and that dip is the window's length, not a measurement — refused here so
    /// the record and the result agree.
    public static func vettedDip(_ ph: ShotPhases) -> BodyMeasure {
        let edgeNote = ph.notes.first { $0.hasPrefix("the dip is the first frame of the lookback") || $0.hasPrefix("the hand only rose inside the lookback") }
        return edgeNote.map { .missing(.seconds, $0) } ?? ph.dip
    }
}
