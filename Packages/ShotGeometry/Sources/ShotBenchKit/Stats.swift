// Statistics for `ShotBench compare`. Named `BenchStats` (not `Stats`) so it never collides with
// `ShotGeometry.Stats`, which this file's callers also see.
import Foundation

public enum BenchStats {

    // MARK: - order statistics

    /// Linear-interpolation ("type 7") percentile, matching `numpy.percentile` / R's default.
    public static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        let v = xs.filter(\.isFinite).sorted()
        guard !v.isEmpty else { return nil }
        if v.count == 1 { return v[0] }
        let h = (Double(v.count) - 1) * min(max(p, 0), 1)
        let lo = Int(h.rounded(.down)), hi = min(lo + 1, v.count - 1)
        return v[lo] + (h - Double(lo)) * (v[hi] - v[lo])
    }
    public static func median(_ xs: [Double]) -> Double? { percentile(xs, 0.5) }
    public static func p90(_ xs: [Double]) -> Double? { percentile(xs, 0.9) }

    public static func sd(_ xs: [Double]) -> Double? {
        let v = xs.filter(\.isFinite)
        guard v.count >= 2 else { return nil }
        let m = v.reduce(0, +) / Double(v.count)
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1)).squareRoot()
    }

    // MARK: - exact binomial tail

    /// `C(n, k)` as a `Double`, built by the multiplicative recurrence (never forms the huge
    /// intermediate factorials an `n!/(k!(n-k)!)` computation would, so it stays exact — to Double's
    /// 53-bit mantissa — for every n this tool will ever see: corpora of shot windows, not genomes).
    static func binomialCoefficient(_ n: Int, _ k: Int) -> Double {
        guard k >= 0, k <= n else { return 0 }
        let k = min(k, n - k)
        if k == 0 { return 1 }
        var c = 1.0
        for i in 0..<k { c = c * Double(n - i) / Double(i + 1) }
        return c
    }

    /// `P(X ≥ k)` for `X ~ Binomial(n, 0.5)`, exact.
    public static func binomialUpperTail(k: Int, n: Int) -> Double {
        guard n >= 0 else { return .nan }
        guard k > 0 else { return 1 }
        guard k <= n else { return 0 }
        var sum = 0.0
        for i in k...n { sum += binomialCoefficient(n, i) }
        return sum / pow(2.0, Double(n))
    }

    /// Two-sided exact p for "does a binomial(n, 0.5) split as unevenly as `k` out of `n`",
    /// i.e. `min(1, 2 · P(X ≥ k))`. Used by both McNemar (k = max(b, c)) and the sign test.
    public static func exactTwoSidedSignP(k: Int, n: Int) -> Double {
        guard n > 0 else { return .nan }
        return min(1, 2 * binomialUpperTail(k: k, n: n))
    }

    /// The smallest majority-side count `k` (out of the given `n`) whose exact two-sided p is
    /// `≤ alpha` — "how lopsided would the same number of discordant windows need to be to reach
    /// significance". Nil when `n == 0` (there is nothing to split).
    public static func minorityNeededForSignificance(n: Int, alpha: Double = 0.05) -> Int? {
        guard n > 0 else { return nil }
        let start = n / 2 + 1   // smallest integer strictly greater than n/2
        guard start <= n else { return nil }
        for k in start...n where exactTwoSidedSignP(k: k, n: n) <= alpha { return k }
        return nil
    }

    // MARK: - McNemar

    public struct McNemarResult: Sendable {
        public var b: Int   // baseline accepted, candidate rejected
        public var c: Int   // baseline rejected, candidate accepted
        public var p: Double?  // nil iff b + c == 0
        /// Discordant count needed on the majority side, at n = b+c, to reach p ≤ 0.05. Nil iff b+c == 0.
        public var minorityNeededForSignificance: Int?
        public var net: Int { c - b }   // positive: candidate accepts more
    }

    public static func mcNemar(b: Int, c: Int, alpha: Double = 0.05) -> McNemarResult {
        let n = b + c
        guard n > 0 else { return McNemarResult(b: b, c: c, p: nil, minorityNeededForSignificance: nil) }
        let k = max(b, c)
        return McNemarResult(b: b, c: c, p: exactTwoSidedSignP(k: k, n: n),
                             minorityNeededForSignificance: minorityNeededForSignificance(n: n, alpha: alpha))
    }

    // MARK: - sign test on paired deltas

    public struct SignTestResult: Sendable {
        public var n: Int          // non-zero pairs only
        public var positive: Int   // candidate > baseline
        public var negative: Int   // candidate < baseline
        public var ties: Int
        public var p: Double?      // nil iff n == 0
    }

    /// Classic sign test: counts which side of zero each paired delta (`candidate − baseline`) falls
    /// on, drops exact ties, and runs the same exact binomial test as McNemar on what is left.
    /// Non-finite deltas (e.g. `.infinity − .infinity == .nan`, which happens when a metric like
    /// `gError` is deliberately `.infinity` in both arms — see `GravityGate.verdict`) are dropped
    /// before classification, never counted as ties: a tie means "measured no change", not "could
    /// not be compared".
    public static func signTest(_ deltas: [Double]) -> SignTestResult {
        var pos = 0, neg = 0, ties = 0
        for d in deltas where d.isFinite {
            if d > 0 { pos += 1 } else if d < 0 { neg += 1 } else { ties += 1 }
        }
        let n = pos + neg
        let p = n > 0 ? exactTwoSidedSignP(k: max(pos, neg), n: n) : nil
        return SignTestResult(n: n, positive: pos, negative: neg, ties: ties, p: p)
    }

    /// Median of `candidate − baseline` over paired values (both non-nil).
    public static func medianPairedDelta(_ pairs: [(base: Double, candidate: Double)]) -> Double? {
        median(pairs.map { $0.candidate - $0.base })
    }
}
