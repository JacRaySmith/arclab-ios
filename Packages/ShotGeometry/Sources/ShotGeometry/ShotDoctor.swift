import Foundation

// MARK: - Evidence grading
//
// Deliberately NOT named `EvidenceGrade`: the App module already declares a type by that name in
// `SessionCoaching.swift`. Two identical names would resolve to the App's copy inside App files and
// to this one inside the package, which is legal but invites a silent mix-up. The letters and their
// meanings are the same scheme (`docs/research/healthy-shot-model-2026-09-14.md` §0).

public enum ShotEvidenceGrade: Int, Sendable, Codable, Comparable, CaseIterable {
    /// Peer-reviewed measurement on skilled shooters, large-n tracking of professionals, or exact geometry.
    case a = 0
    /// Peer-reviewed but small n, recreational population, indirect measure, or internally shaky.
    case b
    /// Expert coaching consensus with a biomechanical rationale but no controlled measurement.
    case c
    /// Opinion, vendor marketing, or an untested in-house hypothesis.
    case d

    public var letter: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .d: return "D"
        }
    }

    public var meaning: String {
        switch self {
        case .a: return "peer-reviewed on skilled shooters, large-n professional tracking, or exact geometry"
        case .b: return "peer-reviewed but small n, recreational sample, or an indirect measure"
        case .c: return "coaching consensus with a rationale, no controlled measurement"
        case .d: return "opinion or an untested in-house hypothesis"
        }
    }

    public static func < (l: ShotEvidenceGrade, r: ShotEvidenceGrade) -> Bool { l.rawValue < r.rawValue }
}

// MARK: - Spots

/// The spots the app records. Raw values match `ShotSpot` in `App/Sources/SessionStore.swift`, so the
/// App layer can bridge with `DoctorSpot(rawValue: savedSession.spot.rawValue)`.
public enum DoctorSpot: String, Sendable, Codable, CaseIterable {
    case freeThrow = "Free throws"
    case elbow = "Elbow"
    case midRange = "Mid-range"
    case three = "Three"
    case collegeThree = "College three"
    case other = "Other"

    /// Where the shooter's **feet** nominally are, metres from the rim centre. This is a label, not a
    /// measurement: the engine prefers each spot's measured mean `releaseDistance` and only falls back
    /// here, flagging `distanceIsMeasured = false`. `.other` has no nominal distance and gets none.
    public var nominalStandingDistance: Double? {
        switch self {
        case .freeThrow: return Court.freeThrowLineToRimCenter        // 4.191 m, exact
        case .elbow: return 4.8                                       // nominal
        case .midRange: return 5.5                                    // nominal
        case .three: return CourtType.fiba.threePointRadius           // 6.75; 6.02–7.24 by rulebook
        case .collegeThree: return 6.75                               // NCAA arc since 2019, 22 ft 1.75 in
        case .other: return nil
        }
    }

    /// Ordering near → far. `.other` sorts last because its distance is unknown.
    public var order: Int {
        switch self {
        case .freeThrow: return 0
        case .elbow: return 1
        case .midRange: return 2
        case .three: return 3
        case .collegeThree: return 4
        case .other: return 5
        }
    }
}

public enum ShotOutcomeLabel: String, Sendable, Codable {
    case make, miss, unknown
}

// MARK: - The per-shot record the App feeds in

/// One shot, in package units: radians, metres, seconds. Mirrors `BlockRow` + `SavedShot` without
/// dragging any App type into the package. Every field is optional except identity and the spot,
/// because every one of them can legitimately be unmeasurable on a given clip.
public struct ShotRecord: Sendable, Codable, Identifiable {
    public var id: Int
    /// Groups shots into sessions for drift, pass checks and retention. Any stable string.
    public var sessionID: String
    /// When that session happened — the only ordering that can put two sessions in sequence.
    public var sessionDate: Date
    /// Shot order inside the session, from 0. Drives `trend_over_session` (Ch 15 §15.3.4).
    public var sequence: Int
    public var spot: DoctorSpot
    public var outcome: ShotOutcomeLabel
    /// `false` for a rejected window: the engine drops it from every statistic.
    public var accepted: Bool

    // Trajectory
    public var releaseSpeed: Double?          // m/s
    public var releaseAngle: Double?          // rad above horizontal
    public var releaseHeight: Double?         // m, ball centre above floor
    public var releaseDistance: Double?       // m, release point → rim centre (the Jacobian's lever arm)
    public var entryAngle: Double?            // rad below horizontal
    public var depthPastFrontRim: Double?     // m
    public var lateralDeviation: Double?      // m, + = right of the rim centre. nil on a pure side view.
    public var dipToRelease: Double?          // s
    public var viewClass: ViewClass?

    // Optional body measures (`BlockRow`'s body block). Absent on most clips; never invented.
    public var kneeExtensionPeakDegreesPerSecond: Double?
    public var proximalToDistal: Bool?
    public var elbowAtReleaseDegrees: Double?
    public var headStabilityNormalised: Double?
    public var shoulderLineYawDegrees: Double?
    public var forearmFromVerticalDegrees: Double?
    /// Degrees of tilt of the spin axis from pure backspin. Needs the taped-stripe mode
    /// (`DESIGN-MEMO-2026-09-13.md` §3.7) and a behind-the-shooter clip. Normally nil.
    public var spinAxisTiltDegrees: Double?
    public var backspinRevolutionsPerSecond: Double?

