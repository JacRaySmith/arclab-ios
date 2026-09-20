import SwiftUI

/// The way in to the vertical jump test, as one row that can be dropped into any `List` inside a
/// `NavigationStack`.
///
/// Self-contained on purpose: it owns a `JumpStore` if nobody hands it one, so it can be added to a
/// screen without that screen having to learn about jump tests first. When a screen already holds a
/// store (so the same object backs several places), pass it in.
struct JumpTestEntryCard: View {
    /// Pass the screen's own store when there is one; leave it out and the card keeps its own.
    var store: JumpStore? = nil
    @State private var owned = JumpStore()

    private var active: JumpStore { store ?? owned }

    var body: some View {
        NavigationLink {
            JumpTestView(store: active)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "figure.jumprope")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    Text("Vertical jump test").font(.headline)
                    Spacer()
                }
                if let best = active.best?.bestMetres, let latest = active.latest {
                    Text(String(format: "Your best: %.1f cm", 100 * best))
                        .font(.subheadline.monospacedDigit())
                    Text("Last tested \(latest.date, format: .dateTime.day().month()) — \(latest.line)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Three jumps, filmed side-on. The app times how long you are in the air and turns that into a height.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
