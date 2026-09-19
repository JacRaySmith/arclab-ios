import ShotGeometry
import SwiftUI

/// Today's plan: the blocks to shoot, in order, each with its spot and its pass check, and one tap
/// into the block that is next. Built from the active plan when there is one
/// (`docs/DESIGN-PRACTICE-MODE-2026-09-15.md` §1); a plain baseline block when there is not, because
/// there is nothing to score a fix against until one session exists.
struct PracticeHomeView: View {
    var practice: PracticeStore
    var doctor: ShotDoctorModel
    var store: SessionStore

    @State private var sessionID: UUID?

    private var session: PracticeSession? {
        guard let sessionID else { return nil }
        return practice.session(sessionID)
    }

    var body: some View {
        List {
            planSection
            if let s = session {
                blocksSection(s)
                continueSection(s)
            }
            honestySection
        }
        .navigationTitle("Today's plan")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let built = practice.ensureToday(doctor: doctor)
            // Every block done is not the end of the day: propose what follows from what the last
            // block measured before this screen lists anything.
            practice.refreshProposal(doctor: doctor)
            let s = practice.session(built.id) ?? built
            sessionID = s.id
            ActivityLog.shared.event("screen", ["name": "practice.home", "blocks": s.blocks.count, "done": s.doneCount,
                                                "plan": s.planHypothesis])
        }
    }

    // MARK: What today is for

    private var planSection: some View {
        Section {
            if let progress = doctor.planProgress, let id = HypothesisID(rawValue: progress.plan.hypothesis) {
                Text(DoctorNames.hypothesis(id)).font(.headline)
                let names = PracticeNames.measure(progress.package.passCheck.measure)
                Text("The one thing being scored at \(progress.spot.rawValue): \(names.name). \(progress.package.passCheck.description).")
                    .font(.subheadline)
                if let value = progress.plan.baselineValue {
                    Text("Baseline \(String(format: "%.\(names.decimals)f", value))\(names.unit.isEmpty ? "" : " \(names.unit)") from \(progress.plan.baselineAcceptedShots) counted shots on \(progress.plan.baselineSessionDate.formatted(date: .abbreviated, time: .omitted)) — your own number, not a published target.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let why = progress.plan.baselineUnavailableReason {
                    Text(why).font(.caption).foregroundStyle(.orange)
                }
                if let why = progress.baselineUnavailableReason {
                    Text(why).font(.caption).foregroundStyle(.orange)
                }
            } else if store.activePlan != nil {
                Text("There is an active plan but it cannot be read back. Today is a plain baseline block.").font(.subheadline)
            } else {
                Text("No active plan yet").font(.headline)
                Text("Today is a baseline: ten free throws, un-cued. A fix can only be scored against a session that already exists, so this block is the one that makes the rest possible. Ask about your shot once it is saved and the plan starts there.")
                    .font(.subheadline)
            }
            if let s = session {
                LabeledContent("Blocks", value: "\(s.doneCount) of \(s.blocks.count) done · \(s.blocks.reduce(0) { $0 + $1.intendedShots }) shots planned")
                    .font(.caption)
                if !s.blocks.contains(where: \.isDone), s.planID != store.activePlan?.id {
                    Button("Rebuild today's plan from the current fix") {
                        practice.rebuildToday(doctor: doctor)
                        sessionID = practice.todaysSession?.id
                    }
                    .font(.subheadline)
                }
            }
        } header: {
            Text(Date().formatted(date: .complete, time: .omitted))
        }
    }

    // MARK: The blocks

    private func blocksSection(_ s: PracticeSession) -> some View {
        Section {
            ForEach(s.blocks) { block in
                NavigationLink {
                    PracticeBlockView(sessionID: s.id, block: block, practice: practice, doctor: doctor, store: store)
                } label: {
                    blockRow(block)
                }
            }
        } header: {
            Text("Blocks")
        } footer: {
            Text("Every block states its spot before a shot is taken, and saves itself at that spot when its analysis ends. Two spots are never pooled: a free throw and a three are different shots.")
        }
    }

    private func blockRow(_ b: PracticeBlock) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: b.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(b.isDone ? .green : .secondary)
                Text("\(PracticeNames.role(b.role)) · \(b.intendedShots) at \(b.spot.rawValue)")
                    .font(.subheadline.bold())
            }
            if b.isDone {
                if let text = b.measureText {
                    Text(text).font(.caption)
                } else if let summary = b.summaryLine {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                if let c = b.check {
                    Text(c.sentence).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                }
            } else if let note = b.blockNote {
                Text(note).font(.caption2).foregroundStyle(.orange).lineLimit(3)
            } else if let cue = b.cue {
                Text(cue).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("Un-cued.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Start, continue, finish

    @ViewBuilder
    private func continueSection(_ s: PracticeSession) -> some View {
        Section {
            // There is always one thing to do next: the block that is waiting, or — once the day's
            // limit is reached — what tomorrow starts with. This row is never empty.
            if let action = practice.nextAction {
                PracticeNextCard(action: action)
            }
            if let next = s.nextBlock {
                NavigationLink {
                    PracticeBlockView(sessionID: s.id, block: next, practice: practice, doctor: doctor, store: store)
                } label: {
                    Label(s.doneCount == 0 ? "Start the first block" : "Record it: \(PracticeNames.role(next.role)) at \(next.spot.rawValue)",
                          systemImage: "play.circle.fill")
                }
            }
            if s.doneCount > 0 {
                NavigationLink {
                    PracticeSummaryView(sessionID: s.id, practice: practice, doctor: doctor, store: store)
                } label: {
                    Label(s.isComplete ? "Session summary" : "Summary so far", systemImage: "doc.text")
                }
            }
        } footer: {
            Text("A block's card appears a minute or two after the block, not shot by shot: measuring one shot still takes several seconds on this phone. Record the next block while the last one finishes.")
        }
    }

    private var honestySection: some View {
        Section {
            ForEach(FixLibrary.honestyRules, id: \.self) { rule in
                Text(rule).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("What this session can and cannot tell you")
        }
    }
}