    public init(id: Int, sessionID: String, sessionDate: Date, sequence: Int, spot: DoctorSpot,
                outcome: ShotOutcomeLabel, accepted: Bool = true,
                releaseSpeed: Double? = nil, releaseAngle: Double? = nil, releaseHeight: Double? = nil,
                releaseDistance: Double? = nil, entryAngle: Double? = nil, depthPastFrontRim: Double? = nil,
                lateralDeviation: Double? = nil, dipToRelease: Double? = nil, viewClass: ViewClass? = nil,
                kneeExtensionPeakDegreesPerSecond: Double? = nil, proximalToDistal: Bool? = nil,
                elbowAtReleaseDegrees: Double? = nil, headStabilityNormalised: Double? = nil,
                shoulderLineYawDegrees: Double? = nil, forearmFromVerticalDegrees: Double? = nil,
                spinAxisTiltDegrees: Double? = nil, backspinRevolutionsPerSecond: Double? = nil) {
        self.id = id; self.sessionID = sessionID; self.sessionDate = sessionDate; self.sequence = sequence
        self.spot = spot; self.outcome = outcome; self.accepted = accepted
        self.releaseSpeed = releaseSpeed; self.releaseAngle = releaseAngle; self.releaseHeight = releaseHeight
        self.releaseDistance = releaseDistance; self.entryAngle = entryAngle
        self.depthPastFrontRim = depthPastFrontRim; self.lateralDeviation = lateralDeviation
        self.dipToRelease = dipToRelease; self.viewClass = viewClass
        self.kneeExtensionPeakDegreesPerSecond = kneeExtensionPeakDegreesPerSecond
        self.proximalToDistal = proximalToDistal; self.elbowAtReleaseDegrees = elbowAtReleaseDegrees
        self.headStabilityNormalised = headStabilityNormalised
        self.shoulderLineYawDegrees = shoulderLineYawDegrees
        self.forearmFromVerticalDegrees = forearmFromVerticalDegrees
        self.spinAxisTiltDegrees = spinAxisTiltDegrees
        self.backspinRevolutionsPerSecond = backspinRevolutionsPerSecond
    }
}

// MARK: - Small statistics, ddof = 1 (digest Ch 5 §5.1)

public struct MeanSD: Sendable, Codable, Equatable {
    public var mean: Double
    public var sd: Double
    public var n: Int

    public init(mean: Double, sd: Double, n: Int) { self.mean = mean; self.sd = sd; self.n = n }

    /// Relative standard error of an SD estimate, ≈ 1/√(2n) (digest Ch 5 §5.6).
    public var relativeStandardErrorOfSD: Double? { n >= 2 ? 1 / (2 * Double(n)).squareRoot() : nil }

    /// Same statistic with both moments scaled — the radians → degrees boundary.
    public var inDegrees: MeanSD { MeanSD(mean: Angle.degrees(mean), sd: Angle.degrees(sd), n: n) }

    public static func of(_ xs: [Double]) -> MeanSD? {
        guard xs.count >= 2 else { return nil }
        let m = xs.reduce(0, +) / Double(xs.count)
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count - 1)
        return MeanSD(mean: m, sd: v.squareRoot(), n: xs.count)
    }
}

public enum DoctorStats {
    public static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Sample covariance, ddof = 1. Nil unless both columns have the same length ≥ 2.
    public static func covariance(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count >= 2, let ma = mean(a), let mb = mean(b) else { return nil }
        var s = 0.0
        for i in 0..<a.count { s += (a[i] - ma) * (b[i] - mb) }
        return s / Double(a.count - 1)
    }

    /// 3×3 covariance of (θ rad, v m/s, h m). **θ must be radians** — the §5.1 unit trap.
    public static func covariance3(theta: [Double], speed: [Double], height: [Double]) -> [[Double]]? {
        let cols = [theta, speed, height]
        guard cols.allSatisfy({ $0.count == theta.count }), theta.count >= 2 else { return nil }
        var m = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                guard let c = covariance(cols[i], cols[j]) else { return nil }
                m[i][j] = c
            }
        }
        return m
    }

    /// Ordinary least-squares slope of `y` on `x`. Nil for fewer than two distinct x.
    public static func slope(x: [Double], y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2, let mx = mean(x), let my = mean(y) else { return nil }
        var sxy = 0.0, sxx = 0.0
        for i in 0..<x.count { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) * (x[i] - mx) }
        guard sxx > 1e-12 else { return nil }
        return sxy / sxx
    }

    /// The smallest ratio of two SDs that `n` shots per side can distinguish at 95 %.
    ///
    /// log(SD) has SE ≈ 1/√(2n), so the difference of two log SDs has SE 1/√n and the detectable
    /// ratio is exp(1.96/√n). That reproduces `DESIGN-MEMO-2026-09-13.md` §3.5 (1.36× at n = 30,
    /// 1.28× at 50, 1.20× at 100, 1.14× at 200) to within 0.04 and is conservative at small n.
    public static func detectableSDRatio(n: Int) -> Double? {
        guard n >= 2 else { return nil }
        return exp(1.96 / Double(n).squareRoot())
    }
}

// MARK: - The reference a miss is measured against

public enum CentroidSource: String, Sendable, Codable {
    /// The shooter's own makes — available only at or above `ShotDoctor.ownMakesFloor`.
    case ownMakes
    /// Daly-Grafstein & Bornn's 25–28 cm past-the-front-rim band, used when the shooter has too few makes.
    case publishedBand
}

