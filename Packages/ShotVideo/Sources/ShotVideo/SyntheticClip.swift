import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import ShotGeometry

/// Ground truth written next to a synthetic clip so the detector can be scored frame by frame.
public struct SyntheticTruth: Codable, Sendable {
    public struct Frame: Codable, Sendable {
        public var index: Int
        public var t: Double            // seconds, release at 0
        public var pts: Double          // seconds in the clip
        public var phase: String        // hold | push | flight | contact
        public var u: Double
        public var v: Double
        public var diameterPx: Double
        public var visible: Bool        // drawn in the frame
    }
    public var fps: Double
    public var width: Int
    public var height: Int
    public var fx: Double, fy: Double, cx: Double, cy: Double
    public var rimBoundary: [[Double]]
    public var releaseAngleDeg: Double
    public var releaseSpeed: Double
    public var releaseHeight: Double
    public var releaseDistance: Double
    public var entryAngleDeg: Double
    public var apexHeight: Double
    public var timeOfFlight: Double
    public var viewAngleDeg: Double
    public var releasePTS: Double
    public var frames: [Frame]
    public var intrinsics: CameraIntrinsics { CameraIntrinsics(fx: fx, fy: fy, cx: cx, cy: cy, width: width, height: height) }
}

public struct SyntheticClipOptions: Sendable {
    /// Draw a static textured background (rectangles + noise) instead of flat grey.
    public var texturedBackground = true
    /// Draw an "arm" occluder below the ball while it is held / pushed.
    public var drawArm = true
    /// Motion blur: smear the ball along its per-frame displacement (exposure fraction of the frame interval).
    public var exposureFraction: Double = 1.0
    /// Draw the rim as an orange ellipse from the simulator's boundary points.
    public var drawRim = true
    public var codec: AVVideoCodecType = .h264
    public init() {}
}

public enum SyntheticClip {
    /// Renders the simulated shot to a video at the simulation's fps. Returns the truth record.
    public static func write(_ sim: SimulatedShot, to url: URL, options: SyntheticClipOptions = .init()) async throws -> SyntheticTruth {
        let W = sim.camera.intrinsics.width, H = sim.camera.intrinsics.height
        let fps = sim.options.fps
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.codec,
            AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoReaderError.cannotStartReading("writer") }
        writer.startSession(atSourceTime: .zero)

        let background = makeBackground(width: W, height: H, textured: options.texturedBackground, seed: sim.options.seed)
        let t0 = sim.frames.first?.t ?? 0
        let timescale: CMTimeScale = 240_000
        var truthFrames: [SyntheticTruth.Frame] = []
        var previousUV: SIMD2<Double>? = nil
        for f in sim.frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw VideoReaderError.cannotStartReading("no pixel buffer pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw VideoReaderError.cannotStartReading("pixel buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: W, height: H, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            // CoreGraphics origin is bottom-left; flip so (u, v) top-left image coordinates draw directly.
            ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(background, in: CGRect(x: 0, y: 0, width: W, height: H))
            if options.drawRim, sim.rimBoundary.count >= 3 {
                ctx.setStrokeColor(CGColor(red: 0.95, green: 0.45, blue: 0.1, alpha: 1)); ctx.setLineWidth(6)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: sim.rimBoundary[0].x, y: sim.rimBoundary[0].y))
                for p in sim.rimBoundary.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
                ctx.closePath(); ctx.strokePath()
            }
            let visible = !f.outOfFrame
            if visible {
                let r = f.diameterPx / 2
                if options.drawArm, f.phase == .hold || f.phase == .push {
                    ctx.setFillColor(CGColor(red: 0.35, green: 0.25, blue: 0.2, alpha: 1))
                    ctx.fill(CGRect(x: f.uvTrue.x - r * 0.6, y: f.uvTrue.y + r * 0.2, width: r * 1.2, height: Double(H)))
                }
                ctx.setFillColor(CGColor(red: 0.85, green: 0.42, blue: 0.12, alpha: 1))
                if options.exposureFraction > 0, let prev = previousUV, f.phase == .flight || f.phase == .contact {
                    // Smear: draw the ball at sub-steps across the exposure window.
                    let steps = 6
                    for s in 0...steps {
                        let a = Double(s) / Double(steps) * options.exposureFraction
                        let p = f.uvTrue - (f.uvTrue - prev) * a
                        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                    }
                } else {
                    ctx.fillEllipse(in: CGRect(x: f.uvTrue.x - r, y: f.uvTrue.y - r, width: 2 * r, height: 2 * r))
                }
            }
            previousUV = f.uvTrue
            CVPixelBufferUnlockBaseAddress(pb, [])
            let pts = f.t - t0
            let time = CMTime(value: CMTimeValue((pts * Double(timescale)).rounded()), timescale: timescale)
            guard adaptor.append(pb, withPresentationTime: time) else { throw writer.error ?? VideoReaderError.cannotStartReading("append") }
            truthFrames.append(.init(index: f.index, t: f.t, pts: pts, phase: f.phase.rawValue, u: f.uvTrue.x, v: f.uvTrue.y,
                                     diameterPx: f.diameterPx, visible: visible))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let e = writer.error { throw e }
        let k = sim.camera.intrinsics
        return SyntheticTruth(fps: fps, width: W, height: H, fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy,
                              rimBoundary: sim.rimBoundary.map { [$0.x, $0.y] },
                              releaseAngleDeg: Angle.degrees(sim.parameters.releaseAngle), releaseSpeed: sim.parameters.releaseSpeed,
                              releaseHeight: sim.parameters.releaseHeight, releaseDistance: sim.parameters.releaseDistance,
                              entryAngleDeg: Angle.degrees(sim.truth.entryAngle), apexHeight: sim.truth.apexHeight,
                              timeOfFlight: sim.truth.timeOfFlight, viewAngleDeg: Angle.degrees(sim.truth.viewAngle),
                              releasePTS: -t0, frames: truthFrames)
    }

    static func makeBackground(width: Int, height: Int, textured: Bool, seed: UInt64) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 0.62, green: 0.6, blue: 0.58, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if textured {
            var rng = SeededRandom(seed: seed &+ 99)
            // Floor band, wall panels, a few "posters" and speckle so frame differencing has structure to ignore.
            ctx.setFillColor(CGColor(red: 0.72, green: 0.58, blue: 0.4, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 5))
            for _ in 0..<40 {
                let w = 40 + rng.nextDouble() * 300, h = 40 + rng.nextDouble() * 200
                let x = rng.nextDouble() * Double(width), y = rng.nextDouble() * Double(height)
                let g = 0.3 + rng.nextDouble() * 0.5
                ctx.setFillColor(CGColor(red: g, green: g * (0.8 + 0.2 * rng.nextDouble()), blue: g * 0.9, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: w, height: h))
            }
            ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 0.5))
            for _ in 0..<3000 {
                ctx.fill(CGRect(x: rng.nextDouble() * Double(width), y: rng.nextDouble() * Double(height), width: 2, height: 2))
            }
        }
        return ctx.makeImage()!
    }
}

/// Tiny deterministic generator so backgrounds are reproducible without depending on ShotGeometry's internals.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
