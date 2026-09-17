import Foundation

/// Where a shot crossed the rim plane, in rim coordinates. Metres.
/// `along` is measured from the rim centre in the flight direction (positive = long), `lateral` sideways.
public struct RimCrossing: Sendable, Equatable {
    public var along: Double
    public var lateral: Double
    public var entryAngle: Double   // rad below horizontal
    public init(along: Double, lateral: Double, entryAngle: Double) {
        self.along = along; self.lateral = lateral; self.entryAngle = entryAngle
    }
    public init(depthPastFrontRim: Double, lateral: Double, entryAngle: Double) {
        self.init(along: depthPastFrontRim - Court.rimInnerRadius, lateral: lateral, entryAngle: entryAngle)
    }
}

/// Make probability as a function of the rim crossing.
///
/// Two layers, kept separate on purpose:
/// 1. `cleanPass` is geometry (Tier A): does the swept ball miss the ring entirely? It is exact and needs no data,
///    but it is a *lower bound* on makes because most makes touch the ring. Simulation (2026-09-13) shows a
///    16 cm depth SD gives ~12 % clean passes but ~45 % makes under a forgiving model, so never present it as xFG.
/// 2. `SoftMakeModel` is a parametric surface P(make | along, lateral) whose parameters must be fitted from the
///    player's tagged outcomes (or a published population prior). The default parameters are a placeholder shape.
public enum MakeGeometry {
    /// The ball, moving at `entryAngle`, sweeps an ellipse in the rim plane with semi-axes
    /// (d/2)/sin(entry) along the flight and d/2 across. The pass is clean iff that ellipse lies inside the ring.
    public static func cleanPass(_ c: RimCrossing, ballDiameter: Double = BallSize.size7.diameter,
                                 rimDiameter: Double = Court.rimInnerDiameter) -> Bool {
        ringExcess(c, ballDiameter: ballDiameter, rimDiameter: rimDiameter) <= 0
    }

    /// How far (m) the swept ellipse pokes outside the ring; ≤ 0 means a clean pass.
    public static func ringExcess(_ c: RimCrossing, ballDiameter: Double = BallSize.size7.diameter,
                                  rimDiameter: Double = Court.rimInnerDiameter, samples: Int = 72) -> Double {
        let s = max(sin(c.entryAngle), 1e-3)
        let a = ballDiameter / 2 / s, b = ballDiameter / 2, R = rimDiameter / 2
        var worst = -Double.infinity
        for i in 0..<samples {
            let p = 2 * .pi * Double(i) / Double(samples)
            let x = c.along + a * cos(p), y = c.lateral + b * sin(p)
            worst = max(worst, (x * x + y * y).squareRoot() - R)
        }
        return worst
    }
}

/// Parametric make surface. P = pMax · exp(−((along − idealAlong)/widthAlong)² − (lateral/widthLateral)²).
/// Fit `pMax`, `idealAlong`, `widthAlong`, `widthLateral` from tagged shots; the defaults are a placeholder
/// shape chosen so that a 9 cm depth SD gives ~63 % and a 17 cm SD ~46 % at the free-throw line.
public struct SoftMakeModel: Sendable, Equatable, Codable {
    public var pMax: Double = 0.92
    public var idealAlong: Double = 0.03        // m past rim centre (published NBA optimum is ~5 cm past centre)
    public var widthAlong: Double = 0.16
    public var widthLateral: Double = 0.12
    public var isFitted: Bool = false           // false = placeholder shape; the UI must say so
    public init() {}

    public func probability(_ c: RimCrossing) -> Double {
        let x = (c.along - idealAlong) / widthAlong, y = c.lateral / widthLateral
        return pMax * exp(-x * x - y * y)
    }

    /// Expected makes per 100 for a set of crossings. Missing crossings (nil) count as zero.
    public func expectedMakesPer100(_ crossings: [RimCrossing?]) -> Double {
        guard !crossings.isEmpty else { return 0 }
        return 100 * crossings.map { $0.map(probability) ?? 0 }.reduce(0, +) / Double(crossings.count)
    }
}

