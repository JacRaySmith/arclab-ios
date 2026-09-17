import Foundation

/// General conic `a·x² + b·xy + c·y² + d·x + e·y + f = 0`.
public struct Conic: Sendable, Equatable {
    public var a, b, c, d, e, f: Double
    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    /// Symmetric 3×3 matrix Q with pᵀ Q p = 0 for homogeneous p = (x, y, 1).
    public var matrix: [[Double]] {
        [[a, b / 2, d / 2], [b / 2, c, e / 2], [d / 2, e / 2, f]]
    }

    public init(matrix Q: [[Double]]) {
        a = Q[0][0]; b = 2 * Q[0][1]; c = Q[1][1]; d = 2 * Q[0][2]; e = 2 * Q[1][2]; f = Q[2][2]
    }

    @inlinable public func evaluate(_ p: SIMD2<Double>) -> Double {
        a * p.x * p.x + b * p.x * p.y + c * p.y * p.y + d * p.x + e * p.y + f
    }

    /// First-order geometric distance from a point to the conic (Sampson distance).
    public func sampsonDistance(_ p: SIMD2<Double>) -> Double {
        let F = evaluate(p)
        let gx = 2 * a * p.x + b * p.y + d
        let gy = b * p.x + 2 * c * p.y + e
        let g = (gx * gx + gy * gy).squareRoot()
        return g < 1e-300 ? abs(F) : abs(F) / g
    }

    /// Convert to ellipse parameters. Nil when the conic is not a real ellipse.
    public func ellipse() -> Ellipse? {
        var (A, B, C, D, E, F) = (a, b, c, d, e, f)
        // Quadratic form Q2 = [[A, B/2], [B/2, C]] must be positive definite for (p-c)ᵀQ2(p-c) = k.
        if A + C < 0 { A = -A; B = -B; C = -C; D = -D; E = -E; F = -F }
        let det = A * C - B * B / 4
        guard det > 0 else { return nil }
        // Centre: Q2 c = -(D/2, E/2)
        let cx = (-(D / 2) * C + (B / 2) * (E / 2)) / det
        let cy = (-(E / 2) * A + (B / 2) * (D / 2)) / det
        // (p-c)ᵀ Q2 (p-c) = k with k = cᵀ Q2 c − F
        let k = A * cx * cx + B * cx * cy + C * cy * cy - F
        guard k > 0 else { return nil }
        let eig = LinAlg.eigen2x2(p: A, q: B / 2, r: C)
        guard eig[0].value > 0 else { return nil }
        let semiMajor = (k / eig[0].value).squareRoot()
        let semiMinor = (k / eig[1].value).squareRoot()
        let v = eig[0].vector
        var angle = atan2(v.y, v.x)                     // major axis direction, defined mod π
        if angle >= .pi / 2 { angle -= .pi } else if angle < -.pi / 2 { angle += .pi }
        return Ellipse(center: SIMD2(cx, cy), semiMajor: semiMajor, semiMinor: semiMinor, angle: angle)
    }
}

/// An ellipse in image coordinates. `angle` is the direction of the major axis measured from +x toward +y.
public struct Ellipse: Sendable, Equatable {
    public var center: SIMD2<Double>
    public var semiMajor: Double
    public var semiMinor: Double
    public var angle: Double

    public init(center: SIMD2<Double>, semiMajor: Double, semiMinor: Double, angle: Double) {
        self.center = center; self.semiMajor = semiMajor; self.semiMinor = semiMinor; self.angle = angle
    }

    /// minor / major. 1 = circle (camera on the rim axis); → 0 = edge-on.
    public var axisRatio: Double { semiMinor / semiMajor }

    public func point(at phi: Double) -> SIMD2<Double> {
        let ca = cos(angle), sa = sin(angle)
        let x = semiMajor * cos(phi), y = semiMinor * sin(phi)
        return SIMD2(center.x + ca * x - sa * y, center.y + sa * x + ca * y)
    }

    public var conic: Conic {
        let ca = cos(angle), sa = sin(angle)
        let ia = 1 / (semiMajor * semiMajor), ib = 1 / (semiMinor * semiMinor)
        // Q2 = R diag(ia, ib) Rᵀ
        let q11 = ca * ca * ia + sa * sa * ib
        let q12 = ca * sa * (ia - ib)
        let q22 = sa * sa * ia + ca * ca * ib
        let cx = center.x, cy = center.y
        let d = -2 * (q11 * cx + q12 * cy)
        let e = -2 * (q12 * cx + q22 * cy)
        let f = q11 * cx * cx + 2 * q12 * cx * cy + q22 * cy * cy - 1
        return Conic(a: q11, b: 2 * q12, c: q22, d: d, e: e, f: f)
    }
}

public struct EllipseFit: Sendable {
    public var ellipse: Ellipse
    /// RMS Sampson distance of the input points, same units as the points.
    public var rmsResidual: Double
    public var pointCount: Int
}

public enum EllipseFitter {
    /// Direct algebraic conic fit (smallest eigenvector of the normalised scatter matrix), then
    /// conversion to ellipse parameters. Points are normalised (centred, isotropically scaled)
    /// first so the scatter matrix is well conditioned in pixel units.
    /// Returns nil for fewer than 6 points or when the best conic is not an ellipse.
    public static func fit(_ points: [SIMD2<Double>]) -> EllipseFit? {
        let n = points.count
        guard n >= 6 else { return nil }
        var mean = SIMD2<Double>(0, 0)
        for p in points { mean += p }
        mean /= Double(n)
        var msr = 0.0
        for p in points { let d = p - mean; msr += d.x * d.x + d.y * d.y }
        let scale = (msr / (2 * Double(n))).squareRoot()
        guard scale > 1e-12 else { return nil }

        let q = points.map { ($0 - mean) / scale }
        // Pass 0: plain algebraic fit. Passes 1–4: rows weighted by 1/|∇F| at the current conic
        // (gradient-weighted / Sampson), which removes the algebraic fit's bias toward smaller,
        // rounder ellipses — the bias is worst for the eccentric ellipses a low camera produces.
        var conic: Conic? = nil
        for _ in 0..<5 {
            var S = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
            for pt in q {
                let row = [pt.x * pt.x, pt.x * pt.y, pt.y * pt.y, pt.x, pt.y, 1.0]
                var wgt = 1.0
                if let c = conic {
                    let gx = 2 * c.a * pt.x + c.b * pt.y + c.d, gy = c.b * pt.x + 2 * c.c * pt.y + c.e
                    let g2 = gx * gx + gy * gy
                    wgt = g2 > 1e-12 ? 1 / g2 : 1
                }
                for i in 0..<6 { for j in 0..<6 { S[i][j] += wgt * row[i] * row[j] } }
            }
            let (vals, vecs) = LinAlg.symmetricEigen(S)
            var best = 0
            for k in 1..<6 where vals[k] < vals[best] { best = k }
            let c = (0..<6).map { vecs[$0][best] }
            conic = Conic(a: c[0], b: c[1], c: c[2], d: c[3], e: c[4], f: c[5])
        }
        guard let normalisedConic = conic, var ell = normalisedConic.ellipse() else { return nil }
        ell.center = mean + ell.center * scale
        ell.semiMajor *= scale
        ell.semiMinor *= scale
        let finalConic = ell.conic
        let rms = Stats.rms(points.map { finalConic.sampsonDistance($0) })
        return EllipseFit(ellipse: ell, rmsResidual: rms, pointCount: n)
    }
}
