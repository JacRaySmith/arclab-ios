import Foundation

/// A ball detection in the image with its timestamp.
public struct ImageSample: Sendable, Equatable {
    public var t: Double
    public var uv: SIMD2<Double>
    /// Apparent ball diameter in pixels, if the detector reports one.
    public var diameterPx: Double?
    public init(t: Double, uv: SIMD2<Double>, diameterPx: Double? = nil) { self.t = t; self.uv = uv; self.diameterPx = diameterPx }
}

/// The vertical plane containing the rim centre and the ball's flight, expressed in the camera frame.
public struct ShotPlaneFrame: Sendable {
    public var origin: SIMD3<Double>     // rim centre
    public var up: SIMD3<Double>
    public var along: SIMD3<Double>      // horizontal, in-plane, pointing from shooter toward rim
    public var normal: SIMD3<Double>
    /// Azimuth parameter that produced this plane (radians, in the solver's horizontal basis).
    public var azimuth: Double

    /// Intersect a camera ray with the plane. Nil when the ray is (nearly) parallel or hits behind the camera.
    public func intersect(ray: SIMD3<Double>, minimumDepth: Double = 0.5) -> SIMD3<Double>? {
        let denom = dot3(ray, normal)
        guard abs(denom) > 1e-6 else { return nil }
        let lambda = dot3(origin, normal) / denom
        guard lambda > 0 else { return nil }
        let p = lambda * ray
        guard p.z >= minimumDepth else { return nil }
        return p
    }

    public func planeCoordinates(_ p: SIMD3<Double>) -> SIMD2<Double> {
        let d = p - origin
        return SIMD2(dot3(d, along), dot3(d, up))
    }

    public func point3D(x: Double, y: Double) -> SIMD3<Double> { origin + x * along + y * up }

    /// Angle between the camera's optical axis (horizontal component) and the plane normal.
    /// 0 = perfect side view, π/2 = head-on.
    public var viewAngle: Double {
        let z = SIMD3<Double>(0, 0, 1)
        let zh = unit(z - dot3(z, up) * up)
        return acos(min(1, abs(dot3(zh, normal))))
    }
}

public struct AzimuthSolution: Sendable {
    public var frame: ShotPlaneFrame
    public var pixelRMS: Double
    /// Objective sampled on the coarse grid: (azimuth, pixel RMS or +inf where invalid).
    public var curve: [(Double, Double)]
    /// Second-best local minimum's RMS relative to the best; ≈1 means the azimuth is ambiguous.
    public var ambiguityRatio: Double
    /// Approximate 1σ uncertainty of the azimuth from the objective's curvature, radians.
    public var azimuthSigma: Double
    public var warnings: [String]
}

public enum ShotPlaneError: Error, CustomStringConvertible, Sendable {
    case tooFewSamples(Int)
    case noValidAzimuth
    public var description: String {
        switch self {
        case .tooFewSamples(let n): return "azimuth solve needs ≥ 6 samples, got \(n)"
        case .noValidAzimuth: return "no azimuth places the whole track in front of the camera"
        }
    }
}

