import ShotGeometry
import SwiftUI

/// What the session came to: every block with the number it produced, what moved in the plan, and
/// the way into Progress. Nothing here is recomputed — it reads what each block wrote when it saved
/// itself, plus the plan's own scoring from `ShotDoctorModel.planProgress`.
struct PracticeSummaryView: View {
    let sessionID: UUID
    var practice: PracticeStore
    var doctor: ShotDoctorModel
    var store: SessionStore

    private var session: PracticeSession? { practice.session(sessionID) }

    var body: some View {
        List {
            if let s = session {
                headerSection(s)
                blocksSection(s)
            }
            planSection
            progressSection
        }
        .navigationTitle("Session summary")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ActivityLog.shared.event("screen", ["name": "practice.summary", "sessionID": sessionID.uuidString,
                                                "done": session?.doneCount, "blocks": session?.blocks.count])
        }
    }

    private func headerSection(_ s: PracticeSession) -> some View {
        Section {
            let counted = s.blocks.reduce(0) { $0 + ($1.acceptedShots ?? 0) }
            let measured = s.blocks.reduce(0) { $0 + ($1.measuredShots ?? 0) }
            Text(s.isComplete ? "Session done" : "\(s.doneCount) of \(s.blocks.count) blocks done").font(.headline)
            LabeledContent("Shots", value: "\(counted) counted of \(measured) measured")
            let spots = Array(Set(s.blocks.filter(\.isDone).map(\.spot.rawValue))).sorted()
            if !spots.isEmpty {
                LabeledContent("Spots", value: spots.joined(separator: ", "))
            }
            Text("Each block was saved on its own, at its own spot. Nothing was pooled across spots, so the Progress screen can read them apart.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text(s.date.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private func blocksSection(_ s: PracticeSession) -> some View {
        Section {
            ForEach(s.blocks) { b in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(PracticeNames.role(b.role)) · \(b.intendedShots) planned at \(b.spot.rawValue)")
                        .font(.subheadline.bold())
                    if b.isDone {
                        Text("\(b.acceptedShots ?? 0) counted of \(b.measuredShots ?? 0) measured").font(.caption).foregroundStyle(.secondary)
                        if let text = b.measureText { Text(text).font(.caption) }
                        else if let why = b.measureUnavailableReason { Text(why).font(.caption2).foregroundStyle(.secondary) }
                        if let summary = b.summaryLine { Text(summary).font(.caption2).foregroundStyle(.secondary) }
                        if let c = b.check { Text(c.sentence).font(.caption2).foregroundStyle(c.passed == true ? .green : .secondary) }
                    } else if let note = b.blockNote {
                        Text(note).font(.caption2).foregroundStyle(.orange)
                    } else {
                        Text("Not recorded.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Blocks")
        }
    }

    // MARK: What advanced in the plan

    @ViewBuilder
    private var planSection: some View {
        if let p = doctor.planProgress, let id = HypothesisID(rawValue: p.plan.hypothesis) {
            Section {
                Text(DoctorNames.hypothesis(id)).font(.subheadline.bold())
                row("Baseline", value: p.baseline.map { "saved \($0.date.formatted(date: .abbreviated, time: .omitted)), \($0.accepted) counted" },
                    reason: p.baselineUnavailableReason)
                row("Follow-up", value: p.followUp.map { "saved \($0.date.formatted(date: .abbreviated, time: .omitted)), \($0.accepted) counted" },
                    reason: p.followUpUnavailableReason)
                row("Retention", value: p.retention.map { "saved \($0.date.formatted(date: .abbreviated, time: .omitted)), \($0.accepted) counted" },
                    reason: p.retentionUnavailableReason)
                if let c = p.check {
                    Text(c.sentence).font(.caption)
                }
                if let r = p.retentionResult {
                    Text(r.sentence).font(.caption).foregroundStyle(r.held == true ? .green : .secondary)
                }
                Text(p.package.retentionRule).font(.caption2).foregroundStyle(.secondary)
            } header: {
                Text("What moved in the plan")
            } footer: {
                Text("A block that passes is a block that was practised. It counts as learned only when it is still there in a later session with no cue — and even then it is associated with the change, never proof of it.")
            }
        } else {
            Section {
                Text("No active plan, so nothing advanced. The blocks above are saved sessions all the same; ask about your shot and the answer is drawn from them.")
                    .font(.subheadline)
            } header: {
                Text("What moved in the plan")
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: String?, reason: String?) -> some View {
        if let value {
            LabeledContent(label, value: value).font(.caption)
        } else if let reason {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption.bold())
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var progressSection: some View {
        Section {
            NavigationLink {
                HistoryView(store: store, doctor: doctor)
            } label: {
                Label("Progress across sessions", systemImage: "chart.line.uptrend.xyaxis")
            }
            NavigationLink {
                PracticeHomeView(practice: practice, doctor: doctor, store: store)
            } label: {
                Label("Back to today's plan", systemImage: "list.bullet.clipboard")
            }
        }
    }
}
