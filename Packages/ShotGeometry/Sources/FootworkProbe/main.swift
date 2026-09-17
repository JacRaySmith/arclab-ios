// FootworkProbe — run `FootworkMetrics` over exported `BodyShot` files and print the distributions.
//
// A separate target from `BodyRefit` on purpose: the two sweep different things and are edited by
// different hands. The loader is BodyRefit's, copied rather than shared, because BodyRefit's is
// changing under Track A.
//
//   swift run -c release FootworkProbe <dir-or-file> [--drill NAME] [--per-shot] [--json OUT.json]
//
// Drill names: stationaryCatch (default), catchAndShoot, pullUpStrongSide, pullUpWeakSide, stepBack.
import Foundation
import simd
import ShotGeometry

func fmt(_ x: Double?, _ d: Int = 3) -> String {
    guard let x, x.isFinite else { return "   nil" }
    return String(format: "%\(d + 4).\(d)f", x)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first, !path.hasPrefix("--") else {
    print("usage: FootworkProbe <dir-or-file.json> [--drill NAME] [--per-shot] [--json OUT.json]")
    exit(2)
}
args.removeFirst()
let argv = args
func flag(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: "--" + name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
let drill = FootworkDrill(rawValue: flag("drill") ?? "stationaryCatch") ?? .stationaryCatch
let perShot = argv.contains("--per-shot")
let jsonOut = flag("json")

// Every .json under the path, one level of sub-directories included (the phone writes one folder
// per session).
func jsonFiles(_ url: URL) -> [URL] {
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    guard isDir.boolValue else { return url.pathExtension == "json" ? [url] : [] }
    let kids = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    var out: [URL] = []
    for k in kids {
        var kid: ObjCBool = false
        FileManager.default.fileExists(atPath: k.path, isDirectory: &kid)
        if kid.boolValue { out += jsonFiles(k) } else if k.pathExtension == "json" { out.append(k) }
    }
    return out.sorted { $0.path < $1.path }
}
let files = jsonFiles(URL(fileURLWithPath: path))
guard !files.isEmpty else { print("no .json under \(path)"); exit(2) }

/// The export's camera frame (x right, y down, z forward) back into Vision's own.
func visionCamera(_ j: BodyShotJoint3D) -> SIMD3<Double> { SIMD3(j.x, -j.y, -j.z) }

/// The export's body frame has x along the camera's horizontal *toward the rim's image column*. The
/// column itself is not written, but the sign is recoverable: regress the fitted x against the image
/// u over every joint on every frame. Positive slope → the rim is camera-right.
func rimBearingSign(_ shot: BodyShot) -> Double? {
    var sxy = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, n = 0.0
    for f in shot.frames {
        for (name, fit) in f.fitted3D {
            guard let p = f.points2D[name] else { continue }
            sxy += p.u * fit.x; sx += p.u; sy += fit.x; sxx += p.u * p.u; n += 1
        }
    }
    guard n > 20 else { return nil }
    let denom = n * sxx - sx * sx
    guard abs(denom) > 1e-9 else { return nil }
    let slope = (n * sxy - sx * sy) / denom
    guard abs(slope) > 1e-9 else { return nil }
    return slope > 0 ? 1 : -1
}

struct Row {
    var file: String
    var pattern: String
    var contactsLeft: Int
    var contactsRight: Int
    var refusedFeet: [String]
    var steps: Double?
    var gather: Double?
    var liftToRelease: Double?
    var separation: Double?
    var width: Double?
    var stagger: Double?
    var driftImage: Double?
    var driftLateral: Double?
    var driftTowardRim: Double?
    var rise: Double?
    var forward: Double?
    var frontal: Double?
    var azimuthDegrees: Double?
    var faults: [String]
    var unmeasured: Int
    var findings: Int
}

var rows: [Row] = []
var reasonCounts: [String: Int] = [:]
var sessions: [String: Int] = [:]

for f in files {
    guard let data = try? Data(contentsOf: f), let shot = try? BodyShot.decode(data) else {
        print("\(f.lastPathComponent): not a BodyShot this build can read"); continue
    }
    let session = f.deletingLastPathComponent().lastPathComponent
    sessions[session, default: 0] += 1

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
    let info = shot.source.format
    let timeline = BodyTimeline(frames: frames, timeScale: 1, imageWidth: info.w, imageHeight: info.h,
                                everyNthFrame: shot.timing.everyNthFrame, decodedFrames: frames.count,
                                analysedFrames: frames.count, wallSeconds: 0, notes: [])
    var o = FootworkOptions(shootingSide: shot.shootingSide,
                            standingHeightMetres: shot.skeleton.standingHeight.value,
                            heightIsMeasured: false)
    o.rimBearingSign = rimBearingSign(shot)

    let m = FootworkMetrics.compute(timeline: timeline,
                                    releaseRealTime: shot.timing.releaseRealTime,
                                    setRealTime: shot.timing.set.value,
                                    options: o)
    let e = FootworkEvaluation.evaluate(m, drill: drill)

    for w in m.warnings {
        let key = w.contains("ankles sit") ? "ankles too close to their own noise to trust the stagger"
                : w.contains("mid-hip jumps") ? "mid-hip jumped: drift refused"
                : w.contains("hip line's image span swings") ? "hip line unstable: view refused"
                : String(w.prefix(60))
        reasonCounts["WARNING: \(key)", default: 0] += 1
    }
    for (foot, why) in m.contactsUnavailable { reasonCounts["contacts/\(foot): \(why.prefix(70))", default: 0] += 1 }
    for key in ["stanceWidth", "stanceStagger", "hipDriftLateral", "hipDriftTowardRim", "jumpForwardTravel"] {
        let v: FootworkValue
        switch key {
        case "stanceWidth": v = m.stanceWidth
        case "stanceStagger": v = m.stanceStagger
        case "hipDriftLateral": v = m.hipDriftLateral
        case "hipDriftTowardRim": v = m.hipDriftTowardRim
        default: v = m.jumpForwardTravel
        }
        if let why = v.unavailableReason { reasonCounts["\(key): \(why.prefix(70))", default: 0] += 1 }
    }

    rows.append(Row(file: "\(session.prefix(4))/\(f.deletingPathExtension().lastPathComponent)",
                    pattern: m.pattern.rawValue,
                    contactsLeft: m.contacts.filter { $0.foot == .left }.count,
                    contactsRight: m.contacts.filter { $0.foot == .right }.count,
                    refusedFeet: m.contactsUnavailable.keys.sorted(),
                    steps: m.stepCount.value, gather: m.gatherSeconds.value,
                    liftToRelease: m.liftToReleaseSeconds.value,
                    separation: m.ankleSeparationImage.value, width: m.stanceWidth.value,
                    stagger: m.stanceStagger.value, driftImage: m.hipDriftImage.value,
                    driftLateral: m.hipDriftLateral.value, driftTowardRim: m.hipDriftTowardRim.value,
                    rise: m.jumpRise.value, forward: m.jumpForwardTravel.value,
                    frontal: m.viewFrontalProjection.value,
                    azimuthDegrees: m.viewAzimuth.value.map { $0 * 180 / .pi },
                    faults: e.faults.map(\.id), unmeasured: e.unmeasured.count, findings: e.findings.count))

    if perShot {
        print(String(format: "%-14@ %-11@ L%d R%d steps%@ gather%@ lift→rel%@ sep%@ driftImg%@ rise%@ |cosθ|%@ θ%@°",
                     rows.last!.file as NSString, m.pattern.rawValue as NSString,
                     rows.last!.contactsLeft, rows.last!.contactsRight,
                     fmt(m.stepCount.value, 0), fmt(m.gatherSeconds.value), fmt(m.liftToReleaseSeconds.value),
                     fmt(m.ankleSeparationImage.value), fmt(m.hipDriftImage.value), fmt(m.jumpRise.value),
                     fmt(m.viewFrontalProjection.value, 2), fmt(rows.last!.azimuthDegrees, 1)))
    }
}

// ---- distributions -------------------------------------------------------------------------------
func stats(_ xs: [Double]) -> String {
    guard !xs.isEmpty else { return "n=0" }
    let s = xs.sorted()
    func q(_ p: Double) -> Double { s[max(0, min(s.count - 1, Int((Double(s.count - 1) * p).rounded())))] }
    let mean = s.reduce(0, +) / Double(s.count)
    let sd = s.count > 1 ? (s.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(s.count - 1)).squareRoot() : 0
    return String(format: "n=%3d  min %.3f  p25 %.3f  med %.3f  p75 %.3f  max %.3f  mean %.3f  sd %.3f",
                  s.count, s.first!, q(0.25), q(0.5), q(0.75), s.last!, mean, sd)
}
let snapshot = rows
let column: (String, (Row) -> Double?) -> Void = { name, f in
    print(String(format: "  %-22@ %@", name as NSString, stats(snapshot.compactMap(f))))
}

print("\n================ FootworkProbe — \(rows.count) shots, drill = \(drill.rawValue) ================")
print("sessions: " + sessions.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8))…=\($0.value)" }.joined(separator: "  "))

var patterns: [String: Int] = [:]
for r in rows { patterns[r.pattern, default: 0] += 1 }
print("\npattern:  " + patterns.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
let refused = rows.filter { !$0.refusedFeet.isEmpty }.count
print("feet whose contacts were refused on at least one side: \(refused)/\(rows.count)")
let bothFeetContacts = rows.filter { $0.contactsLeft > 0 && $0.contactsRight > 0 }.count
print("shots with a contact interval on BOTH feet: \(bothFeetContacts)/\(rows.count)")
print("contacts per shot, left:  " + stats(rows.map { Double($0.contactsLeft) }))
print("contacts per shot, right: " + stats(rows.map { Double($0.contactsRight) }))

print("\ndistributions (lengths in stature units = the ankle-to-nose image span):")
column("steps before lift", { $0.steps })
column("gather s", { $0.gather })
column("lift→release s", { $0.liftToRelease })
column("ankle sep (image)", { $0.separation })
column("stance width", { $0.width })
column("stance stagger", { $0.stagger })
column("hip drift (image)", { $0.driftImage })
column("hip drift lateral", { $0.driftLateral })
column("hip drift → rim", { $0.driftTowardRim })
column("jump rise", { $0.rise })
column("jump forward travel", { $0.forward })
column("|cos θ| (frontality)", { $0.frontal })
column("θ degrees", { $0.azimuthDegrees })

print("\nevaluation: \(rows.reduce(0) { $0 + $1.unmeasured }) unmeasured findings out of \(rows.reduce(0) { $0 + $1.findings }) total")
var faultCounts: [String: Int] = [:]
for r in rows { for f in r.faults { faultCounts[f, default: 0] += 1 } }
print("faults: " + (faultCounts.isEmpty ? "none" : faultCounts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")))

print("\nwhy numbers were refused / warned (top reasons, truncated):")
for (why, n) in reasonCounts.sorted(by: { $0.value > $1.value }).prefix(14) {
    print("  \(n)×  \(why)")
}

if let jsonOut {
    var lines: [[String: Double?]] = []
    for r in rows {
        lines.append(["steps": r.steps, "gather": r.gather, "liftToRelease": r.liftToRelease,
                      "separation": r.separation, "driftImage": r.driftImage, "rise": r.rise,
                      "frontal": r.frontal])
    }
    let obj = lines.map { d in d.compactMapValues { $0 } }
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: jsonOut))
        print("\nwrote \(jsonOut)")
    }
}
