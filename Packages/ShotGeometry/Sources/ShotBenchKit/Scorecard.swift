// Replays a cache of `CachedWindow`s through `ShotAnalyzer.analyze` under one named variant and
// produces a `Scorecard`. No video, no network — every input is already in the cache.
import Foundation
import ShotGeometry

public struct WindowScore: Codable, Sendable {
    public var windowID: String
    public var clip: String
    public var spot: String?
    public var accepted: Bool
    public var refusalReason: String?
    public var gError: Double?
    public var rmsPx: Double?
    public var releaseHeight: Double?
    public var releaseSpeed: Double?
    public var releaseAngleDegrees: Double?
    public var releaseUnavailableReason: String?
    public var entryAngleDegrees: Double?
    public var entryAngleUnavailableReason: String?
    public var depthPastFrontRim: Double?
    public var sampleCount: Int?
    public var releaseTimeErrorMs: Double?
    /// The azimuth the analysis actually used, degrees in [0, 360) in the calibration's horizontal
    /// basis — the clip's pooled value where pooling engaged, this window's own solve otherwise.
    /// Optional so scorecards written before 2026-09-24 still decode.
    public var azimuthUsedDegrees: Double?
    /// `viewAngle` of the solved plane, degrees (0 = perfect side view, 90 = head-on).
    public var viewAngleDegrees: Double?
}

public struct SkippedWindow: Codable, Sendable, Error {
    public var windowID: String
    public var clip: String
    public var spot: String?
    public var reason: String
}

public struct BlockSpread: Codable, Sendable {
    public var clip: String
    public var spot: String?
    public var n: Int
    public var releaseHeightSD: Double?
    public var releaseHeightSDUnavailableReason: String?
    public var releaseSpeedSD: Double?
    public var releaseSpeedSDUnavailableReason: String?
}

public struct QualitySummary: Codable, Sendable {
    public var n: Int   // accepted windows the medians/p90 below are computed over
    public var medianAbsGError: Double?
    public var p90AbsGError: Double?
    public var medianRmsPx: Double?
    public var withinBlockSpread: [BlockSpread]
}

public struct RefusalBucket: Codable, Sendable { public var reason: String; public var count: Int }

public struct GroupSummary: Codable, Sendable {
    public var label: String
    public var windowsAnalysed: Int
    public var accepted: Int
    public var acceptanceRate: Double
    public var refusalHistogram: [RefusalBucket]
    public var quality: QualitySummary
}

public struct LabelMatch: Codable, Sendable {
    public var windowID: String
    public var clip: String
    public var labelVideo: String
    public var errorMs: Double
}

public struct LabelScoringSummary: Codable, Sendable {
    public var sourcePath: String
    public var status: String
    public var detail: String?
    public var matches: [LabelMatch]
}

public struct Scorecard: Codable, Sendable {
    public var variant: String
    public var variantSummary: String
    public var cacheDir: String
    public var generatedAt: String
    public var windows: [WindowScore]
    public var skipped: [SkippedWindow]
    public var overall: GroupSummary
    public var perSpot: [GroupSummary]
    public var labelScoring: LabelScoringSummary
    /// Precision/recall against `docs/footage-2026-09-13/window_labels.json` (shot / notShot / unsure
    /// hand labels — see `PrecisionRecall.swift`). Always present; `status` says whether it scored.
    public var windowLabelScoring: WindowLabelScoring
    public var notes: [String]
    /// What this variant's azimuth pooling did, per clip — engaged or not, and the numbers behind
    /// that decision. Nil for a variant that does not pool (and for scorecards written before
    /// 2026-09-24, which is why it is optional).
    public var pooling: [PoolDiagnostics]?
}

public enum BenchRunner {

    // MARK: - calibration

    static func calibration(for window: CachedWindow, override: CalibrationOverride = CalibrationOverride()) -> RimCalibration? {
        var options = RimCalibrationOptions()
        options.rimDiameter = window.rimDiameterUsed
        if let up = override.knownUp { options.knownUp = up }
        let points = override.rimBoundaryPoints ?? window.rimBoundaryPoints
        return try? RimCalibrator.calibrate(boundaryPoints: points, intrinsics: window.intrinsics, options: options)
    }

    // MARK: - session-pooled azimuth (baseline only)

