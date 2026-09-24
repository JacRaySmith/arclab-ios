import Foundation

// MARK: - The missing degree of freedom
//
// A traced rim ellipse plus a measured up direction fixes five of the camera's six pose
// parameters: `RimCalibration` gives the rim centre in the camera frame and the camera's tilt
// relative to gravity. What it cannot give is the **bearing** — where around the hoop the camera
// stands — because a circle is symmetric about its own axis. That one free number is why
// `ShotPlaneSolver` has to solve a shot-plane azimuth per shot from weak cues, and why
// `AnalysisOptions.knownReleaseDistance` exists as an escape hatch.
//
// Any second court feature at a known position *relative to the rim* fixes the bearing. This file
// takes marked court features and solves the remaining number, giving a full camera pose in a
// **court frame**:
//
//     origin : the point on the floor directly below the rim centre
//     +x     : horizontal, from the rim centre toward the free-throw line (away from the backboard)
//     +y     : up × x  (so (x, y, z) is right-handed with z up)
//     +z     : up, i.e. `RimCalibration.up`
//
// Every feature kind below reduces, in closed form, to one bearing estimate with an uncertainty,
// and the bearing is then the inverse-variance weighted circular mean of the ones that survive.
// A feature that cannot constrain the bearing — a line parallel to the rim axis, a circle
// concentric with it (the three-point arc), a line whose image runs along the horizon — is
// **refused with a reason**, never silently down-weighted.

/// Painted-marking dimensions the rest of `Court` does not carry, because until now nothing read
/// the floor. NCAA / high-school / FIBA figures: the 12 ft lane and the 12 ft free-throw circle
/// (the NBA's lane is 16 ft; its free-throw circle is the same 12 ft). The lane's half-width and
/// the circle's radius are equal on a 12 ft lane, which is why the lane side lines run tangent to
/// the free-throw circle — the tangency is a property of the court, not of the marking.
public enum CourtMarkings {
    /// Half the lane width, metres (12 ft lane).
    public static let laneHalfWidth: Double = 1.829
    /// Free-throw circle radius, metres (12 ft diameter).
    public static let freeThrowCircleRadius: Double = 1.829
    /// Horizontal distance from the rim centre to the free-throw line, metres.
    public static let freeThrowLineDistance: Double = Court.freeThrowLineToRimCenter
    /// Court-frame centre of the free-throw circle.
    public static let freeThrowCircleCenter = SIMD2<Double>(freeThrowLineDistance, 0)
}

/// Which court feature a bearing estimate came from.
public enum CourtFeatureKind: String, Sendable, Codable {
    case line, circle, point
}

/// A straight painted line of known direction in the court frame (e.g. a lane side line, the
/// free-throw line). Two or more traced image points are enough; more reduce the marking noise.
public struct CourtLineMark: Sendable {
    public var name: String
    /// Points traced along the painted line, in pixels.
    public var imagePoints: [SIMD2<Double>]
    /// The line's direction in the court frame (need not be unit). A **vertical** direction —
    /// parallel to the rim axis — is refused: its vanishing point is fixed by gravity alone and
    /// says nothing about the bearing.
    public var courtDirection: SIMD3<Double>
    /// A point the line is known to pass through, in court coordinates, when that is known
    /// (the free-throw line passes through `(4.191, 0, 0)`). Used only for the reported residual,
    /// never for the bearing: the bearing comes from the direction alone.
    public var courtPointOnLine: SIMD3<Double>?

    public init(name: String, imagePoints: [SIMD2<Double>], courtDirection: SIMD3<Double>,
                courtPointOnLine: SIMD3<Double>? = nil) {
        self.name = name; self.imagePoints = imagePoints
        self.courtDirection = courtDirection; self.courtPointOnLine = courtPointOnLine
    }
}

/// A painted circle lying on the floor at a known court position (the free-throw circle, the
/// centre circle, the three-point arc). Needs ≥ 6 traced points for the conic fit.
public struct CourtCircleMark: Sendable {
    public var name: String
    public var imagePoints: [SIMD2<Double>]
    /// Centre of the circle in court coordinates, metres. `(0, 0)` — concentric with the rim
    /// axis, which is what a three-point arc is — carries **no** bearing information and is
    /// refused for the bearing (it is still used for the scale checks).
    public var courtCenter: SIMD2<Double>
    public var radius: Double

    public init(name: String, imagePoints: [SIMD2<Double>], courtCenter: SIMD2<Double>, radius: Double) {
        self.name = name; self.imagePoints = imagePoints
        self.courtCenter = courtCenter; self.radius = radius
    }
}

/// One image point whose position in the court frame is known — a line intersection, a backboard
/// corner, the inner rectangle's corners (the backboard is rigidly fixed to the rim, so its
/// corners are court points with a known height as well as a known ground position).
public struct CourtPointMark: Sendable {
    public var name: String
    public var imagePoint: SIMD2<Double>
    /// Court coordinates, metres: x along the lane, y across it, z up from the floor.
    public var courtPoint: SIMD3<Double>
    public init(name: String, imagePoint: SIMD2<Double>, courtPoint: SIMD3<Double>) {
        self.name = name; self.imagePoint = imagePoint; self.courtPoint = courtPoint
    }
}

/// Everything marked on one clip.
public struct CourtMarks: Sendable {
    public var lines: [CourtLineMark]
    public var circles: [CourtCircleMark]
    public var points: [CourtPointMark]
    /// Free text recording where the marks came from (which frame, by whom, how).
    public var provenance: String

    public init(lines: [CourtLineMark] = [], circles: [CourtCircleMark] = [],
                points: [CourtPointMark] = [], provenance: String = "") {
        self.lines = lines; self.circles = circles; self.points = points; self.provenance = provenance
    }
    public var isEmpty: Bool { lines.isEmpty && circles.isEmpty && points.isEmpty }
}

