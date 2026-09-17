import Foundation
import AVFoundation
import CoreMedia
import CoreML
import ShotVideo
import ShotGeometry
import CoreText

// TrajectoryProbe — desktop tool for Phase 2.
//   probe <clip>                         metadata + measured frame rate from decoded PTS
//   track <clip> [--out run.json] [--length 10] [--min-r 0.005] [--max-r 0.06] [--start s] [--end s] [--roi x,y,w,h]
//   frame <clip> --time <s> --out f.png  export one frame (for rim annotation)

func writeOverlay(clip: URL, samples: [ImageSample], rim: [[Double]], analysis: ShotAnalysis?, intrinsics k: CameraIntrinsics, scale: Double, out: URL) async throws {
    let tRelease = (analysis?.window.releaseTime ?? samples.first?.t ?? 0) * scale
    let framePNG = out.deletingPathExtension().appendingPathExtension("frame.png")
    _ = try await FrameExport.writePNG(url: clip, time: tRelease, to: framePNG)
    var items: [Overlay.Item] = []
    for p in rim { items.append(.init(uv: SIMD2(p[0], p[1]), radius: 2, rgb: (0, 1, 0), filled: true)) }
    let t0 = samples.first?.t ?? 0, t1 = samples.last?.t ?? 1
    for s in samples {
        let f = (s.t - t0) / max(t1 - t0, 1e-6)
        items.append(.init(uv: s.uv, radius: max(3, (s.diameterPx ?? 20) / 2), rgb: (f, 0.2, 1 - f)))
    }
    var legend = ["green dots: rim ellipse fit", "circles blue→red: ball detections over time (radius = detected size)"]
    var polylines: [([SIMD2<Double>], (Double, Double, Double), Double)] = []
    if let a = analysis {
        let ri = a.flightIndices.first ?? 0, ei = a.flightIndices.last ?? 0
        for i in a.flightIndices where i < samples.count { items.append(.init(uv: samples[i].uv, radius: 6, rgb: (1, 1, 1))) }
        if ri < samples.count { items.append(.init(uv: samples[ri].uv, radius: 14, rgb: (1, 0, 0))); items.append(.init(uv: samples[ri].uv, radius: 18, rgb: (1, 0, 0))) }
        if ei < samples.count { items.append(.init(uv: samples[ei].uv, radius: 14, rgb: (1, 0.6, 0))) }
        legend.append("white rings: samples in the flight window   red double ring: release sample   orange ring: window end")
        // reproject the fitted parabola
        var pts: [SIMD2<Double>] = []
        let tr = a.window.releaseTime, te = a.planeSamples[min(ei, a.planeSamples.count - 1)].t
        var t = tr
        while t <= te + 0.05 { let p = a.fit.position(at: t); let P = a.azimuth.frame.point3D(x: p.x, y: p.y)
            if P.z > 0.1 { pts.append(k.pixel(fromNormalized: SIMD2(P.x / P.z, P.y / P.z))) }
            t += 0.01 }
        polylines.append((pts, (1, 0.5, 0), 3))
        let rc = a.calibration.rimCenter
        items.append(.init(uv: k.pixel(fromNormalized: SIMD2(rc.x / rc.z, rc.y / rc.z)), radius: 8, rgb: (0, 1, 0)))
        legend.append(String(format: "orange curve: fitted parabola reprojected   g_fit %.2f  view %.0f°  release θ %@ at h %@", a.confidence.gFit, Angle.degrees(a.confidence.viewAngle),
                             a.metrics.release.map { String(format: "%.1f°", $0.angleDegrees) } ?? "nil", a.metrics.release.map { String(format: "%.2f m", $0.height) } ?? "—"))
    }
    try Overlay.draw(framePNG: framePNG, to: out, items: items, polylines: polylines, legend: legend)
    print("  overlay written: \(out.path)")
}