    /// Mirrors `Probe.swift`'s pass 1 (`session azimuth: circular mean of N accepted shots…`): per
    /// clip, analyse every window with the per-shot fixed-gravity solve, collect the azimuths of the
    /// ones that pass acceptance, and pool them by circular mean when ≥3 agree within 25°.
    ///
    /// `override` lets a variant that needs session pooling (`gravityUp`, `autoFoundTrace`, in
    /// addition to `baseline`) pool with *its own* calibration — pass 1 must see the same rim
    /// boundary/knownUp the per-window pass 2 will use, or pooling would silently mix calibrations.
    ///
    /// This only ever sees the windows present *in this cache directory*. A live `session` run pools
    /// over every shot in one continuous capture; a cache can hold windows from several dump runs, so
    /// this is the closest a window-independent replay tool can get to that behaviour without
    /// silently assuming windows belong together just because they share a clip name. Document this
    /// when reading a `baseline` scorecard for a cache assembled from partial/limited dumps (e.g. a
    /// `--limit 3` slice): pooling may not engage there the way it would on the full clip, and that
    /// is expected, not a bug in the replay.
    static func legacyPooledAzimuthByClip(_ windows: [CachedWindow], override: @Sendable (_ window: CachedWindow) -> CalibrationOverride = { _ in CalibrationOverride() }) -> [String: Double] {
        var byClip: [String: [CachedWindow]] = [:]
        for w in windows { byClip[w.clip, default: []].append(w) }
        var out: [String: Double] = [:]
        for (clip, ws) in byClip {
            var azimuths: [Double] = []
            for w in ws {
                guard let cal = calibration(for: w, override: override(w)) else { continue }
                var o = AnalysisOptions()
                o.azimuthByFixedGravity = true
                if let r = w.releaseTimeOverride { o.windowOptions.releaseTimeOverride = r }
                guard let a = try? ShotAnalyzer.analyze(track: w.samples.map(\.imageSample), calibration: cal, intrinsics: w.intrinsics, options: o),
                      ShotAcceptance.accepted(a) else { continue }
                azimuths.append(a.azimuth.frame.azimuth)
            }
            guard azimuths.count >= 3 else { continue }
            let mean = atan2(azimuths.map(sin).reduce(0, +) / Double(azimuths.count), azimuths.map(cos).reduce(0, +) / Double(azimuths.count))
            func wrap(_ x: Double) -> Double { atan2(sin(x), cos(x)) }
            let spread = azimuths.map { abs(wrap($0 - mean)) }.max() ?? 0
            if spread <= (25.0 * Double.pi / 180.0) { out[clip] = mean }
        }
        return out
    }

    // MARK: - per-shot azimuths and the pooling strategies (2026-09-24 azimuth experiment)

    /// One window's own fixed-gravity azimuth solve under this variant's calibration — the quantity
    /// every pooling rule pools, and the one the diagnosis dump reports. Independent of acceptance:
    /// a window whose analysis later fails the gravity gate still has an azimuth, and leaving those
    /// out of the pool is exactly what the legacy rule does wrong.
    ///
    /// `timeRange` restricts the solve to (real-seconds) span — used by iterated pooling to re-solve
    /// over just the flight window. Falls back to the whole track if the range leaves too few
    /// samples for a solve, the same rule `ShotAnalyzer` applies to `azimuthTimeRange`.
    static func perShotAzimuth(_ w: CachedWindow, override: CalibrationOverride = CalibrationOverride(),
                               timeRange: ClosedRange<Double>? = nil) -> Double? {
        guard let cal = calibration(for: w, override: override) else { return nil }
        let all = w.samples.map(\.imageSample).sorted { $0.t < $1.t }
        let restricted = timeRange.map { r in all.filter { r.contains($0.t) } } ?? all
        let use = restricted.count >= 8 ? restricted : all
        return ShotPlaneSolver.solveByFixedGravity(use, calibration: cal, intrinsics: w.intrinsics)?.frame.azimuth
    }

    /// Analyse a window with a given azimuth fixed, and report the flight window it found, in real
    /// seconds. Used by iterated pooling to know which samples are actually in flight.
    static func flightSpan(_ w: CachedWindow, override: CalibrationOverride, fixedAzimuth: Double) -> ClosedRange<Double>? {
        guard let cal = calibration(for: w, override: override) else { return nil }
        var o = AnalysisOptions()
        o.azimuthByFixedGravity = true
        o.fixedAzimuth = fixedAzimuth
        if let r = w.releaseTimeOverride { o.windowOptions.releaseTimeOverride = r }
        guard let a = try? ShotAnalyzer.analyze(track: w.samples.map(\.imageSample), calibration: cal, intrinsics: w.intrinsics, options: o),
              a.window.endIndex < a.planeSamples.count else { return nil }
        let lo = a.window.releaseTime, hi = a.planeSamples[a.window.endIndex].t
        return lo < hi ? lo...hi : nil
    }

