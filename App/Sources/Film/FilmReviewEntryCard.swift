import SwiftUI

/// The way in to game film review, as one row that can be dropped into any `List` inside a
/// `NavigationStack`.
///
/// Self-contained: it owns a `FilmStore` when nobody hands it one, so a screen can show it without
/// first learning about film. Pass a store in when the screen already holds one.
struct FilmReviewEntryCard: View {
    var store: FilmStore? = nil
    @State private var owned = FilmStore()

    private var active: FilmStore { store ?? owned }

    var body: some View {
        NavigationLink {
            FilmHomeView(store: active)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    Text("Game film").font(.headline)
                    Spacer()
                }
                if active.films.isEmpty {
                    Text("Bring in a clip of a game, mark your possessions as you watch, and read your own decisions back afterwards.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(active.films.count) clip\(active.films.count == 1 ? "" : "s") · \(active.totalMyTags) of your possessions tagged")
                        .font(.subheadline)
                    Text("You do the tagging. The app keeps it and reads it back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
