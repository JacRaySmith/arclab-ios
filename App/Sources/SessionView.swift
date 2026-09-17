import ShotGeometry
import ShotVideo
import SwiftUI

/// The session screen: what this block of shots did, in the order a shooter reads it.
///
/// The rim map first — one dot per accepted shot, which is the most instantly readable thing the app
/// produces — then the three numbers a session is read by, then the one sentence the coaching card
/// leads with. Everything else (release angle, height, the scale check, the body model, the charts,
/// the provenance, the scan controls) is a disclosure, present and one tap away. Nothing was deleted
/// to make this shorter, and no unavailable measure lost its reason.
struct SessionView: View {
    @Bindable var model: AnalysisModel
    @Bindable var session: SessionModel
    var store: SessionStore? = nil
    @State private var saveSpot: ShotSpot? = nil
    @State private var saveNote = ""
    @State private var savedID: UUID?

    var body: some View {
        List {
            if session.shots.isEmpty || session.isBusy { scanSection }
            if !session.shots.isEmpty {
                heroSection
                tilesSection
                shotsSection
                moreSection
                ShotProfileView(profile: session.coaching.profile)
            }
            if store != nil, session.shots.contains(where: { $0.row != nil }) { saveSection }
        }
        .onAppear {
            ActivityLog.shared.event("screen", ["name": "session", "shots": session.shots.count])
            if saveSpot == nil { saveSpot = session.savedSpot }
            if savedID == nil { savedID = session.savedSessionID }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: The hero — where the shots crossed the ring

    private var heroSection: some View {
        Section {
            SessionRimMapView(rows: session.summary.rows, ballDiameter: BallSize.size7.diameter)
        } header: {
            Text("Where your shots crossed the ring")
        }
    }

    // MARK: The three numbers, then one sentence

    private var tilesSection: some View {
        let card = session.coaching
        return Section {
            SessionSummaryTiles(summary: session.summary)
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            if let first = card.says.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(first.text).font(.subheadline)
                    DisclosureGroup("Why?") {
                        Text(first.provenance).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("The bands on the tiles describe where measured shooters sat. They are not targets, and \"fewer numbers on the first screen\" is a readability decision with no sport-science support behind it.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let why = card.saysEmptyReason {
                Text(why).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("\(session.summary.accepted) of \(session.summary.tracked) measured shots counted")
        }
    }

    // MARK: Everything else, collapsed

    private var moreSection: some View {
        let s = session.summary
        return Section {
            DisclosureGroup("Every number") {
                HStack(spacing: 18) {
                    count("windows", s.windows)
                    count("tracked", s.tracked)
                    count("accepted", s.accepted)
                    if s.failed > 0 { count("failed", s.failed) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                stat("Release angle", s.releaseAngleDegrees, "°", 1, s.unavailableReason(for: s.releaseAngleDegrees, geometry: true))
                stat("Release height", s.releaseHeight, "m", 2, s.unavailableReason(for: s.releaseHeight, geometry: true))
                stat("Release speed", s.releaseSpeed, "m/s", 2, s.unavailableReason(for: s.releaseSpeed, geometry: true))
                stat("Entry angle", s.entryAngleDegrees, "°", 1, s.unavailableReason(for: s.entryAngleDegrees, geometry: true))
                stat("Depth past front rim", s.depthPastFrontRim.map { BlockStat(mean: $0.mean * 100, sd: $0.sd.map { $0 * 100 }, n: $0.n) },
                     "cm", 1, s.unavailableReason(for: s.depthPastFrontRim, geometry: true))
                scaleCheckRow(s)
                HStack(spacing: 18) {
                    count("make", s.makes)
                    count("miss", s.misses)
                    count("unknown", s.unknownOutcomes)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Outcomes are inferred from the ball's behaviour at the rim, not from a scorer; a shot whose outcome was not seen stays unknown.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(s.provenance).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)

            DisclosureGroup("Body") { bodyGroup(s) }
                .font(.subheadline)

            DisclosureGroup("Shot by shot, in clip order") { stripContent }
                .font(.subheadline)

            formRow

            DisclosureGroup("What this session says") { coachingContent }
                .font(.subheadline)

            if let scan = session.scan, !scan.notes.isEmpty {
                DisclosureGroup("How the windows were found") { provenanceContent(scan) }
                    .font(.subheadline)
            }

            if !session.shots.isEmpty {
                DisclosureGroup("The scan and the analyzer") { scanControls }
                    .font(.subheadline)
            }
        } header: {
            Text("More")
        }
    }

    /// g is the check, not an input (CLAUDE.md §3). What a shooter needs from it is whether the scale
    /// held, so that is what it says; the fitted number itself is on the same row.
    @ViewBuilder private func scaleCheckRow(_ s: BlockSummary) -> some View {
        if let g = s.gFit {
            let offBy = abs(g.mean - Court.g) / Court.g * 100
            let ok = offBy <= 8
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Scale check").font(.subheadline)
                    Spacer()
                    Label(String(format: "%@ within %.1f %%", ok ? "✓" : "✗", offBy), systemImage: ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(ok ? .green : .orange)
                }
                Text(String(format: "Fitted gravity over the accepted shots is %@ against 9.81 m/s². It is never an input to the fit — it is how the app checks that the ring's 45.7 cm, the frame rate and the lens agree.",
                            g.text(unit: "m/s²", decimals: 2)))
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            stat("Scale check", nil, "m/s²", 2, s.unavailableReason(for: s.gFit, geometry: true))
        }
    }

    // MARK: Scan

    @ViewBuilder private var scanSection: some View {
        Section {
            if session.scanning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: min(max(session.scanProgress, 0), 1))
                    Text(session.scanMessage ?? "scanning…").font(.caption).foregroundStyle(.secondary)
                    Button(role: .destructive) { session.cancelScan() } label: {
                        Label("Stop the scan", systemImage: "stop.circle")
                    }
                }
            } else {
                scanControls
            }
            if let err = session.scanError { Text(err).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Scan")
        } footer: {
            if session.shots.isEmpty {
                Text("A shot is a ball arriving at the rim. The scan measures nothing — it only says where to point the analyzer.")
            }
        }
    }

    @ViewBuilder private var scanControls: some View {
        if session.pausedByInterruption {
            Label(SessionModel.pauseMessage, systemImage: "pause.circle")
                .font(.caption).foregroundStyle(.orange)
            Button { session.resumeAfterInterruption(model: model) } label: {
                Label("Carry on", systemImage: "play.circle")
            }
        }
        Toggle("Only scan the start of the clip", isOn: $session.limitScan)
        if session.limitScan {
            LabeledContent("Scan the first") {
                HStack {
                    TextField("seconds", value: $session.scanLimitSeconds, format: .number.precision(.fractionLength(0)))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
                    Text("s of file time").foregroundStyle(.secondary)
                }
            }
        }
        Button {
            session.startScan(model: model)
        } label: {
            Label(session.shots.isEmpty ? "Find every shot in the clip" : "Scan again", systemImage: "magnifyingglass")
        }
        .disabled(model.clip == nil || model.calibration == nil || session.isBusy)
        if let scan = session.scan {
            LabeledContent("Windows found", value: "\(scan.windows.count)")
            LabeledContent("Scanned", value: String(format: "%.0f–%.0f s of file time, %d frames",
                                                    scan.scanned.lowerBound, scan.scanned.upperBound, scan.framesScanned))
        }
        if !session.shots.isEmpty {
            if session.analysing {
                Button(role: .destructive) { session.cancelAnalysis() } label: {
                    Label("Stop analysing", systemImage: "stop.circle")
                }
            } else {
                Button { session.analyseAll() } label: { Label("Analyze every shot", systemImage: "function") }
                    .disabled(session.isBusy)
                if session.shots.contains(where: { if case .failed = $0.status { return true }; return false }) {
                    Button { session.analyseAll(redoFailed: true) } label: {
                        Label("Retry the failed windows", systemImage: "arrow.clockwise")
                    }
                    .disabled(session.isBusy)
                }
            }
        }
    }

    // MARK: Rows the disclosures reuse

    /// Mean ± SD n of the body model over the block, then the 2-D angles it sits beside.
    ///
    /// Same rule as the 2-D pose angles: every shot that produced a body model is counted, accepted or
    /// not, because the body model does not depend on the shot-plane solve. The copy is descriptive —
    /// these are associated with how a shot is built, and there is no target drawn anywhere.
    @ViewBuilder private func bodyGroup(_ s: BlockSummary) -> some View {
        stat("Elbow at release (fitted)", s.fittedElbowAtReleaseDegrees, "°", 0, s.bodyUnavailableReason(for: s.fittedElbowAtReleaseDegrees))
        stat("Knee, deepest bend (fitted)", s.fittedKneeMinimumDegrees, "°", 0, s.bodyUnavailableReason(for: s.fittedKneeMinimumDegrees))
        stat("Elbow extension, peak speed", s.elbowExtensionPeakDegreesPerSecond, "°/s", 0, s.bodyUnavailableReason(for: s.elbowExtensionPeakDegreesPerSecond))
        stat("Knee extension, peak speed", s.kneeExtensionPeakDegreesPerSecond, "°/s", 0, s.bodyUnavailableReason(for: s.kneeExtensionPeakDegreesPerSecond))
        stat("Rhythm (lowest wrist → release)", s.bodyDipToReleaseMilliseconds, "ms", 0, s.bodyUnavailableReason(for: s.bodyDipToReleaseMilliseconds))
        stat("Dip depth, of your own height", s.dipDepthNormalised, "", 3, s.bodyUnavailableReason(for: s.dipDepthNormalised))
        stat("Head steadiness, of your own height", s.headStabilityNormalised, "", 4, s.bodyUnavailableReason(for: s.headStabilityNormalised))
        stat("Hands found near release", s.handRateAtRelease, "", 2, s.bodyUnavailableReason(for: s.handRateAtRelease))
        stat("Jump height", s.jumpHeightMetres, "m", 2, s.bodyUnavailableReason(for: s.jumpHeightMetres))
        stat("Dip depth", s.dipDepthMetres, "m", 2, s.bodyUnavailableReason(for: s.dipDepthMetres))
        if let p = s.proximalToDistal {
            LabeledContent("Drive from the ground up") {
                Text("\(p.yes) of \(p.n) shots").font(.subheadline.monospaced())
            }
            .font(.subheadline)
            Text(String(format: "How often knee → hip → shoulder → elbow → wrist came out in that order. It is a pattern, not a score, and the gaps between the peaks are not shown as numbers: one sampled frame is %@ of real time, which is the resolution under all of them.",
                        s.chainFrameFloorMilliseconds.map { String(format: "%.0f ms", $0) } ?? "the video's frame interval"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        if let note = s.metrePoolingNote {
            Label(note, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
        }
        if ShooterProfile.heightCm == nil {
            Text("Metres are unavailable: \(ShooterProfile.missingReason). Add it below, then analyse again, for jump height and dip depth in metres.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        ShooterHeightRow()
        Text(String(format: "One skeleton fitted per shot to the camera-side 2-D joints%@. Angles are associated with how the shot is built; nothing here is scored against a target, and an absolute angle from a single camera is only good to about ±25°, so the spread from shot to shot is the readable part. The two numbers 'of your own height' are divided by your ankle-to-nose pixel span, which is what lets them be compared after the camera moves — the pixel versions are on each shot's own card.",
                    s.fittedElbowJitterDegrees.map { String(format: ", moving %.1f° between sampled frames", $0) } ?? ""))
            .font(.caption2).foregroundStyle(.secondary)
        Divider()
        Text("2-D, camera side").font(.caption.bold()).foregroundStyle(.secondary)
        stat("Elbow at release", s.elbowAtReleaseDegrees, "°", 0, s.unavailableReason(for: s.elbowAtReleaseDegrees, geometry: false))
        stat("Elbow, most extended near release", s.elbowMaxNearReleaseDegrees, "°", 0, s.unavailableReason(for: s.elbowMaxNearReleaseDegrees, geometry: false))
        stat("Knee, deepest bend", s.kneeMinimumDegrees, "°", 0, s.unavailableReason(for: s.kneeMinimumDegrees, geometry: false))
        Text("2-D image-plane angles of the limb facing the camera. They equal the true joint angle only when the limb lies in the image plane, so they are comparable within this camera position and nowhere else. Every shot that produced an angle is counted, accepted or not: these do not depend on the shot-plane solve.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func count(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(n)").font(.title3.monospaced().bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ stat: BlockStat?, _ unit: String, _ decimals: Int, _ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(stat.map { $0.text(unit: unit, decimals: decimals) } ?? "not measured")
                    .font(stat == nil ? .subheadline.italic() : .subheadline.monospaced())
                    .foregroundStyle(stat == nil ? .secondary : .primary)
            }
            if stat == nil {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Strip charts

    @ViewBuilder private var stripContent: some View {
        let s = session.summary
        let rowsByID = Dictionary(uniqueKeysWithValues: s.rows.map { ($0.id, $0) })
        let points = { (key: @escaping (BlockRow) -> Double?) -> [ShotStripChartView.Point] in
            session.shots.map { shot in
                let row = rowsByID[shot.id]
                return ShotStripChartView.Point(id: shot.id, value: row.flatMap(key), accepted: row?.verdict.isAccepted ?? false)
            }
        }
        ShotStripChartView(title: "Release speed", unit: "m/s", decimals: 2,
                           points: points { $0.releaseSpeed }, stat: s.releaseSpeed,
                           unavailableReason: s.unavailableReason(for: s.releaseSpeed, geometry: true))
        ShotStripChartView(title: "Release angle", unit: "°", decimals: 1,
                           points: points { $0.releaseAngleDegrees }, stat: s.releaseAngleDegrees,
                           unavailableReason: s.unavailableReason(for: s.releaseAngleDegrees, geometry: true))
        Text("Filled marks are shots the block rule accepted; hollow marks are measured shots it left out. The dashed line is this block's own mean and the band is ±1 SD of the accepted shots. There is no target band.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: The block's 3-D form

    /// Every accepted shot's form in this block, tagged with its shot number so the viewer can say
    /// which shots the mean is made of.
    private var blockForms: [ShotForm] {
        session.shots.compactMap { shot in
            guard shot.verdict?.isAccepted == true, var f = shot.result?.body?.form else { return nil }
            f.shotID = shot.id
            return f
        }
    }

    private var blockFormModel: FormModel {
        let forms = blockForms
        guard !forms.isEmpty else {
            let measured = session.shots.contains { $0.result?.body != nil }
            return FormModel.unavailable(measured
                ? "no shot in this block was accepted by the block rule, so there is no form to average (a single shot's form is still on its own result screen)"
                : "the body model did not run on any shot in this block, so there is no 3-D form",
                label: "This block")
        }
        return FormModel.build(forms: forms, label: "This block", spot: saveSpot?.rawValue)
    }

    @ViewBuilder private var formRow: some View {
        NavigationLink {
            FormModelView(title: "3-D form", model: blockFormModel, shot: nil, source: "session",
                          earlierSessions: store?.sessionsWithForms() ?? [])
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("3-D form of this block")
                    Text(blockFormModel.isAvailable
                         ? "\(blockFormModel.shots) accepted shot\(blockFormModel.shots == 1 ? "" : "s"), mean form with its spread"
                         : (blockFormModel.unavailableReason ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "figure.basketball")
            }
        }
    }

    // MARK: Shot list

    private var shotsSection: some View {
        Section("Shots (\(session.shots.count))") {
            ForEach(session.shots) { shot in
                if session.resultContext(for: shot) != nil {
                    NavigationLink { shotDestination(shot) } label: { row(shot) }
                } else {
                    row(shot)
                }
            }
        }
    }

    @ViewBuilder private func shotDestination(_ shot: SessionShot) -> some View {
        if let ctx = session.resultContext(for: shot) {
            ResultsView(context: ctx, blockForms: blockForms, blockLabel: "This block",
                        earlierSessions: store?.sessionsWithForms() ?? [])
        } else {
            ContentUnavailableView("Not analysed", systemImage: "hourglass",
                                   description: Text("This window has not been measured yet."))
        }
    }

    /// One shot: number, arc, the numbers, and the verdict in two words. The full reason is on the
    /// shot's own screen, which this row pushes to.
    private func row(_ shot: SessionShot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Shot \(shot.id)").font(.subheadline.bold())
                ArcSparkline(samples: shot.result?.samples ?? [])
                Spacer()
                if shot.row?.verdict.isAccepted == true { DepthChip(depth: shot.row?.depthPastFrontRim) }
                VerdictChip(wording: VerdictWording.of(shot))
            }
            if case .analyzing = shot.status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(shot.statusDetail ?? "working…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let row = shot.row {
                HStack(spacing: 10) {
                    Text(row.releaseSpeed.map { String(format: "%.2f m/s", $0) } ?? "speed —")
                    Text(row.releaseAngleDegrees.map { String(format: "%.0f°", $0) } ?? "angle —")
                    Text(row.entryAngleDegrees.map { String(format: "entry %.1f°", $0) } ?? "entry —")
                    Text(row.depthPastFrontRim.map { String(format: "%.0f cm", $0 * 100) } ?? "depth —")
                }
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
            } else if case .queued = shot.status {
                Text(String(format: "arrival at %.1f s, %.0f px from the rim centre", shot.window.arrivalFileTime, shot.window.arrivalDistancePx))
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Coaching card

    @ViewBuilder private var coachingContent: some View {
        let card = session.coaching
        if card.says.isEmpty {
            Text(card.saysEmptyReason ?? "not measured").font(.footnote).foregroundStyle(.secondary)
        } else {
            ForEach(card.says) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.text).font(.footnote)
                    Text(line.provenance).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Divider()
        Text("What to work on").font(.caption.bold()).foregroundStyle(.secondary)
        switch card.workOn {
        case .collectingBaseline(let accepted, let needed):
            VStack(alignment: .leading, spacing: 6) {
                Text("Collecting baseline: \(accepted) of \(needed) accepted shots.").font(.subheadline.bold())
                ProgressView(value: Double(accepted), total: Double(needed))
                Text("What unlocks at \(needed): one finding with its evidence, and one drill. One thing at a time, and only at 30 or more accepted shots in the block.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .finding(let title, let evidence, let cue, let provenance):
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.bold())
                Text(evidence).font(.footnote)
                Label(cue, systemImage: "target").font(.footnote)
                Text(provenance).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .nothingFired(let accepted):
            Text("Nothing to work on from this block: at \(accepted) accepted shots no rule fired, which means nothing here separated itself from the shot-to-shot noise.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        Divider()
        Text("How to film next time").font(.caption.bold()).foregroundStyle(.secondary)
        if card.filming.isEmpty {
            Text(card.filmingEmptyReason ?? "not measured").font(.footnote).foregroundStyle(.secondary)
        } else {
            ForEach(card.filming) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Label(line.text, systemImage: "camera").font(.footnote)
                    Text(line.provenance).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Text("Each sentence carries its own numbers and n. Everything here is an association measured on this clip, never a cause, and none of it is a target.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: Save

    /// Saving is what makes the 30-shot floor reachable: the finding a shooter came for appears on the
    /// Progress screen, where sessions from the same spot are pooled, not in any single session. The
    /// guided flow saves automatically with the spot it asked for at the start; this is the manual
    /// door, and it says "Saved" rather than offering to write a second copy.
    private var saveSection: some View {
        let measured = session.shots.filter { $0.row != nil }.count
        let accepted = session.summary.accepted
        let savedSession = session.savedSessionID.flatMap { id in store?.sessions.first { $0.id == id } }
        return Section {
            if let savedSession {
                Label("Saved as \(savedSession.spot.rawValue) — \(accepted) accepted of \(measured) measured shots now count towards that spot on Progress.",
                      systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(.green)
                Button(role: .destructive) {
                    store?.delete(savedSession.id)
                    session.savedSessionID = nil
                    session.savedSpot = nil
                    savedID = nil
                    ActivityLog.shared.event("session.autosave.undone", ["id": savedSession.id.uuidString, "from": "session"])
                } label: {
                    Label("Undo the save", systemImage: "arrow.uturn.backward")
                }
            } else {
                Picker("Shot from", selection: $saveSpot) {
                    Text("Choose the spot…").tag(ShotSpot?.none)
                    ForEach(ShotSpot.allCases) { Text($0.rawValue).tag(ShotSpot?.some($0)) }
                }
                if let dup = store?.sessions.first(where: { $0.clipName == session.clipURLName && $0.shots.count == measured }) {
                    Label(String(format: "This clip looks already saved (%@, %@, %d shots). Saving again would count it twice on the Progress screen.",
                                 dup.spot.rawValue, dup.date.formatted(date: .abbreviated, time: .shortened), dup.shots.count), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                TextField("Note (optional): court, ball, how it felt", text: $saveNote)
                Button {
                    guard let store, let saveSpot else { return }
                    let saved = store.save(session: session, spot: saveSpot, note: saveNote,
                                           clipName: session.clipURLName, hfovDegrees: model.hfovDegrees,
                                           clipFingerprint: model.clipFingerprint)
                    savedID = saved.id
                    session.savedSessionID = saved.id
                    session.savedSpot = saveSpot
                } label: {
                    Label("Save this session (\(measured) measured, \(accepted) accepted)", systemImage: "square.and.arrow.down")
                }
                .disabled(session.isBusy || saveSpot == nil)
                if saveSpot == nil { Text("Pick the spot first — the statistics pool per spot and never across spots.").font(.caption).foregroundStyle(.secondary) }
            }
            if let err = store?.saveError { Text(err).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Save")
        }
    }

    // MARK: Provenance

    @ViewBuilder private func provenanceContent(_ scan: SessionScanResult) -> some View {
        if let lens = session.lensNote {
            Label(lens, systemImage: "camera.aperture").font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
        }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(scan.notes.enumerated()), id: \.offset) { _, n in
                Text("• " + n).font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(String(format: "• %d ball-sized candidates over %d frames (%@ scanner); measured %.2f fps in the file (%.1f fps real at a %.2f× factor)",
                        scan.candidateCount, scan.framesScanned, scan.mode.rawValue, scan.measuredFrameRate,
                        scan.measuredFrameRate * session.timeScale, session.timeScale))
                .font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