    /// Is this window accepted under its own per-shot solve? (The population the legacy rule and
    /// `.robustAccepted` pool over.)
    static func acceptedUnderOwnSolve(_ w: CachedWindow, override: CalibrationOverride) -> Bool {
        guard let cal = calibration(for: w, override: override) else { return false }
        var o = AnalysisOptions()
        o.azimuthByFixedGravity = true
        if let r = w.releaseTimeOverride { o.windowOptions.releaseTimeOverride = r }
        guard let a = try? ShotAnalyzer.analyze(track: w.samples.map(\.imageSample), calibration: cal, intrinsics: w.intrinsics, options: o) else { return false }
        return ShotAcceptance.accepted(a)
    }

    /// The pooled azimuth per clip under a variant's pooling strategy, plus the diagnostics that
    /// say why each clip was or was not pooled. `.none` returns nothing and computes nothing.
    static func pooledAzimuth(_ windows: [CachedWindow], strategy: AzimuthPoolingStrategy,
                              override: @Sendable (_ window: CachedWindow) -> CalibrationOverride = { _ in CalibrationOverride() })
        -> (byClip: [String: Double], byWindow: [String: Double], diagnostics: [PoolDiagnostics]) {
        switch strategy {
        case .none:
            return ([:], [:], [])

        case .clusteredRobust(let config, let gapDegrees):
            var byClipWindows: [String: [CachedWindow]] = [:]
            for w in windows { byClipWindows[w.clip, default: []].append(w) }
            var byWindow: [String: Double] = [:]
            var diags: [PoolDiagnostics] = []
            for clip in byClipWindows.keys.sorted() {
                var azimuths: [(id: String, az: Double)] = []
                for w in byClipWindows[clip]! {
                    if let az = perShotAzimuth(w, override: override(w)) { azimuths.append((w.windowID, az)) }
                }
                let groups = AzimuthPooling.clusters(azimuths.map(\.az), gapDegrees: gapDegrees)
                if groups.isEmpty {
                    diags.append(PoolDiagnostics(clip: clip, strategy: strategy.label, inputCount: 0, keptCount: 0, droppedCount: 0,
                                                 centerDegrees: nil, scaledMADDegrees: nil, maxDeviationDegrees: nil, resultantLength: nil,
                                                 engaged: false, reason: "no window in this clip produced a per-shot azimuth solve",
                                                 iterations: nil, iterationShiftsDegrees: nil))
                    continue
                }
                for (i, group) in groups.enumerated() {
                    guard let pooled = AzimuthPooling.robust(group, clip: clip, strategy: strategy.label + " [cluster \(i + 1) of \(groups.count)]", config: config) else { continue }
                    var d = pooled.diagnostics
                    if d.engaged {
                        // A window joins this cluster when its own solve is inside the cluster's span.
                        let radius = max(Angle.radians(gapDegrees), (CircularStats.maxDeviation(group, about: pooled.center) ?? 0))
                        for a in azimuths where CircularStats.distance(a.az, pooled.center) <= radius {
                            byWindow[a.id] = pooled.center
                        }
                    } else {
                        d.reason = "cluster \(i + 1) of \(groups.count): " + d.reason
                    }
                    diags.append(d)
                }
            }
            return ([:], byWindow, diags)

        case .legacyAcceptedMean:
            let byClip = legacyPooledAzimuthByClip(windows, override: override)
            var diags: [PoolDiagnostics] = []
            for clip in Set(windows.map(\.clip)).sorted() {
                let engaged = byClip[clip] != nil
                diags.append(PoolDiagnostics(clip: clip, strategy: strategy.label, inputCount: windows.filter { $0.clip == clip }.count,
                                             keptCount: 0, droppedCount: 0,
                                             centerDegrees: byClip[clip].map { Angle.degrees(CircularStats.wrapPositive($0)) },
                                             scaledMADDegrees: nil, maxDeviationDegrees: nil, resultantLength: nil,
                                             engaged: engaged,
                                             reason: engaged ? "pooled (legacy rule)" : "fewer than 3 accepted shots, or they disagreed by more than 25°",
                                             iterations: nil, iterationShiftsDegrees: nil))
            }
            return (byClip, [:], diags)

        case .robustAll(let config), .robustAccepted(let config):
            var acceptedOnly = false
            if case .robustAccepted = strategy { acceptedOnly = true }
            var byClipWindows: [String: [CachedWindow]] = [:]
            for w in windows { byClipWindows[w.clip, default: []].append(w) }
            var out: [String: Double] = [:]
            var diags: [PoolDiagnostics] = []
            for clip in byClipWindows.keys.sorted() {
                var values: [Double] = []
                for w in byClipWindows[clip]! {
                    let ov = override(w)
                    if acceptedOnly, !acceptedUnderOwnSolve(w, override: ov) { continue }
                    if let az = perShotAzimuth(w, override: ov) { values.append(az) }
                }
                guard let pooled = AzimuthPooling.robust(values, clip: clip, strategy: strategy.label, config: config) else {
                    diags.append(PoolDiagnostics(clip: clip, strategy: strategy.label, inputCount: values.count, keptCount: 0, droppedCount: 0,
                                                 centerDegrees: nil, scaledMADDegrees: nil, maxDeviationDegrees: nil, resultantLength: nil,
                                                 engaged: false, reason: "no window in this clip produced a per-shot azimuth solve",
                                                 iterations: nil, iterationShiftsDegrees: nil))
                    continue
                }
                if pooled.diagnostics.engaged { out[clip] = pooled.center }
                diags.append(pooled.diagnostics)
            }
            return (out, [:], diags)

        case .iteratedRobust(let config, let iterations, let toleranceDegrees):
            var byClipWindows: [String: [CachedWindow]] = [:]
            for w in windows { byClipWindows[w.clip, default: []].append(w) }
            var out: [String: Double] = [:]
            var diags: [PoolDiagnostics] = []
            for clip in byClipWindows.keys.sorted() {
                let ws = byClipWindows[clip]!
                // Round 0: the whole-track per-shot solves, pooled robustly.
                var azimuths: [String: Double] = [:]
                for w in ws { if let az = perShotAzimuth(w, override: override(w)) { azimuths[w.windowID] = az } }
                guard var pooled = AzimuthPooling.robust(Array(azimuths.values), clip: clip, strategy: strategy.label, config: config) else {
                    diags.append(PoolDiagnostics(clip: clip, strategy: strategy.label, inputCount: 0, keptCount: 0, droppedCount: 0,
                                                 centerDegrees: nil, scaledMADDegrees: nil, maxDeviationDegrees: nil, resultantLength: nil,
                                                 engaged: false, reason: "no window in this clip produced a per-shot azimuth solve",
                                                 iterations: 0, iterationShiftsDegrees: nil))
                    continue
                }
                var shifts: [Double] = []
                var rounds = 0
                while pooled.diagnostics.engaged && rounds < iterations {
                    rounds += 1
                    // Re-solve every window's azimuth over just the flight window the current pooled
                    // azimuth implies; a window whose analysis or re-solve fails keeps its previous value.
                    for w in ws {
                        let ov = override(w)
                        guard let span = flightSpan(w, override: ov, fixedAzimuth: pooled.center),
                              let az = perShotAzimuth(w, override: ov, timeRange: span) else { continue }
                        azimuths[w.windowID] = az
                    }
                    guard let next = AzimuthPooling.robust(Array(azimuths.values), clip: clip, strategy: strategy.label, config: config) else { break }
                    let shift = Angle.degrees(CircularStats.distance(next.center, pooled.center))
                    shifts.append(shift)
                    pooled = next
                    if shift < toleranceDegrees { break }
                }
                var d = pooled.diagnostics
                d.iterations = rounds
                d.iterationShiftsDegrees = shifts
                if d.engaged { out[clip] = pooled.center }
                diags.append(d)
            }
            return (out, [:], diags)
        }
    }

