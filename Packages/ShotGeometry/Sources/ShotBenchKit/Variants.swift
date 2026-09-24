// A variant is a named set of `AnalysisOptions` overrides declared as data, so shipping a new
// experiment is adding one entry here, not editing `BenchRunner`.
import Foundation
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
    public var makeOptions: @Sendable (_ window: CachedWindow, _ context: VariantContext) -> VariantResult

    public init(name: String, summary: String, needsSessionPooling: Bool = false,
                makeOptions: @escaping @Sendable (_ window: CachedWindow, _ context: VariantContext) -> VariantResult) {
        self.name = name; self.summary = summary; self.needsSessionPooling = needsSessionPooling; self.makeOptions = makeOptions
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

    public static let all: [Variant] = [baseline, fixedGravityAzimuth, knownDistance]
    public static func named(_ name: String) -> Variant? { all.first { $0.name == name } }
}
