import SwiftUI

/// **Learn** — the curriculum, plus the way to film it.
///
/// Thin on purpose: `LearnView` is the screen. It was opened once in two days because it was the
/// fifth row of six on the home screen (`docs/IMPROVEMENTS-2026-09-16.md` §0), so the change here is
/// that it has a tab rather than a row. "How to film" rides along with it because the filming
/// protocol is the first thing the curriculum depends on — a clip filmed from the wrong place cannot
/// be measured, however well the drill was shot.
struct LearnHubView: View {
    var practice: PracticeStore
    var doctor: ShotDoctorModel
    var store: SessionStore

    var body: some View {
        LearnView(practice: practice, doctor: doctor, store: store)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        FilmingGuideView()
                    } label: {
                        Label("How to film", systemImage: "video")
                    }
                }
            }
            .onAppear { ActivityLog.shared.event("screen", ["name": "learn"]) }
    }
}
