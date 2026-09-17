import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo

/// What a clip actually is, measured from its decoded samples — never from `nominalFrameRate` alone.
public struct VideoProbeResult: Sendable, Codable {
    public var url: String
    public var width: Int
    public var height: Int
    public var codec: String
    public var nominalFrameRate: Double     // from the track header; wrong for slo-mo edit lists
    public var trackDuration: Double        // seconds, from the track
    public var decodedFrames: Int
    public var firstPTS: Double
    public var lastPTS: Double
    public var measuredFrameRate: Double    // (decodedFrames - 1) / (lastPTS - firstPTS)
    public var medianFrameInterval: Double  // seconds
    public var maxFrameInterval: Double
    public var minFrameInterval: Double
    public var intervalJitterPercent: Double // (max - min) / median * 100
    public var droppedFrameGaps: Int        // intervals > 1.5 × median
    public var transformIsIdentity: Bool
    public var naturalTimeScale: Int
    public var minFrameDuration: Double        // seconds, from the track header
    public var editSegments: [String]          // "source a→b (dur) maps to target c→d (dur)"; slo-mo shows source ≠ target
    public var sloMoStretch: Double            // target duration / source duration over all segments (1 = real time; 8 = 240 fps slowed to 30)
    public var preferredTransformDescription: String
    public var notes: [String]
}

public enum VideoReaderError: Error, CustomStringConvertible {
    case noVideoTrack
    case cannotStartReading(String)
    public var description: String {
        switch self {
        case .noVideoTrack: return "the file has no video track"
        case .cannotStartReading(let s): return "AVAssetReader could not start: \(s)"
        }
    }
}

/// One decoded frame with its real presentation timestamp.
public struct DecodedFrame: @unchecked Sendable {
    public let index: Int
    public let pts: Double
    public let sampleBuffer: CMSampleBuffer
    public var pixelBuffer: CVPixelBuffer? { CMSampleBufferGetImageBuffer(sampleBuffer) }
}

