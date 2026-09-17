import PhotosUI
import ShotGeometry
import ShotVideo
import SwiftUI

/// The form-clip screen: record or pick a close-up, let the body find the shots, measure each one,
/// and show the block's 3-D form.
///
/// It is deliberately shorter than the session screen, because a form clip measures fewer things and
/// says so once, at the top, instead of leaving twenty rows to say "not measured" one at a time.
struct FormClipView: View {
    @State private var model = FormClipModel()
    var store: SessionStore
    @State private var selection: PhotosPickerItem?
    @State private var spot: ShotSpot = .freeThrow
    @State private var showSave = false

    var body: some View {
        List {
            clipSection
            if model.clip != nil { scanSection }
            if !model.shots.isEmpty { shotsSection }
            if !model.measuredShots.isEmpty { formSection; saveSection }
        }
        .navigationTitle("Form clip")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ActivityLog.shared.event("screen", ["name": "formClip"]) }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            model.importAndProbe(item)
        }
    }

    // MARK: 1 — the clip

    private var clipSection: some View {
        Section {
            if let clip = model.clip, let p = model.probe {
                Label(clip.url.lastPathComponent, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(String(format: "%d × %d, %.0f fps in the file, %.0f s%@", p.width, p.height, p.measuredFrameRate,
                            p.trackDuration, model.timeScale > 1.05 ? String(format: ", %.0f× slow motion", model.timeScale) : ""))
                    .font(.caption).foregroundStyle(.secondary)
                Text("Lens: \(String(format: "%.1f°", model.hfovDegrees)) horizontal — \(model.hfovProvenance).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Pick a different clip") { model.reset(); model.clip = nil; model.phase = .empty }
                    .disabled(model.isBusy)
                if model.shots.isEmpty, let earlier = store.sessions(fromClip: model.clipFingerprint, includingFormClips: true).first {
                    // The same recording again. It was saved three times on 2026-09-14, 39 forms each
                    // time, and every copy counts separately on Progress. Measuring it again gives the
                    // same numbers, so the saved one is one tap away — and scanning again stays possible.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("You analysed this video on \(earlier.date.formatted(date: .abbreviated, time: .shortened)) — \(earlier.shots.count) shot\(earlier.shots.count == 1 ? "" : "s")\(earlier.isFormClip ? "" : " (as a shot session)"), saved as \(earlier.spot.rawValue).",
                              systemImage: "clock.arrow.circlepath")
                            .font(.footnote)
                        NavigationLink { EditSessionView(store: store, sessionID: earlier.id) } label: {
                            Label("Open that session", systemImage: "folder")
                        }
                        Text("Scanning below measures it again and would add a second copy to Progress.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                NavigationLink {
                    CaptureView { recorded in model.useRecordedClip(recorded) }
                } label: {
                    Label("Record a form clip now", systemImage: "record.circle")
                }
                .disabled(model.isBusy)
                PhotosPicker(selection: $selection, matching: .videos, photoLibrary: .shared()) {
                    Label("Pick a clip from Photos", systemImage: "film")
                }
                .disabled(model.isBusy)
                let previous = RecordedClip.loadAll().filter(\.fileExists).sorted { $0.recordedAt > $1.recordedAt }
                if !previous.isEmpty {
                    Menu {
                        ForEach(previous) { r in
                            Button {
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
            }
            if model.phase == .importing { busy("Copying the clip…") }
            if model.phase == .probing { busy("Reading every frame to learn its real frame rate…") }
            if case .failed(let message) = model.phase { Text(message).font(.caption).foregroundStyle(.red) }
            ShooterHeightRow(detailed: true)
        } header: {
            Text("1 · The clip")
        } footer: {
            Text("Phone 3–4 m away on your shooting-hand side, side-on, your whole body in frame from the floor to a hand's width above your follow-through, 240 fps, good light, 10–15 shots. The rim does not need to be in frame. Closer means the ankle, the neck and the fingers can be read; at 9 m they cannot. What this clip cannot measure: release speed, release angle, entry angle, depth at the rim, make or miss — those need the rim in frame and come from a shot session.")
        }
    }

    // MARK: 2 — the scan

    private var scanSection: some View {
        Section {
            if model.phase == .scanning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: model.scanProgress)
                    Text(model.scanMessage ?? "reading the clip…").font(.caption).foregroundStyle(.secondary)
                }
            } else if model.shots.isEmpty {
                Toggle("Set shots only", isOn: Binding(get: { model.setShotsOnly }, set: { model.setShotsOnly = $0 }))
                    .disabled(model.isBusy)
                Button { model.scan() } label: { Label("Find the shots", systemImage: "figure.basketball") }
                    .disabled(model.isBusy)
                if let m = model.scanMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("\(model.shots.count) shot\(model.shots.count == 1 ? "" : "s") found\(model.scanSeconds.map { String(format: " in %.0f s", $0) } ?? "")")
                    .font(.subheadline.bold())
            }
            ForEach(Array(model.scanNotes.enumerated()), id: \.offset) { _, n in
                Text(n).font(.caption2).foregroundStyle(.secondary)
            }
            if !model.rejected.isEmpty {
                DisclosureGroup {
                    ForEach(Array(model.rejected.enumerated()), id: \.offset) { _, r in
                        Text(String(format: "%.1f s — %@", r.apexRealTime, r.reason))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } label: {
                    Text("\(model.rejected.count) wrist high point\(model.rejected.count == 1 ? "" : "s") refused")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("2 · Shots, found by your body")
        } footer: {
            Text("""
            With no rim in frame there is no ball arriving to count, so a shot here is a pattern in your own wrist, sampled 30 times a second across the whole clip: it rises by more than half a torso length into a high point above your shoulder line, holds that extension for at least 0.3 s, and — with “set shots only” on — drives there from a set position it held still for at least 80 ms, by no more than one torso length. Dribbles, catches, walks with the ball and quick tips from under the rim fail one of those and are listed with the reason. Two shots closer than three seconds count as one. The shooting hand is voted from the shots themselves (the wrist extended further from the body at the top), not from which side faces the phone.

            What the scan needs: your whole body in frame — shoulders, hips and both wrists — on most frames. It cannot find a shot on frames where you are cut off at the waist, out of frame, or too small to read (under about 60 px of torso).
            """)
        }
    }

    // MARK: 3 — the shots

    private var shotsSection: some View {
        Section {
            if model.phase == .analysing {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(model.shots.filter { $0.isMeasured }.count), total: Double(model.shots.count))
                    if let eta = model.estimatedSecondsRemaining {
                        Text(eta < 90 ? String(format: "about %.0f s left", eta) : String(format: "about %.0f min left", (eta / 60).rounded()))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(role: .destructive) { model.cancelAnalysis() } label: { Label("Stop", systemImage: "stop.circle") }
            } else if model.shots.contains(where: { !$0.isMeasured }) {
                Button { model.analyseAll() } label: { Label("Measure the rest", systemImage: "play.circle") }
            }
            ForEach(model.shots) { shot in
                NavigationLink {
                    FormClipShotView(shot: shot, blockForms: model.measuredShots.compactMap(\.form))
                } label: {
                    shotRow(shot)
                }
                .disabled(shot.body == nil)
            }
        } header: {
            Text("3 · Each shot")
        } footer: {
            Text("Every shot is measured from its own release instant. Where the ball could still be seen leaving your hand, that is the instant; where it had already left the frame, it is the highest point of your wrist, and the card says which and how wide that is.")
        }
    }

    private func shotRow(_ shot: FormClipModel.Shot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Shot \(shot.id)").font(.subheadline.bold())
                Spacer()
                switch shot.status {
                case .queued: Text("waiting").font(.caption).foregroundStyle(.secondary)
                case .analysing(let what): HStack(spacing: 6) { ProgressView(); Text(what).font(.caption2).foregroundStyle(.secondary) }
                case .measured:
                    Text(shot.release.map { r in
                        String(format: "%@ · ±%.0f ms", r.source == .ballLeftHand ? "ball left the hand" : "wrist's highest point", 1000 * r.sigmaSeconds)
                    } ?? "measured").font(.caption).foregroundStyle(.secondary)
                case .failed: Text("not measured").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let b = shot.body {
                Text(summaryLine(b)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else if case .failed(let why) = shot.status {
                Text(why).font(.caption2).foregroundStyle(.secondary)
            }
            Text(String(format: "at %.1f s · wrist rose %.2f torso lengths in %.0f ms · %@ hand%@",
                        shot.window.apexRealTime, shot.window.riseSpans, 1000 * shot.window.riseSeconds,
                        shot.window.shootingSide,
                        shot.window.setPlateauSeconds.map { String(format: " · held still %.0f ms at the set", 1000 * $0) } ?? " · no set position"))
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(shot.window.notes.enumerated()), id: \.offset) { _, n in
                Text(n).font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private func summaryLine(_ b: ShotBodyResult) -> String {
        var parts: [String] = []
        if let e = b.elbowAtRelease.degrees { parts.append(String(format: "elbow %.0f°", e)) }
        if let k = b.kneeMinimum.degrees { parts.append(String(format: "knee %.0f°", k)) }
        if let d = b.dipToReleaseMilliseconds.value { parts.append(String(format: "dip→release %.0f ms", d)) }
        if let j = b.jumpHeight.value { parts.append(String(format: "jump %.2f m", j)) }
        return parts.isEmpty ? "measured" : parts.joined(separator: " · ")
    }

    // MARK: 4 — the block's form

    private var formSection: some View {
        Section {
            NavigationLink {
                FormModelView(title: "3-D form", model: model.blockFormModel, shot: nil, source: "formClip",
                              earlierSessions: store.formClipSessions)
            } label: {
                Label("The 3-D form of these \(model.measuredShots.compactMap(\.form).count) shots", systemImage: "figure.basketball")
            }
            let n = model.measuredShots.count
            Text("\(n) shot\(n == 1 ? "" : "s") measured of \(model.shots.count) found. Every number on this clip is a body number: no rim was in frame, so release speed, release angle, entry angle, depth at the rim and make-or-miss are not measured here.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("4 · Your form across the clip")
        }
    }

    // MARK: 5 — saving

    private var saveSection: some View {
        Section {
            if let saved = model.saved {
                Label("Saved as a form clip at \(saved.spot.rawValue)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.subheadline)
            } else {
                Picker("Spot", selection: $spot) {
                    ForEach(ShotSpot.allCases) { s in Text(s.rawValue).tag(s) }
                }
                TextField("Note (optional)", text: Binding(get: { model.saveNote }, set: { model.saveNote = $0 }))
                Button {
                    _ = model.save(store: store, spot: spot)
                } label: {
                    Label("Save this form clip", systemImage: "square.and.arrow.down")
                }
                .disabled(model.measuredShots.isEmpty)
            }
        } header: {
            Text("5 · Save")
        } footer: {
            Text("Saved with a form-clip flag. Form clips are pooled per spot on their own, separately from shot sessions: they measure the body, and a shot session measures the ball, so a form clip never enters a release-speed, entry-angle, depth or make-rate statistic, and never counts toward the 30-shot floor.")
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 12) { ProgressView(); Text(text).font(.footnote).foregroundStyle(.secondary) }
    }
}

// ================================================================================================
// MARK: - One form-clip shot
// ================================================================================================

/// The body card for a shot with no ball numbers behind it. The same measures the session's results
/// screen shows, without the arc, the gravity check and the rim map — none of which exist here.
struct FormClipShotView: View {
    let shot: FormClipModel.Shot
    var blockForms: [ShotForm] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                releaseCard
                if let b = shot.body {
                    GroupBox("Body model") {
                        VStack(alignment: .leading, spacing: 10) {
                            phaseTable(b)
                            Divider()
                            measureRow("Set to release", setToRelease(b), "%.0f")
                            measureRow("Dip to release", b.dipToReleaseMilliseconds, "%.0f")
                            measureRow("Elbow extension, peak speed", b.elbowExtensionPeakRate, "%.0f")
                            measureRow("Knee extension, peak speed", b.kneeExtensionPeakRate, "%.0f")
                            measureRow("Knee, deepest bend (fitted)", b.kneeMinimum, "%.0f")
                            Divider()
                            measureRow("Jump height", b.jumpHeight, "%.2f")
                            measureRow("Dip depth, of your own height", b.dipDepthNormalised, "%.3f")
                            measureRow("Head steadiness, of your own height", b.headStabilityNormalised, "%.4f")
                            measureRow("Squareness (shoulder line)", b.shoulderLineYaw, "%.1f")
                            measureRow("Hands found near release", b.handRateAtRelease, "%.2f")
                            provenance(b)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    NavigationLink {
                        FormModelView(title: "3-D form",
                                      model: blockForms.isEmpty
                                        ? FormModel.unavailable("no other shot in this clip has been measured yet, so there is no block mean to compare with", label: "Form clip")
                                        : FormModel.build(forms: blockForms, label: "Form clip"),
                                      shot: b.form, source: "formClipShot")
                    } label: {
                        Label("This shot in 3-D, against the clip's mean", systemImage: "figure.basketball")
                    }
                } else if case .failed(let why) = shot.status {
                    GroupBox("Not measured") { Text(why).font(.footnote).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 28)
        }
        .navigationTitle("Shot \(shot.id)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var releaseCard: some View {
        GroupBox("The release instant") {
            VStack(alignment: .leading, spacing: 6) {
                if let r = shot.release {
                    HStack {
                        Text(r.source == .ballLeftHand ? "The ball leaving your hand" : "The highest point of your wrist")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.3f s ± %.0f ms", r.realTime, 1000 * r.sigmaSeconds))
                            .font(.subheadline.monospacedDigit())
                    }
                    Text(r.note).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(shot.releaseUnavailableReason ?? "the release instant was not dated for this shot")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text(FormClipModel.ballUnavailableReason + ", so release speed, release angle, entry angle, depth at the rim and make-or-miss are not measured on this clip.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Set → release, which is the tempo number that survives when a shot has no dip at all.
    private func setToRelease(_ b: ShotBodyResult) -> BodyMeasure {
        guard let set = b.phases.first(where: { $0.name == "Set" })?.realTime,
              let release = b.phases.first(where: { $0.name == "Release" })?.realTime else {
            return .missing(.milliseconds, b.phases.first(where: { $0.name == "Set" })?.unavailableReason
                            ?? "the set position was not found inside this window")
        }
        return .ok(1000 * (release - set), .milliseconds)
    }

    private func phaseTable(_ b: ShotBodyResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Phase").frame(width: 104, alignment: .leading)
                Text("elbow").frame(maxWidth: .infinity, alignment: .trailing)
                Text("knee").frame(maxWidth: .infinity, alignment: .trailing)
                Text("hip").frame(maxWidth: .infinity, alignment: .trailing)
                Text("shoulder").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2).foregroundStyle(.secondary)
            ForEach(b.phases) { p in
                HStack {
                    Text(p.name).frame(width: 104, alignment: .leading)
                    ForEach(Array([p.elbow, p.knee, p.hip, p.shoulderElevation].enumerated()), id: \.offset) { _, m in
                        Text(m.degrees.map { String(format: "%.0f°", $0) } ?? "—")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundStyle(m.isAvailable ? .primary : .secondary)
                    }
                }
                .font(.caption.monospacedDigit())
                if let why = p.unavailableReason {
                    Text("\(p.name.lowercased()): \(why)").font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(String(format: "Angles of one skeleton fitted to the whole shot, read at each phase. These are associated with how a shot is built, not scored against a target; an absolute angle from one camera is only good to about ±25°%@, so read your own shot-to-shot change.",
                        b.elbowJitterDegrees.map { String(format: ", and this fit moves %.1f° between sampled frames", $0) } ?? ""))
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(b.phaseNotes.enumerated()), id: \.offset) { _, n in
                Text(n).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func measureRow(_ label: String, _ m: BodyMeasure, _ format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline)
                Spacer()
                Text(m.isAvailable ? m.describe(format) : "not measured")
                    .font(m.isAvailable ? .subheadline.monospaced() : .subheadline.italic())
                    .foregroundStyle(m.isAvailable ? .primary : .secondary)
            }
            if !m.isAvailable, let why = m.unavailableReason {
                Text(why).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func provenance(_ b: ShotBodyResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%d frames analysed over %.2f s of real time (every %d%@ frame), a body on %d of them, hands on %d. %@ Reprojection %@. Vision %.1f s + fit %.2f s.",
                        b.framesAnalysed, b.windowEndReal - b.windowStartReal, b.everyNthFrame,
                        b.everyNthFrame == 1 ? "" : "nd", b.framesWith2D, b.framesWithHands,
                        b.scaleNote, b.reprojectionRMSPx.describe("%.2f"), b.visionSeconds, b.fitSeconds))
            ForEach(Array(b.warnings.enumerated()), id: \.offset) { _, w in
                Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
