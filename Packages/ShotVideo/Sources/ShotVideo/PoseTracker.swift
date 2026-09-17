import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import Vision
import simd

/// Apple Vision 2-D body pose over a window of a clip.
///
/// This is the Swift port of the pose stage that made the Python pipeline's release instant accurate
/// (`tools/pytrack/report.py`, `release_from_pose`). Vision on macOS runs the same models as iOS, so the
/// numbers this produces on the desktop probe are the numbers the app will see.
///
/// Coordinates are **top-left pixel coordinates of the full-resolution frame**, the same convention as
/// `BallDetection.u/v`, obtained with `NormalizedPoint.toImageCoordinates(_:origin: .upperLeft)`.
public struct JointSample: Sendable, Codable {
    public var name: String          // "l_wrist", "r_elbow", "nose", … (the pytrack naming)
    public var u: Double             // pixels, top-left origin
    public var v: Double             // pixels, top-left origin, increasing downwards
    public var confidence: Double    // Vision's per-joint confidence, 0…1
    public init(name: String, u: Double, v: Double, confidence: Double) {
        self.name = name; self.u = u; self.v = v; self.confidence = confidence
    }
}

/// The joints of the one person chosen on a frame. A frame with no observation produces no `PoseFrame`.
public struct PoseFrame: Sendable, Codable {
    public var frameIndex: Int       // absolute frame number when `fps` was supplied, else the index within the window
    public var pts: Double           // presentation timestamp in file seconds (the same clock as `BallDetection.pts`)
    public var joints: [String: JointSample]
    public init(frameIndex: Int, pts: Double, joints: [String: JointSample]) {
        self.frameIndex = frameIndex; self.pts = pts; self.joints = joints
    }
}

public enum PoseTracker {
    /// The joints the shooting metrics need, mapped to the pytrack names so the two pipelines can be compared directly.
    /// Face joints other than the nose, the ears, the eyes, the neck and the root are dropped.
    public static let keptJoints: [HumanBodyPoseObservation.JointName: String] = [
        .leftShoulder: "l_shoulder", .rightShoulder: "r_shoulder",
        .leftElbow: "l_elbow", .rightElbow: "r_elbow",
        .leftWrist: "l_wrist", .rightWrist: "r_wrist",
        .leftHip: "l_hip", .rightHip: "r_hip",
        .leftKnee: "l_knee", .rightKnee: "r_knee",
        .leftAnkle: "l_ankle", .rightAnkle: "r_ankle",
        .nose: "nose",
    ]

