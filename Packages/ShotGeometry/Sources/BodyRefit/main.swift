// BodyRefit — re-run `BodySkeletonFit` on exported `BodyShot` files.
//
// Why it exists. A BodyShot carries every input the skeleton fit consumes (the 2-D points with their
// confidences and Vision's raw 3-D, per frame) and the fit itself costs ~0.1 s, so an option can be
// swept over dozens of *real* shots from the phone without decoding a frame of video. Nothing here
// produces a measurement the app does not: it calls the same `BodySkeletonFit.fit`.
//
//   swift run -c release BodyRefit <dir-or-file> [--limb-bone-weight W] [--limb-prior on|off]
//                                 [--height M] [--hfov D] [--out-dir DIR] [--quiet] [--profile]
//
// `--profile` prints the wall time of each `BodySkeletonFit.fit` call and a summary line, which is
// how the solver's cost per shot is measured on real phone windows.
import Foundation
import simd
import ShotGeometry

func fmt(_ x: Double, _ d: Int = 3) -> String { x.isFinite ? String(format: "%.\(d)f", x) : "nil" }

var args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first, !path.hasPrefix("--") else {
    print("usage: BodyRefit <dir-or-file.json> [--limb-bone-weight W] [--limb-prior on|off] [--height M] [--hfov D] [--out-dir DIR] [--quiet] [--profile]")
    exit(2)
}
args.removeFirst()
let argv = args
func flag(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: "--" + name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
let limbWeight = flag("limb-bone-weight").flatMap(Double.init)
let limbPrior = flag("limb-prior").map { $0 == "on" }
let boneWeight = flag("bone-weight").flatMap(Double.init)
let smoothWeight = flag("smoothness-weight").flatMap(Double.init)
let sweeps = flag("sweeps").flatMap(Int.init)
let heightOverride = flag("height").flatMap(Double.init)
let hfovOverride = flag("hfov").flatMap(Double.init)
let transversePrior = flag("transverse-prior").map { $0 == "on" }
let torsoBreadth = flag("torso-breadth").map { $0 == "on" }
let visionPrior = flag("vision-prior").flatMap(Double.init)
let depthSmooth = flag("depth-smooth").flatMap(Double.init)
let floorFrames = flag("floor-frames").flatMap(Int.init)
let outDir = flag("out-dir")
let writeShotDir = flag("write-shot")
let quiet = argv.contains("--quiet")
let profile = argv.contains("--profile")
var fitSeconds: [(String, Double, Int)] = []

var files: [URL] = []
let url = URL(fileURLWithPath: path)
var isDir: ObjCBool = false
FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
if isDir.boolValue {
    files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension == "json" }
        .sorted { (Int($0.deletingPathExtension().lastPathComponent) ?? 0) < (Int($1.deletingPathExtension().lastPathComponent) ?? 0) } ?? []
} else { files = [url] }
guard !files.isEmpty else { print("no .json under \(path)"); exit(2) }

/// The export's camera frame (x right, y down, z forward) back into Vision's (x right, y up, z toward
/// the camera) — the convention `BodyFrame.joints3D` is stored in. The map is its own inverse.
func visionCamera(_ j: BodyShotJoint3D) -> SIMD3<Double> { SIMD3(j.x, -j.y, -j.z) }

struct Row {
    var file: String
    var rms: Double
    var bones: [String: Double]          // metres (or unit height)
    var perFrame: [String: (lo: Double, hi: Double, sd: Double)]   // fitted length ÷ its own median
    var stature: Double
    var elbowJitterDegrees: Double
    var kneeJitterDegrees: Double
    /// Median frame-to-frame displacement of the mid-hip, in stature units.
    var hipStep: Double
    var depthSigma: Double
    var unit: String
    /// Flatness (1.1). Every length is in stature units; every angle in degrees.
    var flat: Flatness
}

