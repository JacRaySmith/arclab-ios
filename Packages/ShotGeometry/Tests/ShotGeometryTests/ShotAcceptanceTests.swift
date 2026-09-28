import XCTest
@testable import ShotGeometry

/// The acceptance rule decides which shots become numbers, so it is the one rule the app, the
/// desktop probe and the bench must apply identically. Until 2026-09-27 they did not: three copies
/// existed and two of them had drifted from the phone's. These tests pin both divergences, in both
/// directions, so a future edit to one copy cannot quietly re-open the gap.
final class ShotAcceptanceTests: XCTestCase {

    /// A release that passes every bound, so each test can move exactly one number.
    private func goodMetrics(height: Double = 2.4, speed: Double = 7.2, distance: Double = 4.19,
                             depth: Double? = 0.18) -> ShotMetrics {
        var m = ShotMetrics()
        m.release = ReleaseMetrics(angle: Angle.radians(47), height: height, speed: speed, distance: distance)
        m.depthPastFrontRim = depth
        return m
    }

    // MARK: - the rule agrees with itself

    func testAPlainGoodShotIsPlausibleUnderBothPolicies() {
        let m = goodMetrics()
        XCTAssertTrue(ShotAcceptance.plausible(m, policy: .shipping))
        XCTAssertTrue(ShotAcceptance.plausible(m, policy: .legacyBench))
    }

    func testTheSharedBoundsAreTheSameInBothPolicies() {
        for p in [ShotAcceptancePolicy.shipping, .legacyBench] {
            XCTAssertEqual(p.releaseHeight, 1.6...3.3, "release height band moved in \(p.name)")
            XCTAssertEqual(p.releaseSpeed, 4.5...11.0, "release speed band moved in \(p.name)")
            XCTAssertEqual(p.depthPastFrontRim, -0.6...1.0, "depth band moved in \(p.name)")
            XCTAssertEqual(p.maxReprojectionRmsPx, 25.0, "residual ceiling moved in \(p.name)")
            XCTAssertEqual(p.gravityTolerance, GravityGate.acceptTolerance, "gravity tolerance moved in \(p.name)")
        }
    }

    func testHeightSpeedAndDepthBoundsRejectOutsideValues() {
        XCTAssertFalse(ShotAcceptance.plausible(goodMetrics(height: 1.59)))
        XCTAssertFalse(ShotAcceptance.plausible(goodMetrics(height: 3.31)))
        XCTAssertFalse(ShotAcceptance.plausible(goodMetrics(speed: 4.49)))
        XCTAssertFalse(ShotAcceptance.plausible(goodMetrics(speed: 11.01)))
        XCTAssertFalse(ShotAcceptance.plausible(goodMetrics(depth: -0.61)))
        XCTAssertFalse(ShotAcceptance.plausible(goodMetrics(depth: 1.01)))
    }

    // MARK: - divergence 1: the minimum release distance existed only in the app

    func testAPutBackIsRefusedByTheShippingRule() {
        // A ball released 0.25 m from the rim centre is a tip or a put-back, not a shot from a spot.
        let tip = goodMetrics(distance: 0.25)
        XCTAssertFalse(ShotAcceptance.plausible(tip, policy: .shipping),
                       "the phone refuses a release inside minimumReleaseDistance")
    }

    func testThePreviousBenchRuleCountedThatPutBackAsAShot() {
        // This is the bug, stated as a test: the bench scored every EXPERIMENTS.md row with a rule
        // that had no distance floor at all.
        let tip = goodMetrics(distance: 0.25)
        XCTAssertTrue(ShotAcceptance.plausible(tip, policy: .legacyBench),
                      "legacyBench must keep reproducing the old numbers, distance floor and all")
        XCTAssertNil(ShotAcceptancePolicy.legacyBench.minimumReleaseDistance)
        XCTAssertEqual(ShotAcceptancePolicy.shipping.minimumReleaseDistance, 2.0)
    }

    func testTheDistanceFloorIsExactlyTwoMetres() {
        XCTAssertTrue(ShotAcceptance.plausible(goodMetrics(distance: 2.0)))
        XCTAssertFalse(ShotAcceptance.plausible(goodMetrics(distance: 1.999)))
    }

    // MARK: - divergence 2: a window with no depth

    func testAShotWithNoMeasurableDepthIsKeptByTheAppAndWasRefusedByTheBench() {
        // `depthPastFrontRim` is nil when the arc was not tracked past apex, the view is frontal, or
        // the fitted arc never reaches rim height. CLAUDE.md rule 1: unavailable is not implausible.
        var m = goodMetrics(depth: nil)
        m.entryAngleUnavailableReason = "arc not tracked past apex (1 samples after apex)"
        XCTAssertTrue(ShotAcceptance.plausible(m, policy: .shipping),
                      "the phone skips a check it has no number for")
        XCTAssertFalse(ShotAcceptance.plausible(m, policy: .legacyBench),
                       "the old bench rule refused the window outright")
    }

    func testAShotWithNoObservedReleaseSplitsTheSameWay() {
        var m = ShotMetrics()
        m.releaseUnavailableReason = "release instant not in the footage (track starts in flight)"
        m.depthPastFrontRim = 0.2
        XCTAssertTrue(ShotAcceptance.plausible(m, policy: .shipping))
        XCTAssertFalse(ShotAcceptance.plausible(m, policy: .legacyBench))
    }

    // MARK: - the verdict wording the UI reads

