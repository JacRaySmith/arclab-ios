import Foundation
import simd

// MARK: - Frames

/// Turning the phone's measured gravity into the "up" direction `RimCalibrationOptions.knownUp`
/// wants — and nothing else. Pure arithmetic on three named frames; no CoreMotion here (this module
/// depends on Foundation and simd alone, CLAUDE.md rule 2). The app measures, this converts.
///
/// Three frames, named once and used with these names everywhere below:
///
/// * **device** — CoreMotion's frame, where `CMDeviceMotion.gravity` lives. With the phone held
///   upright in portrait: `+x` out of the right edge of the screen, `+y` out of the top edge,
///   `+z` out of the screen towards the viewer. Gravity points *down*, so an upright phone
///   measures `(0, −1, 0)`.
///
/// * **sensor** — the rear camera's native buffer, the frame AVFoundation hands over when a
///   capture connection's `videoRotationAngle` is 0. Axis convention is ShotGeometry's camera
///   frame: `+x` is image right, `+y` is image **down**, `+z` is the optical axis, out of the
///   *back* of the phone. In device coordinates:
///
///       x_sensor = (0, −1, 0)      y_sensor = (−1, 0, 0)      z_sensor = (0, 0, −1)
///
///   Two independent checks that this is the right mapping, because it is the part that is easy to
///   get silently wrong:
///     1. It is right-handed with `z` forward: `x_sensor × y_sensor = (0, 0, −1) = z_sensor`.
///     2. It reproduces the preferred transform every iPhone portrait video carries. In portrait
///        the stored buffer is landscape and the track's transform is `(a: 0, b: 1, c: −1, d: 0)`.
///        Under the mapping above, buffer `+u` runs along device `−y` (screen down) and buffer
///        `+v` along device `−x` (screen left), which is exactly the point mapping that matrix
///        performs. A sign error anywhere in the three axes breaks that agreement.
///   Said the other way round: the native buffer is already the right way up when the phone lies
///   landscape with its bottom edge to the right — the rear camera's native orientation, the one
///   the old API called `.landscapeRight` — and that is precisely the pose in which the device's
///   `+x` axis points at the sky.
///
/// * **image** — the frame the rim trace and the ball detections are in: the **stored** pixels of
///   the movie file, because the reader decodes samples and never applies the track's
///   `preferredTransform` (it says so in its own notes). Same axis convention as *sensor*; it
///   differs from *sensor* only by a rotation about the optical axis.
public enum CameraGravity {
    /// Rotation from *sensor* to *image*, in the same convention a video track's preferred
    /// transform uses: the angle `atan2(b, a)` of the matrix that takes stored pixel coordinates to
    /// displayed ones. An iPhone portrait video's transform is `(0, 1, −1, 0)`, i.e. 90°.
    ///
    /// The caller works it out by subtraction and never by assumption: the capture connection was
    /// told to rotate by `θ_connection`, the finished file's transform rotates by `θ_transform`, so
    /// whatever the movie writer chose to do — rotate the pixels, or leave them native and write
    /// the rotation into the track — the stored pixels sit at `θ_connection − θ_transform` from the
    /// sensor. Both terms are measured.
    ///
    /// - Parameters:
    ///   - gravityDevice: `CMDeviceMotion.gravity` as measured, in the **device** frame. Points down.
    ///   - sensorToImageDegrees: the rotation above.
    /// - Returns: unit "up" (away from the floor) in the **image** frame — what
    ///   `RimCalibrationOptions.knownUp` expects — or `nil` if the vector has no length to speak of.
    public static func imageUp(fromDeviceGravity gravityDevice: SIMD3<Double>,
                               sensorToImageDegrees: Double) -> SIMD3<Double>? {
        let length = norm(gravityDevice)
        guard length > 1e-6 else { return nil }
        let g = gravityDevice / length

        // device → sensor: components along x_sensor, y_sensor, z_sensor as written above.
        let gSensor = SIMD3(-g.y, -g.x, -g.z)

        // sensor → image. The transform takes sensor pixel coordinates to image pixel coordinates
        // through R(θ) = [[cosθ, −sinθ], [sinθ, cosθ]] acting on (u, v), so a direction's components
        // transform by the same matrix. The optical axis is the rotation axis and is untouched.
        let t = Angle.radians(sensorToImageDegrees)
        let c = cos(t), s = sin(t)
        let gImage = SIMD3(c * gSensor.x - s * gSensor.y,
                           s * gSensor.x + c * gSensor.y,
                           gSensor.z)
        return -gImage          // "up" is away from the floor; gravity points at it
    }

