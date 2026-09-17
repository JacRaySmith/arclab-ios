import SwiftUI

/// **Review** — the saved sessions and what they add up to.
///
/// Deliberately thin: `HistoryView` is the screen (spot picker, pooled numbers, charts, session by
/// session, and its own "Diagnosis and plan" row), and this only gives it a tab of its own so that
/// leaving an analysis to look at last week no longer means unwinding a navigation stack
/// (`docs/IMPROVEMENTS-2026-09-16.md` §1.1 item 3 — 30 cancelled analyses in two days).
///
/// The toolbar link is the one addition: with nothing saved yet `HistoryView` shows only its empty
/// state, so the way through to the diagnosis would otherwise disappear exactly when a shooter is
/// most likely to go looking for it.
struct ReviewView: View {
    var store: SessionStore
    var doctor: ShotDoctorModel

    var body: some View {
        HistoryView(store: store, doctor: doctor)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        DiagnosisView(doctor: doctor)
                    } label: {
                        Label("Diagnosis and plan", systemImage: "list.bullet.clipboard")
                    }
                }
            }
            .onAppear {
                ActivityLog.shared.event("screen", ["name": "review", "sessions": store.sessions.count])
            }
    }
}
