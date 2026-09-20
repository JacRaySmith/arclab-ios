import SceneKit
import ShotGeometry
import SwiftUI
import UIKit

// ================================================================================================
// MARK: - The 3-D body player
// ================================================================================================
//
// One real shot, played back as a proportioned body (`SceneBody.swift`) off its own `BodyShot` file:
// every frame the analysis processed, at the tempo it was shot at, with the phase times, the fitted
// angles and the model's warnings beside it.
//
// The rules the screen holds, because a rendering is more persuasive than a table:
//
//   · Positions are the file's. A joint it does not carry is **not drawn**; one it flags
//     `symmetryInferred` is drawn translucent and no number is read off it.
//   · Thicknesses are drawn proportions, not measurements, and the provenance card says so.
//   · Every angle is the file's own track. Outside a track's samples — or where the export refused
//     the track outright — the reason is printed, never a number.
//   · The phase markers are only the phases the export found. A dip it refused is absent from the
//     timeline and its sentence is under it.
//
// 1.2 (docs/IMPROVEMENTS-2026-09-16.md §1.4): it opens on the **release** frame, the six stops on the
// clock are a segmented control (`FormPhaseStops` — four this file times, two derived from its own
// samples and labelled as such), the camera presets are the shared ones (`FormCameraPresets`, so the
// skeleton viewer and this agree where "side" is), and every number over the scene sits on an opaque
// scrim on a fixed dark ground.

// MARK: - The files on the phone

/// One `BodyShot` file, as the library list shows it. Metadata only: the files are ≈ 1 MB each and
/// nothing is decoded until a row is opened.
struct BodyShotFileRef: Identifiable, Hashable, Sendable {
    var url: URL
    /// The directory the writer used: the clip's name (a session has no UUID until it is saved).
    var clip: String
    var shotID: Int?
    var date: Date
    var bytes: Int

    var id: URL { url }
    var shotLabel: String { shotID.map { "Shot \($0)" } ?? url.deletingPathExtension().lastPathComponent }

    static func all(limit: Int = 200) -> [BodyShotFileRef] {
        BodyShotWriter.list().prefix(limit).map { u in
            let values = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return BodyShotFileRef(url: u,
                                   clip: u.deletingLastPathComponent().lastPathComponent,
                                   shotID: Int(u.deletingPathExtension().lastPathComponent),
                                   date: values?.contentModificationDate ?? .distantPast,
                                   bytes: values?.fileSize ?? 0)
        }
    }
}

/// The "Your shots in 3-D" row. The same row on the session screen and on Progress.
struct BodyShotsRow: View {
    /// For the activity log: which screen the row was tapped on.
    var source: String

    @State private var count: Int?

    var body: some View {
        NavigationLink {
            BodyShotLibraryView(source: source)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your shots in 3-D")
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "figure.basketball.circle")
            }
        }
        .task { if count == nil { count = BodyShotWriter.list().count } }
    }

    private var subtitle: String {
        switch count {
        case .none: return "Looking for saved body files…"
        case .some(0): return "No body files yet: they are written for accepted shots once the body stage has run."
        case .some(1): return "One shot, played back as a body at the tempo it was shot at."
        case .some(let n): return "\(n) shots, each played back as a body at the tempo it was shot at."
        }
    }
}

/// Every `BodyShot` file on the phone, newest first, grouped by the clip it came from.
struct BodyShotLibraryView: View {
    var source: String = "library"
    @State private var files: [BodyShotFileRef] = []
    @State private var loaded = false

    private var groups: [(clip: String, files: [BodyShotFileRef])] {
        var order: [String] = []
        var byClip: [String: [BodyShotFileRef]] = [:]
        for f in files {
            if byClip[f.clip] == nil { order.append(f.clip) }
            byClip[f.clip, default: []].append(f)
        }
        return order.map { ($0, (byClip[$0] ?? []).sorted { ($0.shotID ?? 0) < ($1.shotID ?? 0) }) }
    }

