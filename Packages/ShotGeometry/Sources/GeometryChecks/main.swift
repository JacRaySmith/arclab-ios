import Foundation
import ShotGeometry

var R = CheckRunner()
let deg = Angle.degrees, rad = Angle.radians

// MARK: forward model — textbook Ch 4.1 reference cases
R.suite("Physics.forward")
if let f = Physics.forward(theta: rad(50), v: 7.0, h: 2.2, L: 4.19, rimHeight: 3.05) {   // textbook constants
    R.near(deg(f.entry), 37.68, tol: 0.01, "entry angle (50°, 7.0, 2.2)")
    R.near(f.depth, 0.0920, tol: 0.0005, "depth past front rim")
} else { R.check(false, "forward returned nil for a shot that reaches the rim") }
if let f = Physics.forward(theta: rad(52), v: 7.1, h: 2.2, L: 4.19, rimHeight: 3.05) {
    R.near(deg(f.entry), 41.183, tol: 0.005, "entry angle (52°, 7.1, 2.2)")
    R.near(f.depth, 0.2356, tol: 0.0005, "depth (52°, 7.1, 2.2)")
}
R.check(Physics.forward(theta: rad(30), v: 5.0, h: 2.2, L: 4.19) == nil, "short shot must return nil, not a number")
R.near(deg(Physics.entryFloor(ballDiameter: 0.2426)), 32.06, tol: 0.05, "entry floor, size 7 (0.2426)")

// MARK: perspective yaw formula — brief §4.4
R.suite("Perspective.yaw")
R.near(deg(Perspective.apparentAngle(true: rad(50), yaw: rad(30))), 54.0, tol: 0.05, "50° true seen 30° off-axis")
R.near(deg(Perspective.yawCorrectedAngle(measured: rad(54.0), yaw: rad(30))), 50.0, tol: 0.05, "inverse correction")

// MARK: polynomial fit exactness
R.suite("PolyFit")
do {
    let t = (0..<30).map { Double($0) / 120 }
    let y = t.map { 2.2 + 5.362 * $0 - 0.5 * 9.81 * $0 * $0 }
    let q = PolyFit.quadratic(t, y)!
    R.near(q.c0, 2.2, tol: 1e-9, "c0"); R.near(q.c1, 5.362, tol: 1e-9, "c1"); R.near(-2 * q.c2, 9.81, tol: 1e-9, "g")
    // textbook §3.4 five hand-typed points
    let t5 = [0.00, 0.05, 0.10, 0.15, 0.20], y5 = [2.200, 2.456, 2.688, 2.895, 3.078]
    let q5 = PolyFit.quadratic(t5, y5)!
    R.near(q5.c2, -4.88571429, tol: 1e-6, "textbook c2"); R.near(q5.c1, 5.36714286, tol: 1e-6, "textbook c1"); R.near(q5.c0, 2.19997143, tol: 1e-6, "textbook c0")
}

