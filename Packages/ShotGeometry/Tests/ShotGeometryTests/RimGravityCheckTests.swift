import XCTest
@testable import ShotGeometry

/// The two pure pieces the app needs to know which way is down when a rim is traced:
/// `CameraGravity` (CoreMotion's device-frame gravity → an up direction in the camera's own basis)
/// and `RimGravity` (how far a traced rim's own plane normal is from that direction).
///
/// The app owns the CoreMotion half; everything with arithmetic in it is here, where it can be run.
final class RimGravityCheckTests: XCTestCase {

    // MARK: - The basis conversion

    /// The anchor case: a phone held upright in portrait, filming level. CoreMotion reads
    /// `(0, −1, 0)`; the recorded picture is the sensor turned by 90° (the rotation an iPhone
    /// portrait video's preferred transform carries); the camera's up must come out as
    /// `(0, −1, 0)` — `RimCalibrationOptions.upHint`'s documented "an upright phone".
    func testUprightPortraitPhoneGivesTheDocumentedUpHint() throws {
        let up = try XCTUnwrap(CameraGravity.imageUp(fromDeviceGravity: SIMD3(0, -1, 0), sensorToImageDegrees: 90))
        XCTAssertEqual(up.x, 0, accuracy: 1e-12)
        XCTAssertEqual(up.y, -1, accuracy: 1e-12)
        XCTAssertEqual(up.z, 0, accuracy: 1e-12)
        XCTAssertEqual(CameraGravity.pitch(ofUp: up), 0, accuracy: 1e-12)
        XCTAssertEqual(CameraGravity.roll(ofUp: up), 0, accuracy: 1e-12)
    }

    /// The other anchor, and the one the tripod actually uses: the phone on its side, filming
    /// level, with no rotation applied because the native buffer is already the right way up.
    /// Gravity then lies along the device's −x axis and the camera is again level.
    func testLandscapeOnATripodIsLevelWithNoRotation() throws {
        let up = try XCTUnwrap(CameraGravity.imageUp(fromDeviceGravity: SIMD3(-1, 0, 0), sensorToImageDegrees: 0))
        XCTAssertEqual(up.y, -1, accuracy: 1e-12)
        XCTAssertEqual(CameraGravity.roll(ofUp: up), 0, accuracy: 1e-12)
        XCTAssertEqual(CameraGravity.pitch(ofUp: up), 0, accuracy: 1e-12)

        // Turned end for end (the same tripod, the phone the other way up) the picture is upside
        // down in the buffer, so the file carries a 180° rotation and the camera is level again.
        let flipped = try XCTUnwrap(CameraGravity.imageUp(fromDeviceGravity: SIMD3(1, 0, 0), sensorToImageDegrees: 180))
        XCTAssertEqual(flipped.y, -1, accuracy: 1e-12)
        XCTAssertEqual(CameraGravity.roll(ofUp: flipped), 0, accuracy: 1e-12)
    }

    /// A camera tipped up to see the rim: gravity leans into the device's +z (the screen turns
    /// towards the floor), and the recovered pitch must be that lean, with the roll untouched.
    /// This is the sign that decides whether the release height is read too high or too low.
    func testTiltingTheCameraUpShowsAsPositivePitch() throws {
        for degrees in [3.0, 8.0, 21.0] {
            let r = Angle.radians(degrees)
            // Phone on its side (native rotation), camera pitched up by `degrees`.
            let gravityDevice = SIMD3(-cos(r), 0, sin(r))
            let up = try XCTUnwrap(CameraGravity.imageUp(fromDeviceGravity: gravityDevice, sensorToImageDegrees: 0))
            XCTAssertEqual(Angle.degrees(CameraGravity.pitch(ofUp: up)), degrees, accuracy: 1e-9)
            XCTAssertEqual(Angle.degrees(CameraGravity.roll(ofUp: up)), 0, accuracy: 1e-9)
        }
    }

    /// Rolling the phone about the lens axis shows up as roll and nothing else, at every one of the
    /// four rotations a recorded file can carry.
    func testRollingThePhoneShowsAsRollAtEveryStoredRotation() throws {
        for (rotation, level) in [(0.0, SIMD3(-1.0, 0, 0)), (90.0, SIMD3(0.0, -1, 0)),
                                  (180.0, SIMD3(1.0, 0, 0)), (270.0, SIMD3(0.0, 1, 0))] {
            for degrees in [-12.0, -4.0, 6.0] {
                // Roll about the optical axis = about the device's z axis, whatever the rotation.
                let r = Angle.radians(degrees)
                let c = cos(r), s = sin(r)
                let rolled = SIMD3(c * level.x - s * level.y, s * level.x + c * level.y, level.z)
                let up = try XCTUnwrap(CameraGravity.imageUp(fromDeviceGravity: rolled, sensorToImageDegrees: rotation))
                XCTAssertEqual(abs(Angle.degrees(CameraGravity.roll(ofUp: up))), abs(degrees), accuracy: 1e-9,
                               "rotation \(rotation)°, roll \(degrees)°")
                XCTAssertEqual(Angle.degrees(CameraGravity.pitch(ofUp: up)), 0, accuracy: 1e-9)
            }
        }
    }

