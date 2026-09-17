import XCTest
import simd
@testable import FormEvalKit
@testable import ShotGeometry

/// Every case here has an answer that can be worked out on paper, because a reliability statistic
/// that is only checked against its own output is not checked at all.
final class StatisticsTests: XCTestCase {

    // MARK: - order statistics

    func testPercentileMatchesTheType7Definition() throws {
        let xs = (1...10).map(Double.init)
        // numpy.percentile(range(1,11), 50) = 5.5; 90 → 9.1; 0 → 1; 100 → 10.
        XCTAssertEqual(try XCTUnwrap(EvalStats.percentile(xs, 0.5)), 5.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(EvalStats.percentile(xs, 0.9)), 9.1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(EvalStats.percentile(xs, 0.0)), 1.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(EvalStats.percentile(xs, 1.0)), 10.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(EvalStats.percentile([7], 0.9)), 7.0, accuracy: 1e-12)
        XCTAssertNil(EvalStats.percentile([], 0.5))
    }

    func testPercentileIgnoresNonFiniteValues() throws {
        XCTAssertEqual(try XCTUnwrap(EvalStats.percentile([1, 2, .nan, 3], 0.5)), 2.0, accuracy: 1e-12)
    }

    func testSDNeedsTwoValues() {
        XCTAssertNil(EvalStats.sd([4.0]))
        XCTAssertEqual(EvalStats.sd([2, 4, 4, 4, 5, 5, 7, 9])!, 2.138089935299395, accuracy: 1e-12)
    }

    // MARK: - two-way ANOVA

    /// A hand-computable 3×2 table. x = [[1,2],[3,4],[5,6]].
    /// grand = 3.5; row means 1.5, 3.5, 5.5; col means 3, 4.
    /// SSR = 2·(4+0+4) = 16 → MSR = 8.   SSC = 3·(0.25+0.25) = 1.5 → MSC = 1.5.
    /// SST = Σ(x−3.5)² = 6.25+2.25+0.25+0.25+2.25+6.25 = 17.5 → SSE = 0 → MSE = 0.
    func testTwoWayMeanSquaresOnAHandComputedTable() throws {
        let ms = try XCTUnwrap(EvalStats.twoWayMeanSquares([[1, 2], [3, 4], [5, 6]]))
        XCTAssertEqual(ms.msr, 8.0, accuracy: 1e-12)
        XCTAssertEqual(ms.msc, 1.5, accuracy: 1e-12)
        XCTAssertEqual(ms.mse, 0.0, accuracy: 1e-12)
        XCTAssertEqual(ms.n, 3); XCTAssertEqual(ms.k, 2)
    }

    // MARK: - ICC

