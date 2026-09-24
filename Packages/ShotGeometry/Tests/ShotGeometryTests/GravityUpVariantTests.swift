// `upFromPitchRoll` / `MeasuredVertical` / `AutoFoundRimTrace` (Packages/ShotGeometry/Sources/ShotBenchKit/Variants.swift)
// — the conversion and per-clip data the `gravityUp` and `autoFoundTrace` variants need.
//
// Three things get checked here, matching docs/research/three-point-acceptance-2026-09-24.md §2/§4:
// (1) the pitch/roll → up conversion reproduces that document's one published number bit for bit;
// (2) it round-trips a known pitch/roll through the *actual* `RimCalibration.pitch`/`.roll` formulas,
//     not a reimplementation of them;
// (3) the two clips whose pitch/roll are *not* published anywhere are derived, not guessed, from the
//     raw vanishing points docs/PHASE2-PREP.md records for them, by the identical method.
import XCTest
import simd
@testable import ShotGeometry
@testable import ShotBenchKit

final class GravityUpVariantTests: XCTestCase {

    // MARK: - the one number the research document states outright

    func testMatchesTheResearchDocumentsPublishedIMG1766Value() {
        let published = SIMD3(0.0639, -0.9917, 0.1120)
        let fromPitchRoll = upFromPitchRoll(pitchDegrees: 6.43, rollDegrees: -3.69)
        XCTAssertEqual(fromPitchRoll.x, published.x, accuracy: 0.0005)
        XCTAssertEqual(fromPitchRoll.y, published.y, accuracy: 0.0005)
        XCTAssertEqual(fromPitchRoll.z, published.z, accuracy: 0.0005)

        // Cross-check via the independent path: the raw vertical vanishing point PHASE2-PREP.md
        // records for IMG_1766, (1837, −13064), through this cache's own hfov (64°).
        let k = CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 64)
        let fromVP = upFromVerticalVanishingPoint(SIMD2(1837, -13064), intrinsics: k)
        XCTAssertEqual(fromVP.x, published.x, accuracy: 0.0005)
        XCTAssertEqual(fromVP.y, published.y, accuracy: 0.0005)
        XCTAssertEqual(fromVP.z, published.z, accuracy: 0.0005)

