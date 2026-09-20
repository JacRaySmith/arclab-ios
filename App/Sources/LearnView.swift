import ShotGeometry
import SwiftUI

/// **Learn** — the curriculum, in the order a shooting coach teaches it
/// (`docs/research/shooting-curriculum-2026-09-15.md`, `ShotGeometry/Curriculum.swift`).
///
/// The shot doctor answers "your numbers say X, so do Y". This screen answers the other question:
/// "teach me to shoot." Ten modules, each with what the coach watches, one cue, the drills, what
/// *done* looks like in ArcLab's own numbers, and the faults with the fingerprint each one leaves.
/// The last two (ball handling, handling under pressure) were added on 2026-09-19 and are the ones
/// the app can measure least of — which their own copy says first.
///
/// Two honesty rules the screen is built around:
///  * **Progress is read out of what was shot**, never out of a tick the shooter puts in a box. A
///    module counts as passed when a block recorded from its drill passed its own gate against an
///    earlier block from the same module.
///  * **A module whose gate ArcLab cannot measure says so** and stays open. Nothing is quietly
///    marked done because it was read.
struct LearnView: View {
    var practice: PracticeStore
    var doctor: ShotDoctorModel
    var store: SessionStore

    var body: some View {
        List {
            introSection
            modulesSection
            gameSection
            honestySection
        }
        .navigationTitle("Learn")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ActivityLog.shared.event("screen", ["name": "learn.home",
                                                "modules": Curriculum.modules.count,
                                                "passed": passedModules.count])
        }
    }

    // MARK: Progress, read out of recorded blocks only

    /// What has actually been shot from a module, and whether any of it passed the module's gate.
    struct ModuleProgress {
        var blocks: Int
        var shots: Int
        var passed: Bool
        var latest: String?

        var isStarted: Bool { blocks > 0 }
    }

    func progress(_ id: CurriculumModuleID) -> ModuleProgress {
        let blocks = practice.blocks(forModule: id).filter(\.isDone)
        return ModuleProgress(
            blocks: blocks.count,
            shots: blocks.reduce(0) { $0 + ($1.acceptedShots ?? 0) },
            passed: blocks.contains { $0.check?.passed == true },
            latest: blocks.last?.check?.sentence ?? blocks.last?.measureText)
    }

    private var passedModules: Set<CurriculumModuleID> {
        Set(CurriculumModuleID.allCases.filter { progress($0).passed })
    }

    // MARK: Sections

    private var introSection: some View {
        Section {
            Text("\(Curriculum.modules.count) modules, in the order a shooting coach works through them. Read one, run its drill as a practice block, and the block is scored on that module's own gate — not on whatever plan happens to be active.")
                .font(.subheadline)
            Text("The order itself is coaching consensus, not a proven sequence: no study has compared teaching orders for shooting. What is graded module by module is the measure, never the wording of the cue.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("The curriculum")
        }
    }

    private var modulesSection: some View {
        let done = passedModules
        return Section {
            ForEach(Curriculum.modules.sorted { $0.order < $1.order }) { module in
                NavigationLink {
                    LearnModuleView(module: module, practice: practice, doctor: doctor, store: store)
                } label: {
                    moduleRow(module, unlocked: Curriculum.isUnlocked(module.id, completed: done))
                }
            }
        } header: {
            Text("Modules")
        } footer: {
            Text("A module is never locked away from reading. What the prerequisites gate is the claim that it is done: working on range before the release repeats means the range numbers are measuring the release.")
        }
    }

    private func moduleRow(_ module: CurriculumModule, unlocked: Bool) -> some View {
        let p = progress(module.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: p.passed ? "checkmark.circle.fill" : (p.isStarted ? "circle.lefthalf.filled" : "circle"))
                    .foregroundStyle(p.passed ? .green : (p.isStarted ? .orange : .secondary))
                Text("\(module.order + 1). \(module.title)").font(.subheadline.bold())
                Spacer()
                if !unlocked && !p.passed {
                    Image(systemName: "lock").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(module.cue).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(statusLine(module, p, unlocked: unlocked)).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func statusLine(_ module: CurriculumModule, _ p: ModuleProgress, unlocked: Bool) -> String {
        var parts: [String] = []
        if p.blocks == 0 {
            parts.append("no blocks recorded")
        } else {
            parts.append("\(p.blocks) block\(p.blocks == 1 ? "" : "s"), \(p.shots) counted shot\(p.shots == 1 ? "" : "s")")
            parts.append(p.passed ? "gate passed once" : "gate not passed yet")
        }
        if !unlocked {
            let names = module.prerequisites.map { Curriculum.module($0).title }.joined(separator: " and ")
            parts.append("comes after \(names)")
        }
        if !module.doneWhen.contains(where: \.isMeasurableToday) {
            parts.append("no gate ArcLab can measure yet")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Taking it to a game (added 2026-09-19)

    /// The two modules at the end of the order teach ball handling and shooting under pressure, and
    /// neither is finished on a court by itself: one needs the same shot taken under a game's
    /// conditions, the other needs a record of what actually happened in a game. Both are a tap away
    /// from here rather than buried under a plan that may not exist yet.
    private var gameSection: some View {
        Section {
            NavigationLink {
                GameLikeBlocksView(practice: practice, doctor: doctor, store: store)
            } label: {
                Label("Game-like blocks", systemImage: "figure.basketball")
            }
            NavigationLink {
                GameLogView(store: store)
            } label: {
                Label("Games you have played", systemImage: "list.clipboard")
            }
            Text("A change measured in an empty gym has only been shown to exist in an empty gym. These two are how the app finds out whether yours goes any further.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Practice against games")
        } footer: {
            Text("The app measures the same shot numbers in a game-like block as in any other. It cannot see the defender, the clock or the call, and every block says so on its own card.")
        }
    }

    private var honestySection: some View {
        Section {
            ForEach(Curriculum.honestyRules, id: \.self) { rule in
                Text(rule).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("What this can and cannot tell you")
        }
    }
}

// MARK: - One module

/// A module in full: what the coach watches, the cue, the drills (each one startable as a practice
/// block), what done looks like, and the faults. Everything carries its grade and its source.
struct LearnModuleView: View {
    let module: CurriculumModule
    /// Nil when the module is opened from a screen that does not own the practice store (the shot
    /// doctor's plan, via "Learn why"). Two `PracticeStore` instances would both write
    /// `practice.json` from stale memory, so the module is read-only there and says so rather than
    /// quietly making a second store.
    var practice: PracticeStore?
    var doctor: ShotDoctorModel
    var store: SessionStore

    @State private var addedBlock: PracticeBlock?
    @State private var addedSessionID: UUID?
    @State private var addedNote: String?

    var body: some View {
        List {
            headerSection
            watchSection
            drillsSection
            doneSection
            faultsSection
            progressSection
            if !module.openQuestions.isEmpty { openSection }
        }
        .navigationTitle(module.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ActivityLog.shared.event("screen", ["name": "learn.module", "module": module.id.rawValue])
        }
    }

    // MARK: The cue

    private var headerSection: some View {
        Section {
            Text(module.summary).font(.subheadline)
            Label(module.cue, systemImage: "target").font(.subheadline.bold())
            Text("The cue is one sentence, aimed at the ball and the target rather than at your body. Its wording is the least evidenced thing on this screen — a bias-corrected meta-analysis of external-focus cues found g = 0.01 on performance. What is graded below is the measure.")
                .font(.caption2).foregroundStyle(.secondary)
        } header: {
            Text("Module \(module.order + 1) of \(Curriculum.modules.count)")
        } footer: {
            if module.prerequisites.isEmpty {
                Text("Nothing comes before this one.")
            } else {
                Text("Comes after: \(module.prerequisites.map { Curriculum.module($0).title }.joined(separator: ", ")).")
            }
        }
    }

    private var watchSection: some View {
        Section {
            ForEach(module.whatCoachWatches, id: \.self) { line in
                Label(line, systemImage: "eye").font(.footnote)
            }
        } header: {
            Text("What the coach watches")
        }
    }

    // MARK: Drills

    private var drillsSection: some View {
        Section {
            ForEach(Array(module.drills.enumerated()), id: \.offset) { _, d in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(d.drill.name).font(.subheadline.bold())
                        Spacer()
                        DoctorGradeBadge(grade: d.methodGrade)
                    }
                    Text(d.purpose).font(.footnote)
                    Text("\(d.drill.sets) sets × \(d.drill.reps) shots — \(d.drill.totalShots) in all")
                        .font(.footnote.monospacedDigit())
                    Text(d.drill.spots.isEmpty
                         ? "At one spot of your choosing — the drill does not name one."
                         : "Spots: \(d.drill.spots.spotList)")
                        .font(.footnote)
                    if let card = d.card {
                        DrillCardView(card: card)
                    } else {
                        // Only for a "drill" that is deliberately not one. It still says what it is.
                        Text(d.drill.constraint).font(.footnote)
                        Text(d.drill.schedule).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(d.source).font(.caption2).foregroundStyle(.secondary)
                    if practice != nil {
                        Button {
                            add(d)
                        } label: {
                            Label("Start this drill as a practice block", systemImage: "plus.circle")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note = addedNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if practice == nil {
                Text("Open Learn from the home screen to add this drill to today's plan — this screen was reached from a plan and does not own the practice log.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let practice, let block = addedBlock, let sessionID = addedSessionID {
                NavigationLink {
                    PracticeBlockView(sessionID: sessionID, block: block, practice: practice,
                                      doctor: doctor, store: store)
                } label: {
                    Label("Record it now: \(block.intendedShots) at \(block.spot.display)",
                          systemImage: "play.circle.fill")
                }
                NavigationLink {
                    PracticeHomeView(practice: practice, doctor: doctor, store: store)
                } label: {
                    Label("See today's plan", systemImage: "list.bullet")
                }
            }
        } header: {
            Text("The drill")
        } footer: {
            Text("The badge on a drill grades the evidence that **this way of practising** does anything — a different question from the grade on the measure it is scored on. Most coaching drills have never been tested; they are here labelled, not hidden.")
        }
    }

    private func add(_ d: CurriculumDrill) {
        guard let practice else { return }
        // The fallback spot when the drill names none is the active plan's spot, and free throws when
        // there is no plan. It is stated here rather than defaulted silently inside the store.
        let fallback = doctor.planProgress?.spot ?? .freeThrow
        let added = practice.addDrill(d, module: module, fallbackSpot: fallback, doctor: doctor)
        addedSessionID = practice.todaysSession?.id
        addedBlock = added.first
        addedNote = added.isEmpty
            ? "The drill could not be added to today's session."
            : "Added \(added.count) block\(added.count == 1 ? "" : "s") to today's plan: \(added.map { "\($0.intendedShots) at \($0.spot.display)" }.joined(separator: ", "))."
    }

    // MARK: Done

    private var doneSection: some View {
        Section {
            ForEach(Array(module.doneWhen.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: c.isMeasurableToday ? "checkmark.seal" : "questionmark.circle")
                            .foregroundStyle(c.isMeasurableToday ? .green : .orange)
                        Text(c.plainWords).font(.footnote)
                        Spacer(minLength: 6)
                        DoctorGradeBadge(grade: c.grade)
                    }
                    if let check = c.check {
                        Text(GateWords.sentence(check))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if let why = c.unavailableReason {
                        Text(why).font(.caption2).foregroundStyle(.orange)
                    }
                    if let precise = c.precise {
                        DisclosureGroup("The exact version") {
                            Text(precise)
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption2)
                    }
                    Text(c.source).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("What done looks like")
        } footer: {
            Text("A gate is scored by exactly the machinery that scores a plan: this module's block against the earliest block you recorded from the same module at the same spot. One block never passes a gate on its own.")
        }
    }

    // MARK: Faults

    private var faultsSection: some View {
        Section {
            ForEach(module.faults) { f in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(f.name).font(.subheadline.bold())
                        Spacer()
                        DoctorGradeBadge(grade: f.grade)
                    }
                    Text(f.howItShowsInNumbers).font(.footnote)
                    if let h = f.hypothesis {
                        Text("Tested by: \(DoctorNames.hypothesis(h)).").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(f.sources, id: \.self) { s in
                        Text(s).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("Common faults")
        } footer: {
            Text("A **D** here means coaches commonly teach it and nobody has measured it. It is listed rather than left out, because being told a thing is folklore is more use than hearing it repeated as fact.")
        }
    }

    // MARK: This shooter's blocks from this module

    @ViewBuilder
    private var progressSection: some View {
        let blocks = practice?.blocks(forModule: module.id).filter(\.isDone) ?? []
        Section {
            if blocks.isEmpty {
                Text("Nothing recorded from this module yet. Progress here is only ever what you shot — there is no box to tick.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(blocks) { b in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(b.drillName ?? "Drill") · \(b.intendedShots) at \(b.spot.display)\(b.acceptedShots.map { " · \($0) counted" } ?? "")")
                            .font(.subheadline)
                        if let text = b.measureText { Text(text).font(.caption) }
                        if let c = b.check {
                            Text(c.sentence).font(.caption2)
                                .foregroundStyle(c.passed == true ? .green : .secondary)
                        } else if let why = b.measureUnavailableReason {
                            Text(why).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
        } header: {
            Text("Your blocks from this module")
        }
    }

    private var openSection: some View {
        Section {
            ForEach(module.openQuestions, id: \.self) { q in
                Label(q, systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("What ArcLab still cannot see here")
        }
    }
}
