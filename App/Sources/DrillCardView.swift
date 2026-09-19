import ShotGeometry
import SwiftUI

/// One drill, rendered the same way everywhere it appears.
///
/// Added 2026-09-19 after "I went to the drills and some of the descriptions are hard to follow."
/// Three screens showed a drill three different ways, each of them a paragraph with a statistic in
/// the middle of it. Now there is one shape — Setup, Do this, What the app watches, Done when, Why
/// this works — and the precise wording sits behind a disclosure instead of on the court.
///
/// `DrillCard` is built in `ShotGeometry`, so the order of the questions is fixed in the model and
/// not in each view's layout.
struct DrillCardView: View {
    let card: DrillCard
    /// Everything but `Do this` collapses when this is false — the block card's mode, where the
    /// screen is read from five metres away with a ball in your hands.
    var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Setup", card.setup, icon: "mappin.and.ellipse")
            row("Do this", card.doThis, icon: "figure.basketball", emphasis: true)
            row("A shot counts when", card.counts, icon: "checkmark.circle")
            row("Order", card.order, icon: "list.number")
            row("What the app watches", card.watches, icon: "eye")
            row("Done when", card.doneWhen, icon: "flag.checkered")
            row("Why this works", card.why, icon: "lightbulb")
            if let detail = card.detail, !detail.isEmpty {
                DisclosureGroup("The exact version") {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ title: String, _ body: String, icon: String, emphasis: Bool = false) -> some View {
        if !body.isEmpty, expanded || emphasis {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(body)
                    .font(emphasis ? .body.weight(.semibold) : .footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The one line a shooter reads with a ball in their hands, at the size that can be read from the
/// tripod. Everything else about the drill is a tap away.
struct DrillDoThisView: View {
    let card: DrillCard
    let shots: Int
    let spot: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.doThis)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(shots) shots · \(spot)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - How a gate is introduced

/// A gate's `description` is written as a clause, so the screen that shows it supplies the verb in
/// front. The one thing this must never do is call a number that is only *watched* a pass mark:
/// `reportOnly` gates get their own opening, because "done when" would be a claim the evidence does
/// not support.
enum GateWords {
    static func sentence(_ check: PassCheck) -> String {
        if case .reportOnly = check.target {
            return "Shown, never scored: \(check.description). It needs \(check.minimumN) counted shots before it is worth showing at all."
        }
        return "Done when \(check.description), over at least \(check.minimumN) counted shots — under that the app says it cannot tell yet."
    }
}

// MARK: - Names, never identifiers

// `ShotSpot` and `DoctorSpot` already spell their raw values the way a person says them ("Free
// throws", "Mid-range"), but reading `.rawValue` in a `Text` is how an identifier eventually leaks
// into the interface (`docs/IMPROVEMENTS-2026-09-16.md` §4 rule 2, item 74). These give the views a
// name to ask for instead.

extension ShotSpot {
    var display: String { rawValue }
    /// Mid-sentence: "…at free throws".
    var displayLower: String { rawValue.lowercased() }
}

extension DoctorSpot {
    var display: String { rawValue }
    var displayLower: String { rawValue.lowercased() }
}

extension FootSide {
    /// "Left" / "Right" — the word, not the case name it happens to share.
    var display: String { rawValue.capitalized }
}

extension Array where Element == DoctorSpot {
    /// "Free throws, Elbow" — or the sentence that says there is no ladder.
    var spotList: String { map(\.display).joined(separator: ", ") }
}
