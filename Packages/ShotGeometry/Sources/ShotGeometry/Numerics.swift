import Foundation

// MARK: - Seeded random numbers (Foundation's system RNG cannot be seeded; tests must not flake)

/// SplitMix64. Deterministic for a given seed on every platform.
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    public mutating func uniform(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * uniform()
    }

    /// Standard normal via Box–Muller.
    public mutating func gaussian(sd: Double = 1.0) -> Double {
        var u1 = uniform()
        if u1 < 1e-300 { u1 = 1e-300 }
        let u2 = uniform()
        return sd * (-2.0 * log(u1)).squareRoot() * cos(2.0 * .pi * u2)
    }
}

// MARK: - Descriptive statistics

public enum Stats {
    public static func mean(_ x: [Double]) -> Double {
        x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count)
    }

    /// Sample variance (ddof = 1 by default, matching numpy's `ddof=1`).
    public static func variance(_ x: [Double], ddof: Int = 1) -> Double {
        let n = x.count
        guard n > ddof else { return .nan }
        let m = mean(x)
        return x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(n - ddof)
    }

    public static func sd(_ x: [Double], ddof: Int = 1) -> Double { variance(x, ddof: ddof).squareRoot() }

    public static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return .nan }
        let s = x.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }

    /// Median absolute deviation scaled to be a consistent estimator of σ for Gaussian data.
    public static func robustSD(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return .nan }
        let m = median(x)
        return 1.4826 * median(x.map { abs($0 - m) })
    }

    public static func rms(_ x: [Double]) -> Double {
        x.isEmpty ? .nan : (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot()
    }
}

// MARK: - Small dense linear algebra (row-major [[Double]])

public enum LinAlg {
    /// Least squares `A β ≈ b` by Householder QR. Returns nil if A is rank deficient.
    /// Optional per-row weights `w` solve the weighted problem (rows scaled by √w).
    /// Least squares by Householder QR. Kept for callers that already hold an array of rows; it
    /// flattens and hands over to `leastSquaresRowMajor`, which is where the arithmetic lives.
    public static func leastSquares(_ A: [[Double]], _ b: [Double], weights: [Double]? = nil) -> [Double]? {
        let m = A.count
        guard m > 0 else { return nil }
        let n = A[0].count
        guard m >= n, b.count == m else { return nil }
        var flat = [Double](repeating: 0, count: m * n)
        for i in 0..<m { for j in 0..<n { flat[i * n + j] = A[i][j] } }
        return leastSquaresRowMajor(flat, b, rows: m, columns: n, weights: weights)
    }

    /// The same Householder QR on a **flat, row-major** design matrix.
    ///
    /// Why flat. An `[[Double]]` puts every row behind its own heap allocation with its own reference
    /// count, so `R[i][j] *= s` paid a copy-on-write uniqueness check per element and every inner
    /// loop chased a pointer per row. Profiling the Phase 1 gate harness, this one function and the
    /// malloc/retain traffic it caused were the largest single cost in the package. The operations
    /// below are the same operations in the same order as before, on the same values, so every
    /// coefficient is bit-for-bit what it was.
    public static func leastSquaresRowMajor(_ A: [Double], _ b: [Double], rows m: Int, columns n: Int,
                                            weights: [Double]? = nil) -> [Double]? {
        guard m > 0, n > 0, m >= n, A.count == m * n, b.count == m else { return nil }
        if let w = weights, w.count != m { return nil }
        var R = A
        var y = b
        if let w = weights {
            for i in 0..<m {
                let s = max(w[i], 0).squareRoot()
                for j in 0..<n { R[i * n + j] *= s }
                y[i] *= s
            }
        }
        var beta = [Double](repeating: 0, count: n)
        var ok = true
        R.withUnsafeMutableBufferPointer { rBuf in
            y.withUnsafeMutableBufferPointer { yBuf in
                beta.withUnsafeMutableBufferPointer { betaBuf in
                    withUnsafeTemporaryAllocation(of: Double.self, capacity: m) { v in
                        let R = rBuf.baseAddress!, y = yBuf.baseAddress!, beta = betaBuf.baseAddress!
                        for k in 0..<n {
                            var norm = 0.0
                            for i in k..<m { let a = R[i * n + k]; norm += a * a }
                            norm = norm.squareRoot()
                            if norm < 1e-300 { ok = false; return }
                            let alpha = R[k * n + k] > 0 ? -norm : norm
                            for i in 0..<m { v[i] = 0 }
                            v[k] = R[k * n + k] - alpha
                            for i in (k + 1)..<m { v[i] = R[i * n + k] }
                            var vnorm2 = 0.0
                            for i in k..<m { vnorm2 += v[i] * v[i] }
                            if vnorm2 < 1e-300 { continue }
                            for j in k..<n {
                                var s = 0.0
                                for i in k..<m { s += v[i] * R[i * n + j] }
                                let f = 2 * s / vnorm2
                                for i in k..<m { R[i * n + j] -= f * v[i] }
                            }
                            var s = 0.0
                            for i in k..<m { s += v[i] * y[i] }
                            let f = 2 * s / vnorm2
                            for i in k..<m { y[i] -= f * v[i] }
                        }
                        for k in stride(from: n - 1, through: 0, by: -1) {
                            var s = y[k]
                            for j in (k + 1)..<n { s -= R[k * n + j] * beta[j] }
                            if abs(R[k * n + k]) < 1e-14 * max(1.0, abs(s)) { ok = false; return }
                            beta[k] = s / R[k * n + k]
                        }
                    }
                }
            }
        }
        return ok ? beta : nil
    }