    // MARK: - per-window evaluation

    static func evaluate(_ window: CachedWindow, variant: Variant, context: VariantContext, labels: LoadedLabels?)
        -> (result: Result<WindowScore, SkippedWindow>, labelMatch: LabelMatch?) {
        switch variant.makeOptions(window, context) {
        case .skip(let reason):
            return (.failure(SkippedWindow(windowID: window.windowID, clip: window.clip, spot: window.spot, reason: reason)), nil)
        case .options(let o):
            guard let cal = calibration(for: window, override: variant.calibrationOverride(window)) else {
                return (.failure(SkippedWindow(windowID: window.windowID, clip: window.clip, spot: window.spot,
                                               reason: "rim calibration failed under this variant's calibration (boundary override or knownUp)")), nil)
            }
            do {
                let a = try ShotAnalyzer.analyze(track: window.samples.map(\.imageSample), calibration: cal, intrinsics: window.intrinsics, options: o)
                let accepted = ShotAcceptance.accepted(a)
                var errMs: Double? = nil
                var match: LabelMatch? = nil
                if let labels, let m = labels.matching(window) {
                    let e = (a.confidence.releaseTime - m.releaseReal) * 1000
                    errMs = e
                    match = LabelMatch(windowID: window.windowID, clip: window.clip, labelVideo: m.label.video, errorMs: e)
                }
                let score = WindowScore(windowID: window.windowID, clip: window.clip, spot: window.spot, accepted: accepted,
                                        refusalReason: ShotAcceptance.refusalReason(a), gError: a.confidence.gError, rmsPx: a.confidence.rmsPx,
                                        releaseHeight: a.metrics.release?.height, releaseSpeed: a.metrics.release?.speed,
                                        releaseAngleDegrees: a.metrics.release?.angleDegrees, releaseUnavailableReason: a.metrics.releaseUnavailableReason,
                                        entryAngleDegrees: a.metrics.entryAngleDegrees, entryAngleUnavailableReason: a.metrics.entryAngleUnavailableReason,
                                        depthPastFrontRim: a.metrics.depthPastFrontRim, sampleCount: a.confidence.nInliers, releaseTimeErrorMs: errMs,
                                        azimuthUsedDegrees: Angle.degrees(CircularStats.wrapPositive(a.azimuth.frame.azimuth)),
                                        viewAngleDegrees: Angle.degrees(a.confidence.viewAngle))
                return (.success(score), match)
            } catch {
                let score = WindowScore(windowID: window.windowID, clip: window.clip, spot: window.spot, accepted: false, refusalReason: "\(error)",
                                        gError: nil, rmsPx: nil, releaseHeight: nil, releaseSpeed: nil, releaseAngleDegrees: nil,
                                        releaseUnavailableReason: nil, entryAngleDegrees: nil, entryAngleUnavailableReason: nil,
                                        depthPastFrontRim: nil, sampleCount: nil, releaseTimeErrorMs: nil,
                                        azimuthUsedDegrees: nil, viewAngleDegrees: nil)
                return (.success(score), nil)
            }
        }
    }