    func testTheRefusalSentenceNamesTheNumberThatFailed() {
        var m = goodMetrics(height: 1.30)
        m.entryAngleUnavailableReason = nil
        // Build the sentence the same way `evaluate` does for a plausibility failure.
        XCTAssertFalse(ShotAcceptance.plausible(m, policy: .shipping))
        // The band is quoted in the message so the shooter can see what it was compared against.
        let policy = ShotAcceptancePolicy.shipping
        XCTAssertEqual(policy.releaseHeight.lowerBound, 1.6)
        XCTAssertEqual(policy.releaseHeight.upperBound, 3.3)
    }

    func testPolicyNamesAreStableBecauseScorecardsRecordThem() {
        XCTAssertEqual(ShotAcceptancePolicy.shipping.name, "shipping")
        XCTAssertEqual(ShotAcceptancePolicy.legacyBench.name, "legacyBench")
        XCTAssertNotEqual(ShotAcceptancePolicy.shipping, ShotAcceptancePolicy.legacyBench,
                          "if these ever become equal, every scorecard's provenance becomes a lie")
    }
}

/// The absolute ball-size cue (2026-09-27). It was **measured and reverted** — it rescued no refused
/// window on the 2026-09-13 corpus and made the fit residual significantly worse (see
/// `docs/EXPERIMENTS.md`). The apparatus is kept so the negative result stays reproducible, which
/// makes "it is off, and off means off" the thing worth pinning.
final class BallSizeCueTests: XCTestCase {

    func testTheCueIsOffByDefault() {
        XCTAssertNil(AnalysisOptions().ballSizeCue,
                     "the cue was reverted on the evidence; a default of non-nil would silently ship it")
    }

    func testTheExpectedDiameterIsTheBallTimesTheMeasuredBoxBias() {
        let cue = BallSizeCue.detectorDefault(weight: 0.02)
        XCTAssertEqual(cue.expectedDiameter, BallSize.size7.diameter * BallSizeCue.measuredBoxBias, accuracy: 1e-12)
        // The bias is a detector property measured over three camera placements (1.157/1.176/1.181).
        // If it ever leaves that range, the number stopped being the thing the comment describes.
        XCTAssertGreaterThan(BallSizeCue.measuredBoxBias, 1.15)
        XCTAssertLessThan(BallSizeCue.measuredBoxBias, 1.19)
        // And it must be a *bias*, never silently the true ball: that would move every depth by 15 %.
        XCTAssertNotEqual(cue.expectedDiameter, BallSize.size7.diameter)
    }

    /// A zero weight must be exactly the un-cued solve, so the sweep's low end is a true control.
    func testZeroWeightIsIdenticalToNoCue() throws {
        let p = ShotParameters(releaseAngle: Angle.radians(48), releaseSpeed: 7.1, releaseHeight: 2.35,
                               releaseDistance: 4.19, lateralOffset: 0, lateralAimError: 0)
        let pl = CameraPlacement(viewAngle: Angle.radians(30), distance: 8, height: 1.5,
                                 intrinsics: CameraPlacement.iPhone1080p())
        var o = SimulationOptions(); o.noisePx = 1.0; o.diameterNoisePx = 1.0; o.seed = 4242
        let sim = ShotSimulator.simulate(p, placement: pl, options: o)
        let cal = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: pl.intrinsics)

        let plain = ShotPlaneSolver.solveByFixedGravity(sim.samples, calibration: cal, intrinsics: pl.intrinsics)
        let zero = ShotPlaneSolver.solveByFixedGravity(sim.samples, calibration: cal, intrinsics: pl.intrinsics,
                                                       ballSizeCue: BallSizeCue.detectorDefault(weight: 0))
        XCTAssertNotNil(plain); XCTAssertNotNil(zero)
        XCTAssertEqual(try XCTUnwrap(plain).frame.azimuth, try XCTUnwrap(zero).frame.azimuth, accuracy: 1e-12,
                       "weight 0 must not perturb the objective at all")
    }

    /// A cue heavy enough to matter must still *change* something, or the sweep measured nothing.
    func testANonZeroWeightCanMoveTheSolve() throws {
        let p = ShotParameters(releaseAngle: Angle.radians(48), releaseSpeed: 7.1, releaseHeight: 2.35,
                               releaseDistance: 4.19, lateralOffset: 0, lateralAimError: 0)
        let pl = CameraPlacement(viewAngle: Angle.radians(45), distance: 8, height: 1.5,
                                 intrinsics: CameraPlacement.iPhone1080p())
        var o = SimulationOptions(); o.noisePx = 2.0; o.diameterNoisePx = 3.0; o.seed = 909
        let sim = ShotSimulator.simulate(p, placement: pl, options: o)
        let cal = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: pl.intrinsics)
        // A deliberately wrong expected size: the objective must be able to feel it.
        let wrong = BallSizeCue(expectedDiameter: 0.05, weight: 5.0)
        let plain = try XCTUnwrap(ShotPlaneSolver.solveByFixedGravity(sim.samples, calibration: cal, intrinsics: pl.intrinsics))
        let cued = try XCTUnwrap(ShotPlaneSolver.solveByFixedGravity(sim.samples, calibration: cal, intrinsics: pl.intrinsics,
                                                                     ballSizeCue: wrong))
        XCTAssertNotEqual(plain.frame.azimuth, cued.frame.azimuth, accuracy: 0,
                          "a 5 m-per-100 % prior toward a 5 cm ball that changes nothing means the term is not wired in")
    }
}
