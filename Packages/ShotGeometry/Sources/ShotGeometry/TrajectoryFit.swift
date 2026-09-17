import Foundation

/// One ball observation in the shot plane: time (s), horizontal distance toward the rim (m),
/// height relative to the plane origin (m). `y` is **up**.
public struct TrajectorySample: Sendable, Equatable {
    public var t: Double
    public var x: Double
    public var y: Double
    public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
}

public enum TrajectoryFitError: Error, CustomStringConvertible, Sendable {
    case tooFewSamples(Int, minimum: Int)
    case spanTooShort(Double, minimum: Double)
    case singular
    case nonFiniteInput

    public var description: String {
        switch self {
        case .tooFewSamples(let n, let m): return "trajectory fit needs ≥ \(m) samples, got \(n)"
        case .spanTooShort(let s, let m): return String(format: "trajectory window spans %.3f s, need ≥ %.3f s", s, m)
        case .singular: return "trajectory design matrix is singular"
        case .nonFiniteInput: return "trajectory samples contain NaN/Inf"
        }
    }
}

/// Free-flight model fitted against time, evaluated at `anchorTime`:
///   x(t) = x0 + vx·τ,   y(t) = y0 + vy·τ − ½·g·τ²,   τ = t − anchorTime.
/// `g` is a *fitted* quantity: it is the check, not an input.
public struct TrajectoryFit: Sendable {
    public var anchorTime: Double
    public var x0: Double, vx: Double
    public var y0: Double, vy: Double
    public var g: Double
    public var n: Int
    public var nInliers: Int
    public var span: Double
    public var tFirst: Double, tLast: Double
    /// RMS of residuals over inliers, metres, per axis and pooled.
    public var rmsX: Double, rmsY: Double, rms: Double
    /// Per-sample robust weights (0 = rejected) in input order.
    public var weights: [Double]
    public var residualsX: [Double], residualsY: [Double]

    @inlinable public func position(at t: Double) -> SIMD2<Double> {
        let tau = t - anchorTime
        return SIMD2(x0 + vx * tau, y0 + vy * tau - 0.5 * g * tau * tau)
    }
    @inlinable public func velocity(at t: Double) -> SIMD2<Double> {
        SIMD2(vx, vy - g * (t - anchorTime))
    }
    /// Same parabola, re-anchored at a different time. The curve does not change.
    public func reanchored(at t: Double) -> TrajectoryFit {
        var f = self
        let p = position(at: t), v = velocity(at: t)
        f.anchorTime = t; f.x0 = p.x; f.y0 = p.y; f.vx = v.x; f.vy = v.y
        return f
    }
    public var timeOfApex: Double { anchorTime + vy / g }
    public var releaseAngle: Double { atan2(vy, vx) }
    public var releaseSpeed: Double { (vx * vx + vy * vy).squareRoot() }
    public var gError: Double { abs(g - Court.g) / Court.g }
}

public struct TrajectoryFitOptions: Sendable {
    public var robust: Bool = true
    public var minimumSamples: Int = 6
    public var minimumSpan: Double = 0.15
    /// Huber threshold in robust σ units.
    public var huberK: Double = 1.5
    /// Hard rejection threshold in robust σ units.
    public var rejectK: Double = 4.0
    public var iterations: Int = 6
    /// Floor for the robust scale, metres (prevents zero-weighting exact synthetic data).
    public var sigmaFloor: Double = 1e-4
    /// When set, the curvature is held at −½·fixedG and only (x0, vx, y0, vy) are fitted. Used for
    /// window detection, where a known g makes extrapolation far more stable; never for the final
    /// fit, whose free g is the check.
    public var fixedG: Double? = nil
    public init() {}
}

public enum TrajectoryFitter {
    public static func fit(_ samples: [TrajectorySample], anchorTime: Double,
                           options: TrajectoryFitOptions = .init()) throws -> TrajectoryFit {
        try fit(samples[...], anchorTime: anchorTime, options: options)
    }

