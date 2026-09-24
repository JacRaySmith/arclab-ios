import Foundation

/// One of the two circle poses consistent with an image ellipse.
public struct RimPoseCandidate: Sendable {
    /// Rim centre in the camera frame, metres.
    public var center: SIMD3<Double>
    /// Unit normal of the rim plane in the camera frame, oriented "up".
    public var normal: SIMD3<Double>
    /// Positive when the rim centre lies above the camera along `normal`.
    public var rimHeightAboveCamera: Double { dot3(center, normal) }
}

public enum RimCalibrationError: Error, CustomStringConvertible, Sendable {
    case tooFewPoints(Int)
    case notAnEllipse
    case degenerate(axisRatio: Double)
    case notACone
    case noSolutionInFrontOfCamera

    public var description: String {
        switch self {
        case .tooFewPoints(let n): return "rim ellipse needs ≥ 6 boundary points, got \(n)"
        case .notAnEllipse: return "rim boundary points do not fit an ellipse"
        case .degenerate(let r): return String(format: "rim ellipse is nearly edge-on (axis ratio %.3f); the camera is too close to rim height — lower it or move closer to the basket", r)
        case .notACone: return "conic does not define a real cone (fit is not an ellipse)"
        case .noSolutionInFrontOfCamera: return "no circle pose in front of the camera"
        }
    }
}

/// Camera pose relative to the rim, recovered from the rim's image ellipse.
///
/// A circle of known radius seen through a calibrated camera fixes the circle's centre and
/// plane normal up to a two-fold ambiguity (Safaee-Rad et al. 1992). The rim is horizontal and
/// almost always above the camera; that resolves the ambiguity without any sensor. What the rim
/// cannot fix is rotation about its own axis: the shot plane's azimuth comes from the ball
/// track (`ShotPlaneSolver`), not from here.
public struct RimCalibration: Sendable {
    public var rimCenter: SIMD3<Double>       // camera frame
    public var up: SIMD3<Double>              // unit, camera frame
    public var chosen: RimPoseCandidate
    public var alternate: RimPoseCandidate
    /// Angle between the two candidate normals. Small values mean the choice is fragile.
    public var ambiguityAngle: Double
    public var ellipse: Ellipse
    public var ellipseResidualPx: Double
    public var rimDiameterUsed: Double
    public var warnings: [String]

    public var distanceToRim: Double { norm(rimCenter) }
    public var rimHeightAboveCamera: Double { dot3(rimCenter, up) }
    /// Camera pitch relative to gravity (positive = looking up), radians.
    public var pitch: Double { asin(max(-1, min(1, up.z))) }
    /// Camera roll relative to gravity, radians (0 = level).
    public var roll: Double { atan2(-up.x, -up.y) }
    /// Elevation of the line of sight to the rim above horizontal, radians.
    public var elevationToRim: Double { asin(max(-1, min(1, rimHeightAboveCamera / distanceToRim))) }
}

public struct RimCalibrationOptions: Sendable {
    /// Diameter of the circle that the boundary points trace. Inner edge → 0.4572; outer edge → 0.489.
    public var rimDiameter: Double = Court.rimInnerDiameter
    /// Approximate "up" in the camera frame. Only its sign matters (it orients the normal).
    /// (0, −1, 0) is an upright phone; pass the CoreMotion gravity vector negated when available.
    public var upHint: SIMD3<Double> = SIMD3(0, -1, 0)
    /// A **measured** up direction in the camera frame (unit, pointing away from the floor). When set,
    /// the rim plane's normal is taken from this and only the rim's *position* is solved from the conic.
    ///
    /// Why this exists: the conic solve reads the rim plane's normal from the ellipse's shape, and the
    /// shape is exactly what a few contaminated boundary points spoil. On `footage/2026-09-13/IMG_1766`
    /// the trace's right end runs along the backboard bracket, and the recovered normal implies an 18°
    /// camera roll where the same tripod's other clips give 1–3°. A 14° error in the plane's "up" costs
    /// the release height `L·sin 14° ≈ 1.6 m` at a three-point release and almost nothing at the rim, so
    /// it is invisible in the rim reprojection and fatal to the shot metrics — and it grows with the
    /// shot distance, which is why threes fail where free throws pass.
    ///
    /// Gravity, unlike the trace, is measured to a fraction of a degree: CoreMotion's gravity vector on
    /// the phone, or the vertical vanishing point of poles and posts on archive footage. Nothing else
    /// about the solve changes: the radius is still the rulebook's, the distance still comes from the
    /// ellipse's angular size, and `g` is still the check.
    ///
    /// Leave nil to keep the conic's own normal (the behaviour of every release before 2026-09-24).
    public var knownUp: SIMD3<Double>? = nil
    /// Warn when the traced ellipse's own plane normal is further than this from `knownUp` (radians).
    /// Past a few degrees one of the two is wrong, and the trace is the likelier of the pair.
    public var knownUpDisagreementWarning: Double = Angle.radians(8)
    /// The rim is above the camera. Set false only for a camera mounted above 3.05 m.
    public var cameraBelowRim: Bool = true
    /// Below this minor/major ratio the normal is poorly determined; warn.
    public var minimumAxisRatio: Double = 0.15
    /// Plausible lens heights above the floor, metres; outside this band the calibration warns.
    ///
    /// Worth checking every time: the ellipse's axis ratio fixes the elevation of the line of sight
    /// to the rim almost independently of fx, so fx alone decides the distance — and therefore the
    /// implied camera height. A focal length that is too narrow puts the rim too far away and the
    /// camera on the floor. That is what `--hfov 48` did to the 2026-09-13 clips (implied lens
    /// height 0.2–0.5 m for a tripod at 1.2 m) while every other number still looked reasonable.
    /// Set to nil for a camera genuinely mounted outside the band.
    public var plausibleCameraHeight: ClosedRange<Double>? = 0.6...2.4
    public init() {}
}

