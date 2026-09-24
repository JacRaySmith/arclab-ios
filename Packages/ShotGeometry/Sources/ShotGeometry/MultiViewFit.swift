import Foundation
import simd

// MultiViewFit — triangulating one joint from two or more court-anchored camera views.
//
// The honest split (docs/DESIGN-MULTIVIEW-2026-09-24.md §0), stated once here because every caller
// needs to know which case it is in:
//
//   * **Two devices filming the same shot, synchronised** (see `MultiViewSync.swift`) hand this
//     function two rays that actually intersect (up to pixel noise) at the true joint position at
//     that instant — a real triangulation of one movement.
//   * **One device moved between blocks** (today's only option — a second phone has been an open
//     question since 2026-09-13) hands this function rays from *different shots*, paired only by a
//     shared nominal shot-clock label (e.g. both "40 ms after release"). The arithmetic below cannot
//     tell the two cases apart — a ray is a ray — so the "position" it returns in that case is a
//     statistical combination of two different instances of the movement, not a reconstruction of
//     either one, and must never be shown to the user as if it were. See the design doc §2.
//
// This file assumes each `Camera` it is handed already carries its pose in a **shared court frame**
// — `CourtCalibration`'s job (rim ellipse + measured gravity + marked court features), not this
// file's. `Camera`/`CameraPose` (Camera.swift) are already frame-agnostic rigid transforms, so
// nothing here needs to know how that frame was built, only that both cameras share it.
//
// Method: the closest point of approach of N weighted rays, i.e. minimise
//
//     Σ_i (1/σ_i²) · ‖ P_i (X − o_i) ‖²        P_i = I − d_i d_i^T, the projector ⟂ ray i
//
// Expanding each P_i's perpendicular plane into an orthonormal basis (u_i, v_i) turns this into an
// ordinary weighted linear least squares in the 3 components of X (two rows per ray: u_i·X = u_i·o_i,
// v_i·X = v_i·o_i), solved by the same Householder QR (`LinAlg.leastSquaresRowMajor`) every other
// fit in this package uses — no new numerics, only a new set of rows. The same information matrix
// (Σ w_i P_i) inverted gives the uncertainty: a direction no ray constrains (near-parallel rays)
// shows up as a huge eigenvalue there, which is exactly the failure the bearing-separation gate
// below exists to catch before it gets that far.
public enum MultiViewFit {

    /// One view's observation of a joint (or a ball sample — anything that is a single 2-D point
    /// with a confidence). `view` is a free-form label (e.g. a clip id) kept only for diagnostics —
    /// which view is dragging the fit around, which view a residual belongs to.
    public struct Observation: Sendable {
        public var view: String
        public var camera: Camera
        public var pixel: SIMD2<Double>
        public var confidence: Double

        public init(view: String, camera: Camera, pixel: SIMD2<Double>, confidence: Double) {
            self.view = view; self.camera = camera; self.pixel = pixel; self.confidence = confidence
        }

        /// Convenience for a `BodyKinematics.swift` `BodyPoint2D`: its pixel and confidence carry
        /// straight across since both are already full-frame pixels on the same v-down convention.
        public init(view: String, camera: Camera, point: BodyPoint2D) {
            self.init(view: view, camera: camera, pixel: point.uv, confidence: point.confidence)
        }
    }

    public struct Options: Sendable {
        /// Below this an observation is dropped before triangulating — the same default
        /// `BodyKinematicsOptions.minimumConfidence2D` uses for a single view, so a point that would
        /// not be trusted from one camera is not smuggled in via a second.
        public var minimumConfidence2D: Double = 0.3
        /// 2-D noise, one sigma for every view, in pixels. Default is the whole-skeleton reprojection
        /// RMS **median** measured on real footage — `docs/research/form-eval-baseline-2026-09-16.md`
        /// §1: "Whole-skeleton RMS: median 1.85 px per shot." That is a driven-fit consistency number,
        /// not raw detector noise, but it is the only reprojection figure this codebase has measured,
        /// and CLAUDE.md rule 1 forbids inventing a sharper one.
        public var pixelNoiseSigmaPx: Double = 1.85
        /// Refuse when the best pair of views subtends less than this angle at the triangulated point
        /// — the "two cameras too close in bearing" case, where the rays are nearly parallel and the
        /// depth-like direction is barely constrained. 8° is not a law of geometry; it is where
        /// `docs/DESIGN-MULTIVIEW-2026-09-24.md` §4's synthetic sweep found the recovered error was
        /// still an order of magnitude worse than at 30°+. Override it once real footage says otherwise.
        public var minimumBearingSeparationRadians: Double = Angle.radians(8)

        public init() {}
        public init(pixelNoiseSigmaPx: Double, minimumBearingSeparationRadians: Double, minimumConfidence2D: Double = 0.3) {
            self.pixelNoiseSigmaPx = pixelNoiseSigmaPx
            self.minimumBearingSeparationRadians = minimumBearingSeparationRadians
            self.minimumConfidence2D = minimumConfidence2D
        }
    }

