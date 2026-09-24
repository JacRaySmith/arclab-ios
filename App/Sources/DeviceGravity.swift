import CoreMotion
import Foundation
import ShotGeometry
import simd

// MARK: - What was measured

/// Which way was down while a clip was filmed, as the phone's own sensors measured it.
///
/// Why this exists: the rim calibration reads the rim plane's normal out of the *shape* of a traced
/// ellipse, and a trace that wanders a few pixels onto the backboard bracket tilts that normal by
/// tens of degrees while the reprojected rim still lands on the ring. The tilt costs the release
/// height about `L · sin ε` — nothing at the rim, 1.1 m at a free throw, 1.7 m at a three — so it
/// hides completely at short range and refuses two thirds of the long shots
/// (`docs/research/three-point-acceptance-2026-09-24.md`). Gravity is measured to a fraction of a
/// degree and is the only independent witness the phone has.
///
/// **Frame.** `x/y/z` is CoreMotion's **device** frame and nothing else: `+x` out of the right edge
/// of the screen in portrait, `+y` out of the top edge, `+z` out of the screen towards the viewer;
/// the vector points *down*. Turning it into the camera's own basis needs the rotation between the
/// camera's native buffer and the pixels stored in the file, which is why that rotation is stored
/// beside it on `RecordedClip` and the conversion happens there, once, in `CameraGravity`.
struct GravityMeasurement: Codable, Sendable, Hashable {
    var x: Double
    var y: Double
    var z: Double
    /// How many device-motion samples the mean was taken over.
    var samples: Int
    /// The widest angle any single sample made with the mean, degrees. A tripod reads a fraction of
    /// a degree; a hand-held phone reads several. It is a measure of how much the camera moved, and
    /// therefore of whether *one* gravity direction describes the clip at all.
    var spreadDegrees: Double
    var measuredAt: Date

    var deviceVector: SIMD3<Double> { SIMD3(x, y, z) }

    /// Past this spread the clip has no single camera orientation, so neither the rim calibration
    /// nor this measurement describes it, and the measurement is withheld with a reason rather than
    /// averaged into a number that means nothing.
    ///
    /// The value is the same 5° convention `RimUpAgreement.tolerance` uses, for the same reason:
    /// below it the cost in release height is inside the noise of the trace itself. It is a
    /// convention, not a measured threshold.
    static let maxSpreadDegrees = Angle.degrees(RimUpAgreement.tolerance)
}

// MARK: - Measuring it

/// Reads gravity from CoreMotion while the app is filming, and hands back a mean with its spread.
///
/// Everything CoreMotion-shaped is in this file. The arithmetic that turns what it measures into an
/// up direction in the camera's basis lives in `ShotGeometry.CameraGravity`, where it is unit
/// tested; nothing here does geometry.
@MainActor
final class GravitySampler {
    static let shared = GravitySampler()

    private let motion = CMMotionManager()
    private var samples: [SIMD3<Double>] = []
    private var collecting = false

    private init() {
        // 10 Hz is ample: the question is which way a tripod points, not how it vibrates.
        motion.deviceMotionUpdateInterval = 0.1
    }

    /// Why there is no gravity to be had, in the shooter's words, or nil when there is.
    var unavailableReason: String? {
        #if targetEnvironment(simulator)
        return "the Simulator has no motion sensors, so nothing here knows which way is down"
        #else
        guard motion.isDeviceMotionAvailable else {
            return "this device reports no motion sensors, so nothing here knows which way is down"
        }
        return nil
        #endif
    }

    /// Start the sensors. Safe to call repeatedly; a no-op where there are none.
    func start() {
        guard unavailableReason == nil, !motion.isDeviceMotionActive else { return }
        // The pull model: no handler, no queue, no concurrency question — the value is simply read
        // off `motion.deviceMotion` whenever it is wanted.
        motion.startDeviceMotionUpdates()
    }

    func stop() {
        guard motion.isDeviceMotionActive else { return }
        motion.stopDeviceMotionUpdates()
        collecting = false
        samples = []
    }

    /// Begin a fresh collection for one recording.
    func beginCollecting() {
        samples = []
        collecting = true
        start()
        sample()
    }

    /// Take one reading. Called from the recorder's 100 ms tick, so a 10 s clip contributes ~100.
    func sample() {
        guard collecting, let g = motion.deviceMotion?.gravity else { return }
        let v = SIMD3(g.x, g.y, g.z)
        guard simd_length(v) > 0.5 else { return }      // a CoreMotion gravity vector is ~1 g
        samples.append(simd_normalize(v))
        // A long clip does not need thousands of them, and the spread is what matters, not the count.
        if samples.count > 2000 { samples.removeFirst(samples.count - 2000) }
    }

    /// Finish a collection: the mean direction over the recording and how far the worst sample was
    /// from it. `nil` with a reason when there is nothing to report — and never a default
    /// "straight down".
    func finishCollecting() -> (measurement: GravityMeasurement?, unavailableReason: String?) {
        collecting = false
        let taken = samples
        samples = []
        if let reason = unavailableReason { return (nil, reason) }
        guard !taken.isEmpty else {
            return (nil, "the motion sensors returned nothing while this clip was filmed, so which way was down is unknown")
        }
        var sum = SIMD3<Double>(0, 0, 0)
        for s in taken { sum += s }
        guard simd_length(sum) > 1e-6 else {
            return (nil, "the phone turned so much while filming that there is no single direction of down for this clip")
        }
        let mean = simd_normalize(sum)
        var spread = 0.0
        for s in taken { spread = max(spread, acos(max(-1, min(1, simd_dot(s, mean))))) }
        return (GravityMeasurement(x: mean.x, y: mean.y, z: mean.z, samples: taken.count,
                                   spreadDegrees: Angle.degrees(spread), measuredAt: Date()), nil)
    }
}
