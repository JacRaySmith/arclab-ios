import Foundation
import ShotVideo
import simd
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `TrajectoryProbe spin <clip> --track-json shot.json --from <file s> [...]`
/// `TrajectoryProbe spin any --self-test`
///
/// Measures ball spin — rate and axis — from the ball's surface texture over consecutive frames,
/// and self-tests the estimator against a synthetic sphere whose angular velocity is known.
enum SpinCommand {

    struct PyBall: Decodable { var u: Double?; var v: Double?; var r: Double?; var source: String }
    struct PyFrame: Decodable { var t_file: Double; var ball: PyBall }
    struct PyTrack: Decodable { var frames: [PyFrame] }

    static func run(clip: URL, args: [String]) async throws {
        func flag(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("--self-test") { selfTest(); return }

        guard let trackPath = flag("--track-json"), let from = flag("--from").flatMap(Double.init) else {
            print("""
            usage: TrajectoryProbe spin <clip.mov> --track-json <pytrack shot.json> --from <file s>
                     [--count N, default 16] [--time-scale 4] [--max-rate rev/s, default 8]
                     [--keep-static] [--no-translation] [--strip out.png] [--json out.json]
                   TrajectoryProbe spin any --self-test
            """)
            return
        }
        let scale = flag("--time-scale").flatMap(Double.init) ?? 1
        let count = flag("--count").flatMap(Int.init) ?? 16

        let py = try JSONDecoder().decode(PyTrack.self, from: Data(contentsOf: URL(fileURLWithPath: trackPath)))
        var entries: [(tFile: Double, uv: SIMD2<Double>, r: Double)] = []
        for f in py.frames {
            guard let u = f.ball.u, let v = f.ball.v, let r = f.ball.r, f.ball.source != "none" else { continue }
            guard f.t_file >= from - 1e-6 else { continue }
            entries.append((f.t_file, SIMD2(u, v), r))
            if entries.count >= count { break }
        }
        guard entries.count >= 3 else { print("spin: fewer than 3 tracked frames from \(from) s"); return }
        print(String(format: "spin: %d tracked frames, file t %.3f → %.3f s, ball radius %.1f → %.1f px",
                     entries.count, entries.first!.tFile, entries.last!.tFile, entries.first!.r, entries.last!.r))

        // Decode just those frames and keep a crop around the ball.
        let t0 = entries.first!.tFile, t1 = entries.last!.tFile
        let range = CMTimeRange(start: CMTime(seconds: max(0, t0 - 0.05), preferredTimescale: 600),
                                end: CMTime(seconds: t1 + 0.05, preferredTimescale: 600))
        var frames = [SpinGrayImage?](repeating: nil, count: entries.count)
        let tolerance = 0.6 / 30.0
        try await VideoReader(url: clip).forEachPixelBuffer(timeRange: range) { _, pts, pb in
            for (i, e) in entries.enumerated() where frames[i] == nil && abs(pts - e.tFile) < tolerance {
                let box = Int(e.r * 2.2) + 8
                frames[i] = SpinGrayImage.luma(from: pb,
                                               cropX: Int(e.uv.x) - box, cropY: Int(e.uv.y) - box,
                                               cropWidth: 2 * box, cropHeight: 2 * box)
            }
            return pts <= t1 + 0.02
        }
        var images: [SpinGrayImage] = [], track: [SpinSample] = []
        for (i, e) in entries.enumerated() {
            guard let img = frames[i] else { continue }
            images.append(img)
            track.append(SpinSample(timeSeconds: e.tFile / scale, centre: e.uv, radiusPx: e.r))
        }
        guard images.count >= 3 else { print("spin: could not decode enough of those frames"); return }

        var options = SpinOptions()
        if let m = flag("--max-rate").flatMap(Double.init) { options.maxRateRevPerSecond = m }
        if args.contains("--keep-static") { options.suppressStaticIllumination = false }
        if args.contains("--no-translation") { options.refineTranslation = false }

        if let strip = flag("--strip"), let p = SpinTracker.patchStrip(frames: images, track: track, options: options) {
            try writeStrip(p, to: URL(fileURLWithPath: strip))
            print("  strip written: \(strip)   (top row: ball crops; bottom row: what the matcher sees)")
        }

        guard let r = SpinTracker.measure(frames: images, track: track, options: options) else {
            print("spin: unavailable — fewer than three usable samples"); return
        }
        report(r)
        if let out = flag("--json") {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(r).write(to: URL(fileURLWithPath: out))
            print("  wrote \(out)")
        }
    }

    static func report(_ r: SpinResult) {
        print(String(format: "  ball %.0f px across at %.0f fps   texture SNR %.2f   static structure %.0f%%   frames %d",
                     r.ballDiameterPx, r.effectiveFrameRate, r.dynamicTextureSNR, 100 * r.staticStructureFraction, r.framesUsed))
        print(String(format: "  frame pairs: %d attempted, %d fitted   median inliers %d   median residual %.2f px",
                     r.pairsAttempted, r.pairsFitted, r.medianInliers, r.medianResidualPx))
        if let rate = r.rateRevPerSecond {
            print(String(format: "  RATE  %.2f rev/s  (± %.2f scatter, %.2f°/frame)   confidence %.2f",
                         rate, r.rateScatterRevPerSecond ?? 0, r.degreesPerFrame ?? 0, r.confidence))
        } else {
            print("  RATE  nil — \(r.rateUnavailableReason ?? "no reason recorded")")
        }
        if let tilt = r.tiltFromBackspinDegrees, let a = r.axisCamera {
            print(String(format: "  AXIS  %.1f° off pure backspin   side tilt %+.1f°   rifle tilt %+.1f°   backspin fraction %.2f",
                         tilt, r.sideTiltDegrees ?? 0, r.rifleTiltDegrees ?? 0, r.backspinFraction ?? 0))
            print(String(format: "        unit axis in camera coords (x right, y down, z away): (%+.3f, %+.3f, %+.3f)", a.x, a.y, a.z))
        } else if r.rateRevPerSecond != nil {
            print("  AXIS  nil — \(r.axisUnavailableReason ?? "no reason recorded")")
        }
        for w in r.warnings { print("  ! \(w)") }
    }

    // MARK: Synthetic validation

    static func selfTest() {
        print("spin self-test: a textured sphere with a known ω, rendered with shading, a camera-fixed")
        print("specular highlight, motion blur, noise and sub-pixel centring error, then measured.\n")

        // Flight to the right and slightly up, so the pure-backspin axis is (0, 0, -1): toward the camera.
        let velocity = SIMD2<Double>(6, -4)
        let flight = simd_normalize(SIMD3<Double>(velocity.x, velocity.y, 0))
        let up = SIMD3<Double>(0, -1, 0)
        let eB = simd_normalize(simd_cross(flight, up))
        let eV = simd_normalize(simd_cross(eB, flight))

        struct Case { var name: String; var radius: Double; var fps: Double; var rate: Double
                      var tiltDeg: Double; var contrast: Double; var blurSubsteps: Int; var noise: Double }
        let cases = [
            Case(name: "60 px ball, 120 fps, pure backspin 2.5 rev/s", radius: 30, fps: 120, rate: 2.5, tiltDeg: 0, contrast: 1.0, blurSubsteps: 4, noise: 1.5),
            Case(name: "60 px ball, 120 fps, diagonal 30° at 2.5 rev/s", radius: 30, fps: 120, rate: 2.5, tiltDeg: 30, contrast: 1.0, blurSubsteps: 4, noise: 1.5),
            Case(name: "60 px ball, 120 fps, diagonal 55° at 3.0 rev/s", radius: 30, fps: 120, rate: 3.0, tiltDeg: 55, contrast: 1.0, blurSubsteps: 4, noise: 1.5),
            Case(name: "60 px ball, 240 fps, diagonal 30° at 2.5 rev/s", radius: 30, fps: 240, rate: 2.5, tiltDeg: 30, contrast: 1.0, blurSubsteps: 2, noise: 1.5),
            Case(name: "90 px ball, 240 fps, diagonal 30° at 2.5 rev/s", radius: 45, fps: 240, rate: 2.5, tiltDeg: 30, contrast: 1.0, blurSubsteps: 2, noise: 1.5),
            Case(name: "60 px ball, 120 fps, heavy blur (8 substeps)", radius: 30, fps: 120, rate: 2.5, tiltDeg: 30, contrast: 1.0, blurSubsteps: 12, noise: 2.5),
            Case(name: "60 px ball, faint texture (contrast × 0.06) — must refuse", radius: 30, fps: 120, rate: 2.5, tiltDeg: 30, contrast: 0.06, blurSubsteps: 4, noise: 2.0),
        ]

        for c in cases {
            let axis = simd_normalize(cos(c.tiltDeg * .pi / 180) * eB + sin(c.tiltDeg * .pi / 180) * eV)
            let omega = axis * (2 * .pi * c.rate / c.fps)
            let clip = SpinTracker.renderSyntheticBall(radiusPx: c.radius, omegaRadiansPerFrame: omega,
                                                       frameCount: 24, frameRate: c.fps,
                                                       velocityPxPerFrame: velocity * (120 / c.fps),
                                                       blurSubsteps: c.blurSubsteps, noiseSigma: c.noise,
                                                       centreErrorPx: 0.4, textureContrast: c.contrast, seed: 7)
            var o = SpinOptions()
            o.maxRateRevPerSecond = 8
            print("• \(c.name)")
            guard let r = SpinTracker.measure(frames: clip.frames, track: clip.track, options: o) else {
                print("   result: nil (input unusable)\n"); continue
            }
            print(String(format: "   truth: %.2f rev/s, %.0f° off backspin      texture SNR %.2f, static %.0f%%, pairs %d/%d, inliers %d, residual %.2f px",
                         c.rate, c.tiltDeg, r.dynamicTextureSNR, 100 * r.staticStructureFraction,
                         r.pairsFitted, r.pairsAttempted, r.medianInliers, r.medianResidualPx))
            if let rate = r.rateRevPerSecond, let a = r.axisCamera {
                let axisErr = acos(max(-1, min(1, abs(simd_dot(a, axis))))) * 180 / .pi
                print(String(format: "   measured: %.2f rev/s (%+.1f%%), %.1f° off backspin (truth %.0f°), axis error %.1f°, side %+.1f°, rifle %+.1f°, confidence %.2f",
                             rate, 100 * (rate - c.rate) / c.rate, r.tiltFromBackspinDegrees ?? 0, c.tiltDeg,
                             axisErr, r.sideTiltDegrees ?? 0, r.rifleTiltDegrees ?? 0, r.confidence))
            } else {
                print("   measured: nil — \(r.rateUnavailableReason ?? "?")")
            }
            for w in r.warnings { print("   ! \(w)") }
            print("")
        }
    }

    // MARK: Strip PNG

    static func writeStrip(_ p: SpinTracker.SpinPatches, to url: URL) throws {
        let n = p.raw.count
        let tile = p.side
        let width = tile * n, height = tile * 2
        var bytes = [UInt8](repeating: 0, count: width * height)

        func blit(_ src: [Float], row: Int, col: Int, gain: Double, offset: Double) {
            for y in 0..<tile {
                let dy = row * tile + y
                for x in 0..<tile {
                    let v = Double(src[y * tile + x]) * gain + offset
                    bytes[dy * width + col * tile + x] = UInt8(max(0, min(255, v)))
                }
            }
        }
        for (i, r) in p.raw.enumerated() { blit(r, row: 0, col: i, gain: 1, offset: 0) }
        // The dynamic patches are near zero everywhere unless there is real moving texture, so they
        // are stretched by a common gain set from their own spread; a blank row means no signal.
        var acc = 0.0, cnt = 0
        for d in p.dynamic { for v in d { acc += Double(v * v); cnt += 1 } }
        let rms = cnt > 0 ? sqrt(acc / Double(cnt)) : 1
        let gain = rms > 1e-6 ? 60.0 / rms : 1
        for (i, d) in p.dynamic.enumerated() { blit(d, row: 1, col: i, gain: gain, offset: 128) }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
