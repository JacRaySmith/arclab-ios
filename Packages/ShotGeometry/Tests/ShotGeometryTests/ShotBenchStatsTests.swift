// Statistics for `ShotBench compare` (Packages/ShotGeometry/Sources/ShotBenchKit/Stats.swift,
// Compare.swift). Hand-computed against the exact binomial formula — no video, no cache files.
import XCTest
@testable import ShotBenchKit

final class ShotBenchStatsTests: XCTestCase {

    // MARK: - exact binomial tail

    func testBinomialCoefficient() {
        XCTAssertEqual(BenchStats.binomialCoefficient(10, 0), 1)
        XCTAssertEqual(BenchStats.binomialCoefficient(10, 10), 1)
        XCTAssertEqual(BenchStats.binomialCoefficient(10, 5), 252)
        XCTAssertEqual(BenchStats.binomialCoefficient(10, 9), 10)
        XCTAssertEqual(BenchStats.binomialCoefficient(4, 3), 4)
    }

    func testBinomialUpperTail() {
        // P(X >= 9 | n=10, p=0.5) = (C(10,9) + C(10,10)) / 1024 = 11/1024
        XCTAssertEqual(BenchStats.binomialUpperTail(k: 9, n: 10), 11.0 / 1024.0, accuracy: 1e-12)
        // P(X >= 0) = 1 always
        XCTAssertEqual(BenchStats.binomialUpperTail(k: 0, n: 10), 1)
        // P(X >= n+1) = 0
        XCTAssertEqual(BenchStats.binomialUpperTail(k: 11, n: 10), 0)
    }

    // MARK: - McNemar

    func testMcNemarNoDiscordantPairs() {
        // b + c == 0: no window changed verdict, no p-value.
        let r = BenchStats.mcNemar(b: 0, c: 0)
        XCTAssertNil(r.p)
        XCTAssertNil(r.minorityNeededForSignificance)
        XCTAssertEqual(r.net, 0)
    }

    func testMcNemarSymmetricSplit() {
        // b == c: as even as a split can be, p must be exactly 1 (never > 1, per the min(1, ...) rule).
        let r = BenchStats.mcNemar(b: 5, c: 5)
        XCTAssertEqual(r.p!, 1.0, accuracy: 1e-12)
        XCTAssertEqual(r.net, 0)
    }

    func testMcNemarLopsidedIsSignificant() {
        // b=1, c=9, n=10: P(X>=9|10,0.5) = 11/1024 = 0.0107421875; two-sided p = 0.021484375.
        let r = BenchStats.mcNemar(b: 1, c: 9)
        XCTAssertEqual(r.p!, 0.021484375, accuracy: 1e-9)
        XCTAssertLessThan(r.p!, 0.05)
        XCTAssertEqual(r.net, 8)
    }

    func testMcNemarNearBoundaryIsNotSignificant() {
        // b=2, c=8, n=10: P(X>=8|10,0.5) = 56/1024; two-sided p = 0.109375 > 0.05.
        let r = BenchStats.mcNemar(b: 2, c: 8)
        XCTAssertEqual(r.p!, 0.109375, accuracy: 1e-9)
        XCTAssertGreaterThan(r.p!, 0.05)
    }

    func testMinorityNeededForSignificance() {
        // At n=10, the smallest lopsided split with p <= 0.05 is 9 (verified against testMcNemarLopsidedIsSignificant).
        XCTAssertEqual(BenchStats.minorityNeededForSignificance(n: 10), 9)
        // n=0: nothing to split.
        XCTAssertNil(BenchStats.minorityNeededForSignificance(n: 0))
        // n=1: a single discordant pair can never be significant (p=1 either way).
        XCTAssertNil(BenchStats.minorityNeededForSignificance(n: 1))
    }

    // MARK: - sign test

    func testSignTestHandComputed() {
        // deltas: +,+,-,+,0 -> positive=3, negative=1, ties=1, n=4, k=3.
        // P(X>=3|4,0.5) = (C(4,3)+C(4,4))/16 = 5/16 = 0.3125; two-sided p = 0.625.
        let r = BenchStats.signTest([1, 1, -1, 1, 0])
        XCTAssertEqual(r.positive, 3)
        XCTAssertEqual(r.negative, 1)
        XCTAssertEqual(r.ties, 1)
        XCTAssertEqual(r.n, 4)
        XCTAssertEqual(r.p!, 0.625, accuracy: 1e-9)
    }

    func testSignTestAllZerosHasNoP() {
        let r = BenchStats.signTest([0, 0, 0])
        XCTAssertEqual(r.n, 0)
        XCTAssertNil(r.p)
    }

    func testSignTestEmptyInput() {
        let r = BenchStats.signTest([])
        XCTAssertEqual(r.n, 0)
        XCTAssertNil(r.p)
    }

    // MARK: - median / percentile

    func testMedianAndP90() {
        let xs: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        XCTAssertEqual(BenchStats.median(xs)!, 5.5, accuracy: 1e-9)
        // "type 7" percentile at p=0.9 over 10 sorted values 1...10: h = 9*0.9 = 8.1 -> between v[8]=9, v[9]=10.
        XCTAssertEqual(BenchStats.p90(xs)!, 9.1, accuracy: 1e-9)
    }

    func testMedianEmpty() {
        XCTAssertNil(BenchStats.median([]))
        XCTAssertNil(BenchStats.p90([]))
    }

    // MARK: - paired-delta pairing (Compare.swift's `Pairing.pair`)

    func testPairingMatchesCommonKeysOnly() {
        let base: [String: Double] = ["a": 1, "b": 2, "c": 3]
        let candidate: [String: Double] = ["a": 1.5, "b": 2.5, "d": 9]
        let (pairs, baseOnly, candOnly) = Pairing.pair(base, candidate)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(Set(pairs.map(\.id)), ["a", "b"])
        XCTAssertEqual(pairs.first { $0.id == "a" }!.base, 1)
        XCTAssertEqual(pairs.first { $0.id == "a" }!.candidate, 1.5)
        XCTAssertEqual(baseOnly, ["c"])       // present only in base
        XCTAssertEqual(candOnly, ["d"])       // present only in candidate
    }

    func testPairingWithNoOverlap() {
        let base: [String: Double] = ["a": 1]
        let candidate: [String: Double] = ["b": 2]
        let (pairs, baseOnly, candOnly) = Pairing.pair(base, candidate)
        XCTAssertTrue(pairs.isEmpty)
        XCTAssertEqual(baseOnly, ["a"])
        XCTAssertEqual(candOnly, ["b"])
    }

    func testPairingIsSortedById() {
        let base: [String: Double] = ["z": 1, "a": 2, "m": 3]
        let candidate: [String: Double] = ["z": 1, "a": 2, "m": 3]
        let (pairs, _, _) = Pairing.pair(base, candidate)
        XCTAssertEqual(pairs.map(\.id), ["a", "m", "z"])
    }

    func testMedianPairedDelta() {
        let pairs: [(base: Double, candidate: Double)] = [(1, 2), (2, 2), (3, 1)]
        // deltas: +1, 0, -2 -> median = 0
        XCTAssertEqual(BenchStats.medianPairedDelta(pairs)!, 0, accuracy: 1e-9)
    }
}
