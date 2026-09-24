// A variant is a named set of `AnalysisOptions` overrides declared as data, so shipping a new
// experiment is adding one entry here, not editing `BenchRunner`.
import Foundation
import simd
import ShotGeometry

/// Horizontal release-to-rim-centre distance by shooting spot, metres. Matches the `--spot` labels
/// `TrajectoryProbe session` is given.
///
/// "elbow" is deliberately absent: the elbow is a lateral position on the floor, not a fixed
/// distance from the rim the way a free-throw line or a three-point arc is — there is no single
/// number to put here, so `knownDistance` must skip an elbow window rather than guess one.
public enum SpotDistanceTable {
    public static let metres: [String: Double] = [
        "freeThrow": Court.freeThrowLineToRimCenter,   // 4.191 m
        "three": 6.75,                                 // FIBA / current NCAA three-point radius
        "collegeThree": 6.32,                           // pre-2019 NCAA men's / NCAA women's three-point radius
    ]
}

public enum VariantResult: Sendable {
    case options(AnalysisOptions)
    case skip(String)
}

/// A variant may need to change how a window's `RimCalibration` is built, not just the
/// `AnalysisOptions` handed to `ShotAnalyzer.analyze`. Two experiments need this: `gravityUp` (a
/// measured `RimCalibrationOptions.knownUp`) and `autoFoundTrace` (a different rim boundary
/// entirely, recalibrating from the auto-found trace instead of the cached hand trace). Both fields
/// default to nil ("use the window's own cached boundary, free solve") for every variant that
/// doesn't need this — `baseline`, `fixedGravityAzimuth`, `knownDistance`.
public struct CalibrationOverride: Sendable {
    /// Replace the cached window's own `rimBoundary` with these points before fitting the ellipse.
    public var rimBoundaryPoints: [SIMD2<Double>]?
    /// `RimCalibrationOptions.knownUp` for this window. nil keeps the free solve (the conic's own normal).
    public var knownUp: SIMD3<Double>?
    public init(rimBoundaryPoints: [SIMD2<Double>]? = nil, knownUp: SIMD3<Double>? = nil) {
        self.rimBoundaryPoints = rimBoundaryPoints; self.knownUp = knownUp
    }
}

/// A vertical vanishing point is where the images of parallel vertical lines (light poles, fence
/// posts) converge; the ray from the camera through that pixel *is* the vertical direction in the
/// camera frame (the single-vanishing-point calibration `docs/PHASE2-PREP.md` "Vanishing points"
/// section uses). Only used here to *derive* the pitch/roll constants in `MeasuredVertical` below —
/// audit trail, not the runtime path (`upFromPitchRoll` is).
func upFromVerticalVanishingPoint(_ vp: SIMD2<Double>, intrinsics k: CameraIntrinsics) -> SIMD3<Double> {
    let ray = SIMD3((vp.x - k.cx) / k.fx, (vp.y - k.cy) / k.fy, 1.0)
    return simd_normalize(ray)
}

/// The convention this file uses to turn a measured camera roll/pitch (degrees, relative to
/// gravity) into the `up` vector `RimCalibrationOptions.knownUp` wants, in the calibration's own
/// basis. `RimCalibration.swift`'s `pitch`/`roll` computed properties read:
///
///     pitch = asin(up.z)                    (positive = looking up)
///     roll  = atan2(-up.x, -up.y)            (0 = level; an upright phone's upHint = (0,-1,0))
///
/// which is `up.z = sin(pitch)`, `(-up.x, -up.y) = cos(pitch)·(sin(roll), cos(roll))` solved for
/// `up`:
///
///     up = (-cos(pitch)·sin(roll), -cos(pitch)·cos(roll), sin(pitch))
///
/// Verified against the one up vector `docs/research/three-point-acceptance-2026-09-24.md` states
/// outright — IMG_1766, pitch 6.43°, roll −3.69° ⇒ (0.0639, −0.9917, 0.1120) — reproduced to 4
/// significant figures, and round-tripped back through the `pitch`/`roll` formulas above to within
/// 0.01°: see `GravityUpVariantTests`.
public func upFromPitchRoll(pitchDegrees: Double, rollDegrees: Double) -> SIMD3<Double> {
    let pitch = Angle.radians(pitchDegrees), roll = Angle.radians(rollDegrees)
    return SIMD3(-cos(pitch) * sin(roll), -cos(pitch) * cos(roll), sin(pitch))
}

