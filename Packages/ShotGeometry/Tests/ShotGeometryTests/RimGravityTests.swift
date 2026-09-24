import XCTest
@testable import ShotGeometry

/// `RimCalibrationOptions.knownUp` — taking the rim plane's normal from a measured gravity direction
/// instead of from the shape of the traced ellipse.
///
/// Why it matters, from `docs/research/three-point-acceptance-2026-09-24.md`: the conic solve reads the
/// plane's normal out of the ellipse's shape, and a few contaminated boundary points tilt that normal by
/// tens of degrees while the reprojected rim still looks right. A tilted plane costs the release height
/// roughly `L·sin(tilt)` — nothing at the rim, 1.6 m at a three-point release — so the error hides at
/// short range and refuses the shot at long range. On `footage/2026-09-13/IMG_1766` the hand trace's own
/// normal is 15° from the vertical that the light poles and an independent auto-found trace both give,
/// and that one number refused 24 of 25 three-point windows.
final class RimGravityTests: XCTestCase {
    /// The 2026-09-13 three-point camera pose: side-on, ~7.6 m off the shot line, lens ~1.05 m.
    private func simulate(releaseDistance L: Double = 6.45) -> SimulatedShot {
        let k = CameraPlacement.iPhone14Pro1080p120()
        let shot = ShotParameters(releaseAngle: Angle.radians(47), releaseSpeed: 7.7, releaseHeight: 2.6, releaseDistance: L)
        let placement = CameraPlacement(viewAngle: Angle.radians(6), distance: 7.6, height: 1.05, intrinsics: k)
        var o = SimulationOptions(); o.fps = 120; o.seed = 7; o.rimNoisePx = 0
        return ShotSimulator.simulate(shot, placement: placement, options: o)
    }

    /// Drag the boundary points on one side of the ellipse, the way a trace that wanders onto the
    /// backboard bracket does. `docs/PHASE2-PREP.md` measures the real thing at +3, +9 px.
    private func contaminate(_ boundary: [SIMD2<Double>], by delta: SIMD2<Double>, fraction: Double = 0.2) -> [SIMD2<Double>] {
        let xs = boundary.map(\.x).sorted()
        let cut = xs[Int(Double(xs.count) * (1 - fraction))]
        return boundary.map { $0.x >= cut ? $0 + delta : $0 }
    }

    // MARK: - the closed form and the constrained fit agree with the free solve on a clean trace