public struct CourtCalibrationOptions: Sendable {
    /// Height of the rim above the floor. Used to place the court frame's origin; the recovered
    /// value from an independent floor feature is reported in `CourtChecks.rimHeightAboveFloor`
    /// as a **check**, exactly as `g` is a check and never an input.
    public var rimHeight: Double = Court.rimHeight
    /// Assumed 1σ marking error of a traced image point, pixels. Drives every reported σ.
    public var markSigmaPx: Double = 3
    /// A single feature whose bearing σ exceeds this is refused rather than used (radians).
    public var maximumFeatureBearingSigma: Double = Angle.radians(10)
    /// Warn when two usable features' bearings disagree by more than this (radians).
    public var bearingDisagreementWarning: Double = Angle.radians(4)
    /// Refuse the whole solve when two usable features disagree by more than this (radians).
    public var bearingDisagreementLimit: Double = Angle.radians(25)
    /// The camera is on the court side of the backboard, not behind it. This is what resolves the
    /// 180° ambiguity every direction-only feature has; set false for a camera behind the board.
    public var cameraInFrontOfBackboard: Bool = true
    /// Circles flatter than this are too near edge-on for their centre to be recovered.
    public var minimumCircleAxisRatio: Double = 0.06
    public init() {}
}

public enum CourtCalibrationError: Error, CustomStringConvertible, Sendable {
    case noFeatures
    case noUsableFeature([String])
    case featuresDisagree(spreadDegrees: Double, limitDegrees: Double, detail: String)
    case bearingBranchAmbiguous(cameraOffLaneDegrees: Double)
    case rayAboveHorizon
    case floorIntersectionIllConditioned(rangeSigma: Double, limit: Double, depressionDegrees: Double)

    public var description: String {
        switch self {
        case .noFeatures:
            return "no court features marked: the rim alone cannot fix the camera's bearing (a circle is symmetric about its axis)"
        case .noUsableFeature(let reasons):
            return "no marked court feature can fix the bearing — " + reasons.joined(separator: "; ")
        case .featuresDisagree(let spread, let limit, let detail):
            return String(format: "marked court features disagree on the bearing by %.1f° (limit %.1f°): %@", spread, limit, detail)
        case .bearingBranchAmbiguous(let off):
            return String(format: "only direction-only features (lines) were marked, and the camera stands %.1f° off the lane's centre line — too square across it for \"the camera is in front of the backboard\" to tell the free-throw line from the baseline. Mark a circle or one known point to fix which way the court runs.", off)
        case .rayAboveHorizon:
            return "that image point is above the horizon: its ray never meets the floor"
        case .floorIntersectionIllConditioned(let sigma, let limit, let dep):
            return String(format: "floor intersection is ill-conditioned: the ray meets the floor at %.1f° below horizontal, so a %.0f cm marking error moves the point %.2f m along the ground (limit %.2f m) — measure this shooter's position another way",
                          dep, 0.0, sigma, limit)
        }
    }
}

/// What one marked feature contributed, and what it cost.
public struct CourtFeatureResidual: Sendable {
    public var name: String
    public var kind: CourtFeatureKind
    /// Bearing this feature alone implies, radians in the calibration's horizontal basis. Nil when
    /// the feature was refused for the bearing (`reason` says why).
    public var bearing: Double?
    public var bearingSigma: Double?
    public var used: Bool
    /// RMS reprojection error, in pixels, of this feature's marked points against the solved pose.
    public var residualPx: Double?
    public var reason: String
}

/// Numbers the pose reproduces that it was not fitted to — the honest check on a court solve.
public struct CourtChecks: Sendable {
    /// Rim height above the floor recovered from a marked floor circle's own range, metres.
    /// Nil when no floor circle was marked (a line mark carries no scale).
    public var rimHeightAboveFloor: Double?
    /// Horizontal rim-centre → free-throw-line distance recovered from the marked free-throw
    /// circle's centre, metres. Nil when that circle was not marked.
    public var freeThrowDistance: Double?
    /// The name of the circle each recovered number came from.
    public var scaleSource: String?
    /// Lens height above the floor implied by the rim calibration alone, metres.
    public var cameraHeight: Double
    /// Camera position in court coordinates, metres.
    public var cameraCourtPosition: SIMD3<Double>
    /// Horizontal distance from the rim's floor point to the camera, metres.
    public var cameraHorizontalDistance: Double
    /// Where the camera stands around the hoop: 0° = on the lane's centre line out toward the
    /// free-throw line, +90° = square on the side the +y axis points to.
    public var cameraBearingDegrees: Double
}

/// The full camera pose in the court frame.
public struct CourtCalibration: Sendable {
    public var rim: RimCalibration
    /// Court-frame origin and axes, in the camera frame.
    public var origin: SIMD3<Double>
    public var xAxis: SIMD3<Double>
    public var yAxis: SIMD3<Double>
    public var zAxis: SIMD3<Double>
    /// The recovered bearing: the azimuth of +x in `ShotPlaneSolver.horizontalBasis(up:)`,
    /// i.e. the same parameterisation `ShotPlaneFrame.azimuth` uses.
    public var bearing: Double
    public var bearingSigma: Double
    public var features: [CourtFeatureResidual]
    public var checks: CourtChecks
    public var warnings: [String]

    /// Court coordinates → camera frame.
    public func camera(fromCourt p: SIMD3<Double>) -> SIMD3<Double> {
        origin + p.x * xAxis + p.y * yAxis + p.z * zAxis
    }
    /// Camera frame → court coordinates.
    public func court(fromCamera p: SIMD3<Double>) -> SIMD3<Double> {
        let d = p - origin
        return SIMD3(dot3(d, xAxis), dot3(d, yAxis), dot3(d, zAxis))
    }
    /// Shot-plane azimuth (in the calibration's horizontal basis) for a shooter standing at the
    /// given court ground position: the vertical plane through the rim centre and that point.
    public func shotPlaneAzimuth(standingAtCourt p: SIMD2<Double>) -> Double? {
        guard norm(p) > 1e-6 else { return nil }
        // `ShotPlaneSolver.frame` builds `along = normal × up`, and `normal` is the azimuth
        // direction in (a, b). Solve for the azimuth whose `along` points from the shooter to the
        // rim, i.e. along −p.
        let (a, b) = ShotPlaneSolver.horizontalBasis(up: zAxis)
        let along = unit(-(p.x * xAxis + p.y * yAxis))
        let normalVec = cross3(zAxis, along)          // along = normal × up  ⇒  normal = up × along
        return atan2(dot3(normalVec, b), dot3(normalVec, a))
    }
}