/// Per-clip camera verticals for the 2026-09-13 corpus, measured independently of any rim trace —
/// what the `gravityUp` variant needs.
///
/// **Only IMG_1766's pitch/roll is stated outright** in
/// `docs/research/three-point-acceptance-2026-09-24.md` §2: "up = (0.0639, −0.9917, 0.1120) —
/// pitch 6.43°, roll −3.69°". IMG_1764's and IMG_1765's are not restated anywhere as a pitch/roll
/// pair; they are **derived here**, by the identical method (`upFromVerticalVanishingPoint`, then
/// `RimCalibration`'s own pitch/roll formulas), from the raw vertical vanishing points
/// `docs/PHASE2-PREP.md`'s "Vanishing points on a 33-frame median of each clip" table records for
/// *all three* clips (the same 2026-09-14 measurement pass, `cv2.createLineSegmentDetector` + RANSAC
/// on a 33-frame median) — that table's pixel coordinates are the only thing taken on faith; the
/// arithmetic from there is this file's own, checked against IMG_1766's published answer:
///
///     clip                  vertical VP        → pitch, roll (at hfov 64°, this cache's own)
///     IMG_1764 elbow        (1314, −10892)      →  7.65°, −1.77°
///     IMG_1765 free throw   (1191, −10141)      →  8.18°, −1.24°
///     IMG_1766 three        (1837, −13064)      →  6.43°, −3.69°   (matches the doc exactly)
///
/// A clip absent from this table makes `knownUp` return nil, and `gravityUp`'s `makeOptions` skips
/// that window with a stated reason rather than guessing a vertical for it.
public enum MeasuredVertical {
    public struct Entry: Sendable { public var pitchDegrees: Double; public var rollDegrees: Double }

    public static let byClip: [String: Entry] = [
        "IMG_1764.mov": Entry(pitchDegrees: 7.65, rollDegrees: -1.77),
        "IMG_1765.mov": Entry(pitchDegrees: 8.18, rollDegrees: -1.24),
        "IMG_1766.mov": Entry(pitchDegrees: 6.43, rollDegrees: -3.69),   // docs/research/three-point-acceptance-2026-09-24.md §2
    ]

    public static func knownUp(clip: String) -> SIMD3<Double>? {
        guard let e = byClip[clip] else { return nil }
        return upFromPitchRoll(pitchDegrees: e.pitchDegrees, rollDegrees: e.rollDegrees)
    }
}

/// Auto-found rim traces (RimFinder, 2026-09-14) — what the `autoFoundTrace` variant recalibrates
/// from instead of the cached hand trace. Bundled as a `ShotBenchKit` resource (`Resources/rim_*_found.json`,
/// copied byte-for-byte from `footage/2026-09-13/`; diff against that file to audit) so this variant
/// needs no access to the gitignored, multi-GB footage directory at replay time — the same "no video"
/// property every other variant has.
public enum AutoFoundRimTrace {
    private struct RimFile: Decodable { var points: [[Double]] }

    /// clip file name → resource name (without extension), for the three clips a trace was found for.
    private static let resourceByClip: [String: String] = [
        "IMG_1764.mov": "rim_1764_found", "IMG_1765.mov": "rim_1765_found", "IMG_1766.mov": "rim_1766_found",
    ]

    public static let boundaryPointsByClip: [String: [SIMD2<Double>]] = {
        var result: [String: [SIMD2<Double>]] = [:]
        for (clip, resourceName) in resourceByClip {
            guard let url = Bundle.module.url(forResource: resourceName, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(RimFile.self, from: data) else { continue }
            result[clip] = file.points.map { SIMD2($0[0], $0[1]) }
        }
        return result
    }()

    public static func boundaryPoints(forClip clip: String) -> [SIMD2<Double>]? { boundaryPointsByClip[clip] }
}

/// Court features marked by eye on the 2026-09-13 corpus — the second court feature that fixes the
/// camera's bearing, which the rim ellipse alone cannot.
///
/// The numbers here are a **copy** of `docs/footage-2026-09-13/court_marks_2026-09-13.json`, which
/// is the record: it names the exact frame each mark came from, who made it (one agent, by eye),
/// and what was deliberately left unmarked. Diff the two if either is edited. They live here as
/// literals for the same reason `MeasuredVertical` does — `ShotBenchKit` must replay a cache with
/// no access to the gitignored footage directory and no new package resource.
///
/// Three features per clip, all on the floor: the free-throw line, and the two lane side lines.
/// `IMG_1765` and `IMG_1766` add the free-throw circle, which is the only feature here that also
/// carries a **scale** (a known radius gives a range), so it is what
/// `CourtChecks.rimHeightAboveFloor` and `.freeThrowDistance` are recovered from. `IMG_1764` has no
/// circle mark: on that clip the camera sees the free-throw circle so nearly edge-on that its
/// visible arc is indistinguishable from the tangent lane line, and a guess there would be a
/// fabricated measurement.
public enum CourtMarksCorpus0913 {
    private static let laneAlong = SIMD3<Double>(1, 0, 0)      // rim → free-throw line
    private static let laneAcross = SIMD3<Double>(0, 1, 0)

