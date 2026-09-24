// `ShotBench azimuth <cache> --variant <name>` — the per-shot azimuth, window by window, before
// any pooling decision is taken.
//
// The scorecard reports the azimuth a window's analysis *used*, which is the pooled value wherever
// pooling engaged; this dump reports what each window's own fixed-gravity solve says, including for
// windows whose analysis later throws (a failed flight window or fit still has an azimuth). That
// distinction is the whole diagnosis: is a clip's per-shot azimuth scattered around one value
// (pooling will help) or genuinely multi-modal (pooling would lock in one branch)?
import Foundation
import ShotGeometry

public struct AzimuthRow: Codable, Sendable {
    public var windowID: String
    public var clip: String
    public var spot: String?
    public var sampleCount: Int
    /// This window's own whole-track fixed-gravity solve, degrees in [0, 360). Nil when the solve failed.
    public var perShotAzimuthDegrees: Double?
    /// The solver's own quality numbers for that solve.
    public var solveRmsPx: Double?
    public var ambiguityRatio: Double?
    public var azimuthSigmaDegrees: Double?
    /// Re-solve restricted to the flight window that the clip's pooled azimuth implies (held-ball
    /// and in-net samples excluded) — round 1 of iterated pooling, per window. Nil when the clip
    /// was not pooled, or the analysis/re-solve failed.
    public var flightRestrictedAzimuthDegrees: Double?
    /// Deviation of `perShotAzimuthDegrees` from this clip's robust pooled centre, degrees in [0, 180].
    public var deviationFromPoolDegrees: Double?
    /// Verdict under this window's *own* solve (no pooling), and why not, so the diagnosis can ask
    /// whether accepted and refused windows solve the azimuth differently.
    public var acceptedUnderOwnSolve: Bool
    public var refusalReasonUnderOwnSolve: String?
    public var releaseHeightUnderOwnSolve: Double?
    /// Horizontal release-to-rim distance the fit implies, metres. The decisive check on a
    /// bimodal azimuth solve: the free-throw line is 4.191 m from the rim centre by rule, so a
    /// branch that puts the release 6 m away is the wrong branch, whatever its fit residual.
    public var releaseDistanceUnderOwnSolve: Double?
    public var gErrorUnderOwnSolve: Double?
    /// View angle of the window's own solved plane, degrees (0 = side on, 90 = head on).
    public var viewAngleDegreesUnderOwnSolve: Double?
    /// **Independent of gravity**: the ball diameter the window's own plane implies, metres,
    /// median over every sample that has a detected diameter — `D = d_px · z(plane) / fx`. The
    /// fixed-gravity azimuth solve chooses the plane that makes the fit's g come out at 9.81, so a
    /// wrong branch of a bimodal solve can still have a tiny gravity error; the ball's apparent
    /// size does not know about gravity, and a size-7 ball is 0.2413 m whatever the plane says.
    /// Read it *relative to the same clip's other windows and to the unimodal clips*, not as an
    /// absolute: the detector's diameters carry an unknown uniform bias, which is exactly why
    /// `ShotPlaneSolver.objective` fits a free scale factor to them.
    public var impliedBallDiameterM: Double?
    /// Relative spread of that implied diameter along the track, (p90 − p10) / median. A ball does
    /// not change size, so the *correct* plane makes `d_px · z(plane)` constant along the flight
    /// whatever uniform bias the detector has; a wrong plane gets the depth *profile* wrong and this
    /// number grows. Unlike the median above, it is immune to a uniform detector bias — which makes
    /// it the discriminator between two branches of a bimodal azimuth solve.
    public var impliedBallDiameterSpread: Double?
    /// Depth of the first detection from the camera under the window's own plane, metres.
    public var startDepthM: Double?
    /// Window start on the clip's own file-time axis, seconds — so the diagnosis can ask whether
    /// two azimuth clusters alternate shot by shot (a bimodal solve) or occupy separate stretches
    /// of the block (the shooter really moved).
    public var fileStart: Double
}

public struct AzimuthDiagnosis: Codable, Sendable {
    public var variant: String
    public var cacheDir: String
    public var generatedAt: String
    public var rows: [AzimuthRow]
    /// The robust pool per clip (`AzimuthPooling.robust` over every window's per-shot solve), with
    /// its outlier count, MAD and max deviation — reported whether or not it would engage.
    public var pools: [PoolDiagnostics]
}

public enum AzimuthDiagnoser {