    // MARK: - refusal categorisation (for the histogram only; `refusalReason` on each window keeps the exact text)

    static func category(_ reason: String) -> String {
        let first = reason.split(separator: ";").first.map(String.init) ?? reason
        let r = first.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("only") && r.contains("ball detections") { return "too few detections" }
        if r.hasPrefix("shot plane:") { return "azimuth solve failed" }
        if r.hasPrefix("flight window:") { return "flight window detection failed" }
        if r.hasPrefix("trajectory fit:") { return "trajectory fit failed" }
        if r.contains("could not project") { return "projection failed" }
        if r.hasPrefix("gravity check failed") { return "gravity rejected (curve fit)" }
        if r.contains("gravity error") { return "gravity gate (> 8%)" }
        if r.contains("release unavailable") { return "no observed release" }
        if r.contains("release height") || r.contains("release speed") || r.contains("depth") || r.contains("implausible") { return "plausibility gate" }
        if r.contains("fit residual") { return "residual gate (> 25 px)" }
        return "other: \(r)"
    }

    // MARK: - aggregation

    static func withinBlockSpread(_ scores: [WindowScore]) -> [BlockSpread] {
        struct Key: Hashable { var clip: String; var spot: String? }
        var byBlock: [Key: [WindowScore]] = [:]
        for s in scores where s.accepted { byBlock[Key(clip: s.clip, spot: s.spot), default: []].append(s) }
        return byBlock.keys.sorted { ($0.clip, $0.spot ?? "") < ($1.clip, $1.spot ?? "") }.map { key in
            let ws = byBlock[key]!
            let n = ws.count
            let reason = n < 5 ? "n = \(n) < 5" : nil
            let hSD = n < 5 ? nil : BenchStats.sd(ws.compactMap(\.releaseHeight))
            let vSD = n < 5 ? nil : BenchStats.sd(ws.compactMap(\.releaseSpeed))
            return BlockSpread(clip: key.clip, spot: key.spot, n: n,
                               releaseHeightSD: hSD, releaseHeightSDUnavailableReason: hSD == nil ? reason : nil,
                               releaseSpeedSD: vSD, releaseSpeedSDUnavailableReason: vSD == nil ? reason : nil)
        }
    }

