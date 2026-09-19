import ShotGeometry
import SwiftUI

/// **Shoot** — the first screen of the app: one number, one button.
///
/// `docs/IMPROVEMENTS-2026-09-16.md` §1.1 item 1: the only thing the logs say a shooter reads on the
/// home screen is the glance card, and it used to be fourth on the page under six `Start` rows and a
/// nine-line footer. So this screen is the card, then the one thing to do next, then everything else
/// as a plain row. Every explanatory paragraph that used to be a grey footer is a collapsed
/// "Why?" / "How this is measured" disclosure (§1.1 item 4).
///
/// Honesty (CLAUDE.md rule 1) shapes the card more than the layout does. The card never invents a
/// number: the plan's measure is read back through `FixLibrary.check`, which is the same public
/// scorer the plan screen uses, and when it cannot be computed the card shows the reason sentence
/// the scorer returned rather than a dash. The trend arrow shows the direction the number moved and
/// is only coloured when the check actually produced a pass/fail — never on a guess about which way
/// is "good".
struct TodayView: View {
    var model: AnalysisModel
    var session: SessionModel
    var store: SessionStore
    var doctor: ShotDoctorModel
    var practice: PracticeStore

    @State private var card: TodayCard = .loading
    @State private var going: PrimaryDestination?
    /// A session an earlier run of ArcLab was in the middle of when it stopped. Read from disk, never
    /// from memory: the point of it is that the process it belonged to is gone.
    @State private var unfinished: GuidedCheckpoint?

    /// One destination at a time, so there is a single `navigationDestination` on this screen rather
    /// than two competing `isPresented` ones.
    enum PrimaryDestination: Hashable, Identifiable {
        case block(UUID)
        case guided
        /// The guided screen, told to pick up an unfinished session rather than start a new one.
        case resume
        var id: Self { self }
    }

    var body: some View {
        List {
            resumeSection
            cardSection
            primarySection
            secondarySection
        }
        .navigationTitle("Shoot")
        .navigationDestination(item: $going) { destination in
            switch destination {
            case .guided:
                GuidedSessionView(model: model, session: session, store: store)
            case .resume:
                GuidedSessionView(model: model, session: session, store: store, resume: unfinished)
            case .block(let id):
                // Looked up by id rather than taken from `openBlock`, because a resumed block is not
                // necessarily the next one in the plan.
                if let found = blockLookup(id) {
                    PracticeBlockView(sessionID: found.session.id, block: found.block,
                                      practice: practice, doctor: doctor, store: store,
                                      resume: unfinished?.practiceBlockID == id ? unfinished : nil)
                }
            }
        }
        .task(id: refreshKey) {
            // The day is a sequence: if today's blocks are all done, the engine proposes the next one
            // before this screen draws its button. `ensureToday` is still not called — a day with no
            // practice session stays that way until the shooter starts one.
            practice.refreshProposal(doctor: doctor)
            card = makeCard()
        }
        .onAppear {
            unfinished = GuidedCheckpointStore.load()
            ActivityLog.shared.event("screen", ["name": "today",
                                                "savedSessions": store.sessions.count,
                                                "plan": store.activePlan?.hypothesis,
                                                "openBlock": openBlock != nil,
                                                "unfinished": unfinished?.summaryLine])
        }
    }

    /// Everything the card is built from. Reading these in `body` is what makes `.task(id:)` re-run
    /// when a session is saved on another tab.
    private var refreshKey: String {
        let practiceKey = practice.todaysSession.map { "\($0.id)#\($0.doneCount)" } ?? "none"
        return "\(store.sessions.count)|\(store.activePlan?.id.uuidString ?? "none")|\(practiceKey)"
    }

    // MARK: The number that matters

