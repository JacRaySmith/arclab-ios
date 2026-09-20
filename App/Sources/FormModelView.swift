import SceneKit
import ShotGeometry
import SwiftUI
import UIKit
import simd

// ================================================================================================
// MARK: - The 3-D form viewer
// ================================================================================================
//
// One rotatable skeleton on the phase-normalised clock, played back at the block's own real tempo.
// The skeletons themselves are built in `FormScene.swift`; this file is the screen around them.
//
// 1.2 (docs/IMPROVEMENTS-2026-09-16.md §1.4, sharpened by §7):
//
//   18 · it opens on the **release** pose, and a segmented control of the six stops on the clock
//        jumps to any of them (`FormPhaseStops`: four the model times, two derived and labelled).
//   19 · the translucent form behind the solid one is a **ghost of the shooter's own best reps** at
//        this spot when the rule finds five, and the block's mean when it does not — and the legend
//        says which, with the counts (`FormGhostBuilder`, `FormModel.bestReps`).
//   20 · tapping a joint opens one callout with that joint's angle and the block's spread; tapping
//        it again clears it. No permanent numbers on the body (`FormAngleCallout`).
//   21 · Side / Front / Above / Rim's-eye presets; free orbit stays as a gesture
//        (`FormCameraPresets`).
//    5 · every number over the scene sits on an opaque ≥ 80 % scrim, on a fixed dark ground.
//
// Nothing on this screen is a number the model refused: where a form, a phase or a spread is
// unavailable, the screen prints the model's own sentence instead of drawing something.

// MARK: - The SceneKit surface

/// `SCNView` rather than `SceneView`, so a preset can move the point of view, the viewer can keep
/// orbiting from wherever it put them, and a tap can be matched against the joints on screen.
private struct FormSceneContainer: UIViewRepresentable {
    let scene: FormSceneModel
    /// Bumped whenever a preset is chosen, so `updateUIView` knows to re-aim.
    var presetToken: Int
    /// The layer a tap is matched against, and the joint indices in it that may be tapped.
    var tapLayer: () -> FormLayer?
    var tappable: [Int]
    /// The joint index under the tap, or nil when the tap missed every drawn joint.
    var onTap: (Int?) -> Void
    /// True while the clock is moving the skeleton — playback, or a finger on the scrubber.
    ///
    /// Same fix as `BodySceneContainer.isAnimating` in `BodyPlayerView.swift`, for the same reason:
    /// with `rendersContinuously = false` an `SCNView` presents a new drawable only when SceneKit's
    /// own change tracking decides the scene moved, and `UIView.setNeedsDisplay()` does not drive a
    /// Metal-backed SceneKit renderer. Moving the skeleton from a `Timer` on the main run loop then
    /// leaves the view on its clear colour — the dark ground read as black — until something else
    /// forces a render, which is what "it comes back at the end" was.
    var isAnimating: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene.scene
        view.pointOfView = scene.cameraNode
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.backgroundColor = FormSceneModel.background
        view.isOpaque = true
        view.rendersContinuously = isAnimating
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTapsRequired = 1
        view.addGestureRecognizer(tap)
        context.coordinator.owner = self
        aim(view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.owner = self
        if context.coordinator.token != presetToken {
            context.coordinator.token = presetToken
            view.pointOfView = scene.cameraNode
            aim(view)
        }
        if view.rendersContinuously != isAnimating { view.rendersContinuously = isAnimating }
        view.setNeedsDisplay()
    }

    private func aim(_ view: SCNView) {
        let t = scene.target
        view.defaultCameraController.target = SCNVector3(t.x, t.y, t.z)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var token = -1
        var owner: FormSceneContainer?

        /// A joint sphere is a few points across, so the tap is matched by **projecting** the drawn
        /// joints into the view and taking the nearest one within a finger's width — not by hit-
        /// testing the geometry, which would miss almost every tap.
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let owner, let view = g.view as? SCNView else { return }
            let p = g.location(in: view)
            guard let layer = owner.tapLayer() else { owner.onTap(nil); return }
            var best: (index: Int, distance: CGFloat)?
            for j in layer.drawnJointsInWorld(owner.tappable) {
                let projected = view.projectPoint(SCNVector3(j.world))
                guard projected.z > 0, projected.z < 1 else { continue }
                let d = hypot(CGFloat(projected.x) - p.x, CGFloat(projected.y) - p.y)
                guard d <= 44 else { continue }
                if best == nil || d < best!.distance { best = (j.index, d) }
            }
            owner.onTap(best?.index)
        }
    }
}

