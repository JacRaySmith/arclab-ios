import Foundation
import ShotGeometry
let rad = Angle.radians, deg = Angle.degrees
func fmt(_ x: Double, _ d: Int = 3) -> String { String(format: "%.\(d)f", x) }
let args = CommandLine.arguments
let fps = args.count > 1 ? Double(args[1])! : 240.0
let view = args.count > 2 ? Double(args[2])! : 0.0
let noise = args.count > 3 ? Double(args[3])! : 0.0
func arg(_ i: Int, _ d: Double) -> Double { args.count > i ? Double(args[i])! : d }
let p = ShotParameters(releaseAngle: rad(arg(4, 44.1)), releaseSpeed: arg(5, 7.18), releaseHeight: arg(6, 2.04), releaseDistance: arg(7, 4.19))
let pl = CameraPlacement(viewAngle: rad(view), distance: arg(8, 7.9), height: arg(9, 1.75), intrinsics: CameraPlacement.iPhone1080p())
var o = SimulationOptions(); o.fps = fps; o.noisePx = noise; o.rimNoisePx = 0.3; o.seed = UInt64(arg(10, 1)); o.diameterNoisePx = noise > 0 ? 1.0 : 0
let sim = ShotSimulator.simulate(p, placement: pl, options: o)
let cal = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: pl.intrinsics)
print("cal warnings", cal.warnings, "rim center err", cal.rimCenter - sim.truth.rimCenterCamera)
let a = try ShotAnalyzer.analyze(track: sim.samples, calibration: cal, intrinsics: pl.intrinsics)
let frames = sim.frames.filter { !$0.dropped && !$0.outOfFrame }
print("n samples", frames.count, "phases:", Dictionary(grouping: frames, by: { $0.phase.rawValue }).mapValues { $0.count })
print("window release idx", a.window.releaseIndex, "t", fmt(a.window.releaseTime, 4), "phase at idx", frames[a.window.releaseIndex].phase, "t", fmt(frames[a.window.releaseIndex].t, 4))
print("window end idx", a.window.endIndex, "phase", frames[a.window.endIndex].phase, "t", fmt(frames[a.window.endIndex].t, 4), "last flight t", fmt(sim.truth.timeOfFlight, 4))
print("anchor", a.window.anchorRange, "tau", fmt(a.window.tau, 4), "noiseFloor", fmt(a.window.noiseFloor, 5), "ramp k", fmt(a.window.rampCoefficient, 2), "notes", a.window.notes)
print("anchor fit g", fmt(a.window.anchorFit.g), "rms", fmt(a.window.anchorFit.rms, 5))
print("metrics θ", fmt((a.metrics.release?.angleDegrees ?? .nan), 2), "h", fmt((a.metrics.release?.height ?? .nan)), "g", fmt(a.confidence.gFit), "rmsPx", fmt(a.confidence.rmsPx), "view", fmt(deg(a.confidence.viewAngle), 1), "warnings", a.confidence.warnings)
// residual profile vs anchor fit around release
let plane = a.planeSamples
for i in stride(from: max(0, a.window.releaseIndex - 30), through: min(plane.count - 1, a.window.releaseIndex + 12), by: 1) {
    let pp = a.window.anchorFit.position(at: plane[i].t)
    let r = ((plane[i].x - pp.x) * (plane[i].x - pp.x) + (plane[i].y - pp.y) * (plane[i].y - pp.y)).squareRoot()
    print("  i", i, "t", fmt(plane[i].t, 4), frames[i].phase.rawValue, "res", fmt(r, 4), "x", fmt(plane[i].x), "y", fmt(plane[i].y))
}
