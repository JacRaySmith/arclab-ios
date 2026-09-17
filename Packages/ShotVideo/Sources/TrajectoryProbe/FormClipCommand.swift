import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import ShotVideo
import ShotGeometry
import simd

/// `TrajectoryProbe formclip <clip> [...]` — the form-clip path end to end, on the desktop.
///
/// A form clip is the close-up the filming guide asks for: 3–4 m away, side-on, the whole shooter,
/// no rim. So nothing here may use a rim calibration or a ball flight: the shots are found from the
/// wrist's rise-and-release pattern (`FormClipScanner`) and the release instant comes from the ball
/// leaving the hand where the ball can still be seen, and from the wrist's own apex where it cannot.
///
/// The command exists to *measure* those two claims against footage where the truth is known — a
/// 9 m clip whose rim **is** in frame, so the ball-based release from the session pipeline is the
/// reference — and to simulate the close-up by cropping that footage to the shooter.
enum FormClipCommand {

    static func run(clip: URL, args: [String]) async throws {
        func flag(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("--help") {
            print("""
            usage: TrajectoryProbe formclip <clip.mov> [--start s] [--end s] [--time-scale N]
                     scan:     [--rate Hz] [--series out.json] [--use-series in.json] [--render-scale f]
                               [--rise spans] [--apex spans] [--hold s] [--quiet fraction] [--spacing s] [--require-set]
                     release:  [--body] [--limit N] [--every N] [--hfov D] [--height m] [--no-ball]
                               [--truth t1,t2,… | --truth-file f.txt]
                     close-up: [--crop 3.0] [--crop-out dir] [--crop-windows 3]
            """)
            return
        }
        let scale = flag("--time-scale").flatMap(Double.init) ?? 1
        var options = FormClipScanOptions()
        options.timeScale = scale
        if let s = flag("--start").flatMap(Double.init) { options.startTime = s }
        if let e = flag("--end").flatMap(Double.init) { options.endTime = e }
        if let r = flag("--rate").flatMap(Double.init) { options.sampleRateHz = r }
        if let r = flag("--render-scale").flatMap(Double.init) { options.renderScale = r }
        if let r = flag("--rise").flatMap(Double.init) { options.minimumRiseTorsoSpans = r }
        if let r = flag("--spacing").flatMap(Double.init) { options.minimumShotSpacingSeconds = r }
        if let r = flag("--apex").flatMap(Double.init) { options.minimumApexAboveShoulderSpans = r }
        if let r = flag("--hold").flatMap(Double.init) { options.minimumExtensionSeconds = r }
        if let r = flag("--quiet").flatMap(Double.init) { options.quietRateFraction = r }
        if args.contains("--require-set") { options.requireSetPlateau = true }

        let probe = try await VideoReader(url: clip).quickProbe(maxFrames: 60)
        let fps = probe.measuredFrameRate

        // ---- the scan ----------------------------------------------------------------------------
        struct SeriesFile: Codable { var samples: [FormClipSample]; var timeScale: Double; var fps: Double }
        var samples: [FormClipSample]
        var result: FormClipScanResult? = nil
        var rejected: [FormClipRejectedCandidate] = []
        var windows: [FormClipWindow] = []
        if let path = flag("--use-series") {
            let f = try JSONDecoder().decode(SeriesFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            samples = f.samples
            print("  series re-read from \(path): \(samples.count) samples (no decode, no Vision)")
            let found = FormClipScanner.analyse(samples, options: options)
            samples = found.samples
            windows = found.windows
            rejected = found.rejected
            print("  · " + found.sideNote)
        } else {
            let t0 = Date()
            let r = try await FormClipScanner.scan(url: clip, options: options) { t, _ in
                FileHandle.standardError.write(Data(String(format: "\r  scanning… %.0f s", t).utf8))
            }
            FileHandle.standardError.write(Data("\n".utf8))
            result = r
            samples = r.samples
            windows = r.windows
            rejected = r.rejected
            print(String(format: "formclip scan: %@  %dx%d at %.2f fps (time scale %.0f)", clip.lastPathComponent,
                         r.imageWidth, r.imageHeight, r.fileFrameRate, r.timeScale))
            print(String(format: "  %d frames decoded, %d sampled, body complete on %d (%.0f %%), %.1f s wall (%.0f samples/s)",
                         r.decodedFrames, r.analysedFrames, r.framesWithBody,
                         100 * Double(r.framesWithBody) / Double(max(1, r.analysedFrames)),
                         r.wallSeconds, Double(r.analysedFrames) / max(r.wallSeconds, 1e-6)))
            for n in r.notes { print("  · \(n)") }
            print(String(format: "  cost: %.1f ms per sampled frame, %.1f s per minute of clip",
                         1000 * r.wallSeconds / Double(max(1, r.analysedFrames)),
                         60 * r.wallSeconds / max(1e-6, (r.samples.last?.realTime ?? 1) - (r.samples.first?.realTime ?? 0))))
            if let path = flag("--series") {
                let data = try JSONEncoder().encode(SeriesFile(samples: r.samples, timeScale: r.timeScale, fps: r.fileFrameRate))
                try data.write(to: URL(fileURLWithPath: path))
                print("  series written: \(path) (\(data.count / 1024) kB)")
            }
        }

        print("  \(windows.count) shot window(s) found by the body:")
        for w in windows {
            print(String(format: "   %2d  apex %8.3f s  rise %.2f spans in %.0f ms  set %@  plateau %@  %@ hand, torso %.0f px%@",
                         w.id, w.apexRealTime, w.riseSpans, 1000 * w.riseSeconds,
                         w.setRealTime.map { String(format: "%.3f (−%.0f ms)", $0, 1000 * (w.apexRealTime - $0)) } ?? "nil",
                         w.setPlateauSeconds.map { String(format: "%.0f ms", 1000 * $0) } ?? "—",
                         w.shootingSide, w.torsoSpanPx,
                         w.notes.isEmpty ? "" : "  · " + w.notes.joined(separator: "; ")))
        }

        if !rejected.isEmpty {
            print("  \(rejected.count) wrist high point(s) refused:")
            for r in rejected {
                print(String(format: "      %8.3f s  rise %.2f, apex %+.2f spans from the shoulder line — %@", r.apexRealTime, r.riseSpans, r.apexAboveShoulderSpans, r.reason))
            }
        }

        // ---- the truth, when the clip has one --------------------------------------------------
        var truth: [Double] = []
        if let list = flag("--truth") { truth = list.split(separator: ",").compactMap { Double($0) } }
        if let path = flag("--truth-file") {
            let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            truth = text.split(whereSeparator: \.isNewline).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        truth.sort()
        if !truth.isEmpty {
            print("\n  against \(truth.count) ball-based releases (the rim is in frame on this clip):")
            var matchedApex: [Double] = []
            var missed: [Double] = []
            for t in truth {
                if let w = windows.min(by: { abs($0.apexRealTime - t) < abs($1.apexRealTime - t) }), abs(w.apexRealTime - t) <= 0.5 {
                    matchedApex.append(w.apexRealTime - t)
                } else { missed.append(t) }
            }
            let extras = windows.filter { w in !truth.contains { abs($0 - w.apexRealTime) <= 0.5 } }
            print(String(format: "    found %d of %d (%.0f %%), %d window(s) with no ball-based release nearby",
                         matchedApex.count, truth.count, 100 * Double(matchedApex.count) / Double(truth.count), extras.count))
            if !missed.isEmpty { print("    missed: " + missed.map { String(format: "%.1f", $0) }.joined(separator: " ")) }
            if !extras.isEmpty { print("    extra:  " + extras.map { String(format: "%.1f", $0.apexRealTime) }.joined(separator: " ")) }
            report("    wrist apex − ball release", matchedApex, fps: fps / scale)
            // Only the windows with a reference are worth any Vision time below.
            windows = windows.filter { w in truth.contains { abs($0 - w.apexRealTime) <= 0.5 } }
        }

        // ---- the release, window by window, with the body only -----------------------------------
        if args.contains("--body") {
            let limit = flag("--limit").flatMap(Int.init) ?? windows.count
            let step = flag("--every").flatMap(Int.init) ?? 2
            let hfov = flag("--hfov").flatMap(Double.init) ?? 73.83
            let useBall = !args.contains("--no-ball")
            var errorsBall: [Double] = [], errorsApex: [Double] = [], errorsPeak: [Double] = []
            var sources: [String: Int] = [:]
            print("\n  body-only release on \(min(limit, windows.count)) window(s) (every \(step) frame\(step == 1 ? "" : "s"), hFOV \(hfov)°):")
            for w in windows.prefix(limit) {
                var bodyOptions = BodyTracker.Options()
                bodyOptions.everyNthFrame = step
                bodyOptions.timeScale = scale
                bodyOptions.shootingSide = w.shootingSide
                bodyOptions.handFocusRealTimeRange = (w.apexRealTime - 0.4)...(w.apexRealTime + 0.4)
                // A form clip has no ball track to place the hand crop from; the wrist does it.
                bodyOptions.handFocusUsesBall = false

                // The ball, seeded from the hand rather than from a rim arrival.
                var ballTrack: [BodyBallSample] = []
                var ballSeconds = 0.0
                if useBall {
                    let t0 = Date()
                    let seeds = FormClipBall.seeds(from: samples, side: w.shootingSide,
                                                   realTimeRange: (w.apexRealTime - 0.35)...(w.apexRealTime + 0.05))
                    let diameter = FormClipBall.ballDiametersPerTorsoSpan * w.torsoSpanPx
                    let detections = (try? await FormClipBall.track(url: clip, start: w.startFile, end: w.endFile, fps: fps,
                                                                    seeds: seeds, expectedDiameterPx: diameter)) ?? []
                    ballTrack = detections.filter { !$0.edge }
                        .map { BodyBallSample(t: $0.pts / scale, u: $0.u, v: $0.v, diameterPx: $0.diameterPx) }
                    ballSeconds = Date().timeIntervalSince(t0)
                }

                let t1 = Date()
                let timeline = try await BodyTracker.run(url: clip, start: w.startFile, end: w.endFile,
                                                         options: bodyOptions,
                                                         ballSeed: ballTrack.map { (pts: $0.t * scale, uv: SIMD2($0.u, $0.v)) },
                                                         fps: fps)
                let bodySeconds = Date().timeIntervalSince(t1)
                let (release, why) = FormClipReleaseEstimator.estimate(timeline: timeline, ball: ballTrack,
                                                                       apexRealTime: w.apexRealTime,
                                                                       shootingSide: w.shootingSide)
                let reference = truth.min(by: { abs($0 - w.apexRealTime) < abs($1 - w.apexRealTime) })
                let frameMs = 1000 * scale / fps
                var line = String(format: "   %2d  ball %3d samples in %.1f s, body %d frames in %.1f s",
                                  w.id, ballTrack.count, ballSeconds, timeline.analysedFrames, bodySeconds)
                if let r = release {
                    sources[r.source.rawValue, default: 0] += 1
                    line += String(format: "  → %@ at %.4f s (±%.0f ms)", r.source.rawValue, r.realTime, 1000 * r.sigmaSeconds)
                    if let reference {
                        let dt = r.realTime - reference
                        line += String(format: "   Δ %+6.1f ms = %+5.2f frames", 1000 * dt, 1000 * dt / frameMs)
                        switch r.source {
                        case .ballLeftHand: errorsBall.append(dt)
                        case .wristApex: errorsApex.append(dt)
                        case .wristPeakVelocity: errorsPeak.append(dt)
                        }
                    }
                    // Both fallbacks, every time, so the spread of the one that is used is known.
                    let (apexOnly, _) = FormClipReleaseEstimator.estimate(timeline: timeline, ball: [],
                                                                          apexRealTime: w.apexRealTime,
                                                                          shootingSide: w.shootingSide)
                    if let a = apexOnly, let reference, r.source == .ballLeftHand {
                        line += String(format: "   [apex %+.1f ms]", 1000 * (a.realTime - reference))
                        errorsApex.append(a.realTime - reference)
                    }
                    if let reference, let p = w.peakRateRealTime {
                        errorsPeak.append(p - reference)
                    }
                } else {
                    line += "  → no release (\(why ?? "no reason given"))"
                }
                print(line)
            }
            let frameSeconds = scale / fps
            print("\n  release error against the ball-based reference, in frames of the file (\(String(format: "%.2f", 1000 * frameSeconds)) ms):")
            report("    ball left the hand ", errorsBall, fps: fps / scale)
            report("    wrist apex         ", errorsApex, fps: fps / scale)
            report("    wrist peak velocity", errorsPeak, fps: fps / scale)
            print("    source used: " + (sources.isEmpty ? "none" : sources.map { "\($0.key) ×\($0.value)" }.sorted().joined(separator: ", ")))
        }

        // ---- the simulated close-up ---------------------------------------------------------------
        if let zoom = flag("--crop").flatMap(Double.init) {
            let dir = URL(fileURLWithPath: flag("--crop-out") ?? NSTemporaryDirectory()).standardizedFileURL.absoluteURL
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let count = flag("--crop-windows").flatMap(Int.init) ?? 3
            let step = flag("--every").flatMap(Int.init) ?? 2
            let hfov = flag("--hfov").flatMap(Double.init) ?? 73.83
            print(String(format: "\n  simulated close-up: the frame cropped %.1f× around the shooter and re-encoded, %d window(s)", zoom, count))
            for w in windows.prefix(count) {
                // The crop box is fitted to the shooter, not to a round number. The mid-shoulder row
                // comes back from the scan's own scalar (wristHeightSpans = (midShoulder v − wrist v)
                // ÷ torso span), the follow-through hand sets the top, and the ankles sit about 4.6
                // torso spans below the shoulders on this shooter.
                let near = samples.filter { $0.realTime >= w.apexRealTime - 1.5 && $0.realTime <= w.apexRealTime + 0.4 }
                let boxes = near.compactMap(\.bodyBox)
                guard boxes.count >= 5 else { print("   \(w.id): too few body boxes near the apex to place a crop (re-scan; an older series has none)"); continue }
                // The union of every confident joint over the window, plus a third of a torso span
                // of margin — the "whole body, a hand's width above the follow-through" framing.
                let span = w.torsoSpanPx
                let top = boxes.map { $0[1] }.min()! - 0.35 * span
                let bottom = boxes.map { $0[3] }.max()! + 0.35 * span
                let cx = (boxes.map { $0[0] }.min()! + boxes.map { $0[2] }.max()!) / 2
                let cy = (top + bottom) / 2
                // The requested zoom is a *cap*: a 1080-row frame cannot hold a 500-px shooter in a
                // 360-row crop, so the box the body needs wins and the achieved zoom is printed.
                let needed = bottom - top
                let out = dir.appendingPathComponent(String(format: "crop_%d.mov", w.id))
                let box = try await CropExport.write(clip: clip, start: w.startFile, end: w.endFile,
                                                     centre: SIMD2(cx, cy),
                                                     zoom: min(zoom, 1080 / max(needed, 1)), to: out)
                print(String(format: "   %2d: the body needs %.0f rows; crop %.0f×%.0f at (%.0f, %.0f) = %.2f× zoom → %@",
                             w.id, needed, box.width, box.height, box.origin.x, box.origin.y,
                             1080 / box.height, out.lastPathComponent))
                for (label, url, x0, y0) in [("full frame", clip, 0.0, 0.0), ("close-up  ", out, box.origin.x, box.origin.y)] {
                    var o = BodyTracker.Options()
                    o.everyNthFrame = step
                    o.timeScale = scale
                    o.shootingSide = w.shootingSide
                    o.handFocusRealTimeRange = (w.apexRealTime - 0.4)...(w.apexRealTime + 0.4)
                    o.handFocusUsesBall = false
                    let start = url == clip ? w.startFile : 0
                    let end = url == clip ? w.endFile : (w.endFile - w.startFile)
                    // The crop's clock starts at the window (`CropExport` writes pts − first), so the
                    // apex — and with it the hand-focus range and the "hands at release" count — must
                    // be moved onto that clock, or the crop row reports 0/0 hands for a clock offset.
                    let apexReal = url == clip ? w.apexRealTime : w.apexRealTime - w.startFile / scale
                    o.handFocusRealTimeRange = (apexReal - 0.4)...(apexReal + 0.4)
                    let t0 = Date()
                    let timeline = try await BodyTracker.run(url: url, start: start, end: end, options: o, fps: fps)
                    let seconds = Date().timeIntervalSince(t0)
                    let all = BodyCoverage.perJoint(timeline: timeline)
                    let coverage = Dictionary(uniqueKeysWithValues: all.filter { $0.source == "body2D" }.map { ($0.name, $0) })
                    let names = [Body2DPoint.nose, Body2DPoint.neck, Body2DPoint.rightShoulder, Body2DPoint.rightElbow,
                                 Body2DPoint.rightWrist, Body2DPoint.rightHip, Body2DPoint.rightKnee, Body2DPoint.rightAnkle]
                    let seen = names.compactMap { coverage[$0]?.seenFraction }
                    let jitter = names.compactMap { coverage[$0]?.jitterPixels.value }
                    let handFrames = timeline.frames.filter { abs($0.realTime - apexReal) <= 0.4 }
                    let withHands = handFrames.filter { !$0.hands.isEmpty }.count
                    // The shooter's own size, so the two rows can be compared at all.
                    let span = shooterSpan(timeline)
                    let body3D = timeline.frames.filter { !$0.joints3D.isEmpty }.count
                    print(String(format: "      %@ %.1f s  shooter %.0f px  seen %.0f–%.0f %% (mean %.1f %%)  jitter %.2f–%.2f px (median %.2f = %.2f %% of height)  3-D body %d/%d  hands at release %d/%d = %.0f %%",
                                 label, seconds, span ?? .nan,
                                 100 * (seen.min() ?? .nan), 100 * (seen.max() ?? .nan), 100 * mean(seen),
                                 jitter.min() ?? .nan, jitter.max() ?? .nan, median(jitter),
                                 100 * median(jitter) / (span ?? .nan),
                                 body3D, timeline.frames.count,
                                 withHands, handFrames.count,
                                 handFrames.isEmpty ? 0 : 100 * Double(withHands) / Double(handFrames.count)))
                    let perJoint = names.map { n in
                        String(format: "%@ %.0f%%/%.2fpx", short(n), 100 * (coverage[n]?.seenFraction ?? 0),
                               coverage[n]?.jitterPixels.value ?? .nan)
                    }
                    print("        " + perJoint.joined(separator: "  "))
                    _ = hfov
                }
            }
        }
    }

    // MARK: - Small reporting helpers

    static func short(_ joint: String) -> String {
        joint.replacingOccurrences(of: "right", with: "r").replacingOccurrences(of: "left", with: "l")
    }

    static func mean(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count) }
    static func median(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.sorted()[x.count / 2] }

    static func report(_ label: String, _ errors: [Double], fps: Double) {
        guard !errors.isEmpty else { print("\(label): n 0") ; return }
        let frames = errors.map { $0 * fps }
        let m = mean(frames)
        let sd = frames.count >= 2
            ? (frames.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(frames.count - 1)).squareRoot() : Double.nan
        let absolute = frames.map { abs($0) }.sorted()
        print(String(format: "%@: n %d, mean %+.2f frames, SD %.2f, median |Δ| %.2f, worst %.2f (%.1f ms)",
                     label, frames.count, m, sd, absolute[absolute.count / 2], absolute.last ?? .nan,
                     1000 * (absolute.last ?? .nan) / fps))
    }

    /// The shooter's 90th-percentile ankle-to-nose pixel span in this timeline — the one number that
    /// says how big the subject was, and therefore what the two rows above are comparing.
    static func shooterSpan(_ timeline: BodyTimeline) -> Double? {
        var spans: [Double] = []
        for f in timeline.frames {
            guard let nose = f.points2D[Body2DPoint.nose], nose.confidence >= 0.3 else { continue }
            let ankles = [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle].compactMap { f.points2D[$0] }.filter { $0.confidence >= 0.3 }
            guard let a = ankles.max(by: { $0.v < $1.v }) else { continue }
            spans.append(simd_length(SIMD2(a.u, a.v) - SIMD2(nose.u, nose.v)))
        }
        guard spans.count >= 5 else { return nil }
        let sorted = spans.sorted()
        return sorted[min(sorted.count - 1, Int((0.9 * Double(sorted.count - 1)).rounded()))]
    }
}

// MARK: - Cropping a clip to the shooter, to stand in for a close-up

/// Re-encodes a window of a clip as a zoomed crop around a point. The crop's clock starts at zero
/// at the window's first frame (frame spacing is the source's), so a caller comparing against the
/// source must subtract the window start. This is how a 9 m clip with a known ball-based release is turned
/// into something the shape of a 3–4 m form clip, without filming one.
enum CropExport {
    static func write(clip: URL, start: Double, end: Double, centre: SIMD2<Double>, zoom: Double, to out: URL) async throws -> CGRect {
        let asset = AVURLAsset(url: clip)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoReaderError.noVideoTrack }
        let natural = try await track.load(.naturalSize)
        let imageSize = CGSize(width: abs(natural.width), height: abs(natural.height))
        // The crop keeps the source aspect ratio, so nothing about the lens model changes except the
        // field of view — which is exactly what moving the camera closer does.
        // H.264 wants even dimensions: an odd width writes a file that will not open again.
        var w = (imageSize.width / zoom / 2).rounded() * 2, h = (imageSize.height / zoom / 2).rounded() * 2
        w = min(w, imageSize.width); h = min(h, imageSize.height)
        var x = (centre.x - w / 2).rounded(), y = (centre.y - h / 2).rounded()
        x = min(max(0, x), imageSize.width - w)
        y = min(max(0, y), imageSize.height - h)
        let box = CGRect(x: x, y: y, width: w, height: h)

        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(w), AVVideoHeightKey: Int(h),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(w), kCVPixelBufferHeightKey as String: Int(h)])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoReaderError.cannotStartReading("writer") }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        let reader = VideoReader(url: clip)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        var first: Double? = nil
        try await reader.forEachFrame(timeRange: range) { f in
            guard let pb = f.pixelBuffer, let pool = adaptor.pixelBufferPool else { return true }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var outPB: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB) == kCVReturnSuccess, let destination = outPB else { return true }
            let image = CIImage(cvPixelBuffer: pb)
            let ciRect = CGRect(x: box.origin.x, y: imageSize.height - box.origin.y - box.height, width: box.width, height: box.height)
            let cropped = image.cropped(to: ciRect).transformed(by: CGAffineTransform(translationX: -ciRect.origin.x, y: -ciRect.origin.y))
            context.render(cropped, to: destination, bounds: CGRect(origin: .zero, size: box.size), colorSpace: CGColorSpaceCreateDeviceRGB())
            if first == nil { first = f.pts }
            // 600 ticks/s cannot hold 240 fps (2.5 ticks per frame): every other frame collided with
            // its neighbour and the file came back "damaged". 240 000 holds any rate the app records.
            adaptor.append(destination, withPresentationTime: CMTime(seconds: f.pts - (first ?? 0), preferredTimescale: 240_000))
            return true
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? VideoReaderError.cannotStartReading("the crop writer ended in state \(writer.status.rawValue)")
        }
        return box
    }
}