// MARK: - The screen

/// The 3-D form: a shot, a block's mean form, or both, with an earlier session for progress.
struct FormModelView: View {
    let title: String
    /// The block's mean form. May be `unavailable` — then its reason is shown, not a skeleton.
    let model: FormModel
    /// The shot this screen was opened from, when it was opened from a shot.
    var shot: ShotForm?
    /// Where the screen was reached from, for the activity log.
    var source: String
    /// Earlier saved sessions to offer in the comparison picker.
    var earlierSessions: [SavedSession] = []

    @State private var scene = FormSceneModel()
    /// Item 18: the clock opens on the release, not on t = 0. The first frame of a shot is a person
    /// standing still; the release is the thing the screen exists to show.
    @State private var tau: Double = FormPhase.release.normalisedTime
    @State private var playing = false
    @State private var showEllipsoids = false
    @State private var showGhost = true
    @State private var earlierID: UUID?
    @State private var earlierModel: FormModel?
    @State private var built = false
    @State private var preset: FormCameraPreset = .side
    @State private var presetToken = 0
    @State private var ghost: FormGhost?
    @State private var ghostSearched = false
    @State private var selectedJoint: Int?
    @State private var stops: [FormClockStop] = []
    /// The stop the viewer asked for that this clock does not carry, so the screen can say why.
    @State private var refusedStop: String?
    /// True while a finger is on the scrubber — see `FormSceneContainer.isAnimating`.
    @State private var scrubbing = false

    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    /// Whatever there is to show: the shot if the screen was opened from one, else the block's mean.
    private var hasAnything: Bool { shot != nil || model.isAvailable }

    /// The joints the tap and the callout are indexed against: the drawn shot's, or the ghost's when
    /// the screen was opened on a block.
    private var activeJoints: [String] { shot?.joints ?? ghost?.model.joints ?? model.joints }
    /// Does the form on screen carry a hand plate at all? An older form does not, and then the
    /// legend says nothing about one rather than promising a plate that will never appear.
    private var handPlateInForm: Bool {
        activeJoints.contains(Body2DPoint.rightIndexMCP) || activeJoints.contains(Body2DPoint.leftIndexMCP)
    }
    private var activeInferred: [Bool] { shot?.inferredBySymmetry ?? model.inferredBySymmetry }
    /// The model the callout quotes: whatever is drawn translucent, because that is the spread whose
    /// ellipsoids the viewer can see.
    private var calloutModel: FormModel { ghost?.isAvailable == true ? ghost!.model : model }
    private var calloutModelLabel: String {
        guard let g = ghost, g.isAvailable else { return "the block mean" }
        return g.isBestRepGhost ? "your best reps" : "the block mean"
    }

