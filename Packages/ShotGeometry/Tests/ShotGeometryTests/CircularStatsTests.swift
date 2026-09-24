// `CircularStats` / `AzimuthPooling` (Packages/ShotGeometry/Sources/ShotBenchKit/CircularStats.swift)
// — the circular estimators the pooled-azimuth variants are built on.
//
// The shot-plane azimuth lives on the full circle, so every estimator here has to survive the wrap
// point: on the 2026-09-13 corpus two of the three clips solve near 276°, and a sample straddling
// 0°/360° is the ordinary case, not a corner case. A circular median in particular is easy to get
// subtly wrong there (the naive "sort and take the middle" answer for {350°, 355°, 5°, 10°} is
// 177.5°, which is 180° from the truth), so every estimator is tested at the wrap point as well as
// away from it.
import XCTest
@testable import ShotGeometry
@testable import ShotBenchKit

final class CircularStatsTests: XCTestCase {

    private func deg(_ x: Double) -> Double { Angle.radians(x) }
    private func degs(_ xs: [Double]) -> [Double] { xs.map { Angle.radians($0) } }
    /// Wrapped to [0, 360) for comparison, so 359.9999 vs −0.0001 never fails on the wrap alone.
    private func inDegrees(_ x: Double?) -> Double? { x.map { Angle.degrees(CircularStats.wrapPositive($0)) } }

    // MARK: - wrapping and distance

    func testWrapPutsEveryAngleInTheHalfOpenInterval() {
        XCTAssertEqual(CircularStats.wrap(deg(370)), deg(10), accuracy: 1e-12)
        XCTAssertEqual(CircularStats.wrap(deg(-10)), deg(-10), accuracy: 1e-12)
        XCTAssertEqual(CircularStats.wrap(deg(350)), deg(-10), accuracy: 1e-12)
        XCTAssertEqual(CircularStats.wrapPositive(deg(-10)), deg(350), accuracy: 1e-12)
        XCTAssertEqual(CircularStats.wrapPositive(deg(730)), deg(10), accuracy: 1e-12)
        // A tiny negative angle must not round up to a full turn.
        XCTAssertLessThan(CircularStats.wrapPositive(-1e-17), 2 * Double.pi)
        XCTAssertGreaterThanOrEqual(CircularStats.wrapPositive(-1e-17), 0)
    }

    func testDistanceTakesTheShortWayRoundTheWrapPoint() {
        XCTAssertEqual(Angle.degrees(CircularStats.distance(deg(359), deg(1))), 2, accuracy: 1e-9)
        XCTAssertEqual(Angle.degrees(CircularStats.distance(deg(1), deg(359))), 2, accuracy: 1e-9)
        XCTAssertEqual(Angle.degrees(CircularStats.distance(deg(10), deg(200))), 170, accuracy: 1e-9)
        XCTAssertEqual(Angle.degrees(CircularStats.distance(deg(0), deg(180))), 180, accuracy: 1e-9)
    }

    // MARK: - mean

    func testMeanAtTheWrapPoint() {
        XCTAssertEqual(inDegrees(CircularStats.mean(degs([350, 355, 5, 10])))!, 0, accuracy: 1e-9)
        XCTAssertEqual(inDegrees(CircularStats.mean(degs([275, 277, 279])))!, 277, accuracy: 1e-9)
    }

    func testMeanRefusesASampleWithNoMeanDirection() {
        XCTAssertNil(CircularStats.mean([]))
        XCTAssertNil(CircularStats.mean(degs([0, 180])))          // exactly antipodal: no mean direction
        XCTAssertNil(CircularStats.mean(degs([0, 120, 240])))     // uniformly spread: resultant vanishes
    }

    // MARK: - median

    func testMedianAtTheWrapPoint() {
        // The naive non-circular median of {350, 355, 5, 10} is 177.5° — the antipode of the truth.
        XCTAssertEqual(inDegrees(CircularStats.median(degs([350, 355, 5, 10])))!, 0, accuracy: 1e-9)
        XCTAssertEqual(inDegrees(CircularStats.median(degs([358, 359, 0, 1, 2])))!, 0, accuracy: 1e-9)
        XCTAssertEqual(inDegrees(CircularStats.median(degs([355, 3])))!, 359, accuracy: 1e-9)
    }

    func testMedianIsTheMiddleValueForOddNAndTheMidpointForEvenN() {
        XCTAssertEqual(inDegrees(CircularStats.median(degs([270, 276, 280])))!, 276, accuracy: 1e-9)
        XCTAssertEqual(inDegrees(CircularStats.median(degs([270, 276, 280, 282])))!, 278, accuracy: 1e-9)
        XCTAssertEqual(inDegrees(CircularStats.median(degs([42])))!, 42, accuracy: 1e-9)
        XCTAssertNil(CircularStats.median([]))
    }

