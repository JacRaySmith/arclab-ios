import Foundation

public enum ViewClass: String, Sendable, Codable {
    /// Camera within `sideMax` of perpendicular to the shot plane: arc, release angle, entry angle, elbow angle valid.
    case side
    /// In between: only what survives (release angle/entry angle via the solved plane, flagged).
    case oblique
    /// Camera nearly in the shot plane: left/right deviation valid, arc not.
    case frontal
}

public enum ViewClassifier {
    public static let sideMax = Angle.radians(25)
    public static let frontalMin = Angle.radians(65)
    public static func classify(viewAngle: Double) -> ViewClass {
        if viewAngle <= sideMax { return .side }
        if viewAngle >= frontalMin { return .frontal }
        return .oblique
    }
}

public enum CalibrationPath: String, Sendable, Codable {
    case rimEllipse, backboard, ballScale, none
}

public enum GravityVerdict: String, Sendable, Codable {
    case accept, lowConfidence, reject
}

/// Brief §4.7: |g_fit − 9.81| / 9.81 ≤ 0.08 accept; ≤ 0.20 accept low-confidence; else reject.
public enum GravityGate {
    public static let acceptTolerance = 0.08
    public static let lowConfidenceTolerance = 0.20

    public static func verdict(gFit: Double) -> (verdict: GravityVerdict, error: Double) {
        guard gFit.isFinite, gFit > 0 else { return (.reject, .infinity) }
        let e = abs(gFit - Court.g) / Court.g
        if e <= acceptTolerance { return (.accept, e) }
        if e <= lowConfidenceTolerance { return (.lowConfidence, e) }
        return (.reject, e)
    }

    public static func explain(gFit: Double) -> String {
        let (v, e) = verdict(gFit: gFit)
        let ratio = gFit / Court.g
        var s = String(format: "g_fit = %.2f m/s² (%+.1f%% vs 9.81): %@", gFit, e * 100, v.rawValue)
        if v == .reject {
            if abs(ratio - 4) < 0.3 || abs(ratio - 0.25) < 0.03 { s += " — off by ≈4×: frame rate wrong by 2× (timestamps)" }
            else if abs(ratio - 2) < 0.2 || abs(ratio - 0.5) < 0.05 { s += " — off by ≈2×: a radius/diameter or units mix-up" }
            else { s += " — scale, timing, or window contamination" }
        }
        return s
    }
}

public enum Perspective {
    /// Brief §4.4: when a trajectory is measured in a plane yawed by `yaw` from the true shot plane,
    /// horizontal displacement is foreshortened by cos(yaw) and tan(θ_measured) = tan(θ_true)/cos(yaw).
    /// Inverse: tan(θ_true) = tan(θ_measured) · cos(yaw).
    public static func yawCorrectedAngle(measured: Double, yaw: Double) -> Double {
        atan(tan(measured) * cos(yaw))
    }
    public static func apparentAngle(true theta: Double, yaw: Double) -> Double {
        atan(tan(theta) / cos(yaw))
    }
}

/// The forward model: release parameters → what happens at the rim. Pure; the most-tested function.
public enum Physics {
    /// Textbook Ch 4.1. `L` is horizontal distance from the release point to the rim centre.
    /// Returns entry angle below horizontal (rad) and depth of the ball centre past the front rim (m).
    /// Nil when the ball never reaches rim height.
    public static func forward(theta: Double, v: Double, h: Double, L: Double,
                               g: Double = Court.g, rimHeight: Double = Court.rimHeight) -> (entry: Double, depth: Double)? {
        let vx = v * cos(theta), vy = v * sin(theta)
        let disc = vy * vy - 2 * g * (rimHeight - h)
        guard disc >= 0, vx > 0 else { return nil }
        let tStar = (vy + disc.squareRoot()) / g      // larger root: descending crossing
        let entry = atan(abs(vy - g * tStar) / vx)
        let xRim = vx * tStar
        return (entry, xRim - (L - Court.rimInnerRadius))
    }

    /// Below this entry angle a clean pass through the ring is geometrically impossible: asin(D_ball / D_rim).
    public static func entryFloor(ballDiameter: Double = BallSize.size7.diameter) -> Double {
        asin(ballDiameter / Court.rimInnerDiameter)
    }
}

public enum DepthClass: String, Sendable, Codable {
    case front, center, back
}

public struct ReleaseMetrics: Sendable {
    public var angle: Double                  // rad above horizontal
    public var height: Double                 // ball centre above floor, m
    public var speed: Double                  // m/s
    public var distance: Double               // horizontal, release point → rim centre, m
    public var angleDegrees: Double { Angle.degrees(angle) }
}

public struct ShotMetrics: Sendable {
    // Tier 1 — trajectory (radians / metres / seconds; convert at the UI boundary)
    /// Nil when the release instant was not observed (track starts in flight, shooter cropped).
    public var release: ReleaseMetrics?
    public var releaseUnavailableReason: String?
    public var entryAngle: Double?
    public var entryAngleUnavailableReason: String?
    public var apexHeight: Double?            // above floor
    public var timeOfFlight: Double?
    /// Ball-centre crossing of the rim plane relative to the rim centre; + = past centre.
    public var rimCrossingOffset: Double?
    public var depthPastFrontRim: Double?
    public var depthClass: DepthClass?
    /// Left/right of the rim centre at the crossing (frontal views only). nil when not measurable.
    public var lateralDeviation: Double?

    public var entryAngleDegrees: Double? { entryAngle.map(Angle.degrees) }
    public init() {}
}

public struct ConfidencePayload: Sendable {
    public var gFit: Double
    public var gError: Double
    public var gravityVerdict: GravityVerdict
    public var rmsPx: Double
    public var rmsM: Double
    public var nDetections: Int
    public var nInliers: Int
    public var flightSpan: Double
    public var samplesAfterApex: Int
    public var calibrationPath: CalibrationPath
    public var viewClass: ViewClass
    public var viewAngle: Double
    public var azimuthSigma: Double
    public var releaseTime: Double
    public var releaseObserved: Bool
    public var warnings: [String]
}