    var body: some View {
        Group {
            if hasAnything {
                content
            } else {
                ContentUnavailableView("No 3-D form",
                                       systemImage: "figure.basketball",
                                       description: Text(model.unavailableReason
                                                         ?? "this shot has no body model, so there is nothing to draw"))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ActivityLog.shared.event("screen", ["name": "form", "source": source,
                                                "shots": model.shots, "hasShot": shot != nil,
                                                "unit": model.unit.rawValue,
                                                "openedAt": "release",
                                                "unavailable": model.unavailableReason])
            build()
        }
        .task { await loadGhost() }
        .onReceive(tick) { _ in advance() }
        // Without this a screen left while it is playing keeps a 60 Hz timer redrawing a scene
        // nobody is looking at, for as long as the app runs.
        .onDisappear { playing = false; scrubbing = false }
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FormSceneContainer(scene: scene, presetToken: presetToken,
                                   tapLayer: { scene.shotLayer ?? scene.ghostLayer },
                                   tappable: FormTappableJoint.indices(in: activeJoints),
                                   onTap: tapped,
                                   isAnimating: playing || scrubbing)
                    .frame(height: 400)
                    .background(FormSceneChrome.sceneBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) { legend.padding(8) }
                    .overlay(alignment: .bottomTrailing) { timeStamp.padding(8) }
                    .accessibilityLabel("A rotatable 3-D skeleton of the shooting form. Tap a joint for its angle.")
                calloutOverlay
                ghostLine
                cameraRow
                phaseRow
                transport
                toggles
                if !earlierSessions.isEmpty { comparePicker }
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 14) {
                        deviationCard
                        tempoCard
                        provenanceCard
                    }
                    .padding(.top, 6)
                }
                .font(.subheadline.bold())
            }
            .padding(.horizontal)
            .padding(.bottom, 28)
        }
    }

    // MARK: Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            if shot != nil { swatch(.blue, "this shot") }
            if let g = ghost, g.isAvailable, showGhost {
                swatch(Color(white: 0.9), g.isBestRepGhost ? "ghost · your best reps" : "ghost · block mean")
            }
            if let e = earlierModel, e.isAvailable { swatch(.orange, e.label) }
            Text("dashed = inferred by symmetry").font(.caption2)
            // 1.3: the hand plate. It is drawn where the hand detector saw both knuckles and nowhere
            // else, and its size is a borrowed number — both facts belong on the screen, not in a doc.
            if handPlateInForm {
                Text("hand plate = wrist · index knuckle · little knuckle. Orientation fitted; **size is a population prior** (0.049 × stature across the knuckles). Absent on the samples the hand detector did not see.")
                    .font(.caption2)
                    .frame(maxWidth: 260, alignment: .leading)
            }
            // The head reads as a head only when the view says which way it faces. When it does not,
            // the skull is bare and this says why rather than inventing a direction to look in.
            if let why = scene.shotLayer?.headFaceUnavailableReason ?? scene.ghostLayer?.headFaceUnavailableReason {
                Text("no face drawn — " + why)
                    .font(.caption2)
                    .frame(maxWidth: 240, alignment: .leading)
            } else {
                Text("face side = the measured nose past the neck").font(.caption2)
            }
        }
        .foregroundStyle(FormSceneChrome.secondaryText)
        .formSceneScrim(corner: 8)
    }

    private func swatch(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(text).font(.caption2).foregroundStyle(FormSceneChrome.text)
        }
    }

    private var timeStamp: some View {
        Text(timeLabel)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(FormSceneChrome.secondaryText)
            .formSceneScrim(corner: 6)
    }

    /// Item 20. Under the scene rather than over it: a card wide enough to carry a reason would
    /// cover the body it is about, and the ring on the joint says which joint it is.
    @ViewBuilder private var calloutOverlay: some View {
        if let j = selectedJoint, activeJoints.indices.contains(j) {
            FormJointCalloutView(callout: FormJointCallout.build(
                joint: activeJoints[j], joints: activeJoints,
                shotPositions: shot.map { FormSampling.positions(of: $0, at: tau) },
                shotInferred: activeInferred,
                model: calloutModel, modelLabel: calloutModelLabel,
                sampleIndex: sampleIndex(at: tau, count: calloutModel.sampleCount),
                whenLabel: phaseLabel.lowercased()),
                                 onClose: { select(nil) })
        }
    }

    /// The one line that says what the translucent skeleton is. It sits on the same scrim as the
    /// legend because it is part of the legend: item 19's honesty is in this sentence.
    @ViewBuilder private var ghostLine: some View {
        if let g = ghost {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: g.isBestRepGhost ? "person.2.fill" : "person.fill")
                    .font(.caption)
                Text(g.legend).font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(FormSceneChrome.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .formSceneScrim()
        } else if !ghostSearched {
            Text("Looking through your saved sessions for your best reps at this spot…")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Camera (item 21)

    private var cameraRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Camera", selection: $preset) {
                ForEach(FormCameraPreset.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: preset) { _, new in
                scene.apply(new)
                presetToken += 1
                ActivityLog.shared.event("form.camera", ["preset": new.rawValue, "source": source])
            }
            Text(preset.note(rimNote: rimNote)).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// What the body frame's +x means on this form: a measured bearing to the rim, or — when the
    /// clip never said where the rim was — the camera's own right. Every preset's caption carries it,
    /// because "side" and "rim's-eye" only mean anything against that axis.
    private var rimNote: String {
        FormCameraPreset.shortFacingNote(shot?.facingNote ?? model.notes.first { $0.hasPrefix("x ") } ?? "")
    }

    // MARK: The clock (item 18)

    private var phaseRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Phase", selection: Binding(get: { nearestStopKey }, set: { jump(to: $0) })) {
                ForEach(stops) { stop in
                    Text(stop.label).tag(stop.key)
                }
            }
            .pickerStyle(.segmented)
            .font(.caption2)
            if let stop = stops.first(where: { $0.key == nearestStopKey }) {
                Text(stop.isAvailable
                     ? stop.provenance
                     : (stop.unavailableReason.map { "\(stop.label.lowercased()): not on this clock — \($0)" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let refused = stops.first(where: { $0.key == refusedStop }) {
                Text("\(refused.label) is not on this clock — \(refused.unavailableReason ?? "the model never timed it")")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    /// The stop the scrubber is sitting on, or the last one it passed.
    private var nearestStopKey: String {
        let available = stops.filter(\.isAvailable)
        guard let exact = available.min(by: { abs(($0.time ?? 0) - tau) < abs(($1.time ?? 0) - tau) }) else {
            return stops.first?.key ?? FormPhase.release.rawValue
        }
        return exact.key
    }

    private func jump(to key: String) {
        guard let stop = stops.first(where: { $0.key == key }) else { return }
        guard let t = stop.time else {
            // An unavailable stop moves nothing and says why, rather than jumping somewhere near it.
            refusedStop = stop.key
            return
        }
        refusedStop = nil
        playing = false
        tau = t
        redraw()
        ActivityLog.shared.event("form.phase", ["stop": key, "derived": stop.isDerived, "tau": t])
    }

    private var phaseLabel: String {
        guard let stop = stops.first(where: { $0.key == nearestStopKey }), let t = stop.time else { return "shot" }
        if abs(t - tau) < 0.012 { return stop.label }
        let after = stops.filter { ($0.time ?? 2) <= tau }.max { ($0.time ?? 0) < ($1.time ?? 0) }
        let before = stops.filter { ($0.time ?? -1) > tau }.min { ($0.time ?? 0) < ($1.time ?? 0) }
        if let a = after, let b = before { return "\(a.label.lowercased()) → \(b.label.lowercased())" }
        return stop.label
    }

    /// The real clock, not the normalised one: seconds relative to the release.
    private var timeLabel: String {
        guard let dt = realTime(at: tau) else { return "real time not known on this stretch" }
        return String(format: "%+.3f s from release", dt)
    }

    // MARK: Transport

    private var transport: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.title)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    Text(phaseLabel).font(.subheadline.bold())
                    Text(timeLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Slider(value: $tau, in: 0...1) { editing in
                scrubbing = editing
                if editing { playing = false }
            }
            .onChange(of: tau) { _, _ in redraw() }
        }
    }

    // MARK: Toggles

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ghost?.isAvailable == true {
                Toggle("Show the ghost", isOn: $showGhost)
                    .font(.subheadline)
                    .onChange(of: showGhost) { _, on in scene.ghostLayer?.setVisible(on) }
            }
            if model.isAvailable {
                Toggle("Variability (1σ ellipsoids)", isOn: $showEllipsoids)
                    .font(.subheadline)
                    .onChange(of: showEllipsoids) { _, on in
                        scene.ghostLayer?.setEllipsoidsVisible(on)
                        scene.earlierLayer?.setEllipsoidsVisible(on)
                        redraw()
                    }
                if calloutModel.shots < 3 {
                    Text("Ellipsoids need at least 3 shots; \(calloutModelLabel) has \(calloutModel.shots), so every spread here is unavailable.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("Tap a joint — elbow, knee, shoulder, hip, wrist — for its angle at this instant. Tap it again to clear it.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var comparePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Compare with an earlier session", selection: $earlierID) {
                Text("None").tag(UUID?.none)
                ForEach(earlierSessions) { s in
                    Text("\(s.formLabel) · \(s.shots.filter { $0.form != nil }.count) shots").tag(UUID?.some(s.id))
                }
            }
            .font(.subheadline)
            .onChange(of: earlierID) { _, id in loadEarlier(id) }
            if let e = earlierModel, let why = e.unavailableReason {
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The numbers

    @ViewBuilder private var deviationCard: some View {
        if let shot, model.isAvailable {
            let c = model.compare(shot: shot)
            GroupBox("This shot against the block") {
                VStack(alignment: .leading, spacing: 6) {
                    if let why = c.unavailableReason {
                        Text(why).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        let phase = FormPhase.allCases.min { abs($0.normalisedTime - tau) < abs($1.normalisedTime - tau) }!
                        Text("At the \(phase.label.lowercased()), furthest from the block's mean:")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(c.ranked.filter { $0.phase == phase.rawValue }.prefix(5), id: \.joint) { d in
                            HStack {
                                Text(d.joint).font(.caption)
                                if d.inferredBySymmetry {
                                    Text("inferred").font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.18), in: Capsule())
                                }
                                Spacer()
                                Text(String(format: "%.1f SD", d.deviationSDs.value ?? .nan))
                                    .font(.caption.monospaced())
                                    .foregroundStyle((d.deviationSDs.value ?? 0) > 2 ? .orange : .secondary)
                            }
                        }
                        if c.ranked.filter({ $0.phase == phase.rawValue }).isEmpty {
                            Text("No joint at this phase has a spread to be measured against.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(c.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let e = earlierModel, e.isAvailable, model.isAvailable {
            let d = FormModel.compare(e, with: model)
            GroupBox("\(e.label) → \(model.label)") {
                VStack(alignment: .leading, spacing: 6) {
                    if let why = d.unavailableReason {
                        Text(why).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Biggest changes, in the two blocks' pooled SDs:").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(d.ranked.prefix(6).enumerated()), id: \.offset) { _, r in
                            HStack {
                                Text("\(r.joint) at \(r.phase)").font(.caption)
                                Spacer()
                                Text(String(format: "%+.1f SD", r.differenceSDs.value ?? .nan)).font(.caption.monospaced())
                            }
                        }
                        ForEach(d.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var tempoCard: some View {
        if model.isAvailable {
            GroupBox("Tempo") {
                VStack(alignment: .leading, spacing: 4) {
                    tempoRow("Set → dip", model.tempo.setToDip, shot?.durations.setToDip)
                    tempoRow("Rhythm (lowest wrist → release)", model.tempo.dipToRelease, shot?.durations.dipToRelease)
                    tempoRow("Release → follow-through", model.tempo.releaseToFollowThrough, shot?.durations.releaseToFollowThrough)
                    tempoRow("Whole shot", model.tempo.total, shot?.durations.total)
                    Text("The normalised scrubber lines two shots of different tempo up; these are the real durations it set aside.")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func tempoRow(_ label: String, _ stat: FormStat, _ shotValue: BodyMeasure?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption)
            Spacer()
            if let v = shotValue?.value {
                Text(String(format: "%.0f ms", v)).font(.caption.monospaced())
                Text("·").foregroundStyle(.secondary)
            }
            if let m = stat.mean.value {
                Text(stat.sd.value.map { String(format: "%.0f ± %.0f ms (n %d)", m, $0, stat.n) }
                     ?? String(format: "%.0f ms (n %d)", m, stat.n))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            } else {
                Text(stat.mean.unavailableReason ?? "unavailable")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder private var provenanceCard: some View {
        GroupBox("What this is, and what it is not") {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.isAvailable ? model.unitNote : (shot?.unitNote ?? "")).font(.caption)
                if let g = ghost {
                    Text(g.provenance).font(.caption2).foregroundStyle(.secondary)
                    if shot != nil, g.isAvailable {
                        Text("The ghost is moved so its mid-hip sits on this shot's at the instant on screen: what you see is a difference in shape, not a difference in where you stood.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(stops.filter { !$0.isAvailable }) { stop in
                    Text("\(stop.label): \(stop.unavailableReason ?? "not on this clock")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(FormPhaseStops.loadProvenance).font(.caption2).foregroundStyle(.secondary)
                Text(FormPhaseStops.riseProvenance).font(.caption2).foregroundStyle(.secondary)
                if let f = shot {
                    Text(f.facingNote).font(.caption2).foregroundStyle(.secondary)
                    let inferred = zip(f.joints, f.inferredBySymmetry).filter(\.1).map(\.0)
                    if !inferred.isEmpty {
                        Text("Drawn dashed, mirrored from the other side because the tracker never saw them: \(inferred.joined(separator: ", ")).")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    ForEach(f.refusedJoints.sorted(by: { $0.key < $1.key }), id: \.key) { j, why in
                        Text("\(j): not drawn — \(why)").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(f.gaps, id: \.reason) { g in
                        Text(g.reason).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(f.warnings, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
                }
                ForEach(model.warnings, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
                ForEach(model.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Building and playback

    private func build() {
        guard !built else { return }
        built = true
        var range = -0.5...1.0
        var midHip: SIMD3<Double>?
        if let f = shot {
            let samples = f.samples.map(\.positions)
            let S = FormSampling.stature(joints: f.joints, samples: samples)
            scene.setShot(FormLayer(joints: f.joints, inferred: f.inferredBySymmetry, style: .shot,
                                    boneLengths: FormSampling.lengths(of: f), showsEllipsoids: false,
                                    stature: S,
                                    facingLock: S.flatMap { FormSampling.facingLock(joints: f.joints, samples: samples, stature: $0) }))
            range = FormSampling.heightRange(of: f) ?? range
            scene.stature = S ?? 1
            midHip = FormSampling.meanMidHip(joints: f.joints, samples: samples)
            stops = FormPhaseStops.normalised(joints: f.joints,
                                              samples: f.samples.map { ($0.t, $0.positions) })
        } else if model.isAvailable {
            let samples = model.samples.map { s in (0..<model.joints.count).map { s.position($0) } }
            scene.stature = FormSampling.stature(joints: model.joints, samples: samples) ?? 1
            range = FormSampling.heightRange(of: model) ?? range
            midHip = FormSampling.meanMidHip(joints: model.joints, samples: samples)
            let joints = model.joints
            stops = FormPhaseStops.normalised(joints: joints,
                                              samples: model.samples.map { s in
                                                  (t: s.t, positions: (0..<joints.count).map { j in s.position(j) }) })
        }
        scene.centre(on: range, midHip: midHip)
        // The rim's-eye height is a real metre only when the form is in metres.
        if (shot?.unit ?? model.unit) == .metres {
            scene.rimSceneHeight = scene.floorSceneHeight + Float(FormCameraPreset.rimHeightMetres)
        }
        scene.apply(preset)
        presetToken += 1
        redraw()
    }

    /// The ghost: the shooter's own best reps at this spot, off the saved sessions on this phone.
    /// Read and chosen off the main actor — the saved file carries every form of every session.
    private func loadGhost() async {
        guard ghost == nil, !ghostSearched else { return }
        let url = SessionStore.fileURL
        let model = self.model
        let shot = self.shot
        let built = await Task.detached(priority: .userInitiated) { () -> FormGhost in
            let sessions = FormGhostBuilder.savedSessions(at: url)
            return FormGhostBuilder.build(model: model, shot: shot, sessions: sessions)
        }.value
        ghostSearched = true
        ghost = built
        ActivityLog.shared.event("form.ghost", ["bestReps": built.isBestRepGhost,
                                                "shots": built.model.shots,
                                                "unavailable": built.unavailableReason])
        guard built.isAvailable else { return }
        let g = built.model
        let samples = g.samples.map { s in (0..<g.joints.count).map { s.position($0) } }
        let S = FormSampling.stature(joints: g.joints, samples: samples)
        scene.setGhost(FormLayer(joints: g.joints, inferred: g.inferredBySymmetry, style: .ghost,
                                 boneLengths: FormSampling.lengths(of: g), showsEllipsoids: showEllipsoids,
                                 stature: S,
                                 facingLock: S.flatMap { FormSampling.facingLock(joints: g.joints, samples: samples, stature: $0) }))
        scene.ghostLayer?.setVisible(showGhost)
        if self.shot == nil, stops.isEmpty {
            let joints = g.joints
            stops = FormPhaseStops.normalised(joints: joints,
                                              samples: g.samples.map { s in
                                                  (t: s.t, positions: (0..<joints.count).map { j in s.position(j) }) })
        }
        redraw()
    }

    private func loadEarlier(_ id: UUID?) {
        guard let id, let s = earlierSessions.first(where: { $0.id == id }) else {
            earlierModel = nil
            scene.setEarlier(nil)
            return
        }
        let m = s.formModel
        earlierModel = m
        ActivityLog.shared.event("form.compare", ["session": s.id.uuidString, "shots": m.shots,
                                                  "unavailable": m.unavailableReason])
        guard m.isAvailable else { scene.setEarlier(nil); return }
        let samples = m.samples.map { s in (0..<m.joints.count).map { s.position($0) } }
        let S = FormSampling.stature(joints: m.joints, samples: samples)
        scene.setEarlier(FormLayer(joints: m.joints, inferred: m.inferredBySymmetry, style: .earlier,
                                   boneLengths: FormSampling.lengths(of: m), showsEllipsoids: showEllipsoids,
                                   stature: S,
                                   facingLock: S.flatMap { FormSampling.facingLock(joints: m.joints, samples: samples, stature: $0) }))
        redraw()
    }

    private func tapped(_ index: Int?) {
        guard let index else { return }              // a tap on empty space leaves the card alone
        select(selectedJoint == index ? nil : index)
    }

    private func select(_ index: Int?) {
        selectedJoint = index
        scene.shotLayer?.highlight(index)
        scene.ghostLayer?.highlight(shot == nil ? index : nil)
        if let index, activeJoints.indices.contains(index) {
            ActivityLog.shared.event("form.joint", ["joint": activeJoints[index], "tau": tau])
        }
        redraw()
    }

    private func redraw() {
        let shotPositions = shot.map { FormSampling.positions(of: $0, at: tau) }
        if let layer = scene.shotLayer, let p = shotPositions {
            layer.update(positions: p, spreads: nil)
            layer.setVisible(true)
        }
        if let g = ghost, g.isAvailable, let layer = scene.ghostLayer {
            let (p, s) = FormSampling.positions(of: g.model, at: tau)
            // Item 19: aligned at the mid-hip at the same phase time, so the ghost is a difference in
            // shape rather than a difference in where the shooter stood.
            if let sp = shotPositions, let f = shot {
                layer.offset = FormGhostBuilder.midHipOffset(ghost: p, ghostJoints: g.model.joints,
                                                             shot: sp, shotJoints: f.joints)
            } else {
                layer.offset = .zero
            }
            layer.update(positions: p, spreads: s)
            layer.setVisible(showGhost)
        }
        if let e = earlierModel, e.isAvailable, let layer = scene.earlierLayer {
            let (p, s) = FormSampling.positions(of: e, at: tau)
            layer.update(positions: p, spreads: s)
        }
    }

    /// Playback at the block's **real** tempo: step the real clock, then find the normalised time
    /// that corresponds to it. Stepping τ directly would play a slow dip at the same speed as a fast
    /// one, which is the whole thing the normalised axis was built to hide.
    private func advance() {
        guard playing else { return }
        let dt = 1.0 / 60.0
        guard let now = realTime(at: tau), let span = realSpan else { playing = false; return }
        let next = now + dt
        if next >= span.upperBound {
            tau = 1
            playing = false
        } else {
            tau = normalisedTime(at: max(span.lowerBound, next))
        }
        redraw()
    }

    private var timeTable: [(t: Double, dt: Double)] {
        if let f = shot { return f.samples.map { ($0.t, $0.dt) } }
        return model.samples.filter { $0.dt.isFinite }.map { ($0.t, $0.dt) }
    }

    private var realSpan: ClosedRange<Double>? {
        let table = timeTable
        guard let lo = table.first?.dt, let hi = table.last?.dt, hi > lo else { return nil }
        return lo...hi
    }

    private func realTime(at tau: Double) -> Double? {
        let table = timeTable
        guard let first = table.first, let last = table.last else { return nil }
        if tau <= first.t { return first.dt }
        if tau >= last.t { return last.dt }
        for i in 1..<table.count where table[i].t >= tau {
            let a = table[i - 1], b = table[i]
            let f = b.t > a.t ? (tau - a.t) / (b.t - a.t) : 0
            return a.dt + f * (b.dt - a.dt)
        }
        return last.dt
    }

    private func normalisedTime(at dt: Double) -> Double {
        let table = timeTable
        guard let first = table.first, let last = table.last else { return tau }
        if dt <= first.dt { return first.t }
        if dt >= last.dt { return last.t }
        for i in 1..<table.count where table[i].dt >= dt {
            let a = table[i - 1], b = table[i]
            let f = b.dt > a.dt ? (dt - a.dt) / (b.dt - a.dt) : 0
            return a.t + f * (b.t - a.t)
        }
        return last.t
    }

    private func sampleIndex(at tau: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return min(count - 1, max(0, Int((tau * Double(count - 1)).rounded())))
    }

}
