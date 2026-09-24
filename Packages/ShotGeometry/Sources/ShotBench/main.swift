// ShotBench — replay a cached corpus of shot windows through ShotAnalyzer under a named variant,
// and compare two such replays with a paired statistical test. No video, no network: everything it
// needs was written by `TrajectoryProbe session --dump-windows`.
//
//   ShotBench run <cache-dir> --variant <name> [--json out.json] [--markdown out.md] [--labels path]
//   ShotBench compare <base.json> <cand.json> [--markdown out.md]
//
// See docs/PIPELINE.md.
import Foundation
import ShotGeometry
import ShotBenchKit

func usage() -> Never {
    print("""
    usage:
      ShotBench run <cache-dir> --variant <name> [--json out.json] [--markdown out.md] [--labels path] [--window-labels path]
                     variants: \(Variant.all.map(\.name).joined(separator: ", "))
      ShotBench compare <base.json> <cand.json> [--markdown out.md]
      ShotBench azimuth <cache-dir> --variant <name> [--json out.json]
                     per-window azimuth solve + the robust per-clip pool (diagnosis, no verdict)
    """)
    exit(2)
}

// Everything mutable lives inside this function rather than at file scope: Swift 6 treats a mutable
// top-level `var` as implicitly `@MainActor`-isolated, which a nested nonisolated `func flag` could
// not then read. A local `var` inside an ordinary function has no such isolation.
func runShotBench() {
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { usage() }
    let command = args.removeFirst()

    func flag(_ name: String) -> String? {
        guard let i = args.firstIndex(of: "--" + name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // `gError` is deliberately `.infinity` for a fit whose g is non-finite or non-positive
    // (`GravityGate.verdict`, ShotGeometry/Metrics.swift) — a real, meaningful value ("this fit is
    // not physical"), not something to fabricate a number for. `JSONEncoder`/`JSONDecoder` cannot
    // round-trip Double.infinity/.nan by default, so encode/decode them as tokens instead of
    // clobbering them (e.g. to a sentinel like -999, which a later reader could mistake for real).
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")

    func writeOutputs(json: Encodable, markdownText: String, jsonPath: String?, markdownPath: String?) {
        if let p = jsonPath {
            if let data = try? encoder.encode(json) {
                try? data.write(to: URL(fileURLWithPath: p))
                print("wrote \(p)")
            } else { print("! failed to encode JSON for \(p)") }
        }
        if let p = markdownPath {
            try? markdownText.write(to: URL(fileURLWithPath: p), atomically: true, encoding: .utf8)
            print("wrote \(p)")
        }
    }

    switch command {
    case "run":
        guard let cacheDir = args.first, !cacheDir.hasPrefix("--"), let variantName = flag("variant") else { usage() }
        guard Variant.named(variantName) != nil else {
            print("unknown variant \"\(variantName)\"; known: \(Variant.all.map(\.name).joined(separator: ", "))")
            exit(2)
        }
        let dir = URL(fileURLWithPath: cacheDir)
        do {
            let (windows, loadErrors) = try CacheLoader.loadAll(dir: dir)
            for e in loadErrors { print("! \(e)") }
            guard !windows.isEmpty else { print("no windows loaded from \(cacheDir)"); exit(1) }
            let labelsPath = flag("labels") ?? LabelLoader.defaultPath
            let windowLabelsPath = flag("window-labels") ?? WindowLabelLoader.defaultPath
            guard let card = BenchRunner.run(windows: windows, variantName: variantName, cacheDir: cacheDir, labelsPath: labelsPath, windowLabelsPath: windowLabelsPath) else {
                print("could not build a scorecard for variant \"\(variantName)\""); exit(1)
            }
            let md = BenchReporting.markdown(card)
            print(md)
            writeOutputs(json: card, markdownText: md, jsonPath: flag("json"), markdownPath: flag("markdown"))
        } catch {
            print("! \(error)")
            exit(1)
        }

    case "azimuth":
        guard let cacheDir = args.first, !cacheDir.hasPrefix("--"), let variantName = flag("variant") else { usage() }
        guard Variant.named(variantName) != nil else {
            print("unknown variant \"\(variantName)\"; known: \(Variant.all.map(\.name).joined(separator: ", "))")
            exit(2)
        }
        do {
            let (windows, loadErrors) = try CacheLoader.loadAll(dir: URL(fileURLWithPath: cacheDir))
            for e in loadErrors { print("! \(e)") }
            guard !windows.isEmpty else { print("no windows loaded from \(cacheDir)"); exit(1) }
            guard let diag = AzimuthDiagnoser.run(windows: windows, variantName: variantName, cacheDir: cacheDir) else {
                print("could not build an azimuth diagnosis for variant \"\(variantName)\""); exit(1)
            }
            for p in diag.pools {
                print(String(format: "%@  n=%d kept=%d dropped=%d  centre %.2f°  1.4826·MAD %.2f°  max dev %.2f°  R̄ %.3f  %@",
                             p.clip, p.inputCount, p.keptCount, p.droppedCount, p.centerDegrees ?? .nan,
                             p.scaledMADDegrees ?? .nan, p.maxDeviationDegrees ?? .nan, p.resultantLength ?? .nan,
                             p.engaged ? "would pool" : "would NOT pool — " + p.reason))
            }
            writeOutputs(json: diag, markdownText: "", jsonPath: flag("json"), markdownPath: nil)
        } catch {
            print("! \(error)")
            exit(1)
        }

    case "compare":
        guard args.count >= 2, !args[0].hasPrefix("--"), !args[1].hasPrefix("--") else { usage() }
        let basePath = args[0], candPath = args[1]
        guard let baseData = try? Data(contentsOf: URL(fileURLWithPath: basePath)) else { print("cannot read \(basePath)"); exit(1) }
        guard let candData = try? Data(contentsOf: URL(fileURLWithPath: candPath)) else { print("cannot read \(candPath)"); exit(1) }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let base = try? decoder.decode(Scorecard.self, from: baseData) else { print("cannot decode \(basePath) as a ShotBench scorecard"); exit(1) }
        guard let cand = try? decoder.decode(Scorecard.self, from: candData) else { print("cannot decode \(candPath) as a ShotBench scorecard"); exit(1) }
        let report = Comparator.compare(base: base, candidate: cand)
        let md = BenchReporting.markdown(report)
        print(md)
        writeOutputs(json: report, markdownText: md, jsonPath: nil, markdownPath: flag("markdown"))
        print("verdict: \(report.verdict) — \(report.verdictReason)")
        exit(0)

    default:
        usage()
    }
}

runShotBench()
