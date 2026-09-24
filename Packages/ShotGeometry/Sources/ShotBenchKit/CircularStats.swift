// Circular statistics for the shot-plane azimuth, and the robust pooled-azimuth estimator the
// `pooled*` variants use.
//
// Why circular and not ordinary statistics: `ShotPlaneSolver.solveByFixedGravity` scans the whole
// 0…2π circle and disambiguates the mirror plane by the "shooter at negative x" convention, so a
// per-shot azimuth is an angle on the full circle, not a number on a line. 359° and 1° are 2°
// apart, not 358°, and a mean/median/SD computed on the raw numbers would be wrong near the wrap
// point — which is exactly where the 2026-09-13 corpus's azimuths sit for two of the three clips.
//
// Foundation + ShotGeometry only (this target may not import anything else; see Package.swift);
// `Angle` comes from ShotGeometry.
import Foundation
import ShotGeometry

public enum CircularStats {

    /// Wrap an angle to (−π, π].
    public static func wrap(_ x: Double) -> Double {
        let y = atan2(sin(x), cos(x))
        return y
    }

    /// Wrap to [0, 2π).
    public static func wrapPositive(_ x: Double) -> Double {
        let twoPi = 2 * Double.pi
        var y = x.truncatingRemainder(dividingBy: twoPi)
        if y < 0 { y += twoPi }
        if y >= twoPi { y -= twoPi }       // guards the (−1e-17).truncatingRemainder → 2π rounding case
        return y
    }

    /// Shortest angular distance between two angles, in [0, π].
    public static func distance(_ a: Double, _ b: Double) -> Double { abs(wrap(a - b)) }

    /// Mean resultant length R̄ ∈ [0, 1]: 1 = perfectly concentrated, 0 = uniformly spread.
    public static func resultantLength(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let c = xs.map(cos).reduce(0, +) / Double(xs.count)
        let s = xs.map(sin).reduce(0, +) / Double(xs.count)
        return (c * c + s * s).squareRoot()
    }

    /// Circular mean (the direction of the resultant). Nil for an empty sample or one whose
    /// resultant vanishes (e.g. two exactly antipodal angles) — there is no mean direction to
    /// report there, and inventing one would be fabricating a number.
    public static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let c = xs.map(cos).reduce(0, +), s = xs.map(sin).reduce(0, +)
        guard (c * c + s * s).squareRoot() / Double(xs.count) > 1e-9 else { return nil }
        return atan2(s, c)
    }

    /// Total circular distance from `c` to every sample — the objective the circular median minimises.
    static func totalDistance(_ xs: [Double], to c: Double) -> Double {
        xs.reduce(0) { $0 + distance($1, c) }
    }

    /// Circular median: the angle minimising Σ |wrap(xᵢ − c)|.
    ///
    /// The objective is piecewise linear in `c` with kinks at the data points (slope jumps by +2)
    /// and at their antipodes (slope jumps by −2), so every *local minimum* is at a data point, and
    /// a flat minimum runs between two data points (the even-n case). Candidates are therefore the
    /// data points plus the midpoint of each circularly adjacent pair, which is complete. When the
    /// minimum is flat (the even-n case) the **midpoint of the flat arc** is returned — the ordinary
    /// even-n median convention, computed on the circle so it is right at the wrap point too
    /// ({350°, 355°, 5°, 10°} ⇒ 0°, not 177.5°). That makes the result symmetric in the data and
    /// independent of input order.
    ///
    /// Nil for an empty sample. n = 1 returns that sample; n = 2 returns the midpoint of the short
    /// arc (and, for exactly antipodal pairs, one of the two equally valid midpoints — documented,
    /// not meaningful, and `mean` refuses that configuration outright).
    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        if xs.count == 1 { return wrap(xs[0]) }
        let sorted = xs.map(wrapPositive).sorted()
        var candidates = sorted
        for i in 0..<sorted.count {
            let a = sorted[i], b = sorted[(i + 1) % sorted.count]
            let gap = wrapPositive(b - a)                    // forward arc a → b
            candidates.append(wrapPositive(a + gap / 2))
        }
        let costs = candidates.map { totalDistance(xs, to: $0) }
        guard let minimum = costs.min() else { return nil }
        // Tolerance scaled by n: the cost is a sum of n angles, so its rounding error grows with n.
        let tol = 1e-9 * Double(xs.count)
        let minimisers = zip(candidates, costs).filter { $0.1 <= minimum + tol }.map(\.0).sorted()
        if minimisers.count == 1 { return wrap(minimisers[0]) }
        // The minimisers form one contiguous arc (possibly wrapping): find the widest gap between
        // circularly adjacent minimisers — the arc is everything else — and take its midpoint.
        var gapIndex = 0, widest = -1.0
        for i in 0..<minimisers.count {
            let gap = wrapPositive(minimisers[(i + 1) % minimisers.count] - minimisers[i])
            if gap > widest { widest = gap; gapIndex = i }
        }
        let start = minimisers[(gapIndex + 1) % minimisers.count]
        let end = minimisers[gapIndex]
        return wrap(start + wrapPositive(end - start) / 2)
    }

    /// Median absolute (circular) deviation about `center`, radians.
    public static func medianAbsoluteDeviation(_ xs: [Double], about center: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        return BenchStats.median(xs.map { distance($0, center) })
    }

    /// Largest circular deviation from `center`, radians.
    public static func maxDeviation(_ xs: [Double], about center: Double) -> Double? {
        xs.map { distance($0, center) }.max()
    }

    /// Circular standard deviation, radians: √(−2·ln R̄) (Mardia). Reported for diagnosis only —
    /// the pooling rules use MAD, which a single wild outlier cannot inflate the same way.
    public static func standardDeviation(_ xs: [Double]) -> Double? {
        guard xs.count >= 2 else { return nil }
        let r = resultantLength(xs)
        guard r > 1e-12 else { return nil }
        return (-2 * log(min(r, 1))).squareRoot()
    }
}