    func testICCIsOneWhenTheTwoMeasurementsAgreeExactly() throws {
        let rows = [[10.0, 10.0], [12.0, 12.0], [14.0, 14.0], [9.0, 9.0], [20.0, 20.0]]
        let r = EvalStats.icc21(rows, bootstrap: 0)
        XCTAssertEqual(try XCTUnwrap(r.value), 1.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r.consistency), 1.0, accuracy: 1e-12)
        XCTAssertEqual(r.subjects, 5); XCTAssertEqual(r.raters, 2)
    }

    /// A constant offset between the two measurements is exactly what "absolute agreement" must
    /// punish and "consistency" must not. With b = a + c the algebra collapses to
    ///     ICC(2,1) = 2·var(a) / (2·var(a) + c²)        and       ICC(3,1) = 1.
    func testConstantBiasHasAClosedFormICC() throws {
        let a = [1.0, 2.0, 3.0, 4.0, 5.0]          // sample variance 2.5
        for c in [0.5, 1.0, 3.0] {
            let rows = a.map { [$0, $0 + c] }
            let r = EvalStats.icc21(rows, bootstrap: 0)
            let expected = 2 * 2.5 / (2 * 2.5 + c * c)
            XCTAssertEqual(try XCTUnwrap(r.value), expected, accuracy: 1e-10, "offset \(c)")
            XCTAssertEqual(try XCTUnwrap(r.consistency), 1.0, accuracy: 1e-10, "offset \(c)")
            XCTAssertLessThan(try XCTUnwrap(r.value), 1.0)
        }
    }

    /// Two measurements that are a pure coin flip around one shared mean carry no subject signal:
    /// MSR ≈ MSE and the ICC sits at zero (it is allowed to go slightly negative, which is the
    /// honest report of "less agreement than chance", so the test bounds rather than clamps it).
    func testICCIsNearZeroWhenTheSubjectsCarryNoSignal() throws {
        var rng = SplitMix64(seed: 99)
        func gaussian() -> Double {
            let u1 = Double(rng.next() >> 11) / Double(1 << 53), u2 = Double(rng.next() >> 11) / Double(1 << 53)
            return (-2 * Foundation.log(max(u1, 1e-12))).squareRoot() * Foundation.cos(2 * .pi * u2)
        }
        let rows = (0..<400).map { _ in [gaussian(), gaussian()] }
        let r = EvalStats.icc21(rows, bootstrap: 0)
        XCTAssertEqual(try XCTUnwrap(r.value), 0.0, accuracy: 0.12)
    }

    /// Subject spread ten times the measurement noise must read as high reliability.
    func testICCRisesWithTheSubjectToNoiseRatio() throws {
        var rng = SplitMix64(seed: 7)
        func gaussian() -> Double {
            let u1 = Double(rng.next() >> 11) / Double(1 << 53), u2 = Double(rng.next() >> 11) / Double(1 << 53)
            return (-2 * Foundation.log(max(u1, 1e-12))).squareRoot() * Foundation.cos(2 * .pi * u2)
        }
        let rows = (0..<300).map { _ -> [Double] in
            let truth = 10 * gaussian()
            return [truth + gaussian(), truth + gaussian()]
        }
        let r = EvalStats.icc21(rows, bootstrap: 0)
        // σ²_subject = 100, σ²_error = 1 → ICC ≈ 100/101 ≈ 0.990.
        XCTAssertEqual(try XCTUnwrap(r.value), 0.990, accuracy: 0.02)
    }

    func testICCRefusesAnImpossibleTable() {
        XCTAssertNotNil(EvalStats.icc21([[1.0, 2.0]], bootstrap: 0).unavailableReason)
        XCTAssertNotNil(EvalStats.icc21([[1.0, 1.0], [1.0, 1.0]], bootstrap: 0).unavailableReason)
        XCTAssertNotNil(EvalStats.icc21([[1.0, 2.0], [3.0]], bootstrap: 0).unavailableReason)
        // …but a well-formed 2×2 table is computed, with no excuse attached.
        let fine = EvalStats.icc21([[1.0, 2.0], [3.0, 4.0]], bootstrap: 0)
        XCTAssertNil(fine.unavailableReason)
        XCTAssertNotNil(fine.value)
    }

    func testBootstrapIntervalIsDeterministicAndBracketsThePoint() throws {
        let rows = (0..<40).map { i -> [Double] in
            let t = Double(i) * 0.5
            return [t, t + (i % 3 == 0 ? 0.4 : -0.2)]
        }
        let a = EvalStats.icc21(rows, bootstrap: 500)
        let b = EvalStats.icc21(rows, bootstrap: 500)
        XCTAssertEqual(try XCTUnwrap(a.lower95), try XCTUnwrap(b.lower95), accuracy: 0)
        XCTAssertEqual(try XCTUnwrap(a.upper95), try XCTUnwrap(b.upper95), accuracy: 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(a.lower95), try XCTUnwrap(a.value))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(a.upper95), try XCTUnwrap(a.value))
        XCTAssertGreaterThan(a.bootstrapSamples, 100)
    }

    // MARK: - repeatability

    /// σ_meas is the SD of **one** measurement recovered from the paired differences:
    /// Var(a − b) = 2σ², so σ = √(Σd²/2n). A split that is always exactly ±1 therefore gives
    /// σ = √(4·n / 2n) = √2 — the formula cannot tell a constant 2-unit disagreement from noise of
    /// that size, and it is supposed to charge for it either way. SDC = 1.96·√2·σ = 3.92,
    /// reliability = 1 − σ²/s² = 1 − 2/10 = 0.8.
    func testRepeatabilityHasTheStatedAlgebra() throws {
        let full = [10.0, 12.0, 14.0, 16.0, 18.0]                 // sample SD = √10
        let a = full.map { $0 + 1.0 }, b = full.map { $0 - 1.0 }  // every difference is 2
        let r = EvalStats.repeatability(measure: "x", unit: "deg", full: full, a: a, b: b, bootstrap: 0)
        XCTAssertEqual(r.n, 5)
        XCTAssertEqual(try XCTUnwrap(r.mean), 14.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r.betweenShotSD), 10.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r.measurementSD), 2.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r.smallestDetectableChange), 3.92, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r.reliability), 0.8, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r.cvPercent), 100 * 10.0.squareRoot() / 14.0, accuracy: 1e-12)
    }

    /// And a split that agrees exactly is noise-free: σ = 0, SDC = 0, reliability = 1.
    func testAPerfectlyRepeatableMeasureCostsNothing() throws {
        let full = [10.0, 12.0, 14.0, 16.0, 18.0]
        let r = EvalStats.repeatability(measure: "x", unit: "deg", full: full, a: full, b: full, bootstrap: 0)
        XCTAssertEqual(try XCTUnwrap(r.measurementSD), 0.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r.smallestDetectableChange), 0.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r.reliability), 1.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r.icc.value), 1.0, accuracy: 1e-12)
    }

    func testRepeatabilityRefusesWhatItCannotCompute() {
        let r = EvalStats.repeatability(measure: "x", unit: "deg", full: [1], a: [1], b: [1], bootstrap: 0)
        XCTAssertNotNil(r.unavailableReason)
        XCTAssertNil(r.betweenShotSD)
        let ragged = EvalStats.repeatability(measure: "x", unit: "deg", full: [1, 2], a: [1], b: [1], bootstrap: 0)
        XCTAssertNotNil(ragged.unavailableReason)
    }

    /// Reliability is a share and must never leave [0, 1], even when the noise exceeds the spread.
    func testReliabilityIsClampedAtZeroWhenNoiseSwampsTheSignal() throws {
        let full = [10.0, 10.1, 9.9, 10.05]
        let a = full.map { $0 + 5.0 }, b = full.map { $0 - 5.0 }
        let r = EvalStats.repeatability(measure: "x", unit: "deg", full: full, a: a, b: b, bootstrap: 0)
        XCTAssertEqual(try XCTUnwrap(r.reliability), 0.0, accuracy: 1e-12)
    }
}
