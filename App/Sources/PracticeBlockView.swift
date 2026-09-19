import ShotGeometry
import SwiftUI

/// One block of a practice session: read the instruction and its cue, record the block, watch the
/// analysis stream shot by shot, and read the block card.
///
/// It drives exactly the models the guided flow drives — `AnalysisModel.useRecordedClip` →
/// `findRimAutomatically` → `SessionModel.startScan`/`analyseAll` — so the measurements are the same
/// numbers by the same path. What practice mode adds is the plan: the block's spot is fixed before a
/// shot is taken, the session saves itself when the analysis ends, and the block is scored with the
/// plan's own pass check rather than a number this screen chose.
struct PracticeBlockView: View {
    let sessionID: UUID
    var practice: PracticeStore
    var doctor: ShotDoctorModel
    var store: SessionStore

    @State private var current: PracticeBlock
    @State private var model = AnalysisModel()
    @State private var session = SessionModel()
    @State private var showCapture = false
    @State private var scanStarted = false
    @State private var finished = false

    init(sessionID: UUID, block: PracticeBlock, practice: PracticeStore,
         doctor: ShotDoctorModel, store: SessionStore) {
        self.sessionID = sessionID
        self.practice = practice
        self.doctor = doctor
        self.store = store
        _current = State(initialValue: block)
    }