public enum RimCalibrator {
    public static func calibrate(boundaryPoints: [SIMD2<Double>], intrinsics: CameraIntrinsics,
                                 options: RimCalibrationOptions = .init()) throws -> RimCalibration {
        guard boundaryPoints.count >= 6 else { throw RimCalibrationError.tooFewPoints(boundaryPoints.count) }
        guard let fit = EllipseFitter.fit(boundaryPoints) else { throw RimCalibrationError.notAnEllipse }
        return try calibrate(ellipse: fit.ellipse, ellipseResidualPx: fit.rmsResidual, intrinsics: intrinsics, options: options)
    }

    public static func calibrate(ellipse: Ellipse, ellipseResidualPx: Double = 0, intrinsics: CameraIntrinsics,
                                 options: RimCalibrationOptions = .init()) throws -> RimCalibration {
        var warnings: [String] = []
        let ratio = ellipse.axisRatio
        if ratio < 0.05 { throw RimCalibrationError.degenerate(axisRatio: ratio) }
        if ratio < options.minimumAxisRatio {
            warnings.append(String(format: "rim ellipse axis ratio %.3f < %.2f: camera is too close to rim height (lower it or move closer); rim-plane normal is weakly determined", ratio, options.minimumAxisRatio))
        }

        // Conic in normalised coordinates: Q_n = Kᵀ Q_px K.
        let Qpx = ellipse.conic.matrix
        let K = intrinsics.matrix
        var KtQ = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { KtQ[i][j] += K[k][i] * Qpx[k][j] } } }
        var Qn = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { Qn[i][j] += KtQ[i][k] * K[k][j] } } }
        // Symmetrise against round-off and scale to O(1).
        var maxAbs = 0.0
        for i in 0..<3 { for j in 0..<3 { maxAbs = max(maxAbs, abs(Qn[i][j])) } }
        let raw = Qn
        for i in 0..<3 { for j in 0..<3 { Qn[i][j] = 0.5 * (raw[i][j] + raw[j][i]) / maxAbs } }

        let r = options.rimDiameter / 2
        var candidates: [RimPoseCandidate] = []
        var normalFromGravity = false

        if let givenUp = options.knownUp, norm(givenUp) > 1e-9 {
            normalFromGravity = true
            // Gravity-constrained path: the plane's normal is *given*, only the position is solved.
            let up = unit(givenUp)
            let free = try? conePoses(conic: Qn, radius: r, upHint: options.upHint, cameraBelowRim: options.cameraBelowRim).first
            // Start from whichever of (free solve, closed form) is available; refine against the trace.
            let seed = free?.center ?? poseWithKnownNormal(conic: Qn, normal: up, radius: r)?.center
            guard let seed, let fitted = fitHorizontalCircle(ellipse: ellipse, intrinsics: intrinsics, normal: up,
                                                             radius: r, initial: seed) else {
                throw RimCalibrationError.noSolutionInFrontOfCamera
            }
            candidates = [fitted.pose, fitted.pose]
            // Two numbers say whether to believe the trace. (1) How far its own plane normal is from the
            // measured one — past a few degrees it is contaminated (a bracket, a net loop, the backboard
            // border). (2) How well *any* horizontal circle reproduces it. A failed free solve is itself
            // evidence, not a reason to stop.
            if let free {
                let disagreement = angleBetween(free.normal, up)
                if disagreement > options.knownUpDisagreementWarning {
                    warnings.append(String(format: "rim trace's own plane normal is %.1f° from the measured gravity direction; using gravity — the trace is not the image of a horizontal circle (bracket, net loop or backboard border in the points), so re-trace it",
                                           Angle.degrees(disagreement)))
                }
            } else {
                warnings.append("rim trace does not define a valid cone on its own; the rim position comes from the measured gravity direction")
            }
            if fitted.rmsPx > 2 {
                warnings.append(String(format: "no horizontal circle reproduces this rim trace better than %.1f px; the trace, not the solve, is the limit on this calibration", fitted.rmsPx))
            }
        } else {
            candidates = try conePoses(conic: Qn, radius: r, upHint: options.upHint, cameraBelowRim: options.cameraBelowRim)
        }
        guard !candidates.isEmpty else { throw RimCalibrationError.noSolutionInFrontOfCamera }
        if candidates.count == 1 { candidates.append(candidates[0]) }

        let sign: Double = options.cameraBelowRim ? 1 : -1
        let sorted = candidates.sorted { sign * $0.rimHeightAboveCamera > sign * $1.rimHeightAboveCamera }
        let chosen = sorted[0], alternate = sorted[1]
        let ambiguity = angleBetween(chosen.normal, alternate.normal)
        let margin = abs(chosen.rimHeightAboveCamera - alternate.rimHeightAboveCamera)
        // With the normal supplied there is only one pose, so the two-fold test does not apply.
        if margin < 0.2 && !normalFromGravity {
            warnings.append(String(format: "two-fold pose ambiguity is weakly resolved (height margin %.2f m); camera is nearly level with the rim", margin))
        }
        if sign * chosen.rimHeightAboveCamera < 0 {
            warnings.append("neither circle pose puts the rim above the camera; check cameraBelowRim")
        }
        if let band = options.plausibleCameraHeight, options.cameraBelowRim {
            let lens = Court.rimHeight - chosen.rimHeightAboveCamera
            if !band.contains(lens) {
                warnings.append(String(format: "this calibration puts the lens %.2f m above the floor (expected %.1f–%.1f m); unless the camera really was there, the focal length is wrong — measure it, never infer it from an assumed rim distance",
                                       lens, band.lowerBound, band.upperBound))
            }
        }

        return RimCalibration(rimCenter: chosen.center, up: chosen.normal, chosen: chosen, alternate: alternate,
                              ambiguityAngle: ambiguity, ellipse: ellipse, ellipseResidualPx: ellipseResidualPx,
                              rimDiameterUsed: options.rimDiameter, warnings: warnings)
    }

    /// The classical two-fold circle-pose solve (Safaee-Rad et al. 1992): the cone through the image
    /// ellipse is cut by the two planes on which it meets a circle of the given radius. Both the plane's
    /// normal and the circle's centre come out of the conic's eigenvalues, so both depend on the *shape*
    /// of the traced ellipse. Ordered with the pose that puts the rim on the expected side first.
    static func conePoses(conic Qn: [[Double]], radius r: Double, upHint: SIMD3<Double>,
                          cameraBelowRim: Bool) throws -> [RimPoseCandidate] {
        var (vals, vecs) = LinAlg.symmetricEigen(Qn)
        let positives = vals.filter { $0 > 0 }.count
        if positives == 1 { vals = vals.map { -$0 } }
        else if positives != 2 { throw RimCalibrationError.notACone }
        let order = (0..<3).sorted { vals[$0] > vals[$1] }      // λ1 ≥ λ2 > 0 > λ3
        let l1 = vals[order[0]], l2 = vals[order[1]], l3 = vals[order[2]]
        guard l2 > 0, l3 < 0 else { throw RimCalibrationError.notACone }
        let e1 = SIMD3(vecs[0][order[0]], vecs[1][order[0]], vecs[2][order[0]])
        let e2 = SIMD3(vecs[0][order[1]], vecs[1][order[1]], vecs[2][order[1]])
        let e3 = cross3(e1, e2)

        let cosA = ((l2 - l3) / (l1 - l3)).squareRoot()
        let sinAmag = ((l1 - l2) / (l1 - l3)).squareRoot()
        let dmag = r * l2 / (-l1 * l3).squareRoot()

        var candidates: [RimPoseCandidate] = []
        for s in [1.0, -1.0] {
            let sinA = s * sinAmag
            let zhat = sinA * e1 + cosA * e3
            let xhat = cosA * e1 - sinA * e3
            var found: RimPoseCandidate?
            for dsign in [1.0, -1.0] {
                let d = dsign * dmag
                let xc = -d * sinA * cosA * (l1 - l3) / l2
                let center = xc * xhat + d * zhat
                if center.z > 0 {
                    var normal = zhat
                    if dot3(normal, upHint) < 0 { normal = -normal }
                    found = RimPoseCandidate(center: center, normal: normal)
                    break
                }
            }
            if let f = found { candidates.append(f) }
        }
        let sign: Double = cameraBelowRim ? 1 : -1
        return candidates.sorted { sign * $0.rimHeightAboveCamera > sign * $1.rimHeightAboveCamera }
    }

    /// Best horizontal circle for a traced rim, with the plane's normal fixed to a measured gravity
    /// direction. Three unknowns (the circle's centre) against the whole traced boundary, so unlike the
    /// closed form below it is over-determined and stays stable when the trace is *not* exactly the image
    /// of a circle in that plane — which is the case this exists for.
    ///
    /// Residual: RMS Sampson distance, in pixels, of points sampled round the traced ellipse to the
    /// projected circle. On 2026-09-13 footage the same fit gives 0.6 px (IMG_1764), 1.7 px (IMG_1765)
    /// and 6.2 px (IMG_1766) — the last being the clip whose trace runs onto the backboard bracket.
    static func fitHorizontalCircle(ellipse: Ellipse, intrinsics: CameraIntrinsics, normal n: SIMD3<Double>,
                                    radius r: Double, initial: SIMD3<Double>) -> (pose: RimPoseCandidate, rmsPx: Double)? {
        let (e1, e2) = ShotPlaneSolver.horizontalBasis(up: n)
        let samples = (0..<72).map { ellipse.point(at: 2 * Double.pi * Double($0) / 72) }
        let Kinv = [[1 / intrinsics.fx, 0, -intrinsics.cx / intrinsics.fx],
                    [0, 1 / intrinsics.fy, -intrinsics.cy / intrinsics.fy],
                    [0.0, 0, 1]]

        // The ellipse's angular size fixes the range to within the foreshortening correction, which the
        // normal can only change by a modest factor — so the solution lies near the seed's range. Without
        // this bound the objective has a second, meaningless minimum with the rim almost at the lens,
        // which a contaminated trace can make look deceptively good.
        let seedRange = norm(initial)
        let rangeBounds = (0.4 * seedRange)...(2.5 * seedRange)

        /// Pixel conic of the circle (centre C, normal n, radius r), then its Sampson residual.
        func residual(_ p: SIMD3<Double>) -> Double {
            let C = p.x * n + p.y * e1 + p.z * e2
            guard C.z > 0.05, p.x > 0, rangeBounds.contains(norm(C)) else { return .infinity }
            let d = p.x                                    // C·n by construction
            let c2n = C.x * C.x + C.y * C.y + C.z * C.z - r * r
            let v = [C.x, C.y, C.z], nn = [n.x, n.y, n.z]
            var M = [[Double]](repeating: [0, 0, 0], count: 3)
            for i in 0..<3 {
                for j in 0..<3 {
                    M[i][j] = (i == j ? d * d : 0) - d * (v[i] * nn[j] + nn[i] * v[j]) + c2n * nn[i] * nn[j]
                }
            }
            var KtM = [[Double]](repeating: [0, 0, 0], count: 3)     // K⁻ᵀ M K⁻¹
            for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { KtM[i][j] += Kinv[k][i] * M[k][j] } } }
            var Q = [[Double]](repeating: [0, 0, 0], count: 3)
            for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { Q[i][j] += KtM[i][k] * Kinv[k][j] } } }
            var scale = 0.0
            for i in 0..<3 { for j in 0..<3 { scale = max(scale, abs(Q[i][j])) } }
            guard scale > 0, scale.isFinite else { return .infinity }
            for i in 0..<3 { for j in 0..<3 { Q[i][j] /= scale } }
            let conic = Conic(matrix: Q)
            guard conic.ellipse() != nil else { return .infinity }
            var sse = 0.0
            for s in samples { let e = conic.sampsonDistance(s); sse += e * e }
            let rms = (sse / Double(samples.count)).squareRoot()
            return rms.isFinite ? rms : .infinity
        }

        // Nelder–Mead on (d, c₁, c₂). Three parameters, a good starting point and a smooth objective,
        // so a plain simplex converges in a few hundred evaluations and needs no derivatives.
        let start = SIMD3(dot3(initial, n), dot3(initial, e1), dot3(initial, e2))
        let step = max(0.02, 0.05 * norm(initial))
        var simplex: [(p: SIMD3<Double>, f: Double)] = [(start, residual(start))]
        for k in 0..<3 {
            var p = start
            p[k] += step
            simplex.append((p, residual(p)))
        }
        guard simplex.allSatisfy({ $0.f.isFinite }) else { return nil }
        for _ in 0..<400 {
            simplex.sort { $0.f < $1.f }
            let best = simplex[0], worst = simplex[3]
            if abs(worst.f - best.f) < 1e-9 * max(1, abs(best.f)) { break }
            var centroid = SIMD3<Double>(0, 0, 0)
            for i in 0..<3 { centroid += simplex[i].p }
            centroid /= 3
            let reflected = centroid + (centroid - worst.p)
            let fr = residual(reflected)
            if fr < best.f {
                let expanded = centroid + 2 * (centroid - worst.p)
                let fe = residual(expanded)
                simplex[3] = fe < fr ? (expanded, fe) : (reflected, fr)
            } else if fr < simplex[2].f {
                simplex[3] = (reflected, fr)
            } else {
                let contracted = centroid + 0.5 * (worst.p - centroid)
                let fc = residual(contracted)
                if fc < worst.f { simplex[3] = (contracted, fc) }
                else { for i in 1..<4 { let p = best.p + 0.5 * (simplex[i].p - best.p); simplex[i] = (p, residual(p)) } }
            }
        }
        simplex.sort { $0.f < $1.f }
        let p = simplex[0].p
        guard simplex[0].f.isFinite else { return nil }
        let center = p.x * n + p.y * e1 + p.z * e2
        guard center.z > 0 else { return nil }
        return (RimPoseCandidate(center: center, normal: n), simplex[0].f)
    }

    /// Closed-form circle centre when the plane's normal is already known.
    ///
    /// A point `X` on a circle of radius `r`, centre `C`, in the plane `X·n = d` (`d = C·n`) images to the
    /// ray `X = λm`, so `λ = d/(m·n)` and `|λm − C|² = r²`. Clearing the denominator leaves a quadratic
    /// form in the image point that *is* the conic the circle projects to:
    ///
    ///     mᵀ M m = 0,   M = d²·I − d·(C nᵀ + n Cᵀ) + (|C|² − r²)·n nᵀ
    ///
    /// Written in an orthonormal basis `(e₁, e₂, n)` with the in-plane offset `c = C − d n`, that is
    ///
    ///     M = [[d², 0, −d·c₁], [0, d², −d·c₂], [−d·c₁, −d·c₂, |c|² − r²]]
    ///
    /// so the observed conic, rotated into the same basis and matched term by term, gives `d` and `c`
    /// directly. The conic is known only up to scale, and that scale cancels: with `β = (B₁₁+B₂₂)/2`,
    ///
    ///     d = r·β / √(B₁₃² + B₂₃² − β·B₃₃),   c₁ = −B₁₃·d/β,   c₂ = −B₂₃·d/β
    ///
    /// The overall sign is fixed by requiring the rim in front of the camera; there is no two-fold
    /// ambiguity left, because the normal was not something the conic had to supply. `B₁₁ ≠ B₂₂` or
    /// `B₁₂ ≠ 0` measures how far the trace is from being the image of a circle in *this* plane; that
    /// inconsistency is reported as the angle between the free solve's normal and this one by the caller.
    static func poseWithKnownNormal(conic Qn: [[Double]], normal n: SIMD3<Double>, radius r: Double) -> RimPoseCandidate? {
        let (a, b) = ShotPlaneSolver.horizontalBasis(up: n)
        let basis = [a, b, n]
        var B = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                var s = 0.0
                let bi = basis[i], bj = basis[j]
                let vi = [bi.x, bi.y, bi.z], vj = [bj.x, bj.y, bj.z]
                for p in 0..<3 { for q in 0..<3 { s += vi[p] * Qn[p][q] * vj[q] } }
                B[i][j] = s
            }
        }
        var beta = 0.5 * (B[0][0] + B[1][1])
        guard abs(beta) > 1e-12 else { return nil }
        if beta < 0 { for i in 0..<3 { for j in 0..<3 { B[i][j] = -B[i][j] } }; beta = -beta }
        let disc = B[0][2] * B[0][2] + B[1][2] * B[1][2] - beta * B[2][2]
        guard disc > 1e-15 else { return nil }
        let d = r * beta / disc.squareRoot()
        let c1 = -B[0][2] * d / beta, c2 = -B[1][2] * d / beta
        var center = d * n + c1 * a + c2 * b
        if center.z < 0 { center = -center }          // the mirrored solution is behind the camera
        guard center.z > 0, center.x.isFinite, center.y.isFinite, center.z.isFinite else { return nil }
        return RimPoseCandidate(center: center, normal: n)
    }
}
