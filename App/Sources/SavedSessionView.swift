import ShotGeometry
import SwiftUI

// ================================================================================================
// MARK: - One saved session, and getting rid of one
// ================================================================================================
//
// The 1.3.1 report was "I should be able to delete and view specific sessions". Both were already
// possible and neither was findable: the only list of sessions lived at the bottom of the Progress
// screen behind a spot picker, and tapping a row opened the *edit* form — a spot picker, a note
// field and a delete button — never the session itself.
//
// So: a "Sessions" row at the top of Review opens `SessionsListView` (every session, newest first,
// no spot filter), and a row there opens `SavedSessionView` — that session's own page, built out of
// the same pieces the live session screen uses (`SessionSummaryTiles`, `SessionRimMapView`,
// `ShotStripChartView`, `FormModelView`, `EditSessionView`).
//
// Deleting says what else it takes with it *before* it is confirmed (`SessionDeletionImpact`), and
// nothing is removed silently: the recording and the 3-D body files are named with their sizes, and
// where they are kept the reason is printed.

// MARK: - What deleting one session takes with it

/// Everything a delete would touch, worked out before the shooter is asked.
///
/// Read-only over the other stores: the practice log is decoded straight off its own file rather
/// than through `PracticeStore`, so this screen does not need the practice store passed into the
/// Review tab. (If `PracticeStore` ever grows a `blocks(forSession:)` accessor, this is the one
/// place to swap it in.)
struct SessionDeletionImpact: Sendable {
    /// Practice blocks whose numbers came from this session. They keep their instruction and their
    /// shot count; what they lose is the saved session those numbers were read from.
    var practiceBlocks: [String] = []
    /// Set when the one plan being scored used this session as its baseline.
    var planBaselineNote: String?
    /// Set when the plan used this session as its follow-up or retention session.
    var planFollowUpNote: String?
    /// The recording on disk, when this session still has one.
    var recording: RecordedClip?
    /// Why the recording will be kept even though it exists. Nil when it can go.
    var recordingKeptReason: String?
    /// The `Documents/ArcLab/body/<key>` folders holding this session's 3-D body exports.
    var bodyDirectories: [URL] = []
    var bodyFileCount = 0
    var bodyBytes = 0
    /// Why the body exports will be kept. Nil when they can go.
    var bodyKeptReason: String?