    func testMedianIsUnmovedByAWildOutlierThatDragsTheMean() {
        let core = degs([275, 276, 276, 277, 278])
        let withOutlier = core + degs([70])
        XCTAssertEqual(inDegrees(CircularStats.median(core))!, 276, accuracy: 1e-9)
        let medianShift = Angle.degrees(CircularStats.distance(CircularStats.median(withOutlier)!, CircularStats.median(core)!))
        XCTAssertLessThan(medianShift, 1.0)
        // The mean, by contrast, is dragged several degrees by that one value — an order of
        // magnitude more than the median, which is the whole reason the pooling rules use the median.
        let meanShift = Angle.degrees(CircularStats.distance(CircularStats.mean(withOutlier)!, CircularStats.mean(core)!))
        XCTAssertGreaterThan(meanShift, 5)
        XCTAssertGreaterThan(meanShift, 5 * max(medianShift, 0.01))
    }

    func testMedianDoesNotDependOnInputOrder() {
        let values = degs([350, 355, 5, 10, 12])
        let a = CircularStats.median(values)!
        let b = CircularStats.median(values.reversed())!
        let c = CircularStats.median([values[2], values[0], values[4], values[1], values[3]])!
        XCTAssertEqual(CircularStats.distance(a, b), 0, accuracy: 1e-12)
        XCTAssertEqual(CircularStats.distance(a, c), 0, accuracy: 1e-12)
    }

    // MARK: - spread

    func testMADAndMaxDeviationAtTheWrapPoint() {
        let values = degs([358, 359, 1, 2])
        let centre = CircularStats.median(values)!
        XCTAssertEqual(Angle.degrees(CircularStats.medianAbsoluteDeviation(values, about: centre)!), 1.5, accuracy: 1e-9)
        XCTAssertEqual(Angle.degrees(CircularStats.maxDeviation(values, about: centre)!), 2, accuracy: 1e-9)
    }

    func testResultantLengthAndCircularSD() {
        XCTAssertEqual(CircularStats.resultantLength(degs([10, 10, 10])), 1, accuracy: 1e-12)
        XCTAssertEqual(CircularStats.resultantLength(degs([0, 180])), 0, accuracy: 1e-12)
        XCTAssertEqual(Angle.degrees(CircularStats.standardDeviation(degs([-5, 0, 5]))!), 4.08, accuracy: 0.1)
        XCTAssertNil(CircularStats.standardDeviation(degs([7])))
    }

    // MARK: - the robust pool

    func testRobustPoolDropsAnOutlierAndKeepsTheCore() {
        let values = degs([275, 276, 276.5, 277, 278, 70])
        let pooled = AzimuthPooling.robust(values, clip: "test")!
        XCTAssertEqual(pooled.diagnostics.droppedCount, 1)
        XCTAssertEqual(pooled.kept.count, 5)
        XCTAssertEqual(inDegrees(pooled.center)!, 276.5, accuracy: 0.6)
        XCTAssertTrue(pooled.diagnostics.engaged)
    }

    func testRobustPoolWorksAcrossTheWrapPoint() {
        let values = degs([357, 358, 359, 1, 2, 170])
        let pooled = AzimuthPooling.robust(values, clip: "test")!
        XCTAssertEqual(pooled.diagnostics.droppedCount, 1)
        XCTAssertEqual(inDegrees(pooled.center)!, 359, accuracy: 1.5)
    }

    func testOutlierFloorProtectsATightCoreFromRejectingItsOwnMembers() {
        // Five values inside 0.2° of each other: MAD ≈ 0, so a pure k·MAD rule would reject the
        // ones a hair off centre. The floor keeps them.
        let values = degs([276.0, 276.0, 276.0, 276.1, 276.2])
        let pooled = AzimuthPooling.robust(values, clip: "test")!
        XCTAssertEqual(pooled.diagnostics.droppedCount, 0)
        XCTAssertEqual(pooled.diagnostics.keptCount, 5)
    }

    func testMinimumWindowsGateRefusesToPoolAndSaysWhy() {
        let pooled = AzimuthPooling.robust(degs([275, 277]), clip: "c", config: RobustPoolConfig(minimumWindows: 5))!
        XCTAssertFalse(pooled.diagnostics.engaged)
        XCTAssertTrue(pooled.diagnostics.reason.contains("need 5"), pooled.diagnostics.reason)
        // …but the numbers are still reported, so a refusal is auditable.
        XCTAssertNotNil(pooled.diagnostics.centerDegrees)
    }

    func testMADAgreementGateRefusesAScatteredClip() {
        let scattered = degs([240, 241, 242, 288, 290, 293])
        let config = RobustPoolConfig(minimumWindows: 3, maximumScaledMADDegrees: 10)
        let pooled = AzimuthPooling.robust(scattered, clip: "c", config: config)!
        XCTAssertFalse(pooled.diagnostics.engaged)
        XCTAssertTrue(pooled.diagnostics.reason.contains("agreement gate"), pooled.diagnostics.reason)
        // The same sample passes when the gate is off, which is what makes the gate the deciding rule.
        let ungated = AzimuthPooling.robust(scattered, clip: "c", config: RobustPoolConfig(minimumWindows: 3))!
        XCTAssertTrue(ungated.diagnostics.engaged)
    }