    private static func lane(_ name: String, _ pts: [(Double, Double)]) -> CourtLineMark {
        CourtLineMark(name: name, imagePoints: pts.map { SIMD2($0.0, $0.1) }, courtDirection: laneAlong)
    }
    private static func freeThrowLine(_ pts: [(Double, Double)]) -> CourtLineMark {
        CourtLineMark(name: "freeThrowLine", imagePoints: pts.map { SIMD2($0.0, $0.1) }, courtDirection: laneAcross,
                      courtPointOnLine: SIMD3(CourtMarkings.freeThrowLineDistance, 0, 0))
    }
    private static func circle(_ pts: [(Double, Double)]) -> CourtCircleMark {
        CourtCircleMark(name: "freeThrowCircle", imagePoints: pts.map { SIMD2($0.0, $0.1) },
                        courtCenter: CourtMarkings.freeThrowCircleCenter, radius: CourtMarkings.freeThrowCircleRadius)
    }

    public static let byClip: [String: CourtMarks] = [
        "IMG_1764.mov": CourtMarks(
            lines: [freeThrowLine([(65.6, 1063.2), (106.4, 1042.2), (196.7, 1004.2), (282.8, 969.8), (355.0, 940.5), (453.1, 899.1)]),
                    lane("laneLineFar", [(600.0, 898.8), (840.0, 905.0), (1080.1, 906.0)]),
                    lane("laneLineNear", [(60.0, 1059.7), (299.9, 1065.7), (599.9, 1069.5), (899.9, 1073.7), (1139.9, 1077.1)])],
            circles: [],
            provenance: "frame IMG_1764@0000.0/frame_0 (empty court); no free-throw circle marked — see the JSON's note"),
        "IMG_1765.mov": CourtMarks(
            lines: [freeThrowLine([(302.1, 1037.6), (401.5, 997.9), (501.6, 960.2), (601.2, 921.0), (667.9, 891.7)]),
                    lane("laneLineFar", [(690.0, 890.6), (800.0, 893.6), (951.0, 897.6), (1124.9, 905.1), (1299.0, 907.4), (1450.0, 913.0)]),
                    lane("laneLineNear", [(320.0, 1037.7), (458.9, 1047.5), (556.9, 1053.2), (846.9, 1065.3), (1033.2, 1075.8)])],
            circles: [circle([(413.9, 894.3), (310.1, 905.6), (207.3, 914.9), (104.0, 935.7), (54.5, 950.7), (23.5, 974.0),
                              (51.5, 997.8), (103.8, 1015.3), (206.9, 1031.6), (299.9, 1040.1)])],
            provenance: "41-frame median of IMG_1765"),
        "IMG_1766.mov": CourtMarks(
            lines: [freeThrowLine([(600.6, 1018.5), (635.3, 982.2), (675.4, 942.5), (716.4, 906.7), (751.0, 871.1)]),
                    lane("laneLineFar", [(790.1, 870.0), (916.0, 878.4), (1125.8, 889.8), (1336.8, 896.4), (1547.0, 904.0)]),
                    lane("laneLineNear", [(605.1, 1019.0), (758.2, 1029.8), (916.0, 1042.2), (1074.0, 1051.1), (1283.8, 1066.3), (1494.7, 1077.9)])],
            circles: [circle([(557.9, 865.8), (432.8, 871.7), (307.8, 885.7), (233.1, 899.2), (209.5, 920.0),
                              (231.4, 968.5), (308.6, 984.0), (433.2, 1003.5), (558.1, 1017.4)])],
            provenance: "41-frame median of IMG_1766"),
    ]

    public static func marks(forClip clip: String) -> CourtMarks? { byClip[clip] }

    /// The shooter's foot-contact pixel, marked by eye at 5× zoom in one shooting frame per clip.
    /// One stance per clip is all the window cache can support (it stores ball detections only, no
    /// pose landmarks), so this is a *station*, not a per-shot position — `azimuthTolerance` below
    /// is what carries the shooter's stepping and drift, and the elbow clip adds its mirror station
    /// because the shooter alternated sides there.
    public static let markedStancePixel: [String: SIMD2<Double>] = [
        "IMG_1764.mov": SIMD2(253, 958),      // IMG_1764@0271.4/frame_1
        "IMG_1765.mov": SIMD2(330, 1039),     // IMG_1765@0311.3/frame_1
        "IMG_1766.mov": SIMD2(205, 877),      // IMG_1766@0393.2/frame_1
    ]

    /// Clips where the shooter worked both sides of the lane, so the marked station's mirror image
    /// in the lane's centre line is an equally real station.
    public static let mirrorsStation: Set<String> = ["IMG_1764.mov"]

    /// Half-width of the azimuth window around each station, radians. 12° is ±0.9 m of lateral
    /// stance at a free throw and ±1.4 m at a three — wide enough for a shooter who steps and
    /// drifts, narrow enough that it is nothing like the free 0…2π scan it replaces.
    public static let azimuthTolerance: Double = Angle.radians(12)