public struct VideoReader: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    /// Builds a reader on the first video track, decoding to 4:2:0 biplanar (Apple's stated optimal format).
    /// `timeRange` restricts decoding; nil reads the whole track.
    /// `passthrough` hands over the compressed samples (timestamps only, no decode) — for probing.
    public func makeReader(timeRange: CMTimeRange? = nil, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                           passthrough: Bool = false, outputSize: (width: Int, height: Int)? = nil)
        async throws -> (AVAssetReader, AVAssetReaderTrackOutput, AVAssetTrack)
    {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoReaderError.noVideoTrack }
        let reader = try AVAssetReader(asset: asset)
        // `outputSize` asks AVFoundation to hand back an already-scaled buffer. The decode itself is still
        // full-resolution (that is what the codec stores), but the scaling runs in VideoToolbox rather than in
        // this process, and every downstream pass then touches a sixteenth of the bytes.
        var settings: [String: Any]? = passthrough ? nil : [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        if !passthrough, let outputSize, outputSize.width > 1, outputSize.height > 1 {
            settings?[kCVPixelBufferWidthKey as String] = outputSize.width
            settings?[kCVPixelBufferHeightKey as String] = outputSize.height
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        // Do not call reader.add(output): outputProvider(for:) adds it and must run before startReading().
        if let timeRange { reader.timeRange = timeRange }
        return (reader, output, track)
    }

    /// Iterate every decoded frame in presentation order with its PTS. Stops early if `body` returns false.
    /// `stride` > 1 hands over only every n-th frame (counted from the first in `timeRange`). The decode cannot
    /// be skipped — that is what inter-frame coding means — but the **re-wrap** can, and that is a format
    /// description and a `CMSampleBuffer` per frame that a caller sampling every 2nd or 3rd frame was paying for
    /// nothing. The frames handed over are exactly the ones a caller counting `index % stride == 0` itself saw.
    public func forEachFrame(timeRange: CMTimeRange? = nil, stride: Int = 1,
                             _ body: (DecodedFrame) async throws -> Bool) async throws {
        let (reader, output, _) = try await makeReader(timeRange: timeRange)
        let provider = reader.outputProvider(for: output)   // must precede startReading()
        guard reader.startReading() else {
            throw VideoReaderError.cannotStartReading(reader.error?.localizedDescription ?? "unknown")
        }
        var index = 0
        let step = max(1, stride)
        let box = RewrapBox()
        while let ready = try await provider.next() {
            if index % step != 0 { index += 1; continue }
            let pts = ready.presentationTimeStamp.seconds
            // The provider's buffer must not escape its closure, but Vision's stateful requests are async and
            // need timing, so re-wrap the (independently retained) pixel buffer with the original timing.
            ready.withUnsafeSampleBuffer { sb in box.rewrap(sb) }
            guard let sb = box.buffer else { index += 1; continue }
            let keepGoing = try await body(DecodedFrame(index: index, pts: pts, sampleBuffer: sb))
            index += 1
            if !keepGoing { reader.cancelReading(); return }
        }
        if reader.status == .failed { throw VideoReaderError.cannotStartReading(reader.error?.localizedDescription ?? "failed mid-stream") }
    }

    /// Iterate every decoded frame's **pixel buffer** in presentation order, without re-wrapping it in a fresh
    /// `CMSampleBuffer`. `forEachFrame` has to re-wrap (Vision's stateful requests are async and need the timing),
    /// and that costs a format description and a sample buffer per frame — pure waste for a synchronous consumer
    /// that only reads pixels. The buffer is valid only for the duration of `body` and must not escape it.
    /// Returns false from `body` to stop early.
    public func forEachPixelBuffer(timeRange: CMTimeRange? = nil, outputSize: (width: Int, height: Int)? = nil,
                                   _ body: (_ index: Int, _ pts: Double, _ pixelBuffer: CVPixelBuffer) throws -> Bool) async throws {
        let (reader, output, _) = try await makeReader(timeRange: timeRange, outputSize: outputSize)
        let provider = reader.outputProvider(for: output)   // must precede startReading()
        guard reader.startReading() else {
            throw VideoReaderError.cannotStartReading(reader.error?.localizedDescription ?? "unknown")
        }
        var index = 0
        var stop = false
        var thrown: (any Error)? = nil
        while let ready = try await provider.next() {
            let pts = ready.presentationTimeStamp.seconds
            ready.withUnsafeSampleBuffer { sb in
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
                do { stop = !(try body(index, pts, pb)) } catch { thrown = error; stop = true }
            }
            index += 1
            if let thrown { reader.cancelReading(); throw thrown }
            if stop { reader.cancelReading(); return }
        }
        if reader.status == .failed { throw VideoReaderError.cannotStartReading(reader.error?.localizedDescription ?? "failed mid-stream") }
    }

    /// Fast probe for windowed work: decodes only the first `maxFrames` frames (dimensions, codec, measured rate, edit list).
    /// A full `probe()` is still the authority on frame count, drops and jitter across the whole clip.
    public func quickProbe(maxFrames: Int = 120) async throws -> VideoProbeResult {
        var full = try await probe(maxFrames: maxFrames)
        full.notes.append("quick probe: only the first \(maxFrames) frames were decoded; frame count, drops and jitter are not clip-wide")
        return full
    }

    /// Decode the whole clip once and report what it really is.
    public func probe() async throws -> VideoProbeResult { try await probe(maxFrames: nil) }

    func probe(maxFrames: Int?) async throws -> VideoProbeResult {
        // Passthrough: the probe only needs every sample's presentation timestamp, so the reader hands
        // over the *compressed* samples (`outputSettings: nil`) and never decodes a pixel. A 7-minute
        // 120 fps clip probed in 93 s on the phone when it decoded; the timestamps alone take ~1 s.
        let (reader, output, track) = try await makeReader(passthrough: true)
        let size = try await track.load(.naturalSize)
        let nominal = try await track.load(.nominalFrameRate)
        let duration = try await track.load(.timeRange).duration.seconds
        let transform = try await track.load(.preferredTransform)
        let descs = try await track.load(.formatDescriptions)
        let timescale = try await track.load(.naturalTimeScale)
        let minDur = try await track.load(.minFrameDuration).seconds
        let segments = try await track.load(.segments)
        var segDesc: [String] = []
        var srcTotal = 0.0, tgtTotal = 0.0
        for sg in segments {
            let m = sg.timeMapping
            segDesc.append(String(format: "source %.3f→%.3f (%.3f s) maps to target %.3f→%.3f (%.3f s)%@",
                                  m.source.start.seconds, m.source.end.seconds, m.source.duration.seconds,
                                  m.target.start.seconds, m.target.end.seconds, m.target.duration.seconds, sg.isEmpty ? " [empty]" : ""))
            if !sg.isEmpty { srcTotal += m.source.duration.seconds; tgtTotal += m.target.duration.seconds }
        }
        let stretch = srcTotal > 0 ? tgtTotal / srcTotal : 1
        let codec = descs.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
        let provider = reader.outputProvider(for: output)   // must precede startReading()
        guard reader.startReading() else {
            throw VideoReaderError.cannotStartReading(reader.error?.localizedDescription ?? "unknown")
        }
        var pts: [Double] = []
        pts.reserveCapacity(4096)
        while let ready = try await provider.next() {
            // A passthrough read can hand over samples with no valid presentation time (e.g. a
            // trailing non-displayed sample); those are not frames and are not counted.
            let t = ready.presentationTimeStamp
            if t.isValid && !t.isIndefinite && t.seconds.isFinite { pts.append(t.seconds) }
            if let m = maxFrames, pts.count >= m { reader.cancelReading(); break }
        }
        // Compressed samples arrive in decode order, which for a codec with B-frames is not presentation
        // order; the statistics below are about presentation time, so sort first.
        pts.sort()
        // Two samples at the same presentation time are one frame (an edit-list boundary can list a
        // sample twice); the decoding path shows one frame there, so this path counts one too.
        var dedup: [Double] = []
        dedup.reserveCapacity(pts.count)
        for t in pts where dedup.last.map({ t - $0 > 1e-6 }) ?? true { dedup.append(t) }
        pts = dedup
        var notes: [String] = []
        let n = pts.count
        var intervals: [Double] = []
        if n >= 2 { for i in 1..<n { intervals.append(pts[i] - pts[i - 1]) } }
        let sorted = intervals.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let maxI = sorted.last ?? 0, minI = sorted.first ?? 0
        let measured = (n >= 2 && pts[n - 1] > pts[0]) ? Double(n - 1) / (pts[n - 1] - pts[0]) : 0
        let jitter = median > 0 ? (maxI - minI) / median * 100 : 0
        let gaps = intervals.filter { $0 > 1.5 * median }.count
        if n == 0 { notes.append("no frames decoded") }
        if nominal > 0, measured > 0, abs(measured / Double(nominal) - 1) > 0.05 {
            notes.append(String(format: "nominal %.2f fps but measured %.2f fps: slo-mo edit list or re-encode; trust measured", nominal, measured))
        }
        if jitter > 5 { notes.append(String(format: "frame interval jitter %.1f%%: variable frame rate; use per-frame PTS, never k/fps", jitter)) }
        if gaps > 0 { notes.append("\(gaps) interval(s) > 1.5× median: dropped frames") }
        if !transform.isIdentity { notes.append("preferredTransform is not identity: rotate pixel coordinates before use") }
        if abs(stretch - 1) > 0.01 { notes.append(String(format: "edit list stretches time by %.2f×: slo-mo file; real frame rate ≈ %.1f fps; divide decoded PTS by %.2f", stretch, measured * stretch, stretch)) }
        return VideoProbeResult(
            url: url.path, width: Int(size.width), height: Int(size.height), codec: codec,
            nominalFrameRate: Double(nominal), trackDuration: duration, decodedFrames: n,
            firstPTS: pts.first ?? 0, lastPTS: pts.last ?? 0, measuredFrameRate: measured,
            medianFrameInterval: median, maxFrameInterval: maxI, minFrameInterval: minI,
            intervalJitterPercent: jitter, droppedFrameGaps: gaps,
            transformIsIdentity: transform.isIdentity, naturalTimeScale: Int(timescale), minFrameDuration: minDur,
            editSegments: segDesc, sloMoStretch: stretch,
            preferredTransformDescription: "[a \(transform.a) b \(transform.b) c \(transform.c) d \(transform.d) tx \(transform.tx) ty \(transform.ty)]",
            notes: notes)
    }
}

/// Holds the re-wrapped buffer across the non-escaping `withUnsafeSampleBuffer` boundary.
///
/// The format description is cached: every frame of a clip has the same one, and building it per frame was a
/// dictionary construction and a `CMFormatDescription` allocation on every decoded frame. `CMVideoFormatDescription`
/// carries the buffer's dimensions and pixel format, so the cache is keyed on those and rebuilt if either changes.
final class RewrapBox: @unchecked Sendable {
    var buffer: CMSampleBuffer?
    private var cachedFD: CMVideoFormatDescription?
    private var cachedShape: (Int, Int, OSType) = (0, 0, 0)
    func rewrap(_ sb: CMSampleBuffer) {
        buffer = nil
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sb, at: 0, timingInfoOut: &timing)
        let shape = (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), CVPixelBufferGetPixelFormatType(pb))
        var fd: CMVideoFormatDescription? = (shape == cachedShape) ? cachedFD : nil
        if fd == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
            cachedFD = fd; cachedShape = shape
        }
        guard let fd else { return }
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd,
                                                 sampleTiming: &timing, sampleBufferOut: &out)
        buffer = out
    }
}

func fourCC(_ code: FourCharCode) -> String {
    let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? String(code)
}