    var recordingBytes: Int {
        guard let recording else { return 0 }
        return (try? recording.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    var canDeleteRecording: Bool { recording != nil && recordingKeptReason == nil }
    var canDeleteBodyFiles: Bool { bodyFileCount > 0 && bodyKeptReason == nil }

    /// The lines the page and the confirmation dialog both show. Every one of them is a fact about
    /// this phone's own files or this shooter's own saved work — never a guess.
    var lines: [String] {
        var out: [String] = []
        if practiceBlocks.isEmpty {
            out.append("No practice block was scored from this session.")
        } else {
            out.append("\(practiceBlocks.count) practice block\(practiceBlocks.count == 1 ? "" : "s") "
                       + "\(practiceBlocks.count == 1 ? "was" : "were") scored from this session and "
                       + "\(practiceBlocks.count == 1 ? "becomes" : "become") unscored: "
                       + practiceBlocks.joined(separator: ", ") + ".")
        }
        if let planBaselineNote { out.append(planBaselineNote) }
        if let planFollowUpNote { out.append(planFollowUpNote) }
        if let recording {
            if let recordingKeptReason {
                out.append("The recording \(recording.movieFileName) is kept: " + recordingKeptReason)
            } else {
                out.append(String(format: "The recording %@ (%.0f MB) is deleted with it.",
                                  recording.movieFileName, Double(recordingBytes) / 1e6))
            }
        } else {
            out.append("There is no recording on this phone for this session — it was imported from Photos, or the file has already been removed.")
        }
        if bodyFileCount == 0 {
            out.append("This session wrote no 3-D body files.")
        } else if let bodyKeptReason {
            out.append("Its \(bodyFileCount) 3-D body file\(bodyFileCount == 1 ? "" : "s") are kept: " + bodyKeptReason)
        } else {
            out.append(String(format: "Its %d 3-D body file%@ (%.0f MB) are deleted with it, so those shots leave \"Your shots in 3-D\".",
                              bodyFileCount, bodyFileCount == 1 ? "" : "s", Double(bodyBytes) / 1e6))
        }
        out.append("The numbers themselves are gone for good: the pooled statistics at \(spotName) are recomputed without this session, and it cannot be undone.")
        return out
    }

    fileprivate var spotName = ""

    // MARK: Building it

    @MainActor
    static func build(for session: SavedSession, store: SessionStore) -> SessionDeletionImpact {
        var impact = SessionDeletionImpact()
        impact.spotName = session.spot.rawValue

        // --- practice blocks that were scored from it
        for practice in practiceSessions() {
            for block in practice.blocks where block.savedSessionID == session.id {
                impact.practiceBlocks.append("\(block.role.rawValue) at \(block.spot.rawValue), "
                                             + practice.date.formatted(date: .abbreviated, time: .omitted))
            }
        }

        // --- the one plan being scored
        if let plan = store.activePlan {
            let name = HypothesisID(rawValue: plan.hypothesis).map { DoctorNames.hypothesis($0) } ?? plan.hypothesis
            if plan.baselineSessionID == session.id {
                impact.planBaselineNote = "The plan being scored (\(name) at \(plan.spot.rawValue)) read its baseline from this session. "
                    + "Deleting it leaves the plan with no baseline, so it cannot be scored until a new session is saved at \(plan.spot.rawValue). The plan itself is not deleted."
            } else if plan.followUpSessionID == session.id || plan.retentionSessionID == session.id {
                impact.planFollowUpNote = "The plan being scored (\(name) at \(plan.spot.rawValue)) used this session as its "
                    + (plan.followUpSessionID == session.id ? "follow-up" : "retention")
                    + " session; the check goes back to waiting for one."
            }
        }

        // --- the recording
        if let clip = RecordedClip.loadAll().first(where: { $0.movieFileName == session.clipName }) {
            impact.recording = clip
            let others = store.sessions.filter { $0.id != session.id && $0.clipName == session.clipName }
            if !others.isEmpty {
                impact.recordingKeptReason = "\(others.count) other saved session\(others.count == 1 ? "" : "s") "
                    + "\(others.count == 1 ? "was" : "were") analysed from the same recording."
            } else if practiceSessions().contains(where: { p in
                p.blocks.contains { $0.savedSessionID != session.id && $0.recordingFile == session.clipName }
            }) {
                impact.recordingKeptReason = "a practice block that is not this session still points at it."
            }
        }

        // --- the 3-D body exports
        //
        // `SessionModel` keys an export by the *clip's* stem, and the form-clip model prefixes it
        // with "formclip-". A session imported twice therefore shares one folder, which is exactly
        // the case the keep-reason below covers.
        let stem = (session.clipName as NSString).deletingPathExtension
        let keys = session.isFormClip ? ["formclip-" + stem] : [stem]
        var directories: [URL] = []
        var files = 0
        var bytes = 0
        for key in keys {
            let dir = BodyShotWriter.url(sessionKey: key, shotID: 0).deletingLastPathComponent()
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let json = contents.filter { $0.pathExtension == "json" }
            guard !json.isEmpty else { continue }
            directories.append(dir)
            files += json.count
            bytes += json.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        impact.bodyDirectories = directories
        impact.bodyFileCount = files
        impact.bodyBytes = bytes
        if files > 0 {
            let others = store.sessions.filter { $0.id != session.id && $0.clipName == session.clipName }
            if !others.isEmpty {
                impact.bodyKeptReason = "\(others.count) other saved session\(others.count == 1 ? "" : "s") came from the same recording and the exports are filed under the recording, not the session."
            }
        }
        return impact
    }

    /// The practice log, read straight off disk. Not `PracticeStore`: the Review tab is not given
    /// one, and this only ever reads.
    @MainActor
    private static func practiceSessions() -> [PracticeSession] {
        guard let data = try? Data(contentsOf: PracticeStore.fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PracticeSession].self, from: data)) ?? []
    }
}

// MARK: - The list of sessions

/// Every saved session, newest first, across every spot. The screen the report asked for: a way in
/// that does not go through a spot picker and does not pretend a session is a form to be edited.
struct SessionsListView: View {
    @Bindable var store: SessionStore
    @State private var pendingDelete: SavedSession?