    func testRobustPoolRefusesAnEmptySample() {
        XCTAssertNil(AzimuthPooling.robust([], clip: "c"))
    }

    // MARK: - clustering

    func testClustersSplitTwoModesAndKeepOneModeWhole() {
        let two = AzimuthPooling.clusters(degs([240, 241, 242, 288, 290, 293]), gapDegrees: 10)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two[0].count, 3)
        XCTAssertEqual(two[1].count, 3)

        // A gap wider than the valley leaves the same sample as one cluster — the sensitivity the
        // 2026-09-24 experiment found on the free-throw clip.
        let one = AzimuthPooling.clusters(degs([240, 241, 242, 288, 290, 293]), gapDegrees: 60)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].count, 6)
    }

    func testAClusterStraddlingTheWrapPointStaysOneCluster() {
        let c = AzimuthPooling.clusters(degs([355, 358, 1, 4]), gapDegrees: 10)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].count, 4)
        XCTAssertEqual(inDegrees(CircularStats.median(c[0]))!, 359.5, accuracy: 1e-9)
    }

    func testClustersOfEmptyAndSingleSamples() {
        XCTAssertTrue(AzimuthPooling.clusters([], gapDegrees: 10).isEmpty)
        XCTAssertEqual(AzimuthPooling.clusters(degs([42]), gapDegrees: 10).count, 1)
    }

    func testClustersAreOrderedBiggestFirstAndPartitionTheSample() {
        let values = degs([10, 11, 12, 13, 200, 201, 330])
        let c = AzimuthPooling.clusters(values, gapDegrees: 10)
        XCTAssertEqual(c.map(\.count), [4, 2, 1])
        XCTAssertEqual(c.reduce(0) { $0 + $1.count }, values.count)
    }

    // MARK: - the variants that use all of the above

    func testPoolingExperimentVariantsAreRegisteredAndDifferOnlyInTheirPoolingRule() {
        let names = ["autoFoundNoPool", "autoFoundPooledMedian", "autoFoundPooledMedianAccepted",
                     "autoFoundPooledGated", "autoFoundPooledIterated", "autoFoundPooledClustered",
                     "autoFoundPooledClusteredTight"]
        for name in names { XCTAssertNotNil(Variant.named(name), "variant \(name) is not in Variant.all") }
        XCTAssertFalse(Variant.named("autoFoundNoPool")!.pooling.isEnabled)
        XCTAssertTrue(Variant.named("autoFoundPooledMedian")!.pooling.isEnabled)
        XCTAssertEqual(Variant.named("autoFoundTrace")!.pooling, .legacyAcceptedMean)
        XCTAssertEqual(Variant.named("autoFoundPooledGated")!.pooling,
                       .robustAll(RobustPoolConfig(maximumScaledMADDegrees: 10)))
    }

    func testPoolingVariantsSkipAClipWithNoBundledAutoFoundTrace() {
        let window = CachedWindow(windowID: "X@0001.0", clip: "NOT_A_CLIP.mov", spot: "three", samples: [],
                                  rimBoundary: [], rimDiameterUsed: 0.4572, width: 1920, height: 1080,
                                  hfovDegrees: 64, timeScale: 4, measuredFPS: 30, fileStart: 0, fileEnd: 1,
                                  releaseTimeOverride: nil, dumpedAt: "")
        for name in ["autoFoundNoPool", "autoFoundPooledMedian", "autoFoundPooledClustered"] {
            guard case .skip(let why) = Variant.named(name)!.makeOptions(window, VariantContext()) else {
                return XCTFail("\(name) should skip a clip with no bundled auto-found trace")
            }
            XCTAssertTrue(why.contains("auto-found rim trace"), why)
        }
    }

    func testContextPrefersAPerWindowPooledAzimuthOverThePerClipOne() {
        let window = CachedWindow(windowID: "W@0002.0", clip: "IMG_1765.mov", spot: "freeThrow", samples: [],
                                  rimBoundary: [], rimDiameterUsed: 0.4572, width: 1920, height: 1080,
                                  hfovDegrees: 64, timeScale: 4, measuredFPS: 30, fileStart: 0, fileEnd: 1,
                                  releaseTimeOverride: nil, dumpedAt: "")
        let context = VariantContext(pooledAzimuthByClip: ["IMG_1765.mov": deg(290)],
                                     pooledAzimuthByWindowID: ["W@0002.0": deg(241)])
        XCTAssertEqual(Angle.degrees(context.pooled(for: window)!), 241, accuracy: 1e-9)
        XCTAssertEqual(Angle.degrees(VariantContext(pooledAzimuthByClip: ["IMG_1765.mov": deg(290)]).pooled(for: window)!),
                       290, accuracy: 1e-9)
    }
}
