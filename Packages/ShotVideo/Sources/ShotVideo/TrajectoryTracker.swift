import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import Vision
import ShotGeometry

/// Everything Vision said about one trajectory on one frame. Kept raw so nothing is lost before evaluation.
public struct TrajectoryFrameRecord: Sendable, Codable {
    public var frameIndex: Int
    public var pts: Double
    public var uuid: String
    public var confidence: Float
    public var timeRangeStart: Double?
    public var timeRangeDuration: Double?
    public var movingAverageRadiusPx: Double     // Vision's normalized radius × image width
    public var detectedCount: Int
    public var lastDetectedPx: [Double]           // [u, v], top-left origin
    public var detectedPx: [[Double]]             // the whole sliding window (trajectoryLength points), top-left origin
    public var equationCoefficients: [Float]      // Vision's a, b, c in normalized coords
}

/// A trajectory reassembled from the per-frame records: one sample per frame on which the trajectory grew.
public struct TrajectoryTrack: Sendable, Codable {
    public var uuid: String
    public var samples: [TrackSample]
    public var maxConfidence: Float
    public var meanRadiusPx: Double
    public var firstPTS: Double { samples.first?.pts ?? 0 }
    public var lastPTS: Double { samples.last?.pts ?? 0 }
}

public struct TrackSample: Sendable, Codable {
    public var frameIndex: Int
    public var pts: Double
    public var u: Double
    public var v: Double
    public var radiusPx: Double
    public var confidence: Float
}

public struct TrajectoryRun: Sendable, Codable {
    public var probe: VideoProbeResult
    public var options: TrajectoryTrackerOptions
    public var framesProcessed: Int
    public var records: [TrajectoryFrameRecord]
    public var tracks: [TrajectoryTrack]
}

public struct TrajectoryTrackerOptions: Sendable, Codable {
    /// Vision requires ≥ 5. Apple's Action & Vision demo used 10 at 60 fps... at 240 fps a longer window is the same time span.
    public var trajectoryLength: Int = 10
    /// Normalized to image width. A 45 px ball in a 1920 px frame is 0.0117 radius.
    public var minimumNormalizedRadius: Float = 0.005
    public var maximumNormalizedRadius: Float = 0.06
    /// Only frames in [start, end] seconds are analysed. nil = whole clip.
    public var startTime: Double? = nil
    public var endTime: Double? = nil
    /// Region of interest in normalized image coords (top-left origin: x, y, w, h). nil = full frame.
    public var regionOfInterest: [Double]? = nil
    public init() {}
}

public enum TrajectoryTracker {
    /// Runs one stateful `DetectTrajectoriesRequest` over the clip, feeding every decoded frame with its PTS.
    public static func run(url: URL, options: TrajectoryTrackerOptions = .init(),
                           progress: (@Sendable (Int, Double) -> Void)? = nil) async throws -> TrajectoryRun {
        let reader = VideoReader(url: url)
        // Windowed runs only need dimensions and the frame rate: don't decode a 20-minute clip to analyse 7 seconds of it.
        let probe = options.startTime != nil || options.endTime != nil ? try await reader.quickProbe() : try await reader.probe()
        let request = DetectTrajectoriesRequest(trajectoryLength: options.trajectoryLength)
        request.objectMinimumNormalizedRadius = options.minimumNormalizedRadius
        request.objectMaximumNormalizedRadius = options.maximumNormalizedRadius
        if let roi = options.regionOfInterest, roi.count == 4 {
            // Vision's NormalizedRect has a lower-left origin.
            request.regionOfInterest = NormalizedRect(x: roi[0], y: 1 - roi[1] - roi[3], width: roi[2], height: roi[3])
        }
        let imageSize = CGSize(width: probe.width, height: probe.height)
        var records: [TrajectoryFrameRecord] = []
        var processed = 0
        var skipped = 0
        var timeRange: CMTimeRange? = nil
        if let s = options.startTime {
            let start = CMTime(seconds: s, preferredTimescale: 600)
            let end = options.endTime.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .positiveInfinity
            timeRange = CMTimeRange(start: start, end: end)
        }
        try await reader.forEachFrame(timeRange: timeRange) { frame in
            if let e = options.endTime, frame.pts > e { return false }
            let observations: [TrajectoryObservation]
            do { observations = try await request.perform(on: frame.sampleBuffer) }
            catch { skipped += 1; processed += 1; return true }     // e.g. "Too many moving objects or noise": skip the frame
            for o in observations {
                let pts = o.detectedPoints.map { $0.toImageCoordinates(imageSize, origin: .upperLeft) }
                let last = pts.last
                records.append(TrajectoryFrameRecord(
                    frameIndex: frame.index, pts: frame.pts, uuid: o.uuid.uuidString, confidence: o.confidence,
                    timeRangeStart: o.timeRange?.start.seconds, timeRangeDuration: o.timeRange?.duration.seconds,
                    movingAverageRadiusPx: Double(o.movingAverageRadius) * Double(probe.width),
                    detectedCount: o.detectedPoints.count,
                    lastDetectedPx: last.map { [Double($0.x), Double($0.y)] } ?? [],
                    detectedPx: pts.map { [Double($0.x), Double($0.y)] },
                    equationCoefficients: [o.equationCoefficients.x, o.equationCoefficients.y, o.equationCoefficients.z]))
            }
            processed += 1
            if processed % 240 == 0 { progress?(processed, frame.pts) }
            return true
        }
        let tracks = assemble(records)
        if skipped > 0 { FileHandle.standardError.write("  Vision skipped \(skipped) frame(s) (too many moving objects)\n".data(using: .utf8)!) }
        return TrajectoryRun(probe: probe, options: options, framesProcessed: processed, records: records, tracks: tracks)
    }

