import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreGraphics
import CoreText
import ShotVideo
import ShotGeometry

/// `TrajectoryProbe review <clip.mov> --cache <dir/variant> --out review.mov [--scores card.json] [--labels labels.json]
///                         [--rim-found rim_found.json] [--only wid,wid] [--limit N] [--slow-x1 3]`
///
/// One movie for a whole clip, window after window, so a person can step through it (arrow keys in QuickTime
/// Player) and check that the ring is on the ball on every frame. Each window opens with a title card (its
/// id, hand label, bench verdict, sample count, time scale) and then plays every source frame of the window
/// with: the rim trace (green dots), every detection the tracker returned up to that frame as a trail
/// coloured by the pass that placed it (cyan forward, green backward, magenta parabola walk, yellow template,
/// red edge-clipped), the current frame's detection as a ring (white when the fit used it, cyan when it was
/// tracked but outside the flight window, red when edge-clipped and left out, yellow for a template fill),
/// the fitted parabola in orange with the release (red double ring) and flight end (orange ring), and a
/// dashed orange ring where the fit predicts the ball on a frame with no detection. Windows that are ×1
/// content (the export's normal-speed stretches) are written `--slow-x1` times per frame so they play at a
/// third of the speed and can be stepped like the rest.
///
/// The cache directory is one written by `session --dump-windows` (`--track-variants` puts each variant in
/// its own subdirectory, with the `.diag.json` files this needs). `--scores` is a `ShotBench run --json`
/// scorecard for the same cache, and is what the verdict line shows; without it the verdict is recomputed
/// here with the per-shot fixed-gravity azimuth and the cache's own rim trace. `--rim-found` replaces the
/// cache's rim trace with the auto-found one, which is what the `autoFound*` bench variants use.
enum ReviewCommand {
    struct Cache: Decodable {
        struct Sample: Decodable { var t: Double; var u: Double; var v: Double; var diameterPx: Double? }
        var windowID: String; var clip: String; var spot: String?
        var samples: [Sample]; var rimBoundary: [[Double]]; var rimDiameterUsed: Double
        var width: Int; var height: Int; var hfovDegrees: Double; var timeScale: Double; var measuredFPS: Double
        var fileStart: Double; var fileEnd: Double; var releaseTimeOverride: Double?
    }
    struct Diag: Decodable {
        struct Det: Decodable { var frameIndex: Int; var pts: Double; var u: Double; var v: Double; var diameterPx: Double; var edge: Bool; var source: String; var origin: String? }
        var windowID: String; var variant: String?; var timeScale: Double
        var expectedDiameterPx: Double; var seeds: [[Double]]; var detections: [Det]; var note: String?
    }
    struct ManifestEntry: Decodable { var windowID: String; var file: String; var clip: String; var fileStart: Double }
    struct RimFile: Decodable { var points: [[Double]] }
    struct Verdict { var accepted: Bool; var text: String }

    static func run(clip: URL, args: [String]) async throws {
        func flag(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let cacheDir = flag("--cache"), let outPath = flag("--out") else {
            print("usage: TrajectoryProbe review <clip.mov> --cache <dir/variant> --out review.mov [--scores card.json] [--labels labels.json] [--rim-found rim.json] [--only wid,wid] [--limit N] [--slow-x1 3]")
            exit(2)
        }
        let cache = URL(fileURLWithPath: cacheDir)
        let clipName = clip.lastPathComponent
        let manifest = try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: cache.appendingPathComponent("manifest.json")))
        var entries = manifest.filter { $0.clip == clipName }.sorted { $0.fileStart < $1.fileStart }
        if let only = flag("--only") { let set = Set(only.split(separator: ",").map(String.init)); entries = entries.filter { set.contains($0.windowID) } }
        if let n = flag("--limit").flatMap(Int.init) { entries = Array(entries.prefix(n)) }
        guard !entries.isEmpty else { print("no windows for \(clipName) in \(cacheDir)"); exit(1) }
        let slowX1 = max(1, flag("--slow-x1").flatMap(Int.init) ?? 3)

