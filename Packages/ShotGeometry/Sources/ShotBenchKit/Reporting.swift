// Markdown rendering for `ShotBench run` and `ShotBench compare`. Mirrors the style of
// `FormEvalKit/Report.swift`: a `fmt` helper that prints "—" for anything unavailable, one table per
// section, nothing hidden.
import Foundation

public enum BenchReporting {
    public static func fmt(_ x: Double?, _ d: Int = 3) -> String {
        guard let x, x.isFinite else { return "—" }
        return String(format: "%.\(d)f", x)
    }
    static func pct(_ x: Double?) -> String {
        guard let x, x.isFinite else { return "—" }
        return String(format: "%.1f%%", x * 100)
    }

    public static func markdown(_ s: Scorecard) -> String {
        var out = ""
        func line(_ t: String) { out += t + "\n" }
        line("## ShotBench run — variant `\(s.variant)`")
        line(s.variantSummary)
        line("")
        line("Cache: `\(s.cacheDir)`  ·  generated \(s.generatedAt)")
        line("")
        line("### Acceptance")
        line("| group | windows | accepted | rate | median |gError| | p90 |gError| | median rmsPx | n (quality) |")
        line("|---|---:|---:|---:|---:|---:|---:|---:|")
        func row(_ g: GroupSummary) {
            line("| \(g.label) | \(g.windowsAnalysed) | \(g.accepted) | \(pct(g.acceptanceRate)) | \(fmt(g.quality.medianAbsGError)) | \(fmt(g.quality.p90AbsGError)) | \(fmt(g.quality.medianRmsPx, 1)) | \(g.quality.n) |")
        }
        row(s.overall)
        for g in s.perSpot { row(g) }
        line("")
        line("**Acceptance rate alone is never the verdict** — read it beside gError/rmsPx and the within-block spread below; a variant that accepts more by loosening physics is a regression.")
        line("")
        line("### Refusal reasons (overall)")
        if s.overall.refusalHistogram.isEmpty { line("none — every analysed window was accepted.") }
        else {
            line("| reason | count |")
            line("|---|---:|")
            for b in s.overall.refusalHistogram.sorted(by: { $0.count > $1.count }) { line("| \(b.reason) | \(b.count) |") }
        }
        line("")
        line("### Within-block spread (accepted windows, same clip + spot; refused below n = 5)")
        if s.overall.quality.withinBlockSpread.isEmpty { line("no blocks.") }
        else {
            line("| clip | spot | n | release-height SD (m) | release-speed SD (m/s) |")
            line("|---|---|---:|---:|---:|")
            for b in s.overall.quality.withinBlockSpread {
                let h = b.releaseHeightSD.map { fmt($0) } ?? (b.releaseHeightSDUnavailableReason ?? "—")
                let v = b.releaseSpeedSD.map { fmt($0) } ?? (b.releaseSpeedSDUnavailableReason ?? "—")
                line("| \(b.clip) | \(b.spot ?? "(unlabeled)") | \(b.n) | \(h) | \(v) |")
            }
        }
        line("")
        if !s.skipped.isEmpty {
            line("### Skipped by this variant (\(s.skipped.count))")
            line("| windowID | clip | spot | reason |")
            line("|---|---|---|---|")
            for sk in s.skipped { line("| \(sk.windowID) | \(sk.clip) | \(sk.spot ?? "—") | \(sk.reason) |") }
            line("")
        }
        line("### Release-time labels")
        line("source: `\(s.labelScoring.sourcePath)` — \(s.labelScoring.status)" + (s.labelScoring.detail.map { ": \($0)" } ?? ""))
        if !s.labelScoring.matches.isEmpty {
            line("")
            line("| windowID | clip | label video | error (ms) |")
            line("|---|---|---|---:|")
            for m in s.labelScoring.matches { line("| \(m.windowID) | \(m.clip) | \(m.labelVideo) | \(fmt(m.errorMs, 1)) |") }
        }
        line("")
        line("### Shot labels (precision / recall)")
        let wl = s.windowLabelScoring
        if wl.status != "scored" {
            line("labels not found at `\(wl.sourcePath)` (\(wl.status)" + (wl.detail.map { ": \($0)" } ?? "") + ") — precision/recall not computed.")
        } else {
            line("source: `\(wl.sourcePath)`")
            line("")
            line("| group | shot (labelled) | shot accepted | recall | accepted | accepted w/ definite label | accepted shot | precision | unsure excluded | no label |")
            line("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
            func row(_ g: WindowLabelGroupSummary) {
                line("| \(g.label) | \(g.shotCount) | \(g.shotAccepted) | \(pct(g.recall)) | \(g.acceptedCount) | \(g.acceptedWithDefiniteLabel) | \(g.acceptedShot) | \(pct(g.precision)) | \(g.unsureCount) | \(g.noLabelCount) |")
            }
            if let overall = wl.overall { row(overall) }
            for g in wl.perClip { row(g) }
            func refusalTable(_ title: String, _ groups: [(String, [RefusalBucket])]) {
                line("")
                line("### \(title)")
                for (label, hist) in groups {
                    if hist.isEmpty { continue }
                    line("**\(label)**")
                    line("| reason | count |")
                    line("|---|---:|")
                    for b in hist.sorted(by: { $0.count > $1.count }) { line("| \(b.reason) | \(b.count) |") }
                    line("")
                }
            }
            if let overall = wl.overall {
                refusalTable("Refusal reasons among labelled `shot` windows (refused, and it was a shot)",
                             [("overall", overall.refusalByLabel.shot)] + wl.perClip.map { ($0.label, $0.refusalByLabel.shot) })
                refusalTable("Refusal reasons among labelled `notShot` windows (refused, and correctly so)",
                             [("overall", overall.refusalByLabel.notShot)] + wl.perClip.map { ($0.label, $0.refusalByLabel.notShot) })
            }
        }
        if !s.notes.isEmpty {
            line("")
            line("### Notes")
            for n in s.notes { line("- \(n)") }
        }
        return out
    }

    public static func markdown(_ r: CompareReport) -> String {
        var out = ""
        func line(_ t: String) { out += t + "\n" }
        line("## ShotBench compare — `\(r.baselineVariant)` (baseline) vs `\(r.candidateVariant)` (candidate)")
        line("generated \(r.generatedAt)")
        line("")
        line("### Verdict: **\(r.verdict)**")
        line(r.verdictReason)
        line("")
        line("### Verdict flips — exact McNemar test")
        line("b (baseline accepted, candidate rejected) = \(r.mcNemar.b)   c (baseline rejected, candidate accepted) = \(r.mcNemar.c)   net = \(r.mcNemar.net)   n paired = \(r.mcNemar.n)")
        if r.mcNemar.b + r.mcNemar.c == 0 {
            line("no window changed verdict.")
        } else {
            line("p = \(fmt(r.mcNemar.p, 4)) — " + ((r.mcNemar.p ?? 1) <= 0.05 ? "distinguishable from chance at α = 0.05." : "**p > 0.05: not distinguishable from chance on this corpus.**"))
            if let m = r.mcNemar.minorityNeededForSignificance {
                line("at the current \(r.mcNemar.b + r.mcNemar.c) discordant window(s), the minority side would need to reach \(m) (out of \(r.mcNemar.b + r.mcNemar.c)) to be significant at α = 0.05.")
            }
        }
        line("")
        line("### Paired deltas (candidate − baseline, over windows where the measure exists in both arms)")
        line("| metric | n | median Δ | sign test (+/−/ties) | p |")
        line("|---|---:|---:|---:|---:|")
        for d in r.pairedDeltas {
            line("| \(d.metric) | \(d.n) | \(fmt(d.medianDelta, 4)) | \(d.positive)/\(d.negative)/\(d.ties) | \(fmt(d.p, 4)) |")
        }
        line("")
        line("### Regressions")
        line("Rule: _\(r.regressions.rule)_ (gError threshold \(fmt(r.regressions.gErrorAbsoluteThreshold, 3)) absolute, rmsPx threshold \(fmt(r.regressions.rmsPxThreshold, 1)) px; any spread widening counts).")
        if r.regressions.entries.isEmpty { line("none.") }
        else { for e in r.regressions.entries { line("- **\(e.kind)** — \(e.detail)") } }
        line("")
        line("### Windows present on one side only")
        if r.missing.inBaselineOnly.isEmpty && r.missing.inCandidateOnly.isEmpty { line("none — both runs cover the same windows.") }
        else {
            if !r.missing.inBaselineOnly.isEmpty {
                line("baseline only (\(r.missing.inBaselineOnly.count)): " + r.missing.inBaselineOnly.map(\.windowID).joined(separator: ", "))
            }
            if !r.missing.inCandidateOnly.isEmpty {
                line("candidate only (\(r.missing.inCandidateOnly.count)): " + r.missing.inCandidateOnly.map(\.windowID).joined(separator: ", "))
            }
        }
        return out
    }
}