    /// Eigen-decomposition of a symmetric matrix by cyclic Jacobi rotations.
    /// Returns eigenvalues (unsorted) and eigenvectors as columns: `vectors[i][k]` is component i of eigenvector k.
    public static func symmetricEigen(_ Ain: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
        let n = Ain.count
        var A = Ain
        var V = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { V[i][i] = 1 }

        for _ in 0..<100 {
            var off = 0.0
            for i in 0..<n { for j in 0..<n where i != j { off += A[i][j] * A[i][j] } }
            var diag = 0.0
            for i in 0..<n { diag += A[i][i] * A[i][i] }
            if off <= 1e-30 * max(diag, 1e-300) { break }

            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    let apq = A[p][q]
                    if abs(apq) < 1e-300 { continue }
                    let theta = (A[q][q] - A[p][p]) / (2 * apq)
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c
                    for k in 0..<n {
                        let akp = A[k][p], akq = A[k][q]
                        A[k][p] = c * akp - s * akq
                        A[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = A[p][k], aqk = A[q][k]
                        A[p][k] = c * apk - s * aqk
                        A[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = V[k][p], vkq = V[k][q]
                        V[k][p] = c * vkp - s * vkq
                        V[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        return ((0..<n).map { A[$0][$0] }, V)
    }

    /// Eigenpairs of a symmetric 2×2 `[[p, q], [q, r]]`, ascending.
    public static func eigen2x2(p: Double, q: Double, r: Double) -> [(value: Double, vector: SIMD2<Double>)] {
        let tr = p + r
        let disc = ((p - r) * (p - r) / 4 + q * q).squareRoot()
        let l1 = tr / 2 - disc, l2 = tr / 2 + disc
        func vec(_ l: Double) -> SIMD2<Double> {
            if abs(q) > 1e-14 {
                let v = SIMD2(l - r, q)
                return v / (v.x * v.x + v.y * v.y).squareRoot()
            }
            return abs(l - p) <= abs(l - r) ? SIMD2(1, 0) : SIMD2(0, 1)
        }
        return [(l1, vec(l1)), (l2, vec(l2))]
    }
}

// MARK: - Polynomial least squares in time

/// Coefficients are **lowest power first**: `c[0] + c[1]·t + c[2]·t²`. This is the opposite of
/// numpy's `polyfit`; the field names in `Linear`/`Quadratic` exist so the order is never guessed.
public struct Linear: Sendable, Equatable {
    public var c0: Double, c1: Double
    public init(c0: Double, c1: Double) { self.c0 = c0; self.c1 = c1 }
    @inlinable public func callAsFunction(_ t: Double) -> Double { c0 + c1 * t }
}

public struct Quadratic: Sendable, Equatable {
    public var c0: Double, c1: Double, c2: Double
    public init(c0: Double, c1: Double, c2: Double) { self.c0 = c0; self.c1 = c1; self.c2 = c2 }
    @inlinable public func callAsFunction(_ t: Double) -> Double { c0 + t * (c1 + c2 * t) }
    @inlinable public func derivative(_ t: Double) -> Double { c1 + 2 * c2 * t }
}

public enum PolyFit {
    public static func linear(_ t: [Double], _ y: [Double], weights: [Double]? = nil) -> Linear? {
        guard t.count == y.count, t.count >= 2 else { return nil }
        var A = [Double](repeating: 1, count: 2 * t.count)
        for i in t.indices { A[2 * i + 1] = t[i] }
        guard let c = LinAlg.leastSquaresRowMajor(A, y, rows: t.count, columns: 2, weights: weights) else { return nil }
        return Linear(c0: c[0], c1: c[1])
    }

    public static func quadratic(_ t: [Double], _ y: [Double], weights: [Double]? = nil) -> Quadratic? {
        guard t.count == y.count, t.count >= 3 else { return nil }
        var A = [Double](repeating: 1, count: 3 * t.count)
        for i in t.indices { A[3 * i + 1] = t[i]; A[3 * i + 2] = t[i] * t[i] }
        guard let c = LinAlg.leastSquaresRowMajor(A, y, rows: t.count, columns: 3, weights: weights) else { return nil }
        return Quadratic(c0: c[0], c1: c[1], c2: c[2])
    }
}

// MARK: - simd helpers

@inlinable func norm(_ v: SIMD3<Double>) -> Double { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }
@inlinable func norm(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
@inlinable func unit(_ v: SIMD3<Double>) -> SIMD3<Double> { v / norm(v) }
@inlinable func dot3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
@inlinable func cross3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
/// Angle between two vectors, radians, robust near 0 and π.
@inlinable func angleBetween(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let c = cross3(a, b), d = dot3(a, b)
    return atan2(norm(c), d)
}