public struct MakeCentroid: Sendable {
    /// Metres past the front rim.
    public var depth: Double
    /// Half-width of the band that counts as "on line" in depth, metres.
    public var depthTolerance: Double
    public var lateral: Double?
    public var lateralTolerance: Double
    /// Release variables at the reference. Nil when the reference is the published band: a published
    /// depth says nothing about how *this* shooter should release.
    public var speed: Double?
    public var angle: Double?
    public var height: Double?
    public var n: Int
    public var source: CentroidSource

    public var sourceSentence: String {
        switch source {
        case .ownMakes:
            return String(format: "your own %d makes at this spot (centre %.0f cm past the front rim)",
                          n, depth * 100)
        case .publishedBand:
            return String(format: "the published make band, %.0f–%.0f cm past the front rim (only %d makes of your own, floor is %d)",
                          ShotDoctor.publishedMakeDepthBand.low * 100,
                          ShotDoctor.publishedMakeDepthBand.high * 100, n, ShotDoctor.ownMakesFloor)
        }
    }
}

public enum MissDirection: String, Sendable, Codable {
    case short, long, left, right, onLine
}

/// One release variable's share of a single miss, already converted to centimetres of depth.
public struct DepthChannelContribution: Sendable {
    /// "release speed", "release angle", "release height".
    public var channel: String
    /// Deviation from the reference in the channel's own units.
    public var deviation: Double
    /// That deviation written out with its unit, degrees at the boundary.
    public var deviationDescription: String
    /// Depth it buys at this spot's operating point, centimetres. Sign follows the deviation.
    public var depthCm: Double
}

public struct MissDecomposition: Sendable {
    public var shotID: Int
    public var spot: DoctorSpot
    /// The larger of the two errors, in units of its own tolerance.
    public var direction: MissDirection
    /// Depth direction, always present.
    public var depthDirection: MissDirection
    /// Left/right, nil when the clip could not see it.
    public var lateralDirection: MissDirection?
    public var lateralUnavailableReason: String?
    public var depthErrorCm: Double
    public var lateralErrorCm: Double?
    public var contributions: [DepthChannelContribution]
    /// Depth error the three release channels do not account for, centimetres. Never hidden.
    public var unexplainedCm: Double?
    public var dominantChannel: String?
    public var sentence: String
}

public struct DominantCause: Sendable {
    public var channel: String
    /// Fraction of the predicted depth variance, 0…1.
    public var share: Double
    public var n: Int
    public var sentence: String
}

/// Where the Jacobian was evaluated (digest Ch 5 §5.2: J at the **mean** of the cell).
public struct OperatingPoint: Sendable {
    public var theta: Double          // rad
    public var speed: Double          // m/s
    public var height: Double         // m
    public var distance: Double       // m, release → rim centre
    public var sensitivity: ReleaseSensitivity
    /// The shooter's own depth-turnover angle at this operating point, radians. Nil when the scan
    /// found no sign change (`ReleaseSensitivity.depthTurnoverAngle`).
    public var turnoverAngle: Double?

    /// Centimetres of depth per 0.1 m/s of release speed — the number that makes speed legible.
    public var cmPerTenthOfSpeed: Double { sensitivity.dDepth_dV * 0.1 * 100 }
}

public struct SpotDiagnosis: Sendable {
    public var spot: DoctorSpot
    public var n: Int
    public var makes: Int
    public var misses: Int
    public var unknownOutcomes: Int
    public var operatingPoint: OperatingPoint?
    public var operatingPointUnavailableReason: String?
    public var centroid: MakeCentroid?
    public var centroidUnavailableReason: String?
    public var missDecompositions: [MissDecomposition]
    /// Delta-method attribution of depth variance over every accepted shot at the spot.
    public var attribution: DepthVarianceAttribution?
    public var attributionUnavailableReason: String?
    /// What the depth actually did, for comparison with the attribution's prediction.
    public var observedDepth: MeanSD?
    public var dominantCause: DominantCause?
    /// Everything the shooter is owed about how thin this evidence is.
    public var honesty: [String]
    public var headline: String
}

// MARK: - Distance dependence

public struct SpotProfile: Sendable {
    public var spot: DoctorSpot
    public var n: Int
    public var makes: Int
    public var misses: Int
    /// Metres, release point → rim centre when measured; the spot's nominal standing distance otherwise.
    public var distance: Double?
    public var distanceIsMeasured: Bool
    public var releaseSpeed: MeanSD?
    /// Radians. Use `.inDegrees` at the UI boundary.
    public var releaseAngle: MeanSD?
    public var releaseHeight: MeanSD?
    public var entryAngle: MeanSD?
    public var depthPastFrontRim: MeanSD?
    public var lateralDeviation: MeanSD?
    public var dipToRelease: MeanSD?
}

public struct DistanceTrend: Sendable {
    public var label: String
    public var nearSpot: DoctorSpot
    public var farSpot: DoctorSpot
    public var near: Double
    public var far: Double
    public var unit: String
    /// Change per metre of distance, nil when no two spots carried a distance.
    public var slopePerMetre: Double?
    /// far / near, only filled in where a ratio is meaningful (spreads).
    public var ratio: Double?
    public var nearN: Int
    public var farN: Int
}

public enum VersatilityVerdict: String, Sendable, Codable {
    /// Spread holds across distance — the skilled signature (Slegers 2021: velocity SD equal at FT and 3-pt).
    case spreadStable
    /// Spread inflates with distance by more than these shot counts could see by chance.
    case spreadWidens
    /// Spread narrows with distance by more than chance — unusual, report it rather than explain it.
    case spreadNarrows
    /// Not enough spots, or not enough shots, to say either way.
    case undecided
}

