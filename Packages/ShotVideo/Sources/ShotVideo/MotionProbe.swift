import Foundation
import CoreVideo
import Accelerate
import simd

/// A very cheap "where is something ball-shaped moving?" signal, used to **aim** the Core ML tile.
///
/// The Core ML detector costs one inference per 512-px tile. With something to aim at that is one tile a frame;
/// with nothing, the whole frame has to be swept — 15 tiles at 1080p, which is where most of a window's inference
/// time went. This class gives the decode loop an aim point for a fraction of a millisecond: a sigma-delta
/// background at a sixteenth of the area, the same difference-and-orange test the detector uses, and the most
/// ball-like blob. It never places a ball and never produces a detection; a wrong guess only costs that frame's
/// tile, exactly as a missed sweep would.
final class MotionProbe {
    private let ww: Int, wh: Int, ds: Int
    private let expectedArea: Double
    private let minArea: Double, maxArea: Double
    private let maxAspect: Double
    private let thr: Float, orange: Float, chroma: Float

    private var y: [UInt8], cr: [UInt8]
    private var fy: [Float], fc: [Float]
    private var bgY: [Float], bgCr: [Float]
    private var dY: [Float], dC: [Float], diff: [Float], scratch: [Float]
    private var boxScratch: [Float]
    private var mask: [UInt8], visited: [UInt8], stack: [Int32]
    private var primed = false

    init(width: Int, height: Int, ballDiameterPx: Double, downscale: Int = 4,
         diffThreshold: Double = 16, chromaWeight: Double = 3, orangeMargin: Double = 5) {
        ds = max(1, downscale)
        ww = width / ds; wh = height / ds
        let n = ww * wh
        let d = max(3.0, ballDiameterPx / Double(ds))
        expectedArea = Double.pi * d * d / 4
        minArea = 0.10 * expectedArea; maxArea = 6.0 * expectedArea
        maxAspect = 2.8
        thr = Float(diffThreshold); orange = Float(orangeMargin.rounded()); chroma = Float(chromaWeight)
        y = [UInt8](repeating: 0, count: n); cr = [UInt8](repeating: 0, count: n)
        fy = [Float](repeating: 0, count: n); fc = [Float](repeating: 0, count: n)
        bgY = [Float](repeating: 0, count: n); bgCr = [Float](repeating: 0, count: n)
        dY = [Float](repeating: 0, count: n); dC = [Float](repeating: 0, count: n)
        diff = [Float](repeating: 0, count: n); scratch = [Float](repeating: 0, count: n)
        boxScratch = [Float](repeating: 0, count: 2 * width + ww)
        mask = [UInt8](repeating: 0, count: n); visited = [UInt8](repeating: 0, count: n)
        stack = [Int32](repeating: 0, count: n)
    }

    /// The most ball-like moving blob on this frame, in full-resolution pixels, or nil. Must be called on every
    /// decoded frame in order: the background is built from the frames it sees.
    func best(in pb: CVPixelBuffer) -> SIMD2<Double>? {
        let n = ww * wh
        guard n > 0 else { return nil }
        RimArrivalScanner.downsample(pb, ds: ds, workWidth: ww, workHeight: wh, scratch: &boxScratch, y: &y, cr: &cr)
        vDSP_vfltu8(y, 1, &fy, 1, vDSP_Length(n))
        vDSP_vfltu8(cr, 1, &fc, 1, vDSP_Length(n))
        if !primed { bgY = fy; bgCr = fc; primed = true; return nil }

        vDSP_vsub(bgY, 1, fy, 1, &dY, 1, vDSP_Length(n))
        vDSP_vsub(bgCr, 1, fc, 1, &dC, 1, vDSP_Length(n))
        vDSP_vabs(dY, 1, &diff, 1, vDSP_Length(n))
        vDSP_vabs(dC, 1, &scratch, 1, vDSP_Length(n))
        var weight = chroma
        vDSP_vsma(scratch, 1, &weight, diff, 1, &diff, 1, vDSP_Length(n))
        var hits = 0
        diff.withUnsafeBufferPointer { df in dC.withUnsafeBufferPointer { dc in
            mask.withUnsafeMutableBufferPointer { mk in
                for i in 0..<n {
                    let on: UInt8 = (df[i] >= thr && dc[i] > orange) ? 1 : 0
                    mk[i] = on; hits += Int(on)
                }
            }
        } }
        // Background update: the differences are whole numbers, so clipping them to [−1, 1] is their sign.
        var lo: Float = -1, hi: Float = 1
        vDSP_vclip(dY, 1, &lo, &hi, &scratch, 1, vDSP_Length(n))
        vDSP_vadd(bgY, 1, scratch, 1, &bgY, 1, vDSP_Length(n))
        vDSP_vclip(dC, 1, &lo, &hi, &scratch, 1, vDSP_Length(n))
        vDSP_vadd(bgCr, 1, scratch, 1, &bgCr, 1, vDSP_Length(n))

        guard hits > 0, hits < n / 4 else { return nil }
        var best: (score: Double, u: Double, v: Double)? = nil
        for i in 0..<n where mask[i] == 1 && visited[i] == 0 {
            var sp = 0
            stack[sp] = Int32(i); sp += 1; visited[i] = 1
            var count = 0, su = 0.0, sv = 0.0, sd = 0.0
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            while sp > 0 {
                sp -= 1
                let q = Int(stack[sp])
                let qx = q % ww, qy = q / ww
                count += 1
                let w = Double(diff[q]) * Double(diff[q])
                su += w * Double(qx); sv += w * Double(qy); sd += w
                if qx < minX { minX = qx }; if qx > maxX { maxX = qx }
                if qy < minY { minY = qy }; if qy > maxY { maxY = qy }
                if qx > 0, mask[q - 1] == 1, visited[q - 1] == 0 { visited[q - 1] = 1; stack[sp] = Int32(q - 1); sp += 1 }
                if qx < ww - 1, mask[q + 1] == 1, visited[q + 1] == 0 { visited[q + 1] = 1; stack[sp] = Int32(q + 1); sp += 1 }
                if qy > 0, mask[q - ww] == 1, visited[q - ww] == 0 { visited[q - ww] = 1; stack[sp] = Int32(q - ww); sp += 1 }
                if qy < wh - 1, mask[q + ww] == 1, visited[q + ww] == 0 { visited[q + ww] = 1; stack[sp] = Int32(q + ww); sp += 1 }
            }
            let area = Double(count)
            guard area >= minArea, area <= maxArea, sd > 0 else { continue }
            let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
            guard max(bw, bh) / max(1, min(bw, bh)) <= maxAspect else { continue }
            // The most ball-like: the right size and as round as possible.
            let score = abs(log(area / expectedArea)) + 0.5 * (max(bw, bh) / max(1, min(bw, bh)) - 1)
            if best == nil || score < best!.score {
                best = (score, (su / sd + 0.5) * Double(ds), (sv / sd + 0.5) * Double(ds))
            }
        }
        for i in 0..<n where mask[i] == 1 { visited[i] = 0 }
        return best.map { SIMD2($0.u, $0.v) }
    }
}