    /// Solved court pose per clip, cached: the solve fits an ellipse and runs a Nelder–Mead circle
    /// fit, so it is not something to redo for all 98 windows.
    private static let solveOutcome: (poses: [String: CourtCalibration], failures: [String: String]) = {
        var poses: [String: CourtCalibration] = [:]
        var failures: [String: String] = [:]
        for (clip, marks) in byClip {
            guard let rim = referenceRimCalibration(forClip: clip) else {
                failures[clip] = "rim calibration failed on the bundled auto-found trace"
                continue
            }
            do {
                poses[clip] = try CourtCalibrator.solve(rim: rim, marks: marks, intrinsics: referenceIntrinsics,
                                                        options: CourtCalibrationOptions())
            } catch {
                failures[clip] = "\(error)"
            }
        }
        return (poses, failures)
    }()
    private static var solved: [String: CourtCalibration] { solveOutcome.poses }
    /// Why a clip's court pose could not be solved — quoted verbatim into the variant's skip reason,
    /// so a refusal always says what went wrong rather than just "skipped".
    public static func solveFailure(forClip clip: String) -> String? { solveOutcome.failures[clip] }

    /// Intrinsics the marks were made under: the corpus is 1920×1080 and the cache was dumped at
    /// the probe's default 64° horizontal field of view (`docs/BENCH-RESULTS-2026-09-24.md` §1).
    /// A window whose cached intrinsics differ from these is skipped rather than re-marked.
    public static let referenceIntrinsics = CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 64)

    static func referenceRimCalibration(forClip clip: String) -> RimCalibration? {
        guard let pts = AutoFoundRimTrace.boundaryPoints(forClip: clip) else { return nil }
        var o = RimCalibrationOptions()
        o.rimDiameter = Court.rimInnerDiameter
        return try? RimCalibrator.calibrate(boundaryPoints: pts, intrinsics: referenceIntrinsics, options: o)
    }

    public static func courtCalibration(forClip clip: String) -> CourtCalibration? { solved[clip] }

    /// The shooter's measured standing position for a clip, or nil when the floor intersection is
    /// too ill-conditioned to report (`CourtCalibrator.floorPoint` refuses rather than guesses).
    public static func measuredStance(forClip clip: String) -> CourtFloorPoint? {
        guard let cal = solved[clip], let px = markedStancePixel[clip] else { return nil }
        return try? CourtCalibrator.floorPoint(px, calibration: cal, intrinsics: referenceIntrinsics,
                                               pixelSigma: 6, maximumRangeSigma: 2.5)
    }

    /// The anchor handed to `AnalysisOptions.courtAnchor` for one cached window.
    public static func anchor(for window: CachedWindow) -> CourtShotAnchor? {
        guard let cal = solved[window.clip] else { return nil }
        guard window.width == referenceIntrinsics.width, window.height == referenceIntrinsics.height,
              abs(window.hfovDegrees - 64) < 1e-6 else { return nil }
        var candidates: [Double] = []
        var stance: CourtFloorPoint? = nil
        if let s = measuredStance(forClip: window.clip) {
            stance = s
            if mirrorsStation.contains(window.clip), let mirrored = cal.shotPlaneAzimuth(standingAtCourt: SIMD2(s.court.x, -s.court.y)) {
                candidates.append(mirrored)
            }
        }
        return CourtShotAnchor(calibration: cal, standing: stance, azimuthCandidates: candidates,
                               azimuthTolerance: azimuthTolerance, useCourtSectorFallback: true,
                               constrainReleaseDistance: false,
                               label: "court marks + stance, clip \(window.clip)")
    }
}

/// Context a variant may need beyond the single window it is being asked about: the per-clip
/// pooled azimuth, when this variant asked for one (see `Variant.pooling` and `BenchRunner`).
public struct VariantContext: Sendable {
    public var pooledAzimuthByClip: [String: Double]
    /// Per-window pooled azimuth, for a strategy that pools a clip into more than one group
    /// (`.clusteredRobust`). Takes precedence over `pooledAzimuthByClip` when both hold a value.
    public var pooledAzimuthByWindowID: [String: Double]
    public init(pooledAzimuthByClip: [String: Double] = [:], pooledAzimuthByWindowID: [String: Double] = [:]) {
        self.pooledAzimuthByClip = pooledAzimuthByClip; self.pooledAzimuthByWindowID = pooledAzimuthByWindowID
    }
    /// The azimuth this variant should fix for a window, if any.
    public func pooled(for window: CachedWindow) -> Double? {
        pooledAzimuthByWindowID[window.windowID] ?? pooledAzimuthByClip[window.clip]
    }
}