/// How much of the shot the fit put in the direction the camera cannot see.
///
/// The camera frame the fit writes is x image-horizontal, y up, z toward the camera, so "depth" is
/// z and "image plane" is (x, y). On a side-on view of a shot the *sagittal* excursion — the arm
/// travelling forward — lies in the image plane, and depth carries the body's **thickness**: the
/// stance width, the shoulder and hip lines, the near arm in front of the far one. A fit that is
/// "flat" is one where those depth separations have collapsed, so the shooter is a cardboard
/// cut-out when the viewer orbits to the front.
struct Flatness {
    /// Depth (z) range of a joint over set→release, stature units, and the same in the image plane.
    var elbowDepth: Double, elbowImage: Double
    var wristDepth: Double, wristImage: Double
    var kneeDepth: Double, kneeImage: Double
    /// Median over frames of (max z − min z) across every fitted joint: the body's own thickness.
    var bodyDepthExtent: Double
    /// Median |z_left − z_right| for the three transverse pairs.
    var shoulderDepthSep: Double, hipDepthSep: Double, ankleDepthSep: Double
    /// Shooting-side knee interior angle: its range over the window, degrees.
    var kneeFlexionRange: Double
    /// Shooting elbow interior angle range, degrees (the arm has to open ~60–90° into the release).
    var elbowAngleRange: Double
    /// Worst per-frame bone-length spread over the drawn segments, per cent of that bone's median.
    var worstBoneSD: Double
    /// Shooting-elbow interior angle range measured in the **image** over the same window. On a
    /// near-side view the shooting arm lies in the image plane, so this is the honest reference the
    /// 3-D range has to match: a 3-D arm that opens far less than the picture does is folded wrong.
    var elbowAngleRange2D: Double
    /// Median |z − mid-hip z| per joint, stature units: where the depth actually went.
    var jointDepth: [String: Double]
}

func segment(_ frames: [BodyFrame], _ a: String, _ b: String) -> [Double] {
    frames.compactMap { (f: BodyFrame) -> Double? in
        guard let pa = f.joints3D[a]?.cameraPosition, let pb = f.joints3D[b]?.cameraPosition else { return nil }
        return simd_length(pa - pb)
    }
}

let drawn: [(String, String, String)] = [
    ("upperArmRight", Body2DPoint.rightShoulder, Body2DPoint.rightElbow),
    ("forearmRight", Body2DPoint.rightElbow, Body2DPoint.rightWrist),
    ("upperArmLeft", Body2DPoint.leftShoulder, Body2DPoint.leftElbow),
    ("forearmLeft", Body2DPoint.leftElbow, Body2DPoint.leftWrist),
    ("thighRight", Body2DPoint.rightHip, Body2DPoint.rightKnee),
    ("shinRight", Body2DPoint.rightKnee, Body2DPoint.rightAnkle),
    ("trunkRight", Body2DPoint.rightShoulder, Body2DPoint.rightHip),
    ("biacromial", Body2DPoint.leftShoulder, Body2DPoint.rightShoulder),
]

