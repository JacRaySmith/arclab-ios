// The form measures the repeatability table is computed on.
//
// Deliberately computed here, from the fitted timeline alone, and **not** taken from `FormModel` or
// `BodyKinematics`: the harness has to be able to say "this measure moved" without the possibility
// that what moved was the reporting layer. Everything is either an interior angle in degrees or a
// length in stature units, so a number means the same thing on a 1.70 m shooter and a 2.00 m one.
import Foundation
import simd
import ShotGeometry

public enum FormMeasures {

    /// name → unit, in print order.
    public static let catalogue: [(name: String, unit: String)] = [
        ("elbowAtRelease", "deg"),
        ("elbowMinimum", "deg"),
        ("elbowOpening", "deg"),
        ("kneeMinimum", "deg"),
        ("shoulderElevationAtRelease", "deg"),
        ("trunkLeanAtRelease", "deg"),
        ("releaseHeight", "stature"),
        ("jumpHeight", "stature"),
        ("dipDepth", "stature"),
        ("headHorizontalRange", "stature"),
    ]

    static func position(_ f: BodyFrame, _ name: String) -> SIMD3<Double>? {
        f.joints3D[FormEvaluator.joint3DKey(name)]?.cameraPosition
    }

    static func midpoint(_ f: BodyFrame, _ a: String, _ b: String) -> SIMD3<Double>? {
        guard let pa = position(f, a), let pb = position(f, b) else { return nil }
        return (pa + pb) / 2
    }

    static func interiorAngle(_ f: BodyFrame, _ a: String, _ v: String, _ b: String) -> Double? {
        guard let pa = position(f, a), let pv = position(f, v), let pb = position(f, b),
              let r = BodyAngles.angle(pa, pv, pb) else { return nil }
        let d = Angle.degrees(r)
        return d.isFinite ? d : nil
    }

    /// Camera space here is Vision's: +x right in the image, **+y up**, +z toward the camera.
    static let up = SIMD3<Double>(0, 1, 0)

    /// Every measure this harness tracks, for one fitted shot. A measure whose inputs are missing is
    /// simply absent from the dictionary — never zero, never interpolated.
    public static func all(frames: [BodyFrame], side: String, phases: [EvalPhase: Double],
                           stature: Double) -> [String: Double] {
        guard stature > 1e-6, !frames.isEmpty else { return [:] }
        let spacing = FormEvaluator.medianFrameSpacing(frames)
        let tolerance = 1.5 * spacing
        func at(_ p: EvalPhase) -> BodyFrame? {
            guard let t = phases[p] else { return nil }
            return FormEvaluator.nearestFrame(frames, t, tolerance: tolerance)
        }
        guard let release = phases[.release] else { return [:] }
        let start = phases[.set] ?? phases[.dip] ?? (release - 0.6)
        let end = phases[.followThrough] ?? (release + 0.2)
        let window = frames.filter { $0.realTime >= min(start, release - 0.05) && $0.realTime <= max(end, release) }
        let toRelease = frames.filter { $0.realTime >= min(start, release - 0.05) && $0.realTime <= release }

        var out: [String: Double] = [:]
        let shoulder = side + "Shoulder", elbow = side + "Elbow", wrist = side + "Wrist"
        let hip = side + "Hip", knee = side + "Knee", ankle = side + "Ankle"

        if let f = at(.release), let a = interiorAngle(f, shoulder, elbow, wrist) { out["elbowAtRelease"] = a }
        let elbowTrack = toRelease.compactMap { interiorAngle($0, shoulder, elbow, wrist) }
        if let lo = elbowTrack.min() { out["elbowMinimum"] = lo }
        if let lo = elbowTrack.min(), let a = out["elbowAtRelease"] { out["elbowOpening"] = a - lo }
        if let lo = window.compactMap({ interiorAngle($0, hip, knee, ankle) }).min() { out["kneeMinimum"] = lo }

        // Shoulder elevation: the upper arm against the trunk axis on the shooting side.
        if let f = at(.release), let s = position(f, shoulder), let e = position(f, elbow), let h = position(f, hip),
           let r = BodyAngles.angleBetween(e - s, h - s) {
            let d = Angle.degrees(r)
            if d.isFinite { out["shoulderElevationAtRelease"] = d }
        }
        // Trunk lean: mid-hip → mid-shoulder against up. 0° is upright.
        if let f = at(.release), let sh = midpoint(f, Body2DPoint.leftShoulder, Body2DPoint.rightShoulder),
           let hp = midpoint(f, Body2DPoint.leftHip, Body2DPoint.rightHip),
           let r = BodyAngles.angleBetween(sh - hp, up) {
            let d = Angle.degrees(r)
            if d.isFinite { out["trunkLeanAtRelease"] = d }
        }
        // Release height: the shooting wrist above the lower ankle, in stature units.
        if let f = at(.release), let w = position(f, wrist) {
            let ankles = [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle].compactMap { position(f, $0) }
            if let floor = ankles.map(\.y).min() { out["releaseHeight"] = (w.y - floor) / stature }
        }
        // Jump: the mid-hip's peak rise above its height at the set (or the dip when there is no set).
        let hips = window.compactMap { f -> (Double, Double)? in
            midpoint(f, Body2DPoint.leftHip, Body2DPoint.rightHip).map { (f.realTime, $0.y) } }
        if let base = at(.set).flatMap({ midpoint($0, Body2DPoint.leftHip, Body2DPoint.rightHip)?.y })
                    ?? at(.dip).flatMap({ midpoint($0, Body2DPoint.leftHip, Body2DPoint.rightHip)?.y }),
           let peak = hips.map(\.1).max() {
            out["jumpHeight"] = (peak - base) / stature
        }
        // Dip: how far the mid-hip fell below its set height before the release. Needs a set *and* a
        // dip: on a shot the body model refused a dip for ("the hand rises from the set position
        // straight into the release") there is no dip to measure, and clamping the number at zero
        // would put a fabricated 0.000 into the repeatability table.
        if phases[.dip] != nil, let setFrame = at(.set),
           let base = midpoint(setFrame, Body2DPoint.leftHip, Body2DPoint.rightHip)?.y,
           let low = toRelease.compactMap({ midpoint($0, Body2DPoint.leftHip, Body2DPoint.rightHip)?.y }).min() {
            out["dipDepth"] = max(0, base - low) / stature
        }
        // Head sway: the horizontal excursion of the head through the lift, in stature units.
        let heads = toRelease.compactMap { position($0, Body2DPoint.nose)?.x }
        if let lo = heads.min(), let hi = heads.max(), heads.count >= 3 {
            out["headHorizontalRange"] = (hi - lo) / stature
        }
        return out
    }
}
