import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Accelerate
import simd

/// One ball-sized moving blob seen by the whole-clip scan, in full-resolution pixels.
public struct RimScanCandidate: Sendable {
    public var frameIndex: Int      // absolute frame number, round(pts × fps)
    public var pts: Double          // file seconds
    public var u: Double
    public var v: Double
    public var diameterPx: Double
    public var meanDiff: Double
}

public struct RimScanOptions: Sendable {
    /// Process every n-th decoded frame. The decode itself cannot be skipped (inter-frame coding), but the
    /// pixel work can. The arrival rule keys on absolute frame indices, so skipped frames are simply empty.
    /// 0 means "choose from the clip's real frame rate" (see `processHz`).
    public var everyNthFrame: Int = 1
    /// How often the pixel work has to run, in **real** Hz, when `everyNthFrame` is 0. The arrival rule needs
    /// a ball-sized blob near the rim on a frame, another one above it within `descentLookbackFrames`, and six
    /// of them high in the frame over the preceding 1.5 s — none of which is a per-frame measurement, so a
    /// 120 fps clip does not have to be searched 120 times a second. The stride is capped at
    /// `ArrivalRuleOptions.descentLookbackFrames` (3): past that the descent test has no earlier frame to see.
    ///
    /// **Measured and not made the default** (2026-09-16). It works — on the bench clip it took the scan from
    /// 4.2 s to 2.7 s and on 130 s of the 240 fps clip from 41 s to 34 s — but it *moves the arrival frame*, by
    /// up to 4.5 file frames (37 ms of real time) on the bench clip, and the window moves with it. The release
    /// instant is quantised to the pose stride (16.7 ms of real time), so a moved window can put the release one
    /// pose frame away, and g·Δt then moves the release speed by up to 0.18 m/s — twice the 0.05 m/s parity
    /// budget. Two of the bench clip's four accepted shots moved that far. Left as a knob, off by default.
    public var processHz: Double = 60
    /// File seconds per real second (4 for a 120 fps clip written at 30), used only to turn `processHz` into a stride.
    public var timeScale: Double = 1
    /// Work resolution = full resolution ÷ this. 4 turns a 60 px ball into a 15 px blob, which is still
    /// several times the 3–4 px a connected-component test needs, and costs a sixteenth of the pixels.
    public var downscale: Int = 4
    /// Rows `0 … bandFraction·H` are always in the region of interest: that is where the arrival rule counts
    /// the ascending ball ("the upper 40 % of the frame"). The rim's own neighbourhood is added to it.
    public var bandFraction: Double = 0.40
    /// Half-height of the rim box, in ball diameters, added to the band so the arriving ball is always seen.
    public var rimBoxDiameters: Double = 3.0
    /// Ask AVFoundation for an already-scaled buffer (half the full frame) instead of scaling every frame in
    /// this process. The decode is still full-resolution — that is what the codec stores — but the box-average
    /// then reads a quarter of the bytes and lands on the identical work grid. Only used when `downscale` is
    /// even and at least 4, so the grid the candidates are measured on cannot change.
    ///
    /// **Off by default, on measurement** (2026-09-16, 130 s of the 240 fps clip, Mac): it moves work from the
    /// CPU to the decoder rather than removing it — one lane, 27.2 s decode + 14.9 s detect (42.4 s wall) plain
    /// against 35.1 s decode + 3.8 s detect (39.1 s wall) scaled; at two lanes the two are the same wall time
    /// (29.1 s against 30.4 s). It also changes the pixel values slightly (VideoToolbox's filter is not the
    /// box average this grid is defined by), so the default keeps the candidates bit-for-bit what they were.
    public var scaledDecode: Bool = false
    /// Frames of background warm-up before any candidate is emitted.
    public var warmupFrames: Int = 60
    /// The loose local threshold, as a fraction of `diffThreshold`, used only to measure the ball's size.
    public var extentThresholdFactor: Double = 0.45
    // The blob test, the same shape as `BallDetector`'s (thresholds are on the same 0–255 scale).
    public var diffThreshold: Double = 16
    public var chromaWeight: Double = 3.0
    public var orangeMargin: Double = 5
    public var minAreaFraction: Double = 0.10
    public var maxAreaFraction: Double = 6.0
    public var maxAspect: Double = 2.6
    /// At most this many blobs per frame survive (strongest difference first); a frame with more than this is
    /// noise, not a ball.
    public var maxCandidatesPerFrame: Int = 12
    /// How many segments of the clip are scanned **at the same time**, each with its own reader, background
    /// model and buffers. 0 means "choose from the machine": the decode is the floor of this pass and one
    /// reader does not saturate the decoder, so a long clip is cut into lanes and the pieces are scanned
    /// concurrently. Measured (2026-09-16, 130 s of the 240 fps clip, Mac): 42.0 s at one lane, 31.5 s at two,
    /// 30.0 s at three — so two, because a third buys 5 % and a phone that is already seeing
    /// `AVFoundationErrorDomain -11847` under one reader should not be given three. Each lane pre-rolls over `laneOverlapRealSeconds` of the previous lane's frames so its
    /// background is warm and the arrival rule's 1.5 s lookback is never truncated at a seam; candidates in
    /// the pre-roll are dropped, so a frame is owned by exactly one lane and never counted twice.
    public var lanes: Int = 0
    /// How far back a lane pre-rolls before the frames it owns, in **real** seconds. It has to cover the
    /// arrival rule's `highLookbackRealSeconds` (1.5) plus the background warm-up.
    public var laneOverlapRealSeconds: Double = 2.0
    /// A lane is only worth its own reader if it has at least this much **file** time to scan.
    public var minimumLaneSeconds: Double = 20
    public var startTime: Double = 0
    public var endTime: Double? = nil
    public init() {}
}