public struct Versatility: Sendable {
    public var verdict: VersatilityVerdict
    public var speedSDRatio: Double?
    public var detectableRatio: Double?
    public var nearSpot: DoctorSpot?
    public var farSpot: DoctorSpot?
    public var sentence: String
    public var grade: ShotEvidenceGrade
    public var source: String
}

public struct DistanceDependence: Sendable {
    public var profiles: [SpotProfile]
    public var trends: [DistanceTrend]
    public var versatility: Versatility
    public var statements: [String]
    /// Nil when there was something to compare.
    public var unavailableReason: String?
}

public struct Diagnosis: Sendable {
    public var perSpot: [SpotDiagnosis]
    public var distance: DistanceDependence
    public var shotsConsidered: Int
    public var shotsRejected: Int
    public var notes: [String]

    public func spot(_ s: DoctorSpot) -> SpotDiagnosis? { perSpot.first { $0.spot == s } }
    public func profile(_ s: DoctorSpot) -> SpotProfile? { distance.profiles.first { $0.spot == s } }
}

// MARK: - The engine

public enum ShotDoctor {

    /// Makes peak 25–28 cm (10–11 in) past the front rim over >50 000 NBA 3-point trajectories
    /// (Daly-Grafstein & Bornn 2019 JQAS). Grade A — but measured on NBA threes, not on this shooter.
    public static let publishedMakeDepthBand = (low: 0.25, high: 0.28)
    public static var publishedMakeDepth: Double { (publishedMakeDepthBand.low + publishedMakeDepthBand.high) / 2 }

    /// Below this many makes at a spot the shooter's own make centroid is noise, so the published band
    /// is used instead and every sentence says so.
    public static let ownMakesFloor = 8

    /// Ch 5 §5.6 / Ch 15: the delta-method attribution is not quoted below 20 shots.
    public static let attributionFloor = 20

    /// A spot needs this many accepted shots before it enters the distance comparison at all.
    public static let spotFloor = 5

    /// Geometric half-width of the ring left for the ball's centre: a ball centred more than this far
    /// off the rim centre cannot pass. (Tier A, exact.)
    public static var lateralGeometricTolerance: Double {
        Court.rimInnerRadius - BallSize.size7.diameter / 2
    }

    // MARK: Entry point

    public static func diagnose(records: [ShotRecord]) -> Diagnosis {
        let accepted = records.filter(\.accepted)
        let rejected = records.count - accepted.count
        var perSpot: [SpotDiagnosis] = []
        for spot in DoctorSpot.allCases {
            let rows = accepted.filter { $0.spot == spot }
            guard !rows.isEmpty else { continue }
            perSpot.append(diagnoseSpot(spot: spot, rows: rows))
        }
        perSpot.sort { $0.spot.order < $1.spot.order }
        let distance = distanceDependence(accepted: accepted)
        var notes: [String] = []
        if rejected > 0 {
            notes.append("\(rejected) window(s) were rejected by the shot gate and are in no statistic below.")
        }
        notes.append("Everything here is an association inside your own shooting. Nothing in this engine has been shown to cause a make.")
        return Diagnosis(perSpot: perSpot, distance: distance, shotsConsidered: accepted.count,
                         shotsRejected: rejected, notes: notes)
    }

    // MARK: Per-spot

