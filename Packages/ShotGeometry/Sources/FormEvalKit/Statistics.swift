// Statistics for the form-evaluation harness (Track D, 1.3).
//
// Foundation only — the same rule `Packages/ShotGeometry` lives under. Every estimator here is
// named with its own formula in the doc comment, because a reliability number whose definition is
// not written down is not a measurement, it is a mood.
import Foundation

public enum EvalStats {

    // MARK: - order statistics

    /// Order statistic with linear interpolation between neighbours — the "type 7" definition, which
    /// is what `numpy.percentile` and R's default `quantile` return, so a p90 printed here means the
    /// same thing as a p90 printed by the Python scratch scripts. `p` is a fraction in [0, 1].
    public static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        let v = xs.filter(\.isFinite).sorted()
        guard !v.isEmpty else { return nil }
        if v.count == 1 { return v[0] }
        let h = (Double(v.count) - 1) * min(max(p, 0), 1)
        let lo = Int(h.rounded(.down)), hi = min(lo + 1, v.count - 1)
        return v[lo] + (h - Double(lo)) * (v[hi] - v[lo])
    }

    public static func median(_ xs: [Double]) -> Double? { percentile(xs, 0.5) }

    public static func mean(_ xs: [Double]) -> Double? {
        let v = xs.filter(\.isFinite)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    /// Sample standard deviation (ddof = 1). Nil for fewer than two finite values — an SD from one
    /// number is not zero, it is unknown.
    public static func sd(_ xs: [Double]) -> Double? {
        let v = xs.filter(\.isFinite)
        guard v.count >= 2, let m = mean(v) else { return nil }
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1)).squareRoot()
    }

    public static func rms(_ xs: [Double]) -> Double? {
        let v = xs.filter(\.isFinite)
        guard !v.isEmpty else { return nil }
        return (v.reduce(0) { $0 + $1 * $1 } / Double(v.count)).squareRoot()
    }

    // MARK: - ICC

    /// One intraclass-correlation estimate, with everything needed to audit it.
    public struct ICCResult: Sendable, Codable, Equatable {
        /// ICC(2,1): two-way random effects, **absolute agreement**, single measurement.
        public var value: Double?
        /// ICC(3,1): two-way mixed, **consistency**, single measurement. Reported beside (2,1)
        /// because the gap between the two *is* the systematic offset between the raters.
        public var consistency: Double?
        public var lower95: Double?
        public var upper95: Double?
        public var subjects: Int
        public var raters: Int
        public var meanSquareSubjects: Double?
        public var meanSquareRaters: Double?
        public var meanSquareError: Double?
        /// How many bootstrap resamples produced a finite ICC (the CI is a percentile of those).
        public var bootstrapSamples: Int
        public var unavailableReason: String?

        public init(value: Double? = nil, consistency: Double? = nil, lower95: Double? = nil, upper95: Double? = nil,
                    subjects: Int = 0, raters: Int = 0, meanSquareSubjects: Double? = nil,
                    meanSquareRaters: Double? = nil, meanSquareError: Double? = nil,
                    bootstrapSamples: Int = 0, unavailableReason: String? = nil) {
            self.value = value; self.consistency = consistency; self.lower95 = lower95; self.upper95 = upper95
            self.subjects = subjects; self.raters = raters
            self.meanSquareSubjects = meanSquareSubjects; self.meanSquareRaters = meanSquareRaters
            self.meanSquareError = meanSquareError; self.bootstrapSamples = bootstrapSamples
            self.unavailableReason = unavailableReason
        }
    }

    /// The two-way ANOVA mean squares of an `n × k` complete table (rows = subjects, columns = raters).
    ///
    ///     MSR = k·Σ(row̄ᵢ − grand)² / (n − 1)
    ///     MSC = n·Σ(col̄ⱼ − grand)² / (k − 1)
    ///     MSE = (SST − SSR − SSC) / ((n − 1)(k − 1))
    public static func twoWayMeanSquares(_ rows: [[Double]]) -> (msr: Double, msc: Double, mse: Double, n: Int, k: Int)? {
        guard let k = rows.first?.count, k >= 2, rows.count >= 2,
              rows.allSatisfy({ $0.count == k && $0.allSatisfy(\.isFinite) }) else { return nil }
        let n = rows.count
        let grand = rows.reduce(0) { $0 + $1.reduce(0, +) } / Double(n * k)
        let rowMeans = rows.map { $0.reduce(0, +) / Double(k) }
        var colMeans = [Double](repeating: 0, count: k)
        for r in rows { for j in 0..<k { colMeans[j] += r[j] } }
        for j in 0..<k { colMeans[j] /= Double(n) }
        let ssr = Double(k) * rowMeans.reduce(0) { $0 + ($1 - grand) * ($1 - grand) }
        let ssc = Double(n) * colMeans.reduce(0) { $0 + ($1 - grand) * ($1 - grand) }
        var sst = 0.0
        for r in rows { for x in r { sst += (x - grand) * (x - grand) } }
        let sse = max(0, sst - ssr - ssc)
        return (ssr / Double(n - 1), ssc / Double(k - 1), sse / Double((n - 1) * (k - 1)), n, k)
    }

    /// ICC(2,1) — two-way random effects, absolute agreement, single measurement (Shrout & Fleiss
    /// 1979; McGraw & Wong 1996 form):
    ///
    ///     ICC(2,1) = (MSR − MSE) / (MSR + (k−1)·MSE + k·(MSC − MSE)/n)
    ///
    /// Rows are subjects, columns are the repeated measurements of that subject. The **absolute**
    /// form is the one this project wants: two analyses that differ by a constant bias do not agree,
    /// and a reliability number that forgives a constant bias would hide exactly the failure mode a
    /// biometrics change introduces. `consistency` (ICC(3,1) = (MSR − MSE)/(MSR + (k−1)·MSE)) is
    /// returned beside it so the size of that bias is visible.
    ///
    /// The 95 % interval is a **percentile bootstrap over subjects** (deterministic, seeded), not the
    /// F-distribution interval: it makes no normality claim, and with 20–40 shots it is the honest
    /// width. Nil interval when fewer than 100 resamples produced a finite estimate.
    public static func icc21(_ rows: [[Double]], bootstrap: Int = 2000, seed: UInt64 = 0x5EED_1234_ABCD_0001) -> ICCResult {
        guard let k = rows.first?.count else {
            return ICCResult(unavailableReason: "no rows: an ICC needs at least two subjects measured at least twice")
        }
        guard rows.count >= 2 else {
            return ICCResult(subjects: rows.count, raters: k,
                             unavailableReason: "\(rows.count) subject(s): an ICC needs at least two")
        }
        guard k >= 2, rows.allSatisfy({ $0.count == k && $0.allSatisfy(\.isFinite) }) else {
            return ICCResult(subjects: rows.count, raters: k,
                             unavailableReason: "the table is ragged or carries a non-finite value; an ICC needs a complete n×k table")
        }
        guard let point = iccPair(rows) else {
            return ICCResult(subjects: rows.count, raters: k,
                             unavailableReason: "every measurement is identical, so there is no variance to partition")
        }
        var lo: Double? = nil, hi: Double? = nil, used = 0
        if bootstrap > 0 {
            var rng = SplitMix64(seed: seed)
            var draws: [Double] = []
            draws.reserveCapacity(bootstrap)
            for _ in 0..<bootstrap {
                var sample: [[Double]] = []
                sample.reserveCapacity(rows.count)
                for _ in 0..<rows.count { sample.append(rows[Int(rng.next() % UInt64(rows.count))]) }
                if let v = iccPair(sample)?.icc, v.isFinite { draws.append(v) }
            }
            used = draws.count
            if used >= 100 { lo = percentile(draws, 0.025); hi = percentile(draws, 0.975) }
        }
        let ms = twoWayMeanSquares(rows)
        return ICCResult(value: point.icc, consistency: point.consistency, lower95: lo, upper95: hi,
                         subjects: rows.count, raters: k,
                         meanSquareSubjects: ms?.msr, meanSquareRaters: ms?.msc, meanSquareError: ms?.mse,
                         bootstrapSamples: used)
    }

    private static func iccPair(_ rows: [[Double]]) -> (icc: Double, consistency: Double)? {
        guard let (msr, msc, mse, n, k) = twoWayMeanSquares(rows) else { return nil }
        let denom = msr + Double(k - 1) * mse + Double(k) * (msc - mse) / Double(n)
        let consistencyDenom = msr + Double(k - 1) * mse
        guard denom > 1e-12, consistencyDenom > 1e-12 else { return nil }
        return ((msr - mse) / denom, (msr - mse) / consistencyDenom)
    }

    // MARK: - repeatability

    /// What a repeated measurement of one athlete's one movement can and cannot tell apart.
    public struct RepeatabilityResult: Sendable, Codable, Equatable {
        public var measure: String
        public var unit: String
        /// Shots that produced the measure on the full-rate fit *and* on both half-rate refits.
        public var n: Int
        public var mean: Double?
        /// SD of the full-rate value across the session's shots: athlete variation *plus* measurement noise.
        public var betweenShotSD: Double?
        public var cvPercent: Double?
        /// Measurement SD of a single analysis, from the paired half-rate refits:
        /// σ_meas = √(Σd²/2n), d = even-frame value − odd-frame value.
        public var measurementSD: Double?
        /// 1.96·√2·σ_meas — below this, two analyses of the same movement are not distinguishable.
        public var smallestDetectableChange: Double?
        /// max(0, 1 − σ²_meas / σ²_betweenShot): the share of the shot-to-shot spread that is not
        /// measurement noise. 1.0 means every wobble you see is the athlete; 0 means none of it is.
        public var reliability: Double?
        /// ICC(2,1) with shots as subjects and the two half-rate refits as the repeated measurements.
        public var icc: ICCResult
        public var unavailableReason: String?

        public init(measure: String, unit: String, n: Int, mean: Double?, betweenShotSD: Double?,
                    cvPercent: Double?, measurementSD: Double?, smallestDetectableChange: Double?,
                    reliability: Double?, icc: ICCResult, unavailableReason: String?) {
            self.measure = measure; self.unit = unit; self.n = n; self.mean = mean
            self.betweenShotSD = betweenShotSD; self.cvPercent = cvPercent
            self.measurementSD = measurementSD; self.smallestDetectableChange = smallestDetectableChange
            self.reliability = reliability; self.icc = icc; self.unavailableReason = unavailableReason
        }
    }

    /// `full` is the value from the whole-rate fit, `a`/`b` the two half-rate refits of the same shot.
    /// Every array is one entry per shot and they must be the same length.
    public static func repeatability(measure: String, unit: String,
                                     full: [Double], a: [Double], b: [Double],
                                     bootstrap: Int = 2000) -> RepeatabilityResult {
        guard full.count == a.count, a.count == b.count else {
            return RepeatabilityResult(measure: measure, unit: unit, n: 0, mean: nil, betweenShotSD: nil,
                                       cvPercent: nil, measurementSD: nil, smallestDetectableChange: nil,
                                       reliability: nil, icc: ICCResult(unavailableReason: "ragged input"),
                                       unavailableReason: "the three per-shot arrays are different lengths")
        }
        guard full.count >= 2 else {
            return RepeatabilityResult(measure: measure, unit: unit, n: full.count, mean: mean(full),
                                       betweenShotSD: nil, cvPercent: nil, measurementSD: nil,
                                       smallestDetectableChange: nil, reliability: nil,
                                       icc: ICCResult(subjects: full.count, raters: 2,
                                                      unavailableReason: "fewer than two shots carried this measure"),
                                       unavailableReason: "fewer than two shots carried this measure on every fit")
        }
        let m = mean(full), between = sd(full)
        let diffs = zip(a, b).map { $0 - $1 }
        // σ_meas is the SD of ONE measurement, so the paired differences (variance 2σ²) are halved.
        let sigma = (diffs.reduce(0) { $0 + $1 * $1 } / Double(2 * diffs.count)).squareRoot()
        let reliability: Double? = {
            guard let bs = between, bs > 1e-12 else { return nil }
            return max(0, 1 - (sigma * sigma) / (bs * bs))
        }()
        let cv: Double? = {
            guard let m, abs(m) > 1e-12, let bs = between else { return nil }
            return 100 * bs / abs(m)
        }()
        return RepeatabilityResult(measure: measure, unit: unit, n: full.count, mean: m, betweenShotSD: between,
                                   cvPercent: cv, measurementSD: sigma,
                                   smallestDetectableChange: 1.96 * 2.0.squareRoot() * sigma,
                                   reliability: reliability,
                                   icc: icc21(zip(a, b).map { [$0, $1] }, bootstrap: bootstrap),
                                   unavailableReason: nil)
    }
}

/// A small, deterministic PRNG so a bootstrap interval printed today is the same interval tomorrow.
/// (Vigna's SplitMix64. Seeded explicitly; never `SystemRandomNumberGenerator`, which would make the
/// harness's own output unrepeatable.)
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