    private var sessions: [SavedSession] { store.sessions.sorted { $0.date > $1.date } }

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView("No saved sessions",
                                       systemImage: "tray",
                                       description: Text("A session appears here once it has been analysed and saved with the spot it was shot from."))
            } else {
                Section {
                    ForEach(sessions) { s in
                        NavigationLink { SavedSessionView(store: store, sessionID: s.id) } label: { row(s) }
                    }
                    .onDelete { offsets in
                        // Swipe still works, and still has to say what it takes with it.
                        if let i = offsets.first, sessions.indices.contains(i) { pendingDelete = sessions[i] }
                    }
                } footer: {
                    Text("Tap a session to open it. Swipe a row to delete it — either way you are shown what else the delete affects first. Sessions live only on this phone, in the app's own folder.")
                }
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ActivityLog.shared.event("screen", ["name": "sessions.list", "sessions": store.sessions.count]) }
        .deleteSessionConfirmation(store: store, session: $pendingDelete, onDeleted: nil)
    }

    private func row(_ s: SavedSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(s.date, format: .dateTime.day().month().year().hour().minute()).font(.subheadline.bold())
                Spacer()
                Text(s.spot.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(s.shots.count) shot\(s.shots.count == 1 ? "" : "s") counted · \(s.accepted) accepted\(s.isFormClip ? " · form clip" : "")")
                .font(.caption).foregroundStyle(.secondary)
            Text(s.clipName).font(.caption2).foregroundStyle(.tertiary)
            if !s.note.isEmpty { Text(s.note).font(.caption) }
        }
    }
}

// MARK: - One session's own page

/// The saved session itself: its tiles, its rim map, its shot strip, its shots, its 3-D form — and
/// one explicit way to delete it that says what else goes.
struct SavedSessionView: View {
    @Bindable var store: SessionStore
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: SavedSession?

    private var session: SavedSession? { store.sessions.first { $0.id == sessionID } }

    var body: some View {
        Group {
            if let s = session { content(s) } else {
                ContentUnavailableView("This session no longer exists", systemImage: "tray",
                                       description: Text("It was deleted from this phone."))
            }
        }
        .navigationTitle(session.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ActivityLog.shared.event("screen", ["name": "session.saved", "spot": session?.spot.rawValue,
                                                "shots": session?.shots.count, "accepted": session?.accepted])
        }
        .deleteSessionConfirmation(store: store, session: $pendingDelete, onDeleted: { dismiss() })
    }

