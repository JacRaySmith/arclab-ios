import PhotosUI
import ShotGeometry
import SwiftUI

/// The product path: pick a video, say where you were shooting from, confirm the ring, and everything
/// else runs by itself — timing defaults, the whole-clip scan, every shot's analysis, the save — until
/// the session screen has numbers and a coaching card. The numbered step-by-step flow on the home
/// screen stays as the advanced route; this view drives exactly the same models, so the measurements
/// are identical.
struct GuidedSessionView: View {
    @Bindable var model: AnalysisModel
    @Bindable var session: SessionModel
    var store: SessionStore
    @State private var selection: PhotosPickerItem?
    @State private var autoStarted = false
    @State private var autoRimTried = false
    @State private var rimConfirmed = false
    /// The spot, asked before the rim and kept for next time. Empty until the shooter has ever chosen one.
    @AppStorage("guided.lastSpot") private var lastSpotRaw: String = ""
    @State private var spot: ShotSpot?
    /// The shooter's own release-speed band at this spot, from the sessions already saved. Read once
    /// when the spot is chosen, not on every row the feed draws.
    @State private var band: SpeedBand?
    @State private var showEveryNumber = false
    @Environment(\.scenePhase) private var scenePhase

    private enum Stage: Int, Comparable {
        case video, spot, rim, analysing, done
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    private var stage: Stage {
        if model.clip == nil || model.probe == nil { return .video }
        if spot == nil { return .spot }
        if model.calibration == nil { return .rim }
        // Once the scan has started the rim step is behind us: coming back to this screen mid-analysis
        // must not put the ring back in the shooter's way.
        if !rimConfirmed, session.shots.isEmpty, !session.isBusy { return .rim }
        if session.shots.isEmpty || session.isBusy || session.shots.contains(where: { if case .queued = $0.status { return true }; return false }) {
            return .analysing
        }
        return .done
    }