var rows: [Row] = []
for f in files {
    guard let data = try? Data(contentsOf: f), let shot = try? BodyShot.decode(data) else {
        print("\(f.lastPathComponent): not a BodyShot this build can read"); continue
    }
    var frames: [BodyFrame] = []
    for sf in shot.frames {
        var p2: [String: BodyPoint2D] = [:]
        for (name, p) in sf.points2D { p2[name] = BodyPoint2D(name: name, u: p.u, v: p.v, confidence: p.confidence) }
        var j3: [String: BodyJoint3D] = [:]
        for (name, j) in sf.joints3D {
            j3[name] = BodyJoint3D(name: name, position: .zero, cameraPosition: visionCamera(j), confidence: j.confidence)
        }
        frames.append(BodyFrame(frameIndex: sf.frameIndex, fileTime: sf.t_file, realTime: sf.t_real,
                                joints3D: j3, points2D: p2))
    }
    let fmtInfo = shot.source.format
    let timeline = BodyTimeline(frames: frames, timeScale: 1, imageWidth: fmtInfo.w, imageHeight: fmtInfo.h,
                                everyNthFrame: shot.timing.everyNthFrame, decodedFrames: frames.count,
                                analysedFrames: frames.count, wallSeconds: 0, notes: [])
    let hfov = hfovOverride ?? fmtInfo.hfovDegrees
    var o = BodySkeletonOptions(intrinsics: CameraIntrinsics(width: fmtInfo.w, height: fmtInfo.h, horizontalFOVDegrees: hfov))
    if let h = heightOverride ?? shot.skeleton.standingHeight.value, shot.skeleton.scaleProvenance == "statedHeight" || heightOverride != nil {
        o.scale = .statedHeight(metres: h)
    }
    if let w = limbWeight { o.limbBoneWeight = w }
    if let p = limbPrior { o.limbLengthPriorFromStature = p }
    if let w = boneWeight { o.boneWeight = w }
    if let w = smoothWeight { o.smoothnessWeight = w }
    if let s = sweeps { o.sweeps = s }
    if let t = transversePrior { o.transverseBreadthFromHeight = t }
    if let t = torsoBreadth { o.torsoBreadthWhenUnobservable = t }
    if let w = visionPrior { o.visionDepthPriorWeight = w }
    if let d = depthSmooth { o.depthSmoothnessScale = d }
    if let n = floorFrames { o.projectionFloorMedianFrames = n }
    let t0 = DispatchTime.now().uptimeNanoseconds
    let r = BodySkeletonFit.fit(timeline: timeline, options: o)
    let fitElapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    fitSeconds.append((f.deletingPathExtension().lastPathComponent, fitElapsed, frames.count))
    if profile { print(String(format: "profile %@: fit %.3f s over %d frames (%.2f ms/frame)", f.deletingPathExtension().lastPathComponent, fitElapsed, frames.count, 1000 * fitElapsed / Double(max(1, frames.count)))) }

    var bones: [String: Double] = [:]
    for b in r.bones { bones[b.name] = b.metres }
    var per: [String: (lo: Double, hi: Double, sd: Double)] = [:]
    for (name, a, b) in drawn {
        let ls = segment(r.timeline.frames, a, b)
        let m = Stats.median(ls)
        guard ls.count > 2, m > 1e-9 else { continue }
        per[name] = (ls.min()! / m, ls.max()! / m, Stats.sd(ls) / m)
    }
    // Jitter: |Δ| of an interior angle between consecutive fitted frames, and how far the mid-hip
    // moves between frames (the fit's own steadiness gate from iteration 2).
    func jitter(_ a: String, _ v: String, _ b: String) -> Double {
        var deltas: [Double] = []
        var previous: Double? = nil
        for fr in r.timeline.frames {
            guard let pa = fr.joints3D[a]?.cameraPosition, let pv = fr.joints3D[v]?.cameraPosition,
                  let pb = fr.joints3D[b]?.cameraPosition, let theta = BodyAngles.angle(pa, pv, pb) else { continue }
            if let p = previous { deltas.append(abs(Angle.degrees(theta - p))) }
            previous = theta
        }
        return deltas.isEmpty ? .nan : Stats.median(deltas)
    }
    var hipSteps: [Double] = []
    var lastHip: SIMD3<Double>? = nil
    for fr in r.timeline.frames {
        guard let l = fr.joints3D[Body2DPoint.leftHip]?.cameraPosition,
              let rr = fr.joints3D[Body2DPoint.rightHip]?.cameraPosition else { continue }
        let mid = (l + rr) / 2
        if let p = lastHip { hipSteps.append(simd_length(mid - p)) }
        lastHip = mid
    }
    // The shooter's stature in whatever unit the fit worked in: the stated height when there is
    // one, else the fitted skeleton's own 90th-percentile ankle-to-nose span ÷ 0.891 — the same
    // convention the fit and the export use, so a ratio means the same thing in both.
    var spans: [Double] = []
    for fr in r.timeline.frames {
        guard let head = fr.joints3D[Body3DJoint.centerHead]?.cameraPosition
                ?? fr.joints3D[Body2DPoint.nose]?.cameraPosition else { continue }
        let ankles = [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle].compactMap { fr.joints3D[$0]?.cameraPosition }
        guard !ankles.isEmpty else { continue }
        spans.append(ankles.map { simd_length($0 - head) }.max() ?? 0)
    }
    spans.sort()
    let span90 = spans.isEmpty ? 0 : spans[min(spans.count - 1, Int((0.9 * Double(spans.count - 1)).rounded()))]
    let stature = r.standingHeightMetres.value ?? (span90 > 0 ? span90 / 0.891 : 1)
    // ---- flatness (1.1) --------------------------------------------------------------------
    let shootSide = shot.shootingSide ?? "right"
    let releaseT = shot.timing.releaseRealTime
    let startT = shot.timing.set.value ?? shot.timing.dip.value ?? (releaseT - 0.60)
    let win = r.timeline.frames.filter { $0.realTime >= min(startT, releaseT - 0.05) && $0.realTime <= releaseT }
    func axisRange(_ fs: [BodyFrame], _ j: String, _ axis: Int) -> Double {
        let v = fs.compactMap { (fr: BodyFrame) -> Double? in fr.joints3D[j]?.cameraPosition[axis] }
        guard v.count >= 3, let lo = v.min(), let hi = v.max() else { return .nan }
        return (hi - lo) / stature
    }
    func imageRange(_ fs: [BodyFrame], _ j: String) -> Double {
        let v = fs.compactMap { (fr: BodyFrame) -> SIMD2<Double>? in
            fr.joints3D[j].map { SIMD2($0.cameraPosition.x, $0.cameraPosition.y) } }
        guard v.count >= 3 else { return .nan }
        var best = 0.0
        for a in v { for b in v { best = max(best, simd_length(a - b)) } }
        return best / stature
    }
    func depthSep(_ a: String, _ b: String) -> Double {
        let d = r.timeline.frames.compactMap { (fr: BodyFrame) -> Double? in
            guard let pa = fr.joints3D[a]?.cameraPosition, let pb = fr.joints3D[b]?.cameraPosition else { return nil }
            return abs(pa.z - pb.z) }
        return d.isEmpty ? .nan : Stats.median(d) / stature
    }
    var extents: [Double] = []
    for fr in r.timeline.frames {
        let zs = BodySkeletonFit.joints.compactMap { (n: String) -> Double? in
            fr.joints3D[n == Body2DPoint.nose ? Body3DJoint.centerHead
                         : n == Body2DPoint.neck ? Body3DJoint.centerShoulder : n]?.cameraPosition.z }
        guard zs.count >= 8, let lo = zs.min(), let hi = zs.max() else { continue }
        extents.append((hi - lo) / stature)
    }
    func angleRange(_ a: String, _ v: String, _ b: String, _ fs: [BodyFrame]) -> Double {
        let xs = fs.compactMap { (fr: BodyFrame) -> Double? in
            guard let pa = fr.joints3D[a]?.cameraPosition, let pv = fr.joints3D[v]?.cameraPosition,
                  let pb = fr.joints3D[b]?.cameraPosition else { return nil }
            return BodyAngles.angle(pa, pv, pb).map { Angle.degrees($0) } }
        guard xs.count >= 3, let lo = xs.min(), let hi = xs.max() else { return .nan }
        return hi - lo
    }
    let flat = Flatness(
        elbowDepth: axisRange(win, shootSide + "Elbow", 2), elbowImage: imageRange(win, shootSide + "Elbow"),
        wristDepth: axisRange(win, shootSide + "Wrist", 2), wristImage: imageRange(win, shootSide + "Wrist"),
        kneeDepth: axisRange(win, shootSide + "Knee", 2), kneeImage: imageRange(win, shootSide + "Knee"),
        bodyDepthExtent: extents.isEmpty ? .nan : Stats.median(extents),
        shoulderDepthSep: depthSep(Body2DPoint.leftShoulder, Body2DPoint.rightShoulder),
        hipDepthSep: depthSep(Body2DPoint.leftHip, Body2DPoint.rightHip),
        ankleDepthSep: depthSep(Body2DPoint.leftAnkle, Body2DPoint.rightAnkle),
        kneeFlexionRange: angleRange(shootSide + "Hip", shootSide + "Knee", shootSide + "Ankle", r.timeline.frames),
        elbowAngleRange: angleRange(shootSide + "Shoulder", shootSide + "Elbow", shootSide + "Wrist", win),
        worstBoneSD: per.values.map(\.sd).max() ?? .nan,
        elbowAngleRange2D: {
            let xs = win.compactMap { (fr: BodyFrame) -> Double? in
                guard let a = fr.points2D[shootSide + "Shoulder"], a.confidence >= 0.3,
                      let v = fr.points2D[shootSide + "Elbow"], v.confidence >= 0.3,
                      let b = fr.points2D[shootSide + "Wrist"], b.confidence >= 0.3 else { return nil }
                return BodyAngles.imageAngle(a.uv, v.uv, b.uv).map { Angle.degrees($0) } }
            guard xs.count >= 3, let lo = xs.min(), let hi = xs.max() else { return .nan }
            return hi - lo
        }(),
        jointDepth: {
            var out: [String: [Double]] = [:]
            for fr in r.timeline.frames {
                guard let lh = fr.joints3D[Body2DPoint.leftHip]?.cameraPosition,
                      let rh = fr.joints3D[Body2DPoint.rightHip]?.cameraPosition else { continue }
                let z0 = (lh.z + rh.z) / 2
                for n in BodySkeletonFit.joints {
                    let key = n == Body2DPoint.nose ? Body3DJoint.centerHead
                            : n == Body2DPoint.neck ? Body3DJoint.centerShoulder : n
                    guard let p = fr.joints3D[key]?.cameraPosition else { continue }
                    out[n, default: []].append(abs(p.z - z0) / stature)
                }
            }
            return out.mapValues { Stats.median($0) }
        }())

    rows.append(Row(file: f.deletingPathExtension().lastPathComponent,
                    rms: r.reprojectionRMSPixels.value ?? .nan, bones: bones, perFrame: per,
                    stature: stature,
                    elbowJitterDegrees: jitter(Body2DPoint.rightShoulder, Body2DPoint.rightElbow, Body2DPoint.rightWrist),
                    kneeJitterDegrees: jitter(Body2DPoint.rightHip, Body2DPoint.rightKnee, Body2DPoint.rightAnkle),
                    hipStep: hipSteps.isEmpty ? .nan : Stats.median(hipSteps) / stature,
                    depthSigma: r.depthSigmaMetres.value ?? .nan,
                    unit: r.scaleIsMeasured ? "metres" : "unit height",
                    flat: flat))
    // ---- re-written BodyShot (1.1) ------------------------------------------------------------
    // The same file back, with `fitted3D` and the bone table replaced by this run's fit and nothing
    // else touched, so a viewer can be pointed at the before and the after of one shot. The body
    // frame is rebuilt exactly as `BodyShotExport` builds it (schema §4): origin the mid-hip at the
    // set point, z up, x toward the rim — whose sign is read back off the file's own conventions
    // rather than guessed, so the two renders are in the same frame.
    if let writeShotDir {
        let rimRight = !(shot.conventions["body"]?.contains("rim left") ?? false)
        // `stature` above is already the file's own convention: the stated height when there is
        // one, else the fitted 90th-percentile ankle-to-nose span ÷ 0.891.
        let divisor: Double = r.scaleIsMeasured ? 1 : stature
        let up = SIMD3<Double>(0, 1, 0)
        let xAxis = SIMD3<Double>(rimRight ? 1 : -1, 0, 0)
        let yAxis = simd_cross(up, xAxis)
        let originTime = shot.timing.set.value ?? r.timeline.frames.first?.realTime ?? shot.timing.releaseRealTime
        let originFrame = r.timeline.frames.min { abs($0.realTime - originTime) < abs($1.realTime - originTime) }
        let origin: SIMD3<Double>? = originFrame.flatMap { fr in
            guard let l = fr.joints3D[Body2DPoint.leftHip]?.cameraPosition,
                  let rr = fr.joints3D[Body2DPoint.rightHip]?.cameraPosition else { return nil }
            return (l + rr) / 2
        }
        if let origin, divisor > 1e-9 {
            func toBody(_ p: SIMD3<Double>) -> BodyShotFitted3D {
                let d = (p - origin) / divisor
                func rr(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }
                return BodyShotFitted3D(x: rr(simd_dot(d, xAxis)), y: rr(simd_dot(d, yAxis)), z: rr(simd_dot(d, up)))
            }
            var out = shot
            let byIndex = Dictionary(r.timeline.frames.map { ($0.frameIndex, $0) }, uniquingKeysWith: { a, _ in a })
            for i in out.frames.indices {
                guard let fitted = byIndex[out.frames[i].frameIndex] else { out.frames[i].fitted3D = [:]; continue }
                var f3: [String: BodyShotFitted3D] = [:]
                for (name, j) in fitted.joints3D { f3[name] = toBody(j.cameraPosition) }
                out.frames[i].fitted3D = f3
            }
            for b in r.bones {
                guard var existing = out.skeleton.boneLengths[b.name] else { continue }
                existing.length = ((b.metres / (r.scaleIsMeasured ? 1 : divisor)) * 10000).rounded() / 10000
                existing.mad = ((b.madMetres / (r.scaleIsMeasured ? 1 : divisor)) * 10000).rounded() / 10000
                existing.prior = r.priorBones.contains(b.name)
                existing.source = b.source
                out.skeleton.boneLengths[b.name] = existing
            }
            out.notes.append("fitted3D and the bone table in this copy were re-computed by BodyRefit (3-D model 1.1); every other field is the original file's")
            let dir = URL(fileURLWithPath: writeShotDir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let d = try? out.encoded() { try? d.write(to: dir.appendingPathComponent(f.lastPathComponent)) }
        } else {
            print("\(f.lastPathComponent): cannot rewrite — no mid-hip at the set point")
        }
    }

    if let outDir {
        // Fitted positions per frame, for the plots. Body-frame conversion is the viewer's job; this
        // writes the fit's own camera metres plus the phase clock, which is all a picture needs.
        var out: [[String: Any]] = []
        for fr in r.timeline.frames {
            var d: [String: Any] = ["t": fr.realTime - shot.timing.releaseRealTime]
            var js: [String: [Double]] = [:]
            for name in BodySkeletonFit.joints {
                if let p = fr.joints3D[name]?.cameraPosition { js[name] = [p.x, p.y, p.z] }
            }
            d["j"] = js
            out.append(d)
        }
        let payload: [String: Any] = ["file": f.lastPathComponent, "stature": stature,
                                      "rms": rows.last!.rms, "frames": out,
                                      "bones": bones]
        let dir = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: payload) {
            try? d.write(to: dir.appendingPathComponent(f.lastPathComponent))
        }
    }
    if !quiet {
        let ua = per["upperArmRight"], fa = per["forearmRight"]
        print("\(f.deletingPathExtension().lastPathComponent): rms \(fmt(rows.last!.rms, 2)) px, upperArm \(fmt((bones["upperArmRight"] ?? .nan) / stature)) H [\(fmt(ua?.lo ?? .nan, 2))–\(fmt(ua?.hi ?? .nan, 2))], forearm \(fmt((bones["forearmRight"] ?? .nan) / stature)) H [\(fmt(fa?.lo ?? .nan, 2))–\(fmt(fa?.hi ?? .nan, 2))]")
    }
}

