import Foundation
import ShotGeometry
import simd

/// `TrajectoryProbe form <out-model.json> --shots a.json b.json … [--label L] [--spot S]
///                                        [--compare other-model.json] [--vs-shot s.json]`
///
/// Averages per-shot forms (written by `TrajectoryProbe body --form-json`) into one block's
/// `FormModel`, prints what it found — which joints were seen, the tempo, the variability — and
/// optionally compares a shot with the block or one block with another.
enum FormCommand {

    static func run(out: URL, args: [String]) throws {
        func flag(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func list(_ name: String) -> [String] {
            guard let i = args.firstIndex(of: name) else { return [] }
            var v: [String] = []
            var j = i + 1
            while j < args.count, !args[j].hasPrefix("--") { v.append(args[j]); j += 1 }
            return v
        }
        let paths = list("--shots")
        guard !paths.isEmpty else {
            print("""
            usage: TrajectoryProbe form <out-model.json> --shots a.json b.json … [--label L] [--spot S]
                                        [--compare other-model.json] [--vs-shot shot.json]
            """)
            return
        }
        var forms: [ShotForm] = []
        for p in paths {
            let f = try FormJSON.decodeForm(Data(contentsOf: URL(fileURLWithPath: p)))
            forms.append(f)
            print(String(format: "  %@  shot %@  %d/%d samples  %@", (p as NSString).lastPathComponent,
                         f.shotID.map(String.init) ?? "—", f.samples.count, f.sampleCount, f.unit.rawValue))
        }
        let label = flag("--label") ?? out.deletingPathExtension().lastPathComponent
        let model = FormModel.build(forms: forms, label: label, spot: flag("--spot"), date: Date().timeIntervalSince1970)
        if let why = model.unavailableReason {
            print("  form model: nil (\(why))")
            return
        }
        try FormJSON.encode(model).write(to: out)
        report(model)
        print("  wrote \(out.path)")

        if let other = flag("--compare") {
            let b = try FormJSON.decodeModel(Data(contentsOf: URL(fileURLWithPath: other)))
            let d = FormModel.compare(model, with: b)
            print("\n  \(model.label) → \(b.label):")
            if let why = d.unavailableReason { print("    nil (\(why))"); return }
            for r in d.ranked.prefix(10) {
                print(String(format: "    %-14@ %-14@ %+.2f SD  (%.3f %@)", r.joint, r.phase,
                             r.differenceSDs.value ?? .nan, r.displacement.value ?? .nan, model.unit.rawValue))
            }
            for (k, t) in d.tempo.sorted(by: { $0.key < $1.key }) {
                print("    tempo \(k): \(t.aMilliseconds.describe("%.0f")) → \(t.bMilliseconds.describe("%.0f")) = \(t.differenceMilliseconds.describe("%+.0f")), \(t.differenceSDs.describe("%+.2f")) SD")
            }
            for n in d.notes { print("    · \(n)") }
        }

        if let shotPath = flag("--vs-shot") {
            let s = try FormJSON.decodeForm(Data(contentsOf: URL(fileURLWithPath: shotPath)))
            let c = model.compare(shot: s)
            print("\n  shot \(s.shotID.map(String.init) ?? "—") against \(model.label):")
            if let why = c.unavailableReason { print("    nil (\(why))"); return }
            for r in c.ranked.prefix(10) {
                print(String(format: "    %-14@ %-14@ %.2f SD  (%.3f %@)%@", r.joint, r.phase,
                             r.deviationSDs.value ?? .nan, r.displacement.value ?? .nan, model.unit.rawValue,
                             r.inferredBySymmetry ? "  [inferred by symmetry]" : ""))
            }
            for (k, m) in c.tempo.sorted(by: { $0.key < $1.key }) { print("    tempo \(k): \(m.describe("%+.2f")) SD") }
            for n in c.notes { print("    · \(n)") }
        }
    }

    static func report(_ m: FormModel) {
        print(String(format: "  form model \"%@\": %d shots, %d samples, %@", m.label, m.shots, m.sampleCount, m.unit.rawValue))
        print("    \(m.unitNote)")
        print("    joints seen (mean fraction of frames):")
        for (i, name) in m.joints.enumerated() {
            let inferred = m.inferredBySymmetry.indices.contains(i) && m.inferredBySymmetry[i]
            let n = m.sample(at: .release)?.n[i] ?? 0
            print(String(format: "      %-16@ %5.1f %%  on %d shot%@ at release%@", name,
                         100 * (m.seenFraction.indices.contains(i) ? m.seenFraction[i] : 0), n, n == 1 ? "" : "s",
                         inferred ? "   INFERRED BY SYMMETRY (draw dashed)" : ""))
        }
        if !m.refusedJoints.isEmpty {
            for (j, r) in m.refusedJoints.sorted(by: { $0.key < $1.key }) { print("      refused \(j): \(r)") }
        }
        print("    tempo (ms, mean ± SD over n shots):")
        func t(_ name: String, _ s: FormStat) {
            print(String(format: "      %-24@ %@ ± %@  n %d", name, s.mean.describe("%.0f"), s.sd.describe("%.0f"), s.n))
        }
        t("set → dip", m.tempo.setToDip); t("dip → release", m.tempo.dipToRelease)
        t("release → follow-through", m.tempo.releaseToFollowThrough); t("whole shot", m.tempo.total)
        print("    variability (1σ, \(m.unit.rawValue)) at each phase, root-mean-square over the three axes:")
        print(String(format: "      %-16@ %8@ %8@ %8@ %8@", "joint", "set", "dip", "release", "follow"))
        for (i, name) in m.joints.enumerated() {
            var cells: [String] = []
            for phase in FormPhase.allCases {
                guard let s = m.sample(at: phase), let sd = s.spread(i) else { cells.append("     nil"); continue }
                cells.append(String(format: "%8.4f", (simd_length_squared(sd) / 3).squareRoot()))
            }
            print(String(format: "      %-16@ %@", name, cells.joined(separator: " ")))
        }
        print("    joint angles (degrees, mean ± SD at each phase):")
        for track in m.angles {
            var cells: [String] = []
            for phase in FormPhase.allCases {
                let idx = Int((phase.normalisedTime * Double(m.sampleCount - 1)).rounded())
                let mean = track.meanDegrees.indices.contains(idx) ? track.meanDegrees[idx] : nil
                let sd = track.sdDegrees.indices.contains(idx) ? track.sdDegrees[idx] : nil
                cells.append(mean.map { String(format: "%6.1f±%-5.1f", $0, sd ?? .nan) } ?? "    nil     ")
            }
            print(String(format: "      %-24@ %@%@", track.name, cells.joined(separator: " "),
                         track.usesInferredJoints ? "  [uses inferred joints]" : ""))
        }
        for w in m.warnings { print("    ! \(w)") }
        for n in m.notes { print("    · \(n)") }
    }
}