    /// The inverse of `imageUp(fromDeviceGravity:sensorToImageDegrees:)`, so the round trip can be
    /// tested rather than argued about. Returns a unit gravity vector in the **device** frame.
    public static func deviceGravity(fromImageUp up: SIMD3<Double>,
                                     sensorToImageDegrees: Double) -> SIMD3<Double>? {
        let length = norm(up)
        guard length > 1e-6 else { return nil }
        let gImage = -(up / length)

        let t = Angle.radians(sensorToImageDegrees)
        let c = cos(t), s = sin(t)
        let gSensor = SIMD3(c * gImage.x + s * gImage.y,
                            -s * gImage.x + c * gImage.y,
                            gImage.z)
        return SIMD3(-gSensor.y, -gSensor.x, -gSensor.z)
    }

    /// Camera pitch relative to gravity (positive = looking up), radians, from an up direction in
    /// the camera frame. Same definition as `RimCalibration.pitch`, applied to a vector the
    /// calibration did not produce.
    @inlinable public static func pitch(ofUp up: SIMD3<Double>) -> Double {
        asin(max(-1, min(1, unit(up).z)))
    }

    /// Camera roll relative to gravity, radians (0 = level). Same definition as `RimCalibration.roll`.
    @inlinable public static func roll(ofUp up: SIMD3<Double>) -> Double {
        let u = unit(up)
        return atan2(-u.x, -u.y)
    }
}

// MARK: - Does the trace agree with gravity?

/// What a rim trace and a measured gravity direction say about each other. Every field that cannot
/// be computed is `nil` next to the reason it could not be (CLAUDE.md rule 1) — there is no
/// stand-in zero anywhere in here, because a zero disagreement is the one answer that would be read
/// as "all is well".
public struct RimUpAgreement: Sendable {
    /// Up as the traced ellipse's own plane normal implies it, camera frame — the direction the
    /// unconstrained conic solve uses. `nil` when the trace does not solve on its own.
    public var tracedUp: SIMD3<Double>?
    /// Why `tracedUp` is nil.
    public var tracedUnavailableReason: String?
    /// Up as the phone measured it while the clip was filmed, camera frame.
    public var measuredUp: SIMD3<Double>?
    /// Why `measuredUp` is nil — no motion data, permission refused, a clip that came from Photos.
    public var measuredUnavailableReason: String?
    /// Angle between the two, **radians**. `nil` whenever either side is nil.
    public var disagreement: Double?

    public var tracedPitch: Double? { tracedUp.map(CameraGravity.pitch(ofUp:)) }
    public var tracedRoll: Double? { tracedUp.map(CameraGravity.roll(ofUp:)) }
    public var measuredPitch: Double? { measuredUp.map(CameraGravity.pitch(ofUp:)) }
    public var measuredRoll: Double? { measuredUp.map(CameraGravity.roll(ofUp:)) }

    /// True when both directions exist and they are further apart than `RimUpAgreement.tolerance`.
    public var disagrees: Bool {
        guard let disagreement else { return false }
        return disagreement > RimUpAgreement.tolerance
    }