    /// The same fit on a slice. The flight-window search fits a window starting at *every* sample, so
    /// it used to copy a sub-array per window; a slice is the same samples without the copy.
    public static func fit(_ samples: ArraySlice<TrajectorySample>, anchorTime: Double,
                           options: TrajectoryFitOptions = .init()) throws -> TrajectoryFit {
        let n = samples.count
        guard n >= options.minimumSamples else { throw TrajectoryFitError.tooFewSamples(n, minimum: options.minimumSamples) }
        // One pass for the finiteness check, the time span and the three working columns: the five
        // `map`s this replaces allocated five arrays per fit, and a fit runs once per window.
        let base = samples.startIndex
        var tMin = Double.infinity, tMax = -Double.infinity
        var tau = [Double](repeating: 0, count: n)
        var xs = [Double](repeating: 0, count: n), ys = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let s = samples[base + i]
            guard s.t.isFinite, s.x.isFinite, s.y.isFinite else { throw TrajectoryFitError.nonFiniteInput }
            tau[i] = s.t - anchorTime; xs[i] = s.x; ys[i] = s.y
            if s.t < tMin { tMin = s.t }
            if s.t > tMax { tMax = s.t }
        }
        let tFirst = n == 0 ? 0 : tMin, tLast = n == 0 ? 0 : tMax
        let span = tLast - tFirst
        guard span >= options.minimumSpan else { throw TrajectoryFitError.spanTooShort(span, minimum: options.minimumSpan) }

        var w = [Double](repeating: 1, count: n)
        var lin = Linear(c0: 0, c1: 0), quad = Quadratic(c0: 0, c1: 0, c2: 0)
        var rx = [Double](repeating: 0, count: n), ry = rx
        var yAdj = [Double](repeating: 0, count: options.fixedG == nil ? 0 : n)
        var absX = [Double](); absX.reserveCapacity(n)
        var absY = [Double](); absY.reserveCapacity(n)

        let iters = options.robust ? options.iterations : 1
        for it in 0..<iters {
            guard let l = PolyFit.linear(tau, xs, weights: w) else { throw TrajectoryFitError.singular }
            lin = l
            if let g = options.fixedG {
                for i in 0..<n { yAdj[i] = ys[i] + 0.5 * g * tau[i] * tau[i] }
                guard let ly = PolyFit.linear(tau, yAdj, weights: w) else { throw TrajectoryFitError.singular }
                quad = Quadratic(c0: ly.c0, c1: ly.c1, c2: -0.5 * g)
            } else {
                guard let q = PolyFit.quadratic(tau, ys, weights: w) else { throw TrajectoryFitError.singular }
                quad = q
            }
            for i in 0..<n { rx[i] = xs[i] - lin(tau[i]); ry[i] = ys[i] - quad(tau[i]) }
            if !options.robust || it == iters - 1 { break }
            // Robust per-axis scale: 1.4826 × median |r| over current inliers (MAD about zero).
            absX.removeAll(keepingCapacity: true); absY.removeAll(keepingCapacity: true)
            for i in 0..<n where w[i] > 0 { absX.append(abs(rx[i])); absY.append(abs(ry[i])) }
            let sigmaX = max(1.4826 * Stats.median(absX), options.sigmaFloor)
            let sigmaY = max(1.4826 * Stats.median(absY), options.sigmaFloor)
            var newW = [Double](repeating: 1, count: n)
            for i in 0..<n {
                let nx = rx[i] / sigmaX, ny = ry[i] / sigmaY
                let r = (nx * nx + ny * ny).squareRoot()
                if r > options.rejectK { newW[i] = 0 }
                else if r > options.huberK { newW[i] = options.huberK / r }
            }
            var inliers = 0
            for v in newW where v > 0 { inliers += 1 }
            if inliers < options.minimumSamples { break }   // do not reject ourselves into nothing
            var change = 0.0
            for i in 0..<n { change = max(change, abs(newW[i] - w[i])) }
            w = newW
            if change < 1e-6 { break }
        }

        // The three RMS figures in one pass, accumulated in the order the `map`/`flatMap` versions
        // produced (x then y per inlier), so every sum is the same sum.
        var nIn = 0, sumX = 0.0, sumY = 0.0, sumBoth = 0.0
        for i in 0..<n where w[i] > 0 {
            nIn += 1
            sumX += rx[i] * rx[i]
            sumY += ry[i] * ry[i]
            sumBoth += rx[i] * rx[i]
            sumBoth += ry[i] * ry[i]
        }
        let rmsX = nIn == 0 ? Double.nan : (sumX / Double(nIn)).squareRoot()
        let rmsY = nIn == 0 ? Double.nan : (sumY / Double(nIn)).squareRoot()
        let rms = nIn == 0 ? Double.nan : (sumBoth / Double(2 * nIn)).squareRoot()
        return TrajectoryFit(anchorTime: anchorTime, x0: lin.c0, vx: lin.c1, y0: quad.c0, vy: quad.c1, g: -2 * quad.c2,
                             n: n, nInliers: nIn, span: span,
                             tFirst: tFirst, tLast: tLast,
                             rmsX: rmsX, rmsY: rmsY, rms: rms, weights: w, residualsX: rx, residualsY: ry)
    }
}