    /// Round trip: device gravity → camera up → device gravity, at every stored rotation and a
    /// spread of attitudes. A sign error in any of the three axes shows here.
    func testBasisConversionRoundTrips() throws {
        let attitudes: [SIMD3<Double>] = [
            SIMD3(0, -1, 0), SIMD3(-1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0),
            SIMD3(0.12, -0.97, 0.21), SIMD3(0.30, -0.50, 0.81), SIMD3(-0.62, -0.44, -0.65),
        ]
        for rotation in [0.0, 90.0, 180.0, 270.0] {
            for g in attitudes {
                let gu = unit(g)
                let up = try XCTUnwrap(CameraGravity.imageUp(fromDeviceGravity: gu, sensorToImageDegrees: rotation))
                XCTAssertEqual(norm(up), 1, accuracy: 1e-12)
                let back = try XCTUnwrap(CameraGravity.deviceGravity(fromImageUp: up, sensorToImageDegrees: rotation))
                XCTAssertLessThan(norm(back - gu), 1e-12, "rotation \(rotation)°, gravity \(gu)")
            }
        }
    }

    /// No vector, no answer — never a default "straight down".
    func testAZeroGravityVectorIsNilNotAGuess() {
        XCTAssertNil(CameraGravity.imageUp(fromDeviceGravity: SIMD3(0, 0, 0), sensorToImageDegrees: 90))
        XCTAssertNil(CameraGravity.deviceGravity(fromImageUp: SIMD3(0, 0, 0), sensorToImageDegrees: 0))
    }

    // MARK: - Trace against gravity

    private func simulate(releaseDistance L: Double = 6.45) -> SimulatedShot {
        let k = CameraPlacement.iPhone14Pro1080p120()
        let shot = ShotParameters(releaseAngle: Angle.radians(47), releaseSpeed: 7.7, releaseHeight: 2.6, releaseDistance: L)
        let placement = CameraPlacement(viewAngle: Angle.radians(6), distance: 7.6, height: 1.05, intrinsics: k)
        var o = SimulationOptions(); o.fps = 120; o.seed = 7; o.rimNoisePx = 0
        return ShotSimulator.simulate(shot, placement: placement, options: o)
    }

    /// Tip a direction over by exactly `degrees`, in the plane that contains it and the optical
    /// axis — the direction a contaminated trace tilts the rim's normal in. Rotating about the
    /// optical axis itself would move `up` by less than the rotation, because `up` is not
    /// perpendicular to it, and the test wants a known angle.
    private func tilted(_ up: SIMD3<Double>, byDegrees degrees: Double) -> SIMD3<Double> {
        let perpendicular = unit(cross3(up, SIMD3(0, 0, 1)))
        let r = Angle.radians(degrees)
        return unit(cos(r) * unit(up) + sin(r) * perpendicular)
    }

    /// A clean trace and the truth agree, and the app is told to say nothing.
    func testACleanTraceAgreesWithGravity() {
        let sim = simulate()
        let a = RimGravity.compare(boundaryPoints: sim.rimBoundary, intrinsics: sim.placement.intrinsics,
                                   measuredUp: sim.truth.upCamera)
        XCTAssertNotNil(a.tracedUp)
        XCTAssertNil(a.tracedUnavailableReason)
        let disagreement = a.disagreement ?? .infinity
        XCTAssertLessThan(disagreement, Angle.radians(1))
        XCTAssertFalse(a.disagrees)
    }