    static func summarize(_ scores: [WindowScore], label: String, blocks: [BlockSpread]) -> GroupSummary {
        let accepted = scores.filter(\.accepted)
        var hist: [String: Int] = [:]
        for s in scores where !s.accepted { hist[category(s.refusalReason ?? "unknown"), default: 0] += 1 }
        let histogram = hist.keys.sorted().map { RefusalBucket(reason: $0, count: hist[$0]!) }
        let quality = QualitySummary(n: accepted.count,
                                     medianAbsGError: BenchStats.median(accepted.compactMap { $0.gError.map(abs) }),
                                     p90AbsGError: BenchStats.p90(accepted.compactMap { $0.gError.map(abs) }),
                                     medianRmsPx: BenchStats.median(accepted.compactMap(\.rmsPx)),
                                     withinBlockSpread: blocks)
        return GroupSummary(label: label, windowsAnalysed: scores.count, accepted: accepted.count,
                            acceptanceRate: scores.isEmpty ? 0 : Double(accepted.count) / Double(scores.count),
                            refusalHistogram: histogram, quality: quality)
    }

    // MARK: - entry point

    public static func run(windows: [CachedWindow], variantName: String, cacheDir: String, labelsPath: String = LabelLoader.defaultPath,
                           windowLabelsPath: String = WindowLabelLoader.defaultPath) -> Scorecard? {
        guard let variant = Variant.named(variantName) else { return nil }
        var context = VariantContext()
        let pooling = pooledAzimuth(windows, strategy: variant.pooling, override: variant.calibrationOverride)
        context.pooledAzimuthByClip = pooling.byClip
        context.pooledAzimuthByWindowID = pooling.byWindow
        let labelResult = LabelLoader.load(path: labelsPath)

        var scores: [WindowScore] = []
        var skipped: [SkippedWindow] = []
        var matches: [LabelMatch] = []
        for w in windows {
            let (result, match) = evaluate(w, variant: variant, context: context, labels: labelResult.labels)
            switch result {
            case .success(let s): scores.append(s)
            case .failure(let sk): skipped.append(sk)
            }
            if let match { matches.append(match) }
        }

        let allBlocks = withinBlockSpread(scores)
        let overall = summarize(scores, label: "overall", blocks: allBlocks)
        var bySpot: [String: [WindowScore]] = [:]
        for s in scores { bySpot[s.spot ?? "(unlabeled)", default: []].append(s) }
        let perSpot = bySpot.keys.sorted().map { spot in
            summarize(bySpot[spot]!, label: spot, blocks: allBlocks.filter { ($0.spot ?? "(unlabeled)") == spot })
        }

        var notes: [String] = []
        if variant.pooling.isEnabled {
            let pooled = context.pooledAzimuthByClip
            notes.append("azimuth pooling rule: " + variant.pooling.label)
            if !context.pooledAzimuthByWindowID.isEmpty {
                notes.append("pooled azimuth applied per window (clustered): \(context.pooledAzimuthByWindowID.count) of \(windows.count) windows took a cluster centre; the rest kept their own solve")
            }
            notes.append(pooled.isEmpty && context.pooledAzimuthByWindowID.isEmpty ? "pooled azimuth did not engage for any clip in this cache; every window fell back to its own fixed-gravity solve"
                                        : "pooled azimuth applied for: " + pooled.keys.sorted().map { clip in
                                            String(format: "%@ (%.1f°)", clip, Angle.degrees(CircularStats.wrapPositive(pooled[clip]!))) }.joined(separator: ", "))
            for d in pooling.diagnostics where !d.engaged { notes.append("not pooled — \(d.clip): \(d.reason)") }
        }
        if !skipped.isEmpty { notes.append("\(skipped.count) window(s) skipped by this variant — see `skipped`") }

        let windowLabelScoring = WindowLabelScorer.run(scores: scores, skipped: skipped, labelsPath: windowLabelsPath)

        let iso = ISO8601DateFormatter()
        return Scorecard(variant: variant.name, variantSummary: variant.summary, cacheDir: cacheDir, generatedAt: iso.string(from: Date()),
                         windows: scores, skipped: skipped, overall: overall, perSpot: perSpot,
                         labelScoring: LabelScoringSummary(sourcePath: labelResult.sourcePath, status: labelResult.status, detail: labelResult.detail, matches: matches),
                         windowLabelScoring: windowLabelScoring,
                         notes: notes, pooling: pooling.diagnostics.isEmpty ? nil : pooling.diagnostics)
    }
}