    private var cardSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(card.eyebrow)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(card.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                if let value = card.value {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(value)
                            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        if let trend = card.trend {
                            Image(systemName: trend.symbol)
                                .font(.title3.bold())
                                .foregroundStyle(trend.tint)
                                .accessibilityLabel(trend.accessibility)
                        }
                    }
                    if let label = card.valueLabel {
                        Text(label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !card.stats.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) { statViews }
                        VStack(alignment: .leading, spacing: 10) { statViews }
                    }
                }

                if let target = card.target {
                    Text(target)
                        .font(.subheadline)
                        .foregroundStyle(card.passed == true ? .green : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = card.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(card.noteIsWarning ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            DisclosureGroup(card.whyTitle) {
                Text(card.why)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder private var statViews: some View {
        ForEach(card.stats) { stat in
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.value)
                    .font(.title3.weight(.semibold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(stat.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: The one button

    /// The open block of a practice session that already exists today. `ensureToday` is deliberately
    /// **not** called here: opening the app must not manufacture a practice session the shooter never
    /// asked for. The button only offers a block when one is genuinely waiting.
    private var openBlock: (session: PracticeSession, block: PracticeBlock, number: Int)? {
        guard let s = practice.todaysSession, let next = s.nextBlock,
              let index = s.blocks.firstIndex(where: { $0.id == next.id }) else { return nil }
        return (s, next, index + 1)
    }

    /// Which practice session a block belongs to, by the block's own id.
    private func blockLookup(_ id: UUID) -> (session: PracticeSession, block: PracticeBlock)? {
        for s in practice.sessions {
            if let b = s.blocks.first(where: { $0.id == id }) { return (s, b) }
        }
        return nil
    }

    // MARK: The session that was interrupted

    /// Offered above everything else, because a session that is half measured is worth more than a new
    /// one and because losing it once already cost a whole evening of filming (2026-09-18).
    @ViewBuilder private var resumeSection: some View {
        if let unfinished, unfinished.isWorthResuming {
            Section {
                Button {
                    ActivityLog.shared.event("checkpoint.resume.tapped",
                                             ["flow": unfinished.flow, "block": unfinished.practiceBlockID?.uuidString,
                                              "measured": unfinished.measuredCount, "windows": unfinished.windows.count])
                    if let block = unfinished.practiceBlockID, blockLookup(block) != nil {
                        going = .block(block)
                    } else {
                        going = .resume
                    }
                } label: {
                    primaryLabel(title: "Resume the session you were in",
                                 subtitle: unfinished.summaryLine.isEmpty
                                    ? unfinished.startedAt.formatted(date: .abbreviated, time: .shortened)
                                    : unfinished.summaryLine,
                                 symbol: "arrow.clockwise.circle")
                }
                .primaryAction()
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                if let why = unfinished.resumeObstacle {
                    Text(why)
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(role: .destructive) {
                    GuidedCheckpointStore.clear(why: "discarded from the Today screen")
                    self.unfinished = nil
                } label: {
                    Label("Discard it", systemImage: "trash")
                }
                .font(.subheadline)
            } header: {
                Text("Unfinished")
            } footer: {
                Text("ArcLab stopped part-way through this session. Everything it had already measured was written to disk as it went, so resuming carries on from the last shot it finished — nothing measured is measured twice, and nothing unmeasured is shown as a zero.")
            }
        }
    }

    /// The day's one next thing. Never empty once a practice session exists: a block to record, or a
    /// finished day with tomorrow's first block named (`PracticeStore.nextAction`).
    private var nextAction: PracticeNextAction? { practice.nextAction }

    /// Non-nil only when today's cap is reached, so the card can take the place of the record button.
    private var dayDoneAction: PracticeNextAction? {
        if let action = nextAction, case .dayDone = action { return action }
        return nil
    }

    @ViewBuilder
    private var primarySection: some View {
        if let done = dayDoneAction {
            Section {
                PracticeNextCard(action: done)
                Button {
                    going = .guided
                } label: {
                    primaryLabel(title: "Record another session anyway",
                                 subtitle: "The daily limit is ArcLab's own rule, not a finding",
                                 symbol: "basketball")
                }
                .primaryAction()
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        } else {
            Section {
                Button {
                    going = openBlock.map { .block($0.block.id) } ?? .guided
                } label: {
                    if let open = openBlock {
                        primaryLabel(title: "Record block \(open.number): \(open.block.spot.rawValue) × \(open.block.intendedShots)",
                                     subtitle: PracticeNames.role(open.block.role),
                                     symbol: "record.circle")
                    } else {
                        primaryLabel(title: "Record or analyze a session",
                                     subtitle: "Film it here, or pick a clip you already have",
                                     symbol: "basketball")
                    }
                }
                .primaryAction()
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                // Why this block, and what recording it lets ArcLab tell you.
                if let action = nextAction, case .record = action {
                    PracticeNextCard(action: action, showsTitle: false)
                }
            }
        }
    }

    private func primaryLabel(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).opacity(0.85)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    // MARK: Everything else

    private var secondarySection: some View {
        Section {
            NavigationLink {
                PracticeHomeView(practice: practice, doctor: doctor, store: store)
            } label: {
                Label("Practice plan", systemImage: "figure.basketball.circle")
            }
            NavigationLink {
                FormClipView(store: store)
            } label: {
                Label("Form clip", systemImage: "figure.stand")
            }
            NavigationLink {
                AskView(doctor: doctor)
            } label: {
                Label("Ask about your shot", systemImage: "stethoscope")
            }
            DisclosureGroup("What each of these is") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("**Practice plan** runs a session as blocks: a spot and a number of shots each, recorded in the app, analysed and saved by themselves, and scored against the one fix being worked on.")
                    Text("**Form clip** is the close-up one: the phone 3–4 m away with no rim in frame. It measures the body only — the shots are found from your own wrist, and no ball number is produced.")
                    Text("**Ask about your shot** answers a complaint from the sessions already saved, and says so when there are not enough shots to answer it.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
        }
    }

    // MARK: Building the card

    private func makeCard() -> TodayCard {
        if let planCard = planCard() { return planCard }
        if let last = store.sessions.filter({ !$0.isFormClip }).max(by: { $0.date < $1.date }) {
            return lastSessionCard(last)
        }
        return .empty
    }

    /// The active plan's measure, read for the **most recent** session at the plan's spot — not the
    /// first one after the baseline, which is what `planProgress.check` scores. Both come out of the
    /// same public `FixLibrary.check`, so the number on this card and the number on the plan screen
    /// are computed by one piece of code.
    private func planCard() -> TodayCard? {
        guard let progress = doctor.planProgress,
              let id = HypothesisID(rawValue: progress.plan.hypothesis) else { return nil }
        let names = PracticeNames.measure(progress.package.passCheck.measure)
        let spotName = progress.spot.rawValue
        var card = TodayCard.loading
        card.eyebrow = "Your plan · \(spotName)"
        card.title = DoctorNames.hypothesis(id)
        card.valueLabel = names.name
        card.whyTitle = "How this is measured"

        guard let baseline = progress.baseline else {
            card.value = nil
            card.valueLabel = nil
            card.note = progress.baselineUnavailableReason ?? progress.plan.baselineUnavailableReason
            card.noteIsWarning = true
            card.why = Self.planWhy(progress: progress, names: names, check: nil)
            return card
        }

        let later = store.sessions(at: progress.spot).filter { $0.date > baseline.date }
        guard let latest = later.max(by: { $0.date < $1.date }) else {
            // Nothing has been shot at the spot since the plan started: the baseline is the only
            // number there is, and the card says that rather than showing it as today's.
            if let value = progress.plan.baselineValue {
                card.value = Self.format(value, names)
                card.valueLabel = "\(names.name) — still the baseline"
            } else {
                card.valueLabel = nil
                card.noteIsWarning = true
            }
            card.note = progress.followUpUnavailableReason
                ?? "No session has been saved at \(spotName) since this plan was chosen."
            card.target = Self.targetSentence(progress.package.passCheck, baseline: progress.plan.baselineValue, names: names)
            card.why = Self.planWhy(progress: progress, names: names, check: nil)
            return card
        }

        let doctorSpot = DoctorSpot(rawValue: progress.spot.rawValue) ?? .other
        let result = FixLibrary.check(progress.package.passCheck,
                                      baseline: doctor.diagnosis(for: baseline),
                                      followUp: doctor.diagnosis(for: latest),
                                      spot: doctorSpot)
        card.passed = result.passed
        card.eyebrow = "Your plan · \(spotName) · \(latest.date.formatted(date: .abbreviated, time: .shortened))"
        if let f = result.followUpValue {
            card.value = Self.format(f, names)
            if let b = result.baselineValue {
                card.trend = TodayCard.Trend(from: b, to: f, passed: result.passed)
                card.note = "\(Self.format(b, names)) at the baseline on \(baseline.date.formatted(date: .abbreviated, time: .omitted))"
                    + (result.n.map { " · \($0) counted shots in this one" } ?? "")
            }
            card.target = Self.targetSentence(progress.package.passCheck, baseline: result.baselineValue,
                                              computed: result.target, names: names)
        } else {
            card.value = nil
            card.valueLabel = nil
            card.note = result.sentence
            card.noteIsWarning = true
        }
        card.why = Self.planWhy(progress: progress, names: names, check: result)
        return card
    }

    private func lastSessionCard(_ last: SavedSession) -> TodayCard {
        let s = last.summary
        var card = TodayCard.loading
        card.eyebrow = "Last session · \(last.spot.rawValue) · \(last.date.formatted(date: .abbreviated, time: .shortened))"
        card.title = "\(s.accepted) counted shot\(s.accepted == 1 ? "" : "s") of \(s.windows) found"
        card.stats = [
            TodayCard.Stat(label: "release m/s",
                           value: s.releaseSpeed.map { String(format: "%.2f ± %.2f", $0.mean, $0.sd ?? 0) } ?? "not measured"),
            TodayCard.Stat(label: "past front rim",
                           value: s.depthPastFrontRim.map { String(format: "%+.0f cm", $0.mean * 100) } ?? "not measured"),
            TodayCard.Stat(label: "inferred makes", value: "\(s.makes)/\(s.makes + s.misses)"),
        ]
        card.note = "No fix is being scored yet. Ask about your shot, or open the diagnosis on Review, and one number becomes the one that matters."
        card.whyTitle = "Why these three?"
        card.why = """
            These are the three that survive a single camera: release speed with its shot-to-shot spread, how far past \
            the front of the ring the ball crossed, and whether the ball's path through the ring could have gone in. \
            Anything shown as "not measured" was refused by the gates rather than guessed — the session screen carries \
            the reason for each one. Makes are inferred from the ball at the rim, not counted by a person, which is why \
            they are labelled inferred.
            """
        return card
    }

    private static func format(_ value: Double, _ names: (name: String, unit: String, decimals: Int)) -> String {
        let n = String(format: "%.\(names.decimals)f", value)
        return names.unit.isEmpty ? n : "\(n) \(names.unit)"
    }

    /// The target in the measure's own words. `computed` is the number the scorer actually used at
    /// this shot count (the detectable-ratio targets depend on n), and is preferred when present.
    private static func targetSentence(_ check: PassCheck, baseline: Double?, computed: Double? = nil,
                                       names: (name: String, unit: String, decimals: Int)) -> String? {
        switch check.target {
        case .reportOnly:
            return "Reported, never scored."
        case .insideBand(let lo, let hi):
            return "Target: between \(format(lo, names)) and \(format(hi, names))."
        case .moveBy(let delta):
            return "Target: move at least \(format(abs(delta), names)) \(delta < 0 ? "down" : "up")."
        case .narrowByFraction, .narrowByDetectableRatio:
            if let t = computed { return "Target: \(format(t, names)) or tighter." }
            if case .narrowByFraction(let k) = check.target, let b = baseline {
                return "Target: \(format(b * k, names)) or tighter."
            }
            return "Target: tighter than the baseline by the smallest change your shot count can see."
        }
    }

    private static func planWhy(progress: ShotDoctorModel.PlanProgress,
                                names: (name: String, unit: String, decimals: Int),
                                check: FixLibrary.PassCheckResult?) -> String {
        var parts: [String] = []
        parts.append("The number is \(names.name) at \(progress.spot.rawValue), from the most recent session saved there. \(progress.package.passCheck.description)")
        parts.append("The target is your own baseline, not a published figure: \(progress.package.passCheck.minimumN) counted shots at least, or the check says it cannot tell rather than calling it a fail.")
        if let check { parts.append(check.sentence) }
        parts.append("Spots are never pooled — a free throw and a three are different shots — and a change is only credited if it is still there the session after.")
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - The card's contents

/// A plain value type so the card is computed once per data change rather than on every redraw
/// (`diagnosis(for:)` caches, but it is still not something to run from a view's body).
struct TodayCard {
    struct Stat: Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    struct Trend {
        enum Direction { case down, up, flat }

        var direction: Direction
        /// Only set when the scorer produced a verdict. Nothing here decides on its own which
        /// direction is good: colour comes from the check or not at all.
        var passed: Bool?

        init(from baseline: Double, to now: Double, passed: Bool?) {
            let delta = now - baseline
            direction = abs(delta) < 1e-9 ? .flat : (delta < 0 ? .down : .up)
            self.passed = passed
        }

        var symbol: String {
            switch direction {
            case .down: return "arrow.down.right"
            case .up: return "arrow.up.right"
            case .flat: return "arrow.right"
            }
        }

        var tint: Color {
            switch passed {
            case .some(true): return .green
            case .some(false): return .orange
            case nil: return .secondary
            }
        }

        var accessibility: String {
            let word: String
            switch direction {
            case .down: word = "down from the baseline"
            case .up: word = "up from the baseline"
            case .flat: word = "unchanged from the baseline"
            }
            switch passed {
            case .some(true): return "\(word), target met"
            case .some(false): return "\(word), target not met yet"
            case nil: return word
            }
        }
    }

    var eyebrow: String = ""
    var title: String = ""
    var value: String?
    var valueLabel: String?
    var stats: [Stat] = []
    var target: String?
    var note: String?
    var noteIsWarning = false
    var passed: Bool?
    var trend: Trend?
    var whyTitle: String = "Why?"
    var why: String = ""

    static let loading = TodayCard()

    static let empty: TodayCard = {
        var c = TodayCard()
        c.eyebrow = "Nothing saved yet"
        c.title = "One clip of ten shots from one spot"
        c.note = "That is the whole first step. Film ten free throws from the sideline with the ring in frame, let the app measure them, and save the session with its spot. Everything else on this screen is built out of saved sessions."
        c.whyTitle = "Why ten, and why one spot?"
        c.why = """
            A finding needs 30 counted shots from the same spot, which is usually three sessions — the sessions pool on \
            the Review tab until the floor is met. Spots are never mixed, because a free throw and a three are \
            different shots and averaging them would hide both. Ten is simply the number that fits comfortably in one \
            clip without the phone getting hot.
            """
        return c
    }()
}

// MARK: - The one prominent control

private extension View {
    /// iOS 26's glass on the single primary button, and nothing else on the screen
    /// (`docs/IMPROVEMENTS-2026-09-16.md` §1.1 item 6; §7 keeps glass away from footage and charts,
    /// which is why no other surface in the app uses it).
    @ViewBuilder func primaryAction() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).controlSize(.extraLarge)
        } else {
            self.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}