    /// Runs `DetectHumanBodyPoseRequest` on every (or every *n*-th) decoded frame in `[start, end]` file seconds.
    ///
    /// - Parameters:
    ///   - everyNthFrame: 1 analyses every frame; 2 every other frame, …
    ///   - ballSeed: optional (pts, ball centre) pairs. When a seed exists for a frame, the observation whose nearer
    ///     wrist is closest to the ball is chosen; otherwise the observation with the largest joint bounding box wins.
    ///   - fps: when given, `PoseFrame.frameIndex` is the absolute frame number `round(pts × fps)` — the same key
    ///     `BallDetector` uses — so pose frames and ball detections can be joined by index as well as by time.
    public static func run(url: URL, start: Double, end: Double, everyNthFrame: Int = 1,
                           ballSeed: [(pts: Double, uv: SIMD2<Double>)] = [],
                           fps: Double? = nil) async throws -> [PoseFrame] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoReaderError.noVideoTrack }
        let natural = try await track.load(.naturalSize)
        let imageSize = CGSize(width: abs(natural.width), height: abs(natural.height))

        let reader = VideoReader(url: url)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        let request = DetectHumanBodyPoseRequest()
        let seeds = ballSeed.sorted { $0.pts < $1.pts }
        let step = max(1, everyNthFrame)

        var out: [PoseFrame] = []
        var decoded = 0
        var failed = 0
        // The reader skips the frames this pass does not analyse, so only the ones Vision sees are re-wrapped.
        // `index % step` there is this loop's `decoded % step`: the same frames, none added, none taken away.
        try await reader.forEachFrame(timeRange: range, stride: step) { frame in
            defer { decoded = frame.index + 1 }
            if frame.pts > end + 1e-6 { return false }
            guard let pixelBuffer = frame.pixelBuffer else { return true }
            // Measured on macOS 26: `DetectHumanBodyPoseRequest` returns **no** observations for a buffer that
            // carries the decoder's `CVCleanAperture` attachment — even the degenerate full-frame one
            // (1920×1080, offsets 0) that AVAssetReader attaches to every frame of these clips. The same frame
            // as a CIImage or CGImage, or with that one attachment removed, detects the body normally
            // (`DetectTrajectoriesRequest` is unaffected, which is why the trajectory pass never showed it).
            // So: drop the attachment for the duration of the request, then put it back.
            let cleanAperture = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferCleanApertureKey, nil)
            if cleanAperture != nil { CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferCleanApertureKey) }
            defer { if let c = cleanAperture { CVBufferSetAttachment(pixelBuffer, kCVImageBufferCleanApertureKey, c, .shouldPropagate) } }
            let observations: [HumanBodyPoseObservation]
            do { observations = try await request.perform(on: pixelBuffer) }
            catch { failed += 1; return true }
            guard !observations.isEmpty else { return true }
            let candidates = observations.map { jointsInPixels($0, imageSize: imageSize) }
            guard let pick = choose(candidates, seed: nearestSeed(seeds, pts: frame.pts)), !candidates[pick].isEmpty else { return true }
            let index = fps.map { Int((frame.pts * $0).rounded()) } ?? frame.index
            out.append(PoseFrame(frameIndex: index, pts: frame.pts, joints: candidates[pick]))
            return true
        }
        if failed > 0 { FileHandle.standardError.write("  PoseTracker: Vision failed on \(failed) frame(s)\n".data(using: .utf8)!) }
        return out
    }

    static func jointsInPixels(_ o: HumanBodyPoseObservation, imageSize: CGSize) -> [String: JointSample] {
        var d: [String: JointSample] = [:]
        for (jointName, label) in keptJoints {
            guard let j = o.joint(for: jointName) else { continue }
            let p = j.location.toImageCoordinates(imageSize, origin: .upperLeft)
            d[label] = JointSample(name: label, u: Double(p.x), v: Double(p.y), confidence: Double(j.confidence))
        }
        return d
    }

    /// Multi-person choice: the person holding the ball if a seed is given, else the person occupying the most pixels.
    static func choose(_ candidates: [[String: JointSample]], seed: SIMD2<Double>?) -> Int? {
        guard !candidates.isEmpty else { return nil }
        if let s = seed {
            var best: (index: Int, distance: Double)? = nil
            for (i, joints) in candidates.enumerated() {
                var nearest = Double.infinity
                for w in ["l_wrist", "r_wrist"] {
                    guard let j = joints[w], j.confidence >= 0.1 else { continue }
                    nearest = min(nearest, (((j.u - s.x) * (j.u - s.x)) + ((j.v - s.y) * (j.v - s.y))).squareRoot())
                }
                if nearest.isFinite, best == nil || nearest < best!.distance { best = (i, nearest) }
            }
            if let b = best { return b.index }
        }
        var best: (index: Int, size: Double)? = nil
        for (i, joints) in candidates.enumerated() {
            let seen = joints.values.filter { $0.confidence >= 0.1 }
            guard seen.count >= 2 else { continue }
            let us = seen.map(\.u), vs = seen.map(\.v)
            let diagonal = (((us.max()! - us.min()!) * (us.max()! - us.min()!)) + ((vs.max()! - vs.min()!) * (vs.max()! - vs.min()!))).squareRoot()
            if best == nil || diagonal > best!.size { best = (i, diagonal) }
        }
        return best?.index ?? 0
    }

    /// Nearest seed in time; nil when the seeds are empty or none is within half a typical frame.
    static func nearestSeed(_ seeds: [(pts: Double, uv: SIMD2<Double>)], pts: Double, tolerance: Double = 0.05) -> SIMD2<Double>? {
        guard !seeds.isEmpty else { return nil }
        var lo = 0, hi = seeds.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if seeds[mid].pts < pts { lo = mid + 1 } else { hi = mid }
        }
        var best = lo
        if lo > 0, abs(seeds[lo - 1].pts - pts) < abs(seeds[lo].pts - pts) { best = lo - 1 }
        return abs(seeds[best].pts - pts) <= tolerance ? seeds[best].uv : nil
    }
}