    var body: some View {
        List {
            if loaded && files.isEmpty {
                Section {
                    Text("No body files yet. One is written for every shot the block rule accepts, once the body stage has run on it — analyse a session and they appear here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(groups, id: \.clip) { group in
                Section {
                    ForEach(group.files) { file in
                        NavigationLink {
                            BodyPlayerView(title: "\(group.clip) · \(file.shotLabel)", file: file, source: source)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.shotLabel)
                                    Text(file.date, format: .dateTime.day().month().year().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text(group.clip)
                }
            }
        }
        .navigationTitle("Your shots in 3-D")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            files = BodyShotFileRef.all()
            loaded = true
            ActivityLog.shared.event("screen", ["name": "bodyLibrary", "source": source, "files": files.count])
        }
    }
}

// MARK: - Per-frame timings

/// How long one frame of playback takes to push into the scene, summarised every `every` frames.
///
/// A class held in `@State`: counting a frame must not invalidate the view, or the measurement
/// would be measuring itself. Reported through `body.player.frame` so the only machine that can
/// answer "is the phone keeping up?" — the phone — puts the number in the log.
@MainActor
final class BodyPlayerFrameStats {
    struct Report: Sendable {
        var count: Int
        var meanMillis: Double
        var worstMillis: Double
    }

    private let every: Int
    private var count = 0
    private var totalMillis = 0.0
    private var worstMillis = 0.0

    init(every: Int = 30) { self.every = max(1, every) }

    /// Record one applied frame. Returns a report on every `every`-th call, nil otherwise.
    func note(millis: Double) -> Report? {
        count += 1
        totalMillis += millis
        worstMillis = max(worstMillis, millis)
        guard count % every == 0 else { return nil }
        let report = Report(count: count,
                            meanMillis: (totalMillis / Double(count) * 100).rounded() / 100,
                            worstMillis: (worstMillis * 100).rounded() / 100)
        worstMillis = 0
        return report
    }
}

// MARK: - The SceneKit surface

/// `SCNView` rather than `SceneView`, so the camera presets can move the point of view *and* leave
/// the viewer free to keep orbiting from wherever they put it.
private struct BodySceneContainer: UIViewRepresentable {
    let scene: SceneBodyScene
    /// Bumped whenever a preset is chosen, so `updateUIView` knows to re-aim.
    var presetToken: Int
    /// True while the transport is moving the body frame by frame.
    ///
    /// This is the fix for the 1.3.1 report "the image turns black and is only seen again at the
    /// end". `SCNView` with `rendersContinuously = false` only presents a new drawable when
    /// SceneKit's own change tracking decides the scene moved (SCNView.h: "the view will only
    /// redraw when something change or animates in the receiver's scene"). The playback here moves
    /// ~35 node transforms from a `Timer` on the main run loop — outside SceneKit's animation
    /// machinery and outside any `SCNTransaction` — and then asks for a redraw with
    /// `UIView.setNeedsDisplay()`, which does not drive a Metal-backed SceneKit renderer at all.
    /// While that is happening no drawable is presented and the view shows its clear colour: the
    /// dark ground the shooter reads as black. It comes back at the end because stopping produces
    /// an ordinary layout/state change that does force one render.
    ///
    /// `rendersContinuously` is what the property is for, so it is turned on exactly while the
    /// body is being animated and off again when it is parked (a still 3-D scene should not hold
    /// the GPU at 60 fps on a phone).
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
        aim(view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
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
    final class Coordinator { var token = -1 }
}

// MARK: - The player

struct BodyPlayerView: View {
    let title: String
    /// Where to read the record from, when the screen was opened from the library.
    var file: BodyShotFileRef?
    /// The record the results screen already has in memory, when it was opened from a shot.
    var preloaded: BodyShot?
    /// The block's mean form, for the overlay. Only used when its unit matches the file's.
    var meanForm: FormModel?
    var source: String

    @State private var shot: BodyShot?
    @State private var playback: BodyShotPlayback?
    @State private var scene: SceneBodyScene?
    @State private var meanLayer: FormLayer?
    @State private var loadError: String?

    @State private var index = 0
    @State private var playing = false
    @State private var speed = 1.0
    @State private var preset: SceneBodyCamera = .side
    @State private var presetToken = 0
    @State private var showMean = false
    @State private var clock: Double = 0
    /// The six stops on this file's own clock (item 18). Built once, with the file the screen loaded.
    @State private var stops: [FormClockStop] = []
    /// The stop the viewer asked for that this file never timed, so the screen can say why.
    @State private var refusedStop: String?
    /// True while a finger is on the scrubber. A drag moves the body exactly as fast as playback
    /// does, so the renderer has to be driven the same way (see `BodySceneContainer.isAnimating`).
    @State private var scrubbing = false
    /// How many of this frame's joints the file actually carries. Zero means there is nothing to
    /// draw on this frame, and the screen says so rather than leaving an empty scene unexplained.
    @State private var drawnJoints = 0
    /// Per-frame timings for `body.player.frame`. A class, so counting a frame does not invalidate
    /// the view thirty times a second.
    @State private var frameStats = BodyPlayerFrameStats()

    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let shot, let playback, let scene {
                content(shot, playback, scene)
            } else if let loadError {
                ContentUnavailableView("No body file", systemImage: "figure.basketball",
                                       description: Text(loadError))
            } else {
                ProgressView("Reading the body file…").frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onReceive(tick) { _ in advance() }
        .onDisappear { playing = false; scrubbing = false }
    }

    // MARK: Loading

    private func load() async {
        guard shot == nil, loadError == nil else { return }
        var record = preloaded
        if record == nil, let file {
            let url = file.url
            record = await Task.detached(priority: .userInitiated) { () -> BodyShot? in
                BodyShotWriter.load(url: url)
            }.value
            if record == nil {
                loadError = "this body file could not be read: it is either from a schema version this build does not know, or it was written by a newer one."
                return
            }
        }
        guard let record else {
            loadError = "no body file was handed to this screen and none was named on disk."
            return
        }
        guard !record.frames.isEmpty else {
            loadError = "the body file has no frames in it, so there is nothing to play."
            return
        }
        let play = BodyShotPlayback(record)
        let built = SceneBodyScene(shot: record, background: FormSceneModel.background)
        shot = record
        playback = play
        scene = built
        // Item 18: the screen opens on the release, not on the first frame.
        index = play.releaseIndex
        clock = play.times[min(index, play.times.count - 1)] - play.first
        stops = FormPhaseStops.real(shot: record, playback: play)
        built.body.update(frame: record.frames[index])
        drawnJoints = record.frames[index].fitted3D.count
        ActivityLog.shared.event("screen", ["name": "bodyPlayer", "source": source,
                                            "frames": record.frames.count,
                                            "unit": record.skeleton.unit,
                                            "fps": record.source.format.fps,
                                            "everyNth": record.timing.everyNthFrame,
                                            "openedAt": "release"])
    }

    // MARK: Playback

    private func advance() {
        guard playing, let playback, let shot, let scene else { return }
        clock += (1.0 / 60.0) * speed
        if clock > playback.duration { clock = 0 }
        let next = playback.index(atRealTime: playback.first + clock)
        guard next != index else { return }
        index = next
        apply(frame: shot.frames[index], scene: scene, playback: playback)
    }

    private func seek(to newIndex: Int) {
        guard let playback, let shot, let scene else { return }
        let clamped = min(max(0, newIndex), shot.frames.count - 1)
        index = clamped
        clock = playback.times[min(clamped, playback.times.count - 1)] - playback.first
        apply(frame: shot.frames[clamped], scene: scene, playback: playback)
    }

    /// The only per-frame work: the body's transforms, and the mean form's when it is on.
    ///
    /// Timed, because the phone is the only place this can be measured: `body.player.frame` carries
    /// how long one frame takes to apply, so a stall on the real device is a number in the log
    /// rather than a description of a black picture.
    private func apply(frame: BodyShotFrame, scene: SceneBodyScene, playback: BodyShotPlayback) {
        let t0 = CFAbsoluteTimeGetCurrent()
        scene.body.update(frame: frame)
        if showMean, let layer = meanLayer, let model = meanForm, let tau = normalisedTime(at: frame.t_real) {
            let (positions, _) = FormSampling.positions(of: model, at: tau)
            layer.update(positions: positions, spreads: nil)
        }
        let drawn = frame.fitted3D.count
        if drawn != drawnJoints { drawnJoints = drawn }
        if let report = frameStats.note(millis: 1000 * (CFAbsoluteTimeGetCurrent() - t0)) {
            ActivityLog.shared.event("body.player.frame", [
                "index": index, "frames": playback.count, "joints": drawn,
                "meanMs": report.meanMillis, "worstMs": report.worstMillis, "n": report.count,
                "playing": playing, "scrubbing": scrubbing, "speed": speed,
            ])
        }
    }

    // MARK: The screen

    @ViewBuilder private func content(_ shot: BodyShot, _ playback: BodyShotPlayback, _ scene: SceneBodyScene) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BodySceneContainer(scene: scene, presetToken: presetToken,
                                   isAnimating: playing || scrubbing)
                    .frame(height: 400)
                    .background(FormSceneChrome.sceneBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) { legend(shot).padding(8) }
                    .overlay(alignment: .bottomTrailing) { frameStamp(playback).padding(8) }
                    .overlay(alignment: .center) { emptyFrameNote }
                    .accessibilityLabel("A rotatable 3-D body playing back this shot")
                cameraRow(scene)
                phaseRow(playback)
                timeline(shot, playback)
                transport(shot, playback)
                if meanForm != nil { meanToggle(shot, scene) }
                angleCard(shot, playback)
                phaseCard(playback)
                provenanceCard(shot, scene)
            }
            .padding(.horizontal)
            .padding(.bottom, 28)
        }
    }

    private func legend(_ shot: BodyShot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let side = shot.shootingSide {
                swatch(Color(SceneBodyPalette.standard.shooting), "\(side) arm — shooting")
                swatch(Color(SceneBodyPalette.standard.guideArm), "\(side == "right" ? "left" : "right") arm — guide")
            } else {
                swatch(Color(SceneBodyPalette.standard.neutral), "shooting side not decided: both arms neutral")
            }
            if !shot.symmetryInferred.isEmpty {
                swatch(Color(SceneBodyPalette.standard.neutral).opacity(0.35),
                       "\(shot.symmetryInferred.count) joint\(shot.symmetryInferred.count == 1 ? "" : "s") mirrored, drawn faint")
            }
            if let h = shot.hands {
                let right = h.orientedFraction["right"] ?? 0, left = h.orientedFraction["left"] ?? 0
                Text(String(format: "hand plate on %.0f %%/%.0f %% of frames (right/left); size is a prior", 100 * right, 100 * left))
                    .foregroundStyle(FormSceneChrome.secondaryText)
            }
        }
        .font(.caption2)
        .foregroundStyle(FormSceneChrome.secondaryText)
        .formSceneScrim(corner: 8)
    }

