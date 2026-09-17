import Foundation
import simd
import ShotGeometry

/// The release instant read from the ball and the shooter's wrists, ported verbatim from
/// `release_from_pose` in `tools/pytrack/report.py`:
///
///   release = the first tracked frame on which the ball is **≥ 1.0 ball diameters** from the nearer wrist,
///   **above** it, and **rising** (its image *v* falls by more than 2 px over the next three detections).
///
/// Against the shooter's own labels (`docs/footage-2026-09-13/release_labels.json`) this rule was within
/// 4 ms on two of three free throws and 37 ms early on the third; the ball-only rule fails whenever the
/// tracker follows the ball while it is still held.
public enum ReleaseFromPose {
    /// Ball samples that rest on image evidence. Nothing extrapolated is ever allowed to set the release.
    public static let evidenceSources: Set<String> = ["detected", "held", "template", "merged"]

    /// A wrist below this confidence is not trusted to place the hand.
    public static let wristConfidence = 0.3
    /// The ball must clear the wrist by at least this many diameters.
    public static let clearanceDiameters = 1.0
    /// "Rising" means the third following detection is at least this many pixels higher up the image.
    public static let risePx = 2.0

    /// - Parameters:
    ///   - detections: ball detections in any order; only evidence-based sources are considered.
    ///   - poses: pose frames on the same `pts` clock (file seconds). Matched to detections by nearest time.
    ///   - ballDiameterPx: the ball's diameter in pixels (the median of the detections is the usual choice).
    /// - Returns: the detection's `pts` (file seconds) and its frame index, or nil when no frame satisfies the rule.
    public static func estimate(detections: [BallDetection], poses: [PoseFrame], ballDiameterPx: Double)
        -> (pts: Double, frameIndex: Int)?
    {
        let det = detections.filter { evidenceSources.contains($0.source) }.sorted { $0.pts < $1.pts }
        let poseByTime = poses.sorted { $0.pts < $1.pts }
        guard det.count >= 3, !poseByTime.isEmpty, ballDiameterPx > 0 else { return nil }
        var gaps: [Double] = []
        for i in 1..<det.count { gaps.append(det[i].pts - det[i - 1].pts) }
        let medianGap = gaps.sorted()[gaps.count / 2]
        let tolerance = max(0.75 * medianGap, 1e-4)

        for (n, d) in det.enumerated() {
            guard let pose = nearestPose(poseByTime, pts: d.pts, tolerance: tolerance) else { continue }
            var nearest: (distance: Double, wrist: JointSample)? = nil
            for w in ["l_wrist", "r_wrist"] {
                guard let j = pose.joints[w], j.confidence >= wristConfidence else { continue }
                let distance = (((d.u - j.u) * (d.u - j.u)) + ((d.v - j.v) * (d.v - j.v))).squareRoot()
                if nearest == nil || distance < nearest!.distance { nearest = (distance, j) }
            }
            // No trusted wrist, the ball still in the hand, or the ball below the wrist: not a release.
            guard let near = nearest, near.distance >= clearanceDiameters * ballDiameterPx, d.v <= near.wrist.v else { continue }
            let following = det[(n + 1)..<min(n + 4, det.count)].map(\.v)
            guard following.count >= 2, let last = following.last, last < d.v - risePx else { continue }
            return (pts: d.pts, frameIndex: d.frameIndex)
        }
        return nil
    }

    /// The pose frame closest in time to `pts`, or nil when the nearest one is further away than `tolerance`.
    /// `poses` must be sorted by `pts`.
    public static func nearestPose(_ poses: [PoseFrame], pts: Double, tolerance: Double) -> PoseFrame? {
        var lo = 0, hi = poses.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if poses[mid].pts < pts { lo = mid + 1 } else { hi = mid }
        }
        var best = lo
        if lo > 0, abs(poses[lo - 1].pts - pts) < abs(poses[lo].pts - pts) { best = lo - 1 }
        return abs(poses[best].pts - pts) <= tolerance ? poses[best] : nil
    }
}