/// How a variant wants the per-clip shot-plane azimuth pooled, if at all.
///
/// The camera and the shooter do not move inside a filming block, so the shot-plane azimuth is one
/// number per block, not a free parameter per shot: solving it per shot lets detection noise ride
/// into release height, release speed and the fitted g. These are the pooling rules under test
/// (`docs/BENCH-RESULTS-azimuth-2026-09-24.md`).
public enum AzimuthPoolingStrategy: Sendable, Equatable {
    /// No pooling: every window keeps its own per-shot solve.
    case none
    /// What `TrajectoryProbe session` does today, mirrored exactly: circular **mean** of the
    /// azimuths of the *accepted* windows, applied only when ≥3 accepted and their maximum
    /// deviation from that mean is ≤ 25°.
    case legacyAcceptedMean
    /// Circular **median** over *every* window's per-shot solve (accepted or not), with
    /// `AzimuthPooling.robust`'s MAD outlier rule.
    case robustAll(RobustPoolConfig)
    /// The same robust estimator, but over the accepted windows only — isolates "median + MAD
    /// instead of mean + 25° max spread" from "pool over all windows instead of accepted ones".
    case robustAccepted(RobustPoolConfig)
    /// Solve → pool → re-solve every window's azimuth over just the flight window the pooled
    /// azimuth implies (held-ball and in-net samples excluded) → re-pool, until the pooled azimuth
    /// moves less than `toleranceDegrees` or `iterations` rounds have run.
    case iteratedRobust(RobustPoolConfig, iterations: Int, toleranceDegrees: Double)
    /// Cluster the clip's per-shot azimuths by circular gap first, then pool *within* each cluster
    /// big enough to qualify. A window whose own solve falls in a qualifying cluster takes that
    /// cluster's robust centre; every other window keeps its own solve.
    case clusteredRobust(RobustPoolConfig, gapDegrees: Double)

    public var isEnabled: Bool { if case .none = self { return false }; return true }

    public var label: String {
        switch self {
        case .none: return "none"
        case .legacyAcceptedMean: return "legacy accepted-only circular mean, ≥3 windows, ≤25° max deviation"
        case .robustAll(let c): return "robust circular median over all windows (k=\(c.outlierK), floor \(c.outlierFloorDegrees)°, min \(c.minimumWindows)" + (c.maximumScaledMADDegrees.map { ", MAD gate \($0)°" } ?? "") + ")"
        case .robustAccepted(let c): return "robust circular median over accepted windows (k=\(c.outlierK), floor \(c.outlierFloorDegrees)°, min \(c.minimumWindows)" + (c.maximumScaledMADDegrees.map { ", MAD gate \($0)°" } ?? "") + ")"
        case .iteratedRobust(let c, let n, let tol): return "iterated robust circular median (≤\(n) rounds, stop at \(tol)°, k=\(c.outlierK), min \(c.minimumWindows))"
        case .clusteredRobust(let c, let gap): return "robust circular median within each azimuth cluster (gap \(gap)°, min \(c.minimumWindows) per cluster)"
        }
    }
}

public struct Variant: Sendable {
    public var name: String
    public var summary: String
    /// How `BenchRunner` should pool the azimuth per clip before the per-window pass, and hand the
    /// result in via `VariantContext`. `.legacyAcceptedMean` mirrors the live `session` command's
    /// two-pass behaviour exactly; see `AzimuthPoolingStrategy`.
    public var pooling: AzimuthPoolingStrategy
    /// How this variant wants a window's `RimCalibration` built. Defaults to "use the window's own
    /// cached boundary, free solve" — every variant except `gravityUp`/`autoFoundTrace`.
    public var calibrationOverride: @Sendable (_ window: CachedWindow) -> CalibrationOverride
    public var makeOptions: @Sendable (_ window: CachedWindow, _ context: VariantContext) -> VariantResult

    public init(name: String, summary: String, pooling: AzimuthPoolingStrategy = .none,
                calibrationOverride: @escaping @Sendable (_ window: CachedWindow) -> CalibrationOverride = { _ in CalibrationOverride() },
                makeOptions: @escaping @Sendable (_ window: CachedWindow, _ context: VariantContext) -> VariantResult) {
        self.name = name; self.summary = summary; self.pooling = pooling
        self.calibrationOverride = calibrationOverride; self.makeOptions = makeOptions
    }

    private static func withReleaseOverride(_ window: CachedWindow, _ o: inout AnalysisOptions) {
        if let r = window.releaseTimeOverride { o.windowOptions.releaseTimeOverride = r }
    }

    /// Reproduces the options `TrajectoryProbe session` builds for its pass-2 analysis today
    /// (`Probe.swift`, `case "session":`, the loop that prints the shot table): `azimuthByFixedGravity`
    /// is always on, and the per-shot azimuth is overridden by the session's pooled azimuth when
    /// enough shots from the same clip agreed (`BenchRunner` supplies that pooling — see there for
    /// why a corpus of independently-dumped windows cannot simply replay the live two-pass loop
    /// verbatim, and what is done instead).
    public static let baseline = Variant(name: "baseline",
        summary: "azimuthByFixedGravity, with the session-pooled azimuth applied per clip when ≥3 accepted shots agree within 25° — exactly what `session` does today.",
        pooling: .legacyAcceptedMean) { window, context in
        var o = AnalysisOptions()
        o.azimuthByFixedGravity = true
        if let pooled = context.pooledAzimuthByClip[window.clip] { o.fixedAzimuth = pooled }
        withReleaseOverride(window, &o)
        return .options(o)
    }