        // Verdicts from the scorecard, if given (gError may be encoded as "inf"/"nan" strings).
        var verdicts: [String: Verdict] = [:]
        if let sp = flag("--scores"), let data = try? Data(contentsOf: URL(fileURLWithPath: sp)),
           let card = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for w in card["windows"] as? [[String: Any]] ?? [] {
                guard let wid = w["windowID"] as? String else { continue }
                let acc = w["accepted"] as? Bool ?? false
                var text: String
                if acc {
                    text = "ACCEPTED"
                    if let g = w["gError"] as? Double { text += String(format: "  g %+.1f%%", g * 100) }
                    if let h = w["releaseHeight"] as? Double, let v = w["releaseSpeed"] as? Double, let a = w["releaseAngleDegrees"] as? Double {
                        text += String(format: "  release %.2f m, %.1f m/s, %.0f°", h, v, a)
                    } else { text += "  (release not observed)" }
                } else {
                    text = "REFUSED: " + ((w["refusalReason"] as? String) ?? "?")
                }
                verdicts[wid] = Verdict(accepted: acc, text: text)
            }
            for s in card["skipped"] as? [[String: Any]] ?? [] {
                if let wid = s["windowID"] as? String { verdicts[wid] = Verdict(accepted: false, text: "SKIPPED: " + ((s["reason"] as? String) ?? "")) }
            }
        }
        var labels: [String: (label: String, reason: String)] = [:]
        let labelsPath = flag("--labels") ?? (FileManager.default.currentDirectoryPath + "/docs/footage-2026-09-13/window_labels.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: labelsPath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for e in obj["labels"] as? [[String: Any]] ?? [] {
                if let wid = e["windowID"] as? String { labels[wid] = ((e["label"] as? String) ?? "?", (e["reason"] as? String) ?? "") }
            }
        }
        var foundRim: [SIMD2<Double>]? = nil
        if let rp = flag("--rim-found") {
            foundRim = try JSONDecoder().decode(RimFile.self, from: Data(contentsOf: URL(fileURLWithPath: rp))).points.map { SIMD2($0[0], $0[1]) }
        }

        // One writer for the whole clip.
        let out = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: out)
        let fps: Int32 = 30
        var writer: AVAssetWriter? = nil
        var input: AVAssetWriterInput? = nil
        var adaptor: AVAssetWriterInputPixelBufferAdaptor? = nil
        var frameCount = 0
        let ci = CIContext()
        func ensureWriter(width W: Int, height H: Int) throws {
            guard writer == nil else { return }
            let w = try AVAssetWriter(outputURL: out, fileType: .mov)
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000]])
            inp.expectsMediaDataInRealTime = false
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
            w.add(inp)
            guard w.startWriting() else { throw w.error ?? VideoReaderError.cannotStartReading("writer") }
            w.startSession(atSourceTime: .zero)
            writer = w; input = inp; adaptor = ad
        }
        func append(_ pb: CVPixelBuffer, times: Int) async throws {
            guard let inp = input, let ad = adaptor else { return }
            for _ in 0..<times {
                while !inp.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                guard ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frameCount), timescale: fps)) else {
                    throw writer?.error ?? VideoReaderError.cannotStartReading("append")
                }
                frameCount += 1
            }
        }
        func blank(width W: Int, height H: Int) -> CVPixelBuffer? {
            guard let pool = adaptor?.pixelBufferPool else { return nil }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            return pb
        }
        func text(_ ctx: CGContext, _ line: String, x: CGFloat, y: CGFloat, size: CGFloat, H: Int, colour: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)) {
            // `ctx` is expected in top-left orientation; flip for CoreText and back.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
            let attrs: [CFString: Any] = [kCTFontAttributeName: CTFontCreateWithName("Menlo" as CFString, size, nil), kCTForegroundColorAttributeName: colour]
            let str = CFAttributedStringCreate(nil, line as CFString, attrs as CFDictionary)!
            ctx.textPosition = CGPoint(x: x, y: CGFloat(H) - y)
            CTLineDraw(CTLineCreateWithAttributedString(str), ctx)
            ctx.restoreGState()
        }
        func context(for pb: CVPixelBuffer) -> CGContext? {
            let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb)
            guard let c = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: W, height: H, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            c.translateBy(x: 0, y: CGFloat(H)); c.scaleBy(x: 1, y: -1)      // top-left origin, like the detections
            return c
        }
        let stageColour: [String: CGColor] = [
            "forward": CGColor(red: 0.0, green: 0.82, blue: 1.0, alpha: 0.9),
            "back": CGColor(red: 0.35, green: 1.0, blue: 0.35, alpha: 0.9),
            "extend": CGColor(red: 1.0, green: 0.35, blue: 1.0, alpha: 0.9),
            "template": CGColor(red: 1.0, green: 0.86, blue: 0.0, alpha: 0.9),
        ]
        let decoder = JSONDecoder()
        let t0 = Date()
        var windowsDone = 0
        for e in entries {
            let cw = try decoder.decode(Cache.self, from: Data(contentsOf: cache.appendingPathComponent(e.file)))
            let diagURL = cache.appendingPathComponent(e.file.replacingOccurrences(of: ".json", with: ".diag.json"))
            let diag = (try? decoder.decode(Diag.self, from: Data(contentsOf: diagURL)))
            let dets = (diag?.detections ?? cw.samples.map { Diag.Det(frameIndex: 0, pts: $0.t * cw.timeScale, u: $0.u, v: $0.v, diameterPx: $0.diameterPx ?? 0, edge: false, source: "detected", origin: nil) })
                .sorted { $0.pts < $1.pts }
            let scale = cw.timeScale
            // The analysis, for the fitted curve and which samples the fit used.
            let intrinsics = CameraIntrinsics(width: cw.width, height: cw.height, horizontalFOVDegrees: cw.hfovDegrees)
            var ro = RimCalibrationOptions(); ro.rimDiameter = cw.rimDiameterUsed
            let rimPoints = foundRim ?? cw.rimBoundary.map { SIMD2($0[0], $0[1]) }
            let calibration = try? RimCalibrator.calibrate(boundaryPoints: rimPoints, intrinsics: intrinsics, options: ro)
            let samples = cw.samples.map { ImageSample(t: $0.t, uv: SIMD2($0.u, $0.v), diameterPx: $0.diameterPx) }
            var analysis: ShotAnalysis? = nil
            var localVerdict = Verdict(accepted: false, text: "REFUSED: no analysis")
            if let cal = calibration {
                var ao = AnalysisOptions(); ao.azimuthByFixedGravity = true
                if let rt = cw.releaseTimeOverride { ao.windowOptions.releaseTimeOverride = rt }
                do {
                    let a = try ShotAnalyzer.analyze(track: samples, calibration: cal, intrinsics: intrinsics, options: ao)
                    analysis = a
                    let ev = ShotAcceptance.evaluate(a)
                    localVerdict = Verdict(accepted: ev.isAccepted, text: ev.isAccepted ? String(format: "ACCEPTED  g %+.1f%%", a.confidence.gError * 100) : "REFUSED: " + (ev.reason ?? ""))
                } catch { localVerdict = Verdict(accepted: false, text: "REFUSED: \(error)") }
            }
            let verdict = verdicts[cw.windowID] ?? localVerdict
            // Fit curve and markers.
            var curve: [SIMD2<Double>] = []
            var usedTimes = Set<Int>()          // file-time ms of samples the fit used
            var releaseUV: SIMD2<Double>? = nil, endUV: SIMD2<Double>? = nil
            var flightRange: ClosedRange<Double>? = nil
            if let a = analysis {
                let ri = a.flightIndices.first ?? 0, ei = a.flightIndices.last ?? 0
                for i in a.flightIndices where i < samples.count { usedTimes.insert(Int((samples[i].t * scale * 1000).rounded())) }
                if ri < samples.count { releaseUV = samples[ri].uv }
                if ei < samples.count { endUV = samples[ei].uv }
                let tr = a.window.releaseTime, te = a.planeSamples[min(ei, max(0, a.planeSamples.count - 1))].t
                flightRange = tr...max(tr, te)
                var t = tr
                while t <= te + 0.05 {
                    let q = a.fit.position(at: t); let P = a.azimuth.frame.point3D(x: q.x, y: q.y)
                    if P.z > 0.1 { curve.append(intrinsics.pixel(fromNormalized: SIMD2(P.x / P.z, P.y / P.z))) }
                    t += 0.01
                }
            }
            let label = labels[cw.windowID]
            let repeatTimes = scale == 1 ? slowX1 : 1
            let clean = dets.filter { !$0.edge }
            let span = clean.count > 1 ? (clean.last!.pts - clean.first!.pts) / scale : 0
            let titleLines = [
                "\(cw.windowID)   \(diag?.variant ?? "")   arrival at \(String(format: "%.1f", e.fileStart)) s of \(clipName)",
                "hand label: \(label?.label ?? "none")" + (label.map { $0.reason.isEmpty ? "" : " — " + String($0.reason.prefix(110)) } ?? ""),
                verdict.text,
                String(format: "%d detections (%d clean) over %.2f s real   time scale ×%.0f%@", dets.count, clean.count, span, scale, scale == 1 ? "  (normal-speed content, played at 1/\(slowX1) speed)" : ""),
                String((diag?.note ?? "").prefix(120)),
            ]
            // Title card.
            let reader = VideoReader(url: clip)
            let range = CMTimeRange(start: CMTime(seconds: cw.fileStart, preferredTimescale: 600), end: CMTime(seconds: cw.fileEnd, preferredTimescale: 600))
            var titleWritten = false
            var frameInWindow = 0
            try await reader.forEachFrame(timeRange: range) { f in
                guard let pb = f.pixelBuffer else { return true }
                let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb)
                try ensureWriter(width: W, height: H)
                if !titleWritten, let card = blank(width: W, height: H) {
                    CVPixelBufferLockBaseAddress(card, [])
                    if let c = context(for: card) {
                        c.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
                        text(c, "shot review", x: 60, y: 120, size: 44, H: H, colour: CGColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1))
                        for (i, line) in titleLines.enumerated() where !line.isEmpty {
                            let colour = i == 2 ? (verdict.accepted ? CGColor(red: 0.4, green: 1, blue: 0.4, alpha: 1) : CGColor(red: 1, green: 0.45, blue: 0.45, alpha: 1))
                                               : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                            text(c, line, x: 60, y: CGFloat(200 + 56 * i), size: 30, H: H, colour: colour)
                        }
                        text(c, "trail colours: cyan forward pass · green backward pass · magenta parabola walk · yellow template · red edge-clipped", x: 60, y: CGFloat(H) - 120, size: 24, H: H)
                        text(c, "ring: white = used by the fit · cyan = tracked, outside the flight window · red = clipped, left out · dashed orange = fit's prediction, no detection", x: 60, y: CGFloat(H) - 80, size: 24, H: H)
                    }
                    CVPixelBufferUnlockBaseAddress(card, [])
                    try await append(card, times: Int(fps) * 3 / 2)
                    titleWritten = true
                }
                guard let ad = adaptor, let pool = ad.pixelBufferPool else { return false }
                var outPB: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB)
                guard let opb = outPB else { return false }
                ci.render(CIImage(cvPixelBuffer: pb), to: opb)
                CVPixelBufferLockBaseAddress(opb, [])
                if let ctx = context(for: opb) {
                    let tFile = f.pts
                    let realT = tFile / scale
                    // rim
                    ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 0.9))
                    for r in rimPoints { ctx.fillEllipse(in: CGRect(x: r.x - 2, y: r.y - 2, width: 4, height: 4)) }
                    // fitted curve
                    if curve.count > 1 {
                        ctx.setStrokeColor(CGColor(red: 1, green: 0.55, blue: 0, alpha: 0.6)); ctx.setLineWidth(3)
                        ctx.beginPath(); ctx.move(to: CGPoint(x: curve[0].x, y: curve[0].y))
                        for c in curve.dropFirst() { ctx.addLine(to: CGPoint(x: c.x, y: c.y)) }
                        ctx.strokePath()
                    }
                    // trail of detections so far, and the current one
                    var current: Diag.Det? = nil
                    let halfFrame = 0.5 / max(1, cw.measuredFPS)
                    for d in dets where d.pts <= tFile + halfFrame {
                        let stage = d.source == "template" ? "template" : (d.origin ?? "forward").split(separator: ".").first.map(String.init) ?? "forward"
                        var colour = stageColour[stage] ?? CGColor(red: 1, green: 1, blue: 1, alpha: 0.9)
                        if d.edge { colour = CGColor(red: 1, green: 0.25, blue: 0.25, alpha: 0.9) }
                        ctx.setFillColor(colour)
                        ctx.fillEllipse(in: CGRect(x: d.u - 3, y: d.v - 3, width: 6, height: 6))
                        if abs(d.pts - tFile) < halfFrame { current = d }
                    }
                    var status = "no detection on this frame"
                    if let d = current {
                        let r = max(6, d.diameterPx / 2)
                        let key = Int((d.pts * 1000).rounded())
                        let used = usedTimes.contains(key)
                        let ring: CGColor
                        if d.source == "template" { ring = stageColour["template"]!; status = "template fill" }
                        else if d.edge { ring = CGColor(red: 1, green: 0.25, blue: 0.25, alpha: 1); status = "detected but clipped by the frame edge: left out of the fit" }
                        else if used { ring = CGColor(red: 1, green: 1, blue: 1, alpha: 1); status = "detected, used by the fit" }
                        else { ring = CGColor(red: 0, green: 0.82, blue: 1, alpha: 1); status = "detected, outside the flight window" }
                        if let o = d.origin { status += "   [\(o)]" }
                        ctx.setStrokeColor(ring); ctx.setLineWidth(4)
                        ctx.strokeEllipse(in: CGRect(x: d.u - r, y: d.v - r, width: 2 * r, height: 2 * r))
                    } else if let fr = flightRange, fr.contains(realT), let a = analysis {
                        let q = a.fit.position(at: realT); let P = a.azimuth.frame.point3D(x: q.x, y: q.y)
                        if P.z > 0.1 {
                            let uv = intrinsics.pixel(fromNormalized: SIMD2(P.x / P.z, P.y / P.z))
                            ctx.setStrokeColor(CGColor(red: 1, green: 0.55, blue: 0, alpha: 1)); ctx.setLineWidth(3); ctx.setLineDash(phase: 0, lengths: [6, 6])
                            ctx.strokeEllipse(in: CGRect(x: uv.x - 20, y: uv.y - 20, width: 40, height: 40)); ctx.setLineDash(phase: 0, lengths: [])
                            status = "no detection: dashed ring is where the fit predicts the ball"
                        }
                    }
                    if let r = releaseUV {
                        ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.setLineWidth(3)
                        ctx.strokeEllipse(in: CGRect(x: r.x - 16, y: r.y - 16, width: 32, height: 32))
                        ctx.strokeEllipse(in: CGRect(x: r.x - 22, y: r.y - 22, width: 44, height: 44))
                    }
                    if let e2 = endUV {
                        ctx.setStrokeColor(CGColor(red: 1, green: 0.6, blue: 0, alpha: 1)); ctx.setLineWidth(3)
                        ctx.strokeEllipse(in: CGRect(x: e2.x - 16, y: e2.y - 16, width: 32, height: 32))
                    }
                    // text box
                    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.62)); ctx.fill(CGRect(x: 10, y: 10, width: 1180, height: 100))
                    text(ctx, "\(cw.windowID)   \(label.map { "label: " + $0.label } ?? "")   \(verdict.text.prefix(80))", x: 18, y: 38, size: 22, H: H,
                         colour: verdict.accepted ? CGColor(red: 0.5, green: 1, blue: 0.5, alpha: 1) : CGColor(red: 1, green: 0.55, blue: 0.55, alpha: 1))
                    text(ctx, String(format: "frame %d   file %.3f s   real %.3f s (×%.0f)   %@", frameInWindow, tFile, realT, scale, status), x: 18, y: 66, size: 22, H: H)
                    text(ctx, "trail: cyan forward · green backward · magenta parabola · yellow template · red clipped     ring: white used · cyan not in window · red clipped · dashed = predicted", x: 18, y: 94, size: 18, H: H,
                         colour: CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
                }
                CVPixelBufferUnlockBaseAddress(opb, [])
                try await append(opb, times: repeatTimes)
                frameInWindow += 1
                return true
            }
            windowsDone += 1
            FileHandle.standardError.write(String(format: "  %d/%d windows, %d frames written, %.0f s\r", windowsDone, entries.count, frameCount, Date().timeIntervalSince(t0)).data(using: .utf8)!)
        }
        input?.markAsFinished()
        if let w = writer { await w.finishWriting(); if let err = w.error { throw err } }
        print(String(format: "\nwrote %@: %d windows, %d frames (%.1f min at %d fps) in %.0f s", out.path, windowsDone, frameCount, Double(frameCount) / Double(fps) / 60, fps, Date().timeIntervalSince(t0)))
    }
}