    var body: some View {
        List {
            videoSection
            if stage >= .spot { spotSection }
            if stage >= .rim { rimSection }
            if stage >= .analysing { analysisSection }
            if stage == .done { resultsSection }
        }
        .onAppear { ActivityLog.shared.event("screen", ["name": "guided"]) }
        .navigationTitle("Analyze a session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ShotSpeakerToggle(mode: .guided) } }
        .onChange(of: session.lastMeasured?.completionOrder) { _, _ in
            ShotSpeaker.shared.announce(session.lastMeasured, mode: .guided)
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            session.reset()
            autoStarted = false
            autoRimTried = false
            rimConfirmed = false
            model.importAndProbe(item)
        }
        .onChange(of: model.phase) { _, phase in
            // The filming guide says slo-mo, so a file that looks like a slo-mo export is treated as
            // one (4×) without asking. The gravity check catches a wrong factor: it comes back 4× or ¼ off.
            if phase == .probed, model.sloMoSuspected, !model.isSloMo { model.setSloMo(true) }
            // The ring is looked for as soon as the clip is readable, whether or not the spot has been
            // answered yet, so step 3 usually arrives already drawn.
            if phase == .probed { findRimIfNeeded() }
        }
        .onChange(of: spot) { _, chosen in
            guard let chosen else { return }
            lastSpotRaw = chosen.rawValue
            band = SpeedBand.from(store.pooled(at: chosen).summary.releaseSpeed, spot: chosen)
            ActivityLog.shared.event("session.spot", ["spot": chosen.rawValue, "band": band != nil,
                                                      "bandN": band?.n, "bandMean": band?.mean, "bandSD": band?.sd])
            findRimIfNeeded()
        }
        .onChange(of: model.calibration != nil) { _, calibrated in
            if !calibrated { rimConfirmed = false }
        }
        .onChange(of: rimConfirmed) { _, confirmed in
            if confirmed { startIfReady() }
        }
        .onChange(of: session.scanning) { _, scanning in
            if !scanning, !session.shots.isEmpty, !session.analysing, !session.pausedByInterruption { session.analyseAll() }
        }
        .onChange(of: session.analysing) { _, analysing in
            guard !analysing else { return }
            // After the first pass: if every clean shot fitted gravity off by one and the same scale factor,
            // and exactly one of this phone's video formats explains it, re-run with that format's lens.
            if !session.lensPassDone, !session.shots.isEmpty,
               let p = LensSelection.propose(current: model.hfovDegrees, gFits: session.gravityFits) {
                ActivityLog.shared.event("lens.proposal", ["current": p.current, "implied": p.impliedHFOV, "medianG": p.medianG, "n": p.n, "match": p.match.hfovDegrees])
                model.hfovDegrees = p.match.hfovDegrees
                model.calibrateRim()
                rimConfirmed = true
                session.reanalyse(model: model, note: p.explanation)
                return
            }
            logBandwidth()
            autoSaveIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS stops the video decoder when the app is not on screen (−11847). Coming back is the
            // signal to carry on with whatever was left queued; nothing measured is redone.
            guard phase == .active else { return }
            session.resumeAfterInterruption(model: model)
        }
        .onAppear {
            if spot == nil, let remembered = ShotSpot(rawValue: lastSpotRaw) { spot = remembered }
            if session.isBusy || !session.shots.isEmpty { rimConfirmed = true }
            startIfReady()
            // Coming back to a block that finished or was paused while this screen was not on top:
            // carry on, or save what finished. Neither happens twice — both are guarded.
            session.resumeAfterInterruption(model: model)
            autoSaveIfNeeded()
        }
    }

    private func startIfReady() {
        guard model.calibration != nil, model.clip != nil, rimConfirmed, spot != nil,
              session.shots.isEmpty, !session.isBusy, !autoStarted else { return }
        autoStarted = true
        session.startScan(model: model)
    }

    private func findRimIfNeeded() {
        guard model.calibration == nil, model.clip != nil, !model.rimFinding, !autoRimTried else { return }
        autoRimTried = true
        Task { await model.findRimAutomatically() }
    }

    // MARK: 1 — the video

    private var videoSection: some View {
        Section {
            if let clip = model.clip, let p = model.probe {
                Label(clip.url.lastPathComponent, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(String(format: "%d × %d, %.0f fps in the file, %.0f s of file time%@, lens %.0f°", p.width, p.height, p.measuredFrameRate,
                            model.fileDuration, model.isSloMo ? String(format: ", treated as %.0f× slow motion", model.timeScale) : ", real time", model.hfovDegrees))
                    .font(.caption).foregroundStyle(.secondary)
                if let note = model.probeRetryNote {
                    Label(note, systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
                }
                if clip.source == .recordedInApp {
                    Text("Recorded in ArcLab: frame rate and lens read from the recording, nothing to set.").font(.caption).foregroundStyle(.green)
                }
                if model.sloMoSuspected {
                    Toggle("Filmed in slow motion", isOn: Binding(get: { model.isSloMo }, set: { model.setSloMo($0) }))
                        .font(.subheadline)
                        .disabled(session.isBusy)
                }
                PhotosPicker(selection: $selection, matching: .videos, photoLibrary: .shared()) {
                    Label("Pick a different video", systemImage: "film")
                }
                .disabled(model.isBusy || session.isBusy)
            } else {
                NavigationLink {
                    CaptureView { recorded in
                        session.reset()
                        autoStarted = false
                        autoRimTried = false
                        rimConfirmed = false
                        model.useRecordedClip(recorded)
                    }
                } label: {
                    Label("Record a session now", systemImage: "record.circle")
                }
                .disabled(model.isBusy)
                PhotosPicker(selection: $selection, matching: .videos, photoLibrary: .shared()) {
                    Label("Pick a video from Photos", systemImage: "film")
                }
                .disabled(model.isBusy)
                let previous = RecordedClip.loadAll().filter(\.fileExists).sorted { $0.recordedAt > $1.recordedAt }
                if !previous.isEmpty {
                    Menu {
                        ForEach(previous) { r in
                            Button {
                                session.reset(); autoStarted = false; autoRimTried = false; rimConfirmed = false
                                model.useRecordedClip(r)
                            } label: {
                                Text(String(format: "%@ · %.0f fps · %.0f s", r.recordedAt.formatted(date: .abbreviated, time: .shortened),
                                            r.measuredNominalFrameRate ?? r.requestedFrameRate, r.durationSeconds ?? 0))
                            }
                        }
                    } label: {
                        Label("Use an earlier recording (\(previous.count))", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(model.isBusy)
                }
                if model.phase == .importing { busy("Copying the video…") }
                if model.phase == .probing { busy("Reading the clip's timestamps to learn its real frame rate…") }
                if model.phase == .probed, let earlier = store.sessions(fromClip: model.clipFingerprint).first {
                    // The same video again. Analysing it a second time gives the same numbers and a
                    // duplicate on Progress, so the saved session is one tap away; re-analysing stays possible.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("You analysed this video on \(earlier.date.formatted(date: .abbreviated, time: .shortened)) — \(earlier.accepted) accepted shots, saved as \(earlier.spot.rawValue).",
                              systemImage: "clock.arrow.circlepath")
                            .font(.footnote)
                        NavigationLink { EditSessionView(store: store, sessionID: earlier.id) } label: {
                            Label("Open that session", systemImage: "folder")
                        }
                        Text("Continuing below analyses it again and would add a second copy to Progress.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if case .failed(let message) = model.phase { Text(message).font(.caption).foregroundStyle(.red) }
            }
            ShooterHeightRow(detailed: true)
        } header: {
            Text("1 · Video")
        } footer: {
            if model.clip == nil {
                Text("One clip, one spot, the phone on a tripod at the side. Recording in the app fixes the lens and the frame rate for you. Everything runs on this phone; nothing is uploaded.")
            }
        }
    }

    // MARK: 2 — the spot, before anything is measured

    /// Asked here rather than at save time: a session whose spot is known can be saved the moment it
    /// finishes, and the shots pool into the right cell without anyone remembering to do it. Shots
    /// from different distances are never pooled, so this is not a detail the app may guess.
    private var spotSection: some View {
        Section {
            Picker("Where are you shooting from?", selection: $spot) {
                Text("Choose…").tag(ShotSpot?.none)
                ForEach(ShotSpot.allCases) { Text($0.rawValue).tag(ShotSpot?.some($0)) }
            }
            .pickerStyle(.menu)
            .disabled(session.isBusy)
            if let spot, let band {
                Text(String(format: "Your band at %@: %.2f ± %.2f m/s over %d accepted shots already saved.",
                            spot.rawValue, band.mean, band.sd, band.n))
                    .font(.caption).foregroundStyle(.secondary)
            } else if spot != nil {
                Text("No band yet at this spot: below \(SpeedBand.minimumShots) accepted saved shots the feed shows every number.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("2 · The spot")
        } footer: {
            if spot == nil {
                Text("Pick it honestly. The statistics pool per spot and never across spots, and this is remembered for next time.")
            }
        }
    }

    // MARK: 3 — the rim, drawn on the frame

    private var rimSection: some View {
        Section {
            if let cal = model.calibration, let clip = model.clip {
                RimPreviewCard(clipURL: clip.url, frameTime: model.rimFrameTime ?? 0, calibration: cal)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                Label(String(format: "Rim found · %.1f m away", cal.distanceToRim), systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(.green)
                ForEach(cal.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.orange)
                }
                if !rimConfirmed {
                    Button { rimConfirmed = true } label: { Label("Looks right", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                }
                NavigationLink { RimMarkingView(model: model) } label: {
                    Label("Adjust", systemImage: "circle.dashed")
                }
                .disabled(session.isBusy)
                if let note = model.rimFindNote {
                    DisclosureGroup("How the ring was found") {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                        Text("The ring's 45.7 cm is the ruler for every distance in this session.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            } else if model.rimFinding {
                HStack(spacing: 10) { ProgressView(); Text("Looking for the ring…").font(.subheadline) }
            } else {
                Button {
                    Task { await model.findRimAutomatically() }
                } label: {
                    Label("Find the ring again", systemImage: "scope")
                }
                .disabled(model.isBusy)
                if let note = model.rimFindNote { Text(note).font(.caption).foregroundStyle(.orange) }
                NavigationLink { RimMarkingView(model: model) } label: {
                    Label("Mark the rim by hand", systemImage: "circle.dashed")
                }
                if let err = model.calibrationError { Text(err).font(.caption).foregroundStyle(.red) }
            }
        } header: {
            Text("3 · Rim")
        }
    }

    // MARK: 4 — analysis, hands off

    private var analysisSection: some View {
        let measured = session.shots.filter { $0.row != nil }.count
        let accepted = session.summary.accepted
        return Section {
            if session.pausedByInterruption {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Paused — iOS stops video decoding when ArcLab is not on screen.", systemImage: "pause.circle")
                        .font(.subheadline).foregroundStyle(.orange)
                    Text("\(measured) shot\(measured == 1 ? "" : "s") already measured are kept. The rest carry on when you come back to this screen.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { session.resumeAfterInterruption(model: model) } label: {
                        Label("Carry on now", systemImage: "play.circle")
                    }
                }
            } else if session.scanning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(max(session.scanProgress, 0), 1))
                    Text(session.scanMessage ?? "finding every shot in the clip…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let err = session.scanError {
                Text(err).font(.caption).foregroundStyle(.red)
                Button("Try the scan again") { autoStarted = false; startIfReady() }
            } else if !session.shots.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if session.analysing {
                        ProgressView(value: Double(measured + session.shots.filter { if case .failed = $0.status { return true }; return false }.count),
                                     total: Double(session.shots.count))
                        Text(progressLine(measured: measured)).font(.subheadline.bold())
                    } else {
                        Text("\(session.shots.count) shots found · \(measured) measured · \(accepted) accepted")
                            .font(.subheadline.bold())
                    }
                    if let body = session.bodyPhase {
                        Text("every shot is measured; form model \(body.done) of \(body.total)…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ShotFeedView(shots: session.shots, band: band, showEveryNumber: $showEveryNumber)
                if session.analysing {
                    Button(role: .destructive) { session.cancelAnalysis() } label: { Label("Stop", systemImage: "stop.circle") }
                } else if session.shots.contains(where: { if case .queued = $0.status { return true }; return false }) {
                    Button { session.analyseAll() } label: { Label("Continue analysing", systemImage: "play.circle") }
                }
            } else {
                Button { autoStarted = false; startIfReady() } label: { Label("Find and analyse every shot", systemImage: "magnifyingglass") }
            }
        } header: {
            Text("4 · Analysis")
        } footer: {
            if session.analysing {
                Text("A shot counts only when its fitted gravity is within 8 % of 9.81 and its release is physically possible. Tap a row for its numbers and, where it was not counted, the reason.")
            }
        }
    }

    private func progressLine(measured: Int) -> String {
        let eta = session.estimatedSecondsRemaining
        let left = eta.map { $0 < 90 ? String(format: " · about %.0f s left", $0) : String(format: " · about %.0f min left", ($0 / 60).rounded()) } ?? ""
        return "Shot \(min(measured + 1, session.shots.count)) of \(session.shots.count)\(left)"
    }

    // MARK: 5 — results, already saved

    private var resultsSection: some View {
        let s = session.summary
        let card = session.coaching
        return Section {
            if let id = session.savedSessionID, store.sessions.contains(where: { $0.id == id }) {
                HStack {
                    Label("Saved as \(session.savedSpot?.rawValue ?? spot?.rawValue ?? "this spot")", systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.green)
                    Spacer()
                    Button("Undo") { undoSave() }
                        .font(.subheadline)
                }
            } else if session.savedSessionID == nil, session.shots.contains(where: { $0.row != nil }) {
                Label("Not saved. The session screen can save it.", systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.orange)
            }
            NavigationLink {
                SessionView(model: model, session: session, store: store)
            } label: {
                Label("Open the session: every shot, the rim map, the coaching card", systemImage: "list.number")
            }
            LabeledContent("Counted", value: "\(s.accepted) of \(s.tracked) measured shots")
            LabeledContent("Release speed", value: s.releaseSpeed.map { $0.text(unit: "m/s", decimals: 2) } ?? "not measured")
            LabeledContent("Entry angle", value: s.entryAngleDegrees.map { $0.text(unit: "°", decimals: 1) } ?? "not measured")
            if let first = card.says.first {
                Text(first.text).font(.footnote)
            } else if let why = card.saysEmptyReason {
                Text(why).font(.footnote).foregroundStyle(.secondary)
            }
            if case .collectingBaseline(let n, let needed) = card.workOn {
                Text("Baseline: \(n) of \(needed) accepted shots at this spot before a finding is allowed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("5 · Results")
        }
    }

    // MARK: Saving, without being asked

    /// Saved the moment the block finishes, with the spot chosen at the start. A session left unsaved
    /// is a session that never reaches the 30-shot floor, and the floor is where every finding lives.
    /// Only a **shot session** is written here; a form clip has its own screen and its own door.
    private func autoSaveIfNeeded() {
        guard let spot, session.savedSessionID == nil, !session.pausedByInterruption, !session.isBusy else { return }
        let measured = session.shots.filter { $0.row != nil }.count
        guard measured > 0 else { return }
        guard !session.shots.contains(where: { if case .queued = $0.status { return true }; return false }) else { return }
        let saved = store.save(session: session, spot: spot, note: "", clipName: session.clipURLName,
                               hfovDegrees: model.hfovDegrees, clipFingerprint: model.clipFingerprint)
        session.savedSessionID = saved.id
        session.savedSpot = spot
        ActivityLog.shared.event("session.autosaved", ["spot": spot.rawValue, "measured": measured,
                                                       "accepted": saved.accepted, "id": saved.id.uuidString])
    }

    private func undoSave() {
        guard let id = session.savedSessionID else { return }
        store.delete(id)
        session.savedSessionID = nil
        session.savedSpot = nil
        ActivityLog.shared.event("session.autosave.undone", ["id": id.uuidString])
    }

    /// How often the shooter's own band hid a number, for the record. Bandwidth feedback is grade B,
    /// and the counts are what would tell us later whether it was used or switched off.
    private func logBandwidth() {
        let counts = ShotFeedView.bandwidthCounts(shots: session.shots, band: band)
        ActivityLog.shared.event("feed.bandwidth", ["inside": counts.inside, "outside": counts.outside,
                                                    "withSpeed": counts.withSpeed, "hasBand": band != nil,
                                                    "bandN": band?.n, "showEveryNumber": showEveryNumber,
                                                    "spot": spot?.rawValue])
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 12) { ProgressView(); Text(text).font(.footnote).foregroundStyle(.secondary) }
    }
}
