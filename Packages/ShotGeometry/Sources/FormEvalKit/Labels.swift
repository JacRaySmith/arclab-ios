// Hand labels: the only ground truth this project can afford.
//
// A label is one human click on one joint in one frame. It is not the truth — it carries the
// labeller's own error, which is why the schema has a `labeller` field and why two label sets of the
// same frames give a **noise floor**: no model should be judged below the distance the human repeats
// to. The harness prints the floor beside the model's error, or says plainly that it does not have one.
import Foundation
import simd
import ShotGeometry

/// The 12 joints the research doc sizes the labelling job around (§5.5): the shooting hand's plate,
/// the arm chain, the leg chain, the foot triangle, and the nose as a head-orientation check.
/// `heel` / `bigToe` / `littleToe` have **no fitted counterpart yet** — that is Track C's job, and
/// these labels are what will score it.
public enum LabelJoints {
    public static func standard(side: String) -> [String] {
        [Body2DPoint.nose,
         side + "Shoulder", side + "Elbow", side + "Wrist",
         side + "IndexMCP", side + "LittleMCP",
         side + "Hip", side + "Knee", side + "Ankle",
         side + "Heel", side + "BigToe", side + "LittleToe"]
    }
    /// Names this build's fit can actually put a point on, so the report can separate "the model was
    /// wrong" from "the model does not have this joint at all".
    public static var fittable: Set<String> {
        Set(BodySkeletonFit.joints.map { $0 } + Body2DPoint.appendages)
    }
}

public struct LabelPoint: Sendable, Codable, Equatable {
    public var u: Double?
    public var v: Double?
    /// The labeller's own call: `true` clicked, `false` "I can see it is hidden", nil "not labelled".
    /// A hidden joint is a datum, not a gap — it is how the coverage claim gets checked.
    public var visible: Bool?
    public init(u: Double? = nil, v: Double? = nil, visible: Bool? = nil) { self.u = u; self.v = v; self.visible = visible }
}

public struct LabelSheetEntry: Sendable, Codable {
    public var schema: String
    public var clip: String?
    /// Presentation time in the clip, seconds — the same clock `BodyShotFrame.t_file` is on.
    public var clipTimeSeconds: Double
    public var frameFile: String?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var shot: String?
    public var phase: String?
    public var labeller: String?
    public var labelledAt: String?
    /// Path to the `BodyShot` export this frame belongs to; without it there is nothing to score.
    public var bodyShot: String?
    public var shootingSide: String?
    /// The labeller's answer to "is this the release frame?" — a human release label, free.
    public var isReleaseFrame: Bool?
    public var points: [String: LabelPoint]
    public var notes: String?
}

public struct LabelJointRow: Sendable, Codable {
    public var joint: String
    public var labelledFrames: Int
    public var scoredFrames: Int
    public var medianPixels: Double?
    public var p90Pixels: Double?
    public var medianShoulderWidths: Double?
    /// Median distance between two labellers' clicks on the same joint and frame: the floor.
    public var labelNoiseMedianPixels: Double?
    public var labelNoisePairs: Int
    public var unavailableReason: String?
}

public struct LabelReport: Sendable, Codable {
    public var directory: String
    public var files: Int
    public var frames: Int
    public var labellers: [String]
    public var doubleLabelledFrames: Int
    public var rows: [LabelJointRow]
    public var notes: [String]
}

public enum LabelScoring {

    public static func load(directory: String) -> (entries: [LabelSheetEntry], notes: [String]) {
        var out: [LabelSheetEntry] = []
        var notes: [String] = []
        let root = URL(fileURLWithPath: directory)
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let dec = JSONDecoder()
        var files: [URL] = []
        while let f = e?.nextObject() as? URL { if f.pathExtension == "json" { files.append(f) } }
        for f in files.sorted(by: { $0.path < $1.path }) {
            guard let d = try? Data(contentsOf: f) else { continue }
            guard let entry = try? dec.decode(LabelSheetEntry.self, from: d) else {
                notes.append("\(f.lastPathComponent): not a label sheet this build can read")
                continue
            }
            out.append(entry)
        }
        return (out, notes)
    }

