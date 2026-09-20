import ShotGeometry
import SwiftUI

/// **Game-like blocks** — the same shot, under one condition a game actually has.
///
/// Added 2026-09-19 for 1.4 "game". The research position behind the whole screen
/// (`docs/research/ball-handling-and-transfer-2026-09-19.md` §2.2) is narrower than it first looks:
///
///  * a defender does **not** change a skilled shooter's technique — it changes how much the result
///    scatters (Daly-Grafstein & Bornn 2020, Amaro et al. 2025, both grade A);
///  * tiredness is the one condition with a measured effect on the shot itself, and it hits some
///    players and not others (Bourdas et al. 2024 against Slawinski et al. 2018, both grade A);
///  * practising in one easy condition looks best on the day and worst on the test afterwards
///    (Shamshiri et al. 2025, grade B, novices).
///
/// So these blocks measure **spread** across conditions, and they measure fatigue on this shooter
/// rather than assuming it. What the app cannot see — the defender, the clock, the call — is printed
/// on every block rather than hidden behind a disclosure.
struct GameLikeBlocksView: View {
    /// Nil when this screen was reached from somewhere that does not own the practice log (a plan,
    /// via "Learn why"). Two `PracticeStore` instances would both write `practice.json` from stale
    /// memory, so the screen is read-only there and says so — the same rule `LearnModuleView` keeps.
    var practice: PracticeStore?
    var doctor: ShotDoctorModel
    var store: SessionStore

    @State private var addedBlock: PracticeBlock?
    @State private var addedSessionID: UUID?
    @State private var note: String?
    /// The called-catch block whose calls are being typed in, or nil.
    @State private var callsFor: PracticeBlock?

    private var offers: [NextBlock.Plan] { practice?.gameLikeOffers(doctor: doctor) ?? [] }

