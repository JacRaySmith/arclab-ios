import CoreGraphics
import Foundation
import ShotGeometry

/// The three things drawn over the release frame, all in image pixels: the detections the fit used,
/// the fitted parabola reprojected through the solved shot plane, and the rim points that scaled it.
///
/// The parabola is reprojected exactly as `TrajectoryProbe writeOverlay` does: sample the fit in
/// plane coordinates, lift to 3-D with `frame.point3D`, divide by depth, and go through the same
/// intrinsics the analyzer used.
struct ShotOverlay {
    var detections: [CGPoint] = []
    var parabola: [CGPoint] = []
    var rim: [CGPoint] = []
    var flight: [CGPoint] = []
    var releasePoint: CGPoint?
    var windowEndPoint: CGPoint?
    var rimCenter: CGPoint?

    init(analysis a: ShotAnalysis, samples: [ImageSample], rimPoints: [SIMD2<Double>], intrinsics k: CameraIntrinsics) {
        detections = samples.map { CGPoint(x: $0.uv.x, y: $0.uv.y) }
        rim = rimPoints.map { CGPoint(x: $0.x, y: $0.y) }

        for i in a.flightIndices where i < samples.count {
            flight.append(CGPoint(x: samples[i].uv.x, y: samples[i].uv.y))
        }
        if let ri = a.flightIndices.first, ri < samples.count { releasePoint = CGPoint(x: samples[ri].uv.x, y: samples[ri].uv.y) }
        if let ei = a.flightIndices.last, ei < samples.count { windowEndPoint = CGPoint(x: samples[ei].uv.x, y: samples[ei].uv.y) }

        let endIndex = min(a.flightIndices.last ?? 0, a.planeSamples.count - 1)
        guard endIndex >= 0, !a.planeSamples.isEmpty else { return }
        let tStart = a.window.releaseTime
        let tEnd = a.planeSamples[endIndex].t
        var t = tStart
        while t <= tEnd + 0.05 {
            let p = a.fit.position(at: t)
            let P = a.azimuth.frame.point3D(x: p.x, y: p.y)
            if P.z > 0.1 {
                let px = k.pixel(fromNormalized: SIMD2(P.x / P.z, P.y / P.z))
                parabola.append(CGPoint(x: px.x, y: px.y))
            }
            t += 0.005
        }
        let rc = a.calibration.rimCenter
        if rc.z > 0.1 {
            let px = k.pixel(fromNormalized: SIMD2(rc.x / rc.z, rc.y / rc.z))
            rimCenter = CGPoint(x: px.x, y: px.y)
        }
    }
}