    /// Past this the trace and the phone are told to disagree, **radians**.
    ///
    /// Where it comes from: the release height is read along the calibration's `up`, so an error ε
    /// costs about `L · sin ε` — at a three-point release (`L ≈ 6.45 m` from the rim) 5° is 0.56 m,
    /// which is a fifth of the height of a real release and enough on its own to push a shot out of
    /// the 1.6–3.3 m acceptance band. Below it the cost is inside the noise of the trace itself.
    /// A convention with arithmetic behind it, not a measured threshold: no study fixed 5°.
    public static let tolerance = Angle.radians(5)

    /// Distance from the rim to a three-point release, metres — the lever arm the disagreement is
    /// quoted at so a shooter hears a distance and not an angle. The 6.75 m arc puts the ball at
    /// about this (docs/research/three-point-acceptance-2026-09-24.md §1).
    public static let threePointReleaseDistance = 6.45
    /// The same lever arm at the free-throw line, metres: the 4.57 m line, less a stride of release.
    public static let freeThrowReleaseDistance = 4.19

    /// How far out the release height would be at `distance` metres from the rim, metres.
    /// `nil` when there is no disagreement to convert.
    public func heightErrorMetres(atDistance distance: Double) -> Double? {
        disagreement.map { abs(distance * sin($0)) }
    }
}

public enum RimGravity {
    /// A camera roll past this is treated as implausible for a phone on a tripod, **radians**.
    ///
    /// **This is a convention, not a finding.** Nobody measured how far real phone tripods lean;
    /// the number is chosen because a tripod head that looks level to the eye is within a few
    /// degrees, and because the 2026-09-13 clips from one tripod gave 3.0° and 3.4° by hand and by
    /// the automatic finder while the one contaminated trace gave 18.0°. It is a reason to look at
    /// the trace again, never evidence on its own that the trace is wrong — a phone really can be
    /// clamped over at 20°, and then this warning is simply wrong.
    public static let implausibleTripodRoll = Angle.radians(10)

    /// Compare a rim trace with a measured up direction.
    ///
    /// `measuredUp` is in the camera frame (`CameraGravity.imageUp(fromDeviceGravity:…)` puts it
    /// there). The traced direction always comes from the **unconstrained** solve, so this answers
    /// the same question whether or not the calibration it accompanies was solved with `knownUp`.
    public static func compare(boundaryPoints: [SIMD2<Double>],
                               intrinsics: CameraIntrinsics,
                               measuredUp: SIMD3<Double>?,
                               measuredUnavailableReason: String? = nil,
                               rimDiameter: Double = Court.rimInnerDiameter,
                               cameraBelowRim: Bool = true) -> RimUpAgreement {
        var options = RimCalibrationOptions()
        options.rimDiameter = rimDiameter
        options.cameraBelowRim = cameraBelowRim
        // Deliberately the free solve, and deliberately without the lens-height check: the only
        // thing wanted here is the normal the trace's own shape implies.
        options.knownUp = nil
        options.plausibleCameraHeight = nil

        var agreement = RimUpAgreement()
        do {
            let free = try RimCalibrator.calibrate(boundaryPoints: boundaryPoints, intrinsics: intrinsics, options: options)
            agreement.tracedUp = free.up
        } catch {
            agreement.tracedUnavailableReason = "\(error)"
        }

        if let measuredUp, norm(measuredUp) > 1e-9 {
            agreement.measuredUp = unit(measuredUp)
        } else {
            agreement.measuredUnavailableReason = measuredUnavailableReason
                ?? "no measured up direction was supplied"
        }

        if let a = agreement.tracedUp, let b = agreement.measuredUp {
            agreement.disagreement = angleBetween(a, b)
        }
        return agreement
    }

