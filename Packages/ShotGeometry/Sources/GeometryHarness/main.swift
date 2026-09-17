import Foundation
import ShotGeometry

// Phase 1 gate harness (brief §8, Phase 1). Every scenario draws N random shots and cameras,
// runs simulate → calibrate → analyze, and reports recovery error of the release angle and g_fit.
// Gate: perpendicular/zero noise ≤ 0.1°; 30° yaw + pixel noise ≤ 1.5°; 20% dropped frames ≤ 2.0°;
// 30 fps ≤ 3.0°; g_fit within 2% throughout.

let rad = Angle.radians, deg = Angle.degrees

struct Scenario {
    var name: String
    var view: Double            // degrees from perpendicular
    var fps: Double
    var noisePx: Double
    var dropFraction: Double = 0
    var rimNoisePx: Double = 0.3
    var occluded: Int = 0
    var diameterNoisePx: Double = 1.0
    var thetaTol: Double        // degrees
    var gTol: Double = 0.02
    var draws: Int = 50
}

struct DrawResult {
    var dTheta: Double, dG: Double, dEntry: Double, dH: Double, dRelease: Double, rmsPx: Double
    var theta: Double, v: Double, h: Double, L: Double, dist: Double, height: Double
    var seed: UInt64 = 0
    var cropped = false
    var error: String?
}

/// Speed that lands the ball centre on the rim centre for (θ, h, L).
func makeSpeed(theta: Double, h: Double, L: Double) -> Double? {
    let denom = h + L * tan(theta) - Court.rimHeight
    guard denom > 0 else { return nil }
    return (Court.g * L * L / (2 * cos(theta) * cos(theta) * denom)).squareRoot()
}

func run(_ sc: Scenario, seed: UInt64 = 20260912) -> [DrawResult] {
    var rng = SeededRNG(seed: seed)
    var out: [DrawResult] = []
    var i = 0
    while out.count < sc.draws {
        i += 1
        let theta = rad(rng.uniform(in: 40...60))
        let h = rng.uniform(in: 2.0...2.6)
        let L = [Court.freeThrowLineToRimCenter, 5.5, 6.75][Int(rng.uniform() * 3) % 3]
        guard let v0 = makeSpeed(theta: theta, h: h, L: L) else { continue }
        let v = v0 * rng.uniform(in: 0.97...1.03)
        let dist = rng.uniform(in: 6...10), height = rng.uniform(in: 1.2...1.8)
        let p = ShotParameters(releaseAngle: theta, releaseSpeed: v, releaseHeight: h, releaseDistance: L)
        let pl = CameraPlacement(viewAngle: rad(sc.view), distance: dist, height: height, intrinsics: CameraPlacement.iPhone1080p())
        var o = SimulationOptions()
        o.fps = sc.fps; o.noisePx = sc.noisePx; o.dropFraction = sc.dropFraction; o.rimNoisePx = sc.rimNoisePx
        o.occludedFramesAfterRelease = sc.occluded; o.seed = rng.next() % 1_000_000; o.diameterNoisePx = sc.diameterNoisePx
        let sim = ShotSimulator.simulate(p, placement: pl, options: o)
        var r = DrawResult(dTheta: .nan, dG: .nan, dEntry: .nan, dH: .nan, dRelease: .nan, rmsPx: .nan,
                           theta: deg(theta), v: v, h: h, L: L, dist: dist, height: height, seed: o.seed, error: nil)
        do {
            let cal = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: pl.intrinsics)
            let a = try ShotAnalyzer.analyze(track: sim.samples, calibration: cal, intrinsics: pl.intrinsics)
            r.cropped = !a.confidence.releaseObserved
            r.dTheta = (a.metrics.release?.angleDegrees ?? .nan) - deg(theta)
            r.dG = (a.confidence.gFit - Court.g) / Court.g
            r.dEntry = (a.metrics.entryAngleDegrees ?? .nan) - deg(sim.truth.entryAngle)
            r.dH = (a.metrics.release?.height ?? .nan) - h
            r.dRelease = a.window.releaseTime * sc.fps
            r.rmsPx = a.confidence.rmsPx
        } catch { r.error = "\(error)" }
        out.append(r)
    }
    return out
}

