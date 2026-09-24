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

/// Context a variant may need beyond the single window it is being asked about. Only `baseline`
/// uses this today (the session-pooled azimuth, see `BenchRunner`); every other variant ignores it.
public struct VariantContext: Sendable {
    public var pooledAzimuthByClip: [String: Double]
    public init(pooledAzimuthByClip: [String: Double] = [:]) { self.pooledAzimuthByClip = pooledAzimuthByClip }
}

public struct Variant: Sendable {
    public var name: String
    public var summary: String
    /// True only for `baseline`: tells `BenchRunner` to compute the session-pooled azimuth per clip
    /// first (mirroring the live `session` command's two-pass behaviour) and hand it in via `VariantContext`.
    public var needsSessionPooling: Bool
    /// How this variant wants a window's `RimCalibration` built. Defaults to "use the window's own
    /// cached boundary, free solve" — every variant except `gravityUp`/`autoFoundTrace`.
    public var calibrationOverride: @Sendable (_ window: CachedWindow) -> CalibrationOverride
    public var makeOptions: @Sendable (_ window: CachedWindow, _ context: VariantContext) -> VariantResult

    public init(name: String, summary: String, needsSessionPooling: Bool = false,
                calibrationOverride: @escaping @Sendable (_ window: CachedWindow) -> CalibrationOverride = { _ in CalibrationOverride() },
                makeOptions: @escaping @Sendable (_ window: CachedWindow, _ context: VariantContext) -> VariantResult) {
        self.name = name; self.summary = summary; self.needsSessionPooling = needsSessionPooling
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
        needsSessionPooling: true) { window, context in
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
        needsSessionPooling: true,
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
        needsSessionPooling: true,
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

    public static let all: [Variant] = [baseline, fixedGravityAzimuth, knownDistance, gravityUp, autoFoundTrace]
    public static func named(_ name: String) -> Variant? { all.first { $0.name == name } }
}
