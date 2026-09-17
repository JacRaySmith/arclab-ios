// Aggregation, the gate verdicts, and the two outputs: a summary table for a terminal and a JSON
// report for a diff. A failing gate is printed as FAIL in the same table as everything else — the
// point of the harness is that a later change cannot quietly lose ground.
import Foundation
import ShotGeometry

// MARK: - report rows

public struct JointErrorRow: Sendable, Codable {
    public var joint: String
    public var shots: Int
    public var frames: Int
    public var medianPixels: Double?
    public var p90Pixels: Double?
    public var medianShoulderWidths: Double?
    public var p90ShoulderWidths: Double?
    public var unavailableReason: String?
}

public struct HeldOutRow: Sendable, Codable {
    public var joint: String
    public var shots: Int
    /// "Blink": the joint's 2-D hidden on every Nth frame, scored on exactly those frames.
    public var blinkFrames: Int
    public var blinkMedianPixels: Double?
    public var blinkP90Pixels: Double?
    public var blinkMedianShoulderWidths: Double?
    /// "Absent": the joint's 2-D removed from every frame.
    public var absentFrames: Int
    public var absentMedianPixels: Double?
    public var absentP90Pixels: Double?
    /// Shots where the whole-joint refit produced no point at all for this joint.
    public var shotsWithNoPoint: Int
    /// The same joint's error when the fit *was* driven by it — the tautology these rows escape.
    public var drivenMedianPixels: Double?
    /// Shots where the refit could only reach the held-out joint by mirroring the other side.
    public var shotsFallingBackToSymmetry: Int
    public var unavailableReason: String?
}

public struct BoneRow: Sendable, Codable {
    public var bone: String
    /// One anatomical segment (gated) or a span across an articulation (reported, never gated).
    public var rigidSegment: Bool
    public var shots: Int
    /// The fitted skeleton's own per-frame length SD, per cent of its median. Near zero **by
    /// construction** on the limb bones: `BodySkeletonOptions.limbBoneWeight` holds them rigid.
    public var fitMedianSDPercent: Double?
    public var fitP90SDPercent: Double?
    /// The same statistic on Vision's *unconstrained* 3-D joints — the honest measurement, because
    /// nothing in that pipeline was told a bone has a fixed length.
    public var visionMedianSDPercent: Double?
    public var visionP90SDPercent: Double?
    public var priorShots: Int
    public var pooledShots: Int
    public var passesGate: Bool?
}

public struct AsymmetryRow: Sendable, Codable {
    public var pair: String
    public var rigidSegment: Bool
    public var shots: Int
    public var fitMedianPercent: Double?
    public var fitP90Percent: Double?
    public var visionMedianPercent: Double?
    public var visionP90Percent: Double?
    /// Shots where the fit pooled the two sides' length, which makes its asymmetry 0 by construction.
    public var pooledShots: Int
    public var passesGate: Bool?
}

public struct CoverageRow: Sendable, Codable {
    public var joint: String
    /// phase label → fraction of shots that had this point at that instant (0–1), over the shots that
    /// *have* that instant at all.
    public var fractionByPhase: [String: Double]
    public var shotsByPhase: [String: Int]
}

public struct GateVerdict: Sendable, Codable {
    public var name: String
    public var threshold: Double
    public var worstValue: Double?
    public var worstSubject: String?
    public var passes: Bool
    public var note: String
}

public struct FormEvalReport: Sendable, Codable {
    public var generated: String
    public var root: String
    public var filesRead: Int
    public var shotsEvaluated: Int
    public var duplicateExportsDropped: Int
    public var sessions: [String: Int]
    public var minimumConfidence2D: Double
    public var heldOutJoints: [String]
    public var shoulderWidthRule: String
    public var perShot: [ShotRow]
    public var reprojection: [JointErrorRow]
    public var heldOut: [HeldOutRow]
    public var bones: [BoneRow]
    public var asymmetry: [AsymmetryRow]
    public var coverage: [CoverageRow]
    public var phaseAvailability: [String: Int]
    public var repeatability: [EvalStats.RepeatabilityResult]
    public var gates: [GateVerdict]
    public var labels: LabelReport?
    public var notes: [String]
}

public struct ShotRow: Sendable, Codable {
    public var id: String
    public var session: String
    public var digest: String
    public var frames: Int
    public var fps: Double
    public var releaseRealTime: Double
    public var statureMetres: Double
    public var shoulderWidthPixels: Double?
    public var reprojectionRMSPixels: Double?
    public var medianReprojectionPixels: Double?
    public var worstBoneSDPercent: Double?
    public var worstAsymmetryPercent: Double?
    public var warnings: [String]
}