func summarise(_ sc: Scenario, _ rs: [DrawResult]) -> Bool {
    let cropped = rs.filter { $0.error == nil && $0.cropped }.count
    let ok = rs.filter { $0.error == nil && !$0.cropped }
    let dth = ok.map { abs($0.dTheta) }, dg = ok.map { abs($0.dG) }
    let maxTh = dth.max() ?? .nan, maxG = dg.max() ?? .nan
    let pass = ok.count + cropped == rs.count && maxTh <= sc.thetaTol && maxG <= sc.gTol
    let entry = ok.map { abs($0.dEntry) }.filter { $0.isFinite }
    print(String(format: "%-38@ n=%2d  |Δθ| mean %.3f° sd %.3f° max %.3f° (tol %.1f)  |Δg| max %.2f%% (tol %.0f%%)  |Δentry| max %.2f°  Δh max %.3f m  release max %.2f fr  → %@",
                 sc.name as NSString, ok.count, Stats.mean(dth), Stats.sd(dth), maxTh, sc.thetaTol, maxG * 100, sc.gTol * 100,
                 entry.max() ?? .nan, ok.map { abs($0.dH) }.max() ?? .nan, ok.map { abs($0.dRelease) }.max() ?? .nan, (pass ? "PASS" : "FAIL") as NSString))
    if cropped > 0 { print("     \(cropped) draw(s) had the release out of frame (shooter cropped → tier C, excluded from θ stats)") }
    let failures = rs.filter { $0.error != nil }
    for f in failures.prefix(3) { print("     error: \(f.error!)  [θ=\(fmt(f.theta,1)) v=\(fmt(f.v,2)) h=\(fmt(f.h,2)) L=\(fmt(f.L,2)) cam \(fmt(f.dist,1)) m @ \(fmt(f.height,2)) m]") }
    if let worst = ok.max(by: { abs($0.dTheta) < abs($1.dTheta) }), abs(worst.dTheta) > sc.thetaTol * 0.5 {
        print("     worst θ: Δ=\(fmt(worst.dTheta,3))° Δg=\(fmt(worst.dG*100,2))% [θ=\(fmt(worst.theta,1)) v=\(fmt(worst.v,2)) h=\(fmt(worst.h,2)) L=\(fmt(worst.L,2)) cam \(fmt(worst.dist,1)) m @ \(fmt(worst.height,2)) m, rms \(fmt(worst.rmsPx,2)) px, seed \(worst.seed)]")
    }
    return pass
}

func fmt(_ x: Double, _ d: Int) -> String { String(format: "%.\(d)f", x) }

let gate: [Scenario] = [
    Scenario(name: "A perpendicular, zero noise, 240 fps", view: 0, fps: 240, noisePx: 0, rimNoisePx: 0, diameterNoisePx: 0, thetaTol: 0.1),
    Scenario(name: "B 30° yaw, 1.5 px noise, 240 fps", view: 30, fps: 240, noisePx: 1.5, thetaTol: 1.5),
    Scenario(name: "C 30° yaw, 1.5 px, 20% dropped frames", view: 30, fps: 240, noisePx: 1.5, dropFraction: 0.2, thetaTol: 2.0),
    Scenario(name: "D 30° yaw, 1.5 px, 30 fps", view: 30, fps: 30, noisePx: 1.5, thetaTol: 3.0),
]
let extra: [Scenario] = [
    Scenario(name: "E perpendicular, 1.5 px, 120 fps", view: 0, fps: 120, noisePx: 1.5, thetaTol: 1.5),
    Scenario(name: "F 30° yaw, 1.5 px, 60 fps", view: 30, fps: 60, noisePx: 1.5, thetaTol: 2.0),
    Scenario(name: "G 55° yaw (oblique), 1.5 px, 240 fps", view: 55, fps: 240, noisePx: 1.5, thetaTol: 2.0),
    Scenario(name: "H 30° yaw, 1.5 px, 6 frames occluded", view: 30, fps: 240, noisePx: 1.5, occluded: 6, thetaTol: 1.5),
    Scenario(name: "I 30° yaw, 3 px noise, 240 fps", view: 30, fps: 240, noisePx: 3.0, thetaTol: 2.0),
]