// MARK: - Solver

public enum CourtCalibrator {

    /// Solve the full camera pose in the court frame from a rim calibration and one or more marked
    /// court features. One feature is enough for the bearing; more over-determine it and each one's
    /// own estimate, σ and reprojection residual are reported separately.
    public static func solve(rim: RimCalibration, marks: CourtMarks, intrinsics: CameraIntrinsics,
                             options: CourtCalibrationOptions = .init()) throws -> CourtCalibration {
        guard !marks.isEmpty else { throw CourtCalibrationError.noFeatures }
        let up = unit(rim.up)
        let origin = rim.rimCenter - options.rimHeight * up
        var residuals: [CourtFeatureResidual] = []
        var warnings: [String] = []

        // Each feature, independently, in closed form.
        for line in marks.lines {
            residuals.append(bearingFromLine(line, up: up, origin: origin, intrinsics: intrinsics, options: options))
        }
        for circle in marks.circles {
            residuals.append(bearingFromCircle(circle, up: up, origin: origin, intrinsics: intrinsics, options: options))
        }
        for point in marks.points {
            residuals.append(bearingFromPoint(point, up: up, origin: origin, intrinsics: intrinsics, options: options))
        }

        let usable = residuals.filter { $0.used }
        guard !usable.isEmpty else {
            throw CourtCalibrationError.noUsableFeature(residuals.map { "\($0.name): \($0.reason)" })
        }

        // Every direction-only feature leaves a 180° ambiguity (a line's vanishing point is the
        // same for ±d): a lane side line cannot tell the free-throw line from the baseline. A
        // circle or a known point is *absolute* — it fixes the branch as well as the angle — so
        // when one is present it is the reference everything else folds onto, and the "camera is
        // in front of the backboard" rule becomes a cross-check rather than the only evidence.
        let absolute = usable.filter { $0.kind != .line }
        let reference = (absolute.first ?? usable[0]).bearing!
        var folded: [(psi: Double, sigma: Double, name: String)] = []
        for r in usable {
            var psi = r.bearing!
            if abs(wrapAngle(psi - reference)) > .pi / 2 { psi += .pi }
            folded.append((wrapAngle(psi), max(r.bearingSigma ?? Angle.radians(1), 1e-4), r.name))
        }
        var bearing = circularWeightedMean(folded.map { ($0.psi, 1 / ($0.sigma * $0.sigma)) })
        var sigma = (1 / folded.map { 1 / ($0.sigma * $0.sigma) }.reduce(0, +)).squareRoot()

        // Disagreement between features is the honest error bar when there is more than one.
        if folded.count >= 2 {
            var worst = 0.0, detail = ""
            for i in 0..<folded.count {
                for j in (i + 1)..<folded.count {
                    let d = abs(wrapAngle(folded[i].psi - folded[j].psi))
                    if d > worst {
                        worst = d
                        detail = String(format: "%@ %.1f° vs %@ %.1f°", folded[i].name, Angle.degrees(folded[i].psi),
                                        folded[j].name, Angle.degrees(folded[j].psi))
                    }
                }
            }
            if worst > options.bearingDisagreementLimit {
                throw CourtCalibrationError.featuresDisagree(spreadDegrees: Angle.degrees(worst),
                                                             limitDegrees: Angle.degrees(options.bearingDisagreementLimit),
                                                             detail: detail)
            }
            if worst > options.bearingDisagreementWarning {
                warnings.append(String(format: "marked court features disagree on the bearing by %.1f° (%@); the pose is no better than that", Angle.degrees(worst), detail))
            }
            // Never report a σ tighter than the features' own disagreement implies.
            sigma = max(sigma, worst / 2)
        }

        // Resolve the 180° branch: the camera must be in front of the backboard (court x > 0).
        func axes(_ psi: Double) -> (SIMD3<Double>, SIMD3<Double>) {
            let (a, b) = ShotPlaneSolver.horizontalBasis(up: up)
            let x = cos(psi) * a + sin(psi) * b
            return (x, cross3(up, x))
        }
        if options.cameraInFrontOfBackboard {
            let (x0, y0) = axes(bearing)
            let alongLane = dot3(-origin, x0), acrossLane = dot3(-origin, y0)
            // 0° = the camera stands square across the lane (where the rule below is useless);
            // 90° = it stands on the lane's own centre line (where the rule is decisive).
            let offLane = asin(min(1, abs(alongLane) / max(norm(SIMD2(alongLane, acrossLane)), 1e-9)))
            if absolute.isEmpty {
                // Direction-only features alone: the branch rests entirely on this rule, and the
                // rule is itself degenerate for a camera standing square across the lane.
                guard offLane > Angle.radians(8) else {
                    throw CourtCalibrationError.bearingBranchAmbiguous(cameraOffLaneDegrees: Angle.degrees(offLane))
                }
                if alongLane < 0 { bearing = wrapAngle(bearing + .pi) }
            } else if alongLane < 0 && offLane > Angle.radians(8) {
                warnings.append(String(format: "a circle or point mark puts the camera %.1f m *behind* the backboard; trusting the mark over the in-front-of-the-backboard rule, but one of the two is wrong", -alongLane))
            }
        }
        let (xAxis, yAxis) = axes(bearing)

        var cal = CourtCalibration(rim: rim, origin: origin, xAxis: xAxis, yAxis: yAxis, zAxis: up,
                                   bearing: bearing, bearingSigma: sigma, features: residuals,
                                   checks: CourtChecks(rimHeightAboveFloor: nil, freeThrowDistance: nil, scaleSource: nil,
                                                       cameraHeight: 0, cameraCourtPosition: .zero,
                                                       cameraHorizontalDistance: 0, cameraBearingDegrees: 0),
                                   warnings: rim.warnings + warnings)

        // Reprojection residuals at the solved pose.
        for i in residuals.indices {
            let m = residuals[i]
            switch m.kind {
            case .line:
                if let mark = marks.lines.first(where: { $0.name == m.name }) {
                    cal.features[i].residualPx = lineResidualPx(mark, calibration: cal, intrinsics: intrinsics)
                }
            case .circle:
                if let mark = marks.circles.first(where: { $0.name == m.name }) {
                    cal.features[i].residualPx = circleResidualPx(mark, calibration: cal, intrinsics: intrinsics)
                }
            case .point:
                if let mark = marks.points.first(where: { $0.name == m.name }) {
                    let P = cal.camera(fromCourt: mark.courtPoint)
                    if P.z > 1e-6 {
                        let px = intrinsics.pixel(fromNormalized: SIMD2(P.x / P.z, P.y / P.z))
                        cal.features[i].residualPx = norm(px - mark.imagePoint)
                    }
                }
            }
        }

        // Checks: numbers the pose reproduces that it was not fitted to.
        cal.checks = checks(for: cal, marks: marks, intrinsics: intrinsics, options: options)
        if let h = cal.checks.rimHeightAboveFloor, abs(h - options.rimHeight) > 0.25 {
            cal.warnings.append(String(format: "a marked floor circle puts the rim %.2f m above the floor, not %.3f m — the focal length, the rim trace or the marks are wrong (this is the court solve's own g-test)", h, options.rimHeight))
        }
        return cal
    }