// MARK: - aggregation

public enum FormEvalReporting {

    public static func build(evaluations: [ShotEval], options o: FormEvalOptions,
                             root: String, filesRead: Int, duplicatesDropped: Int,
                             labels: LabelReport? = nil, notes: [String] = []) -> FormEvalReport {
        var sessions: [String: Int] = [:]
        for e in evaluations { sessions[e.session, default: 0] += 1 }

        // --- reprojection ---------------------------------------------------------------------
        var reproj: [JointErrorRow] = []
        for joint in BodySkeletonFit.joints {
            var px: [Double] = [], sw: [Double] = [], shots = 0
            for e in evaluations {
                guard let errs = e.drivenError[joint], !errs.isEmpty else { continue }
                shots += 1; px += errs
                if let w = e.shoulderWidthPixels, w > 0 { sw += errs.map { $0 / w } }
            }
            reproj.append(JointErrorRow(joint: joint, shots: shots, frames: px.count,
                                        medianPixels: EvalStats.median(px), p90Pixels: EvalStats.percentile(px, 0.9),
                                        medianShoulderWidths: EvalStats.median(sw),
                                        p90ShoulderWidths: EvalStats.percentile(sw, 0.9),
                                        unavailableReason: px.isEmpty ? "no shot carried an observation of this joint above the confidence gate" : nil))
        }

        // --- held out -------------------------------------------------------------------------
        var held: [HeldOutRow] = []
        for joint in o.heldOutJoints {
            var blink: [Double] = [], blinkSW: [Double] = [], gone: [Double] = []
            var driven: [Double] = [], shots = 0, fallback = 0, noPoint = 0
            for e in evaluations {
                let b = e.blinkError[joint] ?? [], a = e.absentError[joint] ?? []
                if b.isEmpty && a.isEmpty { continue }
                shots += 1
                blink += b; gone += a
                if e.heldOutBySymmetry.contains(joint) { fallback += 1 }
                if e.absentProducedNoPoint.contains(joint) { noPoint += 1 }
                if let w = e.shoulderWidthPixels, w > 0 { blinkSW += b.map { $0 / w } }
                driven += e.drivenError[joint] ?? []
            }
            held.append(HeldOutRow(joint: joint, shots: shots,
                                   blinkFrames: blink.count,
                                   blinkMedianPixels: EvalStats.median(blink),
                                   blinkP90Pixels: EvalStats.percentile(blink, 0.9),
                                   blinkMedianShoulderWidths: EvalStats.median(blinkSW),
                                   absentFrames: gone.count,
                                   absentMedianPixels: EvalStats.median(gone),
                                   absentP90Pixels: EvalStats.percentile(gone, 0.9),
                                   shotsWithNoPoint: noPoint,
                                   drivenMedianPixels: EvalStats.median(driven),
                                   shotsFallingBackToSymmetry: fallback,
                                   unavailableReason: shots == 0 ? "the joint was never observed, so a held-out prediction has nothing to be scored against" : nil))
        }

        // --- bones ----------------------------------------------------------------------------
        var bones: [BoneRow] = []
        for b in BodySkeletonFit.bones {
            let fitSD = evaluations.compactMap { $0.fitBoneSDPercent[b.name] }
            let visSD = evaluations.compactMap { $0.visionBoneSDPercent[b.name] }
            let prior = evaluations.filter { $0.priorBones.contains(b.name) }.count
            let pooled = evaluations.filter { $0.pooledBones.contains(b.name) }.count
            let rigid = FormEvaluator.rigidSegments.contains(b.name)
            let worst = EvalStats.percentile(visSD.isEmpty ? fitSD : visSD, 0.9)
            bones.append(BoneRow(bone: b.name, rigidSegment: rigid, shots: fitSD.count,
                                 fitMedianSDPercent: EvalStats.median(fitSD), fitP90SDPercent: EvalStats.percentile(fitSD, 0.9),
                                 visionMedianSDPercent: EvalStats.median(visSD), visionP90SDPercent: EvalStats.percentile(visSD, 0.9),
                                 priorShots: prior, pooledShots: pooled,
                                 passesGate: rigid ? worst.map { $0 <= o.boneSDGatePercent } : nil))
        }

        // --- asymmetry --------------------------------------------------------------------------
        var asym: [AsymmetryRow] = []
        for pair in FormEvaluator.mirroredPairs {
            let fitA = evaluations.compactMap { $0.fitAsymmetryPercent[pair.name] }
            let visA = evaluations.compactMap { $0.visionAsymmetryPercent[pair.name] }
            let pooled = evaluations.filter { $0.pooledBones.contains(pair.left) || $0.pooledBones.contains(pair.right) }.count
            let worst = EvalStats.percentile(visA.isEmpty ? fitA : visA, 0.9)
            asym.append(AsymmetryRow(pair: pair.name, rigidSegment: pair.gated, shots: fitA.count,
                                     fitMedianPercent: EvalStats.median(fitA), fitP90Percent: EvalStats.percentile(fitA, 0.9),
                                     visionMedianPercent: EvalStats.median(visA), visionP90Percent: EvalStats.percentile(visA, 0.9),
                                     pooledShots: pooled,
                                     passesGate: pair.gated ? worst.map { $0 <= o.asymmetryGatePercent } : nil))
        }

        // --- coverage ----------------------------------------------------------------------------
        var phaseShots: [String: Int] = [:]
        for e in evaluations { for (p, _) in e.coverage { phaseShots[p.label, default: 0] += 1 } }
        var coverage: [CoverageRow] = []
        for joint in FormEvaluator.coveragePoints {
            var frac: [String: Double] = [:], counts: [String: Int] = [:]
            for phase in EvalPhase.allCases {
                let rows = evaluations.compactMap { $0.coverage[phase]?[joint] }
                guard !rows.isEmpty else { continue }
                counts[phase.label] = rows.count
                frac[phase.label] = Double(rows.filter { $0 }.count) / Double(rows.count)
            }
            coverage.append(CoverageRow(joint: joint, fractionByPhase: frac, shotsByPhase: counts))
        }
        // The hand rows, which come from the hand detector rather than the body one.
        var handFrac: [String: Double] = [:], handCounts: [String: Int] = [:]
        var shootFrac: [String: Double] = [:], shootCounts: [String: Int] = [:]
        for phase in EvalPhase.allCases {
            let any = evaluations.compactMap { $0.handCoverage[phase] }
            let shooting = evaluations.compactMap { $0.shootingHandCoverage[phase] }
            if !any.isEmpty { handCounts[phase.label] = any.count; handFrac[phase.label] = Double(any.filter { $0 }.count) / Double(any.count) }
            if !shooting.isEmpty { shootCounts[phase.label] = shooting.count; shootFrac[phase.label] = Double(shooting.filter { $0 }.count) / Double(shooting.count) }
        }
        coverage.append(CoverageRow(joint: "(any hand)", fractionByPhase: handFrac, shotsByPhase: handCounts))
        coverage.append(CoverageRow(joint: "(shooting hand)", fractionByPhase: shootFrac, shotsByPhase: shootCounts))

        // --- repeatability ------------------------------------------------------------------------
        var repeat_: [EvalStats.RepeatabilityResult] = []
        for (name, unit) in FormMeasures.catalogue {
            var full: [Double] = [], a: [Double] = [], b: [Double] = []
            for e in evaluations {
                guard let f = e.measures[name], let x = e.measuresEven[name], let y = e.measuresOdd[name] else { continue }
                full.append(f); a.append(x); b.append(y)
            }
            repeat_.append(EvalStats.repeatability(measure: name, unit: unit, full: full, a: a, b: b,
                                                   bootstrap: o.bootstrapSamples))
        }

        // --- gates --------------------------------------------------------------------------------
        var gates: [GateVerdict] = []
        let boneWorst = bones.filter(\.rigidSegment).compactMap { r -> (Double, String)? in
            guard let v = r.visionP90SDPercent ?? r.fitP90SDPercent else { return nil }
            return (v, r.bone)
        }.max(by: { $0.0 < $1.0 })
        gates.append(GateVerdict(name: "bone-length SD ≤ \(fmt(o.boneSDGatePercent, 1)) % (p90 over shots, per bone)",
                                 threshold: o.boneSDGatePercent, worstValue: boneWorst?.0, worstSubject: boneWorst?.1,
                                 passes: (boneWorst?.0 ?? .infinity) <= o.boneSDGatePercent,
                                 note: "applied to the nine single anatomical segments only; a span across an articulation (biacromial, trunk, head, neck) changes length on a perfectly tracked body and is reported without a gate. Scored on Vision's 3-D joints, because the fitted skeleton's limb bones are rigid by construction and would pass whatever the footage showed"))
        let asymWorst = asym.filter(\.rigidSegment).compactMap { r -> (Double, String)? in
            guard let v = r.visionP90Percent ?? r.fitP90Percent else { return nil }
            return (v, r.pair)
        }.max(by: { $0.0 < $1.0 })
        gates.append(GateVerdict(name: "left–right bone difference ≤ \(fmt(o.asymmetryGatePercent, 1)) % (p90 over shots, per pair)",
                                 threshold: o.asymmetryGatePercent, worstValue: asymWorst?.0, worstSubject: asymWorst?.1,
                                 passes: (asymWorst?.0 ?? .infinity) <= o.asymmetryGatePercent,
                                 note: "limb pairs only, for the same reason; the fit pools mirrored limb lengths on most shots, which makes its own asymmetry 0 by construction"))

        var phaseAvailability: [String: Int] = [:]
        for e in evaluations { for (p, _) in e.phaseTimes { phaseAvailability[p.label, default: 0] += 1 } }

        let perShot = evaluations.map { e -> ShotRow in
            let allErrs = e.drivenError.values.flatMap { $0 }
            return ShotRow(id: e.id, session: e.session, digest: e.inputDigest, frames: e.frameCount, fps: e.fps,
                           releaseRealTime: e.releaseRealTime, statureMetres: e.statureMetres,
                           shoulderWidthPixels: e.shoulderWidthPixels,
                           reprojectionRMSPixels: e.fitReprojectionRMS,
                           medianReprojectionPixels: EvalStats.median(allErrs),
                           worstBoneSDPercent: e.visionBoneSDPercent.values.max(),
                           worstAsymmetryPercent: e.visionAsymmetryPercent.values.max(),
                           warnings: e.warnings)
        }

        let df = ISO8601DateFormatter()
        return FormEvalReport(generated: df.string(from: Date()), root: root, filesRead: filesRead,
                              shotsEvaluated: evaluations.count, duplicateExportsDropped: duplicatesDropped,
                              sessions: sessions, minimumConfidence2D: o.minimumConfidence2D,
                              heldOutJoints: o.heldOutJoints,
                              shoulderWidthRule: evaluations.first?.shoulderWidthNote ?? "no shot produced a shoulder-width ruler",
                              perShot: perShot, reprojection: reproj, heldOut: held, bones: bones,
                              asymmetry: asym, coverage: coverage, phaseAvailability: phaseAvailability,
                              repeatability: repeat_, gates: gates, labels: labels, notes: notes)
    }