    /// The azimuth option in isolation, with no session pooling and no known distance. On a corpus
    /// where session pooling never engages (too few accepted shots, or the accepted shots disagree
    /// by more than 25°) this is numerically identical to `baseline` — that is expected, not a bug:
    /// `baseline` already uses fixed-gravity azimuth, so this variant's job is to stay a stable,
    /// pooling-free reference point if `baseline`'s default ever changes.
    public static let fixedGravityAzimuth = Variant(name: "fixedGravityAzimuth",
        summary: "azimuthByFixedGravity = true, per window, no session pooling, no known distance.") { window, _ in
        var o = AnalysisOptions()
        o.azimuthByFixedGravity = true
        withReleaseOverride(window, &o)
        return .options(o)
    }

    /// `knownReleaseDistance` from the cached spot label. Skips — never guesses — a window whose
    /// spot has no entry in `SpotDistanceTable` (no spot label at all, or "elbow").
    public static let knownDistance = Variant(name: "knownDistance",
        summary: "knownReleaseDistance set from the spot label via SpotDistanceTable; skips windows whose spot has no known distance.") { window, _ in
        guard let spot = window.spot, !spot.isEmpty else { return .skip("no --spot label on this window") }
        guard let d = SpotDistanceTable.metres[spot] else {
            let why = spot == "elbow" ? "the elbow is a lateral position, not a fixed distance from the rim" : "no distance in SpotDistanceTable for spot \"\(spot)\""
            return .skip(why)
        }
        var o = AnalysisOptions()
        o.knownReleaseDistance = d
        withReleaseOverride(window, &o)
        return .options(o)
    }

    /// `RimCalibrationOptions.knownUp` set per clip from `MeasuredVertical` (the vertical vanishing
    /// point of light poles/fence posts, independent of the rim trace). Session-pooled like
    /// `baseline` — the research document's own comparison used the same two-pass pooling on both
    /// sides, so this stays directly comparable to it and to `baseline`. Skips — never guesses — a
    /// window whose clip has no recorded vertical.
    public static let gravityUp = Variant(name: "gravityUp",
        summary: "RimCalibrationOptions.knownUp set per clip from its measured vertical (MeasuredVertical); session-pooled azimuth like baseline; skips a clip with no measured vertical.",
        pooling: .legacyAcceptedMean,
        calibrationOverride: { window in CalibrationOverride(knownUp: MeasuredVertical.knownUp(clip: window.clip)) }) { window, context in
        guard MeasuredVertical.knownUp(clip: window.clip) != nil else {
            return .skip("no measured vertical recorded for clip \"\(window.clip)\" (MeasuredVertical.byClip)")
        }
        var o = AnalysisOptions()
        o.azimuthByFixedGravity = true
        if let pooled = context.pooledAzimuthByClip[window.clip] { o.fixedAzimuth = pooled }
        withReleaseOverride(window, &o)
        return .options(o)
    }

    /// Recalibrates from the auto-found rim trace (`AutoFoundRimTrace`) instead of the cached hand
    /// trace — the fix that needs no extra sensor: is the rim finder's trace better than the human's?
    /// Session-pooled like `baseline`, for the same reason `gravityUp` is. Skips — never guesses — a
    /// window whose clip has no bundled auto-found trace.
    public static let autoFoundTrace = Variant(name: "autoFoundTrace",
        summary: "recalibrates from the auto-found rim trace (RimFinder, 2026-09-14) instead of the cached hand trace; session-pooled azimuth like baseline; skips a clip with no bundled auto-found trace.",
        pooling: .legacyAcceptedMean,
        calibrationOverride: { window in CalibrationOverride(rimBoundaryPoints: AutoFoundRimTrace.boundaryPoints(forClip: window.clip)) }) { window, context in
        guard AutoFoundRimTrace.boundaryPoints(forClip: window.clip) != nil else {
            return .skip("no auto-found rim trace bundled for clip \"\(window.clip)\" (AutoFoundRimTrace.resourceByClip)")
        }
        var o = AnalysisOptions()
        o.azimuthByFixedGravity = true
        if let pooled = context.pooledAzimuthByClip[window.clip] { o.fixedAzimuth = pooled }
        withReleaseOverride(window, &o)
        return .options(o)
    }

    // MARK: - azimuth pooling experiments (2026-09-24)
    //
    // Every variant below sits on top of `autoFoundTrace`'s calibration, because the rim fix is
    // already established (docs/BENCH-RESULTS-2026-09-24.md §4) and the question here is only what
    // pooling the azimuth does *given* that trace. They therefore differ from `autoFoundTrace` in
    // exactly one thing: `pooling`. Compare them against `autoFoundTrace`, not against `baseline`.

