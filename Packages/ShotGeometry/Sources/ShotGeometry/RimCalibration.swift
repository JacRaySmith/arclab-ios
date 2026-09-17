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

        let r = options.rimDiameter / 2
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
                    if dot3(normal, options.upHint) < 0 { normal = -normal }
                    found = RimPoseCandidate(center: center, normal: normal)
                    break
                }
            }
            if let f = found { candidates.append(f) }
        }
        guard !candidates.isEmpty else { throw RimCalibrationError.noSolutionInFrontOfCamera }
        if candidates.count == 1 { candidates.append(candidates[0]) }

        let sign: Double = options.cameraBelowRim ? 1 : -1
        let sorted = candidates.sorted { sign * $0.rimHeightAboveCamera > sign * $1.rimHeightAboveCamera }
        let chosen = sorted[0], alternate = sorted[1]
        let ambiguity = angleBetween(chosen.normal, alternate.normal)
        let margin = abs(chosen.rimHeightAboveCamera - alternate.rimHeightAboveCamera)
        if margin < 0.2 {
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
}