    var body: some View {
        List {
            introSection
            if practice == nil {
                readOnlySection
            } else if offers.isEmpty {
                notYetSection
            } else {
                offersSection
            }
            catalogueSection
            historySection
        }
        .navigationTitle("Game-like blocks")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $callsFor) { block in
            NavigationStack {
                GameCallsEntryView(block: block, practice: practice)
            }
        }
        .onAppear {
            ActivityLog.shared.event("screen", ["name": "game.blocks",
                                                "offers": offers.count,
                                                "recorded": practice?.gameLikeBlocks().count ?? 0,
                                                "readOnly": practice == nil])
        }
    }

    // MARK: Why

    private var introSection: some View {
        Section {
            Text("A change you measured in an empty gym has only been shown to exist in an empty gym. These blocks put one condition of a game on your ordinary shot and measure the same numbers as always.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text("What changes under pressure, in the tracking data, is how much your shots scatter — not how the ball leaves your hand. So what these blocks watch is the scatter.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Why bother")
        }
    }

    private var readOnlySection: some View {
        Section {
            Text("Open this from today's plan to add one of these blocks — this screen was reached from a plan and does not own the practice log.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Reading only")
        }
    }

    private var notYetSection: some View {
        Section {
            Text("Nothing is offered yet. These blocks come after your plan's number has actually moved — either the drill passed its check, or an un-cued block showed the change was still there with the cue gone.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Text("It is not a lock. Practising something harder before the change exists means practising a change you have not got, and neither block could be scored against the other.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Ready when your plan has moved")
        }
    }

    // MARK: The offers

    private var offersSection: some View {
        Section {
            ForEach(Array(offers.enumerated()), id: \.offset) { _, plan in
                offerRow(plan)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let practice, let block = addedBlock, let sessionID = addedSessionID {
                NavigationLink {
                    PracticeBlockView(sessionID: sessionID, block: block, practice: practice,
                                      doctor: doctor, store: store)
                } label: {
                    Label("Record it now: \(block.intendedShots) at \(block.spot.display)",
                          systemImage: "play.circle.fill")
                }
            }
        } header: {
            Text("Ready for you now")
        } footer: {
            Text("A game-like block is never cued. The condition is the thing being added, and a cue on top of it would be two changes at once with neither one scorable.")
        }
    }

    @ViewBuilder
    private func offerRow(_ plan: NextBlock.Plan) -> some View {
        if let variant = plan.gameLike {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(variant.title).font(.subheadline.bold())
                    Spacer()
                    DoctorGradeBadge(grade: variant.grade)
                }
                Text(plan.instruction).font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Label(plan.reason, systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(variant.limit, systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Where this comes from") {
                    Text(variant.source)
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption2)
                Button {
                    add(plan)
                } label: {
                    Label("Add to today", systemImage: "plus.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func add(_ plan: NextBlock.Plan) {
        guard let practice, let block = practice.addGameLikeBlock(plan, doctor: doctor) else {
            note = "That block could not be added to today's session."
            return
        }
        addedSessionID = practice.todaysSession?.id
        addedBlock = block
        // A shuffled offer lands as one block per set, each recorded at its own spot, so the note
        // has to say how many rather than assuming one.
        let sets = max(1, plan.spotSequence.count)
        note = sets == 1
            ? "Added \(block.intendedShots) shots at \(block.spot.display) to today's plan."
            : "Added \(sets) sets of \(block.intendedShots) to today's plan, in this order: \(plan.spotSequence.map(\.display).joined(separator: ", ")). Each one is recorded on its own, because a clip is saved at one spot."
    }

    // MARK: All four, always readable

    private var catalogueSection: some View {
        Section {
            ForEach(NextBlock.GameLikeVariant.allCases) { variant in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(variant.title).font(.subheadline.bold())
                        Spacer()
                        DoctorGradeBadge(grade: variant.grade)
                    }
                    Text(variant.limit).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(variant.source).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("The four conditions")
        } footer: {
            Text("The badge grades the evidence that the condition is worth practising in, not the evidence that the app measures it well. Only one of the four — being tired — has a measured effect on the shot itself, and even that one spared elite juniors entirely.")
        }
    }

    // MARK: What has been shot

    @ViewBuilder private var historySection: some View {
        let blocks = practice?.gameLikeBlocks().filter(\.isDone) ?? []
        if !blocks.isEmpty {
            Section {
                ForEach(blocks) { b in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(b.gameLikeVariant?.title ?? "Game-like") · \(b.intendedShots) at \(b.spot.display)\(b.acceptedShots.map { " · \($0) counted" } ?? "")")
                            .font(.subheadline)
                        if let text = b.measureText { Text(text).font(.caption) }
                        if let calls = b.calls, !calls.isEmpty {
                            Text("You said the calls were: \(calls.joined(separator: ", ")). The app never heard them.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let why = b.measureUnavailableReason {
                            Text(why).font(.caption2).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let practice, b.gameLikeVariant == .decisionCalled, b.calls == nil {
                            Button {
                                callsFor = b
                            } label: {
                                Label("Type in what was called", systemImage: "text.bubble")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .disabled(practice.sessionID(forBlock: b.id) == nil)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Game-like blocks you have shot")
            } footer: {
                Text("Compare one of these with an ordinary block at the same spot on the same day. Across days it is two days being compared as much as two conditions.")
            }
        }
    }
}

// MARK: - What the partner called

/// The calls on a called-catch block, typed in afterwards.
///
/// Along with the game log, this is one of only two things in the app that store something the
/// camera did not see — so it is kept as the shooter's word and said that way wherever it is shown.
/// It is never used in a calculation: it is a record of what the block was, so a block from three
/// weeks ago can still be read back.
struct GameCallsEntryView: View {
    let block: PracticeBlock
    var practice: PracticeStore?
    @Environment(\.dismiss) private var dismiss

    /// The three things a partner can call, in the order the block's own instruction lists them.
    private static let options = ["Catch and shoot", "One dribble pull-up", "Drive"]

    @State private var calls: [String] = []

    var body: some View {
        List {
            Section {
                ForEach(Self.options, id: \.self) { option in
                    Button {
                        calls.append(option)
                    } label: {
                        Label(option, systemImage: "plus.circle")
                    }
                }
            } header: {
                Text("Tap each call in the order it came")
            } footer: {
                Text("The app never heard these. They are kept as your record of what the block was, and nothing is calculated from them.")
            }
            if !calls.isEmpty {
                Section {
                    ForEach(Array(calls.enumerated()), id: \.offset) { i, call in
                        Text("\(i + 1). \(call)").font(.footnote)
                    }
                    .onDelete { calls.remove(atOffsets: $0) }
                } header: {
                    Text("\(calls.count) of \(block.intendedShots)")
                }
            }
            Section {
                Button {
                    save()
                } label: {
                    Label("Save these calls", systemImage: "checkmark.circle")
                }
                .disabled(calls.isEmpty || practice == nil)
            }
        }
        .navigationTitle("What was called")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func save() {
        guard let practice, let sessionID = practice.sessionID(forBlock: block.id) else { return }
        practice.recordCalls(calls, for: block.id, in: sessionID)
        dismiss()
    }
}