    /// Score a label set. `resolve` turns the sheet's `bodyShot` path into a loaded shot, so the CLI
    /// can decide where relative paths hang off.
    public static func score(entries: [LabelSheetEntry], directory: String, options o: FormEvalOptions,
                             resolve: (String) -> BodyShot?) -> LabelReport {
        var notes: [String] = []
        let labellers = Array(Set(entries.compactMap { $0.labeller })).sorted()

        // --- the noise floor: two labellers, same clip and time, same joint -----------------------
        var byFrame: [String: [LabelSheetEntry]] = [:]
        for e in entries {
            byFrame["\(e.clip ?? "")@\(Int((e.clipTimeSeconds * 1e5).rounded()))", default: []].append(e)
        }
        var noise: [String: [Double]] = [:]
        var doubleLabelled = 0
        for (_, group) in byFrame where group.count >= 2 {
            doubleLabelled += 1
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    guard group[i].labeller != group[j].labeller else { continue }
                    for (name, a) in group[i].points {
                        guard let au = a.u, let av = a.v, let b = group[j].points[name], let bu = b.u, let bv = b.v else { continue }
                        noise[name, default: []].append(simd_length(SIMD2(au, av) - SIMD2(bu, bv)))
                    }
                }
            }
        }

        // --- the model's error against the labels --------------------------------------------------
        var errPx: [String: [Double]] = [:], errSW: [String: [Double]] = [:]
        var labelled: [String: Int] = [:]
        var scoredFrames = 0
        // Group by BodyShot so each export is fitted once.
        var byShot: [String: [LabelSheetEntry]] = [:]
        for e in entries { byShot[e.bodyShot ?? "", default: []].append(e) }
        for (path, group) in byShot.sorted(by: { $0.key < $1.key }) {
            for e in group { for (n, p) in e.points where p.u != nil && p.v != nil { labelled[n, default: 0] += 1 } }
            guard !path.isEmpty, let shot = resolve(path) else {
                notes.append(path.isEmpty
                    ? "\(group.count) labelled frame(s) carry no `bodyShot` path, so there is nothing to score them against — they still contribute to the label-noise floor"
                    : "\(group.count) labelled frame(s) point at `\(path)`, which this run could not load")
                continue
            }
            let timeline = BodyShotLoading.timeline(shot, hfovOverride: o.hfovOverride)
            let fit = BodySkeletonFit.fit(timeline: timeline,
                                          options: BodyShotLoading.fitOptions(shot, hfovOverride: o.hfovOverride,
                                                                              heightOverride: o.heightOverride))
            let (sw, _) = FormEvaluator.shoulderWidthPixels(frames: timeline.frames, gate: o.minimumConfidence2D)
            let spacing = FormEvaluator.medianFrameSpacing(timeline.frames)
            for e in group {
                guard let f = fit.timeline.frames.min(by: {
                    abs($0.fileTime - e.clipTimeSeconds) < abs($1.fileTime - e.clipTimeSeconds)
                }), abs(f.fileTime - e.clipTimeSeconds) <= 1.5 * spacing else {
                    notes.append(String(format: "no analysed frame within %.0f ms of %.4f s in %@", 1500 * spacing, e.clipTimeSeconds, (path as NSString).lastPathComponent))
                    continue
                }
                scoredFrames += 1
                for (name, p) in e.points {
                    guard let u = p.u, let v = p.v else { continue }
                    guard let j = f.joints3D[FormEvaluator.joint3DKey(name)], let pu = j.imageU, let pv = j.imageV,
                          pu.isFinite, pv.isFinite else { continue }
                    let d = simd_length(SIMD2(pu, pv) - SIMD2(u, v))
                    errPx[name, default: []].append(d)
                    if let sw, sw > 0 { errSW[name, default: []].append(d / sw) }
                }
            }
        }

        var rows: [LabelJointRow] = []
        for name in Set(labelled.keys).union(noise.keys).sorted() {
            let px = errPx[name] ?? []
            let reason: String? = px.isEmpty
                ? (LabelJoints.fittable.contains(name)
                    ? "the fit produced no point for this joint on any labelled frame"
                    : "this build's skeleton has no such joint — the label is here for the detector that will")
                : nil
            rows.append(LabelJointRow(joint: name, labelledFrames: labelled[name] ?? 0, scoredFrames: px.count,
                                      medianPixels: EvalStats.median(px), p90Pixels: EvalStats.percentile(px, 0.9),
                                      medianShoulderWidths: EvalStats.median(errSW[name] ?? []),
                                      labelNoiseMedianPixels: EvalStats.median(noise[name] ?? []),
                                      labelNoisePairs: (noise[name] ?? []).count,
                                      unavailableReason: reason))
        }
        if doubleLabelled == 0 {
            notes.append("no frame was labelled twice, so there is no intra-rater noise floor: every model error below is uncalibrated and must not be called 'good' or 'bad' yet")
        }
        return LabelReport(directory: directory, files: entries.count, frames: scoredFrames,
                           labellers: labellers, doubleLabelledFrames: doubleLabelled, rows: rows, notes: notes)
    }

    public static func markdown(_ r: LabelReport) -> String {
        var s = "### 7. Hand labels\n\n"
        s += "`\(r.directory)` — \(r.files) sheet(s), \(r.frames) scored frame(s), labeller(s) \(r.labellers.isEmpty ? "unnamed" : r.labellers.joined(separator: ", ")), \(r.doubleLabelledFrames) frame(s) labelled twice.\n\n"
        s += "| joint | labelled | scored | median px | p90 px | median SW | label noise px (pairs) | note |\n"
        s += "|---|---:|---:|---:|---:|---:|---:|---|\n"
        for row in r.rows {
            s += "| \(row.joint) | \(row.labelledFrames) | \(row.scoredFrames) | \(FormEvalReporting.fmt(row.medianPixels)) | \(FormEvalReporting.fmt(row.p90Pixels)) | \(FormEvalReporting.fmt(row.medianShoulderWidths, 3)) | \(FormEvalReporting.fmt(row.labelNoiseMedianPixels)) (\(row.labelNoisePairs)) | \(row.unavailableReason ?? "") |\n"
        }
        s += "\n"
        for n in r.notes { s += "- \(n)\n" }
        s += "\n"
        return s
    }
}