/// Knobs for the robust pooled azimuth. Defaults are the rule stated in `AzimuthPooling.robust`.
public struct RobustPoolConfig: Sendable, Equatable {
    /// Drop a per-shot azimuth farther than `outlierK · 1.4826 · MAD` from the first-pass centre.
    public var outlierK: Double
    /// …but never tighter than this, so a pathologically concentrated core (MAD ≈ 0, which happens
    /// when several windows land on the same coarse grid point) cannot reject shots that agree to
    /// within a couple of degrees.
    public var outlierFloorDegrees: Double
    /// Minimum surviving windows before a clip may be pooled at all.
    public var minimumWindows: Int
    /// Optional agreement gate, on the *robust* scale estimate (1.4826 · MAD, degrees) rather than
    /// on a raw maximum spread. Nil = pool whatever the clip gives (the outlier rule is then the
    /// only defence).
    public var maximumScaledMADDegrees: Double?
    public init(outlierK: Double = 3, outlierFloorDegrees: Double = 4, minimumWindows: Int = 5,
                maximumScaledMADDegrees: Double? = nil) {
        self.outlierK = outlierK; self.outlierFloorDegrees = outlierFloorDegrees
        self.minimumWindows = minimumWindows; self.maximumScaledMADDegrees = maximumScaledMADDegrees
    }
}

/// What a pooling attempt did, kept for the scorecard's notes and the diagnosis dump. Reported
/// whether or not the pool was accepted, so a refusal can say *why* with numbers.
public struct PoolDiagnostics: Codable, Sendable {
    public var clip: String
    public var strategy: String
    public var inputCount: Int
    public var keptCount: Int
    public var droppedCount: Int
    public var centerDegrees: Double?
    public var scaledMADDegrees: Double?
    public var maxDeviationDegrees: Double?
    public var resultantLength: Double?
    public var engaged: Bool
    public var reason: String
    public var iterations: Int?
    public var iterationShiftsDegrees: [Double]?
}

public enum AzimuthPooling {