    static func diagnoseSpot(spot: DoctorSpot, rows: [ShotRecord]) -> SpotDiagnosis {
        let makes = rows.filter { $0.outcome == .make }
        let misses = rows.filter { $0.outcome == .miss }
        let unknown = rows.filter { $0.outcome == .unknown }
        var honesty: [String] = []

        // --- operating point: J at the mean of the cell (Ch 5 §5.2) ---
        let thetas = rows.compactMap(\.releaseAngle)
        let speeds = rows.compactMap(\.releaseSpeed)
        let heights = rows.compactMap(\.releaseHeight)
        let distances = rows.compactMap(\.releaseDistance)
        var operatingPoint: OperatingPoint?
        var operatingPointReason: String?
        if let th = DoctorStats.mean(thetas), let v = DoctorStats.mean(speeds),
           let h = DoctorStats.mean(heights), let L = DoctorStats.mean(distances),
           thetas.count >= 2, speeds.count >= 2, heights.count >= 2 {
            if let s = ReleaseSensitivity.at(theta: th, v: v, h: h, L: L) {
                operatingPoint = OperatingPoint(
                    theta: th, speed: v, height: h, distance: L, sensitivity: s,
                    turnoverAngle: ReleaseSensitivity.depthTurnoverAngle(v: v, h: h, L: L))
            } else {
                operatingPointReason = "the mean release (\(String(format: "%.2f", v)) m/s at \(String(format: "%.1f", Angle.degrees(th)))°) does not reach rim height over \(String(format: "%.2f", L)) m, so no sensitivity can be computed"
            }
        } else if distances.isEmpty {
            operatingPointReason = "no shot at this spot recorded a release distance, so depth has no lever arm to be measured against"
        } else {
            operatingPointReason = "fewer than two shots carried release angle, speed and height together"
        }

        // --- the reference a miss is measured against ---
        let makeDepths = makes.compactMap(\.depthPastFrontRim)
        var centroid: MakeCentroid?
        var centroidReason: String?
        if makeDepths.count >= ownMakesFloor, let d = MeanSD.of(makeDepths) {
            let lat = makes.compactMap(\.lateralDeviation)
            let latStat = MeanSD.of(lat)
            centroid = MakeCentroid(
                depth: d.mean,
                depthTolerance: max(d.sd, 0.01),
                lateral: latStat?.mean,
                lateralTolerance: max(latStat?.sd ?? lateralGeometricTolerance, 0.01),
                speed: DoctorStats.mean(makes.compactMap(\.releaseSpeed)),
                angle: DoctorStats.mean(makes.compactMap(\.releaseAngle)),
                height: DoctorStats.mean(makes.compactMap(\.releaseHeight)),
                n: makeDepths.count, source: .ownMakes)
        } else if rows.contains(where: { $0.depthPastFrontRim != nil }) {
            centroid = MakeCentroid(
                depth: publishedMakeDepth,
                depthTolerance: (publishedMakeDepthBand.high - publishedMakeDepthBand.low) / 2,
                lateral: 0, lateralTolerance: lateralGeometricTolerance,
                speed: nil, angle: nil, height: nil,
                n: makeDepths.count, source: .publishedBand)
            honesty.append("Only \(makeDepths.count) make(s) here carried a depth, below the floor of \(ownMakesFloor), so misses are measured against the published 25–28 cm band (NBA threes, grade A) rather than against your own makes.")
        } else {
            centroidReason = "no shot at this spot produced a rim crossing, so there is nothing to measure a miss against"
        }

        // --- per-miss decomposition ---
        var decompositions: [MissDecomposition] = []
        if let c = centroid {
            for m in misses {
                if let d = decompose(miss: m, spot: spot, centroid: c, operatingPoint: operatingPoint,
                                     fallbackSpeed: DoctorStats.mean(speeds),
                                     fallbackAngle: DoctorStats.mean(thetas),
                                     fallbackHeight: DoctorStats.mean(heights)) {
                    decompositions.append(d)
                }
            }
        }

        // --- delta-method attribution over the whole cell ---
        var attribution: DepthVarianceAttribution?
        var attributionReason: String?
        let triples = rows.compactMap { r -> (Double, Double, Double)? in
            guard let t = r.releaseAngle, let v = r.releaseSpeed, let h = r.releaseHeight else { return nil }
            return (t, v, h)
        }
        if triples.count < attributionFloor {
            attributionReason = "the depth-variance split needs \(attributionFloor) shots with a full release; this spot has \(triples.count)"
        } else if let op = operatingPoint,
                  let cov = DoctorStats.covariance3(theta: triples.map(\.0), speed: triples.map(\.1), height: triples.map(\.2)) {
            attribution = DepthVarianceAttribution.compute(sensitivity: op.sensitivity, covariance: cov)
            if attribution == nil { attributionReason = "the release variables did not vary at this spot, so there is no spread to split" }
        } else {
            attributionReason = operatingPointReason ?? "no operating point, so no Jacobian"
        }

        let observedDepth = MeanSD.of(rows.compactMap(\.depthPastFrontRim))

        var dominant: DominantCause?
        if let a = attribution {
            let parts = [("release speed", a.speedShare), ("release angle", a.thetaShare), ("release height", a.heightShare)]
            if let top = parts.max(by: { $0.1 < $1.1 }) {
                dominant = DominantCause(
                    channel: top.0, share: top.1, n: triples.count,
                    sentence: String(format: "%@ is associated with %.0f%% of your front-to-back spread at %@ (n=%d; the covariance between the channels carries %+.0f%%).",
                                     top.0.prefix(1).uppercased() + top.0.dropFirst(), top.1 * 100, spot.rawValue,
                                     triples.count, a.covarianceShare * 100))
            }
            if a.covarianceShare < 0 {
                honesty.append(String(format: "A channel's share reads above 100%% because the covariance term is %+.0f%%: your release channels partly cancel one another. That is the correct arithmetic (every share is normalised by the full JᵀΣJ), not a bug.", a.covarianceShare * 100))
            }
            if let rse = MeanSD(mean: 0, sd: 0, n: triples.count).relativeStandardErrorOfSD {
                honesty.append(String(format: "At n=%d an SD estimate carries ±%.0f%% of itself, and the percentage split carries ±10–15 points (Ch 5 §5.6).", triples.count, rse * 100))
            }
            if let obs = observedDepth, obs.sd > 0 {
                let predicted = a.sdDepth
                let ratio = predicted / obs.sd
                if ratio > 1.3 {
                    honesty.append(String(format: "Your release variation predicts a %.0f cm depth spread but your shots landed in %.0f cm: either your release channels compensate for one another or the depth measurement is smoothed. Read the percentages as an ordering of the channels, not as centimetres.", predicted * 100, obs.sd * 100))
                } else if ratio < 0.7 {
                    honesty.append(String(format: "Your release variation predicts only %.0f cm of depth spread but your shots landed in %.0f cm: something outside release angle, speed and height — release point, spin, or measurement noise — is adding depth error.", predicted * 100, obs.sd * 100))
                }
            }
        } else if let r = attributionReason {
            honesty.append(r.prefix(1).uppercased() + r.dropFirst() + ".")
        }

        let headline = buildHeadline(spot: spot, n: rows.count, makes: makes.count, misses: misses.count,
                                     unknown: unknown.count, decompositions: decompositions,
                                     observedDepth: observedDepth, dominant: dominant)

        return SpotDiagnosis(spot: spot, n: rows.count, makes: makes.count, misses: misses.count,
                             unknownOutcomes: unknown.count,
                             operatingPoint: operatingPoint, operatingPointUnavailableReason: operatingPointReason,
                             centroid: centroid, centroidUnavailableReason: centroidReason,
                             missDecompositions: decompositions,
                             attribution: attribution, attributionUnavailableReason: attributionReason,
                             observedDepth: observedDepth, dominantCause: dominant,
                             honesty: honesty, headline: headline)
    }

