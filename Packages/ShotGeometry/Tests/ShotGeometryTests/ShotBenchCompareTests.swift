// `Comparator.verdict` (Packages/ShotGeometry/Sources/ShotBenchKit/Compare.swift): the decision
// tree that turns McNemar + paired deltas + regressions into one of IMPROVED / NO DIFFERENCE /
// REGRESSED / MIXED. Built from synthetic sections only — no cache files, no video.
import XCTest
@testable import ShotBenchKit

final class ShotBenchCompareTests: XCTestCase {
    func mc(b: Int, c: Int) -> McNemarSection {
        let r = BenchStats.mcNemar(b: b, c: c)
        return McNemarSection(b: b, c: c, net: c - b, n: b + c, p: r.p, minorityNeededForSignificance: r.minorityNeededForSignificance)
    }

    func testNoDifferenceWhenNothingMoves() {
        let (verdict, _) = Comparator.verdict(mcNemar: mc(b: 1, c: 1), deltas: [], regressions: RegressionSection(gErrorAbsoluteThreshold: 0.02, rmsPxThreshold: 2, rule: "r", entries: []))
        XCTAssertEqual(verdict, "NO DIFFERENCE")
    }

    func testImprovedWhenAcceptanceRisesSignificantlyWithNoRegression() {
        // n=10, b=1, c=9: significant (p ≈ 0.0215), net = +8.
        let (verdict, reason) = Comparator.verdict(mcNemar: mc(b: 1, c: 9), deltas: [], regressions: RegressionSection(gErrorAbsoluteThreshold: 0.02, rmsPxThreshold: 2, rule: "r", entries: []))
        XCTAssertEqual(verdict, "IMPROVED")
        XCTAssertTrue(reason.contains("p="))
    }

    func testRegressedWhenAcceptanceRisesButQualityWorsens() {
        // Same significant acceptance rise as above, but a regression fired: per the stated rule,
        // this must be REGRESSED, never IMPROVED.
        let regressions = RegressionSection(gErrorAbsoluteThreshold: 0.02, rmsPxThreshold: 2, rule: "r",
                                            entries: [RegressionEntry(kind: "gError", detail: "w1: |gError| 3.0% → 9.0%")])
        let (verdict, reason) = Comparator.verdict(mcNemar: mc(b: 1, c: 9), deltas: [], regressions: regressions)
        XCTAssertEqual(verdict, "REGRESSED")
        XCTAssertTrue(reason.contains("regression"))
    }

    func testRegressedOnSignificantGErrorWorsening() {
        let worsening = PairedDeltaSection(metric: "gError", n: 20, medianDelta: 0.01, positive: 18, negative: 2, ties: 0, p: 0.001)
        let (verdict, _) = Comparator.verdict(mcNemar: mc(b: 0, c: 0), deltas: [worsening], regressions: RegressionSection(gErrorAbsoluteThreshold: 0.02, rmsPxThreshold: 2, rule: "r", entries: []))
        XCTAssertEqual(verdict, "REGRESSED")
    }

    func testMixedWhenGainsAndRegressionsBothPresentWithoutNetAcceptanceGain() {
        let improving = PairedDeltaSection(metric: "rmsPx", n: 20, medianDelta: -3, positive: 2, negative: 18, ties: 0, p: 0.001)
        let regressions = RegressionSection(gErrorAbsoluteThreshold: 0.02, rmsPxThreshold: 2, rule: "r",
                                            entries: [RegressionEntry(kind: "withinBlockSpread", detail: "w: SD widened")])
        let (verdict, _) = Comparator.verdict(mcNemar: mc(b: 0, c: 0), deltas: [improving], regressions: regressions)
        XCTAssertEqual(verdict, "MIXED")
    }
}