    /// Builds one of the pooling experiments: auto-found trace + fixed-gravity azimuth, with the
    /// clip's pooled azimuth substituted for the per-shot solve wherever pooling engaged.
    static func autoFoundPooled(name: String, summary: String, pooling: AzimuthPoolingStrategy) -> Variant {
        Variant(name: name, summary: summary, pooling: pooling,
                calibrationOverride: { window in CalibrationOverride(rimBoundaryPoints: AutoFoundRimTrace.boundaryPoints(forClip: window.clip)) }) { window, context in
            guard AutoFoundRimTrace.boundaryPoints(forClip: window.clip) != nil else {
                return .skip("no auto-found rim trace bundled for clip \"\(window.clip)\" (AutoFoundRimTrace.resourceByClip)")
            }
            var o = AnalysisOptions()
            o.azimuthByFixedGravity = true
            if let pooled = context.pooled(for: window) { o.fixedAzimuth = pooled }
            withReleaseOverride(window, &o)
            return .options(o)
        }
    }

    /// Control for the pooling experiments: identical to `autoFoundTrace` except that pooling is
    /// switched off entirely, so every window uses its own per-shot solve. Separates "the pooled
    /// azimuth helped" from "the legacy pooling rule engaging on one clip helped".
    public static let autoFoundNoPool = autoFoundPooled(name: "autoFoundNoPool",
        summary: "auto-found rim trace, per-shot fixed-gravity azimuth, no pooling at all — the control for the pooling experiments.",
        pooling: .none)

    /// The main candidate: one azimuth per clip, the circular **median** of *every* window's
    /// per-shot solve (not only the accepted ones), with `AzimuthPooling.robust`'s MAD outlier rule
    /// and no agreement gate beyond it.
    public static let autoFoundPooledMedian = autoFoundPooled(name: "autoFoundPooledMedian",
        summary: "auto-found rim trace; azimuth pooled per clip as the robust circular median of ALL windows' per-shot solves (MAD outlier rule, k=3, floor 4°, ≥5 survivors).",
        pooling: .robustAll(RobustPoolConfig()))

    /// The same estimator over the accepted windows only — isolates the estimator change (median +
    /// MAD instead of mean + a 25° maximum-spread test) from the population change (all windows
    /// instead of accepted windows).
    public static let autoFoundPooledMedianAccepted = autoFoundPooled(name: "autoFoundPooledMedianAccepted",
        summary: "auto-found rim trace; azimuth pooled per clip as the robust circular median of the ACCEPTED windows' per-shot solves (MAD outlier rule, k=3, floor 4°, ≥5 survivors).",
        pooling: .robustAccepted(RobustPoolConfig()))

    /// Pooling gated on robust agreement: the same estimator, but a clip is only pooled when the
    /// surviving azimuths' robust spread (1.4826·MAD) is ≤ 10°. This is the replacement for the
    /// legacy "≥3 accepted and no accepted shot more than 25° from the mean" rule, which fails
    /// exactly when it is most needed.
    public static let autoFoundPooledGated = autoFoundPooled(name: "autoFoundPooledGated",
        summary: "auto-found rim trace; robust circular median over all windows, engaged only when the surviving azimuths' robust spread (1.4826·MAD) is ≤ 10°.",
        pooling: .robustAll(RobustPoolConfig(maximumScaledMADDegrees: 10)))

    /// Iterated pooling: pool, re-solve every window's azimuth over only the flight window the
    /// pooled azimuth implies (so held-ball and in-net samples cannot contaminate the plane),
    /// re-pool, and repeat until the pooled azimuth settles or the cap is reached.
    public static let autoFoundPooledIterated = autoFoundPooled(name: "autoFoundPooledIterated",
        summary: "auto-found rim trace; robust circular median, iterated — each round re-solves every window's azimuth over the flight window the current pooled azimuth implies, then re-pools (≤4 rounds, stop at 0.25°).",
        pooling: .iteratedRobust(RobustPoolConfig(), iterations: 4, toleranceDegrees: 0.25))

    /// Pooling *within* each azimuth cluster of a clip rather than across the whole clip: the
    /// candidate the diagnosis asked for once the free-throw clip turned out to hold two genuinely
    /// different shooting positions rather than one noisy one. A clip with a single mode (the elbow
    /// and three-point blocks) behaves exactly like `autoFoundPooledMedian` under it.
    public static let autoFoundPooledClustered = autoFoundPooled(name: "autoFoundPooledClustered",
        summary: "auto-found rim trace; the clip's per-shot azimuths are clustered by circular gap (15\u{00B0}) and each cluster of \u{2265}4 windows is pooled to its own robust circular median; a window outside every qualifying cluster keeps its own solve.",
        pooling: .clusteredRobust(RobustPoolConfig(minimumWindows: 4), gapDegrees: 15))