    var body: some View {
        List {
            briefSection
            if current.isDone {
                cardSection
            } else {
                recordSection
                if model.clip != nil { analysisSection }
            }
        }
        .navigationTitle("\(PracticeNames.role(current.role)) · \(current.spot.rawValue)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ShotSpeakerToggle(mode: .practice) } }
        .onChange(of: session.lastMeasured?.completionOrder) { _, _ in
            ShotSpeaker.shared.announce(session.lastMeasured, mode: .practice)
        }
        .onAppear {
            // The log is the source of truth: a block scored on an earlier visit shows its card.
            if let stored = practice.session(sessionID)?.blocks.first(where: { $0.id == current.id }) {
                current = stored
            }
            ActivityLog.shared.event("screen", ["name": "practice.block", "role": current.role.rawValue,
                                                "spot": current.spot.rawValue, "done": current.isDone])
        }
        .fullScreenCover(isPresented: $showCapture) {
            CaptureView { recorded in
                showCapture = false
                start(with: recorded)
            }
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .probed, model.calibration == nil, !model.rimFinding {
                Task { await model.findRimAutomatically() }
            }
        }
        .onChange(of: model.calibration != nil) { _, calibrated in
            if calibrated { startScanIfReady() }
        }
        .onChange(of: session.scanning) { _, scanning in
            if !scanning, !session.shots.isEmpty, !session.analysing { session.analyseAll() }
        }
        .onChange(of: session.analysing) { _, analysing in
            guard !analysing, !session.shots.isEmpty else { return }
            // Same second pass as the guided flow: if every clean shot fitted gravity off by the same
            // factor and one of this phone's formats explains it, re-run with that format's lens.
            if !session.lensPassDone,
               let p = LensSelection.propose(current: model.hfovDegrees, gFits: session.gravityFits) {
                ActivityLog.shared.event("lens.proposal", ["current": p.current, "implied": p.impliedHFOV, "medianG": p.medianG, "n": p.n, "match": p.match.hfovDegrees])
                model.hfovDegrees = p.match.hfovDegrees
                model.calibrateRim()
                session.reanalyse(model: model, note: p.explanation)
                return
            }
            finishBlock()
        }
    }

    // MARK: The brief — what to do, and the one cue

    private var briefSection: some View {
        Section {
            LabeledContent("Spot", value: current.spot.rawValue)
            LabeledContent("Shots", value: "\(current.intendedShots)")
            Text(current.instruction).font(.subheadline)
            // When this block was proposed by the day's sequence, it says which number asked for it
            // and what recording it will let ArcLab tell.
            if let p = practice.session(sessionID)?.proposal(forBlock: current.id) {
                Text(p.reason).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text(p.whatItBuys).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let cue = current.cue {
                Label(cue, systemImage: "quote.opening")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
            } else {
                Text("No cue for this block, on purpose: an un-cued block is the only one that can tell you whether a change is yours or the cue's.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(PracticeNames.role(current.role))
        } footer: {
            Text("The cue is a delivery vehicle, not the evidence — the wording itself is unproven. What counts is the measured change, and whether it is still there next session.")
        }
    }

    // MARK: Record

    private var recordSection: some View {
        Section {
            Button {
                showCapture = true
            } label: {
                Label(model.clip == nil ? "Record \(current.intendedShots) shots" : "Record this block again",
                      systemImage: "record.circle")
            }
            .disabled(model.isBusy || session.isBusy)
            let previous = RecordedClip.loadAll().filter(\.fileExists).sorted { $0.recordedAt > $1.recordedAt }
            if !previous.isEmpty, model.clip == nil {
                Menu {
                    ForEach(previous.prefix(10)) { r in
                        Button {
                            start(with: r)
                        } label: {
                            Text(String(format: "%@ · %.0f fps · %.0f s", r.recordedAt.formatted(date: .abbreviated, time: .shortened),
                                        r.measuredNominalFrameRate ?? r.requestedFrameRate, r.durationSeconds ?? 0))
                        }
                    }
                } label: {
                    Label("Use a recording already on the phone (\(previous.count))", systemImage: "clock.arrow.circlepath")
                }
                .disabled(model.isBusy || session.isBusy)
            }
            if let note = current.blockNote {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Record the block")
        } footer: {
            Text("Phone on the tripod at the side, the whole block in one clip. The lens and the frame rate come from the recording, the ring is found on the first frame that shows it, and the block saves itself at \(current.spot.rawValue) when the analysis ends — there is no save button to forget.")
        }
    }

    // MARK: Analysis, streaming

    private var analysisSection: some View {
        let measured = session.shots.filter { $0.row != nil }.count
        let failed = session.shots.filter { if case .failed = $0.status { return true }; return false }.count
        return Section {
            if model.rimFinding {
                busy("Looking for the ring…")
            } else if model.calibration == nil {
                if let note = model.rimFindNote { Text(note).font(.caption).foregroundStyle(.orange) }
                Button { Task { await model.findRimAutomatically() } } label: {
                    Label("Find the ring again", systemImage: "scope")
                }
                NavigationLink { RimMarkingView(model: model) } label: {
                    Label("Mark the ring by hand", systemImage: "circle.dashed")
                }
            } else if session.scanning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(max(session.scanProgress, 0), 1))
                    Text(session.scanMessage ?? "finding every shot in the clip…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let err = session.scanError {
                Text(err).font(.caption).foregroundStyle(.red)
                Button("Try the scan again") { scanStarted = false; startScanIfReady() }
            } else if !session.shots.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if session.analysing {
                        ProgressView(value: Double(measured + failed), total: Double(session.shots.count))
                    }
                    Text("\(session.shots.count) shots found · \(measured) measured · \(session.summary.accepted) counted")
                        .font(.subheadline.bold())
                    if let now = session.shots.first(where: { if case .analyzing = $0.status { return true }; return false }) {
                        Text("Shot \(now.id): \(now.statusDetail ?? "analysing…")").font(.caption).foregroundStyle(.secondary)
                    }
                    if session.analysing, let eta = session.estimatedSecondsRemaining {
                        Text(eta < 90 ? String(format: "about %.0f s left", eta) : String(format: "about %.0f min left", (eta / 60).rounded()))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let body = session.bodyPhase {
                        Text("every shot is measured; form model \(body.done) of \(body.total)…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let line = PracticeFeedback.line(for: session.lastMeasured) {
                        Text(line).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if session.analysing {
                    Button(role: .destructive) { session.cancelAnalysis() } label: { Label("Stop", systemImage: "stop.circle") }
                }
            } else if model.phase == .probing {
                busy("Reading the recording…")
            } else if case .failed(let message) = model.phase {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Analysing the block")
        } footer: {
            Text("A shot counts only when its fitted gravity lands within 8 % of 9.81 and its release is physically possible; the rest are listed with the reason rather than quietly averaged in.")
        }
    }

    // MARK: The block card

    private var cardSection: some View {
        Section {
            if let text = current.measureText {
                Text(text).font(.title3.bold())
            } else if let why = current.measureUnavailableReason {
                Text(why).font(.subheadline).foregroundStyle(.secondary)
            }
            if let c = current.check {
                HStack(spacing: 8) {
                    Image(systemName: verdictIcon(c)).foregroundStyle(verdictColour(c))
                    Text(verdictLabel(c)).font(.subheadline.bold()).foregroundStyle(verdictColour(c))
                }
                Text(c.sentence).font(.caption).foregroundStyle(.secondary)
                if let short = shotsShort(c) {
                    Text("\(short) more shot\(short == 1 ? "" : "s") at this spot before the check can run. Not a fail — not enough shots to tell.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let summary = current.summaryLine {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Saved", value: "\(current.acceptedShots ?? 0) counted of \(current.measuredShots ?? 0) measured, at \(current.spot.rawValue)")
                .font(.caption)
            if let id = current.savedSessionID, store.sessions.contains(where: { $0.id == id }) {
                NavigationLink { EditSessionView(store: store, sessionID: id) } label: {
                    Label("Open the saved block", systemImage: "list.number")
                }
            }
            // What follows from what this block just measured. The engine has already proposed it
            // (`finishBlock`), so there is always something here — a block, or the day's last word
            // and tomorrow's first block.
            if let action = practice.nextAction, practice.todaysSession?.id == sessionID {
                PracticeNextCard(action: action)
                if let next = nextBlock {
                    NavigationLink {
                        PracticeBlockView(sessionID: sessionID, block: next, practice: practice,
                                          doctor: doctor, store: store)
                    } label: {
                        Label("Go to that block", systemImage: "play.circle.fill")
                    }
                }
            } else {
                Text("That was the last block of the session.").font(.subheadline)
            }
        } header: {
            Text("Block card")
        } footer: {
            Text("Everything here is associated with the change, never caused by it, and every number carries the number of shots it came from. There is no universal target: the comparison is against your own earlier block.")
        }
    }

    private var nextBlock: PracticeBlock? {
        guard let s = practice.session(sessionID),
              let i = s.blocks.firstIndex(where: { $0.id == current.id }), i + 1 < s.blocks.count else { return nil }
        return s.blocks[i + 1]
    }

    private func shotsShort(_ c: PracticeCheck) -> Int? {
        guard c.passed == nil, let n = c.n,
              let progress = doctor.planProgress else { return nil }
        let need = progress.package.passCheck.minimumN
        return n < need ? need - n : nil
    }

    private func verdictLabel(_ c: PracticeCheck) -> String {
        switch (c.kind, c.passed) {
        case ("retention", .some(true)): return "The change held"
        case ("retention", .some(false)): return "Practised, not learned"
        case ("retention", .none): return "Not enough to judge retention yet"
        case (_, .some(true)): return "Passed"
        case (_, .some(false)): return "Not yet"
        default: return "Cannot tell yet"
        }
    }

    private func verdictIcon(_ c: PracticeCheck) -> String {
        switch c.passed {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "arrow.uturn.left.circle"
        case .none: return "questionmark.circle"
        }
    }

    private func verdictColour(_ c: PracticeCheck) -> Color {
        switch c.passed {
        case .some(true): return .green
        case .some(false): return .orange
        case .none: return .secondary
        }
    }

    // MARK: Driving the models

    private func start(with recorded: RecordedClip) {
        finished = false
        scanStarted = false
        session.reset()
        var b = current
        b.recordingFile = recorded.movieFileName
        b.blockNote = nil
        current = b
        practice.replace(b, in: sessionID)
        // A proposed block is accepted when it is actually being shot, not when it is read.
        practice.markProposalAccepted(blockID: current.id, in: sessionID)
        ActivityLog.shared.event("practice.block.start", [
            "role": current.role.rawValue, "spot": current.spot.rawValue,
            "intended": current.intendedShots, "file": recorded.movieFileName,
            "fps": recorded.measuredNominalFrameRate ?? recorded.requestedFrameRate,
        ])
        model.useRecordedClip(recorded)
    }

    private func startScanIfReady() {
        guard model.calibration != nil, model.clip != nil, session.shots.isEmpty,
              !session.isBusy, !scanStarted else { return }
        scanStarted = true
        session.startScan(model: model)
    }

    /// The analysis has finished: save the block at its own spot, score it against the plan, and
    /// write both back into the practice log. No save button, so nothing can be lost by walking away.
    private func finishBlock() {
        guard !finished else { return }
        let measured = session.shots.filter { $0.row != nil }.count
        guard measured > 0 else {
            var b = current
            b.blockNote = "Nothing in that recording could be measured: \(session.shots.count) window(s) found, none of them produced numbers. The block is not saved — record it again rather than count a block that has no shots in it."
            current = b
            practice.replace(b, in: sessionID)
            finished = true
            return
        }
        finished = true
        let clipName = model.clip?.url.lastPathComponent ?? session.clipURLName
        let saved = store.save(session: session, spot: current.spot,
                               note: "practice block: \(current.role.rawValue)",
                               clipName: clipName, hfovDegrees: model.hfovDegrees,
                               clipFingerprint: model.clipFingerprint)
        ActivityLog.shared.event("practice.block.saved", [
            "role": current.role.rawValue, "spot": current.spot.rawValue,
            "sessionID": saved.id.uuidString, "measured": measured, "accepted": saved.accepted,
            "intended": current.intendedShots,
        ])
        let earlier = earlierDrillSession()
        let scored = practice.scored(current, saved: saved, measuredShots: measured,
                                     doctor: doctor, earlierDrillSession: earlier)
        current = scored
        practice.replace(scored, in: sessionID)
        // Let the plan record which sessions its check and retention actually used.
        doctor.recordPlanSessions()
        // The day is a sequence: propose the next block from what this one measured, immediately.
        practice.refreshProposal(doctor: doctor)
    }

    /// The first drill block of this practice session that has already been saved — what a retention
    /// block is compared against when the plan has no follow-up session of its own yet.
    private func earlierDrillSession() -> SavedSession? {
        guard let s = practice.session(sessionID) else { return nil }
        for b in s.blocks where b.role == .drill && b.id != current.id {
            if let id = b.savedSessionID, let saved = store.sessions.first(where: { $0.id == id }) { return saved }
        }
        return nil
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 12) { ProgressView(); Text(text).font(.footnote).foregroundStyle(.secondary) }
    }
}

// MARK: - The feedback line

/// The one sentence a shooter reads while the block is still being analysed. Same shape as the
/// guided flow's line; kept here so practice mode owns its own copy of the wording.
enum PracticeFeedback {
    static func line(for shot: SessionShot?) -> String? {
        guard let shot, let row = shot.row else { return nil }
        let speed = row.releaseSpeed.map { String(format: "%.2f m/s", $0) } ?? "speed not measured"
        let angle = row.releaseAngleDegrees.map { String(format: " at %.0f°", $0) } ?? ""
        let depth = row.depthPastFrontRim.map { d -> String in
            if d > 0.28 { return String(format: ", %.0f cm long of the make band", (d - 0.28) * 100) }
            if d < 0.25 { return String(format: ", %.0f cm short of the make band", (0.25 - d) * 100) }
            return ", in the make band"
        } ?? ""
        return "Shot \(shot.id): \(row.verdict.label) — \(speed)\(angle)\(depth)"
    }
}