@main struct Probe {
  static func main() async {
    func usage() -> Never {
        print("""
        usage:
          TrajectoryProbe probe <clip.mov>
          TrajectoryProbe track <clip.mov> [--out run.json] [--length N] [--min-r R] [--max-r R] [--start s] [--end s] [--roi x,y,w,h]
          TrajectoryProbe frame <clip.mov> --time <seconds> --out frame.png
          TrajectoryProbe scan <clip.mov> --rim rim.json --time-scale 4 [--hfov 48] [--start s] [--end s] [--vision] [--vision-only] [--every N] [--downscale N]
                                 [--scan-lanes N] [--process-hz H] [--no-scaled-decode]
          TrajectoryProbe session <clip.mov> --rim rim.json --time-scale 4 --hfov 48 [--known-distance L] [--out session.json] [--overlays dir] [--limit N] [--no-pose] [--pose-hz H] [--legacy-tracking] [--vision-scan]
                                    [--scan-lanes N] [--every N] [--process-hz H] [--no-scaled-decode]
          environment: ARCLAB_SERIAL_PASSES=1 runs the background/candidate passes on one core and waits for
                       each Core ML inference in the decode loop; ARCLAB_NO_BATCH=1 sends tiles one at a time.
                       Both reproduce the pre-2026-09-16 timings with identical output, for measurement.
          TrajectoryProbe analyze <clip.mov> --rim rim.json --start s --end s [--time-scale 8] [--hfov 64] [--rim-diameter 0.4572] [--min-ball-px 10] [--max-ball-px 90]
                                            [--classical] [--no-coreml] [--no-hybrid] [--coreml-confidence C] [--coreml-rate Hz] [--coreml-sweep-rate Hz] [--no-motion-skip]
                                            [--keep-edge] [--track-json t.json] [--pose] [--release-time s]
                                            [--flight-range a,b] [--fixed-g-azimuth] [--known-distance L] [--level-pitch deg] [--overlay o.png] [--review r.mov]
          TrajectoryProbe synth <out.mov> [--fps 240] [--view 30] [--theta 50] [--speed 7.1] [--h 2.2] [--L 4.19] [--dist 8] [--cam-h 1.3] [--seed 1] [--blur 1.0] [--flat]
          TrajectoryProbe form <out-model.json> --shots a.json b.json … [--label L] [--spot S] [--compare other.json] [--vs-shot s.json]
          TrajectoryProbe eval <clip.mov> [--truth clip.truth.json] [--length N] [--min-r R] [--max-r R] [--out eval.json]
        """)
        exit(2)
    }

    var args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else { usage() }
    let command = args.removeFirst()
    let clip = URL(fileURLWithPath: args.removeFirst())

    func flag(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    func describe(_ p: VideoProbeResult) {
        print(String(format: "%@\n  %dx%d %@  transform identity: %@", p.url, p.width, p.height, p.codec, p.transformIsIdentity ? "yes" : "NO " + p.preferredTransformDescription))
        print(String(format: "  nominal fps %.3f   track duration %.3f s", p.nominalFrameRate, p.trackDuration))
        print(String(format: "  decoded frames %d   PTS %.4f → %.4f s", p.decodedFrames, p.firstPTS, p.lastPTS))
        print(String(format: "  measured fps %.3f   median interval %.5f s   min %.5f   max %.5f   jitter %.2f%%   gaps %d",
                     p.measuredFrameRate, p.medianFrameInterval, p.minFrameInterval, p.maxFrameInterval, p.intervalJitterPercent, p.droppedFrameGaps))
        print(String(format: "  timescale %d   header min frame duration %.5f s   edit stretch %.3f×", p.naturalTimeScale, p.minFrameDuration, p.sloMoStretch))
        for sg in p.editSegments.prefix(4) { print("  segment \(sg)") }
        for n in p.notes { print("  ! \(n)") }
    }

        do {
            switch command {
            case "probe":
                let p = try await VideoReader(url: clip).probe()
                describe(p)
            case "track":
                var opt = TrajectoryTrackerOptions()
                if let v = flag("--length").flatMap(Int.init) { opt.trajectoryLength = v }
                if let v = flag("--min-r").flatMap(Float.init) { opt.minimumNormalizedRadius = v }
                if let v = flag("--max-r").flatMap(Float.init) { opt.maximumNormalizedRadius = v }
                if let v = flag("--start").flatMap(Double.init) { opt.startTime = v }
                if let v = flag("--end").flatMap(Double.init) { opt.endTime = v }
                if let v = flag("--roi") { opt.regionOfInterest = v.split(separator: ",").compactMap { Double($0) } }
                let t0 = Date()
                let run = try await TrajectoryTracker.run(url: clip, options: opt) { n, pts in
                    FileHandle.standardError.write(String(format: "  … %d frames, t = %.2f s\r", n, pts).data(using: .utf8)!)
                }
                describe(run.probe)
                let dt = Date().timeIntervalSince(t0)
                print(String(format: "  processed %d frames in %.1f s (%.1f fps)   observations %d   tracks %d",
                             run.framesProcessed, dt, Double(run.framesProcessed) / dt, run.records.count, run.tracks.count))
                for (i, t) in run.tracks.enumerated() {
                    let d = t.lastPTS - t.firstPTS
                    print(String(format: "  track %2d  %.3f → %.3f s (%.2f s)  %3d samples  radius %.1f px  conf max %.2f  from (%.0f,%.0f) to (%.0f,%.0f)",
                                 i, t.firstPTS, t.lastPTS, d, t.samples.count, t.meanRadiusPx, t.maxConfidence,
                                 t.samples.first!.u, t.samples.first!.v, t.samples.last!.u, t.samples.last!.v))
                }
                if let out = flag("--out") {
                    try encoder.encode(run).write(to: URL(fileURLWithPath: out))
                    print("  wrote \(out)")
                }
            case "synth":
                let rad = Angle.radians
                let theta = flag("--theta").flatMap(Double.init) ?? 50
                let L = flag("--L").flatMap(Double.init) ?? 4.19
                let h = flag("--h").flatMap(Double.init) ?? 2.2
                var p = ShotParameters(releaseAngle: rad(theta), releaseSpeed: 7.1, releaseHeight: h, releaseDistance: L)
                p.releaseSpeed = flag("--speed").flatMap(Double.init) ?? (Court.g * L * L / (2 * cos(rad(theta)) * cos(rad(theta)) * (h + L * tan(rad(theta)) - Court.rimHeight))).squareRoot()
                let pl = CameraPlacement(viewAngle: rad(flag("--view").flatMap(Double.init) ?? 30),
                                         distance: flag("--dist").flatMap(Double.init) ?? 8,
                                         height: flag("--cam-h").flatMap(Double.init) ?? 1.3,
                                         intrinsics: CameraPlacement.iPhone1080p())
                var o = SimulationOptions()
                o.fps = flag("--fps").flatMap(Double.init) ?? 240
                o.seed = flag("--seed").flatMap(UInt64.init) ?? 1
                o.preReleaseTime = 0.6; o.postContactDuration = 0.4
                let sim = ShotSimulator.simulate(p, placement: pl, options: o)
                var co = SyntheticClipOptions()
                co.exposureFraction = flag("--blur").flatMap(Double.init) ?? 1.0
                if args.contains("--flat") { co.texturedBackground = false }
                let truth = try await SyntheticClip.write(sim, to: clip, options: co)
                let truthURL = clip.deletingPathExtension().appendingPathExtension("truth.json")
                try encoder.encode(truth).write(to: truthURL)
                let vis = truth.frames.filter { $0.visible && $0.phase == "flight" }
                print(String(format: "wrote %@ (%d frames at %.0f fps, %d visible flight frames, ball %.0f–%.0f px, release at PTS %.3f s, view %.1f°)",
                             clip.path, truth.frames.count, truth.fps, vis.count, vis.map(\.diameterPx).min() ?? 0, vis.map(\.diameterPx).max() ?? 0,
                             truth.releasePTS, truth.viewAngleDeg))
                print("truth: \(truthURL.path)")
            case "eval":
                let truthURL = flag("--truth").map { URL(fileURLWithPath: $0) } ?? clip.deletingPathExtension().appendingPathExtension("truth.json")
                let truth = try JSONDecoder().decode(SyntheticTruth.self, from: Data(contentsOf: truthURL))
                var opt = TrajectoryTrackerOptions()
                if let v = flag("--length").flatMap(Int.init) { opt.trajectoryLength = v }
                if let v = flag("--min-r").flatMap(Float.init) { opt.minimumNormalizedRadius = v }
                if let v = flag("--max-r").flatMap(Float.init) { opt.maximumNormalizedRadius = v }
                let t0 = Date()
                let run = try await TrajectoryTracker.run(url: clip, options: opt)
                let dt = Date().timeIntervalSince(t0)
                let e = DetectorScorer.score(run: run, truth: truth)
                print(String(format: "Vision trajectory detector on %@ (%d frames in %.1f s, %d tracks)", clip.lastPathComponent, run.framesProcessed, dt, run.tracks.count))
                print(String(format: "  recall: below apex %.1f%% (gate 90)   final third %.1f%% (gate 75)   overall %.1f%%  (%d of %d flight frames)",
                             e.recallBelowApexAscending * 100, e.recallFinalThird * 100, e.recallOverall * 100, e.flightFramesDetected, e.flightFrames))
                print(String(format: "  centroid error px: mean %.2f  rms %.2f  p90 %.2f  max %.2f   diameter bias %.2f px   false positives in flight %d   samples outside flight %d",
                             e.centroidErrorMeanPx, e.centroidErrorRMSPx, e.centroidErrorP90Px, e.centroidErrorMaxPx, e.diameterErrorMeanPx, e.falsePositivesDuringFlight, e.samplesOutsideFlight))
                if let off = e.firstDetectedFlightFrameOffset { print("  first flight detection \(off) frame(s) after release") }
                if let p = e.pipeline {
                    print(String(format: "  pipeline: θ %@ (err %@)   g %.3f (%.2f%%)   entry %@ (err %@)   Δh %@   rms %.2f px   inliers %d   view %.1f°",
                                 p.releaseAngleDeg.map { String(format: "%.2f°", $0) } ?? "nil: \(p.releaseUnavailableReason ?? "?")",
                                 p.releaseAngleErrorDeg.map { String(format: "%.2f°", $0) } ?? "—",
                                 p.gFit, p.gErrorPercent,
                                 p.entryAngleDeg.map { String(format: "%.2f°", $0) } ?? "nil", p.entryAngleErrorDeg.map { String(format: "%.2f°", $0) } ?? "—",
                                 p.releaseHeightError.map { String(format: "%.3f m", $0) } ?? "—", p.rmsPx, p.nInliers, p.viewAngleDeg))
                    for w in p.warnings { print("    warning: \(w)") }
                } else if let err = e.pipelineError { print("  pipeline error: \(err)") }
                if let out = flag("--out") { try encoder.encode(e).write(to: URL(fileURLWithPath: out)); print("  wrote \(out)") }
            case "scan":
            // Where are the shots? Runs the fast rim scanner (and, with --vision, the old whole-clip
            // DetectTrajectories scanner) and applies the same `find_arrivals` rule to both, so the two
            // arrival lists can be compared directly.
            guard let rimPath = flag("--rim") else { usage() }
            struct RimFile: Decodable { var points: [[Double]] }
            let rim = try JSONDecoder().decode(RimFile.self, from: Data(contentsOf: URL(fileURLWithPath: rimPath)))
            let scale = flag("--time-scale").flatMap(Double.init) ?? 1
            let hfov = flag("--hfov").flatMap(Double.init) ?? 64
            let startAt = flag("--start").flatMap(Double.init) ?? 0
            let endAt = flag("--end").flatMap(Double.init)
            let head = try await VideoReader(url: clip).quickProbe(maxFrames: 90)
            let kScan = CameraIntrinsics(width: head.width, height: head.height, horizontalFOVDegrees: hfov)
            var roScan = RimCalibrationOptions(); roScan.rimDiameter = flag("--rim-diameter").flatMap(Double.init) ?? Court.rimInnerDiameter
            let calScan = try RimCalibrator.calibrate(boundaryPoints: rim.points.map { SIMD2($0[0], $0[1]) }, intrinsics: kScan, options: roScan)
            let rimCentre = calScan.ellipse.center
            let ballPx = 2 * calScan.ellipse.semiMajor * (BallSize.size7.diameter / calScan.rimDiameterUsed)
            print(String(format: "rim centre %.1f, %.1f px   ball %.0f px at the rim   %dx%d", rimCentre.x, rimCentre.y, ballPx, head.width, head.height))

            func report(_ label: String, _ arrivals: [ArrivalEvent], _ seconds: Double, _ frames: Int, _ extra: String) {
                print(String(format: "%@: %d arrivals in %.1f s (%d frames, %.0f fps) %@", label, arrivals.count, seconds, frames,
                             seconds > 0 ? Double(frames) / seconds : 0, extra))
                print("  " + arrivals.map { String(format: "%.2f", $0.fileTime) }.joined(separator: " "))
            }
            var fastArrivals: [ArrivalEvent] = []
            var visionArrivals: [ArrivalEvent] = []
            if !args.contains("--vision-only") {
                var so = RimScanOptions()
                so.startTime = startAt
                so.endTime = endAt
                if let v = flag("--every").flatMap(Int.init) { so.everyNthFrame = v }
                if let v = flag("--downscale").flatMap(Int.init) { so.downscale = v }
                if let v = flag("--process-hz").flatMap(Double.init) { so.processHz = v }
                if args.contains("--no-scaled-decode") { so.scaledDecode = false }
                if let v = flag("--scan-lanes").flatMap(Int.init) { so.lanes = v }
                so.timeScale = scale
                let timings = StageTimings()
                let t0 = Date()
                let r = try await RimArrivalScanner.scan(url: clip, rimCenter: rimCentre, ballDiameterPx: ballPx,
                                                        options: so, timings: timings) { n, t in
                    FileHandle.standardError.write(String(format: "  fast … %d frames, t = %.1f s\r", n, t).data(using: .utf8)!)
                }
                let dt = Date().timeIntervalSince(t0)
                var slots: [Int: [ArrivalCandidate]] = [:]
                for c in r.candidates { slots[c.frameIndex, default: []].append(ArrivalCandidate(u: c.u, v: c.v, diameterPx: c.diameterPx)) }
                fastArrivals = ArrivalRule.arrivals(slots: slots, fps: r.measuredFrameRate, frameHeight: Double(r.height),
                                                    rimCenter: rimCentre, ballDiameterPx: ballPx, timeScale: scale)
                if let dump = flag("--dump") {
                    let rows = r.candidates.map { ["f": Double($0.frameIndex), "t": $0.pts, "u": $0.u, "v": $0.v, "d": $0.diameterPx, "s": $0.meanDiff] }
                    try JSONSerialization.data(withJSONObject: rows, options: []).write(to: URL(fileURLWithPath: dump))
                    print("  wrote \(dump) (\(rows.count) candidates)")
                }
                for n in r.notes { print("  " + n) }
                print("  " + timings.line())
                report("fast scan", fastArrivals, dt, r.framesDecoded, String(format: "%d candidates", r.candidates.count))
            }
            if args.contains("--vision") || args.contains("--vision-only") {
                let t0 = Date()
                var slots: [Int: [ArrivalCandidate]] = [:]
                var fpsV = 0.0, framesV = 0, heightV = head.height
                var chunkStart = startAt
                let scanEnd = endAt ?? .infinity
                while chunkStart < scanEnd {
                    var opt = TrajectoryTrackerOptions()
                    opt.startTime = chunkStart
                    let chunkEnd = min(chunkStart + 60, scanEnd)
                    opt.endTime = chunkEnd
                    let run = try await TrajectoryTracker.run(url: clip, options: opt) { n, t in
                        FileHandle.standardError.write(String(format: "  vision … %d frames, t = %.1f s\r", n, t).data(using: .utf8)!)
                    }
                    framesV += run.framesProcessed
                    if fpsV == 0 { fpsV = run.probe.measuredFrameRate; heightV = run.probe.height }
                    for track in run.tracks { for smp in track.samples {
                        let idx = Int((smp.pts * fpsV).rounded())
                        let c = ArrivalCandidate(u: smp.u, v: smp.v, diameterPx: 2 * smp.radiusPx)
                        if let e = slots[idx], e.contains(where: { abs($0.u - c.u) < 2 && abs($0.v - c.v) < 2 }) { continue }
                        slots[idx, default: []].append(c)
                    } }
                    if run.framesProcessed == 0 || chunkEnd >= scanEnd { break }
                    chunkStart = chunkEnd - 3
                }
                let dt = Date().timeIntervalSince(t0)
                visionArrivals = ArrivalRule.arrivals(slots: slots, fps: fpsV, frameHeight: Double(heightV),
                                                      rimCenter: rimCentre, ballDiameterPx: ballPx, timeScale: scale)
                report("vision scan", visionArrivals, dt, framesV, "")
            }
            if !fastArrivals.isEmpty, !visionArrivals.isEmpty {
                var matched = 0
                var offsets: [Double] = []
                var lost: [Double] = []
                for v in visionArrivals {
                    if let f = fastArrivals.min(by: { abs($0.fileTime - v.fileTime) < abs($1.fileTime - v.fileTime) }),
                       abs(f.fileTime - v.fileTime) <= 0.5 * scale {
                        matched += 1; offsets.append(f.fileTime - v.fileTime)
                    } else { lost.append(v.fileTime) }
                }
                let gained = fastArrivals.filter { f in !visionArrivals.contains { abs($0.fileTime - f.fileTime) <= 0.5 * scale } }.map(\.fileTime)
                print(String(format: "match: %d of %d vision arrivals found by the fast scan (max |Δ| %.2f s file); lost %@; gained %@",
                             matched, visionArrivals.count, offsets.map { abs($0) }.max() ?? 0,
                             lost.isEmpty ? "none" : lost.map { String(format: "%.1f", $0) }.joined(separator: ","),
                             gained.isEmpty ? "none" : gained.map { String(format: "%.1f", $0) }.joined(separator: ",")))
            }
            case "session":
            guard let rimPath = flag("--rim") else { usage() }
            struct RimFile: Decodable { var points: [[Double]] }
            let rim = try JSONDecoder().decode(RimFile.self, from: Data(contentsOf: URL(fileURLWithPath: rimPath)))
            let scale = flag("--time-scale").flatMap(Double.init) ?? 1
            let hfov = flag("--hfov").flatMap(Double.init) ?? 64
            let known = flag("--known-distance").flatMap(Double.init)
            let limit = flag("--limit").flatMap(Int.init) ?? 1000
            let rimC = rim.points.reduce(SIMD2<Double>(0, 0)) { $0 + SIMD2($1[0], $1[1]) } / Double(rim.points.count)
            var vo = TrajectoryTrackerOptions()
            if let v = flag("--start").flatMap(Double.init) { vo.startTime = v }
            if let v = flag("--end").flatMap(Double.init) { vo.endTime = v }
            // Where the shots are. The fast scanner decodes the clip once and looks for ball-sized moving blobs on a
            // crop around the rim (`--vision-scan` keeps the old whole-clip DetectTrajectories pass for comparison).
            let useVisionScan = args.contains("--vision-scan")
            let head = try await VideoReader(url: clip).quickProbe(maxFrames: 90)
            var probeW = head.width, probeH = head.height, fpsSession = head.measuredFrameRate
            var shots: [(start: Double, end: Double)] = []
            var ballTracks: [TrajectoryTrack] = []
            var scanCandidates: [RimScanCandidate] = []
            let scanTimings = StageTimings()
            let t0 = Date()
            if useVisionScan {
                let run = try await TrajectoryTracker.run(url: clip, options: vo) { n, t in FileHandle.standardError.write(String(format: "  … %d frames, t = %.1f s\r", n, t).data(using: .utf8)!) }
                probeW = run.probe.width; probeH = run.probe.height; fpsSession = run.probe.measuredFrameRate
                print(String(format: "Vision pass: %d frames, %d tracks in %.0f s", run.framesProcessed, run.tracks.count, Date().timeIntervalSince(t0)))
                // Shot candidates: ball-sized tracks that end within 250 px of the rim centre, merged when they overlap in time.
                ballTracks = run.tracks.filter { t in t.meanRadiusPx > 8 && t.meanRadiusPx < 70 && t.samples.count >= 8 }
                for t in ballTracks.sorted(by: { $0.firstPTS < $1.firstPTS }) {
                    let last = t.samples.last!
                    let nearRim = ((last.u - rimC.x) * (last.u - rimC.x) + (last.v - rimC.y) * (last.v - rimC.y)).squareRoot() < 250
                    guard nearRim else { continue }
                    if let l = shots.last, t.firstPTS - l.end < 2.0 * scale { shots[shots.count - 1].end = max(l.end, t.lastPTS) }
                    else { shots.append((t.firstPTS, t.lastPTS)) }
                }
            }
            let kScan = CameraIntrinsics(width: probeW, height: probeH, horizontalFOVDegrees: hfov)
            var roScan = RimCalibrationOptions(); roScan.rimDiameter = flag("--rim-diameter").flatMap(Double.init) ?? Court.rimInnerDiameter
            let calScan = try RimCalibrator.calibrate(boundaryPoints: rim.points.map { SIMD2($0[0], $0[1]) }, intrinsics: kScan, options: roScan)
            let ballPxAtRim = 2 * calScan.ellipse.semiMajor * (BallSize.size7.diameter / calScan.rimDiameterUsed)
            if !useVisionScan {
                var so = RimScanOptions()
                if let v = flag("--start").flatMap(Double.init) { so.startTime = v }
                if let v = flag("--end").flatMap(Double.init) { so.endTime = v }
                if let v = flag("--every").flatMap(Int.init) { so.everyNthFrame = v }
                if let v = flag("--process-hz").flatMap(Double.init) { so.processHz = v }
                if args.contains("--no-scaled-decode") { so.scaledDecode = false }
                if let v = flag("--scan-lanes").flatMap(Int.init) { so.lanes = v }
                so.timeScale = scale
                let r = try await RimArrivalScanner.scan(url: clip, rimCenter: calScan.ellipse.center, ballDiameterPx: ballPxAtRim,
                                                         options: so, timings: scanTimings) { n, t in
                    FileHandle.standardError.write(String(format: "  … %d frames, t = %.1f s\r", n, t).data(using: .utf8)!)
                }
                probeW = r.width; probeH = r.height; fpsSession = r.measuredFrameRate
                scanCandidates = r.candidates
                var slots: [Int: [ArrivalCandidate]] = [:]
                for c in r.candidates { slots[c.frameIndex, default: []].append(ArrivalCandidate(u: c.u, v: c.v, diameterPx: c.diameterPx)) }
                let arrivals = ArrivalRule.arrivals(slots: slots, fps: r.measuredFrameRate, frameHeight: Double(r.height),
                                                   rimCenter: calScan.ellipse.center, ballDiameterPx: ballPxAtRim, timeScale: scale)
                // The app's window: arrival − (1.3 + 0.35) s real → arrival + 0.4 s real, in file time.
                for a in arrivals { shots.append((max(0, a.fileTime - 1.65 * scale), a.fileTime + 0.4 * scale)) }
                print(String(format: "fast scan: %d frames, %d candidates, %d arrivals in %.0f s (%@)",
                             r.framesDecoded, r.candidates.count, arrivals.count, Date().timeIntervalSince(t0), scanTimings.line(prefix: "")))
            }
            print("shot candidates: \(shots.count)")
            let k = kScan
            let cal = calScan
            // Pass 1: detect + analyse each shot with the per-shot fixed-g azimuth. Pass 2: the camera and the station do not
            // move within a block, so fix the azimuth at the median of the accepted shots and re-analyse everything.
            struct ShotInput { var index: Int; var start: Double; var end: Double; var fileStart: Double; var samples: [ImageSample]; var releaseReal: Double? }
            // `report.py`'s acceptance rule, as the app applies it (`ShotAcceptance.evaluate`): gravity within
            // 8 %, a physically possible release, **and** a fit that actually passes through the tracked ball.
            // The residual ceiling is the app's 25 px; without it the probe accepted rows the phone rejects.
            let maxReprojectionRmsPx = 25.0
            func plausible(_ m: ShotMetrics) -> Bool {
                guard let r = m.release, let depth = m.depthPastFrontRim else { return false }
                return r.height >= 1.6 && r.height <= 3.3 && r.speed >= 4.5 && r.speed <= 11 && depth >= -0.6 && depth <= 1.0
            }
            func accepted(_ a: ShotAnalysis) -> Bool {
                a.confidence.gError <= 0.08 && plausible(a.metrics) && a.confidence.rmsPx <= maxReprojectionRmsPx
            }
            let withPose = !args.contains("--no-pose")
            let legacyTracking = args.contains("--legacy-tracking")     // pre-2026-09-14 detector, for the before/after
            var inputs: [ShotInput] = []
            let sessionTimings = StageTimings()
            var windowSeconds: [Double] = []
            for (i, sh) in shots.prefix(limit).enumerated() {
                let start = max(0, sh.start - 0.35 * scale), end = sh.end + 0.4 * scale
                var seed: [Int: SIMD2<Double>] = [:]
                var radii: [Double] = []
                for t in ballTracks { for smp in t.samples where smp.pts >= start && smp.pts <= end {
                    seed[Int((smp.pts * fpsSession).rounded())] = SIMD2(smp.u, smp.v); radii.append(smp.radiusPx) } }
                for c in scanCandidates where c.pts >= start && c.pts <= end {
                    if seed[c.frameIndex] == nil { seed[c.frameIndex] = SIMD2(c.u, c.v) }
                }
                var dopt = BallDetectorOptions()
                // The gates are physical; the detector needs the file's slow-motion factor to turn them into
                // per-frame numbers (docs/HANDOFF.md, "Tracking at 240 fps").
                dopt.timeScale = scale
                if !radii.isEmpty { dopt.expectedDiameterPx = 1.6 * radii.sorted()[radii.count / 2] }
                else { dopt.expectedDiameterPx = ballPxAtRim }
                if args.contains("--no-motion-skip") { dopt.coreMLSkipWhenMotionAgrees = false }
                if args.contains("--no-still-sweep-gate") { dopt.coreMLSweepOnlyWhenMoving = false }
                if args.contains("--no-free-flight-trim") { dopt.trimAfterFreeFlight = false }
                if let v = flag("--free-flight-drop").flatMap(Double.init) { dopt.freeFlightMinimumDropDiameters = v }
                if let v = flag("--free-flight-residual").flatMap(Double.init) { dopt.freeFlightResidualDiameters = v }
                if args.contains("--legacy-rates") {
                    // The per-frame gates as they stood before 2026-09-15: tuned at 120 fps and applied to every
                    // clip whatever its capture rate. Kept so the frame-rate work can be measured against itself.
                    dopt.timeScale = nil
                }
                if legacyTracking {
                    // Everything the 2026-09-14 parity work added, switched off, so the same harness can measure what
                    // the tracking change alone is worth.
                    dopt.coreMLHybridCentroid = false; dopt.predictedWeakCandidates = false
                    dopt.trimAfterBounce = false; dopt.extendBackDiametersPerSecond = 120
                }
                // One decode for the whole window: the planes, the Core ML boxes and the background model are built
                // once and every later stage works from them.
                let wt = StageTimings()
                let tw = Date()
                var dets: [BallDetection] = []
                var dstats = BallDetectorStats()
                if let win = try? await BallDetector.decodeWindow(url: clip, start: start, end: end, seed: seed,
                                                                  fps: fpsSession, options: dopt, timings: wt) {
                    let r = BallDetector.track(window: win, seed: seed, options: dopt, timings: wt)
                    dets = r.detections; dstats = r.stats
                }
                // The release instant from the shooter's wrist, exactly as the app's session flow does it: the ball
                // alone cannot say when the hand let go. Every 2nd frame, and only over the part of the window that
                // can carry a release — from its start to a little after the ball's first detection.
                var releaseReal: Double? = nil
                if withPose, dets.count >= 12 {
                    let clean = dets.filter { !$0.edge }
                    let sizes = (clean.count >= 8 ? clean : dets).map(\.diameterPx).sorted()
                    let ballPx = sizes.isEmpty ? 0 : sizes[sizes.count / 2]
                    let firstBall = dets.map(\.pts).min() ?? start
                    let poseStart = max(start, firstBall - 0.7 * scale)
                    let poseEnd = min(end, firstBall + 0.5 * scale)
                    let tPose = StageTimings.now()
                    // The pose pass is throttled by real time, not by file frames: every 2nd frame at 120 fps,
                    // every 3rd at 240, so the Vision cost does not double with the capture rate.
                    // `--pose-hz` overrides it, so the throttle can be measured against every frame.
                    let poseHz = flag("--pose-hz").flatMap(Double.init) ?? 80.0
                    let poseStep = max(1, Int((fpsSession * scale / max(1e-6, poseHz)).rounded()))
                    let poses = try? await PoseTracker.run(url: clip, start: poseStart, end: max(poseStart + 0.05, poseEnd), everyNthFrame: poseStep,
                                                           ballSeed: dets.map { (pts: $0.pts, uv: SIMD2($0.u, $0.v)) },
                                                           fps: fpsSession)
                    wt.add("vision.pose", since: tPose)
                    if let poses, let r = ReleaseFromPose.estimate(detections: dets, poses: poses, ballDiameterPx: ballPx) {
                        releaseReal = r.pts / scale
                    }
                }
                let spent = Date().timeIntervalSince(tw)
                windowSeconds.append(spent)
                sessionTimings.absorb(wt)
                // Edge-clipped blobs have an inward-biased centroid: the fit must not see them.
                inputs.append(ShotInput(index: i + 1, start: start, end: end, fileStart: sh.start,
                                        samples: dets.filter { legacyTracking || !$0.edge }.map { ImageSample(t: $0.pts / scale, uv: SIMD2($0.u, $0.v), diameterPx: $0.diameterPx) },
                                        releaseReal: releaseReal))
                print(String(format: "  shot %d/%d  %.2f s  %d detections  [%d tiles on %d frames: %d aimed, %d swept, %d skipped on motion, %d still-frame sweeps skipped, %.1f ms/tile]   %@",
                             i + 1, min(shots.count, limit), spent, dets.count, dstats.coreMLTiles, dstats.coreMLFramesRun,
                             dstats.coreMLAimedFrames, dstats.coreMLGlobalFrames, dstats.coreMLMotionSkippedFrames,
                             dstats.coreMLStillFrameSweepsSkipped, dstats.meanTileMilliseconds, wt.line(prefix: "")))
            }
            if !windowSeconds.isEmpty {
                let sorted = windowSeconds.sorted()
                print(String(format: "per-window: median %.2f s, mean %.2f s, max %.2f s over %d windows",
                             sorted[sorted.count / 2], windowSeconds.reduce(0, +) / Double(windowSeconds.count), sorted.last!, windowSeconds.count))
                print("  " + sessionTimings.line(prefix: "totals:"))
            }
            // Pass 1's azimuths are only worth pooling from shots that actually solved: gravity *and* a physically
            // possible release. Azimuth is an angle on a circle, so the pool is averaged as unit vectors, and it is
            // used only when the shots agree — otherwise the per-shot solve stands.
            var azimuths: [Double] = []
            for inp in inputs {
                var ao = AnalysisOptions(); ao.knownReleaseDistance = known; ao.azimuthByFixedGravity = true
                if let rt = inp.releaseReal { ao.windowOptions.releaseTimeOverride = rt }
                if let a = try? ShotAnalyzer.analyze(track: inp.samples, calibration: cal, intrinsics: k, options: ao), accepted(a) {
                    azimuths.append(a.azimuth.frame.azimuth)
                }
            }
            var sessionAzimuth: Double? = nil
            if azimuths.count >= 3 {
                let mean = atan2(azimuths.map(sin).reduce(0, +) / Double(azimuths.count),
                                 azimuths.map(cos).reduce(0, +) / Double(azimuths.count))
                func wrap(_ x: Double) -> Double { atan2(sin(x), cos(x)) }
                let spread = azimuths.map { abs(wrap($0 - mean)) }.max() ?? 0
                if Angle.degrees(spread) <= 25 {
                    sessionAzimuth = mean
                    let fr = ShotPlaneSolver.frame(calibration: cal, azimuth: mean)
                    print(String(format: "session azimuth: circular mean of %d accepted shots → view angle %.1f° from side (max deviation %.1f°)",
                                 azimuths.count, Angle.degrees(fr.viewAngle), Angle.degrees(spread)))
                } else {
                    print(String(format: "session azimuth: %d accepted shots disagree by %.0f°; using per-shot solves", azimuths.count, Angle.degrees(spread)))
                }
            } else { print("session azimuth: \(azimuths.count) accepted shot(s) in pass 1 (need 3); using per-shot solves") }
            var rows: [[String: Double]] = []
            var nAccepted = 0
            print(" #   file t(s)   g_fit   %err  verdict  θ°    h m   v m/s  L m   entry°  depth m  n   rms px  note")
            for inp in inputs {
                let i = inp.index - 1, sh = (start: inp.fileStart, end: inp.end), start = inp.start, end = inp.end, samples = inp.samples
                var ao = AnalysisOptions(); ao.azimuthByFixedGravity = true
                if let az = sessionAzimuth { ao.fixedAzimuth = az } else { ao.knownReleaseDistance = known }
                if let rt = inp.releaseReal { ao.windowOptions.releaseTimeOverride = rt }
                do {
                    let a = try ShotAnalyzer.analyze(track: samples, calibration: cal, intrinsics: k, options: ao)
                    let m = a.metrics, c = a.confidence
                    let note = (accepted(a) ? "ACCEPT " : "") + (c.warnings.contains { $0.contains("bridged") } ? "bridged " : "") + (m.release == nil ? "no-release " : "")
                        + (inp.releaseReal.map { String(format: "rel %.3f ", $0 * scale) } ?? "")
                    if accepted(a) { nAccepted += 1 }
                    print(String(format: "%2d  %8.1f   %5.2f  %5.1f  %-8@ %5.1f  %5.2f  %5.2f  %5.2f  %5.1f   %6.2f  %3d  %5.1f  %@",
                                 i + 1, sh.start, c.gFit, c.gError * 100, c.gravityVerdict.rawValue,
                                 m.release?.angleDegrees ?? .nan, m.release?.height ?? .nan, m.release?.speed ?? .nan, m.release?.distance ?? .nan,
                                 m.entryAngleDegrees ?? .nan, m.depthPastFrontRim ?? .nan, c.nInliers, c.rmsPx, note))
                    rows.append(["shot": Double(i + 1), "fileTime": sh.start, "gFit": c.gFit, "gError": c.gError, "theta": m.release?.angleDegrees ?? .nan,
                                 "h": m.release?.height ?? .nan, "v": m.release?.speed ?? .nan, "L": m.release?.distance ?? .nan,
                                 "entry": m.entryAngleDegrees ?? .nan, "depth": m.depthPastFrontRim ?? .nan, "rmsPx": c.rmsPx, "n": Double(c.nInliers)])
                    if let dir = flag("--reviews") {
                        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        let title = String(format: "shot %d  g_fit %.2f (%.1f%%)  release θ %@ h %@  entry %@  depth %@", i + 1, c.gFit, c.gError * 100,
                                           m.release.map { String(format: "%.1f°", $0.angleDegrees) } ?? "nil", m.release.map { String(format: "%.2f m", $0.height) } ?? "—",
                                           m.entryAngleDegrees.map { String(format: "%.1f°", $0) } ?? "nil", m.depthPastFrontRim.map { String(format: "%.2f m", $0) } ?? "—")
                        let pr = OverlayVideo.Params(samples: samples, analysis: a, rim: rim.points.map { SIMD2($0[0], $0[1]) }, intrinsics: k, scale: scale, title: title)
                        _ = try? await OverlayVideo.write(clip: clip, start: start, end: end, params: pr, to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "shot%02d.mov", i + 1)))
                    }
                    if let dir = flag("--overlays") {
                        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        try? await writeOverlay(clip: clip, samples: samples, rim: rim.points, analysis: a, intrinsics: k, scale: scale, out: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "shot%02d.png", i + 1)))
                    }
                } catch {
                    print(String(format: "%2d  %8.1f   failed: %@ (%d detections)", i + 1, sh.start, "\(error)", samples.count))
                    rows.append(["shot": Double(i + 1), "fileTime": sh.start, "gFit": .nan])
                }
            }
            print("accepted \(nAccepted) of \(inputs.count) windows (gravity within 8 %, release height 1.6–3.3 m, speed 4.5–11 m/s, depth −0.6…1.0 m, fit residual ≤ 25 px)")
            if let out = flag("--out") { try JSONSerialization.data(withJSONObject: rows.map { $0.mapValues { $0.isFinite ? $0 : -999 } }, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: out)); print("wrote \(out)") }
        case "analyze":
            guard let rimPath = flag("--rim"), let start = flag("--start").flatMap(Double.init), let end = flag("--end").flatMap(Double.init) else { usage() }
            struct RimFile: Decodable { var points: [[Double]] }
            let rim = try JSONDecoder().decode(RimFile.self, from: Data(contentsOf: URL(fileURLWithPath: rimPath)))
            let scale = flag("--time-scale").flatMap(Double.init) ?? 1
            let hfov = flag("--hfov").flatMap(Double.init) ?? 64
            let rimD = flag("--rim-diameter").flatMap(Double.init) ?? Court.rimInnerDiameter
            let minBall = flag("--min-ball-px").flatMap(Double.init) ?? 10, maxBall = flag("--max-ball-px").flatMap(Double.init) ?? 140
            var opt = TrajectoryTrackerOptions(); opt.startTime = start; opt.endTime = end
            let run = try await TrajectoryTracker.run(url: clip, options: opt)
            let k = CameraIntrinsics(width: run.probe.width, height: run.probe.height, horizontalFOVDegrees: hfov)
            var perFrame: [Int: TrackSample] = [:]
            for t in run.tracks { for smp in t.samples where 2 * smp.radiusPx >= minBall && 2 * smp.radiusPx <= maxBall {
                let idx = Int((smp.pts * run.probe.measuredFrameRate).rounded())
                if let e = perFrame[idx], e.confidence >= smp.confidence { continue }
                perFrame[idx] = smp
            } }
            var samples = perFrame.keys.sorted().map { i -> ImageSample in
                let smp = perFrame[i]!; return ImageSample(t: smp.pts / scale, uv: SIMD2(smp.u, smp.v), diameterPx: 2 * smp.radiusPx)
            }
            // The same ball samples in file-time pixel form, for the pose stage (which works in file seconds).
            var ballDets: [BallDetection] = perFrame.keys.sorted().map { i in
                let s = perFrame[i]!
                return BallDetection(frameIndex: i, pts: s.pts, u: s.u, v: s.v, diameterPx: 2 * s.radiusPx,
                                     score: Double(s.confidence), predicted: false, source: "detected", edge: false)
            }
            if let tj = flag("--track-json") {
                // pytrack output: frames[].t (real seconds) and .ball {u, v, r, source}; use every evidence-based sample
                struct PyBall: Decodable { var u: Double?; var v: Double?; var r: Double?; var source: String; var edge: Bool? }
                struct PyFrame: Decodable { var t: Double; var t_file: Double; var ball: PyBall }
                struct PyTrack: Decodable { var frames: [PyFrame] }
                let py = try JSONDecoder().decode(PyTrack.self, from: Data(contentsOf: URL(fileURLWithPath: tj)))
                samples = py.frames.compactMap { f -> ImageSample? in
                    guard let u = f.ball.u, let v = f.ball.v, let r = f.ball.r, ["detected", "held", "template", "merged"].contains(f.ball.source) else { return nil }
                    // A blob cut by the frame edge has its centroid pulled inward (an apex above the frame reads as a
                    // flatter arc, so g fits low); the grader excuses these frames and the fit must not see them.
                    if f.ball.edge == true, !args.contains("--keep-edge") { return nil }
                    return ImageSample(t: f.t, uv: SIMD2(u, v), diameterPx: 2 * r)
                }
                ballDets = py.frames.enumerated().compactMap { (i, f) -> BallDetection? in
                    guard let u = f.ball.u, let v = f.ball.v, let r = f.ball.r else { return nil }
                    return BallDetection(frameIndex: i, pts: f.t_file, u: u, v: v, diameterPx: 2 * r,
                                         score: 0, predicted: false, source: f.ball.source, edge: f.ball.edge ?? false)
                }
                print(String(format: "pytrack samples: %d (t %.3f–%.3f s real)", samples.count, samples.first?.t ?? 0, samples.last?.t ?? 0))
            } else if args.contains("--classical") {
                var dopt = BallDetectorOptions()
                let radii = perFrame.values.map { $0.radiusPx }.sorted()
                if !radii.isEmpty { dopt.expectedDiameterPx = flag("--ball-px").flatMap(Double.init) ?? 1.6 * radii[radii.count / 2] }
                // --classical still means "run BallDetector"; --no-coreml forces the old background-difference path.
                dopt.useCoreML = !args.contains("--no-coreml")
                if args.contains("--no-hybrid") { dopt.coreMLHybridCentroid = false }
                // Core ML throttles are rates in real time now, not frame counts: --coreml-rate 120 is every
                // frame on a 120 fps capture and every 2nd frame on a 240 fps one.
                dopt.timeScale = scale
                if let v = flag("--coreml-rate").flatMap(Double.init) { dopt.coreMLInferenceRateHz = v }
                if let v = flag("--coreml-sweep-rate").flatMap(Double.init) { dopt.coreMLGlobalSweepRateHz = v }
                if let v = flag("--coreml-widen").flatMap(Int.init) { dopt.coreMLStaleWidenCap = v }
                if let v = flag("--coreml-sweep-after").flatMap(Double.init) { dopt.coreMLGlobalSearchSecondsAfterLock = v }
                if args.contains("--no-motion-aim") { dopt.coreMLAimFromMotion = false }
                if args.contains("--no-motion-skip") { dopt.coreMLSkipWhenMotionAgrees = false }
                if args.contains("--no-still-sweep-gate") { dopt.coreMLSweepOnlyWhenMoving = false }
                if args.contains("--no-free-flight-trim") { dopt.trimAfterFreeFlight = false }
                if args.contains("--no-weak") { dopt.predictedWeakCandidates = false }
                if let c = flag("--coreml-confidence").flatMap(Float.init) { dopt.coreMLMinConfidence = c }
                let seed = Dictionary(uniqueKeysWithValues: perFrame.map { ($0.key, SIMD2($0.value.u, $0.value.v)) })
                let tDet = Date()
                let (dets, dstats) = try await BallDetector.runDetailed(url: clip, start: start, end: end, seed: seed, fps: run.probe.measuredFrameRate, options: dopt)
                print(String(format: "ball detector: %d detections in %.1f s (expected ball %.0f px), diameters %.0f–%.0f px, first frame %d (Vision first %d)",
                             dets.count, Date().timeIntervalSince(tDet), dopt.expectedDiameterPx, dets.map(\.diameterPx).min() ?? 0, dets.map(\.diameterPx).max() ?? 0,
                             dets.first?.frameIndex ?? -1, perFrame.keys.min() ?? -1))
                if dopt.useCoreML {
                    print(String(format: "detector: coreml %d frames, classical fallback %d frames, mean inference %.1f ms",
                                 dstats.coreMLFrames, dstats.classicalFallbackFrames, dstats.meanInferenceMilliseconds))
                    print(String(format: "  %d tiles over %d frames (%.2f tiles/frame) at %.1f ms/tile; %d frames aimed at a prediction or seed, %d swept whole-frame",
                                 dstats.coreMLTiles, dstats.coreMLFramesRun, dstats.meanTilesPerFrame, dstats.meanTileMilliseconds,
                                 dstats.coreMLAimedFrames, dstats.coreMLGlobalFrames))
                    print(String(format: "  one-tile frames (the steady state while the ball is tracked): %d at %.1f ms",
                                 dstats.coreMLSingleTileFrames, dstats.meanSingleTileMilliseconds))
                    if let why = dstats.coreMLUnavailableReason { print("  ! Core ML detector unavailable: \(why)") }
                } else {
                    print("detector: coreml 0 frames (--no-coreml), classical fallback \(dets.count) frames, mean inference 0.0 ms")
                }
                if args.contains("--dump") { for d in dets { print(String(format: "   f %d t %.4f u %.1f v %.1f d %.1f s %.2f %@%@", d.frameIndex, d.pts, d.u, d.v, d.diameterPx, d.score, d.source, d.edge ? " edge" : "")) } }
                let nT = dets.filter { $0.source == "template" }.count, nE = dets.filter(\.edge).count
                print("  sources: \(dets.count - nT) detected, \(nT) template, \(nE) edge-clipped")
                print(String(format: "  placement: %d blob chosen by a box, %d box centre (no blob inside), %d plain blob, %d weak descent; %d inflated boxes dropped",
                             dstats.hybridRefinedFrames, dstats.hybridBoxOnlyFrames, dstats.blobOnlyFrames, dstats.weakDescentFrames, dstats.suppressedInflatedBoxes))
                // A blob cut by the frame edge has its centroid pulled inward (an apex above the frame reads as a
                // flatter arc, so g fits low); the fit must not see those frames. --keep-edge puts them back.
                let keepEdge = args.contains("--keep-edge")
                samples = dets.filter { keepEdge || !$0.edge }.map { ImageSample(t: $0.pts / scale, uv: SIMD2($0.u, $0.v), diameterPx: $0.diameterPx) }
                if !keepEdge, nE > 0 { print("  dropped \(nE) edge-clipped sample(s) from the fit (--keep-edge keeps them)") }
                ballDets = dets
            }
            print(String(format: "window %.2f–%.2f s file time, time scale %.0f: %d tracks, %d ball samples, real span %.3f s, ball %.0f–%.0f px",
                         start, end, scale, run.tracks.count, samples.count, (samples.last?.t ?? 0) - (samples.first?.t ?? 0),
                         samples.map { $0.diameterPx ?? 0 }.min() ?? 0, samples.map { $0.diameterPx ?? 0 }.max() ?? 0))
            var ro = RimCalibrationOptions(); ro.rimDiameter = rimD
            var cal = try RimCalibrator.calibrate(boundaryPoints: rim.points.map { SIMD2($0[0], $0[1]) }, intrinsics: k, options: ro)
            print(String(format: "  rim-plane normal (camera frame, y down): (%.3f, %.3f, %.3f); a level camera would give (0, -1, 0)", cal.up.x, cal.up.y, cal.up.z))
            if let pitchDeg = flag("--level-pitch").flatMap(Double.init) {
                // Override the weakly determined rim normal with a level camera pitched up by pitchDeg (image vertical = world vertical).
                let t = Angle.radians(pitchDeg)
                let solved = cal.up
                cal.up = SIMD3(0, -cos(t), sin(t))
                print(String(format: "  using an assumed camera pitch of %.1f°: up = (0, %.3f, %.3f)", pitchDeg, cal.up.y, cal.up.z))
                // How far the traced ellipse's own normal is from that. A few degrees is the usual
                // weakness of a thin ellipse; more than ~8° means the trace is not the image of a
                // horizontal circle at this focal length — re-trace it rather than paper over it.
                let u = solved / (solved * solved).sum().squareRoot()
                let disagreement = Angle.degrees(acos(max(-1, min(1, (u * cal.up).sum()))))
                if disagreement > 8 {
                    print(String(format: "  warning: the rim trace's own plane normal is %.1f° from that assumption; the ellipse is not the image of a horizontal circle (bad trace, or wrong --hfov) — re-trace the rim", disagreement))
                }
            }
            let camDist = (cal.rimCenter.x * cal.rimCenter.x + cal.rimCenter.z * cal.rimCenter.z).squareRoot()
            print(String(format: "rim calibration: camera→rim %.2f m (|rimCenter| %.2f m), rim centre cam (%.2f, %.2f, %.2f), warnings %@",
                         camDist, (cal.rimCenter * cal.rimCenter).sum().squareRoot(), cal.rimCenter.x, cal.rimCenter.y, cal.rimCenter.z, cal.warnings.description))
            if args.contains("--azimuth-scan") {
                var fo = TrajectoryFitOptions(); fo.fixedG = Court.g; fo.minimumSamples = 5; fo.minimumSpan = 0.05
                let flight = samples.filter { $0.t >= samples[0].t && $0.t <= samples[0].t + 1.3 }
                print("  azimuth scan (fixed-g fit over the first 1.3 s of samples):")
                for deg in stride(from: 0, to: 360, by: 6) {
                    let fr = ShotPlaneSolver.frame(calibration: cal, azimuth: Angle.radians(Double(deg)))
                    guard let pl = ShotPlaneSolver.project(flight, intrinsics: k, frame: fr), pl.count >= 8 else { print(String(format: "   az %3d°: projection failed", deg)); continue }
                    let rms = (try? TrajectoryFitter.fit(pl, anchorTime: pl[pl.count / 2].t, options: fo).rms) ?? .nan
                    print(String(format: "   az %3d°  view %5.1f°  first sample x %6.2f y %5.2f m   fixed-g rms %.3f m   n %d", deg, Angle.degrees(fr.viewAngle), pl[0].x, pl[0].y, rms, pl.count))
                }
            }
            // Pose stage (--pose): Vision body pose over the window gives the release instant that made the Python
            // pipeline accurate, plus the camera-side 2-D joint angles. Release is reported in file time and handed
            // to the window detector in real time (samples carry t = pts / scale).
            var poseReleaseTimeReal: Double? = nil
            var poseAngles: PoseAngles2D? = nil
            var poseNote: String? = nil
            if args.contains("--pose") {
                // An edge-clipped blob measures only the visible part of the ball, so it under-reads the diameter;
                // the release rule is a distance in diameters, so the size must come from the unclipped frames.
                let clean = ballDets.filter { !$0.edge }
                let diameters = (clean.count >= 8 ? clean : ballDets).map(\.diameterPx).sorted()
                let ballPx = diameters.isEmpty ? 0 : diameters[diameters.count / 2]
                let seed = ballDets.map { (pts: $0.pts, uv: SIMD2($0.u, $0.v)) }
                let tPose = Date()
                let poses = try await PoseTracker.run(url: clip, start: start, end: end, everyNthFrame: 1,
                                                      ballSeed: seed, fps: run.probe.measuredFrameRate)
                print(String(format: "pose: %d frames carry a body (%.0f s, Vision DetectHumanBodyPoseRequest), ball diameter %.0f px over %d detections",
                             poses.count, Date().timeIntervalSince(tPose), ballPx, ballDets.count))
                if args.contains("--pose-dump") {
                    let sortedPoses = poses.sorted { $0.pts < $1.pts }
                    let det = ballDets.filter { ReleaseFromPose.evidenceSources.contains($0.source) }.sorted { $0.pts < $1.pts }
                    print("  frame   pts      ball u,v      nearer wrist u,v (conf)  dist/D  above  Δv over next 3")
                    for (n, d) in det.enumerated() {
                        let pose = ReleaseFromPose.nearestPose(sortedPoses, pts: d.pts, tolerance: 0.05)
                        var best: (Double, JointSample)? = nil
                        for w in ["l_wrist", "r_wrist"] {
                            guard let j = pose?.joints[w], j.confidence >= ReleaseFromPose.wristConfidence else { continue }
                            let dist = ((d.u - j.u) * (d.u - j.u) + (d.v - j.v) * (d.v - j.v)).squareRoot()
                            if best == nil || dist < best!.0 { best = (dist, j) }
                        }
                        let nxt = det[(n + 1)..<min(n + 4, det.count)].map(\.v)
                        print(String(format: "  %5d %8.3f  %6.1f,%6.1f   %@  %5.2f  %@  %@", d.frameIndex, d.pts, d.u, d.v,
                                     best.map { String(format: "%6.1f,%6.1f (%.2f)", $0.1.u, $0.1.v, $0.1.confidence) } ?? "      —,—       (—) ",
                                     (best?.0 ?? .nan) / max(ballPx, 1e-9),
                                     best.map { d.v <= $0.1.v ? "yes" : "no " } ?? "?  ",
                                     nxt.count >= 2 ? String(format: "%+.1f px", (nxt.last ?? d.v) - d.v) : "—"))
                    }
                }
                if let r = ReleaseFromPose.estimate(detections: ballDets, poses: poses, ballDiameterPx: ballPx) {
                    poseReleaseTimeReal = r.pts / scale
                    print(String(format: "pose: estimated release at file time %.3f s (frame %d, real t %.4f s)", r.pts, r.frameIndex, r.pts / scale))
                    poseAngles = PoseMetrics2D.angles(poses: poses, releasePTS: r.pts, extensionHalfWindowFrames: 6,
                                                      kneeLookbackPTS: 0.6 * scale)   // 0.6 s real → file seconds
                } else {
                    poseNote = "no frame satisfied the release rule (ball ≥ 1 diameter from the nearer wrist, above it, and rising)"
                    print("pose: \(poseNote!)")
                }
            }
            // 2-D angles are camera-plane angles: the brief calls them valid only for a near-side view, so they are
            // always printed with the analyzer's own view classification.
            func printPoseAngles(viewAngleDegrees: Double?, viewClass: String?) {
                guard args.contains("--pose"), let p = poseAngles else { return }
                func deg(_ x: Double?) -> String { x.map { String(format: "%.0f°", $0) } ?? "nil" }
                print("pose: elbow release \(deg(p.elbowAtReleaseDegrees)), elbow max \(deg(p.elbowMaxNearReleaseDegrees)), knee min \(deg(p.kneeMinimumDegrees))")
                if let v = viewAngleDegrees, let cls = viewClass {
                    print(String(format: "  warning: 2-D pose angles are the %@-side limb projected into the image; valid only for a near-side view — this shot is %.0f° from side (%@)", p.side, v, cls))
                } else {
                    print("  warning: 2-D pose angles are the \(p.side)-side limb projected into the image; valid only for a near-side view — the view angle is unknown (the geometry pipeline did not produce one)")
                }
            }
            do {
                var ao = AnalysisOptions()
                if let L = flag("--known-distance").flatMap(Double.init) { ao.knownReleaseDistance = L }
                if args.contains("--fixed-g-azimuth") { ao.azimuthByFixedGravity = true }
                if let az = flag("--fixed-azimuth").flatMap(Double.init) { ao.fixedAzimuth = Angle.radians(az) }   // degrees at the boundary; view angle 0 = side-on
                if let rt = flag("--release-time").flatMap(Double.init) { ao.windowOptions.releaseTimeOverride = rt }
                else if let rt = poseReleaseTimeReal { ao.windowOptions.releaseTimeOverride = rt }
                if let fr = flag("--flight-range") {
                    let parts = fr.split(separator: ",").compactMap { Double($0) }
                    if parts.count == 2, parts[0] < parts[1] { ao.azimuthTimeRange = parts[0]...parts[1] }
                }
                if let v = flag("--local-factor").flatMap(Double.init) { ao.windowOptions.localFactor = v }
                if let v = flag("--local-floor").flatMap(Double.init) { ao.windowOptions.localFloor = v }
                if args.contains("--window-debug") { ao.windowOptions.debugWindows = true }
                let a = try ShotAnalyzer.analyze(track: samples, calibration: cal, intrinsics: k, options: ao)
                let m = a.metrics, c = a.confidence
                print(String(format: "  g_fit %.2f (%.1f%%) %@   rms %.2f px   inliers %d/%d   flight span %.2f s   view %.1f° (%@)   azimuth σ %.1f°",
                             c.gFit, c.gError * 100, c.gravityVerdict.rawValue, c.rmsPx, c.nInliers, c.nDetections, c.flightSpan, Angle.degrees(c.viewAngle), c.viewClass.rawValue, Angle.degrees(c.azimuthSigma)))
                print(String(format: "  release θ %@  h %@  v %@  L %@   entry %@   apex %@   depth past front rim %@   %@",
                             m.release.map { String(format: "%.1f°", $0.angleDegrees) } ?? "nil (\(m.releaseUnavailableReason ?? "?"))",
                             m.release.map { String(format: "%.2f m", $0.height) } ?? "—", m.release.map { String(format: "%.2f m/s", $0.speed) } ?? "—",
                             m.release.map { String(format: "%.2f m", $0.distance) } ?? "—",
                             m.entryAngleDegrees.map { String(format: "%.1f°", $0) } ?? "nil (\(m.entryAngleUnavailableReason ?? "?"))",
                             m.apexHeight.map { String(format: "%.2f m", $0) } ?? "—", m.depthPastFrontRim.map { String(format: "%.2f m", $0) } ?? "—",
                             m.depthClass?.rawValue ?? ""))
                for w in c.warnings { print("  warning: \(w)") }
                for nt in a.window.notes { print("  window: \(nt)") }
                printPoseAngles(viewAngleDegrees: Angle.degrees(c.viewAngle), viewClass: c.viewClass.rawValue)
                if let ov = flag("--overlay") {
                    try await writeOverlay(clip: clip, samples: samples, rim: rim.points, analysis: a, intrinsics: k, scale: scale, out: URL(fileURLWithPath: ov))
                }
                if let rv = flag("--review") {
                    let title = String(format: "%@  g_fit %.2f (%.1f%%)  release θ %@ h %@  entry %@  depth %@", clip.lastPathComponent, c.gFit, c.gError * 100,
                                       m.release.map { String(format: "%.1f°", $0.angleDegrees) } ?? "nil", m.release.map { String(format: "%.2f m", $0.height) } ?? "—",
                                       m.entryAngleDegrees.map { String(format: "%.1f°", $0) } ?? "nil", m.depthPastFrontRim.map { String(format: "%.2f m", $0) } ?? "—")
                    let pr = OverlayVideo.Params(samples: samples, analysis: a, rim: rim.points.map { SIMD2($0[0], $0[1]) }, intrinsics: k, scale: scale, title: title)
                    let n = try await OverlayVideo.write(clip: clip, start: start, end: end, params: pr, to: URL(fileURLWithPath: rv))
                    print("  review video written: \(rv) (\(n) frames; step with arrow keys in QuickTime Player)")
                }
            } catch {
                print("  pipeline: \(error)")
                printPoseAngles(viewAngleDegrees: nil, viewClass: nil)
                if let ov = flag("--overlay") { try? await writeOverlay(clip: clip, samples: samples, rim: rim.points, analysis: nil, intrinsics: k, scale: scale, out: URL(fileURLWithPath: ov)) }
            }
            case "body": try await BodyCommand.run(clip: clip, args: args)
            case "bodyexport": try await BodyExportCommand.run(clip: clip, args: args)
            case "formclip": try await FormClipCommand.run(clip: clip, args: args)
            case "form": try FormCommand.run(out: clip, args: args)
            case "spin": try await SpinCommand.run(clip: clip, args: args)
        case "feetbench":
                // The foot model's cost on *this* machine, separated from the decode and from
                // Vision. Phase 1 of the benchmark the phone has to repeat: same code, same crop
                // size, `computeUnits = .all`, so the two numbers are comparable.
                guard let t = flag("--time").flatMap(Double.init) else {
                    print("usage: TrajectoryProbe feetbench <clip.mov> --time <file s> [--n 200] [--units all|cpu|cpuAndGPU|cpuAndNeuralEngine]")
                    exit(1)
                }
                let n = flag("--n").flatMap(Int.init) ?? 200
                let units: MLComputeUnits = {
                    switch flag("--units") ?? "all" {
                    case "cpu": return .cpuOnly
                    case "cpuAndGPU": return .cpuAndGPU
                    case "cpuAndNeuralEngine": return .cpuAndNeuralEngine
                    default: return .all
                    }
                }()
                let tLoad = Date()
                let detector = try FootPoseDetector(computeUnits: units)
                let loadSeconds = Date().timeIntervalSince(tLoad)
                // One real frame, and a person box that is the whole frame's middle third — the
                // benchmark is about the model, so the box only has to be the right *size*.
                let asset = AVURLAsset(url: clip)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    print("error: no video track"); exit(1)
                }
                let natural = try await track.load(.naturalSize)
                let size = CGSize(width: abs(natural.width), height: abs(natural.height))
                // A blank frame of the clip's real size, not a decoded one: convolution cost does
                // not depend on the pixels, and this keeps the decode out of the benchmark entirely.
                // `--time` still picks the clip so the frame size is the one that will be used.
                var made: CVPixelBuffer?
                guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary,
                                          &made) == kCVReturnSuccess, let buffer = made else {
                    print("error: could not make a \(Int(size.width))x\(Int(size.height)) buffer"); exit(1)
                }
                let crop = FootPoseDetector.crop(minU: Double(size.width) / 3, minV: Double(size.height) / 4,
                                                maxU: 2 * Double(size.width) / 3, maxV: 3 * Double(size.height) / 4)
                for _ in 0..<10 { _ = try detector.run(buffer, imageSize: size, crop: crop) }   // warm up
                var best = Double.greatestFiniteMagnitude, worst = 0.0
                let t0 = Date()
                for _ in 0..<n {
                    let r = try detector.run(buffer, imageSize: size, crop: crop)
                    best = min(best, r.seconds); worst = max(worst, r.seconds)
                }
                let wall = Date().timeIntervalSince(t0)
                print(String(format: "feet bench: %@ · %d predictions on a %.0f x %.0f person box → 192x256",
                             flag("--units") ?? "all", n, crop.width, crop.height))
                print(String(format: "  %.2f ms/frame mean (best %.2f, worst %.2f) · model load + compile %.2f s",
                             1000 * wall / Double(n), 1000 * best, 1000 * worst, loadSeconds))
                print("  the crop render (CIContext) is inside these numbers, as it is in the tracker")
        case "frame":
                guard let t = flag("--time").flatMap(Double.init), let out = flag("--out") else { usage() }
                let pts = try await FrameExport.writePNG(url: clip, time: t, to: URL(fileURLWithPath: out))
                print(String(format: "wrote %@ (frame at PTS %.4f s)", out, pts))
            default:
                usage()
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }

  }
}