    @ViewBuilder private func content(_ s: SavedSession) -> some View {
        let summary = s.summary
        List {
            Section {
                LabeledContent("Shot from", value: s.spot.rawValue)
                LabeledContent("Saved", value: s.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Shots", value: "\(s.accepted) accepted of \(s.shots.count) counted")
                LabeledContent("Windows", value: "\(s.windows) tried, \(s.failed) failed to measure")
                LabeledContent("Clip", value: s.clipName)
                LabeledContent("Lens", value: String(format: "%.1f° horizontal", s.hfovDegrees))
                // Every height and distance in this session was read along one direction. Which one
                // is part of the record, not a detail: a session solved from a tilted trace reads
                // low at range and nothing else on this screen would say so.
                if !s.isFormClip {
                    Text(s.rimUpProvenance ?? "This session was saved before ArcLab recorded which way the rim was solved, so its provenance is unknown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if s.isFormClip {
                    Text("A form clip: no rim was in frame, so release speed, release angle, entry angle, depth at the rim and make-or-miss are not measured in this session and it never joins the shot-session pool.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !s.note.isEmpty { Text(s.note).font(.footnote) }
            } header: {
                Text("This session")
            } footer: {
                Text(summary.provenance)
            }

            Section("The three numbers") {
                SessionSummaryTiles(summary: summary)
            }

            if !s.isFormClip {
                Section {
                    SessionRimMapView(rows: summary.rows, ballDiameter: BallSize.size7.diameter)
                } header: {
                    Text("Rim map")
                }
            }

            Section {
                stripCharts(s, summary)
            } header: {
                Text("Shot by shot")
            }

            Section {
                NavigationLink {
                    FormModelView(title: "3-D form", model: s.formModel, shot: nil, source: "session.saved",
                                  earlierSessions: store.sessionsWithForms(spot: s.spot, excluding: s.id))
                } label: {
                    Label("The 3-D form of this session", systemImage: "figure.basketball")
                }
                Text(s.formModel.isAvailable
                     ? "Built from the \(s.formModel.shots) accepted shot\(s.formModel.shots == 1 ? "" : "s") in this session that carry a form."
                     : (s.formModel.unavailableReason ?? "this session has no 3-D form"))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Form")
            }

            Section {
                ForEach(s.shots) { shot in shotRow(shot) }
            } header: {
                Text("Every shot (\(s.shots.count))")
            } footer: {
                Text("The clip itself is not kept with a saved session, so these rows are the measurements, not a way back to the video. Where a shot was left out of the statistics, the block rule's own reason is underneath it.")
            }

            Section {
                NavigationLink { EditSessionView(store: store, sessionID: s.id) } label: {
                    Label("Change the spot or the note", systemImage: "pencil")
                }
                Button(role: .destructive) { pendingDelete = s } label: {
                    Label("Delete this session", systemImage: "trash")
                }
            } header: {
                Text("Manage")
            }
        }
    }

    @ViewBuilder private func stripCharts(_ s: SavedSession, _ summary: BlockSummary) -> some View {
        let rowsByID = Dictionary(uniqueKeysWithValues: summary.rows.map { ($0.id, $0) })
        let points = { (key: @escaping (BlockRow) -> Double?) -> [ShotStripChartView.Point] in
            s.shots.map { shot in
                let row = rowsByID[shot.id]
                return ShotStripChartView.Point(id: shot.id, value: row.flatMap(key),
                                                accepted: row?.verdict.isAccepted ?? false)
            }
        }
        ShotStripChartView(title: "Release speed", unit: "m/s", decimals: 2,
                           points: points { $0.releaseSpeed }, stat: summary.releaseSpeed,
                           unavailableReason: summary.unavailableReason(for: summary.releaseSpeed, geometry: true))
        ShotStripChartView(title: "Release angle", unit: "°", decimals: 1,
                           points: points { $0.releaseAngleDegrees }, stat: summary.releaseAngleDegrees,
                           unavailableReason: summary.unavailableReason(for: summary.releaseAngleDegrees, geometry: true))
        ShotStripChartView(title: "Entry angle", unit: "°", decimals: 1,
                           points: points { $0.entryAngleDegrees }, stat: summary.entryAngleDegrees,
                           unavailableReason: summary.unavailableReason(for: summary.entryAngleDegrees, geometry: true))
        Text("Filled marks are shots the block rule accepted; hollow marks are measured shots it left out. The dashed line is this session's own mean and the band is ±1 SD of the accepted shots. There is no target band.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func shotRow(_ shot: SavedShot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Shot \(shot.id)").font(.subheadline.bold())
                Spacer()
                Text(shot.verdict).font(.caption)
                    .foregroundStyle(shot.verdict == "accept" ? Color.green : .secondary)
                Text(shot.outcome).font(.caption).foregroundStyle(.secondary)
            }
            Text(numbers(shot)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if shot.verdict != "accept", let why = shot.verdictReason {
                Text(why).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Only the numbers this shot actually has. A measure the analyzer refused is left out of the
    /// line rather than printed as a dash that could be read as a zero.
    private func numbers(_ shot: SavedShot) -> String {
        var parts: [String] = []
        if let v = shot.releaseSpeed { parts.append(String(format: "speed %.2f m/s", v)) }
        if let v = shot.releaseAngleDegrees { parts.append(String(format: "release %.1f°", v)) }
        if let v = shot.entryAngleDegrees { parts.append(String(format: "entry %.1f°", v)) }
        if let v = shot.depthPastFrontRim { parts.append(String(format: "depth %.0f cm", v * 100)) }
        parts.append(String(format: "g %.2f", shot.gFit))
        return parts.joined(separator: " · ")
    }
}

// MARK: - The confirmation, shared by the list and the page

private struct DeleteSessionConfirmation: ViewModifier {
    @Bindable var store: SessionStore
    @Binding var session: SavedSession?
    var onDeleted: (() -> Void)?

    func body(content: Content) -> some View {
        let impact = session.map { SessionDeletionImpact.build(for: $0, store: store) }
        return content
            .confirmationDialog(session.map { "Delete the \($0.spot.rawValue) session of \($0.date.formatted(date: .abbreviated, time: .shortened))?" } ?? "Delete this session?",
                                isPresented: Binding(get: { session != nil }, set: { if !$0 { session = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let s = session, let impact else { return }
                    store.delete(s.id, impact: impact)
                    session = nil
                    onDeleted?()
                }
                Button("Keep it", role: .cancel) { session = nil }
            } message: {
                if let session, let impact {
                    Text(([" \(session.accepted) accepted of \(session.shots.count) counted shots go with it."]
                          + impact.lines).joined(separator: "\n\n"))
                }
            }
    }
}

extension View {
    /// The one delete dialog. Everywhere a session can be deleted uses this, so the swipe and the
    /// button say exactly the same thing.
    func deleteSessionConfirmation(store: SessionStore, session: Binding<SavedSession?>,
                                   onDeleted: (() -> Void)?) -> some View {
        modifier(DeleteSessionConfirmation(store: store, session: session, onDeleted: onDeleted))
    }
}
