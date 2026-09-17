import XCTest
@testable import ShotGeometry

/// A wrong focal length does **not** show up as an obvious blow-up, and that is why it hid for a day.
///
/// Two things go wrong at once, both quiet:
/// 1. The conic solve recovers the rim's distance from its *angular* size, so an off-axis rim is
///    read through a `cos²θ` perspective stretch whose θ depends on fx. Too narrow an fx shrinks θ,
///    shrinks the stretch it corrects for, and shrinks metres-per-pixel at the rim — a uniform
///    scale error for the whole block, larger the further the rim sits from the principal point.
/// 2. It also puts the rim too far away, which makes the shot plane look too flat and under-corrects
///    the foreshortening along the flight — a deficit that **grows with the shot distance**.
///
/// That second signature is the one the 2026-09-13 footage showed with `--hfov 48`: free throws
/// roughly right, elbow −6 %, threes −9…−16 %. The 48° had been inferred from an *assumed* 9.3 m rim
/// distance (`docs/PHASE2-PREP.md`, "Real footage, evening of 2026-09-13"), never measured; the
/// measured value for that recording mode is 66.5° ± 2° — see "Three-point scale error: root cause
/// (2026-09-14)" in the same file for the vanishing-point calibration and its cross-checks.
final class FocalLengthTests: XCTestCase {
    /// Camera pose of the 2026-09-13 three-point block: side-on, ~7 m off the shot line, lens ~1.05 m.
    private static let lensHeight = 1.05

    private func simulate(releaseDistance L: Double, trueHFOV: Double) -> SimulatedShot {
        let truth = CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: trueHFOV)
        let shot = ShotParameters(releaseAngle: Angle.radians(47), releaseSpeed: 7.7, releaseHeight: 2.6, releaseDistance: L)
        let placement = CameraPlacement(viewAngle: Angle.radians(5), distance: 7.0, height: Self.lensHeight, intrinsics: truth)
        var options = SimulationOptions(); options.fps = 120; options.seed = 11
        return ShotSimulator.simulate(shot, placement: placement, options: options)
    }

    /// Everything downstream sees only pixels — the rim boundary and the ball track — plus whatever
    /// intrinsics the operator supplies.
    private func analyse(releaseDistance L: Double, trueHFOV: Double, assumedHFOV: Double) throws -> (g: Double, L: Double, lensHeight: Double) {
        let sim = simulate(releaseDistance: L, trueHFOV: trueHFOV)
        let assumed = CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: assumedHFOV)
        let cal = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: assumed)
        let a = try ShotAnalyzer.analyze(track: sim.samples, calibration: cal, intrinsics: assumed)
        return (a.confidence.gFit, try XCTUnwrap(a.metrics.release).distance, Court.rimHeight - cal.rimHeightAboveCamera)
    }

    /// With the right fx the pipeline returns the gravity and the release distance it was given.
    func testCorrectFocalLengthRecoversGravityAndDistance() throws {
        for L in [4.19, 4.85, 6.45] {
            let r = try analyse(releaseDistance: L, trueHFOV: 66.5, assumedHFOV: 66.5)
            XCTAssertEqual(r.g, Court.g, accuracy: 0.01 * Court.g, "L = \(L) m")
            XCTAssertEqual(r.L, L, accuracy: 0.02 * L, "L = \(L) m")
            XCTAssertEqual(r.lensHeight, Self.lensHeight, accuracy: 0.1, "L = \(L) m")
        }
    }

    /// Assuming 48° when the lens is 66.5° reproduces the field symptom: a gravity deficit that grows
    /// with the shot distance, and a release distance that reads short.
    /// Measured here: −4.6 % at 4.19 m, −5.8 % at 4.85 m, −9.4 % at 6.45 m.
    func testTooNarrowFocalLengthGivesADistanceDependentGravityDeficit() throws {
        let ft = try analyse(releaseDistance: 4.19, trueHFOV: 66.5, assumedHFOV: 48)
        let elbow = try analyse(releaseDistance: 4.85, trueHFOV: 66.5, assumedHFOV: 48)
        let three = try analyse(releaseDistance: 6.45, trueHFOV: 66.5, assumedHFOV: 48)

        let dFT = 1 - ft.g / Court.g, dElbow = 1 - elbow.g / Court.g, dThree = 1 - three.g / Court.g
        XCTAssertGreaterThan(dElbow, dFT, "the deficit must grow with the shot distance")
        XCTAssertGreaterThan(dThree, dElbow, "the deficit must grow with the shot distance")
        // The threes fall outside the brief's 8 % gravity gate; the free throws do not — which is
        // exactly why the free-throw block looked healthy while the three-point block did not.
        XCTAssertGreaterThan(dThree, 0.08)
        XCTAssertLessThan(dFT, 0.08)
        // …and the release distance reads short, as the three-point block did (5.8 m for a ~6.4 m shot).
        XCTAssertLessThan(three.L, 6.45 * 0.97)
    }

    /// The cheap field diagnostic, and the one that caught this: a focal length that is too narrow
    /// puts the rim too far away, so the rim ellipse's axis ratio — which fixes the elevation of the
    /// line of sight, and is nearly independent of fx — implies a camera on the ground.
    /// On 2026-09-13 the phone was on a tripod at ~1.2 m; hFOV 48° implied 0.2–0.5 m.
    func testTooNarrowFocalLengthImpliesAnImpossibleCameraHeight() throws {
        let sim = simulate(releaseDistance: 6.45, trueHFOV: 66.5)
        let wrong = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary,
                                                intrinsics: CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 48))
        let right = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary,
                                                intrinsics: CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 66.5))
        XCTAssertEqual(Court.rimHeight - right.rimHeightAboveCamera, Self.lensHeight, accuracy: 0.1)
        XCTAssertLessThan(Court.rimHeight - wrong.rimHeightAboveCamera, 0.5,
                          "hFOV 48° should imply a camera below knee height — the signature to check for")
        XCTAssertTrue(wrong.warnings.contains { $0.contains("above the floor") }, "the calibrator must say so")
        XCTAssertFalse(right.warnings.contains { $0.contains("above the floor") })
        // Same image, same rim: the recovered distance is not proportional to fx, so metres-per-pixel
        // at the rim moves too. That is the uniform part of the error.
        let mPerPxWrong = wrong.distanceToRim / (960 / tan(Angle.radians(48) / 2))
        let mPerPxRight = right.distanceToRim / (960 / tan(Angle.radians(66.5) / 2))
        XCTAssertLessThan(mPerPxWrong, 0.95 * mPerPxRight)
    }
}
