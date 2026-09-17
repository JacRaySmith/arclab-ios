import Foundation
import ShotGeometry
import ShotVideo
import simd

/// `TrajectoryProbe bodyexport <clip> --start <file s> --end <file s> --release-time <file s> [--out x.json]`
///
/// Runs the app's body stage (tracker → skeleton fit → kinematics) on one window and writes the same
/// `BodyShot` JSON the phone files under `Documents/ArcLab/body/` (docs/BIOMETRIC-SCHEMA.md), so the
/// schema can be checked on the Mac against a real clip.
enum BodyExportCommand {
    static func run(clip: URL, args: [String]) async throws {
        func flag(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let start = flag("--start").flatMap(Double.init), let end = flag("--end").flatMap(Double.init),
              let releaseFile = flag("--release-time").flatMap(Double.init) else {
            print("""
            usage: TrajectoryProbe bodyexport <clip.mov> --start <file s> --end <file s> --release-time <file s>
                     [--time-scale 1] [--every N (default: 2 when the real rate is ≥ 100 fps)] [--hfov <deg, default 48>]
                     [--hfov-provenance sidecar|assumed|gravity-calibrated] [--height <shooter metres>]
                     [--shooting-side left|right] [--rim-u <px>] [--shot-id N] [--out <file.json>]
                     [--limb-bone-weight 3] [--bone-weight 0.3] [--limb-prior on|off] [--floor-median-frames 5]
            """)
            return
        }
        let scale = flag("--time-scale").flatMap(Double.init) ?? 1
        let hfov = flag("--hfov").flatMap(Double.init) ?? 48
        let side = flag("--shooting-side")
        let rimU = flag("--rim-u").flatMap(Double.init)
        let releaseReal = releaseFile / scale

        let probe = try await VideoReader(url: clip).quickProbe(maxFrames: 60)
        let fps = probe.measuredFrameRate
        let realFPS = fps * scale
        let step = flag("--every").flatMap(Int.init) ?? (realFPS >= 100 ? 2 : 1)

        var options = BodyTracker.Options()
        options.everyNthFrame = step
        options.timeScale = scale
        options.shootingSide = side
        options.handFocusRealTimeRange = (releaseReal - 0.4)...(releaseReal + 0.4)
        print(String(format: "bodyexport: %@  window %.3f→%.3f file s, %dx%d at %.2f fps (real %.0f), every %d, release %.3f file s",
                     clip.lastPathComponent, start, end, probe.width, probe.height, fps, realFPS, step, releaseFile))
        let t0 = Date()
        let timeline = try await BodyTracker.run(url: clip, start: start, end: end, options: options, ballSeed: [], fps: fps)
        let tVision = Date().timeIntervalSince(t0)
        guard timeline.frames.contains(where: { !$0.points2D.isEmpty }) else {
            print("  Vision found no body on any frame of the window; nothing to export"); return
        }

        var fo = BodySkeletonOptions(intrinsics: CameraIntrinsics(width: timeline.imageWidth, height: timeline.imageHeight, horizontalFOVDegrees: hfov))
        if let h = flag("--height").flatMap(Double.init) { fo.scale = .statedHeight(metres: h) }
        // Iteration-4 sweep knobs (defaults are the shipped ones).
        if let w = flag("--limb-bone-weight").flatMap(Double.init) { fo.limbBoneWeight = w }
        if let w = flag("--bone-weight").flatMap(Double.init) { fo.boneWeight = w }
        if let v = flag("--limb-prior") { fo.limbLengthPriorFromStature = (v == "on" || v == "true" || v == "1") }
        if let n = flag("--floor-median-frames").flatMap(Int.init) { fo.projectionFloorMedianFrames = n }
        if let w = flag("--smoothness").flatMap(Double.init) { fo.smoothnessWeight = w }
        let t1 = Date()
        var fit = BodySkeletonFit.fit(timeline: timeline, options: fo)
        let tFit = Date().timeIntervalSince(t1)

        // The hand plates (1.3). They sit on the fitted wrist, so they run after the fit and before
        // the record is assembled; `HandTriangleFit` also writes its knuckles into the timeline it
        // returns, which is the timeline the kinematics and the form then see.
        var ho = HandTriangleOptions(intrinsics: fo.intrinsics)
        ho.shootingSide = side
        ho.rimImageU = rimU
        let handFit = HandTriangleFit.fit(timeline: fit.timeline, releaseRealTime: releaseReal, options: ho)
        fit.timeline = handFit.timeline

        var ko = BodyKinematicsOptions(shootingSide: side)
        ko.transverseYawUnavailableReason = fit.transverseYawUnavailableReason
        ko.dipIsLastTurningPoint = true
        let model = BodyKinematics.model(timeline: fit.timeline, releaseRealTime: releaseReal, rimImageU: rimU, options: ko)

        let source = BodyShotSource(kind: "cli", build: "TrajectoryProbe", device: "mac",
                                    format: BodyShotFormat(w: timeline.imageWidth, h: timeline.imageHeight, fps: realFPS,
                                                           hfovDegrees: hfov, provenance: flag("--hfov-provenance") ?? "assumed"))
        let shot = BodyShot.make(rawTimeline: timeline, fit: fit, model: model, releaseRealTime: releaseReal,
                                 setRealTime: model.phases.setPoint, dipRealTime: BodyShot.vettedDip(model.phases),
                                 followThroughPeakRealTime: model.phases.followThroughPeak, realFrameRate: realFPS,
                                 source: source, rimImageU: rimU, shotID: flag("--shot-id").flatMap(Int.init),
                                 handTriangles: handFit)
        let data = try shot.encoded()
        let out = URL(fileURLWithPath: flag("--out") ?? "\(clip.deletingPathExtension().lastPathComponent)-\(Int(releaseFile)).bodyshot.json")
        try data.write(to: out, options: .atomic)
        let decoded = try BodyShot.decode(data)   // the file must read back under this schema
        print(String(format: "  wrote %@: %d bytes, %d frames (vision %.1f s, fit %.1f s); re-read OK: %d frames",
                     out.path, data.count, shot.frames.count, tVision, tFit, decoded.frames.count))
        print("  skeleton: unit \(shot.skeleton.unit) (\(shot.skeleton.scaleProvenance)), \(shot.skeleton.boneLengths.count) bones, symmetric prior \(shot.skeleton.symmetricPrior), reprojection RMS \(fit.reprojectionRMSPixels.value.map { String(format: "%.2f px", $0) } ?? "nil")")
        for n in fit.notes where n.hasPrefix("reprojection RMS by joint") || n.hasPrefix("limb lengths") { print("  " + n) }
        for (name, b) in shot.skeleton.boneLengths.sorted(by: { $0.key < $1.key }) where BodySkeletonFit.limbBoneNames.contains(name) || name == "biacromial" {
            print(String(format: "    %@ %.4f %@ (mad %.4f, %@)", name, b.length, shot.skeleton.unit, b.mad, b.source ?? "?"))
        }
        print("  timing: release \(shot.timing.releaseRealTime) s, set \(shot.timing.set.value.map { String($0) } ?? "nil (\(shot.timing.set.unavailableReason ?? "?"))"), dip \(shot.timing.dip.value.map { String($0) } ?? "nil (\(shot.timing.dip.unavailableReason ?? "?"))"), floor \(shot.timing.quantisationFloor * 1000) ms")
        for (name, t) in shot.angles.sorted(by: { $0.key < $1.key }) {
            print("  angle \(name): \(t.samples.count) samples" + (t.unavailableReason.map { " — \($0)" } ?? ""))
        }
        print("  chain: \(shot.events.order.joined(separator: " → ")) lags \(shot.events.lagsMs) ms (floor \(shot.events.lagFloorMs))" + (shot.events.unavailableReason.map { " — \($0)" } ?? ""))
        print("  symmetry-inferred: \(shot.symmetryInferred)")
        if let h = shot.hands {
            print("  hands: plate fraction \(h.plateFraction), oriented \(h.orientedFraction); size prior \(h.sizePrior.breadthFractionOfStature) × stature across the MCPs (population prior)")
            print("    palm to vertical \(h.palmToVerticalAtRelease.value.map { String(format: "%.1f°", $0 * 180 / .pi) } ?? "nil (\(h.palmToVerticalAtRelease.unavailableReason ?? "?"))")")
            print("    palm to rim bearing \(h.palmToRimBearingAtRelease.value.map { String(format: "%.1f°", $0 * 180 / .pi) } ?? "nil (\(h.palmToRimBearingAtRelease.unavailableReason ?? "?"))")")
            print("    wrist flexion at release \(h.wristFlexionAtRelease.value.map { String(format: "%+.1f°", $0 * 180 / .pi) } ?? "nil (\(h.wristFlexionAtRelease.unavailableReason ?? "?"))")")
            print("    guide contact plane \(h.guideContactPlaneToShotPlane.value.map { String(format: "%.1f°", $0 * 180 / .pi) } ?? "nil (\(h.guideContactPlaneToShotPlane.unavailableReason ?? "?"))")")
        } else {
            print("  hands: no plate in this window")
        }
        for w in shot.warnings { print("  ! \(w)") }
    }
}