        XCTAssertEqual(MeasuredVertical.knownUp(clip: "IMG_1766.mov"), fromPitchRoll)
    }

    // MARK: - IMG_1764/IMG_1765 are derived, not guessed — check the derivation against the raw VP

    func testIMG1764And1765PitchRollAreDerivedFromPHASE2PREPsVanishingPoints() {
        let k = CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 64)
        func pitchRollDegrees(_ vp: SIMD2<Double>) -> (pitch: Double, roll: Double) {
            let up = upFromVerticalVanishingPoint(vp, intrinsics: k)
            return (Angle.degrees(asin(max(-1, min(1, up.z)))), Angle.degrees(atan2(-up.x, -up.y)))
        }
        let elbow = pitchRollDegrees(SIMD2(1314, -10892))
        XCTAssertEqual(elbow.pitch, MeasuredVertical.byClip["IMG_1764.mov"]!.pitchDegrees, accuracy: 0.01)
        XCTAssertEqual(elbow.roll, MeasuredVertical.byClip["IMG_1764.mov"]!.rollDegrees, accuracy: 0.01)

        let freeThrow = pitchRollDegrees(SIMD2(1191, -10141))
        XCTAssertEqual(freeThrow.pitch, MeasuredVertical.byClip["IMG_1765.mov"]!.pitchDegrees, accuracy: 0.01)
        XCTAssertEqual(freeThrow.roll, MeasuredVertical.byClip["IMG_1765.mov"]!.rollDegrees, accuracy: 0.01)
    }

    // MARK: - round-trips a known roll/pitch through the real calibration basis

    private func simulatedRimBoundary() -> (boundary: [SIMD2<Double>], intrinsics: CameraIntrinsics) {
        let k = CameraPlacement.iPhone14Pro1080p120()
        let shot = ShotParameters(releaseAngle: Angle.radians(47), releaseSpeed: 7.7, releaseHeight: 2.6, releaseDistance: 6.45)
        let placement = CameraPlacement(viewAngle: Angle.radians(6), distance: 7.6, height: 1.05, intrinsics: k)
        var o = SimulationOptions(); o.fps = 120; o.seed = 7; o.rimNoisePx = 0
        let sim = ShotSimulator.simulate(shot, placement: placement, options: o)
        return (sim.rimBoundary, sim.placement.intrinsics)
    }

    func testRoundTripsAKnownPitchAndRollThroughRimCalibration() throws {
        let (boundary, k) = simulatedRimBoundary()
        // The simulated camera's own pitch/roll (zero deviation from what the traced ellipse
        // actually is — guaranteed solvable) plus the two real corpus values this file uses. A
        // `knownUp` far from the trace's own plane can legitimately have no horizontal-circle
        // solution in front of the camera (`RimCalibrationError.noSolutionInFrontOfCamera`,
        // `RimCalibration.swift`) — that is the constrained fit's guard against a degenerate
        // minimum working as intended, not something this conversion test needs to exercise.
        var truthUp = SIMD3<Double>(0, -1, 0)
        do {
            let free = try RimCalibrator.calibrate(boundaryPoints: boundary, intrinsics: k)
            truthUp = free.up
        } catch { XCTFail("free solve on the simulated boundary should succeed: \(error)") }
        let truthPitch = Angle.degrees(asin(max(-1, min(1, truthUp.z))))
        let truthRoll = Angle.degrees(atan2(-truthUp.x, -truthUp.y))

        for (pitchDeg, rollDeg) in [(truthPitch, truthRoll), (6.43, -3.69), (7.65, -1.77)] {
            let up = upFromPitchRoll(pitchDegrees: pitchDeg, rollDegrees: rollDeg)
            var o = RimCalibrationOptions(); o.knownUp = up; o.plausibleCameraHeight = nil
            do {
                let cal = try RimCalibrator.calibrate(boundaryPoints: boundary, intrinsics: k, options: o)
                XCTAssertEqual(Angle.degrees(cal.pitch), pitchDeg, accuracy: 0.01,
                               "pitch did not round-trip for (\(pitchDeg), \(rollDeg))")
                XCTAssertEqual(Angle.degrees(cal.roll), rollDeg, accuracy: 0.01,
                               "roll did not round-trip for (\(pitchDeg), \(rollDeg))")
            } catch {
                XCTFail("calibrate threw for (\(pitchDeg), \(rollDeg)): \(error)")
            }
        }
    }

    // MARK: - the variant itself: never guesses a clip it has no measured vertical for

    private func fixtureWindow(clip: String) -> CachedWindow {
        CachedWindow(windowID: "\(clip)@0000.0", clip: clip, spot: "three", samples: [], rimBoundary: [],
                    rimDiameterUsed: 0.4572, width: 1920, height: 1080, hfovDegrees: 64, timeScale: 4,
                    measuredFPS: 30, fileStart: 0, fileEnd: 1, releaseTimeOverride: nil, dumpedAt: "")
    }

    func testGravityUpVariantAppliesTheMeasuredUpAndSkipsAnUnmeasuredClip() {
        let known = fixtureWindow(clip: "IMG_1766.mov")
        guard case .options = Variant.gravityUp.makeOptions(known, VariantContext()) else {
            return XCTFail("IMG_1766 has a measured vertical; gravityUp must not skip it")
        }
        XCTAssertEqual(Variant.gravityUp.calibrationOverride(known).knownUp, upFromPitchRoll(pitchDegrees: 6.43, rollDegrees: -3.69))

        let unmeasured = fixtureWindow(clip: "IMG_9999.mov")
        guard case .skip(let reason) = Variant.gravityUp.makeOptions(unmeasured, VariantContext()) else {
            return XCTFail("a clip with no recorded vertical must be skipped, never guessed")
        }
        XCTAssertTrue(reason.contains("IMG_9999"))
        XCTAssertNil(Variant.gravityUp.calibrationOverride(unmeasured).knownUp)
    }

    // MARK: - the bundled auto-found traces

    func testAutoFoundTraceIsBundledForAllThreeClipsAndSkipsAnUnknownOne() {
        for clip in ["IMG_1764.mov", "IMG_1765.mov", "IMG_1766.mov"] {
            let points = AutoFoundRimTrace.boundaryPoints(forClip: clip)
            XCTAssertEqual(points?.count, 64, "\(clip) should have its bundled 64-point auto-found trace")
            guard case .options = Variant.autoFoundTrace.makeOptions(fixtureWindow(clip: clip), VariantContext()) else {
                return XCTFail("\(clip) has a bundled auto-found trace; autoFoundTrace must not skip it")
            }
        }
        XCTAssertNil(AutoFoundRimTrace.boundaryPoints(forClip: "IMG_9999.mov"))
        guard case .skip(let reason) = Variant.autoFoundTrace.makeOptions(fixtureWindow(clip: "IMG_9999.mov"), VariantContext()) else {
            return XCTFail("a clip with no bundled trace must be skipped, never guessed")
        }
        XCTAssertTrue(reason.contains("IMG_9999"))
    }

    /// The auto-found IMG_1766 trace's own (free-solve) pitch/roll, from
    /// docs/research/three-point-acceptance-2026-09-24.md §2: "pitch 6.9°, roll −3.4°" — close to
    /// the measured vertical (6.43°, −3.69°), unlike the 15°-off hand trace. Confirms the bundled
    /// resource is the same trace that document measured, not a stale or different file.
    func testBundledAutoFoundIMG1766TraceMatchesThePublishedFreeSolve() throws {
        let points = try XCTUnwrap(AutoFoundRimTrace.boundaryPoints(forClip: "IMG_1766.mov"))
        let k = CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 64)
        let cal = try RimCalibrator.calibrate(boundaryPoints: points, intrinsics: k)
        XCTAssertEqual(Angle.degrees(cal.pitch), 6.9, accuracy: 0.3)
        XCTAssertEqual(Angle.degrees(cal.roll), -3.4, accuracy: 0.3)
    }
}