    /// The measured direction is off by a known angle: the comparison must return that angle, not
    /// an approximation of it.
    func testDisagreementIsTheAngleBetweenTheTwoDirections() throws {
        let sim = simulate()
        let traced = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: sim.placement.intrinsics).up
        for degrees in [2.0, 5.5, 15.0, 31.0] {
            let a = RimGravity.compare(tracedUp: traced, measuredUp: tilted(traced, byDegrees: degrees))
            XCTAssertEqual(Angle.degrees(try XCTUnwrap(a.disagreement)), degrees, accuracy: 1e-9)
            XCTAssertEqual(a.disagrees, degrees > 5, "the 5° convention decides whether the shooter hears about it")
        }
    }

    /// The case the whole thing exists for, end to end on a synthetic trace dragged onto a
    /// "bracket": the ellipse still fits, the free solve's normal tilts, and the comparison says so.
    func testAContaminatedTraceIsCaughtAgainstGravity() throws {
        let sim = simulate()
        let xs = sim.rimBoundary.map(\.x).sorted()
        let cut = xs[Int(Double(xs.count) * 0.8)]
        let bad = sim.rimBoundary.map { $0.x >= cut ? $0 + SIMD2(6, 16) : $0 }

        let a = RimGravity.compare(boundaryPoints: bad, intrinsics: sim.placement.intrinsics, measuredUp: sim.truth.upCamera)
        XCTAssertTrue(a.disagrees)
        XCTAssertGreaterThan(try XCTUnwrap(a.disagreement), Angle.radians(8))
        // And the cost the shooter is quoted is the lever arm, not a fudge.
        let cost = try XCTUnwrap(a.heightErrorMetres(atDistance: RimUpAgreement.threePointReleaseDistance))
        XCTAssertEqual(cost, RimUpAgreement.threePointReleaseDistance * sin(try XCTUnwrap(a.disagreement)), accuracy: 1e-12)
        XCTAssertGreaterThan(cost, 0.8)
    }

    /// The cost quoted at the shooter is `L · sin ε` and is zero at the rim itself — the whole
    /// reason a tilted trace hides at short range.
    func testHeightErrorGrowsWithDistanceAndIsZeroAtTheRim() throws {
        var a = RimUpAgreement()
        a.tracedUp = SIMD3(0, -1, 0)
        a.measuredUp = SIMD3(0, -1, 0)
        a.disagreement = Angle.radians(15)
        XCTAssertEqual(try XCTUnwrap(a.heightErrorMetres(atDistance: 0)), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(a.heightErrorMetres(atDistance: 4.19)), 1.084, accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(a.heightErrorMetres(atDistance: 6.45)), 1.669, accuracy: 0.002)
    }

    /// No motion data: nil with the reason that was handed in, and **no** disagreement — a zero
    /// here would read as "the trace is fine", which is the one thing it must never say.
    func testNoMotionDataIsNilWithAReason() {
        let sim = simulate()
        let why = "this clip came from Photos, so nothing recorded which way was down while it was filmed"
        let a = RimGravity.compare(boundaryPoints: sim.rimBoundary, intrinsics: sim.placement.intrinsics,
                                   measuredUp: nil, measuredUnavailableReason: why)
        XCTAssertNil(a.measuredUp)
        XCTAssertNil(a.disagreement)
        XCTAssertNil(a.measuredPitch)
        XCTAssertNil(a.measuredRoll)
        XCTAssertNil(a.heightErrorMetres(atDistance: 6.45))
        XCTAssertFalse(a.disagrees, "an unknown direction is not a disagreement")
        XCTAssertEqual(a.measuredUnavailableReason, why)
        XCTAssertNotNil(a.tracedUp, "the trace's own normal is still measurable without a sensor")
    }

    /// A trace that does not solve at all is a reason, not a crash, and still leaves the measured
    /// side intact.
    func testATraceThatCannotSolveIsAReason() {
        let a = RimGravity.compare(boundaryPoints: [SIMD2(0, 0), SIMD2(1, 1)],
                                   intrinsics: CameraPlacement.iPhone14Pro1080p120(),
                                   measuredUp: SIMD3(0, -1, 0))
        XCTAssertNil(a.tracedUp)
        XCTAssertNotNil(a.tracedUnavailableReason)
        XCTAssertNil(a.disagreement)
        XCTAssertNotNil(a.measuredUp)
    }

    /// The sensor-free check: a trace implying a roll no tripod would hold. The threshold is a
    /// convention, so the test pins the *convention*, not a claim about tripods.
    ///
    /// What `RimGravity.compare` returns on the real 2026-09-13 traces, run at hFOV 64° against the
    /// vertical vanishing points in `docs/PHASE2-PREP.md` (`footage/2026-09-13/rim_*.json`, which
    /// are not in the test bundle, so this is a record rather than an assertion):
    ///
    ///     trace              traced pitch/roll    gravity pitch/roll   disagreement   cost at a three
    ///     rim_1766 (hand)     1.82° / −18.03°      6.43° / −3.69°        15.02°          1.67 m
    ///     rim_1766_found      6.89° /  −3.41°      6.43° / −3.69°         0.54°          0.06 m
    ///     rim_1765 (hand)     5.42° /  −2.98°      8.18° / −1.24°         3.26°          0.37 m
    ///     rim_1764 (hand)     7.20° /  −0.47°      7.65° / −1.77°         1.37°          0.15 m
    ///
    /// The first two reproduce `docs/research/three-point-acceptance-2026-09-24.md` exactly (15.0°
    /// and "0.6° from the pole-derived vertical"). The third is 3.26° where that document says
    /// "2–3° … worth ≈ 0.1 m"; it is the same conclusion — well inside the 5° tolerance — but the
    /// number is a little larger than the document's wording implies, and the 0.1 m is nearer 0.24 m
    /// at a free throw. Reported rather than reconciled.
    func testTheImplausibleRollConventionSeparatesTheRealTraces() {
        // The 2026-09-13 traces, from docs/research/three-point-acceptance-2026-09-24.md §2.
        XCTAssertLessThan(abs(Angle.radians(-3.0)), RimGravity.implausibleTripodRoll, "IMG_1765's hand trace")
        XCTAssertLessThan(abs(Angle.radians(-3.4)), RimGravity.implausibleTripodRoll, "IMG_1766's auto-found trace")
        XCTAssertGreaterThan(abs(Angle.radians(-18.0)), RimGravity.implausibleTripodRoll, "IMG_1766's hand trace")
    }
}
