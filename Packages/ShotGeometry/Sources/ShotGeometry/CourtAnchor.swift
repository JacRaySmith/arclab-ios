import Foundation

/// A window of allowed shot-plane azimuths, as a centre and a half-width (radians). A set of these
/// is what a court-anchored pose hands the azimuth solve in place of the free 0…2π scan.
public struct AzimuthWindow: Sendable, Equatable {
    public var center: Double
    public var halfWidth: Double
    public init(center: Double, halfWidth: Double) { self.center = center; self.halfWidth = halfWidth }

    public func contains(_ azimuth: Double) -> Bool {
        let d = atan2(sin(azimuth - center), cos(azimuth - center))
        return abs(d) <= halfWidth + 1e-12
    }
}

/// Court anchoring for one shot: what a solved `CourtCalibration` (plus, where it exists, a
/// measured shooter position) is allowed to tell `ShotAnalyzer`.
///
/// **Defaulted off** everywhere: `AnalysisOptions.courtAnchor` is `nil` unless a caller sets it, so
/// nothing that ships today changes. What it does when set is narrow and stated: it replaces the
/// free 0…2π azimuth scan with a scan over the azimuth windows the court pose allows. It never
/// replaces the fit, never touches `g`, and never invents a release distance unless
/// `constrainReleaseDistance` is set and a measured standing position exists.
public struct CourtShotAnchor: Sendable {
    /// The solved court pose this anchor comes from.
    public var calibration: CourtCalibration
    /// The shooter's measured standing position, when one was measured for this shot.
    public var standing: CourtFloorPoint?
    /// Extra azimuth candidates (radians, in the calibration's horizontal basis) beyond `standing`
    /// — e.g. the two elbows of a court, or a marked station per block.
    public var azimuthCandidates: [Double]
    /// Half-width applied around every candidate, radians. A shooter is not a point: they step,
    /// drift and lean, so this is never zero.
    public var azimuthTolerance: Double
    /// When no candidate exists, fall back to the sector of azimuths that put the shooter on the
    /// court at all — in front of the backboard, within `maximumCourtHalfWidth` of the lane's
    /// centre line. This is weaker than a measured station but still far narrower than 0…2π.
    public var useCourtSectorFallback: Bool
    public var maximumCourtHalfAngle: Double
    /// Also hand the measured standing distance to the fit as `knownReleaseDistance`.
    /// Off by default: on this corpus the floor intersection measures the shooter's *bearing* well
    /// and their *distance* badly (see `CourtCalibrator.floorPoint`).
    public var constrainReleaseDistance: Bool
    /// Provenance, repeated into the analysis warnings so a number can always be traced back.
    public var label: String

    public init(calibration: CourtCalibration, standing: CourtFloorPoint? = nil,
                azimuthCandidates: [Double] = [], azimuthTolerance: Double = Angle.radians(12),
                useCourtSectorFallback: Bool = true, maximumCourtHalfAngle: Double = Angle.radians(80),
                constrainReleaseDistance: Bool = false, label: String = "court-anchored") {
        self.calibration = calibration; self.standing = standing
        self.azimuthCandidates = azimuthCandidates; self.azimuthTolerance = azimuthTolerance
        self.useCourtSectorFallback = useCourtSectorFallback; self.maximumCourtHalfAngle = maximumCourtHalfAngle
        self.constrainReleaseDistance = constrainReleaseDistance; self.label = label
    }

    /// The azimuth windows this anchor allows. Empty means "no constraint" and the caller should
    /// treat that as a refusal, not as a free scan.
    public func azimuthWindows() -> [AzimuthWindow] {
        var centres: [Double] = []
        if let a = standing?.shotPlaneAzimuth { centres.append(a) }
        centres.append(contentsOf: azimuthCandidates)
        if !centres.isEmpty {
            let sigma = standing?.azimuthSigma ?? 0
            let half = max(azimuthTolerance, min(3 * sigma, Angle.radians(30)))
            return centres.map { AzimuthWindow(center: $0, halfWidth: half) }
        }
        guard useCourtSectorFallback else { return [] }
        // The lane's centre line points from the rim toward the free-throw line; a shooter stands
        // within ±maximumCourtHalfAngle of it. `ShotPlaneSolver.frame` names a plane by its
        // *normal*, and `along = normal × up`, so the azimuth that puts the shooter at court
        // direction φ is φ + π/2 (see `CourtCalibration.shotPlaneAzimuth`).
        guard let centre = calibration.shotPlaneAzimuth(standingAtCourt: SIMD2(1, 0)) else { return [] }
        return [AzimuthWindow(center: centre, halfWidth: maximumCourtHalfAngle)]
    }

    /// The release distance this anchor is willing to assert, if any.
    public var knownReleaseDistance: Double? {
        guard constrainReleaseDistance, let s = standing else { return nil }
        return s.horizontalDistanceToRim
    }

    public var provenance: String {
        var bits = [label, String(format: "bearing %.1f°±%.1f°", Angle.degrees(calibration.bearing), Angle.degrees(calibration.bearingSigma))]
        if let s = standing {
            bits.append(String(format: "shooter measured at court (%.2f, %.2f) m, %.2f m from the rim (±%.2f m), azimuth σ %.2f°",
                               s.court.x, s.court.y, s.horizontalDistanceToRim, s.rangeSigma, Angle.degrees(s.azimuthSigma)))
        } else if azimuthCandidates.isEmpty {
            bits.append("no measured shooter position; azimuth restricted to the court sector only")
        } else {
            bits.append("\(azimuthCandidates.count) marked station(s)")
        }
        return bits.joined(separator: ", ")
    }
}