    // MARK: - one feature at a time

    /// A horizontal line of known court direction fixes the bearing through its **vanishing point**:
    /// all horizontal directions image onto the horizon line `Kᵀ·u = 0`, and the marked line meets
    /// that horizon exactly at the image of its own direction. No scale, no position, no rim height
    /// is involved — which is why a lane side line is the cheapest bearing there is.
    static func bearingFromLine(_ mark: CourtLineMark, up: SIMD3<Double>, origin: SIMD3<Double>,
                                intrinsics: CameraIntrinsics, options: CourtCalibrationOptions) -> CourtFeatureResidual {
        func refuse(_ why: String) -> CourtFeatureResidual {
            CourtFeatureResidual(name: mark.name, kind: .line, bearing: nil, bearingSigma: nil, used: false, residualPx: nil, reason: why)
        }
        guard mark.imagePoints.count >= 2 else { return refuse("a line needs ≥ 2 traced points, got \(mark.imagePoints.count)") }
        let dCourt = mark.courtDirection
        guard norm(dCourt) > 1e-9 else { return refuse("court direction is the zero vector") }
        let horizontal = SIMD2(dCourt.x, dCourt.y)
        if norm(horizontal) < 0.05 * norm(dCourt) {
            return refuse("this line is parallel to the rim axis (vertical); its vanishing point is fixed by gravity alone and says nothing about the bearing")
        }
        let theta = atan2(horizontal.y, horizontal.x)

        guard let (psi, sigma, vpDistance) = lineBearing(mark.imagePoints, theta: theta, up: up,
                                                         intrinsics: intrinsics, sigmaPx: options.markSigmaPx) else {
            return refuse("the traced points do not define a line")
        }
        if !sigma.isFinite || sigma > options.maximumFeatureBearingSigma {
            return refuse(String(format: "seen almost fronto-parallel: its image runs within %.2f° of the horizon, so the vanishing point is %.0f px away and a %.0f px marking error swings the bearing by %.0f°",
                                 Angle.degrees(atan2(1.0, max(vpDistance, 1))), vpDistance, options.markSigmaPx,
                                 sigma.isFinite ? Angle.degrees(sigma) : 999))
        }
        return CourtFeatureResidual(name: mark.name, kind: .line, bearing: psi, bearingSigma: sigma, used: true,
                                    residualPx: nil,
                                    reason: String(format: "vanishing point %.0f px from the principal point; σ %.2f°", vpDistance, Angle.degrees(sigma)))
    }

    /// Bearing from one image line, its known court direction angle `theta`, and gravity.
    /// Returns nil when the points are coincident. σ comes from perturbing the fitted image line by
    /// the marking error — rotating it about the marks' centroid and shifting it sideways — which is
    /// exactly the geometry that blows up when the line is seen fronto-parallel.
    static func lineBearing(_ points: [SIMD2<Double>], theta: Double, up: SIMD3<Double>,
                            intrinsics: CameraIntrinsics, sigmaPx: Double) -> (psi: Double, sigma: Double, vpDistance: Double)? {
        guard let fit = fitImageLine(points) else { return nil }
        guard let psi = bearing(fromImageLine: fit.line, theta: theta, up: up, intrinsics: intrinsics) else { return nil }
        let vp = vanishingPoint(fit.line, up: up, intrinsics: intrinsics)
        let vpDistance = vp.map { norm($0 - SIMD2(intrinsics.cx, intrinsics.cy)) } ?? .infinity

        // Angular uncertainty of the fitted image line: a σ_px scatter over a span S rotates the
        // line by about σ_px/S (with n points, σ_px/(S·√n·…) — keep the conservative 1/√n form).
        let span = max(fit.span, 1)
        let dAngle = sigmaPx / span * (2 / Double(points.count).squareRoot())
        let dOffset = sigmaPx / Double(points.count).squareRoot()
        var worst = 0.0
        for da in [-dAngle, dAngle] {
            for dOff in [-dOffset, dOffset] {
                let perturbed = perturb(fit, angle: da, offset: dOff)
                guard let p2 = bearing(fromImageLine: perturbed, theta: theta, up: up, intrinsics: intrinsics) else {
                    return (psi, .infinity, vpDistance)
                }
                worst = max(worst, abs(wrapAngle(halfTurnFold(p2 - psi))))
            }
        }
        return (psi, worst, vpDistance)
    }