    static func decompose(miss: ShotRecord, spot: DoctorSpot, centroid: MakeCentroid,
                          operatingPoint: OperatingPoint?,
                          fallbackSpeed: Double?, fallbackAngle: Double?, fallbackHeight: Double?) -> MissDecomposition? {
        guard let depth = miss.depthPastFrontRim else { return nil }
        let depthError = depth - centroid.depth
        let depthErrorCm = depthError * 100
        let depthDirection: MissDirection = abs(depthError) <= centroid.depthTolerance
            ? .onLine : (depthError < 0 ? .short : .long)

        var lateralDirection: MissDirection?
        var lateralErrorCm: Double?
        var lateralReason: String?
        if let lat = miss.lateralDeviation {
            let e = lat - (centroid.lateral ?? 0)
            lateralErrorCm = e * 100
            lateralDirection = abs(e) <= centroid.lateralTolerance ? .onLine : (e < 0 ? .left : .right)
        } else {
            lateralReason = "a side-on camera cannot see left/right at the rim — film one set from behind the shooter to unlock it"
        }

        // Which error is bigger, each in units of its own tolerance?
        let depthScore = abs(depthError) / max(centroid.depthTolerance, 1e-6)
        let lateralScore = lateralErrorCm.map { abs($0 / 100) / max(centroid.lateralTolerance, 1e-6) } ?? -1
        let primary: MissDirection = lateralScore > depthScore ? (lateralDirection ?? depthDirection) : depthDirection

        // Release deviations → centimetres of depth, through the Jacobian at the spot's operating point.
        var contributions: [DepthChannelContribution] = []
        var unexplained: Double?
        if let op = operatingPoint {
            let refSpeed = centroid.speed ?? fallbackSpeed
            let refAngle = centroid.angle ?? fallbackAngle
            let refHeight = centroid.height ?? fallbackHeight
            if let v = miss.releaseSpeed, let r = refSpeed {
                let dv = v - r
                contributions.append(DepthChannelContribution(
                    channel: "release speed", deviation: dv,
                    deviationDescription: String(format: "%+.2f m/s", dv),
                    depthCm: op.sensitivity.dDepth_dV * dv * 100))
            }
            if let t = miss.releaseAngle, let r = refAngle {
                let dt = t - r
                contributions.append(DepthChannelContribution(
                    channel: "release angle", deviation: dt,
                    deviationDescription: String(format: "%+.1f°", Angle.degrees(dt)),
                    depthCm: op.sensitivity.dDepth_dTheta * dt * 100))
            }
            if let h = miss.releaseHeight, let r = refHeight {
                let dh = h - r
                contributions.append(DepthChannelContribution(
                    channel: "release height", deviation: dh,
                    deviationDescription: String(format: "%+.2f m", dh),
                    depthCm: op.sensitivity.dDepth_dH * dh * 100))
            }
            if !contributions.isEmpty {
                unexplained = depthErrorCm - contributions.map(\.depthCm).reduce(0, +)
            }
        }
        let dominantChannel = contributions.max(by: { abs($0.depthCm) < abs($1.depthCm) })?.channel

        // --- the sentence ---
        var s = "Shot \(miss.id) at \(spot.rawValue) missed \(primary.rawValue): "
        s += String(format: "%.0f cm %@ of %@", abs(depthErrorCm),
                    depthDirection == .onLine ? "from the centre" : depthDirection.rawValue,
                    centroid.sourceSentence)
        if let l = lateralErrorCm, let d = lateralDirection, d != .onLine {
            s += String(format: ", and %.0f cm %@ of the rim centre", abs(l), d.rawValue)
        }
        s += "."
        if contributions.isEmpty {
            s += " No release variable could be compared" + (operatingPoint == nil ? " (no operating point at this spot)." : " on this shot.")
        } else {
            let parts = contributions.map { String(format: "%@ %@ (%+.0f cm)", $0.channel, $0.deviationDescription, $0.depthCm) }
            s += " Against that reference: " + parts.joined(separator: ", ") + "."
            if let u = unexplained, abs(u) >= 2 {
                s += String(format: " %+.0f cm is not explained by those three.", u)
            }
            if let d = dominantChannel {
                s += " \(d.prefix(1).uppercased() + d.dropFirst()) is the biggest single piece."
            }
        }

        return MissDecomposition(shotID: miss.id, spot: spot, direction: primary, depthDirection: depthDirection,
                                 lateralDirection: lateralDirection, lateralUnavailableReason: lateralReason,
                                 depthErrorCm: depthErrorCm, lateralErrorCm: lateralErrorCm,
                                 contributions: contributions, unexplainedCm: unexplained,
                                 dominantChannel: dominantChannel, sentence: s)
    }

    static func buildHeadline(spot: DoctorSpot, n: Int, makes: Int, misses: Int, unknown: Int,
                              decompositions: [MissDecomposition], observedDepth: MeanSD?,
                              dominant: DominantCause?) -> String {
        var s = "\(spot.rawValue): \(n) shots, \(makes) inferred makes, \(misses) inferred misses"
        if unknown > 0 { s += ", \(unknown) whose outcome was not seen" }
        s += "."
        if !decompositions.isEmpty {
            var counts: [MissDirection: Int] = [:]
            for d in decompositions { counts[d.direction, default: 0] += 1 }
            let order: [MissDirection] = [.short, .long, .left, .right, .onLine]
            let parts = order.compactMap { d -> String? in
                guard let c = counts[d], c > 0 else { return nil }
                return "\(c) \(d == .onLine ? "on line but through" : d.rawValue)"
            }
            if !parts.isEmpty { s += " Misses: " + parts.joined(separator: ", ") + "." }
        }
        if let d = observedDepth {
            s += String(format: " Depth %.0f ± %.0f cm past the front rim.", d.mean * 100, d.sd * 100)
        }
        if let c = dominant { s += " " + c.sentence }
        return s
    }

