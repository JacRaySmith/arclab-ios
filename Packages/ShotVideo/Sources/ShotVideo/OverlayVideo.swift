import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreGraphics
import CoreText
import ShotGeometry

/// Writes a review video for one shot window: each source frame → one output frame with the overlay drawn.
/// Step it frame by frame in QuickTime Player (arrow keys). `scale` = file time / real time (4 for 120 fps slo-mo).
public enum OverlayVideo {
    public struct Params {
        public var samples: [ImageSample]          // t in real seconds
        public var analysis: ShotAnalysis?
        public var rim: [SIMD2<Double>]
        public var intrinsics: CameraIntrinsics
        public var scale: Double
        public var title: String
        public init(samples: [ImageSample], analysis: ShotAnalysis?, rim: [SIMD2<Double>], intrinsics: CameraIntrinsics, scale: Double, title: String) {
            self.samples = samples; self.analysis = analysis; self.rim = rim; self.intrinsics = intrinsics; self.scale = scale; self.title = title
        }
    }

    public static func write(clip: URL, start: Double, end: Double, params p: Params, to out: URL, outputFPS: Int32 = 30) async throws -> Int {
        let reader = VideoReader(url: clip)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        try? FileManager.default.removeItem(at: out)
        var writer: AVAssetWriter? = nil
        var input: AVAssetWriterInput? = nil
        var adaptor: AVAssetWriterInputPixelBufferAdaptor? = nil
        let ci = CIContext()
        var count = 0
        // precompute the fitted curve and window markers
        var curve: [SIMD2<Double>] = []
        var flightTimes: (Double, Double)? = nil
        var releaseUV: SIMD2<Double>? = nil
        var endUV: SIMD2<Double>? = nil
        if let a = p.analysis {
            let ri = a.flightIndices.first ?? 0, ei = a.flightIndices.last ?? 0
            let tr = a.window.releaseTime, te = a.planeSamples[min(ei, a.planeSamples.count - 1)].t
            flightTimes = (tr, te)
            var t = tr
            while t <= te + 0.05 {
                let q = a.fit.position(at: t); let P = a.azimuth.frame.point3D(x: q.x, y: q.y)
                if P.z > 0.1 { curve.append(p.intrinsics.pixel(fromNormalized: SIMD2(P.x / P.z, P.y / P.z))) }
                t += 0.01
            }
            if ri < p.samples.count { releaseUV = p.samples[ri].uv }
            if ei < p.samples.count { endUV = p.samples[ei].uv }
        }
        let byFrameT: [(Double, ImageSample)] = p.samples.map { ($0.t * p.scale, $0) }
        let inWindow = Set(p.analysis?.flightIndices ?? [])
        let sampleIndex: [Int: Int] = Dictionary(uniqueKeysWithValues: p.samples.enumerated().map { (Int(($0.element.t * p.scale * 1000).rounded()), $0.offset) })

        try await reader.forEachFrame(timeRange: range) { f in
            guard let pb = f.pixelBuffer else { return true }
            let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb)
            if writer == nil {
                let w = try AVAssetWriter(outputURL: out, fileType: .mov)
                let inp = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
                                                                                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 25_000_000]])
                inp.expectsMediaDataInRealTime = false
                let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
                w.add(inp); guard w.startWriting() else { throw w.error ?? VideoReaderError.cannotStartReading("writer") }
                w.startSession(atSourceTime: .zero)
                writer = w; input = inp; adaptor = ad
            }
            guard let inp = input, let ad = adaptor, let pool = ad.pixelBufferPool else { return false }
            while !inp.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var outPB: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB)
            guard let opb = outPB else { return false }
            // render source frame into the BGRA buffer, then draw with CoreGraphics
            ci.render(CIImage(cvPixelBuffer: pb), to: opb)
            CVPixelBufferLockBaseAddress(opb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(opb), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(opb),
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
            // rim
            ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 0.9))
            for r in p.rim { ctx.fillEllipse(in: CGRect(x: r.x - 2, y: r.y - 2, width: 4, height: 4)) }
            // fitted curve (dim) and trail of past detections
            if curve.count > 1 {
                ctx.setStrokeColor(CGColor(red: 1, green: 0.55, blue: 0, alpha: 0.55)); ctx.setLineWidth(3)
                ctx.beginPath(); ctx.move(to: CGPoint(x: curve[0].x, y: curve[0].y)); for c in curve.dropFirst() { ctx.addLine(to: CGPoint(x: c.x, y: c.y)) }; ctx.strokePath()
            }
            let tFile = f.pts
            var current: ImageSample? = nil
            var currentIdx: Int? = nil
            for (i, (ts, smp)) in byFrameT.enumerated() where ts <= tFile + 1e-4 {
                ctx.setFillColor(CGColor(red: 0.3, green: 0.8, blue: 1, alpha: 0.8)); ctx.fillEllipse(in: CGRect(x: smp.uv.x - 3, y: smp.uv.y - 3, width: 6, height: 6))
                if abs(ts - tFile) < 1e-3 { current = smp; currentIdx = i }
            }
            let realT = tFile / p.scale
            var status = "no detection"
            if let c = current {
                let r = max(6, (c.diameterPx ?? 30) / 2)
                let accepted = currentIdx.map { inWindow.contains($0) } ?? false
                ctx.setStrokeColor(accepted ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 1)); ctx.setLineWidth(4)
                ctx.strokeEllipse(in: CGRect(x: c.uv.x - r, y: c.uv.y - r, width: 2 * r, height: 2 * r))
                status = accepted ? "detected, used by the fit" : "detected, outside the flight window"
            } else if let ft = flightTimes, realT >= ft.0, realT <= ft.1, let a = p.analysis {
                let q = a.fit.position(at: realT); let P = a.azimuth.frame.point3D(x: q.x, y: q.y)
                if P.z > 0.1 { let uv = p.intrinsics.pixel(fromNormalized: SIMD2(P.x / P.z, P.y / P.z))
                    ctx.setStrokeColor(CGColor(red: 1, green: 0.55, blue: 0, alpha: 1)); ctx.setLineWidth(3); ctx.setLineDash(phase: 0, lengths: [6, 6])
                    ctx.strokeEllipse(in: CGRect(x: uv.x - 20, y: uv.y - 20, width: 40, height: 40)); ctx.setLineDash(phase: 0, lengths: [])
                    status = "no detection: dashed = where the fit predicts the ball" }
            }
            if let r = releaseUV { ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.setLineWidth(3)
                ctx.strokeEllipse(in: CGRect(x: r.x - 16, y: r.y - 16, width: 32, height: 32)); ctx.strokeEllipse(in: CGRect(x: r.x - 22, y: r.y - 22, width: 44, height: 44)) }
            if let e = endUV { ctx.setStrokeColor(CGColor(red: 1, green: 0.6, blue: 0, alpha: 1)); ctx.strokeEllipse(in: CGRect(x: e.x - 16, y: e.y - 16, width: 32, height: 32)) }
            // text
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6)); ctx.fill(CGRect(x: 10, y: 10, width: 900, height: 96))
            ctx.scaleBy(x: 1, y: -1); ctx.translateBy(x: 0, y: -CGFloat(H))
            let lines = [p.title,
                         String(format: "frame %d   file time %.3f s   real time %.3f s   %@", f.index, tFile, realT, status),
                         "red double ring: release   orange ring: window end   white ring: detection used   red ring: detection not used   orange curve: fitted parabola"]
            for (i, line) in lines.enumerated() {
                let attrs: [CFString: Any] = [kCTFontAttributeName: CTFontCreateWithName("Menlo" as CFString, 22, nil), kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
                let str = CFAttributedStringCreate(nil, line as CFString, attrs as CFDictionary)!
                ctx.textPosition = CGPoint(x: 18, y: CGFloat(H) - CGFloat(38 + 28 * i)); CTLineDraw(CTLineCreateWithAttributedString(str), ctx)
            }
            CVPixelBufferUnlockBaseAddress(opb, [])
            guard ad.append(opb, withPresentationTime: CMTime(value: CMTimeValue(count), timescale: outputFPS)) else { return false }
            count += 1
            return true
        }
        input?.markAsFinished()
        if let w = writer { await w.finishWriting(); if let e = w.error { throw e } }
        return count
    }
}