    // MARK: - printing

    public static func fmt(_ x: Double?, _ d: Int = 2) -> String {
        guard let x, x.isFinite else { return "—" }
        return String(format: "%.\(d)f", x)
    }

    public static func markdown(_ r: FormEvalReport) -> String {
        var s = ""
        func line(_ t: String) { s += t + "\n" }
        line("## Form evaluation — \(r.shotsEvaluated) shot(s) from \(r.filesRead) file(s)")
        line("")
        line("`\(r.root)`  ·  generated \(r.generated)")
        if r.duplicateExportsDropped > 0 {
            line("")
            line("**\(r.duplicateExportsDropped) file(s) dropped as duplicate exports** — same 2-D input, same release time, a second run of the exporter over one session. Counting them would multiply every N below without adding a single new observation.")
        }
        line("")
        line("Sessions: " + r.sessions.sorted { $0.key < $1.key }.map { "`\($0.key)` ×\($0.value)" }.joined(separator: ", "))
        line("")
        line("Shoulder-width ruler: \(r.shoulderWidthRule)")
        line("")

        line("### 1. Reprojection, per joint (the fit was driven by these pixels)")
        line("")
        line("| joint | shots | frames | median px | p90 px | median SW | p90 SW |")
        line("|---|---:|---:|---:|---:|---:|---:|")
        for j in r.reprojection {
            line("| \(j.joint) | \(j.shots) | \(j.frames) | \(fmt(j.medianPixels)) | \(fmt(j.p90Pixels)) | \(fmt(j.medianShoulderWidths, 3)) | \(fmt(j.p90ShoulderWidths, 3)) |")
        }
        line("")
        line("### 2. Held-out joint: refit with that joint's 2-D removed, then scored against it")
        line("")
        line("`blink` hides the joint on every Nth frame and scores those frames; `absent` removes it from every frame. `no point` counts shots where the whole-joint refit declined to place the joint at all rather than predicting it.")
        line("")
        line("| joint | shots | blink frames | blink median px | blink p90 px | blink median SW | absent median px | no point | mirrored | driven median px |")
        line("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for h in r.heldOut {
            line("| \(h.joint) | \(h.shots) | \(h.blinkFrames) | \(fmt(h.blinkMedianPixels)) | \(fmt(h.blinkP90Pixels)) | \(fmt(h.blinkMedianShoulderWidths, 3)) | \(fmt(h.absentMedianPixels)) | \(h.shotsWithNoPoint) | \(h.shotsFallingBackToSymmetry) | \(fmt(h.drivenMedianPixels)) |")
        }
        line("")
        line("### 3. Bone-length constancy (SD as % of the bone's own median length)")
        line("")
        line("Gated on single anatomical segments only. A span across an articulation — the biacromial (clavicles rotate), the trunk edges and diagonals (the spine flexes), the head and neck spans (the neck rotates) — changes length on a real body, so it is printed as `articulated` rather than judged.")
        line("")
        line("| bone | shots | fit median | fit p90 | Vision median | Vision p90 | prior | pooled | gate |")
        line("|---|---:|---:|---:|---:|---:|---:|---:|:--|")
        for b in r.bones {
            let g = b.rigidSegment ? (b.passesGate.map { $0 ? "pass" : "**FAIL**" } ?? "—") : "articulated"
            line("| \(b.bone) | \(b.shots) | \(fmt(b.fitMedianSDPercent)) | \(fmt(b.fitP90SDPercent)) | \(fmt(b.visionMedianSDPercent)) | \(fmt(b.visionP90SDPercent)) | \(b.priorShots) | \(b.pooledShots) | \(g) |")
        }
        line("")
        line("### 4. Left–right asymmetry (|L−R| ÷ mean, %)")
        line("")
        line("| pair | shots | fit median | fit p90 | Vision median | Vision p90 | pooled | gate |")
        line("|---|---:|---:|---:|---:|---:|---:|:--|")
        for a in r.asymmetry {
            let g = a.rigidSegment ? (a.passesGate.map { $0 ? "pass" : "**FAIL**" } ?? "—") : "articulated"
            line("| \(a.pair) | \(a.shots) | \(fmt(a.fitMedianPercent)) | \(fmt(a.fitP90Percent)) | \(fmt(a.visionMedianPercent)) | \(fmt(a.visionP90Percent)) | \(a.pooledShots) | \(g) |")
        }
        line("")
        line("### 5. Phase-instant coverage (% of shots carrying the point at that instant)")
        line("")
        line("Shots with the instant at all: " + EvalPhase.allCases.map { "\($0.label) \(r.phaseAvailability[$0.label] ?? 0)" }.joined(separator: " · "))
        line("")
        line("| point | set | dip | release | follow |")
        line("|---|---:|---:|---:|---:|")
        for c in r.coverage {
            let cells = EvalPhase.allCases.map { p -> String in
                guard let f = c.fractionByPhase[p.label], let n = c.shotsByPhase[p.label] else { return "—" }
                return String(format: "%.0f %% (%d)", 100 * f, n)
            }
            line("| \(c.joint) | " + cells.joined(separator: " | ") + " |")
        }
        line("")
        line("### 6. Repeatability of the form measures")
        line("")
        line("Subjects are shots; the two repeated measurements are refits of the **same shot** on disjoint halves of its frames (even / odd). ICC(2,1) is two-way random, absolute agreement, single measurement; the interval is a 2 000-sample percentile bootstrap over shots. σ_meas is the SD of one analysis; SDC = 1.96·√2·σ_meas is the change below which two analyses of one movement cannot be told apart. *Reliability* is the share of the shot-to-shot spread that is not measurement noise.")
        line("")
        line("| measure | unit | n | mean | between-shot SD | CV % | σ_meas | SDC | reliability | ICC(2,1) [95 %] |")
        line("|---|---|---:|---:|---:|---:|---:|---:|---:|---|")
        for m in r.repeatability {
            let icc = m.icc.value.map { v -> String in
                if let lo = m.icc.lower95, let hi = m.icc.upper95 { return "\(fmt(v, 3)) [\(fmt(lo, 3)), \(fmt(hi, 3))]" }
                return fmt(v, 3)
            } ?? (m.icc.unavailableReason ?? "—")
            line("| \(m.measure) | \(m.unit) | \(m.n) | \(fmt(m.mean, 3)) | \(fmt(m.betweenShotSD, 3)) | \(fmt(m.cvPercent, 1)) | \(fmt(m.measurementSD, 3)) | \(fmt(m.smallestDetectableChange, 3)) | \(fmt(m.reliability, 2)) | \(icc) |")
        }
        line("")
        if let l = r.labels { s += LabelScoring.markdown(l) }
        line("### Gates")
        line("")
        for g in r.gates {
            line("- \(g.passes ? "PASS" : "**FAIL**") — \(g.name): worst \(fmt(g.worstValue)) % (\(g.worstSubject ?? "—")). \(g.note)")
        }
        if !r.notes.isEmpty {
            line("")
            line("### Notes")
            line("")
            for n in r.notes { line("- \(n)") }
        }
        return s
    }
}