    /// Split angles into clusters by circular gap: sort them round the circle and cut wherever the
    /// gap to the next value exceeds `gapDegrees`. Returns the clusters in descending size order.
    ///
    /// Needed because "one filming block = one azimuth" is an assumption, not a fact: on the
    /// 2026-09-13 corpus the free-throw clip's per-shot azimuths form two well-populated modes ~50°
    /// apart that alternate shot by shot, and pooling them into one number puts half the shots on
    /// the wrong plane. Clustering first lets a clip that really does hold two shooting positions
    /// be pooled as two.
    public static func clusters(_ values: [Double], gapDegrees: Double) -> [[Double]] {
        guard !values.isEmpty else { return [] }
        let sorted = values.map(CircularStats.wrapPositive).sorted()
        if sorted.count == 1 { return [sorted] }
        let gap = Angle.radians(gapDegrees)
        // Find every cut point (a forward gap wider than `gap`), then walk the circle from one.
        var cuts: [Int] = []
        for i in 0..<sorted.count {
            let next = sorted[(i + 1) % sorted.count]
            if CircularStats.wrapPositive(next - sorted[i]) > gap { cuts.append(i) }
        }
        if cuts.isEmpty { return [sorted] }               // one cluster wrapping the whole circle
        var out: [[Double]] = []
        for (j, cut) in cuts.enumerated() {
            let start = (cut + 1) % sorted.count
            let end = cuts[(j + 1) % cuts.count]          // inclusive
            var group: [Double] = []
            var i = start
            while true {
                group.append(sorted[i])
                if i == end { break }
                i = (i + 1) % sorted.count
            }
            out.append(group)
        }
        return out.sorted { $0.count > $1.count }
    }

    /// The outlier rule, stated once:
    ///
    ///  1. `c₀` = circular median of every per-shot azimuth offered for the clip;
    ///  2. `MAD` = median circular distance to `c₀`; `s = 1.4826 · MAD` is its σ-comparable scale
    ///     (the usual consistency factor for a normal core — a wrapped normal at these spreads);
    ///  3. drop every value farther than `max(k · s, floor)` from `c₀`;
    ///  4. `c` = circular median of the survivors.
    ///
    /// The median (not the mean) at both steps is the point: on this corpus a per-shot azimuth can
    /// land on a completely wrong branch, and one such value drags a circular *mean* by tens of
    /// degrees while moving a circular median not at all.
    ///
    /// Returns nil only for an empty input. `engaged` says whether the gates (`minimumWindows`,
    /// `maximumScaledMADDegrees`) passed; the numbers are filled in either way so a refusal is
    /// reportable.
    public static func robust(_ values: [Double], clip: String = "", strategy: String = "robust",
                              config: RobustPoolConfig = RobustPoolConfig()) -> (center: Double, kept: [Double], diagnostics: PoolDiagnostics)? {
        guard !values.isEmpty, let c0 = CircularStats.median(values) else { return nil }
        let mad = CircularStats.medianAbsoluteDeviation(values, about: c0) ?? 0
        let scaled = 1.4826 * mad
        let cutoff = max(config.outlierK * scaled, Angle.radians(config.outlierFloorDegrees))
        let kept = values.filter { CircularStats.distance($0, c0) <= cutoff }
        let dropped = values.count - kept.count
        guard let center = CircularStats.median(kept.isEmpty ? values : kept) else { return nil }
        let keptValues = kept.isEmpty ? values : kept
        let keptMAD = CircularStats.medianAbsoluteDeviation(keptValues, about: center) ?? 0
        let keptScaledDegrees = Angle.degrees(1.4826 * keptMAD)
        let maxDev = CircularStats.maxDeviation(keptValues, about: center) ?? 0

        var engaged = true
        var reason = "pooled"
        if keptValues.count < config.minimumWindows {
            engaged = false
            reason = "only \(keptValues.count) usable per-shot azimuth(s) after the outlier rule; need \(config.minimumWindows)"
        } else if let maxMAD = config.maximumScaledMADDegrees, keptScaledDegrees > maxMAD {
            engaged = false
            reason = String(format: "robust spread 1.4826·MAD = %.1f° > %.1f° agreement gate", keptScaledDegrees, maxMAD)
        }
        let diag = PoolDiagnostics(clip: clip, strategy: strategy, inputCount: values.count, keptCount: keptValues.count,
                                   droppedCount: dropped, centerDegrees: Angle.degrees(CircularStats.wrapPositive(center)),
                                   scaledMADDegrees: keptScaledDegrees, maxDeviationDegrees: Angle.degrees(maxDev),
                                   resultantLength: CircularStats.resultantLength(keptValues), engaged: engaged, reason: reason,
                                   iterations: nil, iterationShiftsDegrees: nil)
        return (center, keptValues, diag)
    }
}
