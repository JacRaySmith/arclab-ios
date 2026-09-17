// HandProbe — what the hand plates cover, and what they say, over exported `BodyShot` files.
//
// The coverage question 1.3 was asked to answer is "how often does a form carry the shooting wrist,
// the elbow and the index knuckle at the release instant (τ 0.75)?", so this tool rebuilds exactly
// that: BodyShot → timeline (hands included) → optional `HandPoints.lift` → `BodySkeletonFit` →
// `HandTriangleFit` → `ShotForm`, and reads the sample at τ 0.75.
//
//   swift run -c release HandProbe <dir-or-file> [--before] [--no-interpolate] [--no-wrist-fallback]
//                                 [--hand-confidence C] [--per-shot] [--side left|right]
//
// `--before` is the 1.2 baseline: no lift at all, so no appendage point exists and the table shows
// what the app carried before this build.
import Foundation
import simd
import ShotGeometry

var args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first, !path.hasPrefix("--") else {
    print("usage: HandProbe <dir-or-file.json> [--before] [--no-interpolate] [--no-wrist-fallback] [--hand-confidence C] [--per-shot] [--side S]")
    exit(2)
}
args.removeFirst()
let argv = args
func flag(_ n: String) -> String? {
    guard let i = argv.firstIndex(of: "--" + n), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
let before = argv.contains("--before")
let perShot = argv.contains("--per-shot")
let handConfidence = flag("hand-confidence").flatMap(Double.init) ?? 0.20
let interpolate = !argv.contains("--no-interpolate")
let wristFallback = !argv.contains("--no-wrist-fallback")
let forcedSide = flag("side")

func jsonFiles(_ url: URL) -> [URL] {
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    guard isDir.boolValue else { return url.pathExtension == "json" ? [url] : [] }
    let kids = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    var out: [URL] = []
    for k in kids {
        var kid: ObjCBool = false
        FileManager.default.fileExists(atPath: k.path, isDirectory: &kid)
        if kid.boolValue { out += jsonFiles(k) } else if k.pathExtension == "json" { out.append(k) }
    }
    return out.sorted { (Int($0.deletingPathExtension().lastPathComponent) ?? 0) < (Int($1.deletingPathExtension().lastPathComponent) ?? 0) }
}
let files = jsonFiles(URL(fileURLWithPath: path))
guard !files.isEmpty else { print("no .json under \(path)"); exit(2) }

func visionCamera(_ j: BodyShotJoint3D) -> SIMD3<Double> { SIMD3(j.x, -j.y, -j.z) }
func d(_ m: BodyMeasure) -> String { m.degrees.map { String(format: "%+7.1f°", $0) } ?? "    nil" }

struct Row {
    var file: String
    var side: String
    var wristAtRelease = false, elbowAtRelease = false, indexAtRelease = false, littleAtRelease = false
    var plateAtRelease = false, orientedAtRelease = false
    var rms: Double = .nan
    var handRms: Double = .nan
    var plateFraction: Double = 0
    var orientedFraction: Double = 0
    var wristFromHandPose = 0
    var interpolated = 0
    var measures: HandShotMeasures = .unavailable("not run")
    var breadthResidual: Double = .nan
}

var rows: [Row] = []
var reasons: [String: Int] = [:]

for f in files {
    guard let data = try? Data(contentsOf: f), let shot = try? BodyShot.decode(data) else {
        print("\(f.lastPathComponent): not a BodyShot this build can read"); continue
    }
    var frames: [BodyFrame] = []
    for sf in shot.frames {
        var p2: [String: BodyPoint2D] = [:]
        for (name, p) in sf.points2D { p2[name] = BodyPoint2D(name: name, u: p.u, v: p.v, confidence: p.confidence, provenance: p.provenance) }
        var j3: [String: BodyJoint3D] = [:]
        for (name, j) in sf.joints3D { j3[name] = BodyJoint3D(name: name, position: .zero, cameraPosition: visionCamera(j), confidence: j.confidence) }
        let hands = sf.hands.map { h in
            BodyHandFrame(chirality: h.chirality, role: h.role, confidence: h.confidence,
                          landmarks: h.landmarks.mapValues { BodyPoint2D(name: "", u: $0.u, v: $0.v, confidence: $0.confidence) })
        }
        frames.append(BodyFrame(frameIndex: sf.frameIndex, fileTime: sf.t_file, realTime: sf.t_real,
                                joints3D: j3, points2D: p2, hands: hands))
    }
    let fmtInfo = shot.source.format
    let K = CameraIntrinsics(width: fmtInfo.w, height: fmtInfo.h, horizontalFOVDegrees: fmtInfo.hfovDegrees)
    var lift = HandPoints.Report()
    if !before {
        var lo = HandPoints.Options()
        lo.minimumHandLandmarkConfidence = handConfidence
        lo.wristFromHandPose = wristFallback
        lo.interpolateAcrossSamples = interpolate ? 1 : 0
        let r = HandPoints.lift(frames: frames, options: lo)
        frames = r.frames; lift = r.report
    }
    let timeline = BodyTimeline(frames: frames, timeScale: 1, imageWidth: fmtInfo.w, imageHeight: fmtInfo.h,
                                everyNthFrame: shot.timing.everyNthFrame, decodedFrames: frames.count,
                                analysedFrames: frames.count, wallSeconds: 0, notes: [])
    var o = BodySkeletonOptions(intrinsics: K)
    if let h = shot.skeleton.standingHeight.value, shot.skeleton.scaleProvenance == "statedHeight" { o.scale = .statedHeight(metres: h) }
    let fit = BodySkeletonFit.fit(timeline: timeline, options: o)

    let side = forcedSide ?? shot.shootingSide ?? "right"
    var row = Row(file: f.deletingPathExtension().lastPathComponent, side: side)
    row.rms = fit.reprojectionRMSPixels.value ?? .nan
    row.wristFromHandPose = lift.wristsFilledFromHandPose
    row.interpolated = lift.pointsInterpolated

    var fitted = fit
    if !before {
        var ho = HandTriangleOptions(intrinsics: K)
        ho.minimumHandLandmarkConfidence = handConfidence
        ho.shootingSide = shot.shootingSide
        let r = HandTriangleFit.fit(timeline: fit.timeline, releaseRealTime: shot.timing.releaseRealTime, options: ho)
        fitted.timeline = r.timeline
        row.measures = r.measures
        if let track = r.tracks.first(where: { $0.side == side }) {
            row.plateFraction = Double(track.frames.count) / Double(max(1, track.framesInWindow))
            row.orientedFraction = Double(track.framesWithOrientation) / Double(max(1, track.framesInWindow))
            let errs = track.frames.compactMap { $0.reprojectionPixels.value }
            row.handRms = errs.isEmpty ? .nan : Stats.rms(errs)
            let br = track.frames.compactMap { $0.breadthResidual.value }
            row.breadthResidual = br.isEmpty ? .nan : Stats.median(br)
            if let at = track.nearest(shot.timing.releaseRealTime, within: 0.02) {
                row.plateAtRelease = true
                row.orientedAtRelease = at.pointsUsed >= 3
            }
        }
        if let why = r.tracks.first(where: { $0.side == side })?.unavailableReason { reasons[why, default: 0] += 1 }
    }

    // The form, and the sample at τ 0.75.
    let (form, why) = ShotForm.make(fit: fitted,
                                    setRealTime: shot.timing.set.value, dipRealTime: shot.timing.dip.value,
                                    releaseRealTime: shot.timing.releaseRealTime,
                                    followThroughRealTime: shot.timing.followThroughPeak.value,
                                    shootingSide: shot.shootingSide, shotID: shot.shotID)
    if let form {
        if let s = form.samples.first(where: { abs($0.t - 0.75) <= 1e-6 }) {
            func has(_ name: String) -> Bool { form.joints.firstIndex(of: name).map { s.position($0) != nil } ?? false }
            row.wristAtRelease = has(side + "Wrist")
            row.elbowAtRelease = has(side + "Elbow")
            row.indexAtRelease = has(side + "IndexMCP")
            row.littleAtRelease = has(side + "LittleMCP")
        } else {
            reasons["the form has no sample at τ 0.75 (the release anchor is missing)", default: 0] += 1
        }
    } else if let why {
        reasons[why, default: 0] += 1
    }
    rows.append(row)
}

let total = rows.count
func pct(_ n: Int) -> String { String(format: "%2d/%2d (%3.0f %%)", n, total, 100 * Double(n) / Double(max(1, total))) }
func med(_ xs: [Double]) -> Double { xs.isEmpty ? .nan : Stats.median(xs.filter { $0.isFinite }) }

print("")
print("HandProbe — \(rows.count) shot(s) under \(path)\(before ? "   [BEFORE: no hand lift, 1.2 behaviour]" : "   [AFTER: hand floor \(handConfidence), wrist fallback \(wristFallback), interpolate \(interpolate)]")")
print("")
print("coverage at the release instant, τ 0.75 of each shot's own form")
print("  shooting wrist   \(pct(rows.filter(\.wristAtRelease).count))")
print("  shooting elbow   \(pct(rows.filter(\.elbowAtRelease).count))")
print("  index MCP        \(pct(rows.filter(\.indexAtRelease).count))")
print("  little MCP       \(pct(rows.filter(\.littleAtRelease).count))")
print("  plate (≥2 pts)   \(pct(rows.filter(\.plateAtRelease).count))")
print("  plate oriented   \(pct(rows.filter(\.orientedAtRelease).count))")
print(String(format: "skeleton reprojection RMS: median %.2f px over %d shots", med(rows.map(\.rms)), rows.count))
print(String(format: "hand-plate reprojection RMS: median %.2f px; breadth residual median %+.1f %%",
             med(rows.map(\.handRms)), 100 * med(rows.map(\.breadthResidual))))
print(String(format: "plate over the whole window: %.0f %% of frames, %.0f %% oriented; wrists taken from the hand pose: %d total; points bridged across one sample: %d total",
             100 * med(rows.map(\.plateFraction)), 100 * med(rows.map(\.orientedFraction)),
             rows.reduce(0) { $0 + $1.wristFromHandPose }, rows.reduce(0) { $0 + $1.interpolated }))

if !before {
    print("")
    print("what the plates say at the release (median over the shots that have one)")
    func stat(_ pick: (HandShotMeasures) -> BodyMeasure, _ label: String) {
        let xs = rows.compactMap { pick($0.measures).degrees }
        let reason = rows.compactMap { pick($0.measures).unavailableReason }.first
        if xs.isEmpty {
            print("  " + label.padding(toLength: 34, withPad: " ", startingAt: 0) + " nil — " + (reason ?? "no reason recorded"))
        } else {
            let s = xs.sorted()
            print(String(format: "  %@ %+7.1f°   (n = %d of %d, p10 %+.1f, p90 %+.1f)",
                         label.padding(toLength: 34, withPad: " ", startingAt: 0),
                         Stats.median(xs), xs.count, total, s[Int(0.1 * Double(s.count - 1))], s[Int(0.9 * Double(s.count - 1))]))
        }
    }
    stat({ $0.palmToRimBearingAtRelease }, "palm normal to the rim bearing")
    stat({ $0.palmToVerticalAtRelease }, "palm normal to vertical")
    stat({ $0.pointingToVerticalAtRelease }, "hand pointing to vertical")
    stat({ $0.rollAtRelease }, "roll")
    stat({ $0.wristFlexionAtRelease }, "wrist flexion at release")
    stat({ $0.wristFlexionChangeThroughRelease }, "wrist flexion change ±80 ms")
    stat({ $0.wristFlexionRangeThroughRelease }, "wrist flexion range ±80 ms")
    stat({ $0.guideContactPlaneToShotPlane }, "guide contact plane to shot plane")
}
if !reasons.isEmpty {
    print("")
    print("reasons")
    for (why, n) in reasons.sorted(by: { $0.value > $1.value }) { print("  ×\(n)  \(why)") }
}
if perShot {
    print("")
    print("file  wrist elbow index little  plate%  orient%  rms  handRms  flexion")
    for r in rows {
        print(String(format: "%5@  %@    %@     %@     %@   %5.0f    %5.0f  %5.2f  %6.2f  %@",
                     r.file, r.wristAtRelease ? "y" : ".", r.elbowAtRelease ? "y" : ".",
                     r.indexAtRelease ? "y" : ".", r.littleAtRelease ? "y" : ".",
                     100 * r.plateFraction, 100 * r.orientedFraction, r.rms, r.handRms,
                     d(r.measures.wristFlexionAtRelease)))
    }
}
