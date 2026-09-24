// `ShotBench compare` — pairs two scorecards by windowID and reports only what the data supports.
// Acceptance-rate movement alone never drives the verdict; a regression on gravity error, fit
// residual, or within-block spread overrides it (see `Comparator.verdict`).
import Foundation

// MARK: - generic pairing (also unit-tested directly)

public enum Pairing {
    /// Pairs two windowID → value maps. Keys present in only one side are reported, never dropped.
    public static func pair<T>(_ base: [String: T], _ candidate: [String: T]) -> (pairs: [(id: String, base: T, candidate: T)], baseOnly: [String], candidateOnly: [String]) {
        var pairs: [(id: String, base: T, candidate: T)] = []
        var baseOnly: [String] = []
        for (k, bv) in base {
            if let cv = candidate[k] { pairs.append((id: k, base: bv, candidate: cv)) } else { baseOnly.append(k) }
        }
        let candidateOnly = candidate.keys.filter { base[$0] == nil }
        return (pairs.sorted { $0.id < $1.id }, baseOnly.sorted(), candidateOnly.sorted())
    }
}

public struct McNemarSection: Codable, Sendable {
    public var b: Int   // baseline accepted, candidate rejected
    public var c: Int   // baseline rejected, candidate accepted
    public var net: Int // c - b: positive means the candidate accepts more
    public var n: Int   // paired windows the test ran over (both scored, not skipped, by either side)
    public var p: Double?
    public var minorityNeededForSignificance: Int?
}

public struct PairedDeltaSection: Codable, Sendable {
    public var metric: String
    public var n: Int
    public var medianDelta: Double?   // median(candidate - base)
    public var positive: Int
    public var negative: Int
    public var ties: Int
    public var p: Double?
}

public struct RegressionEntry: Codable, Sendable { public var kind: String; public var detail: String }
public struct RegressionSection: Codable, Sendable {
    public var gErrorAbsoluteThreshold: Double
    public var rmsPxThreshold: Double
    public var rule: String
    public var entries: [RegressionEntry]
}

public struct MissingWindow: Codable, Sendable { public var windowID: String; public var reason: String }
public struct MissingSection: Codable, Sendable {
    public var inBaselineOnly: [MissingWindow]
    public var inCandidateOnly: [MissingWindow]
}

public struct CompareReport: Codable, Sendable {
    public var baselineVariant: String
    public var candidateVariant: String
    public var generatedAt: String
    public var mcNemar: McNemarSection
    public var pairedDeltas: [PairedDeltaSection]
    public var regressions: RegressionSection
    public var missing: MissingSection
    public var verdict: String
    public var verdictReason: String
}

public enum Comparator {
    public static let gErrorAbsoluteThreshold = 0.02   // 2 percentage points of |gError|, absolute
    public static let rmsPxThreshold = 2.0             // px