print("=== Phase 1 gate (brief §8) ===")
var allPass = true
for sc in gate { allPass = summarise(sc, run(sc)) && allPass }
print("\n=== Additional scenarios ===")
for sc in extra { _ = summarise(sc, run(sc)) }

// Open question 1: can one 45° camera give 3D from the ball's pixel diameter?
print("\n=== Open question 1: depth from ball diameter (45° view, 240 fps, 1.5 px centroid noise) ===")
for diamNoise in [0.25, 0.5, 1.0, 2.0] {
    var rng = SeededRNG(seed: 99)
    var lateralErrs: [Double] = [], depthErrs: [Double] = []
    for _ in 0..<30 {
        let theta = rad(rng.uniform(in: 45...55)), h = rng.uniform(in: 2.0...2.6), L = 4.6
        guard let v = makeSpeed(theta: theta, h: h, L: L) else { continue }
        let lateral = rng.uniform(in: -0.15...0.15)
        let p = ShotParameters(releaseAngle: theta, releaseSpeed: v, releaseHeight: h, releaseDistance: L, lateralOffset: lateral, lateralAimError: 0)
        let pl = CameraPlacement(viewAngle: rad(45), distance: 8, height: 1.5, intrinsics: CameraPlacement.iPhone1080p())
        var o = SimulationOptions(); o.noisePx = 1.5; o.diameterNoisePx = diamNoise; o.seed = rng.next(); o.postContactDuration = 0
        let sim = ShotSimulator.simulate(p, placement: pl, options: o)
        guard let cal = try? RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: pl.intrinsics) else { continue }
        // Per-frame 3D point from diameter: z = fx·D/d_px along the pixel ray. Fit horizontal
        // coordinates linear in t and vertical quadratic, in the rim-anchored frame; read lateral
        // position at the rim crossing.
        let flight = sim.frames.filter { $0.phase == .flight && !$0.dropped }.dropFirst(2)
        let (a, b) = ShotPlaneSolver.horizontalBasis(up: cal.up)
        var ts: [Double] = [], xa: [Double] = [], xb: [Double] = [], ys: [Double] = []
        for f in flight {
            let z = pl.intrinsics.fx * o.ballDiameter / f.diameterPx
            let ray = pl.intrinsics.ray(f.uv)
            let P = ray * (z / ray.z) - cal.rimCenter
            ts.append(f.t); xa.append(P.x * a.x + P.y * a.y + P.z * a.z); xb.append(P.x * b.x + P.y * b.y + P.z * b.z)
            ys.append(P.x * cal.up.x + P.y * cal.up.y + P.z * cal.up.z)
        }
        guard let la = PolyFit.linear(ts, xa), let lb = PolyFit.linear(ts, xb), let q = PolyFit.quadratic(ts, ys) else { continue }
        // rim crossing: y = 0 descending
        let g = -2 * q.c2; let disc = q.c1 * q.c1 + 2 * g * q.c0
        guard g > 0, disc >= 0 else { continue }
        let tc = (q.c1 + disc.squareRoot()) / g
        let pa = la(tc), pb = lb(tc)
        // Lateral = component perpendicular to the (rim-anchored) direction of travel.
        let dirA = la.c1, dirB = lb.c1, dn = (dirA * dirA + dirB * dirB).squareRoot()
        let lateralMeasured = (-pa * dirB + pb * dirA) / dn
        let trueLateral = sim.parameters.lateralOffset * 0 + (-lateral) // shooter offset means crossing offset of −lateral relative to travel line through rim? crossing is at y_world = lateral
        lateralErrs.append(abs(abs(lateralMeasured) - abs(trueLateral)))
        let depthMeasured = (pa * dirA + pb * dirB) / dn
        depthErrs.append(abs(depthMeasured - sim.truth.rimCrossingOffset))
    }
    print(String(format: "  diameter noise %.2f px: lateral-at-rim |error| median %.3f m, p90 %.3f m; depth-at-rim |error| median %.3f m (n=%d)",
                 diamNoise, Stats.median(lateralErrs), lateralErrs.sorted()[Int(Double(lateralErrs.count) * 0.9)], Stats.median(depthErrs), lateralErrs.count))
}
print("\nGATE:", allPass ? "PASS" : "FAIL")
exit(allPass ? 0 : 1)