// MARK: trajectory fit round trip, invariances, robustness
R.suite("TrajectoryFitter")
func synth(theta: Double, v: Double, h: Double, fps: Double, n: Int, scale: Double = 1, timeScale: Double = 1) -> [TrajectorySample] {
    (0..<n).map { k in
        let t = Double(k) / fps
        return TrajectorySample(t: t / timeScale, x: scale * v * cos(theta) * t, y: scale * (h + v * sin(theta) * t - 0.5 * Court.g * t * t))
    }
}
do {
    let s = synth(theta: rad(50), v: 7, h: 2.2, fps: 120, n: 108)
    let f = try TrajectoryFitter.fit(s, anchorTime: 0)
    R.near(deg(f.releaseAngle), 50, tol: 1e-6, "θ noiseless"); R.near(f.releaseSpeed, 7, tol: 1e-6, "v"); R.near(f.y0, 2.2, tol: 1e-6, "h"); R.near(f.g, 9.81, tol: 1e-6, "g")
    // evaluation at a different anchor moves (θ, v, h), not the curve
    let f2 = try TrajectoryFitter.fit(s, anchorTime: 0.3)
    R.near(f2.g, 9.81, tol: 1e-6, "g independent of anchor")
    R.near(f2.reanchored(at: 0).y0, 2.2, tol: 1e-6, "re-anchoring recovers h")
    // Ch 4.8 lookup table
    let fs = try TrajectoryFitter.fit(synth(theta: rad(50), v: 7, h: 2.2, fps: 120, n: 108, scale: 1.1), anchorTime: 0)
    R.near(deg(fs.releaseAngle), 50, tol: 1e-6, "θ invariant to scale"); R.near(fs.releaseSpeed, 7.7, tol: 1e-6, "v ×k"); R.near(fs.y0, 2.42, tol: 1e-6, "h ×k"); R.near(fs.g, 10.791, tol: 1e-6, "g ×k")
    let ft = try TrajectoryFitter.fit(synth(theta: rad(50), v: 7, h: 2.2, fps: 120, n: 108, timeScale: 1.1), anchorTime: 0)
    R.near(deg(ft.releaseAngle), 50, tol: 1e-6, "θ invariant to fps error"); R.near(ft.releaseSpeed, 7.7, tol: 1e-6, "v ×k"); R.near(ft.y0, 2.2, tol: 1e-6, "h invariant"); R.near(ft.g, 9.81 * 1.21, tol: 1e-6, "g ×k²")
    // contamination: last 4 samples from a bounce; robust fit must shrug it off
    var c = synth(theta: rad(50), v: 7, h: 2.2, fps: 120, n: 100)
    for k in 96..<100 { c[k].y -= 0.08 * Double(k - 95) }
    let fr = try TrajectoryFitter.fit(c, anchorTime: 0)
    R.near(fr.g, 9.81, tol: 0.02, "robust fit ignores 4 contaminated trailing frames (g)")
    R.check(fr.weights[99] == 0, "contaminated frame rejected (weight 0), got \(fr.weights[99])")
    var opts = TrajectoryFitOptions(); opts.robust = false
    let fn = try TrajectoryFitter.fit(c, anchorTime: 0, options: opts)
    R.check(abs(fn.g - 9.81) > 0.1, "plain LSQ is visibly corrupted by the same frames (g=\(fmt(fn.g)))")
    R.check((try? TrajectoryFitter.fit(Array(s.prefix(4)), anchorTime: 0)) == nil, "too few samples is an error, not a number")
} catch { R.check(false, "fit threw: \(error)") }

// MARK: gravity gate
R.suite("GravityGate")
R.check(GravityGate.verdict(gFit: 9.81 * 1.07).verdict == .accept, "7% accepts")
R.check(GravityGate.verdict(gFit: 9.81 * 1.15).verdict == .lowConfidence, "15% low confidence")
R.check(GravityGate.verdict(gFit: 9.81 * 0.7).verdict == .reject, "30% rejects")
R.check(GravityGate.verdict(gFit: -9.81).verdict == .reject, "negative g rejects")
R.check(GravityGate.explain(gFit: 9.81 / 4).contains("4×"), "explains a 4× error as a frame-rate bug")

// MARK: ellipse
R.suite("Ellipse")
do {
    let e = Ellipse(center: SIMD2(960, 300), semiMajor: 48, semiMinor: 9, angle: rad(7))
    let back = e.conic.ellipse()!
    R.near(back.center.x, 960, tol: 1e-8, "conic→ellipse center x"); R.near(back.semiMajor, 48, tol: 1e-8, "semi-major"); R.near(back.semiMinor, 9, tol: 1e-8, "semi-minor"); R.near(deg(back.angle), 7, tol: 1e-6, "angle (normalised to [-90°, 90°))")
    let pts = (0..<40).map { e.point(at: 2 * .pi * Double($0) / 40) }
    let fit = EllipseFitter.fit(pts)!
    R.near(fit.ellipse.center.x, 960, tol: 1e-6, "fit center x"); R.near(fit.ellipse.center.y, 300, tol: 1e-6, "fit center y")
    R.near(fit.ellipse.semiMajor, 48, tol: 1e-6, "fit semi-major"); R.near(fit.ellipse.semiMinor, 9, tol: 1e-6, "fit semi-minor")
    R.near(fit.rmsResidual, 0, tol: 1e-6, "fit residual")
}