// ---- the table -------------------------------------------------------------------------------
func med(_ xs: [Double]) -> Double { let v = xs.filter(\.isFinite); return v.isEmpty ? .nan : Stats.median(v) }
let good = rows.filter { $0.rms.isFinite && $0.rms < 10 }
print("\n\(good.count) shot(s) (\(rows.count - good.count) refused: reprojection over 10 px)")
print(String(format: "%-14@ %9@ %9@ %9@ %9@ %9@", "segment" as NSString, "len/H" as NSString,
             "Winter" as NSString, "min/med" as NSString, "max/med" as NSString, "sd %" as NSString))
let winter: [String: Double] = ["upperArmRight": 0.186, "forearmRight": 0.146, "upperArmLeft": 0.186,
                                "forearmLeft": 0.146, "thighRight": 0.245, "shinRight": 0.246,
                                "trunkRight": 0.288, "biacromial": 0.259]
for (name, _, _) in drawn {
    let l = med(good.map { ($0.bones[name] ?? .nan) / $0.stature })
    let lo = med(good.compactMap { $0.perFrame[name]?.lo })
    let hi = med(good.compactMap { $0.perFrame[name]?.hi })
    let sd = med(good.compactMap { $0.perFrame[name]?.sd })
    print(String(format: "%-14@ %9@ %9@ %9@ %9@ %8@%%", name as NSString, fmt(l, 4) as NSString,
                 fmt(winter[name] ?? .nan, 3) as NSString, fmt(lo, 3) as NSString, fmt(hi, 3) as NSString, fmt(100 * sd, 1) as NSString))
}
if profile || !fitSeconds.isEmpty {
    let ts = fitSeconds.map(\.1)
    let total = ts.reduce(0, +)
    print(String(format: "fit wall time: %d shot(s), total %.2f s, mean %.3f s/shot, median %.3f s, worst %.3f s (%@)",
                 ts.count, total, total / Double(max(1, ts.count)), med(ts), ts.max() ?? .nan,
                 fitSeconds.max(by: { $0.1 < $1.1 })?.0 ?? "-"))
}
print("reprojection RMS px: median \(fmt(med(good.map(\.rms)), 2)), worst \(fmt(good.map(\.rms).max() ?? .nan, 2))")
print("shooting-elbow jitter °/frame: median \(fmt(med(good.map(\.elbowJitterDegrees)), 2)), knee \(fmt(med(good.map(\.kneeJitterDegrees)), 2))")
print("mid-hip step (stature units/frame): median \(fmt(med(good.map(\.hipStep)), 4)); depth 1σ \(fmt(med(good.map(\.depthSigma)), 4))")