/// Recovers the shot plane's azimuth about the rim's vertical axis from the ball track alone.
///
/// The rim fixes the camera's position and the direction of gravity, but a circle is symmetric
/// about its axis, so the plane's rotation about vertical is unknown. For a candidate azimuth,
/// back-project every detection onto that plane and fit x(t) linear, y(t) quadratic. Only the
/// true plane makes the projected motion a parabola in time: a wrong plane is related by a
/// homography, which is not affine, so x(t) bends and the reprojection residual grows. This
/// leaves `g` free — the gravity check stays independent.
public enum ShotPlaneSolver {
    public static func horizontalBasis(up: SIMD3<Double>) -> (a: SIMD3<Double>, b: SIMD3<Double>) {
        let ref: SIMD3<Double> = abs(up.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
        let a = unit(cross3(up, ref))
        let b = cross3(up, a)
        return (a, b)
    }

    public static func frame(calibration: RimCalibration, azimuth: Double) -> ShotPlaneFrame {
        let (a, b) = horizontalBasis(up: calibration.up)
        let normal = cos(azimuth) * a + sin(azimuth) * b
        let along = cross3(normal, calibration.up)
        return ShotPlaneFrame(origin: calibration.rimCenter, up: calibration.up, along: along, normal: normal, azimuth: azimuth)
    }

    /// Project image samples into a plane. Nil if any sample fails to intersect.
    public static func project(_ samples: [ImageSample], intrinsics: CameraIntrinsics, frame: ShotPlaneFrame) -> [TrajectorySample]? {
        var out: [TrajectorySample] = []
        out.reserveCapacity(samples.count)
        for s in samples {
            guard let p = frame.intersect(ray: intrinsics.ray(s.uv)) else { return nil }
            let c = frame.planeCoordinates(p)
            out.append(TrajectorySample(t: s.t, x: c.x, y: c.y))
        }
        return out
    }

    /// Objective for a candidate plane: RMS, in pixels, of (a) the reprojection error of the best
    /// time-parabola through the back-projected samples and (b) the ball's apparent-diameter profile
    /// against the depth profile the plane implies. Term (b) uses only the *shape* of the diameter
    /// profile — a free scale factor absorbs the ball size and any uniform detector bias — so it
    /// constrains the azimuth without trusting the absolute ball diameter. Samples without a
    /// diameter contribute to (a) only.
    static func objective(_ samples: [ImageSample], intrinsics: CameraIntrinsics, frame: ShotPlaneFrame) -> Double {
        guard let pts = project(samples, intrinsics: intrinsics, frame: frame) else { return .infinity }
        let t0 = pts[pts.count / 2].t
        var opts = TrajectoryFitOptions(); opts.minimumSamples = 5; opts.minimumSpan = 0.0; opts.iterations = 3
        guard let fit = try? TrajectoryFitter.fit(pts, anchorTime: t0, options: opts) else { return .infinity }
        var sse = 0.0
        var invDepth: [Double] = [], diam: [Double] = []
        for (i, s) in samples.enumerated() {
            let p = fit.position(at: pts[i].t)
            let P = frame.point3D(x: p.x, y: p.y)
            guard P.z > 1e-6 else { return .infinity }
            let px = intrinsics.pixel(fromNormalized: SIMD2(P.x / P.z, P.y / P.z))
            let d = px - s.uv
            sse += d.x * d.x + d.y * d.y
            if let dp = s.diameterPx, dp > 0 { invDepth.append(1 / P.z); diam.append(dp) }
        }
        if invDepth.count >= 6 {
            // d_i ≈ k / z_i with k free (closed-form least squares).
            var num = 0.0, den = 0.0
            for j in 0..<diam.count { num += invDepth[j] * diam[j]; den += invDepth[j] * invDepth[j] }
            let k = den > 0 ? num / den : 0
            for j in 0..<diam.count { let e = k * invDepth[j] - diam[j]; sse += e * e }
        }
        return (sse / Double(samples.count)).squareRoot()
    }

    /// Whole-track azimuth solve by fixed-gravity fit: scan the azimuth, project every sample, fit a parabola with
    /// g fixed, and take the residual minimum. Robust to a missing apex and to noisy ball diameters (no diameter cue).
    /// The mirror plane (azimuth + π) has the same residual; the convention "shooter at negative x" resolves it.
    /// With `knownDistance`, candidates whose first sample is not within `distanceTolerance` of that horizontal
    /// distance from the rim centre are rejected, which also pins the scale sanity.
    ///
    /// `allowedAzimuths` (default nil, so every existing caller is unchanged) restricts the scan to
    /// a set of azimuth windows — what a court-anchored pose supplies in place of the free 0…2π
    /// search. Outside those windows the objective is not even evaluated, so an azimuth the court
    /// says is impossible can never win on residual alone.
    public static func solveByFixedGravity(_ samples: [ImageSample], calibration: RimCalibration, intrinsics: CameraIntrinsics,
                                           knownDistance: Double? = nil, distanceTolerance: Double = 0.8,
                                           coarseStepDegrees: Double = 2,
                                           allowedAzimuths: [AzimuthWindow]? = nil) -> AzimuthSolution? {
        guard samples.count >= 8 else { return nil }
        if let windows = allowedAzimuths, windows.isEmpty { return nil }
        var fo = TrajectoryFitOptions(); fo.fixedG = Court.g; fo.minimumSamples = 5; fo.minimumSpan = 0.05
        func allowed(_ az: Double) -> Bool {
            guard let windows = allowedAzimuths else { return true }
            return windows.contains { $0.contains(az) }
        }
        func cost(_ az: Double) -> (rms: Double, x0: Double)? {
            guard allowed(az) else { return nil }
            let fr = frame(calibration: calibration, azimuth: az)
            guard let pl = project(samples, intrinsics: intrinsics, frame: fr), pl.count >= 8, let x0 = pl.first?.x, x0 < 0 else { return nil }
            if let L = knownDistance, abs(-x0 - L) > distanceTolerance { return nil }
            guard let f = try? TrajectoryFitter.fit(pl, anchorTime: pl[pl.count / 2].t, options: fo) else { return nil }
            return (f.rms, x0)
        }
        var curve: [(Double, Double)] = []
        var best: (az: Double, rms: Double)? = nil
        var az = 0.0
        while az < 2 * .pi {
            if let c = cost(az) {
                curve.append((az, c.rms))
                if best == nil || c.rms < best!.rms { best = (az, c.rms) }
            } else { curve.append((az, .infinity)) }
            az += Angle.radians(coarseStepDegrees)
        }
        // A window narrower than the coarse step can fall between grid points; always try its centre.
        for w in allowedAzimuths ?? [] {
            let c = atan2(sin(w.center), cos(w.center)) + (w.center < 0 ? 2 * Double.pi : 0)
            if let cost = cost(w.center) {
                curve.append((c, cost.rms))
                if best == nil || cost.rms < best!.rms { best = (w.center, cost.rms) }
            }
        }
        guard var b = best else { return nil }
        // Golden-section refinement in ± one coarse step.
        var lo = b.az - Angle.radians(coarseStepDegrees), hi = b.az + Angle.radians(coarseStepDegrees)
        let phi = (5.0.squareRoot() - 1) / 2
        for _ in 0..<25 {
            let m1 = hi - phi * (hi - lo), m2 = lo + phi * (hi - lo)
            let c1 = cost(m1)?.rms ?? .infinity, c2 = cost(m2)?.rms ?? .infinity
            if c1 < c2 { hi = m2; if c1 < b.rms { b = (m1, c1) } } else { lo = m1; if c2 < b.rms { b = (m2, c2) } }
        }
        // Curvature → σ: the residual grows ~quadratically away from the minimum; find where it doubles.
        var sigma = Angle.radians(coarseStepDegrees)
        let finite = curve.filter { $0.1.isFinite }
        if let right = finite.first(where: { $0.0 > b.az && $0.1 > 2 * b.rms }) { sigma = min(sigma * 5, right.0 - b.az) }
        let secondBest = finite.filter { abs($0.0 - b.az) > Angle.radians(20) }.map { $0.1 }.min() ?? .infinity
        var warnings: [String] = []
        if secondBest.isFinite, secondBest < 1.3 * b.rms { warnings.append(String(format: "fixed-g azimuth is ambiguous: another minimum at %.0f%% of the best residual", 100 * b.rms / secondBest)) }
        return AzimuthSolution(frame: frame(calibration: calibration, azimuth: b.az), pixelRMS: b.rms, curve: curve,
                               ambiguityRatio: secondBest.isFinite ? b.rms / secondBest : 0, azimuthSigma: sigma, warnings: warnings)
    }

    public static func solve(_ samples: [ImageSample], calibration: RimCalibration, intrinsics: CameraIntrinsics,
                             gridSteps: Int = 180) throws -> AzimuthSolution {
        guard samples.count >= 6 else { throw ShotPlaneError.tooFewSamples(samples.count) }
        var curve: [(Double, Double)] = []
        curve.reserveCapacity(gridSteps)
        for k in 0..<gridSteps {
            let psi = Double.pi * Double(k) / Double(gridSteps)    // ψ and ψ+π are the same plane
            curve.append((psi, objective(samples, intrinsics: intrinsics, frame: frame(calibration: calibration, azimuth: psi))))
        }
        let finite = curve.filter { $0.1.isFinite }
        guard !finite.isEmpty else { throw ShotPlaneError.noValidAzimuth }
        let bestK = (0..<gridSteps).min { curve[$0].1 < curve[$1].1 }!

        // Golden-section refinement in the bracket around the best grid point (periodic in π).
        let h = Double.pi / Double(gridSteps)
        var a = curve[bestK].0 - h, b = curve[bestK].0 + h
        let gr = (5.0.squareRoot() - 1) / 2
        var c = b - gr * (b - a), d = a + gr * (b - a)
        var fc = objective(samples, intrinsics: intrinsics, frame: frame(calibration: calibration, azimuth: c))
        var fd = objective(samples, intrinsics: intrinsics, frame: frame(calibration: calibration, azimuth: d))
        for _ in 0..<40 {
            if fc < fd { b = d; d = c; fd = fc; c = b - gr * (b - a); fc = objective(samples, intrinsics: intrinsics, frame: frame(calibration: calibration, azimuth: c)) }
            else { a = c; c = d; fc = fd; d = a + gr * (b - a); fd = objective(samples, intrinsics: intrinsics, frame: frame(calibration: calibration, azimuth: d)) }
            if b - a < 1e-6 { break }
        }
        let psiBest = fc < fd ? c : d
        let bestRMS = min(fc, fd)
        var fr = frame(calibration: calibration, azimuth: psiBest)

        // Orient `along` so the ball travels toward +x (toward the rim).
        if let pts = project(samples, intrinsics: intrinsics, frame: fr), pts.count >= 2, pts.last!.x < pts.first!.x {
            fr.along = -fr.along; fr.normal = -fr.normal
        }

        // Ambiguity: best local minimum other than the global one.
        var otherMin = Double.infinity
        for k in 0..<gridSteps where curve[k].1.isFinite {
            let prev = curve[(k + gridSteps - 1) % gridSteps].1, next = curve[(k + 1) % gridSteps].1
            let isLocalMin = curve[k].1 <= prev && curve[k].1 <= next
            let farFromBest = min(abs(k - bestK), gridSteps - abs(k - bestK)) > 3
            if isLocalMin && farFromBest { otherMin = min(otherMin, curve[k].1) }
        }
        let ambiguityRatio = otherMin.isFinite && otherMin > 0 ? bestRMS / otherMin : 0

        // Curvature-based σ(ψ): fit a parabola to the objective² near the minimum.
        let dpsi = h
        let fp = objective(samples, intrinsics: intrinsics, frame: frame(calibration: calibration, azimuth: psiBest + dpsi))
        let fm = objective(samples, intrinsics: intrinsics, frame: frame(calibration: calibration, azimuth: psiBest - dpsi))
        var sigma = Double.infinity
        if fp.isFinite && fm.isFinite {
            let curv = (fp * fp + fm * fm - 2 * bestRMS * bestRMS) / (dpsi * dpsi)   // d²(RMS²)/dψ²
            // RMS² grows by σ_px²·(1/N_eff)… treat ΔRMS² = bestRMS² as one-sigma level: σψ ≈ sqrt(2·RMS²/curv)
            if curv > 0 { sigma = (2 * max(bestRMS, 0.05) * max(bestRMS, 0.05) / curv).squareRoot() }
        }
        var warnings: [String] = []
        if ambiguityRatio > 0.8 { warnings.append(String(format: "shot-plane azimuth is ambiguous (secondary minimum within %.0f%% of best)", (1 - ambiguityRatio) * 100)) }
        if sigma > Angle.radians(5) { warnings.append(String(format: "shot-plane azimuth is weakly determined (σ ≈ %.1f°)", Angle.degrees(sigma))) }
        return AzimuthSolution(frame: fr, pixelRMS: bestRMS, curve: curve, ambiguityRatio: ambiguityRatio, azimuthSigma: sigma, warnings: warnings)
    }
}
