// FormEval — how well does the 3-D form track the real movement?
//
//   swift run -c release FormEval <dir-or-file.json> [options]
//
// Over a directory of exported `BodyShot` files it re-runs the skeleton fit and reports four kinds of
// evidence, none of which needs a mocap lab: reprojection (driven and **held-out**), bone-length
// constancy and left–right symmetry, phase-instant coverage, and the repeatability of the form
// measures. It prints a table, writes a JSON report, and states pass/fail against the gates. It never
// hides a failure and it never invents a number: anything it cannot compute prints its reason.
//
// Options:
//   --json <path>            write the machine-readable report
//   --markdown <path>        write the same tables as markdown
//   --labels <dir>           score the fit against hand labels in <dir> (see docs)
//   --held-out <list|all|none>   joints to re-fit without, comma-separated (default: all 14)
//   --no-retest              skip the even/odd refits (halves the run time, loses section 6)
//   --no-dedupe              count every file, including repeat exports of one session
//   --limit N                stop after N shots
//   --max-rms P              refuse a shot whose fit reprojects worse than P px RMS (default: keep all)
//   --confidence C           2-D confidence gate (default 0.3, the fit's own)
//   --hfov D / --height M    override the export's framing / the shooter's stature
//   --bone-sd-gate P         default 3.0 %      --asymmetry-gate P   default 4.0 %
//   --bootstrap N            ICC bootstrap resamples (default 2000, 0 = no interval)
//   --quiet                  only the gate lines
import Foundation
import ShotGeometry
import FormEvalKit

let argv = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: "--" + name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
func has(_ name: String) -> Bool { argv.contains("--" + name) }

guard let path = argv.first, !path.hasPrefix("--") else {
    print("""
    usage: FormEval <dir-or-file.json> [--json out.json] [--markdown out.md] [--labels <dir>]
                    [--held-out all|none|<joint,joint>] [--no-retest] [--no-dedupe] [--limit N]
                    [--confidence 0.3] [--hfov D] [--height M] [--max-rms P]
                    [--bone-sd-gate 3] [--asymmetry-gate 4]
                    [--bootstrap 2000] [--quiet]
    """)
    exit(2)
}

var options = FormEvalOptions()
if let c = flag("confidence").flatMap(Double.init) { options.minimumConfidence2D = c }
if let d = flag("hfov").flatMap(Double.init) { options.hfovOverride = d }
if let m = flag("height").flatMap(Double.init) { options.heightOverride = m }
if let p = flag("bone-sd-gate").flatMap(Double.init) { options.boneSDGatePercent = p }
if let p = flag("asymmetry-gate").flatMap(Double.init) { options.asymmetryGatePercent = p }
if let n = flag("bootstrap").flatMap(Int.init) { options.bootstrapSamples = n }
if has("no-retest") { options.runRetest = false }
if has("no-dedupe") { options.dedupe = false }
switch flag("held-out") {
case .some("all"), .none: options.heldOutJoints = BodySkeletonFit.joints
case .some("none"): options.heldOutJoints = []
case .some(let list): options.heldOutJoints = list.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
}
let limit = flag("limit").flatMap(Int.init)
let maxRMS = flag("max-rms").flatMap(Double.init)
let quiet = has("quiet")

let files = BodyShotLoading.files(at: path)
guard !files.isEmpty else { print("no .json under \(path)"); exit(2) }

var evaluations: [ShotEval] = []
var seen: Set<String> = []
var duplicates = 0
var unreadable: [String] = []
var refused: [String] = []
let started = Date()

for f in files {
    if let limit, evaluations.count >= limit { break }
    guard let data = try? Data(contentsOf: f), let shot = try? BodyShot.decode(data) else {
        unreadable.append(f.lastPathComponent); continue
    }
    let session = f.deletingLastPathComponent().lastPathComponent
    let id = f.deletingPathExtension().lastPathComponent
    if options.dedupe {
        let d = FormEvaluator.digest(shot)
        if seen.contains(d) { duplicates += 1; continue }
        seen.insert(d)
    }
    guard let e = FormEvaluator.evaluate(shot: shot, id: id, session: session, path: f.path, options: options) else {
        unreadable.append("\(session)/\(id) (fewer than four analysed frames)"); continue
    }
    if let maxRMS, let rms = e.fitReprojectionRMS, rms > maxRMS {
        refused.append(String(format: "%@/%@ (%.1f px RMS > %.1f)", session, id, rms, maxRMS))
        continue
    }
    evaluations.append(e)
    if !quiet {
        FileHandle.standardError.write("  \(session)/\(id): \(e.frameCount) frames, RMS \(FormEvalReporting.fmt(e.fitReprojectionRMS)) px\n".data(using: .utf8)!)
    }
}

guard !evaluations.isEmpty else { print("no shot could be evaluated"); exit(1) }

// --- labels -----------------------------------------------------------------------------------
var labelReport: LabelReport? = nil
if let dir = flag("labels") {
    let (entries, loadNotes) = LabelScoring.load(directory: dir)
    if entries.isEmpty {
        print("labels: no readable sheet under \(dir)")
    } else {
        var cache: [String: BodyShot] = [:]
        var r = LabelScoring.score(entries: entries, directory: dir, options: options) { p in
            if let c = cache[p] { return c }
            let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : URL(fileURLWithPath: dir).appendingPathComponent(p)
            guard let d = try? Data(contentsOf: url), let s = try? BodyShot.decode(d) else { return nil }
            cache[p] = s
            return s
        }
        r.notes.append(contentsOf: loadNotes)
        labelReport = r
    }
}

var notes: [String] = []
if !unreadable.isEmpty { notes.append("not read: " + unreadable.joined(separator: ", ")) }
if !refused.isEmpty { notes.append("refused by --max-rms: " + refused.joined(separator: ", ")) }
notes.append(String(format: "%d fit(s) in %.1f s of wall time", evaluations.count * (1 + options.heldOutJoints.count + (options.runRetest ? 2 : 0)), Date().timeIntervalSince(started)))

let report = FormEvalReporting.build(evaluations: evaluations, options: options, root: path,
                                     filesRead: files.count, duplicatesDropped: duplicates,
                                     labels: labelReport, notes: notes)
let md = FormEvalReporting.markdown(report)
if !quiet { print(md) }

if let out = flag("markdown") {
    try? md.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
    print("wrote \(out)")
}
if let out = flag("json") {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(report) {
        try? d.write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    }
}

for g in report.gates { print("\(g.passes ? "PASS" : "FAIL") — \(g.name): worst \(FormEvalReporting.fmt(g.worstValue)) % (\(g.worstSubject ?? "—"))") }
exit(report.gates.allSatisfy(\.passes) ? 0 : 1)