    public struct Result: Sendable {
        public var name: String
        public var position: SIMD3<Double>?
        /// √(mean of the covariance's eigenvalues), metres: one number for display.
        public var uncertaintyMetres: Double?
        /// √(largest eigenvalue), metres — the weak axis. Near-parallel rays blow this up long
        /// before `uncertaintyMetres` looks alarming, which is why the refusal gate is on bearing
        /// separation and not on this number alone.
        public var worstAxisUncertaintyMetres: Double?
        /// The largest angle any pair of the used views' rays subtends. Radians.
        public var bearingSeparationRadians: Double?
        /// Perpendicular distance from the fitted point to each view's ray, metres, keyed by `view`.
        public var residualMetres: [String: Double]
        public var rmsResidualMetres: Double?
        public var viewsUsed: [String]
        public var unavailableReason: String?

        public init(name: String, position: SIMD3<Double>?, uncertaintyMetres: Double?, worstAxisUncertaintyMetres: Double?,
                    bearingSeparationRadians: Double?, residualMetres: [String: Double], rmsResidualMetres: Double?,
                    viewsUsed: [String], unavailableReason: String?) {
            self.name = name; self.position = position; self.uncertaintyMetres = uncertaintyMetres
            self.worstAxisUncertaintyMetres = worstAxisUncertaintyMetres; self.bearingSeparationRadians = bearingSeparationRadians
            self.residualMetres = residualMetres; self.rmsResidualMetres = rmsResidualMetres
            self.viewsUsed = viewsUsed; self.unavailableReason = unavailableReason
        }

        static func refused(_ name: String, _ reason: String, bearing: Double? = nil, views: [String] = []) -> Result {
            Result(name: name, position: nil, uncertaintyMetres: nil, worstAxisUncertaintyMetres: nil,
                   bearingSeparationRadians: bearing, residualMetres: [:], rmsResidualMetres: nil,
                   viewsUsed: views, unavailableReason: reason)
        }
    }