    /// The same clustering with a tighter gap. On the 2026-09-13 corpus a 15° gap does *not*
    /// separate the free-throw clip's two modes: the windows whose azimuth solve failed outright
    /// (ambiguity ratio ≈ 1, fit residual 0.16–0.69 m) land between the two modes and bridge them
    /// into one cluster. 10° cuts the one real valley (275°→289°) and leaves the two modes apart.
    /// Kept as a separate variant rather than by retuning the one above, so both results stay
    /// reproducible and the sensitivity to the gap is on the record.
    public static let autoFoundPooledClusteredTight = autoFoundPooled(name: "autoFoundPooledClusteredTight",
        summary: "as autoFoundPooledClustered but with a 10\u{00B0} clustering gap, which is what separates the free-throw clip's two shooting positions on this corpus.",
        pooling: .clusteredRobust(RobustPoolConfig(minimumWindows: 4), gapDegrees: 10))

    /// **A sensitivity probe, not a candidate**: the clip's robust pooled azimuth deliberately
    /// offset by 5°, so the bench can measure how far release height and release speed actually
    /// move per degree of azimuth error. That number is what decides whether azimuth scatter can
    /// explain a 0.4 m within-block release-height spread, or whether the spread has to come from
    /// somewhere else. Never a shipping candidate — it is wrong on purpose.
    public static let autoFoundAzimuthOffset5 = Variant(name: "autoFoundAzimuthOffset5",
        summary: "SENSITIVITY PROBE (deliberately wrong): auto-found rim trace with the clip's robust pooled azimuth offset by +5°, to measure d(release height)/d(azimuth) on real windows.",
        pooling: .robustAll(RobustPoolConfig()),
        calibrationOverride: { window in CalibrationOverride(rimBoundaryPoints: AutoFoundRimTrace.boundaryPoints(forClip: window.clip)) }) { window, context in
        guard AutoFoundRimTrace.boundaryPoints(forClip: window.clip) != nil else {
            return .skip("no auto-found rim trace bundled for clip \"\(window.clip)\" (AutoFoundRimTrace.resourceByClip)")
        }
        guard let pooled = context.pooled(for: window) else { return .skip("this clip was not pooled, so there is no azimuth to offset") }
        var o = AnalysisOptions()
        o.azimuthByFixedGravity = true
        o.fixedAzimuth = pooled + Angle.radians(5)
        withReleaseOverride(window, &o)
        return .options(o)
    }

    /// Court-anchored: the camera's **bearing** — the one pose parameter the rim ellipse cannot
    /// supply, because a circle is symmetric about its own axis — is solved from marked court
    /// features (`CourtMarksCorpus0913`), and the shot-plane azimuth is then searched only inside
    /// the windows that pose allows, instead of the free 0…2π fixed-gravity scan every other
    /// variant runs. Everything else is `autoFoundTrace`: the same auto-found rim trace, the same
    /// fit, the same gates, `g` still the check.
    ///
    /// Two honest limits, stated here because they bound what this variant can show:
    /// 1. The shooter's standing position is a **single hand-marked stance per clip** (there are no
    ///    pose landmarks in the window cache), so the azimuth window is that station ±
    ///    `azimuthTolerance`, widened for the elbow clip by its mirror station because the shooter
    ///    alternated sides. It is a measured bearing with a stated tolerance, not a per-shot fix.
    /// 2. Skips — never guesses — a clip with no marked court features or no auto-found rim trace.
    public static let courtAnchored = Variant(name: "courtAnchored",
        summary: "camera bearing solved from marked court features (CourtCalibration) on the auto-found rim trace; the shot-plane azimuth is searched only inside the court-allowed windows instead of the free 0…2π scan; skips a clip with no court marks.",
        calibrationOverride: { window in CalibrationOverride(rimBoundaryPoints: AutoFoundRimTrace.boundaryPoints(forClip: window.clip)) }) { window, _ in
        guard AutoFoundRimTrace.boundaryPoints(forClip: window.clip) != nil else {
            return .skip("no auto-found rim trace bundled for clip \"\(window.clip)\" (AutoFoundRimTrace.resourceByClip)")
        }
        guard CourtMarksCorpus0913.marks(forClip: window.clip) != nil else {
            return .skip("no court features marked for clip \"\(window.clip)\" (CourtMarksCorpus0913)")
        }
        guard let anchor = CourtMarksCorpus0913.anchor(for: window) else {
            let why = CourtMarksCorpus0913.solveFailure(forClip: window.clip)
                ?? "the window's intrinsics differ from the ones the marks were made under"
            return .skip("court pose unavailable for clip \"\(window.clip)\": \(why)")
        }
        var o = AnalysisOptions()
        o.courtAnchor = anchor
        withReleaseOverride(window, &o)
        return .options(o)
    }

    public static let all: [Variant] = [baseline, fixedGravityAzimuth, knownDistance, gravityUp, autoFoundTrace,
                                        autoFoundNoPool, autoFoundPooledMedian, autoFoundPooledMedianAccepted,
                                        autoFoundPooledGated, autoFoundPooledIterated, autoFoundPooledClustered,
                                        autoFoundPooledClusteredTight, autoFoundAzimuthOffset5, courtAnchored]
    public static func named(_ name: String) -> Variant? { all.first { $0.name == name } }
}