// MARK: rim calibration against the simulated camera
R.suite("RimCalibrator")
let shotFT = ShotParameters(releaseAngle: rad(50), releaseSpeed: 7.0, releaseHeight: 2.2, releaseDistance: Court.freeThrowLineToRimCenter)
for (view, dist, height, noise) in [(0.0, 8.0, 1.5, 0.0), (30.0, 8.0, 1.5, 0.0), (60.0, 7.0, 1.2, 0.0), (0.0, 8.0, 1.5, 0.3), (30.0, 9.0, 1.8, 0.3)] {
    let pl = CameraPlacement(viewAngle: rad(view), distance: dist, height: height, intrinsics: CameraPlacement.iPhone1080p())
    var o = SimulationOptions(); o.rimNoisePx = noise; o.seed = 7
    let sim = ShotSimulator.simulate(shotFT, placement: pl, options: o)
    do {
        let cal = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: pl.intrinsics)
        let centerErr = simd_length_local(cal.rimCenter - sim.truth.rimCenterCamera)
        let upErr = deg(angleBetweenLocal(cal.up, sim.truth.upCamera))
        let tolC = noise == 0 ? 0.005 : (view == 30.0 && dist == 9.0 ? 0.12 : 0.08), tolU = noise == 0 ? 0.05 : 0.6
        R.check(centerErr < tolC, "view \(view)° noise \(noise): rim centre error \(fmt(centerErr, 4)) m (tol \(tolC)); axis ratio \(fmt(cal.ellipse.axisRatio, 3))")
        R.check(upErr < tolU, "view \(view)° noise \(noise): up-vector error \(fmt(upErr, 3))° (tol \(tolU)); ambiguity \(fmt(deg(cal.ambiguityAngle), 1))°")
        R.check(cal.rimHeightAboveCamera > 0, "rim is above the camera")
    } catch { R.check(false, "calibration threw: \(error)") }
}

// MARK: azimuth solve + full pipeline on noiseless data
R.suite("ShotPlaneSolver + ShotAnalyzer noiseless")
for view in [0.0, 30.0, 55.0] {
    let pl = CameraPlacement(viewAngle: rad(view), distance: 8, height: 1.5, intrinsics: CameraPlacement.iPhone1080p())
    var o = SimulationOptions(); o.rimNoisePx = 0; o.noisePx = 0; o.fps = 240
    let sim = ShotSimulator.simulate(shotFT, placement: pl, options: o)
    do {
        let cal = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: pl.intrinsics)
        let a = try ShotAnalyzer.analyze(track: sim.samples, calibration: cal, intrinsics: pl.intrinsics)
        let nErr = deg(min(angleBetweenLocal(a.azimuth.frame.normal, sim.truth.planeNormalCamera), angleBetweenLocal(-a.azimuth.frame.normal, sim.truth.planeNormalCamera)))
        R.check(nErr < 0.2, "view \(view)°: plane normal error \(fmt(nErr, 3))°")
        R.near((a.metrics.release?.angleDegrees ?? .nan), 50, tol: 0.1, "view \(view)°: release angle")
        R.near(a.confidence.gFit, 9.81, tol: 0.05, "view \(view)°: g_fit")
        R.near((a.metrics.release?.height ?? .nan), 2.2, tol: 0.02, "view \(view)°: release height")
        R.near((a.metrics.release?.distance ?? .nan), Court.freeThrowLineToRimCenter, tol: 0.03, "view \(view)°: release distance")
        R.near(a.metrics.entryAngleDegrees ?? .nan, deg(sim.truth.entryAngle), tol: 0.15, "view \(view)°: entry angle")
        R.near(a.metrics.depthPastFrontRim ?? .nan, sim.truth.depthPastFrontRim, tol: 0.02, "view \(view)°: depth")
        R.near(a.window.releaseTime * o.fps, 0, tol: 0.5, "view \(view)°: release time error (frames)")
        R.near(a.confidence.viewAngle, sim.truth.viewAngle, tol: rad(1), "view \(view)°: view angle")
    } catch { R.check(false, "view \(view)° threw: \(error)") }
}