    /// Triangulate one joint from its observations in two or more views. Never fabricates a
    /// position: every early return carries a stated reason (CLAUDE.md rule 1).
    public static func triangulate(name: String, observations raw: [Observation], options: Options = .init()) -> Result {
        let obs = raw.filter { $0.confidence >= options.minimumConfidence2D && $0.pixel.x.isFinite && $0.pixel.y.isFinite }
        guard obs.count >= 2 else {
            if raw.isEmpty { return .refused(name, "no view observed this joint") }
            if obs.isEmpty {
                return .refused(name, "seen in \(raw.count) view(s), all below the \(options.minimumConfidence2D) confidence gate")
            }
            return .refused(name, "seen in only 1 view above the confidence gate; triangulation needs at least 2", views: obs.map(\.view))
        }

        // `pixelSigma` is in pixels; `focalPx` converts it to an angular (then, given a range, a
        // metric) noise via the small-angle approximation angularSigma ≈ pixelSigma / focalPx. Square
        // pixels are assumed elsewhere in this package (`CameraIntrinsics.init(width:height:
        // horizontalFOVDegrees:)` sets fx = fy); averaging fx and fy costs nothing when that holds
        // and degrades gracefully when it does not.
        struct Ray { let view: String; let origin: SIMD3<Double>; let direction: SIMD3<Double>; let pixelSigma: Double; let focalPx: Double }
        let rays: [Ray] = obs.map { o in
            let dirCam = o.camera.intrinsics.ray(o.pixel)
            let dirWorld = unit(o.camera.pose.rotateBack(dirCam))
            // A low-confidence point is treated as noisier, never as more certain: confidence 1 →
            // the base sigma, confidence → 0 → the observation contributes almost no weight.
            let pixelSigma = options.pixelNoiseSigmaPx / max(o.confidence, 0.05)
            let focalPx = (o.camera.intrinsics.fx + o.camera.intrinsics.fy) / 2
            return Ray(view: o.view, origin: o.camera.pose.position, direction: dirWorld, pixelSigma: pixelSigma, focalPx: focalPx)
        }

        // Bearing separation, computed from the rays themselves (no need for the solved point: a
        // ray's direction is fixed by its camera and pixel alone). This is the parallax angle the
        // sweep in the design doc is run against.
        var bearing = 0.0
        for i in 0..<rays.count {
            for j in (i + 1)..<rays.count { bearing = max(bearing, angleBetween(rays[i].direction, rays[j].direction)) }
        }
        guard bearing >= options.minimumBearingSeparationRadians else {
            return .refused(name, String(format: "the views are only %.1f° apart in bearing at this joint (need %.1f°): the rays are too close to parallel to fix depth reliably",
                                         Angle.degrees(bearing), Angle.degrees(options.minimumBearingSeparationRadians)),
                            bearing: bearing, views: obs.map(\.view))
        }

        // Closest point of approach for a given per-ray weight: two rows per ray (u·X=u·o, v·X=v·o),
        // rows scaled by √weight so the QR solves the weighted problem (`LinAlg` does the scaling).
        func solve(weights: [Double]) -> SIMD3<Double>? {
            var A: [Double] = []; var b: [Double] = []; var w: [Double] = []
            for (r, weight) in zip(rays, weights) {
                let (u, v) = perpendicularBasis(r.direction)
                for basis in [u, v] {
                    A.append(contentsOf: [basis.x, basis.y, basis.z])
                    b.append(dot3(basis, r.origin))
                    w.append(weight)
                }
            }
            guard let x = LinAlg.leastSquaresRowMajor(A, b, rows: A.count / 3, columns: 3, weights: w) else { return nil }
            return SIMD3(x[0], x[1], x[2])
        }

        // Pass 1: pixel-domain weights (1/pixelSigma²) — scale-invariant, so this needs no range
        // estimate yet. Good enough to place X, not yet in the right units for a metric covariance.
        guard let x0 = solve(weights: rays.map { 1 / ($0.pixelSigma * $0.pixelSigma) }) else {
            return .refused(name, "the ray geometry is degenerate (rank-deficient normal equations)", bearing: bearing, views: obs.map(\.view))
        }

        // Pass 2: convert each ray's pixel noise to a **metric** noise via the small-angle
        // approximation angularSigma ≈ pixelSigma/focalPx, metricSigma ≈ angularSigma × range, using
        // pass 1's position for the range. Re-solving with these weights both refines X (a camera
        // twice as far away is down-weighted, correctly, twice as hard) and gives an information
        // matrix whose inverse is an actual position covariance in metres² — pass 1's weights are in
        // 1/px², so an uncertainty computed from them would silently be in pixels, not metres.
        let metricSigma: [Double] = rays.map { r in
            let range = max(norm(x0 - r.origin), 1e-3)
            return r.pixelSigma / r.focalPx * range
        }
        let metricWeights = metricSigma.map { 1 / ($0 * $0) }
        guard let X = solve(weights: metricWeights) else {
            return .refused(name, "the ray geometry is degenerate (rank-deficient normal equations)", bearing: bearing, views: obs.map(\.view))
        }

        var residuals: [String: Double] = [:]
        var squared: [Double] = []
        var information = [[Double]](repeating: [0, 0, 0], count: 3)
        for (r, weight) in zip(rays, metricWeights) {
            let toPoint = X - r.origin
            let along = dot3(toPoint, r.direction)
            let perp = toPoint - along * r.direction
            let d = norm(perp)
            residuals[r.view] = d
            squared.append(d * d)
            for a in 0..<3 { for c in 0..<3 {
                let ident = a == c ? 1.0 : 0.0
                information[a][c] += weight * (ident - component(r.direction, a) * component(r.direction, c))
            } }
        }
        let rms = squared.isEmpty ? nil : (squared.reduce(0, +) / Double(squared.count)).squareRoot()

        var uncertainty: Double? = nil, worstAxis: Double? = nil
        if let cov = invert3x3(information) {
            let (eig, _) = LinAlg.symmetricEigen(cov)
            let variances = eig.map { max($0, 0) }
            uncertainty = (variances.reduce(0, +) / 3).squareRoot()
            worstAxis = variances.max()?.squareRoot()
        }

        return Result(name: name, position: X, uncertaintyMetres: uncertainty, worstAxisUncertaintyMetres: worstAxis,
                      bearingSeparationRadians: bearing, residualMetres: residuals, rmsResidualMetres: rms,
                      viewsUsed: obs.map(\.view), unavailableReason: nil)
    }

    /// Triangulate several joints at once — a convenience over `triangulate(name:observations:)`
    /// for a caller holding one frame's worth of points from every view.
    public static func triangulate(observationsByJoint: [String: [Observation]], options: Options = .init()) -> [String: Result] {
        Dictionary(uniqueKeysWithValues: observationsByJoint.map { name, obs in (name, triangulate(name: name, observations: obs, options: options)) })
    }

    // MARK: - small helpers

    static func component(_ v: SIMD3<Double>, _ i: Int) -> Double { i == 0 ? v.x : (i == 1 ? v.y : v.z) }

    /// An orthonormal basis of the plane perpendicular to a unit vector.
    static func perpendicularBasis(_ d: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let seed = abs(d.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u = unit(cross3(d, seed))
        let v = cross3(d, u)
        return (u, v)
    }

    /// Closed-form 3×3 inverse (cofactor expansion). Nil when singular — the near-parallel gate
    /// above should make that unreachable in practice; this is the defensive fallback.
    static func invert3x3(_ m: [[Double]]) -> [[Double]]? {
        let a = m[0][0], b = m[0][1], c = m[0][2]
        let d = m[1][0], e = m[1][1], f = m[1][2]
        let g = m[2][0], h = m[2][1], i = m[2][2]
        let coA = e * i - f * h, coB = -(d * i - f * g), coC = d * h - e * g
        let det = a * coA + b * coB + c * coC
        guard abs(det) > 1e-12 else { return nil }
        let coD = -(b * i - c * h), coE = a * i - c * g, coF = -(a * h - b * g)
        let coG = b * f - c * e, coH = -(a * f - c * d), coI = a * e - b * d
        return [[coA, coD, coG], [coB, coE, coH], [coC, coF, coI]].map { $0.map { $0 / det } }
    }
}
