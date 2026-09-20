import ShotGeometry
import SwiftUI

/// Saved sessions and what they add up to, one spot at a time.
///
/// The point of saving is the 30-shot floor: one session rarely produces 30 accepted shots, so the
/// finding a shooter came for only ever appears here, where sessions from the same spot are pooled.
/// Spots are never mixed — a free throw and a three are different populations.
struct HistoryView: View {
    @Bindable var store: SessionStore
    @Bindable var doctor: ShotDoctorModel
    @State private var spot: ShotSpot = .freeThrow

    var body: some View {
        List {
            if let err = store.loadError { Section("Error") { Text(err).foregroundStyle(.red) } }
            // Game film (1.4): the one way in, here because film review is about looking back at what
            // happened, which is what this screen is for. Self-contained — it brings its own store.
            Section {
                FilmReviewEntryCard()
            } footer: {
                Text("You tag your own possessions while you watch. The app keeps them and reads them back; it does not judge a decision for you.")
                    .font(.caption)
            }
            if store.sessions.isEmpty {
                Section {
                    Text("No saved sessions yet. After a session is analysed, save it from the Session screen with the spot it was shot from. Sessions from the same spot pool together here until the 30 accepted shots a finding needs are in.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                spotPicker
                doctorSection
                progressSection
                ProgressChartsView(store: store, spot: spot)
                coachingSection
                sessionsSection
            }
        }
        .onAppear { ActivityLog.shared.event("screen", ["name": "progress", "sessions": store.sessions.count]) }
        .navigationTitle("Progress")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Open on the spot with the most saved shots, so the first screen is the useful one.
            if let best = ShotSpot.allCases.max(by: { store.sessions(at: $0).count < store.sessions(at: $1).count }),
               !store.sessions(at: best).isEmpty {
                spot = best
            }
        }
    }

    /// The way through to the shot doctor: the per-spot findings the engine makes without being
    /// asked a question, and the one fix being scored.
    private var doctorSection: some View {
        Section {
            NavigationLink {
                DiagnosisView(doctor: doctor)
            } label: {
                Label("Diagnosis and plan", systemImage: "list.bullet.clipboard")
            }
            if let plan = store.activePlan, let id = HypothesisID(rawValue: plan.hypothesis) {
                Text("Scoring one fix: \(DoctorNames.hypothesis(id)) at \(plan.spot.rawValue), chosen \(plan.chosenDate, format: .dateTime.day().month().year()).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No plan is being scored. The diagnosis screen says where your depth spread comes from, whether the shot holds together with distance, and what each miss in the last session was made of.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Shot doctor")
        }
    }

    private var spotPicker: some View {
        Section {
            Picker("Spot", selection: $spot) {
                ForEach(ShotSpot.allCases) { s in
                    let n = store.sessions(at: s).count
                    Text(n == 0 ? s.rawValue : "\(s.rawValue) (\(n))").tag(s)
                }
            }
            .pickerStyle(.menu)
        } footer: {
            Text("Shots pool only within a spot. Different distances are different shots, so their numbers are never averaged together.")
        }
    }

    // MARK: Progress across sessions

    private var progressSection: some View {
        let block = store.pooled(at: spot)
        let s = block.summary
        return Section {
            if block.sessions.isEmpty {
                Text("Nothing saved from this spot yet.").font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(s.accepted) accepted shots across \(block.sessions.count) session\(block.sessions.count == 1 ? "" : "s")")
                        .font(.subheadline.bold())
                    ProgressView(value: Double(min(s.accepted, SessionCoach.findingMinimumN)), total: Double(SessionCoach.findingMinimumN))
                    Text(s.accepted >= SessionCoach.findingMinimumN
                         ? "The 30-shot floor is met: the finding below is allowed to say something."
                         : "\(SessionCoach.findingMinimumN - s.accepted) more accepted shots from this spot unlock a finding.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                stat("Release angle", s.releaseAngleDegrees, "°", 1)
                stat("Release speed", s.releaseSpeed, "m/s", 2)
                stat("Entry angle", s.entryAngleDegrees, "°", 1)
                stat("Depth past front rim", s.depthPastFrontRim.map { BlockStat(mean: $0.mean * 100, sd: $0.sd.map { $0 * 100 }, n: $0.n) }, "cm", 1)
                if !block.lines.isEmpty {
                    DisclosureGroup("Session by session") {
                        ForEach(block.lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.date, format: .dateTime.day().month().year().hour().minute()).font(.caption.bold())
                                Text("accepted \(line.accepted) · speed \(line.releaseSpeed.map { $0.text(unit: "m/s", decimals: 2) } ?? "not measured") · entry \(line.entryAngle.map { $0.text(unit: "°", decimals: 1) } ?? "not measured")")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text("inferred \(line.makes) make, \(line.misses) miss")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if let trend = speedTrend(block) {
                            Text(trend).font(.caption2)
                        }
                    }
                    .font(.subheadline)
                }
            }
        } header: {
            Text("\(spot.rawValue) — all sessions")
        } footer: {
            Text(s.provenance)
        }
    }

    /// The only cross-session comparison the app makes: has the shot-to-shot speed spread narrowed?
    /// Spread is the number that maps to depth at the rim, and it needs no target to be read.
    private func speedTrend(_ block: PooledBlock) -> String? {
        let withSpread = block.lines.compactMap { l -> (Date, Double, Int)? in
            guard let v = l.releaseSpeed, let sd = v.sd, v.n >= 8 else { return nil }
            return (l.date, sd, v.n)
        }
        guard withSpread.count >= 2, let first = withSpread.first, let last = withSpread.last else {
            return "Speed spread is compared between sessions once two sessions each have 8 or more accepted shots."
        }
        let change = last.1 - first.1
        let cm = abs(change) / 0.1 * SessionCoach.depthCmPerTenthOfAMetrePerSecond
        return String(format: "Release-speed spread went from %.2f m/s (n %d) in the first session to %.2f m/s (n %d) in the latest, %@ — associated with about %.0f cm %@ depth spread at the rim.",
                      first.1, first.2, last.1, last.2, change < 0 ? "narrower" : (change > 0 ? "wider" : "unchanged"),
                      cm, change < 0 ? "less" : "more")
    }

    // MARK: Coaching, on the pooled block

    private var coachingSection: some View {
        let block = store.pooled(at: spot)
        let card = block.coaching
        return Group {
            Section {
                switch card.workOn {
                case .collectingBaseline(let accepted, let needed):
                    Text("Collecting baseline: \(accepted) of \(needed) accepted shots from this spot. Keep saving sessions; the finding appears here, not in any single session.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .finding(let title, let evidence, let cue, let provenance):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.subheadline.bold())
                        Text(evidence).font(.footnote)
                        Label(cue, systemImage: "target").font(.footnote)
                        Text(provenance).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .nothingFired(let accepted):
                    Text("Nothing to work on from this spot yet: at \(accepted) accepted shots no rule fired, so nothing separated itself from the shot-to-shot noise.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("What to work on")
            } footer: {
                Text("One thing at a time, from every saved session at this spot, only at 30 or more accepted shots.")
            }
            ShotProfileView(profile: card.profile)
            if !card.says.isEmpty {
                Section("What the pooled shots say") {
                    ForEach(card.says) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.text).font(.footnote)
                            Text(line.provenance).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: Saved sessions

    private var sessionsSection: some View {
        let list = store.sessions(at: spot).sorted { $0.date > $1.date }
        return Section {
            ForEach(list) { s in
                NavigationLink { EditSessionView(store: store, sessionID: s.id) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(s.date, format: .dateTime.day().month().year().hour().minute()).font(.subheadline.bold())
                        Spacer()
                        Text("\(s.accepted) of \(s.shots.count) accepted").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(s.clipName).font(.caption2).foregroundStyle(.secondary)
                    if !s.note.isEmpty { Text(s.note).font(.caption) }
                    Text("Tap to edit the spot or note, or delete it.").font(.caption2).foregroundStyle(.tertiary)
                }
                }
                .contextMenu {
                    ForEach(ShotSpot.allCases.filter { $0 != s.spot }) { target in
                        Button("Move to \(target.rawValue)") {
                            var moved = s; moved.spot = target; store.update(moved)
                            ActivityLog.shared.event("session.moved", ["from": s.spot.rawValue, "to": target.rawValue, "clip": s.clipName])
                        }
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets { store.delete(list[i].id) }
            }
        } header: {
            Text("Saved sessions at this spot")
        } footer: {
            Text("Swipe to delete. Sessions are stored only on this device, in the app's own folder.")
        }
    }

    private func stat(_ label: String, _ stat: BlockStat?, _ unit: String, _ decimals: Int) -> some View {
        LabeledContent(label) {
            Text(stat.map { $0.text(unit: unit, decimals: decimals) } ?? "not measured")
                .font(.subheadline).foregroundStyle(stat == nil ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