    public static func run(windows: [CachedWindow], variantName: String, cacheDir: String,
                           config: RobustPoolConfig = RobustPoolConfig()) -> AzimuthDiagnosis? {
        guard let variant = Variant.named(variantName) else { return nil }
        let override = variant.calibrationOverride

        // Pass 1: every window's own solve and its own verdict.
        var rows: [AzimuthRow] = []
        var byClip: [String: [Double]] = [:]
        for w in windows {
            let ov = override(w)
            let samples = w.samples.map(\.imageSample).sorted { $0.t < $1.t }
            var row = AzimuthRow(windowID: w.windowID, clip: w.clip, spot: w.spot, sampleCount: samples.count,
                                 perShotAzimuthDegrees: nil, solveRmsPx: nil, ambiguityRatio: nil, azimuthSigmaDegrees: nil,
                                 flightRestrictedAzimuthDegrees: nil, deviationFromPoolDegrees: nil,
                                 acceptedUnderOwnSolve: false, refusalReasonUnderOwnSolve: nil,
                                 releaseHeightUnderOwnSolve: nil, releaseDistanceUnderOwnSolve: nil,
                                 gErrorUnderOwnSolve: nil, viewAngleDegreesUnderOwnSolve: nil,
                                 impliedBallDiameterM: nil, impliedBallDiameterSpread: nil, startDepthM: nil, fileStart: w.fileStart)
            if let cal = BenchRunner.calibration(for: w, override: ov) {
                if let sol = ShotPlaneSolver.solveByFixedGravity(samples, calibration: cal, intrinsics: w.intrinsics) {
                    row.perShotAzimuthDegrees = Angle.degrees(CircularStats.wrapPositive(sol.frame.azimuth))
                    row.solveRmsPx = sol.pixelRMS
                    row.ambiguityRatio = sol.ambiguityRatio
                    row.azimuthSigmaDegrees = Angle.degrees(sol.azimuthSigma)
                    byClip[w.clip, default: []].append(sol.frame.azimuth)
                    var implied: [Double] = []
                    for sample in samples {
                        guard let dpx = sample.diameterPx, dpx > 0,
                              let P = sol.frame.intersect(ray: w.intrinsics.ray(sample.uv)) else { continue }
                        implied.append(dpx * P.z / w.intrinsics.fx)
                    }
                    if implied.count >= 5 {
                        row.impliedBallDiameterM = Stats.median(implied)
                        if let m = row.impliedBallDiameterM, m > 0, let p90 = BenchStats.p90(implied), let p10 = BenchStats.percentile(implied, 0.10) {
                            row.impliedBallDiameterSpread = (p90 - p10) / m
                        }
                    }
                    if let first = samples.first, let P = sol.frame.intersect(ray: w.intrinsics.ray(first.uv)) { row.startDepthM = P.z }
                }
                var o = AnalysisOptions()
                o.azimuthByFixedGravity = true
                if let r = w.releaseTimeOverride { o.windowOptions.releaseTimeOverride = r }
                if let a = try? ShotAnalyzer.analyze(track: samples, calibration: cal, intrinsics: w.intrinsics, options: o) {
                    row.acceptedUnderOwnSolve = ShotAcceptance.accepted(a)
                    row.refusalReasonUnderOwnSolve = ShotAcceptance.refusalReason(a)
                    row.releaseHeightUnderOwnSolve = a.metrics.release?.height
                    row.releaseDistanceUnderOwnSolve = a.metrics.release?.distance
                    row.gErrorUnderOwnSolve = a.confidence.gError.isFinite ? a.confidence.gError : nil
                    row.viewAngleDegreesUnderOwnSolve = Angle.degrees(a.confidence.viewAngle)
                } else {
                    row.refusalReasonUnderOwnSolve = "analysis threw under this window's own azimuth solve"
                }
            } else {
                row.refusalReasonUnderOwnSolve = "rim calibration failed under this variant's calibration"
            }
            rows.append(row)
        }

        // Pass 2: the robust pool per clip, then each window's deviation from it and its
        // flight-restricted re-solve (iterated pooling's first round, exposed per window).
        var pools: [PoolDiagnostics] = []
        var centreByClip: [String: Double] = [:]
        for clip in byClip.keys.sorted() {
            guard let pooled = AzimuthPooling.robust(byClip[clip]!, clip: clip, strategy: "robust median over all windows", config: config) else { continue }
            pools.append(pooled.diagnostics)
            centreByClip[clip] = pooled.center
        }
        let windowByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        for i in rows.indices {
            guard let centre = centreByClip[rows[i].clip], let w = windowByID[rows[i].windowID] else { continue }
            if let own = rows[i].perShotAzimuthDegrees {
                rows[i].deviationFromPoolDegrees = Angle.degrees(CircularStats.distance(Angle.radians(own), centre))
            }
            let ov = override(w)
            if let span = BenchRunner.flightSpan(w, override: ov, fixedAzimuth: centre),
               let az = BenchRunner.perShotAzimuth(w, override: ov, timeRange: span) {
                rows[i].flightRestrictedAzimuthDegrees = Angle.degrees(CircularStats.wrapPositive(az))
            }
        }

        return AzimuthDiagnosis(variant: variant.name, cacheDir: cacheDir, generatedAt: ISO8601DateFormatter().string(from: Date()),
                                rows: rows, pools: pools)
    }
}
