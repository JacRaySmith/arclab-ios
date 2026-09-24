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
    public var notes: [String]
}

public enum BenchRunner {

    // MARK: - calibration

    static func calibration(for window: CachedWindow) -> RimCalibration? {
        var options = RimCalibrationOptions()
        options.rimDiameter = window.rimDiameterUsed
        return try? RimCalibrator.calibrate(boundaryPoints: window.rimBoundaryPoints, intrinsics: window.intrinsics, options: options)
    }

    // MARK: - session-pooled azimuth (baseline only)

    /// Mirrors `Probe.swift`'s pass 1 (`session azimuth: circular mean of N accepted shots…`): per
    /// clip, analyse every window with the per-shot fixed-gravity solve, collect the azimuths of the
    /// ones that pass acceptance, and pool them by circular mean when ≥3 agree within 25°.
    ///
    /// This only ever sees the windows present *in this cache directory*. A live `session` run pools
    /// over every shot in one continuous capture; a cache can hold windows from several dump runs, so
    /// this is the closest a window-independent replay tool can get to that behaviour without
    /// silently assuming windows belong together just because they share a clip name. Document this
    /// when reading a `baseline` scorecard for a cache assembled from partial/limited dumps (e.g. a
    /// `--limit 3` slice): pooling may not engage there the way it would on the full clip, and that
    /// is expected, not a bug in the replay.
    static func pooledAzimuthByClip(_ windows: [CachedWindow]) -> [String: Double] {
        var byClip: [String: [CachedWindow]] = [:]
        for w in windows { byClip[w.clip, default: []].append(w) }
        var out: [String: Double] = [:]
        for (clip, ws) in byClip {
            var azimuths: [Double] = []
            for w in ws {
                guard let cal = calibration(for: w) else { continue }
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

    // MARK: - per-window evaluation

    static func evaluate(_ window: CachedWindow, variant: Variant, context: VariantContext, labels: LoadedLabels?)
        -> (result: Result<WindowScore, SkippedWindow>, labelMatch: LabelMatch?) {
        switch variant.makeOptions(window, context) {
        case .skip(let reason):
            return (.failure(SkippedWindow(windowID: window.windowID, clip: window.clip, spot: window.spot, reason: reason)), nil)
        case .options(let o):
            guard let cal = calibration(for: window) else {
                return (.failure(SkippedWindow(windowID: window.windowID, clip: window.clip, spot: window.spot,
                                               reason: "rim calibration failed for this window's cached boundary points")), nil)
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
                                        depthPastFrontRim: a.metrics.depthPastFrontRim, sampleCount: a.confidence.nInliers, releaseTimeErrorMs: errMs)
                return (.success(score), match)
            } catch {
                let score = WindowScore(windowID: window.windowID, clip: window.clip, spot: window.spot, accepted: false, refusalReason: "\(error)",
                                        gError: nil, rmsPx: nil, releaseHeight: nil, releaseSpeed: nil, releaseAngleDegrees: nil,
                                        releaseUnavailableReason: nil, entryAngleDegrees: nil, entryAngleUnavailableReason: nil,
                                        depthPastFrontRim: nil, sampleCount: nil, releaseTimeErrorMs: nil)
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

    public static func run(windows: [CachedWindow], variantName: String, cacheDir: String, labelsPath: String = LabelLoader.defaultPath) -> Scorecard? {
        guard let variant = Variant.named(variantName) else { return nil }
        var context = VariantContext()
        if variant.needsSessionPooling { context.pooledAzimuthByClip = pooledAzimuthByClip(windows) }
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
        if variant.needsSessionPooling {
            let pooled = context.pooledAzimuthByClip
            notes.append(pooled.isEmpty ? "session-pooled azimuth did not engage for any clip in this cache (fewer than 3 accepted shots, or they disagreed by > 25°); every window fell back to its own fixed-gravity solve"
                                        : "session-pooled azimuth applied for: " + pooled.keys.sorted().joined(separator: ", "))
        }
        if !skipped.isEmpty { notes.append("\(skipped.count) window(s) skipped by this variant — see `skipped`") }

        let iso = ISO8601DateFormatter()
        return Scorecard(variant: variant.name, variantSummary: variant.summary, cacheDir: cacheDir, generatedAt: iso.string(from: Date()),
                         windows: scores, skipped: skipped, overall: overall, perSpot: perSpot,
                         labelScoring: LabelScoringSummary(sourcePath: labelResult.sourcePath, status: labelResult.status, detail: labelResult.detail, matches: matches),
                         notes: notes)
    }
}