    func testKnownUpIsANoOpOnACleanTrace() throws {
        let sim = simulate()
        let k = sim.placement.intrinsics
        let free = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: k)
        var o = RimCalibrationOptions(); o.knownUp = sim.truth.upCamera
        let constrained = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: k, options: o)

        // A clean trace already knows which way is up, so constraining it must change nothing that matters.
        XCTAssertLessThan(angleBetween(free.up, sim.truth.upCamera), Angle.radians(1), "free solve should already be within 1° on a clean trace")
        XCTAssertLessThan(norm(constrained.rimCenter - sim.truth.rimCenterCamera), 0.05,
                          "constrained rim centre should land within 5 cm of truth")
        XCTAssertLessThan(abs(constrained.distanceToRim - free.distanceToRim), 0.10,
                          "constrained and free distance should agree within 10 cm on a clean trace")
        XCTAssertFalse(constrained.warnings.contains { $0.contains("from the measured gravity direction") },
                       "no disagreement warning is due on a clean trace")
    }

    /// The closed form behind the constrained fit's starting point, on a conic built from a known circle.
    func testClosedFormCentreFromAKnownNormalIsExact() throws {
        let sim = simulate()
        let k = sim.placement.intrinsics
        guard let fit = EllipseFitter.fit(sim.rimBoundary) else { return XCTFail("rim ellipse did not fit") }
        // Normalised conic, exactly as RimCalibrator builds it.
        let Qpx = fit.ellipse.conic.matrix, K = k.matrix
        var KtQ = [[Double]](repeating: [0, 0, 0], count: 3), Qn = KtQ
        for i in 0..<3 { for j in 0..<3 { for m in 0..<3 { KtQ[i][j] += K[m][i] * Qpx[m][j] } } }
        for i in 0..<3 { for j in 0..<3 { for m in 0..<3 { Qn[i][j] += KtQ[i][m] * K[m][j] } } }
        let pose = try XCTUnwrap(RimCalibrator.poseWithKnownNormal(conic: Qn, normal: sim.truth.upCamera,
                                                                   radius: Court.rimInnerRadius))
        XCTAssertLessThan(norm(pose.center - sim.truth.rimCenterCamera), 0.05)
    }

    // MARK: - the case this exists for

    /// A trace dragged onto a bracket tilts the normal the conic hands back, and `knownUp` pins it — loudly.
    func testContaminatedTraceTiltsTheFreeSolveNormal() throws {
        let sim = simulate()
        let k = sim.placement.intrinsics
        let bad = contaminate(sim.rimBoundary, by: SIMD2(6, 16))

        let free = try RimCalibrator.calibrate(boundaryPoints: bad, intrinsics: k)
        XCTAssertGreaterThan(angleBetween(free.up, sim.truth.upCamera), Angle.radians(8),
                             "the contamination should tilt the free solve's up by >8°")
        // And it does so *silently*: nothing in the free solve's own output says the trace is bad.
        XCTAssertFalse(free.warnings.contains { $0.contains("gravity") })

        var o = RimCalibrationOptions(); o.knownUp = sim.truth.upCamera
        let fixed = try RimCalibrator.calibrate(boundaryPoints: bad, intrinsics: k, options: o)
        XCTAssertLessThan(angleBetween(fixed.up, sim.truth.upCamera), Angle.radians(0.01))
        XCTAssertTrue(fixed.warnings.contains { $0.contains("from the measured gravity direction") },
                      "an 8°+ disagreement must be reported, not silently absorbed")
        XCTAssertTrue(fixed.warnings.contains { $0.contains("no horizontal circle reproduces") },
                      "a trace no horizontal circle fits must say so")
    }

    /// Why a tilted "up" refuses threes and spares free throws, isolated from every solver: the release
    /// height is the true release point's rise above the rim centre *measured along the calibration's up*,
    /// so an error `ε` in that direction costs `≈ L·sin ε` — nothing at the rim, a metre at 6.45 m.
    ///
    /// The end-to-end cost is not exactly this, because the azimuth solve re-optimises in the tilted frame
    /// and absorbs part of it (in the simulator, one tilt direction is absorbed much more than the other).
    /// The field numbers are in `docs/research/three-point-acceptance-2026-09-24.md`; this test pins the
    /// mechanism, which is the part that is exact.
    func testUpTiltCostsReleaseHeightInProportionToShotDistance() throws {
        func heightAsRead(releaseDistance L: Double, tiltDegrees: Double) throws -> Double {
            let sim = simulate(releaseDistance: L)
            let up = sim.truth.upCamera
            let axis = SIMD3<Double>(0, 0, 1)                    // a camera-roll error, about the optical axis
            let c = cos(Angle.radians(tiltDegrees)), s = sin(Angle.radians(tiltDegrees))
            let tilted = unit(c * up + s * cross3(axis, up) + (1 - c) * dot3(axis, up) * axis)
            var o = RimCalibrationOptions(); o.knownUp = tilted; o.plausibleCameraHeight = nil
            let cal = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: sim.placement.intrinsics, options: o)
            // The true release point in the camera frame, read the way the pipeline reads it.
            let release = sim.camera.pose.toCamera(sim.parameters.releasePoint)
            return dot3(release - cal.rimCenter, cal.up) + Court.rimHeight
        }
        for L in [4.19, 6.45] {
            XCTAssertEqual(try heightAsRead(releaseDistance: L, tiltDegrees: 0), 2.6, accuracy: 0.05,
                           "with gravity right the release height must come back as filmed")
        }
        for sign in [1.0, -1.0] {
            let freeThrow = abs(try heightAsRead(releaseDistance: 4.19, tiltDegrees: sign * 15) - 2.6)
            let three = abs(try heightAsRead(releaseDistance: 6.45, tiltDegrees: sign * 15) - 2.6)
            XCTAssertEqual(three / freeThrow, 6.45 / 4.19, accuracy: 0.25, "the cost should scale with the shot distance")
            XCTAssertGreaterThan(three, 1.0, "at 6.45 m a 15° tilt is worth more than a metre of release height")
        }
    }
}
