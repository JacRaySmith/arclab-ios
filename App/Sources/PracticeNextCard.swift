import ShotGeometry
import SwiftUI

/// The one thing to do next, in the same words everywhere it appears (Shoot, practice home, the
/// block card, the session summary).
///
/// The day is a sequence, not one block: after a block is scored the next-block engine
/// (`NextBlock.decide`) proposes the block that follows from what that block actually measured, and
/// this view is how that proposal reads. There is never an empty state — when the day's cap is
/// reached the card says so and names tomorrow's first block instead.
///
/// Every proposal carries two sentences that are not decoration: *why* (which number, from how many
/// shots, and the grade of the rule behind it) and *what it buys* (what the app will be able to tell
/// once the block is in). Both are written by the engine, so nothing on this screen invents a number.
struct PracticeNextCard: View {
    let action: PracticeNextAction
    /// True on the Shoot tab, where the card sits above the big record button and the block's own
    /// name is already on that button.
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch action {
            case .record(let block, let number, let proposal):
                if showsTitle {
                    Text("Next — block \(number): \(PracticeNames.role(block.role)) · \(block.intendedShots) at \(block.spot.rawValue)")
                        .font(.subheadline.bold())
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let proposal {
                    Text(proposal.reason)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(proposal.whatItBuys)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(block.instruction)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let cue = block.cue {
                    Label(cue, systemImage: "quote.opening")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .dayDone(let reason, let tomorrow):
                Text("Day done")
                    .font(.subheadline.bold())
                Text(reason)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tomorrow, first block: \(PracticeNames.role(tomorrow.role)) · \(tomorrow.shots) at \(tomorrow.spot.rawValue)")
                    .font(.footnote.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(tomorrow.instruction)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tomorrow.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tomorrow.whatItBuys)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