public struct RimScanResult: Sendable {
    public var candidates: [RimScanCandidate]
    public var framesDecoded: Int
    public var framesProcessed: Int
    public var measuredFrameRate: Double
    public var width: Int
    public var height: Int
    public var roiBottomPx: Int
    public var workWidth: Int
    public var workHeight: Int
    public var notes: [String]
}

/// The whole-clip pass that says **where the shots are**, without Vision.
///
/// `DetectTrajectoriesRequest` over a whole clip costs about 5 ms a frame — 37 s for a 7 500-frame segment on
/// a Mac, minutes on a phone — and the arrival rule it feeds does not need trajectories at all. It needs
/// ball-sized moving blobs near the rim and in the upper part of the frame. So this decodes the clip once and,
/// on a downscaled crop of exactly those rows, keeps a per-pixel background (a sigma-delta estimator, which
/// converges to the running median at one grey level per frame) and reports the round, orange, moving blobs.
///
/// Nothing is measured here and nothing is interpolated: a frame with no blob produces no candidate. The
/// arrival rule (`SessionScanner.arrivals`) is unchanged and runs on these candidates exactly as it ran on
/// Vision's.
public enum RimArrivalScanner {
    /// The whole clip, in as many concurrent lanes as `RimScanOptions.lanes` asks for. One lane is exactly the
    /// single pass this always was; more than one cuts the clip into pieces, gives each its own reader and
    /// background model, and merges the candidates. A frame belongs to exactly one lane.
    public static func scan(url: URL,
                            rimCenter: SIMD2<Double>,
                            ballDiameterPx: Double,
                            options: RimScanOptions = .init(),
                            timings: StageTimings? = nil,
                            progress: (@Sendable (Int, Double) -> Void)? = nil) async throws -> RimScanResult
    {
        let probe = try await VideoReader(url: url).quickProbe(maxFrames: 90)
        let fps = probe.measuredFrameRate
        guard probe.width > 0, probe.height > 0, fps > 0 else {
            return try await scanSegment(url: url, rimCenter: rimCenter, ballDiameterPx: ballDiameterPx,
                                         options: options, probe: probe, emitFrom: nil, timings: timings, progress: progress)
        }
        let clipEnd = min(options.endTime ?? probe.trackDuration, probe.trackDuration)
        let span = clipEnd - options.startTime
        var lanes = options.lanes
        if lanes <= 0 {
            // The decode is the floor and one reader does not saturate the decoder. Two lanes on any machine,
            // three when there are cores to spare — past that the decoder, not the CPU, is the limit.
            // A hot phone gets one reader. The lanes are worth ~28 % of the scan when there are cores and a
            // decoder to spare and nothing when there are not, and a second `AVAssetReader` is exactly the kind
            // of pressure that produces `AVFoundationErrorDomain -11847`. The candidate list is identical either
            // way (verified on both clips), so this can be decided on the machine's state without touching the
            // measurement.
            let thermal = ProcessInfo.processInfo.thermalState
            lanes = (thermal == .serious || thermal == .critical) ? 1 : 2
        }
        lanes = max(1, min(lanes, Int(span / max(1, options.minimumLaneSeconds))))
        guard lanes > 1 else {
            return try await scanSegment(url: url, rimCenter: rimCenter, ballDiameterPx: ballDiameterPx,
                                         options: options, probe: probe, emitFrom: nil, timings: timings, progress: progress)
        }
        let overlap = options.laneOverlapRealSeconds * max(1, options.timeScale)
        let piece = span / Double(lanes)
        let done = Counter()
        // Roughly how many frames the whole scan will decode, so the progress callback can report a fraction
        // of the clip rather than one lane's position in it.
        let expectedFrames = span * fps + Double(lanes - 1) * overlap * fps
        var results: [RimScanResult] = try await withThrowingTaskGroup(of: (Int, RimScanResult).self) { group in
            for i in 0..<lanes {
                let owns = options.startTime + Double(i) * piece
                let ownsEnd = i == lanes - 1 ? clipEnd : options.startTime + Double(i + 1) * piece
                var o = options
                o.startTime = max(options.startTime, owns - (i == 0 ? 0 : overlap))
                o.endTime = ownsEnd
                let emitFrom: Double? = i == 0 ? nil : owns
                group.addTask {
                    (i, try await scanSegment(url: url, rimCenter: rimCenter, ballDiameterPx: ballDiameterPx,
                                              options: o, probe: probe, emitFrom: emitFrom, timings: timings) { n, _ in
                        // The lanes are at different points in the clip, so one lane's timestamp is not progress.
                        // Report the clip-wide frame total and the time it corresponds to, which only goes up.
                        let total = done.report(lane: i, frames: n)
                        let fraction = expectedFrames > 0 ? min(1, Double(total) / expectedFrames) : 0
                        progress?(total, options.startTime + fraction * span)
                    })
                }
            }
            var out: [(Int, RimScanResult)] = []
            for try await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard var merged = results.first else { throw VideoReaderError.noVideoTrack }
        for r in results.dropFirst() {
            merged.candidates.append(contentsOf: r.candidates)
            merged.framesDecoded += r.framesDecoded
            merged.framesProcessed += r.framesProcessed
        }
        merged.candidates.sort { $0.frameIndex < $1.frameIndex }
        // Lane 0's own per-lane counts would read as the clip's; replace that line with the merged totals.
        merged.notes.removeAll { $0.hasPrefix("\(results[0].framesDecoded) frames decoded") }
        merged.notes.append(String(format: "scanned in %d concurrent lanes, each pre-rolling %.1f s of file time: %d frames decoded, %d processed, %d candidates",
                                   lanes, overlap, merged.framesDecoded, merged.framesProcessed, merged.candidates.count))
        results.removeAll()
        return merged
    }

    /// One contiguous piece of the clip, scanned by one reader. `emitFrom` drops the candidates of the pre-roll,
    /// so the lane that owns those frames is the only one that reports them.
    static func scanSegment(url: URL,
                            rimCenter: SIMD2<Double>,
                            ballDiameterPx: Double,
                            options: RimScanOptions = .init(),
                            probe: VideoProbeResult,
                            emitFrom: Double?,
                            timings: StageTimings? = nil,
                            progress: (@Sendable (Int, Double) -> Void)? = nil) async throws -> RimScanResult
    {
        let reader = VideoReader(url: url)
        let fps = probe.measuredFrameRate
        let W = probe.width, H = probe.height
        guard W > 0, H > 0, fps > 0 else {
            return RimScanResult(candidates: [], framesDecoded: 0, framesProcessed: 0, measuredFrameRate: fps,
                                 width: W, height: H, roiBottomPx: 0, workWidth: 0, workHeight: 0,
                                 notes: ["the clip's first frames could not be decoded"])
        }
        let ds = max(1, options.downscale)
        // Rows to look at: the descent band plus the rim's neighbourhood, rounded up to whole work pixels.
        let wanted = max(options.bandFraction * Double(H), rimCenter.y + options.rimBoxDiameters * ballDiameterPx)
        var roiBottom = min(H, Int(wanted.rounded(.up)))
        roiBottom = min(H, ((roiBottom + ds - 1) / ds) * ds)
        let ww = W / ds, wh = max(1, roiBottom / ds)
        let n = ww * wh

        var timeRange: CMTimeRange? = nil
        if options.startTime > 0 || options.endTime != nil {
            let s = CMTime(seconds: options.startTime, preferredTimescale: 600)
            let e = options.endTime.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .positiveInfinity
            timeRange = CMTimeRange(start: s, end: e)
        }

        // Every buffer the loop needs, allocated once. Nothing inside the frame body allocates.
        var yw = [UInt8](repeating: 0, count: n)
        var crw = [UInt8](repeating: 0, count: n)
        var fy = [Float](repeating: 0, count: n)
        var fc = [Float](repeating: 0, count: n)
        var bgY = [Float](repeating: 0, count: n)
        var bgCr = [Float](repeating: 0, count: n)
        var dY = [Float](repeating: 0, count: n)
        var dC = [Float](repeating: 0, count: n)
        var diff = [Float](repeating: 0, count: n)
        var scratch = [Float](repeating: 0, count: n)          // vDSP working space for the difference
        var boxScratch = [Float](repeating: 0, count: 2 * W + ww)  // vDSP working space for the box average
        var mask = [UInt8](repeating: 0, count: n)
        var visited = [UInt8](repeating: 0, count: n)
        var stack = [Int32](repeating: 0, count: n)
        var blobPixels = [Int32](repeating: 0, count: n)
        // Scratch for the loose local re-threshold that measures the ball's size (below).
        var localVisited = [UInt8](repeating: 0, count: n)
        var localStack = [Int32](repeating: 0, count: n)
        var localTouched = [Int32](repeating: 0, count: n)

        let Dw = max(3.0, ballDiameterPx / Double(ds))
        let expArea = Double.pi * Dw * Dw / 4
        let minArea = options.minAreaFraction * expArea, maxArea = options.maxAreaFraction * expArea
        let cw = Float(options.chromaWeight), thr = Float(options.diffThreshold)
        let looseThr = Float(options.extentThresholdFactor) * thr
        let extentRadius = max(2, Int((1.5 * Dw).rounded()))
        let om = Float(options.orangeMargin.rounded())
        // The stride: whatever the caller asked for, else the one that keeps the pixel work at `processHz`
        // of real time. Never more than the arrival rule's descent lookback, which is what needs a previous
        // processed frame to exist.
        let step: Int
        if options.everyNthFrame > 0 { step = options.everyNthFrame }
        else {
            let realFPS = fps * (options.timeScale > 0 ? options.timeScale : 1)
            step = max(1, min(ArrivalRuleOptions().descentLookbackFrames, Int((realFPS / max(1, options.processHz)).rounded())))
        }

        var out: [RimScanCandidate] = []
        out.reserveCapacity(4096)
        var decoded = 0, processed = 0, warmed = 0
        var detectSeconds = 0.0
        let loopStart = StageTimings.now()

        // The decoder can hand back a half-size frame; the box-average then reads a quarter of the bytes.
        let decodeDivisor = (options.scaledDecode && ds >= 4 && ds % 2 == 0) ? ds / 2 : 1
        let outputSize: (width: Int, height: Int)? = decodeDivisor > 1 ? (W / decodeDivisor, H / decodeDivisor) : nil
        try await reader.forEachPixelBuffer(timeRange: timeRange, outputSize: outputSize) { _, pts, pb in
            if decoded % 64 == 0 { try Task.checkCancellation() }
            defer { decoded += 1 }
            if let e = options.endTime, pts > e { return false }
            guard decoded % step == 0 else { return true }
            let t0 = StageTimings.now()
            defer { detectSeconds += StageTimings.now() - t0 }
            processed += 1

            downsample(pb, ds: ds, workWidth: ww, workHeight: wh, scratch: &boxScratch, y: &yw, cr: &crw)
            vDSP_vfltu8(yw, 1, &fy, 1, vDSP_Length(n))
            vDSP_vfltu8(crw, 1, &fc, 1, vDSP_Length(n))

            if warmed == 0 {
                bgY = fy; bgCr = fc
                warmed = 1
                return true
            }
            // Sigma-delta background: one grey level per processed frame towards the observation. It converges
            // to the per-pixel median, adapts to light, and cannot be dragged by a ball that crosses in 4 frames.
            // |Y − bgY| + w·|Cr − bgCr|, and the mask, in vDSP: the same arithmetic as `CandidateFinder`,
            // but as library calls, so it is vectorised in a debug build too.
            var hits = 0
            vDSP_vsub(bgY, 1, fy, 1, &dY, 1, vDSP_Length(n))          // dY = Y − bgY
            vDSP_vsub(bgCr, 1, fc, 1, &dC, 1, vDSP_Length(n))         // dC = Cr − bgCr
            vDSP_vabs(dY, 1, &diff, 1, vDSP_Length(n))
            vDSP_vabs(dC, 1, &scratch, 1, vDSP_Length(n))
            var weight = cw
            vDSP_vsma(scratch, 1, &weight, diff, 1, &diff, 1, vDSP_Length(n))
            diff.withUnsafeBufferPointer { df in dC.withUnsafeBufferPointer { dc in
                mask.withUnsafeMutableBufferPointer { mk in
                    let fom = Float(om)
                    for i in 0..<n {
                        let on: UInt8 = (df[i] >= thr && dc[i] > fom) ? 1 : 0
                        mk[i] = on
                        hits += Int(on)
                    }
                }
            } }
            // Sigma-delta: bg moves one grey level towards the observation. The differences are whole numbers,
            // so clipping them to [−1, 1] *is* their sign.
            var lo: Float = -1, hi: Float = 1
            vDSP_vclip(dY, 1, &lo, &hi, &scratch, 1, vDSP_Length(n))
            vDSP_vadd(bgY, 1, scratch, 1, &bgY, 1, vDSP_Length(n))
            vDSP_vclip(dC, 1, &lo, &hi, &scratch, 1, vDSP_Length(n))
            vDSP_vadd(bgCr, 1, scratch, 1, &bgCr, 1, vDSP_Length(n))
            warmed += 1
            guard warmed > options.warmupFrames else { return true }
            // A mask covering a fifth of the region is camera shake or a crowd, not a ball: nothing to link.
            guard hits > 0, hits < n / 5 else { return true }

            let index = Int((pts * fps).rounded())
            var found = 0
            for i in 0..<n where mask[i] == 1 && visited[i] == 0 {
                var sp = 0
                stack[sp] = Int32(i); sp += 1; visited[i] = 1
                var count = 0
                var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
                while sp > 0 {
                    sp -= 1
                    let q = Int(stack[sp])
                    blobPixels[count] = Int32(q); count += 1
                    let qx = q % ww, qy = q / ww
                    if qx < minX { minX = qx }; if qx > maxX { maxX = qx }
                    if qy < minY { minY = qy }; if qy > maxY { maxY = qy }
                    if qx > 0, mask[q - 1] == 1, visited[q - 1] == 0 { visited[q - 1] = 1; stack[sp] = Int32(q - 1); sp += 1 }
                    if qx < ww - 1, mask[q + 1] == 1, visited[q + 1] == 0 { visited[q + 1] = 1; stack[sp] = Int32(q + 1); sp += 1 }
                    if qy > 0, mask[q - ww] == 1, visited[q - ww] == 0 { visited[q - ww] = 1; stack[sp] = Int32(q - ww); sp += 1 }
                    if qy < wh - 1, mask[q + ww] == 1, visited[q + ww] == 0 { visited[q + ww] = 1; stack[sp] = Int32(q + ww); sp += 1 }
                }
                let area = Double(count)
                guard area >= minArea, area <= maxArea else { continue }
                let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
                guard max(bw, bh) / max(1, min(bw, bh)) <= options.maxAspect else { continue }
                var sw = 0.0, su = 0.0, sv = 0.0, sd = 0.0
                for j in 0..<count {
                    let q = Int(blobPixels[j])
                    let d = Double(diff[q]); let w = d * d
                    sw += w; su += w * Double(q % ww); sv += w * Double(q / ww); sd += d
                }
                guard sw > 0 else { continue }
                let mu = su / sw, mv = sv / sw
                // Size. The strict mask is the *lit, orange* part of the ball, so its bounding box under-reads the
                // diameter by about half — and the arrival rule gates on diameter. Re-segment locally at a loose
                // threshold with no orange gate (what `BallDetector`'s `looseComponent` does) so the dark side counts.
                var extent = min(bw, bh)
                let cx = Int(mu), cy = Int(mv)
                let lx0 = max(0, cx - extentRadius), lx1 = min(ww - 1, cx + extentRadius)
                let ly0 = max(0, cy - extentRadius), ly1 = min(wh - 1, cy + extentRadius)
                if lx1 > lx0, ly1 > ly0 {
                    var sp2 = 0, touched = 0, larea = 0
                    var lminX = Int.max, lmaxX = Int.min, lminY = Int.max, lmaxY = Int.min
                    let seed = cy * ww + cx
                    if diff[seed] >= looseThr {
                        localStack[sp2] = Int32(seed); sp2 += 1
                        localVisited[seed] = 1; localTouched[touched] = Int32(seed); touched += 1
                    }
                    while sp2 > 0 {
                        sp2 -= 1
                        let q = Int(localStack[sp2])
                        larea += 1
                        let qx = q % ww, qy = q / ww
                        if qx < lminX { lminX = qx }; if qx > lmaxX { lmaxX = qx }
                        if qy < lminY { lminY = qy }; if qy > lmaxY { lmaxY = qy }
                        if qx > lx0, diff[q - 1] >= looseThr, localVisited[q - 1] == 0 {
                            localVisited[q - 1] = 1; localTouched[touched] = Int32(q - 1); touched += 1
                            localStack[sp2] = Int32(q - 1); sp2 += 1
                        }
                        if qx < lx1, diff[q + 1] >= looseThr, localVisited[q + 1] == 0 {
                            localVisited[q + 1] = 1; localTouched[touched] = Int32(q + 1); touched += 1
                            localStack[sp2] = Int32(q + 1); sp2 += 1
                        }
                        if qy > ly0, diff[q - ww] >= looseThr, localVisited[q - ww] == 0 {
                            localVisited[q - ww] = 1; localTouched[touched] = Int32(q - ww); touched += 1
                            localStack[sp2] = Int32(q - ww); sp2 += 1
                        }
                        if qy < ly1, diff[q + ww] >= looseThr, localVisited[q + ww] == 0 {
                            localVisited[q + ww] = 1; localTouched[touched] = Int32(q + ww); touched += 1
                            localStack[sp2] = Int32(q + ww); sp2 += 1
                        }
                    }
                    for j in 0..<touched { localVisited[Int(localTouched[j])] = 0 }
                    if larea > 0, Double(larea) <= 6 * expArea {
                        let lw = Double(lmaxX - lminX + 1), lh = Double(lmaxY - lminY + 1)
                        // The smaller side: motion smear stretches the other one.
                        extent = min(max(min(lw, lh), min(bw, bh)), 2.2 * Dw)
                    }
                }
                if emitFrom.map({ pts >= $0 }) ?? true {
                    out.append(RimScanCandidate(frameIndex: index, pts: pts,
                                                u: (mu + 0.5) * Double(ds), v: (mv + 0.5) * Double(ds),
                                                diameterPx: extent * Double(ds), meanDiff: sd / area))
                }
                found += 1
                if found >= options.maxCandidatesPerFrame { break }
            }
            // `visited` is the only buffer that has to be cleared, and only where the mask was set.
            for i in 0..<n where mask[i] == 1 { visited[i] = 0 }
            if processed % 240 == 0 { progress?(decoded, pts) }
            return true
        }
        let loopSeconds = StageTimings.now() - loopStart
        timings?.add("scan.decode", max(0, loopSeconds - detectSeconds), count: decoded)
        timings?.add("scan.detect", detectSeconds, count: processed)
        var notes: [String] = []
        notes.append(String(format: "fast scan: rows 0–%d px of %d at 1/%d resolution (%d×%d), ball ≈ %.1f work px, every %d%@ frame%@",
                            roiBottom, H, ds, ww, wh, Dw, step, step == 1 ? "" : "nd",
                            decodeDivisor > 1 ? String(format: ", decoded at 1/%d (%dx%d)", decodeDivisor, W / decodeDivisor, H / decodeDivisor) : ""))
        notes.append(String(format: "%d frames decoded, %d processed, %d candidates (%.0f fps decode, %.0f fps detect)",
                            decoded, processed, out.count,
                            loopSeconds > 0 ? Double(decoded) / loopSeconds : 0,
                            detectSeconds > 0 ? Double(processed) / detectSeconds : 0))
        return RimScanResult(candidates: out, framesDecoded: decoded, framesProcessed: processed,
                             measuredFrameRate: fps, width: W, height: H, roiBottomPx: roiBottom,
                             workWidth: ww, workHeight: wh, notes: notes)
    }

    /// Box-average the top `workHeight·ds` rows of a 4:2:0 bi-planar frame into `y` and `cr` at 1/`ds` scale.
    /// Luma averages `ds×ds` source pixels; the chroma plane is already half-resolution, so it averages
    /// `(ds/2)×(ds/2)`. Only the rows the region of interest needs are read, and the summing is vDSP, so a debug
    /// build is not an order of magnitude slower than a release one.
    /// The block factor is taken from the buffer that actually arrived, not from `downscale`, so a
    /// hardware-scaled decode (`RimScanOptions.scaledDecode`) lands on exactly the same work grid.
    static func downsample(_ pb: CVPixelBuffer, ds: Int, workWidth ww: Int, workHeight wh: Int,
                           scratch: inout [Float], y: inout [UInt8], cr: inout [UInt8])
    {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return }
        let lumaBlock = max(1, CVPixelBufferGetWidthOfPlane(pb, 0) / max(1, ww))
        boxRows(base: yBase, stride: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                rows: CVPixelBufferGetHeightOfPlane(pb, 0), block: lumaBlock, sampleStride: 1,
                workWidth: ww, workHeight: wh, scratch: &scratch, out: &y)
        guard CVPixelBufferGetPlaneCount(pb) > 1,
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) else { return }
        // The chroma plane is already half-resolution and interleaved Cb, Cr: start at the first Cr byte and step two.
        let chromaBlock = max(1, CVPixelBufferGetWidthOfPlane(pb, 1) / max(1, ww))
        boxRows(base: cBase + 1, stride: CVPixelBufferGetBytesPerRowOfPlane(pb, 1),
                rows: CVPixelBufferGetHeightOfPlane(pb, 1), block: chromaBlock, sampleStride: 2,
                workWidth: ww, workHeight: wh, scratch: &scratch, out: &cr)
    }

    /// One plane, box-averaged by `block` in both directions into a `workWidth × workHeight` byte image.
    /// `sampleStride` is 1 for a planar source and 2 for one channel of an interleaved pair.
    static func boxRows(base: UnsafePointer<UInt8>, stride: Int, rows: Int, block: Int, sampleStride: Int,
                        workWidth ww: Int, workHeight wh: Int, scratch: inout [Float], out: inout [UInt8])
    {
        let sourceWidth = ww * block
        let need = 2 * sourceWidth + ww
        if scratch.count < need { scratch = [Float](repeating: 0, count: need) }
        let n = vDSP_Length(sourceWidth), w = vDSP_Length(ww), step = vDSP_Stride(block)
        var scale = 1 / Float(block * block)
        scratch.withUnsafeMutableBufferPointer { sp in
            let acc = sp.baseAddress!
            let tmp = acc + sourceWidth
            let row = tmp + sourceWidth
            out.withUnsafeMutableBufferPointer { op in
                guard let dst = op.baseAddress else { return }
                for oy in 0..<wh {
                    var used = 0
                    for k in 0..<block {
                        let sy = oy * block + k
                        guard sy < rows else { break }
                        let src = base + sy * stride
                        if used == 0 {
                            vDSP_vfltu8(src, vDSP_Stride(sampleStride), acc, 1, n)
                        } else {
                            vDSP_vfltu8(src, vDSP_Stride(sampleStride), tmp, 1, n)
                            vDSP_vadd(acc, 1, tmp, 1, acc, 1, n)
                        }
                        used += 1
                    }
                    guard used > 0 else { continue }
                    if block == 1 {
                        cblas_scopy(Int32(ww), acc, 1, row, 1)
                    } else {
                        vDSP_vadd(acc, step, acc + 1, step, row, 1, w)
                        if block > 2 { for j in 2..<block { vDSP_vadd(row, 1, acc + j, step, row, 1, w) } }
                    }
                    vDSP_vsmul(row, 1, &scale, row, 1, w)
                    vDSP_vfixru8(row, 1, dst + oy * ww, 1, w)          // truncating, exactly like sum / (block·block)
                }
            }
        }
    }
}

/// The scan's lanes each count their own decoded frames; this keeps the latest count per lane so the progress
/// callback can report the clip-wide total rather than one lane's share of it.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var byLane: [Int: Int] = [:]
    func report(lane: Int, frames: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        byLane[lane] = frames
        return byLane.values.reduce(0, +)
    }
}