    // MARK: Distance dependence

    static func profile(spot: DoctorSpot, rows: [ShotRecord]) -> SpotProfile {
        let measured = rows.compactMap(\.releaseDistance)
        let distance = DoctorStats.mean(measured) ?? spot.nominalStandingDistance
        return SpotProfile(
            spot: spot, n: rows.count,
            makes: rows.filter { $0.outcome == .make }.count,
            misses: rows.filter { $0.outcome == .miss }.count,
            distance: distance, distanceIsMeasured: !measured.isEmpty,
            releaseSpeed: MeanSD.of(rows.compactMap(\.releaseSpeed)),
            releaseAngle: MeanSD.of(rows.compactMap(\.releaseAngle)),
            releaseHeight: MeanSD.of(rows.compactMap(\.releaseHeight)),
            entryAngle: MeanSD.of(rows.compactMap(\.entryAngle)),
            depthPastFrontRim: MeanSD.of(rows.compactMap(\.depthPastFrontRim)),
            lateralDeviation: MeanSD.of(rows.compactMap(\.lateralDeviation)),
            dipToRelease: MeanSD.of(rows.compactMap(\.dipToRelease)))
    }

    static func distanceDependence(accepted: [ShotRecord]) -> DistanceDependence {
        var profiles: [SpotProfile] = []
        for spot in DoctorSpot.allCases {
            let rows = accepted.filter { $0.spot == spot }
            guard rows.count >= spotFloor else { continue }
            profiles.append(profile(spot: spot, rows: rows))
        }
        profiles.sort { ($0.distance ?? .infinity, $0.spot.order) < ($1.distance ?? .infinity, $1.spot.order) }

        guard profiles.count >= 2, let near = profiles.first, let far = profiles.last else {
            let why = profiles.isEmpty
                ? "no spot reached \(spotFloor) accepted shots"
                : "only one spot (\(profiles[0].spot.rawValue)) reached \(spotFloor) accepted shots — versatility is a comparison and needs at least two"
            return DistanceDependence(
                profiles: profiles, trends: [],
                versatility: Versatility(verdict: .undecided, speedSDRatio: nil, detectableRatio: nil,
                                         nearSpot: profiles.first?.spot, farSpot: nil,
                                         sentence: "Not enough spots to say whether your shot holds up with distance: \(why).",
                                         grade: .a,
                                         source: "Slegers, Lee & Wong 2021 JSSM — skilled velocity SD was the same at free-throw and 3-point range"),
                statements: [], unavailableReason: why)
        }

        var trends: [DistanceTrend] = []
        func addTrend(_ label: String, _ unit: String, _ pick: (SpotProfile) -> Double?, ratio: Bool) {
            guard let a = pick(near), let b = pick(far) else { return }
            let xs = profiles.compactMap { p -> (Double, Double)? in
                guard let d = p.distance, let v = pick(p) else { return nil }
                return (d, v)
            }
            trends.append(DistanceTrend(
                label: label, nearSpot: near.spot, farSpot: far.spot, near: a, far: b, unit: unit,
                slopePerMetre: xs.count >= 2 ? DoctorStats.slope(x: xs.map(\.0), y: xs.map(\.1)) : nil,
                ratio: ratio && a > 1e-9 ? b / a : nil,
                nearN: near.n, farN: far.n))
        }
        addTrend("release-speed mean", "m/s", { $0.releaseSpeed?.mean }, ratio: false)
        addTrend("release-speed SD", "m/s", { $0.releaseSpeed?.sd }, ratio: true)
        addTrend("release-angle mean", "°", { $0.releaseAngle.map { Angle.degrees($0.mean) } }, ratio: false)
        addTrend("release-angle SD", "°", { $0.releaseAngle.map { Angle.degrees($0.sd) } }, ratio: true)
        addTrend("release height", "m", { $0.releaseHeight?.mean }, ratio: false)
        addTrend("entry angle", "°", { $0.entryAngle.map { Angle.degrees($0.mean) } }, ratio: false)
        addTrend("crossing depth", "cm", { $0.depthPastFrontRim.map { $0.mean * 100 } }, ratio: false)
        addTrend("crossing-depth SD", "cm", { $0.depthPastFrontRim.map { $0.sd * 100 } }, ratio: true)
        addTrend("dip→release mean", "s", { $0.dipToRelease?.mean }, ratio: false)
        addTrend("dip→release SD", "s", { $0.dipToRelease?.sd }, ratio: true)

        let versatility = judgeVersatility(near: near, far: far)
        let statements = buildStatements(near: near, far: far, trends: trends, versatility: versatility)
        return DistanceDependence(profiles: profiles, trends: trends, versatility: versatility,
                                  statements: statements, unavailableReason: nil)
    }

