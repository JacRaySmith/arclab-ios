import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Accelerate

/// How fast the **content** of a clip moves from one file frame to the next, along the whole file.
///
/// An iPhone slo-mo clip exported from Photos is a constant 30 fps file whose content runs at 1/4 speed inside
/// the slow section and at full speed outside it — the exporter keeps every captured frame in the slow section
/// and every 4th elsewhere. `docs/PIPELINE.md` describes the 2026-09-13 corpus as "4× slower than real time"
/// throughout; measured on 2026-09-29, the first ~45 s and last ~25 s of `IMG_1765.mov` are not, and every shot
/// in those stretches was refused for a fitted `g` of 90–140 m/s² (a 4× time-scale error squared). Nothing in
/// the file's timestamps says so, so the file has to be asked directly.
///
/// The measure is the mean absolute luma difference between consecutive decoded frames, at a sixteenth of the
/// resolution. On a tripod the background contributes nothing, so the number is "how far did whatever is moving
/// move", which is four times larger when three of every four captured frames are missing. A per-frame value is
/// noisy (a still shooter between shots moves nothing at any speed); what is read is the **upper envelope** over
/// a window of a few seconds, which is set by the fastest thing in it — the ball — and steps by ~4× at a section
/// boundary. This is a description of the file, not a measurement of any shot: the gravity fit is still the check.
public enum ContentSpeed {
    public struct Sample: Sendable, Codable {
        public var pts: Double
        public var meanAbsDiff: Double
    }

    public struct Section: Sendable, Codable {
        public var start: Double
        public var end: Double
        /// Content frames per file frame relative to the slowest section: 1 inside the slow section, ≈ 4 outside.
        public var speedFactor: Double
    }

    /// Mean |Y(t) − Y(t−1)| per decoded frame, at `downscale` × reduced resolution.
    public static func measure(url: URL, start: Double = 0, end: Double? = nil, downscale: Int = 4,
                               progress: (@Sendable (Int, Double) -> Void)? = nil) async throws -> [Sample] {
        let reader = VideoReader(url: url)
        let head = try await reader.quickProbe(maxFrames: 30)
        guard head.width > 0, head.height > 0 else { return [] }
        let ds = max(1, downscale)
        let outW = (head.width / ds) & ~1, outH = (head.height / ds) & ~1
        var range: CMTimeRange? = nil
        if start > 0 || end != nil {
            range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: end.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .positiveInfinity)
        }
        var previous: [Float] = []
        var current: [Float] = []
        var scratch: [Float] = []
        var out: [Sample] = []
        try await reader.forEachPixelBuffer(timeRange: range, outputSize: (outW, outH)) { index, pts, pb in
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return true }
            let n = w * h
            if current.count != n { current = [Float](repeating: 0, count: n); scratch = current }
            for row in 0..<h {
                vDSP_vfltu8(base + row * stride, 1, &current[row * w], 1, vDSP_Length(w))
            }
            if previous.count == n {
                vDSP_vsub(previous, 1, current, 1, &scratch, 1, vDSP_Length(n))
                vDSP_vabs(scratch, 1, &scratch, 1, vDSP_Length(n))
                var mean: Float = 0
                vDSP_meanv(scratch, 1, &mean, vDSP_Length(n))
                out.append(Sample(pts: pts, meanAbsDiff: Double(mean)))
            }
            swap(&previous, &current)
            if index % 240 == 0 { progress?(index, pts) }
            return true
        }
        return out
    }

    /// The upper envelope of the difference signal: the 90th percentile over consecutive bins of `binSeconds`.
    public static func envelope(_ samples: [Sample], binSeconds: Double = 2) -> [(t: Double, p90: Double, n: Int)] {
        guard let first = samples.first else { return [] }
        var bins: [Int: [Double]] = [:]
        for s in samples { bins[Int((s.pts - first.pts) / binSeconds), default: []].append(s.meanAbsDiff) }
        return bins.keys.sorted().map { k in
            let v = bins[k]!.sorted()
            return (first.pts + (Double(k) + 0.5) * binSeconds, v[min(v.count - 1, Int(0.9 * Double(v.count)))], v.count)
        }
    }

    /// Split the clip into runs of "slow" and "fast" content from the envelope: a bin is fast when its p90 is
    /// above `threshold` × the clip-wide median p90 (the slow section is the bulk of an exported slo-mo clip).
    /// Runs shorter than `minimumRunBins` are absorbed into their neighbours so a single busy bin does not open
    /// a section. Returns contiguous sections with `speedFactor` 1 (slow) or `fastFactor`.
    public static func sections(_ envelope: [(t: Double, p90: Double, n: Int)], threshold: Double = 2.0,
                                fastFactor: Double = 4, minimumRunBins: Int = 3, clipEnd: Double) -> [Section] {
        guard !envelope.isEmpty else { return [] }
        let sorted = envelope.map(\.p90).sorted()
        let median = sorted[sorted.count / 2]
        var fast = envelope.map { $0.p90 > threshold * median }
        // Absorb short runs.
        var i = 0
        while i < fast.count {
            var j = i
            while j < fast.count, fast[j] == fast[i] { j += 1 }
            if j - i < minimumRunBins, i > 0 || j < fast.count {
                let fill = i > 0 ? fast[i - 1] : fast[j]
                for k in i..<j { fast[k] = fill }
            }
            i = j
        }
        var out: [Section] = []
        var runStart = 0
        for k in 1...fast.count {
            if k == fast.count || fast[k] != fast[runStart] {
                let t0 = runStart == 0 ? 0 : envelope[runStart].t - (envelope[runStart].t - envelope[runStart - 1].t) / 2
                let t1 = k == fast.count ? clipEnd : envelope[k].t - (envelope[k].t - envelope[k - 1].t) / 2
                out.append(Section(start: t0, end: t1, speedFactor: fast[runStart] ? fastFactor : 1))
                runStart = k
            }
        }
        return out
    }
}