    /// A circle painted on the floor at a known court position gives the bearing from the direction
    /// of its centre, and — because its radius is known — an independent range, which is what makes
    /// `CourtChecks.rimHeightAboveFloor` a real check rather than a restatement of the input.
    static func bearingFromCircle(_ mark: CourtCircleMark, up: SIMD3<Double>, origin: SIMD3<Double>,
                                  intrinsics: CameraIntrinsics, options: CourtCalibrationOptions) -> CourtFeatureResidual {
        func refuse(_ why: String) -> CourtFeatureResidual {
            CourtFeatureResidual(name: mark.name, kind: .circle, bearing: nil, bearingSigma: nil, used: false, residualPx: nil, reason: why)
        }
        guard mark.imagePoints.count >= 6 else { return refuse("a circle needs ≥ 6 traced points, got \(mark.imagePoints.count)") }
        guard mark.radius > 0 else { return refuse("circle radius must be positive") }
        let offset = norm(mark.courtCenter)
        guard let centre = floorCircleCentre(mark, up: up, intrinsics: intrinsics, options: options, origin: origin) else {
            return refuse("no horizontal circle of radius \(String(format: "%.3f", mark.radius)) m reproduces these points (too few, too flat, or not a circle's image)")
        }
        if offset < 0.25 {
            return refuse(String(format: "this circle is concentric with the rim axis (its court centre is %.2f m from it), so it is symmetric about exactly the axis whose rotation is unknown — it fixes the scale, never the bearing", offset))
        }
        let h = horizontal(centre - origin, up: up)
        guard norm(h) > 1e-6 else { return refuse("solved circle centre sits on the rim axis; no direction to read") }
        let (a, b) = ShotPlaneSolver.horizontalBasis(up: up)
        let phi = atan2(dot3(h, b), dot3(h, a))
        let psi = wrapAngle(phi - atan2(mark.courtCenter.y, mark.courtCenter.x))

        // σ: translate the whole traced circle by the *standard error of its centroid* — a marking
        // error of `markSigmaPx` per point over n points — and see how far the implied bearing
        // moves. Translation is the mode that matters: it slides the solved centre bodily, and for
        // a circle seen nearly edge-on that slide is large. The lever arm is the circle's court
        // offset, so a circle close to the rim axis is weak and one far from it is strong — the
        // same geometry the refusal above states in the limit.
        let centroidSigma = options.markSigmaPx / Double(mark.imagePoints.count).squareRoot()
        var worst = 0.0
        for d in [SIMD2(centroidSigma, 0), SIMD2(-centroidSigma, 0),
                  SIMD2(0, centroidSigma), SIMD2(0, -centroidSigma)] {
            var shifted = mark
            shifted.imagePoints = mark.imagePoints.map { $0 + d }
            guard let c2 = floorCircleCentre(shifted, up: up, intrinsics: intrinsics, options: options, origin: origin) else {
                return refuse("the circle solve is unstable under a \(String(format: "%.1f", centroidSigma)) px shift of its whole trace")
            }
            let h2 = horizontal(c2 - origin, up: up)
            guard norm(h2) > 1e-6 else { continue }
            let phi2 = atan2(dot3(h2, b), dot3(h2, a))
            worst = max(worst, abs(wrapAngle(phi2 - phi)))
        }
        if worst > options.maximumFeatureBearingSigma {
            return refuse(String(format: "the solved centre moves too much under a %.1f px shift of its whole trace (%.0f px per point over %d points): bearing σ %.1f°",
                                 centroidSigma, options.markSigmaPx, mark.imagePoints.count, Angle.degrees(worst)))
        }
        return CourtFeatureResidual(name: mark.name, kind: .circle, bearing: psi, bearingSigma: max(worst, 1e-4), used: true,
                                    residualPx: nil,
                                    reason: String(format: "centre %.2f m from the rim axis (lever arm); σ %.2f°", norm(h), Angle.degrees(worst)))
    }

    /// One point of known court position. Gravity gives the height, so the ray's intersection with
    /// the horizontal plane through that point is known without the bearing; the bearing then falls
    /// out of the direction from the rim axis to it.
    static func bearingFromPoint(_ mark: CourtPointMark, up: SIMD3<Double>, origin: SIMD3<Double>,
                                 intrinsics: CameraIntrinsics, options: CourtCalibrationOptions) -> CourtFeatureResidual {
        func refuse(_ why: String) -> CourtFeatureResidual {
            CourtFeatureResidual(name: mark.name, kind: .point, bearing: nil, bearingSigma: nil, used: false, residualPx: nil, reason: why)
        }
        let lever = norm(SIMD2(mark.courtPoint.x, mark.courtPoint.y))
        if lever < 0.25 {
            return refuse(String(format: "this point is on the rim axis (%.2f m from it), so rotating the court about that axis does not move it — it cannot fix the bearing", lever))
        }
        guard let h = horizontalOffsetOfPlanePoint(mark.imagePoint, height: mark.courtPoint.z, up: up,
                                                   origin: origin, intrinsics: intrinsics) else {
            return refuse("the ray through this point never meets the horizontal plane at its own height (it is above the horizon)")
        }
        let (a, b) = ShotPlaneSolver.horizontalBasis(up: up)
        let phi = atan2(dot3(h, b), dot3(h, a))
        let psi = wrapAngle(phi - atan2(mark.courtPoint.y, mark.courtPoint.x))
        var worst = 0.0
        for d in [SIMD2(options.markSigmaPx, 0), SIMD2(-options.markSigmaPx, 0),
                  SIMD2(0, options.markSigmaPx), SIMD2(0, -options.markSigmaPx)] {
            guard let h2 = horizontalOffsetOfPlanePoint(mark.imagePoint + d, height: mark.courtPoint.z, up: up,
                                                        origin: origin, intrinsics: intrinsics) else {
                return refuse("the plane intersection is unstable under a \(String(format: "%.0f", options.markSigmaPx)) px marking error")
            }
            worst = max(worst, abs(wrapAngle(atan2(dot3(h2, b), dot3(h2, a)) - phi)))
        }
        if worst > options.maximumFeatureBearingSigma {
            return refuse(String(format: "grazing view: a %.0f px marking error swings this point's bearing by %.1f°",
                                 options.markSigmaPx, Angle.degrees(worst)))
        }
        return CourtFeatureResidual(name: mark.name, kind: .point, bearing: psi, bearingSigma: max(worst, 1e-4), used: true,
                                    residualPx: nil,
                                    reason: String(format: "%.2f m from the rim axis (lever arm); σ %.2f°", lever, Angle.degrees(worst)))
    }

    // MARK: - checks