// ---- flatness (1.1) ---------------------------------------------------------------------------
func p95(_ xs: [Double]) -> Double { let v = xs.filter(\.isFinite).sorted(); return v.isEmpty ? .nan : v[min(v.count - 1, Int((0.95 * Double(v.count - 1)).rounded()))] }
print("\nflatness, \(good.count) shot(s), stature units unless stated (median over shots)")
func flatRow(_ name: String, _ get: (Flatness) -> Double, _ expect: String) {
    print(String(format: "%-26@ %8@   %@", name as NSString, fmt(med(good.map { get($0.flat) }), 4) as NSString, expect as NSString))
}
flatRow("shooting elbow, depth range", { $0.elbowDepth }, "set\u{2192}release")
flatRow("shooting elbow, image range", { $0.elbowImage }, "the sagittal travel a side view sees")
flatRow("shooting wrist, depth range", { $0.wristDepth }, "")
flatRow("shooting wrist, image range", { $0.wristImage }, "")
flatRow("shooting knee, depth range", { $0.kneeDepth }, "")
flatRow("shooting knee, image range", { $0.kneeImage }, "")
flatRow("body depth extent", { $0.bodyDepthExtent }, "a standing adult is \u{2248} 0.15\u{2013}0.25 H thick front-to-back plus stance")
flatRow("shoulder L\u{2013}R depth sep", { $0.shoulderDepthSep }, "0.245 H if the shot is exactly side-on")
flatRow("hip L\u{2013}R depth sep", { $0.hipDepthSep }, "0.191 H if exactly side-on")
flatRow("ankle L\u{2013}R depth sep", { $0.ankleDepthSep }, "stance width, \u{2248} 0.10\u{2013}0.20 H")
flatRow("knee flexion range (deg)", { $0.kneeFlexionRange }, "a shot dips 30\u{2013}70 deg")
flatRow("shooting elbow range (deg)", { $0.elbowAngleRange }, "set\u{2192}release opens 60\u{2013}110 deg")
flatRow("worst bone SD (fraction)", { $0.worstBoneSD }, "bone constancy; 0.005 = 0.5 %")
print(String(format: "depth/image ratio, elbow: median %@  (a side view should still show the body's thickness)",
             fmt(med(good.map { $0.flat.elbowImage > 0 ? $0.flat.elbowDepth / $0.flat.elbowImage : .nan }), 3) as NSString))
print(String(format: "shots whose body depth extent is under 0.10 H (cardboard): %d of %d", good.filter { $0.flat.bodyDepthExtent < 0.10 }.count, good.count))
print(String(format: "bone SD 95th pct over shots: %@", fmt(100 * p95(good.map { $0.flat.worstBoneSD }), 2) as NSString) + " %")
print(String(format: "shooting-elbow angle range: 3-D %@ deg against the image's %@ deg over the same window",
             fmt(med(good.map { $0.flat.elbowAngleRange }), 1) as NSString,
             fmt(med(good.map { $0.flat.elbowAngleRange2D }), 1) as NSString))
print("median |joint depth - mid-hip depth| (stature units):")
for n in BodySkeletonFit.joints {
    let v = med(good.compactMap { $0.flat.jointDepth[n] })
    if v.isFinite { print(String(format: "  %-16@ %@", n as NSString, fmt(v, 4) as NSString)) }
}