// MARK: release detection with noise
R.suite("FlightWindowFinder noisy")
do {
    let pl = CameraPlacement(viewAngle: rad(20), distance: 8, height: 1.5, intrinsics: CameraPlacement.iPhone1080p())
    var errs: [Double] = []
    for seed in 1...8 {
        var o = SimulationOptions(); o.noisePx = 1.5; o.fps = 240; o.seed = UInt64(seed)
        let sim = ShotSimulator.simulate(shotFT, placement: pl, options: o)
        let cal = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: pl.intrinsics)
        let a = try ShotAnalyzer.analyze(track: sim.samples, calibration: cal, intrinsics: pl.intrinsics)
        errs.append(a.window.releaseTime * o.fps)
    }
    let maxErr = errs.map(abs).max()!
    R.check(maxErr < 4.5 && abs(Stats.mean(errs)) < 3, "release time error over 8 seeds at 240 fps, 1.5 px: max \(fmt(maxErr, 2)) frames, mean \(fmt(Stats.mean(errs), 2))")
} catch { R.check(false, "threw: \(error)") }

// MARK: ball-scale fallback on a perpendicular view
R.suite("BallScaleAnalyzer")
do {
    let pl = CameraPlacement(viewAngle: 0, distance: 8, height: 1.5, intrinsics: CameraPlacement.iPhone1080p())
    var o = SimulationOptions(); o.fps = 240
    let sim = ShotSimulator.simulate(shotFT, placement: pl, options: o)
    let flight = sim.frames.filter { $0.phase == .flight && !$0.dropped }.dropFirst(2).map { ImageSample(t: $0.t, uv: $0.uv, diameterPx: $0.diameterPx) }
    let b = try BallScaleAnalyzer.analyze(flight: Array(flight), releaseTime: 0)
    R.near(deg(b.releaseAngle), 50, tol: 1.0, "release angle from image plane (perpendicular; camera pitch biases it ~0.8°)")
    R.check(abs(b.scaleDisagreement ?? 1) < 0.03, "gravity vs ball scale agree: \(fmt((b.scaleDisagreement ?? .nan) * 100, 2))%")
    let flight30 = ShotSimulator.simulate(shotFT, placement: CameraPlacement(viewAngle: rad(30), distance: 8, height: 1.5, intrinsics: pl.intrinsics), options: o)
        .frames.filter { $0.phase == .flight }.dropFirst(2).map { ImageSample(t: $0.t, uv: $0.uv, diameterPx: $0.diameterPx) }
    let b30 = try BallScaleAnalyzer.analyze(flight: Array(flight30), releaseTime: 0, assumedYaw: rad(30))
    R.check(deg(b30.releaseAngleMeasured) > 50.5, "30° yaw inflates the image-plane angle (orthographic prediction 54°, perspective softens it): \(fmt(deg(b30.releaseAngleMeasured), 2))°")
} catch { R.check(false, "threw: \(error)") }

// MARK: statistics
R.suite("Stats")
R.near(Stats.median([3, 1, 2]), 2, tol: 0, "median odd"); R.near(Stats.median([4, 1, 3, 2]), 2.5, tol: 0, "median even")
R.near(Stats.sd([2, 4, 4, 4, 5, 5, 7, 9]), 2.138, tol: 0.001, "sample sd")

exit(R.finish())

// local helpers (the library keeps its simd helpers internal)
func simd_length_local(_ v: SIMD3<Double>) -> Double { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }
func angleBetweenLocal(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let c = SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    return atan2(simd_length_local(c), a.x * b.x + a.y * b.y + a.z * b.z)
}
