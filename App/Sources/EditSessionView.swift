import SwiftUI

/// Edit a saved session: the spot it was shot from, its note, or delete it. The spot is the cell every
/// statistic pools in, so getting it right after the fact must be one tap, not a re-analysis.
struct EditSessionView: View {
    @Bindable var store: SessionStore
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var spot: ShotSpot = .freeThrow
    @State private var note = ""
    @State private var confirmDelete = false

    private var session: SavedSession? { store.sessions.first { $0.id == sessionID } }

    var body: some View {
        Form {
            if let s = session {
                Section("Session") {
                    LabeledContent("Saved", value: s.date.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Clip", value: s.clipName)
                    LabeledContent("Shots", value: "\(s.accepted) accepted of \(s.shots.count) measured")
                    LabeledContent("Lens", value: String(format: "%.1f°", s.hfovDegrees))
                }
                Section {
                    Picker("Shot from", selection: $spot) {
                        ForEach(ShotSpot.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Note", text: $note)
                    Button("Save changes") {
                        var edited = s
                        edited.spot = spot
                        edited.note = note
                        store.update(edited)
                        ActivityLog.shared.event("session.edited", ["from": s.spot.rawValue, "to": spot.rawValue, "clip": s.clipName])
                        dismiss()
                    }
                    .disabled(spot == s.spot && note == s.note)
                } header: {
                    Text("Edit")
                } footer: {
                    Text("Moving a session to another spot moves every one of its shots with it; nothing is re-measured. A duplicate save of the same clip should be deleted, not moved.")
                }
                Section {
                    Button("Delete this session", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("Delete this session and its \(s.shots.count) shots?", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) { store.delete(s.id); dismiss() }
                        }
                }
            } else {
                Text("This session no longer exists.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Edit session")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let s = session { spot = s.spot; note = s.note }
            ActivityLog.shared.event("screen", ["name": "session.edit"])
        }
    }
}