    public static func compare(base: Scorecard, candidate: Scorecard) -> CompareReport {
        let baseByID = Dictionary(base.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let candByID = Dictionary(candidate.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let baseSkipIDs = Set(base.skipped.map(\.windowID))
        let candSkipIDs = Set(candidate.skipped.map(\.windowID))
        let baseAllIDs = Set(baseByID.keys).union(baseSkipIDs)
        let candAllIDs = Set(candByID.keys).union(candSkipIDs)

        // MARK: McNemar
        let acceptedPairs = Pairing.pair(baseByID.mapValues(\.accepted), candByID.mapValues(\.accepted))
        let b = acceptedPairs.pairs.filter { $0.base && !$0.candidate }.count
        let c = acceptedPairs.pairs.filter { !$0.base && $0.candidate }.count
        let mc = BenchStats.mcNemar(b: b, c: c)
        let mcSection = McNemarSection(b: b, c: c, net: c - b, n: acceptedPairs.pairs.count, p: mc.p, minorityNeededForSignificance: mc.minorityNeededForSignificance)

        // MARK: paired deltas
        // `n` counts only *comparable* pairs: a metric that is `.infinity` in both arms (gError on a
        // fit whose g came out non-finite/non-positive, `GravityGate.verdict`) yields a `.nan` delta,
        // which is dropped rather than counted — it was not "unchanged", it could not be compared.
        func deltaSection(_ metric: String, _ base: [String: Double], _ cand: [String: Double]) -> PairedDeltaSection {
            let (pairs, _, _) = Pairing.pair(base, cand)
            let deltas = pairs.map { $0.candidate - $0.base }.filter(\.isFinite)
            let sign = BenchStats.signTest(deltas)
            return PairedDeltaSection(metric: metric, n: deltas.count, medianDelta: BenchStats.median(deltas),
                                      positive: sign.positive, negative: sign.negative, ties: sign.ties, p: sign.p)
        }
        var deltas: [PairedDeltaSection] = []
        deltas.append(deltaSection("gError", baseByID.compactMapValues(\.gError), candByID.compactMapValues(\.gError)))
        deltas.append(deltaSection("rmsPx", baseByID.compactMapValues(\.rmsPx), candByID.compactMapValues(\.rmsPx)))
        if !base.labelScoring.matches.isEmpty || !candidate.labelScoring.matches.isEmpty {
            let baseErr = Dictionary(base.labelScoring.matches.map { ($0.windowID, $0.errorMs) }, uniquingKeysWith: { a, _ in a })
            let candErr = Dictionary(candidate.labelScoring.matches.map { ($0.windowID, $0.errorMs) }, uniquingKeysWith: { a, _ in a })
            deltas.append(deltaSection("releaseTimeErrorMs", baseErr, candErr))
        }
        // within-block spread, paired by "clip|spot"
        func blockKey(_ s: BlockSpread) -> String { "\(s.clip)|\(s.spot ?? "(unlabeled)")" }
        let baseHeightSD = Dictionary(base.overall.quality.withinBlockSpread.compactMap { b in b.releaseHeightSD.map { (blockKey(b), $0) } }, uniquingKeysWith: { a, _ in a })
        let candHeightSD = Dictionary(candidate.overall.quality.withinBlockSpread.compactMap { b in b.releaseHeightSD.map { (blockKey(b), $0) } }, uniquingKeysWith: { a, _ in a })
        deltas.append(deltaSection("withinBlockSpread.releaseHeightSD", baseHeightSD, candHeightSD))
        let baseSpeedSD = Dictionary(base.overall.quality.withinBlockSpread.compactMap { b in b.releaseSpeedSD.map { (blockKey(b), $0) } }, uniquingKeysWith: { a, _ in a })
        let candSpeedSD = Dictionary(candidate.overall.quality.withinBlockSpread.compactMap { b in b.releaseSpeedSD.map { (blockKey(b), $0) } }, uniquingKeysWith: { a, _ in a })
        deltas.append(deltaSection("withinBlockSpread.releaseSpeedSD", baseSpeedSD, candSpeedSD))

        // MARK: regressions — fires regardless of acceptance
        var regressionEntries: [RegressionEntry] = []
        for pair in acceptedPairs.pairs where pair.base && pair.candidate {
            guard let bw = baseByID[pair.id], let cw = candByID[pair.id] else { continue }
            if let bg = bw.gError, let cg = cw.gError, (abs(cg) - abs(bg)) > gErrorAbsoluteThreshold {
                regressionEntries.append(RegressionEntry(kind: "gError", detail: String(format: "%@: |gError| %.1f%% → %.1f%% (accepted in both)", pair.id, abs(bg) * 100, abs(cg) * 100)))
            }
            if let br = bw.rmsPx, let cr = cw.rmsPx, (cr - br) > rmsPxThreshold {
                regressionEntries.append(RegressionEntry(kind: "rmsPx", detail: String(format: "%@: rmsPx %.1f → %.1f px (accepted in both)", pair.id, br, cr)))
            }
        }
        let (spreadPairsH, _, _) = Pairing.pair(baseHeightSD, candHeightSD)
        for p in spreadPairsH where p.candidate > p.base {
            regressionEntries.append(RegressionEntry(kind: "withinBlockSpread", detail: String(format: "%@: release-height SD %.3f → %.3f m (widened)", p.id, p.base, p.candidate)))
        }
        let (spreadPairsV, _, _) = Pairing.pair(baseSpeedSD, candSpeedSD)
        for p in spreadPairsV where p.candidate > p.base {
            regressionEntries.append(RegressionEntry(kind: "withinBlockSpread", detail: String(format: "%@: release-speed SD %.3f → %.3f m/s (widened)", p.id, p.base, p.candidate)))
        }
        let regressions = RegressionSection(gErrorAbsoluteThreshold: gErrorAbsoluteThreshold, rmsPxThreshold: rmsPxThreshold,
                                            rule: "a candidate that raises acceptance while worsening gravity error, fit residual, or within-block spread is a regression, not an improvement",
                                            entries: regressionEntries)

        // MARK: missing windows
        let baseOnlyIDs = baseAllIDs.subtracting(candAllIDs)
        let candOnlyIDs = candAllIDs.subtracting(baseAllIDs)
        let missing = MissingSection(
            inBaselineOnly: baseOnlyIDs.sorted().map { MissingWindow(windowID: $0, reason: "not present in the candidate run's cache") },
            inCandidateOnly: candOnlyIDs.sorted().map { MissingWindow(windowID: $0, reason: "not present in the baseline run's cache") })

        let (v, reason) = verdict(mcNemar: mcSection, deltas: deltas, regressions: regressions)
        let iso = ISO8601DateFormatter()
        return CompareReport(baselineVariant: base.variant, candidateVariant: candidate.variant, generatedAt: iso.string(from: Date()),
                             mcNemar: mcSection, pairedDeltas: deltas, regressions: regressions, missing: missing,
                             verdict: v, verdictReason: reason)
    }

    static func verdict(mcNemar: McNemarSection, deltas: [PairedDeltaSection], regressions: RegressionSection) -> (String, String) {
        let hasRegression = !regressions.entries.isEmpty
        let mcSig = (mcNemar.p ?? 1) <= 0.05
        let mcImproves = mcSig && mcNemar.net > 0
        let mcWorsens = mcSig && mcNemar.net < 0

        func sig(_ metric: String) -> PairedDeltaSection? { deltas.first { $0.metric == metric && ($0.p ?? 1) <= 0.05 } }
        // lower is better for gError and rmsPx
        let gErrorImproves = sig("gError").map { ($0.medianDelta ?? 0) < 0 } ?? false
        let gErrorWorsens = sig("gError").map { ($0.medianDelta ?? 0) > 0 } ?? false
        let rmsImproves = sig("rmsPx").map { ($0.medianDelta ?? 0) < 0 } ?? false
        let rmsWorsens = sig("rmsPx").map { ($0.medianDelta ?? 0) > 0 } ?? false

        let improves = mcImproves || gErrorImproves || rmsImproves
        let worsens = mcWorsens || gErrorWorsens || rmsWorsens

        func pStr(_ p: Double?) -> String { p.map { String(format: "%.3f", $0) } ?? "n/a" }

        if hasRegression, mcImproves {
            return ("REGRESSED", "candidate accepted \(mcNemar.net) more window(s) net (McNemar p=\(pStr(mcNemar.p))) but \(regressions.entries.count) regression(s) fired on the accepted-in-both windows or within-block spread: raising acceptance while worsening gravity error, fit residual, or spread is a regression, not an improvement.")
        }
        if hasRegression {
            let sample = regressions.entries.prefix(2).map(\.detail).joined(separator: "; ")
            if improves && !worsens {
                return ("MIXED", "a metric improved significantly (McNemar p=\(pStr(mcNemar.p)), or a paired delta) but \(regressions.entries.count) regression(s) also fired: \(sample)")
            }
            return ("REGRESSED", "\(regressions.entries.count) regression(s) fired: \(sample)")
        }
        if improves && !worsens {
            return ("IMPROVED", "candidate net \(mcNemar.net >= 0 ? "+" : "")\(mcNemar.net) verdict flips (McNemar p=\(pStr(mcNemar.p))) with no regression and no significant worsening on gError/rmsPx.")
        }
        if worsens && !improves {
            return ("REGRESSED", "candidate net \(mcNemar.net >= 0 ? "+" : "")\(mcNemar.net) verdict flips (McNemar p=\(pStr(mcNemar.p))) with a significant worsening on gError/rmsPx and no offsetting improvement.")
        }
        if improves && worsens {
            return ("MIXED", "some measures moved significantly in each direction (McNemar p=\(pStr(mcNemar.p)), gError/rmsPx deltas) — read the paired-delta and regression sections before picking a side.")
        }
        return ("NO DIFFERENCE", "no verdict flip beyond chance (McNemar p=\(pStr(mcNemar.p))) and no paired-delta metric moved significantly (p ≤ 0.05, α uncorrected) — not distinguishable from chance on this corpus.")
    }
}