    static func judgeVersatility(near: SpotProfile, far: SpotProfile) -> Versatility {
        let source = "Slegers, Lee & Wong 2021 JSSM: skilled shooters' release-velocity SD was the same at free-throw and 3-point range (0.086 vs 0.089 m/s) and correlated r = −0.96 with 3-point performance"
        guard let a = near.releaseSpeed, let b = far.releaseSpeed, a.sd > 1e-9 else {
            return Versatility(verdict: .undecided, speedSDRatio: nil, detectableRatio: nil,
                               nearSpot: near.spot, farSpot: far.spot,
                               sentence: "Release speed was not measured at both spots, so spread stability across distance cannot be judged.",
                               grade: .a, source: source)
        }
        let ratio = b.sd / a.sd
        guard let floor = DoctorStats.detectableSDRatio(n: min(a.n, b.n)) else {
            return Versatility(verdict: .undecided, speedSDRatio: ratio, detectableRatio: nil,
                               nearSpot: near.spot, farSpot: far.spot,
                               sentence: "Too few shots to compare two spreads.", grade: .a, source: source)
        }
        let verdict: VersatilityVerdict
        if ratio >= floor { verdict = .spreadWidens }
        else if ratio <= 1 / floor { verdict = .spreadNarrows }
        else { verdict = .spreadStable }
        let sentence: String
        switch verdict {
        case .spreadWidens:
            sentence = String(format: "Your shot does not hold its spread with distance: release-speed SD goes %.2f → %.2f m/s from %@ (n=%d) to %@ (n=%d), a %.1f× widening, and %.2f× is the smallest widening these counts could see by chance. The versatile signature is a spread that stays put.",
                              a.sd, b.sd, near.spot.rawValue, a.n, far.spot.rawValue, b.n, ratio, floor)
        case .spreadNarrows:
            sentence = String(format: "Release-speed SD %.2f → %.2f m/s from %@ to %@, a narrowing beyond the %.2f× these counts could see by chance. Unusual — worth confirming next session before reading anything into it.",
                              a.sd, b.sd, near.spot.rawValue, far.spot.rawValue, floor)
        case .spreadStable:
            sentence = String(format: "Your spread holds up with distance: release-speed SD %.2f → %.2f m/s from %@ (n=%d) to %@ (n=%d), inside the %.2f× these counts could distinguish. That stability is the measurable definition of a versatile shot.",
                              a.sd, b.sd, near.spot.rawValue, a.n, far.spot.rawValue, b.n, floor)
        case .undecided:
            sentence = "Undecided."
        }
        return Versatility(verdict: verdict, speedSDRatio: ratio, detectableRatio: floor,
                           nearSpot: near.spot, farSpot: far.spot, sentence: sentence, grade: .a, source: source)
    }

    static func buildStatements(near: SpotProfile, far: SpotProfile, trends: [DistanceTrend],
                                versatility: Versatility) -> [String] {
        var out: [String] = []
        func t(_ label: String) -> DistanceTrend? { trends.first { $0.label == label } }

        if let x = t("release-speed SD") {
            out.append(String(format: "Release-speed SD %.2f → %.2f m/s, %@ (n=%d) → %@ (n=%d)%@. Release-speed consistency is the strongest measured correlate of shooting performance (grade A).",
                              x.near, x.far, x.nearSpot.rawValue, x.nearN, x.farSpot.rawValue, x.farN,
                              x.ratio.map { String(format: " — %.1f× wider", $0) } ?? ""))
        }
        if let x = t("release-angle SD") {
            out.append(String(format: "Release-angle SD %.1f → %.1f°, %@ → %@. Angle spread is a weak correlate (r = −0.41, n.s. in Slegers 2021), so read it as context, not as the problem.",
                              x.near, x.far, x.nearSpot.rawValue, x.farSpot.rawValue))
        }
        if let x = t("dip→release mean") {
            let pct = x.near > 1e-9 ? (x.far - x.near) / x.near * 100 : 0
            out.append(String(format: "Preparatory tempo: dip→release %.2f → %.2f s (%+.0f%%), %@ (n=%d) → %@ (n=%d). Proficient shooters move *slower* through the preparatory phase, and higher-level U18s release faster — the literature pulls both ways, so this is your own trend, not a target (grade B).",
                              x.near, x.far, pct, x.nearSpot.rawValue, x.nearN, x.farSpot.rawValue, x.farN))
        }
        if let x = t("release-speed mean") {
            out.append(String(format: "Release speed %.2f → %.2f m/s%@. Speed must rise with distance; that part is geometry.",
                              x.near, x.far, x.slopePerMetre.map { String(format: ", %.2f m/s per extra metre", $0) } ?? ""))
        }
        if let x = t("release-angle mean") {
            out.append(String(format: "Release angle %.1f → %.1f°. Measured shooters drop 3–5° from free-throw to three-point range (grade B), so compare a release angle only with its own distance.",
                              x.near, x.far))
        }
        if let x = t("release height") {
            out.append(String(format: "Release height %.2f → %.2f m. The literature gives release height no direction — it is reported, never scored (grade B).", x.near, x.far))
        }
        if let x = t("entry angle") {
            out.append(String(format: "Entry angle %.1f → %.1f°. Below %.2f° a size-7 ball cannot pass an 18-inch ring at all (exact geometry for a %.4f m ball; the rulebook tolerance moves that floor by about 0.6°), and below 40° the margin is under 3 cm (grade A).", x.near, x.far, Angle.degrees(Physics.entryFloor()), BallSize.size7.diameter))
        }
        if let x = t("crossing depth") {
            out.append(String(format: "Crossing depth %.0f → %.0f cm past the front rim; makes peaked at 25–28 cm over 50 000 NBA threes (grade A).", x.near, x.far))
        }
        if let x = t("crossing-depth SD") {
            out.append(String(format: "Crossing-depth SD %.0f → %.0f cm%@.", x.near, x.far,
                              x.ratio.map { String(format: " (%.1f×)", $0) } ?? ""))
        }
        out.append(versatility.sentence)
        return out
    }
}