    /// The same comparison when the traced direction is already in hand (the calibration that is on
    /// screen was solved freely, so its `up` *is* the traced one). Saves a second conic solve.
    public static func compare(tracedUp: SIMD3<Double>,
                               measuredUp: SIMD3<Double>?,
                               measuredUnavailableReason: String? = nil) -> RimUpAgreement {
        var agreement = RimUpAgreement()
        agreement.tracedUp = unit(tracedUp)
        if let measuredUp, norm(measuredUp) > 1e-9 {
            agreement.measuredUp = unit(measuredUp)
            agreement.disagreement = angleBetween(agreement.tracedUp!, agreement.measuredUp!)
        } else {
            agreement.measuredUnavailableReason = measuredUnavailableReason
                ?? "no measured up direction was supplied"
        }
        return agreement
    }

    // MARK: - Choosing between a hand trace and an auto-found trace

    /// Which boundary points actually reached `RimCalibrator.calibrate`.
    public enum ArbitrationWinner: String, Sendable {
        case traced
        case autoFound
    }

    /// What gravity decided between a shooter's hand trace and an automatically found trace of the
    /// same rim, and why — the record `arbitrate(tracedDisagreement:autoFoundDisagreement:)` returns.
    public struct Arbitration: Sendable {
        public var winner: ArbitrationWinner
        /// `RimUpAgreement.disagreement` for the hand trace, radians. `nil` when gravity was
        /// unavailable or the trace itself would not solve.
        public var tracedDisagreement: Double?
        /// The same for the auto-found candidate. `nil` when the finder never ran, found nothing, its
        /// candidate would not solve, or gravity was unavailable.
        public var autoFoundDisagreement: Double?
        /// True exactly when the app is using boundary points the shooter did not themselves draw —
        /// the one case CLAUDE.md's "never fabricate, never act silently" spirit requires the shooter
        /// be told about (`RimTrustCard`).
        public var usedRimTheShooterDidNotDraw: Bool { winner == .autoFound }

        public init(winner: ArbitrationWinner, tracedDisagreement: Double?, autoFoundDisagreement: Double?) {
            self.winner = winner
            self.tracedDisagreement = tracedDisagreement
            self.autoFoundDisagreement = autoFoundDisagreement
        }
    }

    /// Past this the two candidates are treated as different enough that gravity should pick between
    /// them, radians.
    ///
    /// **A convention chosen to avoid churn, not a measured finding** — like `RimUpAgreement.tolerance`,
    /// no study fixed this number. It exists so that two traces which already agree with gravity —
    /// on the 2026-09-13 corpus, 1.37° vs 1.24° on the elbow clip and 3.26° vs 1.72° on the free-throw
    /// clip — are never swapped over a fraction of a degree, which would only look like the app
    /// second-guessing a shooter who traced the ring correctly. The clip this exists for is the one
    /// where the gap was never close: 15.02° (hand) vs 0.54° (auto-found) on the three-point clip
    /// (`docs/research/three-point-acceptance-2026-09-24.md` §2).
    public static let arbitrationMargin = Angle.radians(3)

    /// Choose between a hand trace and an auto-found trace using how far each disagrees with gravity
    /// (`compare(...).disagreement` on each candidate, computed independently). The trace wins every
    /// tie and every case where one side is missing — there is nothing to arbitrate with only one
    /// candidate, or with no gravity, and the shooter's own work is the default absent a decisive
    /// reason to leave it.
    ///
    /// Pure and stateless on purpose: it only ever sees two angles and a margin, so it can be tested
    /// against the exact recorded numbers rather than against a rim trace and a mocked sensor.
    public static func arbitrate(tracedDisagreement: Double?, autoFoundDisagreement: Double?) -> Arbitration {
        guard let traced = tracedDisagreement, let autoFound = autoFoundDisagreement else {
            return Arbitration(winner: .traced, tracedDisagreement: tracedDisagreement,
                               autoFoundDisagreement: autoFoundDisagreement)
        }
        let winner: ArbitrationWinner = autoFound + arbitrationMargin < traced ? .autoFound : .traced
        return Arbitration(winner: winner, tracedDisagreement: traced, autoFoundDisagreement: autoFound)
    }
}