/// Camera-side 2-D joint angles. Per the brief these are only meaningful for a near-side view: a 2-D angle
/// between two limb segments is the true 3-D angle only when the limb lies in the image plane, so every caller
/// must print the analyzer's view-angle class alongside them.
public struct PoseAngles2D: Sendable, Codable {
    public var side: String                          // "l" or "r": the limb facing the camera
    public var elbowAtReleaseDegrees: Double?
    public var elbowMaxNearReleaseDegrees: Double?   // maximum extension within ±`extensionHalfWindowFrames`
    public var kneeMinimumDegrees: Double?           // deepest bend in the lookback before release
    public init(side: String, elbowAtReleaseDegrees: Double? = nil,
                elbowMaxNearReleaseDegrees: Double? = nil, kneeMinimumDegrees: Double? = nil) {
        self.side = side
        self.elbowAtReleaseDegrees = elbowAtReleaseDegrees
        self.elbowMaxNearReleaseDegrees = elbowMaxNearReleaseDegrees
        self.kneeMinimumDegrees = kneeMinimumDegrees
    }
}

public enum PoseMetrics2D {
    /// Angle at `b` between `ba` and `bc`, in degrees, in image pixels.
    public static func angleDegrees(_ a: JointSample, _ b: JointSample, _ c: JointSample) -> Double {
        let v1 = SIMD2(a.u - b.u, a.v - b.v), v2 = SIMD2(c.u - b.u, c.v - b.v)
        let n1 = (v1 * v1).sum().squareRoot(), n2 = (v2 * v2).sum().squareRoot()
        let cosine = (v1 * v2).sum() / (n1 * n2 + 1e-9)
        return Angle.degrees(acos(min(1, max(-1, cosine))))
    }

    /// The side the camera sees: whichever elbow Vision reports confidently on more frames (the pytrack rule).
    public static func cameraSide(_ poses: [PoseFrame], minimumConfidence: Double = 0.5) -> String {
        let l = poses.filter { ($0.joints["l_elbow"]?.confidence ?? 0) >= minimumConfidence }.count
        let r = poses.filter { ($0.joints["r_elbow"]?.confidence ?? 0) >= minimumConfidence }.count
        return l > r ? "l" : "r"
    }

    /// - Parameters:
    ///   - releasePTS: the release instant on the pose frames' own clock (file seconds).
    ///   - extensionHalfWindowFrames: ± this many *pose frames* around release for the maximum-extension search.
    ///   - kneeLookbackPTS: how far back to look for the deepest knee bend, **in the same units as `pts`**
    ///     (so a caller working in real seconds on a slow-motion file must multiply by the time scale).
    public static func angles(poses: [PoseFrame], releasePTS: Double,
                              extensionHalfWindowFrames: Int = 6, kneeLookbackPTS: Double,
                              minimumConfidence: Double = 0.4) -> PoseAngles2D? {
        let sorted = poses.sorted { $0.pts < $1.pts }
        guard !sorted.isEmpty else { return nil }
        let side = cameraSide(sorted)
        func joint(_ f: PoseFrame, _ name: String) -> JointSample? {
            guard let j = f.joints["\(side)_\(name)"], j.confidence >= minimumConfidence else { return nil }
            return j
        }
        func elbow(_ f: PoseFrame) -> Double? {
            guard let s = joint(f, "shoulder"), let e = joint(f, "elbow"), let w = joint(f, "wrist") else { return nil }
            return angleDegrees(s, e, w)
        }
        var out = PoseAngles2D(side: side)
        let releaseIndex = sorted.indices.min(by: { abs(sorted[$0].pts - releasePTS) < abs(sorted[$1].pts - releasePTS) })!
        out.elbowAtReleaseDegrees = elbow(sorted[releaseIndex])
        let lo = max(0, releaseIndex - extensionHalfWindowFrames)
        let hi = min(sorted.count - 1, releaseIndex + extensionHalfWindowFrames)
        out.elbowMaxNearReleaseDegrees = (lo...hi).compactMap { elbow(sorted[$0]) }.max()
        var knees: [Double] = []
        for f in sorted where f.pts >= releasePTS - kneeLookbackPTS && f.pts <= releasePTS {
            guard let h = joint(f, "hip"), let k = joint(f, "knee"), let a = joint(f, "ankle") else { continue }
            knees.append(angleDegrees(h, k, a))
        }
        out.kneeMinimumDegrees = knees.min()
        return out
    }
}
