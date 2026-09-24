// Turns a `ShotBench run`'s per-window results plus `docs/footage-2026-09-13/window_labels.json`
// into recall and precision, overall and per clip — the missing denominator `docs/PIPELINE.md`
// flagged: acceptance rate alone cannot say whether a refused window was a real shot the geometry
// got wrong, or correctly-refused debris.
//
//   recall    = (labelled `shot` AND accepted) / (labelled `shot`)         — a thrown-away shot is the real failure
//   precision = (accepted AND labelled `shot`) / (accepted AND labelled `shot` or `notShot`)
//
// `unsure`-labelled windows, and windows this cache has no label for at all, are excluded from
// both numerator and denominator of both fractions — not counted as either outcome — and their
// counts are always reported so the exclusion is never invisible (see `WindowLabelGroupSummary`).
//
// A variant that *skips* a window (never evaluates it — e.g. `knownDistance` on an elbow window)
// counts the same as a refusal here: the app produced no measurement for it either way, and that is
// exactly what recall is asking about.
import Foundation

public struct RefusalByLabel: Codable, Sendable {
    public var shot: [RefusalBucket]
    public var notShot: [RefusalBucket]
}

public struct WindowLabelGroupSummary: Codable, Sendable {
    public var label: String   // "overall" or a clip name

    public var shotCount: Int       // windows labelled `shot` in this group
    public var shotAccepted: Int    // …of those, accepted
    public var recall: Double?      // nil iff shotCount == 0

    public var notShotCount: Int    // windows labelled `notShot` in this group

    public var acceptedCount: Int             // all accepted windows in this group, any label (or none)
    public var acceptedWithDefiniteLabel: Int  // accepted AND labelled shot/notShot — precision's denominator
    public var acceptedShot: Int               // accepted AND labelled shot — precision's numerator
    public var precision: Double?              // nil iff acceptedWithDefiniteLabel == 0

    public var unsureCount: Int     // labelled `unsure` in this group — always reported, excluded from both fractions
    public var noLabelCount: Int    // windows this cache has no entry for at all — also excluded, reported separately from `unsure`

    public var refusalByLabel: RefusalByLabel  // refusal-reason histogram, restricted to shot-labelled / notShot-labelled non-accepted windows
}

public struct WindowLabelScoring: Codable, Sendable {
    public var sourcePath: String
    /// "scored" | "missing" | "unreadable" — mirrors `LabelScoringSummary.status` (release-time labels).
    public var status: String
    public var detail: String?
    public var overall: WindowLabelGroupSummary?
    public var perClip: [WindowLabelGroupSummary]
}

/// One window's outcome under this variant, independent of whether it came from `scores` (evaluated)
/// or `skipped` (never evaluated) — both are "not accepted" for recall's purposes.
struct LabeledOutcome {
    var windowID: String
    var clip: String
    var accepted: Bool
    /// The refusal-reason bucket (`BenchRunner.category`, or a "skipped by variant" bucket for a
    /// window the variant never evaluated) — nil only when accepted.
    var refusalCategory: String?
}

enum WindowLabelScorer {
    static func outcomes(scores: [WindowScore], skipped: [SkippedWindow]) -> [LabeledOutcome] {
        var out: [LabeledOutcome] = []
        out.reserveCapacity(scores.count + skipped.count)
        for s in scores {
            out.append(LabeledOutcome(windowID: s.windowID, clip: s.clip, accepted: s.accepted,
                                      refusalCategory: s.accepted ? nil : BenchRunner.category(s.refusalReason ?? "unknown")))
        }
        for sk in skipped {
            out.append(LabeledOutcome(windowID: sk.windowID, clip: sk.clip, accepted: false,
                                      refusalCategory: "skipped by variant: \(sk.reason)"))
        }
        return out
    }

    static func summarize(_ outcomes: [LabeledOutcome], label: String, labels: [String: WindowLabelEntry]) -> WindowLabelGroupSummary {
        func labelOf(_ o: LabeledOutcome) -> ShotLabelValue? { labels[o.windowID]?.label }

        let shot = outcomes.filter { labelOf($0) == .shot }
        let notShot = outcomes.filter { labelOf($0) == .notShot }
        let unsure = outcomes.filter { labelOf($0) == .unsure }
        let noLabel = outcomes.filter { labels[$0.windowID] == nil }

        let shotAccepted = shot.filter(\.accepted).count
        let recall = shot.isEmpty ? nil : Double(shotAccepted) / Double(shot.count)

        let accepted = outcomes.filter(\.accepted)
        let acceptedDefinite = accepted.filter { let l = labelOf($0); return l == .shot || l == .notShot }
        let acceptedShot = acceptedDefinite.filter { labelOf($0) == .shot }.count
        let precision = acceptedDefinite.isEmpty ? nil : Double(acceptedShot) / Double(acceptedDefinite.count)

        func histogram(_ group: [LabeledOutcome]) -> [RefusalBucket] {
            var h: [String: Int] = [:]
            for o in group where !o.accepted { h[o.refusalCategory ?? "unknown", default: 0] += 1 }
            return h.keys.sorted().map { RefusalBucket(reason: $0, count: h[$0]!) }
        }

        return WindowLabelGroupSummary(
            label: label,
            shotCount: shot.count, shotAccepted: shotAccepted, recall: recall,
            notShotCount: notShot.count,
            acceptedCount: accepted.count, acceptedWithDefiniteLabel: acceptedDefinite.count, acceptedShot: acceptedShot, precision: precision,
            unsureCount: unsure.count, noLabelCount: noLabel.count,
            refusalByLabel: RefusalByLabel(shot: histogram(shot), notShot: histogram(notShot)))
    }

    /// Entry point: builds the overall + per-clip summaries for one scorecard's windows, or a
    /// "missing"/"unreadable" result with no summaries when the label file cannot be scored.
    static func run(scores: [WindowScore], skipped: [SkippedWindow], labelsPath: String) -> WindowLabelScoring {
        let result = WindowLabelLoader.load(path: labelsPath)
        guard let loaded = result.labels else {
            return WindowLabelScoring(sourcePath: result.sourcePath, status: result.status, detail: result.detail, overall: nil, perClip: [])
        }
        let outcomes = outcomes(scores: scores, skipped: skipped)
        let overall = summarize(outcomes, label: "overall", labels: loaded.byWindowID)
        var byClip: [String: [LabeledOutcome]] = [:]
        for o in outcomes { byClip[o.clip, default: []].append(o) }
        let perClip = byClip.keys.sorted().map { clip in summarize(byClip[clip]!, label: clip, labels: loaded.byWindowID) }
        return WindowLabelScoring(sourcePath: result.sourcePath, status: result.status, detail: result.detail, overall: overall, perClip: perClip)
    }
}