    private func swatch(_ colour: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(text).foregroundStyle(FormSceneChrome.text)
        }
    }

    /// An empty scene, explained. The rig hides every joint the file has no fitted position for, so
    /// a frame the pose pass lost is a picture of nothing; naming it beats a blank rectangle.
    @ViewBuilder private var emptyFrameNote: some View {
        if drawnJoints == 0 {
            Text("no fitted joints on this frame — there is nothing to draw here")
                .font(.caption2)
                .foregroundStyle(FormSceneChrome.secondaryText)
                .formSceneScrim(corner: 8)
        }
    }

    private func frameStamp(_ playback: BodyShotPlayback) -> some View {
        let t = playback.times.indices.contains(index) ? playback.times[index] : playback.releaseRealTime
        return Text(String(format: "frame %d / %d   %+.3f s from release", index + 1, playback.count,
                           playback.secondsFromRelease(t)))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(FormSceneChrome.secondaryText)
            .formSceneScrim(corner: 6)
    }

    // MARK: Camera

    private func cameraRow(_ scene: SceneBodyScene) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Camera", selection: $preset) {
                ForEach(SceneBodyCamera.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: preset) { _, new in
                scene.apply(new)
                presetToken += 1
                ActivityLog.shared.event("form.camera", ["preset": new.rawValue, "screen": "bodyPlayer"])
            }
            Text(preset.note(rimNote: scene.rimNote))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: The clock (item 18)

    /// Six stops, four of them this file's own phase times and two derived from its samples. A stop
    /// the file never timed moves nothing and says why — it is not nudged to a nearby frame.
    private func phaseRow(_ playback: BodyShotPlayback) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Phase", selection: Binding(get: { nearestStopKey(playback) },
                                               set: { jump(to: $0, playback: playback) })) {
                ForEach(stops) { stop in Text(stop.label).tag(stop.key) }
            }
            .pickerStyle(.segmented)
            if let stop = stops.first(where: { $0.key == nearestStopKey(playback) }), stop.isAvailable {
                Text(stop.provenance).font(.caption2).foregroundStyle(.secondary)
            }
            if let refused = stops.first(where: { $0.key == refusedStop }) {
                Text("\(refused.label) is not on this file's clock — \(refused.unavailableReason ?? "it was never timed")")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private func nearestStopKey(_ playback: BodyShotPlayback) -> String {
        let t = playback.times.indices.contains(index) ? playback.times[index] : playback.releaseRealTime
        let available = stops.filter(\.isAvailable)
        guard let best = available.min(by: { abs(($0.time ?? 0) - t) < abs(($1.time ?? 0) - t) }) else {
            return stops.first?.key ?? "release"
        }
        return best.key
    }

    private func jump(to key: String, playback: BodyShotPlayback) {
        guard let stop = stops.first(where: { $0.key == key }) else { return }
        guard let t = stop.time else { refusedStop = stop.key; return }
        refusedStop = nil
        playing = false
        seek(to: playback.index(atRealTime: t))
        ActivityLog.shared.event("form.phase", ["stop": key, "derived": stop.isDerived, "screen": "bodyPlayer"])
    }

    // MARK: Timeline and transport

    private func timeline(_ shot: BodyShot, _ playback: BodyShotPlayback) -> some View {
        let available = playback.phases.filter { $0.realTime != nil }
        return VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                let inset: CGFloat = 12
                let width = max(1, geo.size.width - inset * 2)
                ZStack(alignment: .topLeading) {
                    ForEach(available) { phase in
                        let f = CGFloat((phase.realTime! - playback.first) / playback.duration)
                        VStack(spacing: 1) {
                            Rectangle()
                                .fill(phase.name == "Release" ? Color.accentColor : Color.secondary)
                                .frame(width: 1.5, height: 10)
                            Text(phase.name)
                                .font(.system(size: 8))
                                .foregroundStyle(phase.name == "Release" ? Color.accentColor : .secondary)
                                .fixedSize()
                        }
                        .offset(x: inset + width * min(max(f, 0), 1) - 14)
                    }
                }
            }
            .frame(height: 24)
            Slider(value: Binding(get: { Double(index) },
                                  set: { seek(to: Int($0.rounded())) }),
                   in: 0...Double(max(1, shot.frames.count - 1)), step: 1,
                   onEditingChanged: { scrubbing = $0 })
            HStack {
                Text(String(format: "%+.2f s", playback.secondsFromRelease(playback.first)))
                Spacer()
                Text(String(format: "%+.2f s", playback.secondsFromRelease(playback.last)))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func transport(_ shot: BodyShot, _ playback: BodyShotPlayback) -> some View {
        HStack(spacing: 14) {
            Button { seek(to: index - 1) } label: { Image(systemName: "backward.frame.fill") }
                .disabled(index == 0)
            Button {
                playing.toggle()
                if playing, clock >= playback.duration - 1e-6 { clock = 0 }
                ActivityLog.shared.event("body.player.play", ["playing": playing, "speed": speed])
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.title2)
            }
            Button { seek(to: index + 1) } label: { Image(systemName: "forward.frame.fill") }
                .disabled(index >= shot.frames.count - 1)
            Spacer()
            Picker("Speed", selection: $speed) {
                Text("0.25×").tag(0.25)
                Text("0.5×").tag(0.5)
                Text("1×").tag(1.0)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
        .buttonStyle(.plain)
    }

    private func meanToggle(_ shot: BodyShot, _ scene: SceneBodyScene) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Overlay the block's mean form", isOn: Binding(get: { showMean },
                                                                 set: { setMeanOverlay($0, shot: shot, scene: scene) }))
                .font(.subheadline)
            Text(meanOverlayNote(shot)).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Numbers

    private func angleCard(_ shot: BodyShot, _ playback: BodyShotPlayback) -> some View {
        let t = playback.times.indices.contains(index) ? playback.times[index] : playback.releaseRealTime
        let tolerance = playback.frameStep * 1.5
        let side = shot.shootingSide ?? "right"
        let other = side == "right" ? "left" : "right"
        return GroupBox("At this frame") {
            VStack(alignment: .leading, spacing: 6) {
                angleRow("Shooting elbow", shot.angleDegrees("elbow" + side.capitalized, atRealTime: t, tolerance: tolerance))
                angleRow("Guide elbow", shot.angleDegrees("elbow" + other.capitalized, atRealTime: t, tolerance: tolerance))
                angleRow("Shooting knee", shot.angleDegrees("knee" + side.capitalized, atRealTime: t, tolerance: tolerance))
                angleRow("Guide knee", shot.angleDegrees("knee" + other.capitalized, atRealTime: t, tolerance: tolerance))
                angleRow("Shooting shoulder", shot.angleDegrees("shoulderElevation" + side.capitalized, atRealTime: t, tolerance: tolerance))
                angleRow("Wrist (shooting)", shot.angleDegrees("wristFlexion", atRealTime: t, tolerance: tolerance))
                angleRow("Trunk lean", shot.angleDegrees("trunkLean", atRealTime: t, tolerance: tolerance))
                if !shot.warnings.isEmpty {
                    Divider()
                    ForEach(Array(shot.warnings.enumerated()), id: \.offset) { _, w in
                        Label(w, systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func angleRow(_ label: String, _ value: (degrees: Double?, reason: String?)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                if let d = value.degrees {
                    Text(String(format: "%.0f°", d)).font(.subheadline.monospacedDigit().bold())
                } else {
                    Text("not measured").font(.caption).foregroundStyle(.secondary)
                }
            }
            if value.degrees == nil, let reason = value.reason {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func phaseCard(_ playback: BodyShotPlayback) -> some View {
        GroupBox("Phases") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(playback.phases) { phase in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(phase.name).font(.subheadline)
                            Spacer()
                            if let t = phase.realTime {
                                Button {
                                    seek(to: playback.index(atRealTime: t))
                                } label: {
                                    Text(String(format: "%+.3f s", playback.secondsFromRelease(t)))
                                        .font(.subheadline.monospacedDigit())
                                }
                                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            } else {
                                Text("none in this window").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if phase.realTime == nil, let reason = phase.unavailableReason {
                            Text(reason).font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text("Seconds are from the release. The quantisation floor on this file is \(String(format: "%.0f", playback.frameStep * 1000)) ms — one processed frame.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func provenanceCard(_ shot: BodyShot, _ scene: SceneBodyScene) -> some View {
        GroupBox("What you are looking at") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Every joint position is this file's fitted skeleton. The body's thickness — torso, limbs, head, hands — is a drawn proportion, not a measurement: nothing on the screen may be read as a number, and the numbers above are the file's own.")
                ForEach(Array(scene.proportions.notes.enumerated()), id: \.offset) { _, n in Text(n) }
                Text(scene.rimNote)
                if let h = shot.hands {
                    Text("The hand is drawn as an oriented **plate** — the fitted wrist, the index knuckle and the little knuckle — on every frame all three were confident. Its orientation is fitted from the two knuckles' own view rays; its **size is a population prior, not a measurement**: " + h.sizePrior.note)
                    Text(String(format: "A plate was fitted on %.0f %% of this window's frames on the right hand and %.0f %% on the left, of which %.0f %%/%.0f %% had all three points and therefore a palm normal. A frame with only two confident points has a direction but no roll, and is drawn as flat fingers instead; a frame with none gets a mitt. A plate drawn faint had a corner carried across one sampled frame or pulled onto the size prior.",
                                100 * (h.plateFraction["right"] ?? 0), 100 * (h.plateFraction["left"] ?? 0),
                                100 * (h.orientedFraction["right"] ?? 0), 100 * (h.orientedFraction["left"] ?? 0)))
                } else {
                    Text("Hand landmarks are 2-D, so the fingers are drawn flat in the image plane, anchored at the measured 3-D wrist. A frame with no landmarks gets a mitt.")
                }
                // The head: a skull on the neck, and a face only where the view supports one.
                if let why = scene.body.headFaceUnavailableReason {
                    Text("No face is drawn on this shot — " + why)
                } else {
                    Text("The skull sits behind the measured nose and on the fitted neck; the face side — nose, eyes, chin — is placed from the nose's own horizontal offset past the neck, which is the same cue the head-yaw metric uses. The skull's size and shape are adult proportions of this shooter's stature, not a measurement of their head.")
                }
                if !shot.symmetryInferred.isEmpty {
                    Text("Drawn faint and never quoted: " + shot.symmetryInferred.sorted().joined(separator: ", ") + " — mirrored from the other side of the body.")
                }
                Text(shot.skeleton.scaleNote)
                Text("\(shot.frames.count) frames · every \(shot.timing.everyNthFrame)\(shot.timing.everyNthFrame == 1 ? "" : "th") frame of \(String(format: "%.0f", shot.source.format.fps)) fps · field of view \(String(format: "%.1f", shot.source.format.hfovDegrees))° (\(shot.source.format.provenance))")
                if !shot.notes.isEmpty {
                    Divider()
                    ForEach(Array(shot.notes.enumerated()), id: \.offset) { _, n in Text(n) }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: The mean-form overlay

    /// The block's mean form is on the phase-normalised axis and the shot is on a real clock, so the
    /// two are married through the phase times the export vetted — and only those. With fewer than
    /// two of them there is no map, and the overlay says so rather than stretching one.
    private func normalisedTime(at t: Double) -> Double? {
        guard let shot else { return nil }
        var anchors: [(real: Double, tau: Double)] = [(shot.timing.releaseRealTime, FormPhase.release.normalisedTime)]
        if let s = shot.timing.set.value { anchors.append((s, FormPhase.set.normalisedTime)) }
        if let d = shot.timing.dip.value { anchors.append((d, FormPhase.dip.normalisedTime)) }
        if let f = shot.timing.followThroughPeak.value { anchors.append((f, FormPhase.followThrough.normalisedTime)) }
        guard anchors.count >= 2 else { return nil }
        anchors.sort { $0.real < $1.real }
        if t <= anchors[0].real { return anchors[0].tau }
        if t >= anchors[anchors.count - 1].real { return anchors[anchors.count - 1].tau }
        for k in 0..<(anchors.count - 1) {
            let a = anchors[k], b = anchors[k + 1]
            if t >= a.real, t <= b.real, b.real - a.real > 1e-9 {
                return a.tau + (b.tau - a.tau) * (t - a.real) / (b.real - a.real)
            }
        }
        return anchors[anchors.count - 1].tau
    }

    private func meanOverlayNote(_ shot: BodyShot) -> String {
        guard let model = meanForm else { return "" }
        if !model.isAvailable { return model.unavailableReason ?? "the block has no mean form." }
        guard unitsMatch(model, shot) else {
            let modelUnit = model.unit == .metres ? "metres" : "fractions of your height"
            let fileUnit = shot.skeleton.unit == "metres" ? "metres" : "fractions of your height"
            return "The block's mean form is in \(modelUnit) and this file is in \(fileUnit): the two cannot be drawn on top of each other without inventing a scale, so the overlay is off."
        }
        guard normalisedTime(at: shot.timing.releaseRealTime) != nil else {
            return "The mean form lives on the set → dip → release → follow-through axis and this file found only the release, so there is no map from its clock onto that axis."
        }
        return "The block's \(model.shots) accepted shot\(model.shots == 1 ? "" : "s") averaged, drawn in grey at the same phase as the frame on screen. The two clocks are married through the phase times this file found, nothing else."
    }

    private func unitsMatch(_ model: FormModel, _ shot: BodyShot) -> Bool {
        switch model.unit {
        case .metres: return shot.skeleton.unit == "metres"
        case .shooterHeights: return shot.skeleton.unit != "metres"
        }
    }

    private func setMeanOverlay(_ on: Bool, shot: BodyShot, scene: SceneBodyScene) {
        guard let model = meanForm, model.isAvailable, unitsMatch(model, shot),
              let tau = normalisedTime(at: shot.frames[min(index, shot.frames.count - 1)].t_real) else {
            showMean = false
            return
        }
        showMean = on
        if on {
            if meanLayer == nil {
                let layer = FormLayer(joints: model.joints, inferred: model.inferredBySymmetry,
                                      style: .ghost, boneLengths: FormSampling.lengths(of: model),
                                      showsEllipsoids: false)
                meanLayer = layer
                scene.contentNode.addChildNode(layer.root)
            }
            let (positions, _) = FormSampling.positions(of: model, at: tau)
            meanLayer?.update(positions: positions, spreads: nil)
            meanLayer?.setVisible(true)
            ActivityLog.shared.event("body.player.mean", ["shots": model.shots])
        } else {
            meanLayer?.setVisible(false)
        }
    }
}
