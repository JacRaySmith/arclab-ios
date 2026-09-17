import Foundation

/// Court and ball dimensions. Metres, seconds, radians in code; degrees only at the boundary.
/// Sources: brief §4.1 and the ArcLab textbook Appendix A. Three-point distances vary by
/// rulebook and are a user setting (`CourtType`).
public enum Court {
    /// Standard gravity used for the g-test. Local g varies 9.78–9.83; 9.81 is within 0.2% everywhere.
    public static let g: Double = 9.81

    public static let rimInnerDiameter: Double = 0.4572          // 18 in
    public static let rimInnerRadius: Double = rimInnerDiameter / 2
    public static let rimHeight: Double = 3.048                  // 10 ft, top of ring
    /// Ring tube diameter (NBA: 5/8 in solid steel). The *outer* edge of the ring is a
    /// circle of diameter inner + 2 × tube. Calibration must know which edge it fitted.
    public static let rimTubeDiameter: Double = 0.0159
    public static let rimOuterDiameter: Double = rimInnerDiameter + 2 * rimTubeDiameter

    public static let rimCenterToBackboardFace: Double = 0.381   // 6 in gap + 9 in radius
    public static let backboardWidth: Double = 1.829              // 72 in
    public static let backboardHeight: Double = 1.067             // 42 in
    public static let backboardInnerRectWidth: Double = 0.610     // 24 in
    public static let backboardInnerRectHeight: Double = 0.457    // 18 in

    public static let freeThrowLineToBackboardFace: Double = 4.572 // 15 ft
    public static let freeThrowLineToRimCenter: Double = freeThrowLineToBackboardFace - rimCenterToBackboardFace // 4.191
}

/// Ball sizes. Regulation circumference for size 7 is 749–762 mm (29.5–30 in), so the
/// diameter is 0.2385–0.2426 m. The brief specifies the lower figure; the textbook uses the
/// upper. The spread is 1.7%, which is why the ball is the *check* ruler, never the primary one.
public enum BallSize: String, Sendable, Codable, CaseIterable {
    case size7, size6, size5

    public var diameter: Double {
        switch self {
        case .size7: return 0.2385
        case .size6: return 0.2304
        case .size5: return 0.2210
        }
    }
    /// Relative uncertainty of the diameter from the rulebook tolerance alone.
    public var diameterRelativeTolerance: Double { 0.017 }
}

public enum CourtType: String, Sendable, Codable, CaseIterable {
    case nba, fiba, ncaaMen, ncaaWomen, highSchool

    /// Three-point arc radius from the rim centre (top of key). Corners are shorter on
    /// NBA/WNBA/NCAA courts. Confirm against the current rulebook before shipping.
    public var threePointRadius: Double {
        switch self {
        case .nba: return 7.24
        case .fiba: return 6.75
        case .ncaaMen: return 6.75
        case .ncaaWomen: return 6.75
        case .highSchool: return 6.02
        }
    }
}

public enum Angle {
    @inlinable public static func degrees(_ rad: Double) -> Double { rad * 180 / .pi }
    @inlinable public static func radians(_ deg: Double) -> Double { deg * .pi / 180 }
}