    static func checks(for cal: CourtCalibration, marks: CourtMarks, intrinsics: CameraIntrinsics,
                       options: CourtCalibrationOptions) -> CourtChecks {
        let camCourt = cal.court(fromCamera: .zero)
        var rimHeight: Double? = nil, ftDistance: Double? = nil, source: String? = nil
        // Prefer the circle with the largest lever arm — the best-conditioned one.
        let usableCircles = marks.circles
            .compactMap { m -> (CourtCircleMark, SIMD3<Double>)? in
                guard let c = floorCircleCentre(m, up: cal.zAxis, intrinsics: intrinsics, options: options, origin: cal.origin) else { return nil }
                return (m, c)
            }
            .sorted { norm($0.0.courtCenter) > norm($1.0.courtCenter) }
        if let (mark, centre) = usableCircles.first {
            rimHeight = dot3(cal.rim.rimCenter - centre, cal.zAxis)
            ftDistance = norm(horizontal(centre - cal.rim.rimCenter, up: cal.zAxis))
            source = mark.name
        }
        return CourtChecks(rimHeightAboveFloor: rimHeight, freeThrowDistance: ftDistance, scaleSource: source,
                           cameraHeight: Court.rimHeight - cal.rim.rimHeightAboveCamera,
                           cameraCourtPosition: camCourt,
                           cameraHorizontalDistance: norm(SIMD2(camCourt.x, camCourt.y)),
                           cameraBearingDegrees: Angle.degrees(atan2(camCourt.y, camCourt.x)))
    }

    // MARK: - the shooter as a measurement

    /// Where a point marked in the image stands on the floor, in court coordinates, with the
    /// uncertainty the geometry actually carries.
    ///
    /// The floor intersection is **ill-conditioned for a near-level camera**: the range along the
    /// ground grows as `L²·σ_px/(f·h)` — quadratic in the distance and inversely proportional to
    /// the lens height — while the *lateral* position (and so the shot-plane azimuth) only grows as
    /// `L·σ_px/f`. That asymmetry is the whole point: a low camera measures a shooter's **bearing**
    /// well and their **distance** badly, so this refuses rather than reports a distance it cannot
    /// support, and says which of the two failed.
    public static func floorPoint(_ imagePoint: SIMD2<Double>, calibration cal: CourtCalibration,
                                  intrinsics: CameraIntrinsics, pixelSigma: Double = 4,
                                  maximumRangeSigma: Double = 0.75) throws -> CourtFloorPoint {
        guard let p = floorIntersection(imagePoint, cal: cal, intrinsics: intrinsics) else {
            throw CourtCalibrationError.rayAboveHorizon
        }
        let court = cal.court(fromCamera: p)
        let ground = SIMD2(court.x, court.y)
        let ray = intrinsics.ray(imagePoint)
        let depression = asin(max(-1, min(1, -dot3(ray, cal.zAxis))))

        // Exact finite-difference propagation: no algebra to get wrong. "Radial" is along the line
        // of sight *from the camera* — that is the direction the grazing intersection is soft in —
        // and "lateral" is across it.
        var dRadial = 0.0, dLateral = 0.0, dAcrossShotLine = 0.0
        let camCourt = cal.court(fromCamera: .zero)
        let sightline = ground - SIMD2(camCourt.x, camCourt.y)
        let radialDir = norm(sightline) > 1e-6 ? sightline / norm(sightline) : SIMD2(1.0, 0)
        let lateralDir = SIMD2(-radialDir.y, radialDir.x)
        // The shot plane's azimuth only cares about movement perpendicular to the rim→shooter line.
        let shotDir = norm(ground) > 1e-6 ? ground / norm(ground) : SIMD2(1.0, 0)
        let shotPerp = SIMD2(-shotDir.y, shotDir.x)
        for d in [SIMD2(pixelSigma, 0), SIMD2(-pixelSigma, 0), SIMD2(0, pixelSigma), SIMD2(0, -pixelSigma)] {
            guard let q = floorIntersection(imagePoint + d, cal: cal, intrinsics: intrinsics) else {
                throw CourtCalibrationError.floorIntersectionIllConditioned(rangeSigma: .infinity,
                                                                            limit: maximumRangeSigma,
                                                                            depressionDegrees: Angle.degrees(depression))
            }
            let c = cal.court(fromCamera: q)
            let delta = SIMD2(c.x, c.y) - ground
            dRadial = max(dRadial, abs(dot2(delta, radialDir)))
            dLateral = max(dLateral, abs(dot2(delta, lateralDir)))
            dAcrossShotLine = max(dAcrossShotLine, abs(dot2(delta, shotPerp)))
        }
        guard dRadial <= maximumRangeSigma else {
            throw CourtCalibrationError.floorIntersectionIllConditioned(rangeSigma: dRadial, limit: maximumRangeSigma,
                                                                        depressionDegrees: Angle.degrees(depression))
        }
        let distance = norm(ground)
        var warnings: [String] = []
        if dRadial > 0.25 {
            warnings.append(String(format: "shooter distance is soft: %.2f m at 1σ from a %.0f px mark, because the camera is only %.2f m up and the ray meets the floor at %.1f° — the bearing (σ %.2f°) is far better determined than the distance",
                                   dRadial, pixelSigma, cal.checks.cameraHeight, Angle.degrees(depression),
                                   Angle.degrees(distance > 1e-6 ? dLateral / distance : .infinity)))
        }
        let azSigma = distance > 1e-6 ? dAcrossShotLine / distance : Double.infinity
        let azimuth = cal.shotPlaneAzimuth(standingAtCourt: ground)
        return CourtFloorPoint(court: ground, camera: p, horizontalDistanceToRim: distance,
                               shotPlaneAzimuth: azimuth, rangeSigma: dRadial, lateralSigma: dLateral,
                               azimuthSigma: azSigma, depressionAngle: depression, warnings: warnings)
    }

    static func floorIntersection(_ px: SIMD2<Double>, cal: CourtCalibration, intrinsics: CameraIntrinsics) -> SIMD3<Double>? {
        let ray = intrinsics.ray(px)
        let denom = dot3(ray, cal.zAxis)
        guard denom < -1e-9 else { return nil }            // must point below the horizon
        let lambda = dot3(cal.origin, cal.zAxis) / denom
        guard lambda > 0.1 else { return nil }
        return lambda * ray
    }