/// Local sensitivities of the rim crossing to the release variables, by central differences on `Physics.forward`.
/// Units: metres per radian, per m/s, per metre. Evaluate at the player's cell mean (Ch 5: J at the mean).
public struct ReleaseSensitivity: Sendable {
    public var dDepth_dTheta: Double
    public var dDepth_dV: Double
    public var dDepth_dH: Double
    public var dEntry_dTheta: Double
    public var dEntry_dV: Double
    public var dEntry_dH: Double

    public static func at(theta: Double, v: Double, h: Double, L: Double) -> ReleaseSensitivity? {
        func f(_ th: Double, _ vv: Double, _ hh: Double) -> (Double, Double)? {
            Physics.forward(theta: th, v: vv, h: hh, L: L).map { ($0.entry, $0.depth) }
        }
        let dth = 1e-4, dv = 1e-3, dh = 1e-3
        guard let tp = f(theta + dth, v, h), let tm = f(theta - dth, v, h),
              let vp = f(theta, v + dv, h), let vm = f(theta, v - dv, h),
              let hp = f(theta, v, h + dh), let hm = f(theta, v, h - dh) else { return nil }
        return ReleaseSensitivity(
            dDepth_dTheta: (tp.1 - tm.1) / (2 * dth), dDepth_dV: (vp.1 - vm.1) / (2 * dv), dDepth_dH: (hp.1 - hm.1) / (2 * dh),
            dEntry_dTheta: (tp.0 - tm.0) / (2 * dth), dEntry_dV: (vp.0 - vm.0) / (2 * dv), dEntry_dH: (hp.0 - hm.0) / (2 * dh))
    }

    /// Release angle at which depth stops depending on release angle (∂depth/∂θ = 0): above it, "steeper when
    /// harder" compensates; below it, "flatter when harder" does. Bisection on θ ∈ [35°, 70°].
    public static func depthTurnoverAngle(v: Double, h: Double, L: Double) -> Double? {
        // Scan for a sign change of ∂depth/∂θ over [35°, 65°] (some ends give no rim crossing), then bisect.
        var lo: Double? = nil, hi: Double? = nil
        var th = Angle.radians(35)
        var prev: (Double, Double)? = nil
        while th <= Angle.radians(65) {
            if let s = at(theta: th, v: v, h: h, L: L)?.dDepth_dTheta {
                if let (pth, ps) = prev, ps > 0, s < 0 { lo = pth; hi = th; break }
                prev = (th, s)
            }
            th += Angle.radians(1)
        }
        guard var a = lo, var b = hi else { return nil }
        for _ in 0..<50 {
            let mid = (a + b) / 2
            guard let s = at(theta: mid, v: v, h: h, L: L)?.dDepth_dTheta else { return nil }
            if s > 0 { a = mid } else { b = mid }
        }
        return (a + b) / 2
    }
}

/// Delta-method variance decomposition of depth (Ch 5). Inputs are the cell's covariance of (θ rad, v m/s, h m).
public struct DepthVarianceAttribution: Sendable {
    public var totalVariance: Double                 // m²
    public var thetaShare: Double, speedShare: Double, heightShare: Double, covarianceShare: Double   // fractions, sum to 1
    public var sdDepth: Double { totalVariance.squareRoot() }

    public static func compute(sensitivity s: ReleaseSensitivity, covariance c: [[Double]]) -> DepthVarianceAttribution? {
        guard c.count == 3, c.allSatisfy({ $0.count == 3 }) else { return nil }
        let J = [s.dDepth_dTheta, s.dDepth_dV, s.dDepth_dH]
        var total = 0.0
        for i in 0..<3 { for j in 0..<3 { total += J[i] * J[j] * c[i][j] } }
        guard total > 0 else { return nil }
        let parts = (0..<3).map { J[$0] * J[$0] * c[$0][$0] / total }
        return DepthVarianceAttribution(totalVariance: total, thetaShare: parts[0], speedShare: parts[1], heightShare: parts[2],
                                        covarianceShare: 1 - parts.reduce(0, +))
    }
}