    /// Observed behaviour (macOS 26, revision 1): `detectedPoints` is a sliding window of exactly `trajectoryLength`
    /// points, the same uuid persists for the whole flight, and `timeRange.end` is the PTS of the newest point.
    /// So: the first record of a uuid contributes its whole window (times spread evenly over the time range, which is
    /// exact only when no frame was skipped), and every later record whose time-range end advanced contributes its newest point.
    static func assemble(_ records: [TrajectoryFrameRecord]) -> [TrajectoryTrack] {
        var byUUID: [String: [TrajectoryFrameRecord]] = [:]
        for r in records { byUUID[r.uuid, default: []].append(r) }
        var tracks: [TrajectoryTrack] = []
        for (uuid, recs) in byUUID {
            var samples: [TrackSample] = []
            var lastEnd = -Double.infinity
            var radii: [Double] = []
            var maxConf: Float = 0
            for r in recs.sorted(by: { $0.frameIndex < $1.frameIndex }) {
                maxConf = max(maxConf, r.confidence)
                guard let start = r.timeRangeStart, let dur = r.timeRangeDuration else { continue }
                let end = start + dur
                guard end > lastEnd + 1e-6 else { continue }
                if samples.isEmpty, r.detectedPx.count > 1 {
                    let n = r.detectedPx.count
                    for (i, p) in r.detectedPx.enumerated() where p.count == 2 {
                        let t = start + dur * Double(i) / Double(n - 1)
                        samples.append(TrackSample(frameIndex: r.frameIndex - (n - 1 - i), pts: t, u: p[0], v: p[1],
                                                   radiusPx: r.movingAverageRadiusPx, confidence: r.confidence))
                    }
                } else if r.lastDetectedPx.count == 2 {
                    samples.append(TrackSample(frameIndex: r.frameIndex, pts: end, u: r.lastDetectedPx[0], v: r.lastDetectedPx[1],
                                               radiusPx: r.movingAverageRadiusPx, confidence: r.confidence))
                }
                radii.append(r.movingAverageRadiusPx)
                lastEnd = end
            }
            guard !samples.isEmpty else { continue }
            tracks.append(TrajectoryTrack(uuid: uuid, samples: samples, maxConfidence: maxConf,
                                          meanRadiusPx: radii.reduce(0, +) / Double(radii.count)))
        }
        return tracks.sorted { $0.firstPTS < $1.firstPTS }
    }
}

public extension TrajectoryTrack {
    /// Convert to the geometry package's input type. Diameter = 2 × Vision's moving-average radius.
    var imageSamples: [ImageSample] {
        samples.map { ImageSample(t: $0.pts, uv: SIMD2($0.u, $0.v), diameterPx: 2 * $0.radiusPx) }
    }
}