    // MARK: - helpers

    struct ImageLineFit {
        var line: SIMD3<Double>        // homogeneous (a, b, c) with a·u + b·v + c = 0, (a, b) unit
        var centroid: SIMD2<Double>
        var span: Double
    }

    /// Total-least-squares line through image points.
    static func fitImageLine(_ pts: [SIMD2<Double>]) -> ImageLineFit? {
        guard pts.count >= 2 else { return nil }
        var mx = 0.0, my = 0.0
        for p in pts { mx += p.x; my += p.y }
        mx /= Double(pts.count); my /= Double(pts.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts {
            let dx = p.x - mx, dy = p.y - my
            sxx += dx * dx; sxy += dx * dy; syy += dy * dy
        }
        guard sxx + syy > 1e-12 else { return nil }
        // Principal direction = eigenvector of the largest eigenvalue.
        let eig = LinAlg.eigen2x2(p: sxx, q: sxy, r: syy)
        guard let major = eig.max(by: { $0.value < $1.value }) else { return nil }
        let dir = major.vector
        let n = SIMD2(-dir.y, dir.x)                       // normal
        let nn = norm(n) > 1e-12 ? n / norm(n) : SIMD2(0.0, 1)
        let c = -(nn.x * mx + nn.y * my)
        var lo = Double.infinity, hi = -Double.infinity
        for p in pts {
            let t = (p.x - mx) * dir.x + (p.y - my) * dir.y
            lo = min(lo, t); hi = max(hi, t)
        }
        return ImageLineFit(line: SIMD3(nn.x, nn.y, c), centroid: SIMD2(mx, my), span: hi - lo)
    }

    static func perturb(_ fit: ImageLineFit, angle: Double, offset: Double) -> SIMD3<Double> {
        let n = SIMD2(fit.line.x, fit.line.y)
        let rotated = SIMD2(n.x * cos(angle) - n.y * sin(angle), n.x * sin(angle) + n.y * cos(angle))
        let c = -(rotated.x * fit.centroid.x + rotated.y * fit.centroid.y) + offset
        return SIMD3(rotated.x, rotated.y, c)
    }

    /// The horizon of horizontal planes, as a homogeneous image line: a normalised ray `m` is
    /// horizontal iff `m·u = 0`, and `m = K⁻¹x`, so the pixel line is `K⁻ᵀu`.
    static func horizonLine(up: SIMD3<Double>, intrinsics k: CameraIntrinsics) -> SIMD3<Double> {
        SIMD3(up.x / k.fx, up.y / k.fy, up.z - k.cx * up.x / k.fx - k.cy * up.y / k.fy)
    }

    static func vanishingPoint(_ line: SIMD3<Double>, up: SIMD3<Double>, intrinsics k: CameraIntrinsics) -> SIMD2<Double>? {
        let h = horizonLine(up: up, intrinsics: k)
        let v = cross3(line, h)
        guard abs(v.z) > 1e-12 else { return nil }
        return SIMD2(v.x / v.z, v.y / v.z)
    }

    /// Bearing implied by one image line of known court direction angle `theta` (from +x).
    static func bearing(fromImageLine line: SIMD3<Double>, theta: Double, up: SIMD3<Double>,
                        intrinsics k: CameraIntrinsics) -> Double? {
        let h = horizonLine(up: up, intrinsics: k)
        let v = cross3(line, h)                            // homogeneous vanishing point, pixels
        // `v` may be at infinity (v.z == 0); the direction is still K⁻¹v either way.
        let m = SIMD3((v.x - k.cx * v.z) / k.fx, (v.y - k.cy * v.z) / k.fy, v.z)
        guard norm(m) > 1e-12 else { return nil }
        var d = unit(m)
        d = unit(d - dot3(d, up) * up)                      // force exactly horizontal
        guard norm(d) > 1e-9 else { return nil }
        // d = cos θ·x̂ + sin θ·(u × x̂)  ⇒  x̂ = cos θ·d − sin θ·(u × d)
        let x = cos(theta) * d - sin(theta) * cross3(up, d)
        let (a, b) = ShotPlaneSolver.horizontalBasis(up: up)
        return atan2(dot3(x, b), dot3(x, a))
    }

    /// Centre, in the camera frame, of a horizontal circle of known radius traced in the image.
    ///
    /// Not via a conic fit. Court paint is almost never a *whole* circle in view — the free-throw
    /// circle's far half lies inside the lane and on this corpus is not painted at all — and an
    /// ellipse fitted to half an arc wanders badly on the half that was never traced, which then
    /// drags the solved centre tens of degrees off. The plane's normal is already known (gravity),
    /// so a much more direct route works on an arc:
    ///
    /// 1. Back-project every marked point onto the *assumed* floor plane (the one `rimHeight` below
    ///    the rim centre). On that plane the traced points are a circle, up to one unknown scale.
    /// 2. Fit a circle to them in the plane, centre **and** radius free (Kåsa's linear fit).
    /// 3. The fitted radius against the known radius *is* that scale: moving the plane to distance
    ///    `s·D` scales every back-projected point by `s` about the camera centre, so
    ///    `s = r_known / r_fitted` exactly, and the true circle centre is `s` times the fitted one.
    ///
    /// Step 3 is where the independent range comes from — it is the only thing in this file that
    /// knows how far away anything is without being told, and it is what makes
    /// `CourtChecks.rimHeightAboveFloor` a check on the rim calibration rather than a restatement
    /// of it.
    static func floorCircleCentre(_ mark: CourtCircleMark, up: SIMD3<Double>, intrinsics: CameraIntrinsics,
                                  options: CourtCalibrationOptions, origin: SIMD3<Double>) -> SIMD3<Double>? {
        guard mark.imagePoints.count >= 6, mark.radius > 0 else { return nil }
        let dFloor = dot3(origin, up)
        guard dFloor < -1e-6 else { return nil }             // the floor must be below the camera
        let (e1, e2) = ShotPlaneSolver.horizontalBasis(up: up)
        var xs: [Double] = [], ys: [Double] = []
        for px in mark.imagePoints {
            let ray = intrinsics.ray(px)
            let denom = dot3(ray, up)
            guard denom < -1e-9 else { return nil }
            let p = (dFloor / denom) * ray
            xs.append(dot3(p, e1)); ys.append(dot3(p, e2))
        }
        // Kåsa: x² + y² = A·x + B·y + C  ⇒  centre (A/2, B/2), r² = C + (A² + B²)/4.
        var A = [[Double]](); var b = [Double]()
        for i in 0..<xs.count {
            A.append([xs[i], ys[i], 1])
            b.append(xs[i] * xs[i] + ys[i] * ys[i])
        }
        guard let sol = LinAlg.leastSquares(A, b) else { return nil }
        let cx = sol[0] / 2, cy = sol[1] / 2
        let r2 = sol[2] + cx * cx + cy * cy
        guard r2 > 1e-9 else { return nil }
        let rFitted = r2.squareRoot()
        let scale = mark.radius / rFitted
        guard scale.isFinite, scale > 0.05, scale < 20 else { return nil }
        // How well the marked arc is really a circle in this plane, in metres — the conditioning
        // guard that replaces the ellipse fit's axis-ratio test.
        var worstResidual = 0.0
        for i in 0..<xs.count {
            worstResidual = max(worstResidual, abs(norm(SIMD2(xs[i] - cx, ys[i] - cy)) - rFitted))
        }
        guard worstResidual < 0.5 * rFitted else { return nil }
        return scale * (dFloor * up + cx * e1 + cy * e2)
    }

    /// Where the ray through `px` meets the horizontal plane `height` metres above the floor,
    /// expressed as the horizontal offset from the rim axis (camera-frame vector, ⟂ up).
    static func horizontalOffsetOfPlanePoint(_ px: SIMD2<Double>, height: Double, up: SIMD3<Double>,
                                             origin: SIMD3<Double>, intrinsics: CameraIntrinsics) -> SIMD3<Double>? {
        let ray = intrinsics.ray(px)
        let denom = dot3(ray, up)
        let target = dot3(origin, up) + height
        guard abs(denom) > 1e-9 else { return nil }
        let lambda = target / denom
        guard lambda > 0.1 else { return nil }
        return horizontal(lambda * ray - origin, up: up)
    }

    static func horizontal(_ v: SIMD3<Double>, up: SIMD3<Double>) -> SIMD3<Double> { v - dot3(v, up) * up }

    static func lineResidualPx(_ mark: CourtLineMark, calibration cal: CourtCalibration, intrinsics: CameraIntrinsics) -> Double? {
        guard let point = mark.courtPointOnLine else { return nil }
        let dCourt = unit(mark.courtDirection)
        let P0 = cal.camera(fromCourt: point)
        let P1 = cal.camera(fromCourt: point + 3 * dCourt)
        guard P0.z > 1e-6, P1.z > 1e-6 else { return nil }
        let a = intrinsics.pixel(fromNormalized: SIMD2(P0.x / P0.z, P0.y / P0.z))
        let b = intrinsics.pixel(fromNormalized: SIMD2(P1.x / P1.z, P1.y / P1.z))
        let dir = b - a
        guard norm(dir) > 1e-9 else { return nil }
        let n = SIMD2(-dir.y, dir.x) / norm(dir)
        var sse = 0.0
        for p in mark.imagePoints {
            let e = dot2(p - a, n)
            sse += e * e
        }
        return (sse / Double(mark.imagePoints.count)).squareRoot()
    }

    static func circleResidualPx(_ mark: CourtCircleMark, calibration cal: CourtCalibration, intrinsics: CameraIntrinsics) -> Double? {
        var sse = 0.0
        var n = 0
        // Distance from each marked point to the projected circle, measured along the image ray:
        // sample the circle densely and take the nearest projected sample.
        var projected: [SIMD2<Double>] = []
        for k in 0..<360 {
            let t = 2 * Double.pi * Double(k) / 360
            let p = SIMD3(mark.courtCenter.x + mark.radius * cos(t), mark.courtCenter.y + mark.radius * sin(t), 0)
            let P = cal.camera(fromCourt: p)
            guard P.z > 1e-6 else { continue }
            projected.append(intrinsics.pixel(fromNormalized: SIMD2(P.x / P.z, P.y / P.z)))
        }
        guard projected.count > 8 else { return nil }
        for p in mark.imagePoints {
            var best = Double.infinity
            for q in projected { best = min(best, norm(p - q)) }
            sse += best * best
            n += 1
        }
        return n > 0 ? (sse / Double(n)).squareRoot() : nil
    }

    static func wrapAngle(_ x: Double) -> Double { atan2(sin(x), cos(x)) }
    /// Fold an angle difference into (−π/2, π/2]: a line's direction is only known up to sign.
    static func halfTurnFold(_ x: Double) -> Double {
        var d = wrapAngle(x)
        if d > .pi / 2 { d -= .pi }
        if d < -.pi / 2 { d += .pi }
        return d
    }
    static func circularWeightedMean(_ values: [(Double, Double)]) -> Double {
        var s = 0.0, c = 0.0
        for (psi, w) in values { s += w * sin(psi); c += w * cos(psi) }
        return atan2(s, c)
    }
}

@inlinable func dot2(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }

/// A point on the floor, measured rather than assumed.
public struct CourtFloorPoint: Sendable {
    /// Ground position in court coordinates, metres.
    public var court: SIMD2<Double>
    /// The same point in the camera frame.
    public var camera: SIMD3<Double>
    /// Horizontal distance from the rim centre's floor point, metres.
    public var horizontalDistanceToRim: Double
    /// Shot-plane azimuth of the vertical plane through the rim centre and this point, radians in
    /// the calibration's horizontal basis — nil only when the point is on the rim axis.
    public var shotPlaneAzimuth: Double?
    /// 1σ along the line of sight, metres. This is the number that goes bad for a level camera.
    public var rangeSigma: Double
    /// 1σ across the line of sight, metres.
    public var lateralSigma: Double
    /// 1σ of `shotPlaneAzimuth`, radians.
    public var azimuthSigma: Double
    /// How far below horizontal the ray meets the floor, radians.
    public var depressionAngle: Double
    public var warnings: [String]
}
