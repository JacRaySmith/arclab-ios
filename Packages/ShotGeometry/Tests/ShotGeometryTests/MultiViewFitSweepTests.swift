import XCTest
import simd
@testable import ShotGeometry

/// The deliverable sweeps for `docs/DESIGN-MULTIVIEW-2026-09-24.md`: how the recovered-joint error
/// depends on (1) the bearing separation between the two cameras and (2) an uncorrected sync error
/// between the two clips, holding everything else fixed. Both use `MultiViewFit.Options`'s own
/// default 2-D noise (1.85 px — the FormEval whole-skeleton reprojection RMS median,
/// `docs/research/form-eval-baseline-2026-09-16.md` §1), not an invented figure.
///
/// These are measurements, not regressions: the printed tables (`swift test --filter
/// MultiViewFitSweepTests -v`) are what the design doc's sweep tables are built from. The
/// assertions here are loose monotonicity sanity checks, kept so a future change that breaks the
/// geometry fails loudly, not tight bounds on numbers that belong in the doc.
final class MultiViewFitSweepTests: XCTestCase {

    let intrinsics = CameraPlacement.iPhone14Pro1080p120()
    let pixelNoise = 1.85
    let duration = 0.5
    let fps = 240.0
    /// Roughly the centre of the synthetic joint path below, so every camera keeps it framed.
    let target = SIMD3<Double>(0.15, 0, 1.6)

    /// A synthetic shooting-motion path for one joint (a release-side wrist): rising from the set
    /// position to release with a bit of forward drive and a small natural lateral wobble, in a
    /// court frame with the shooter facing +x and z up — the frame `CourtCalibration` is expected to
    /// hand this file (docs/DESIGN-MULTIVIEW-2026-09-24.md §0).
    func jointPosition(_ t: Double) -> SIMD3<Double> {
        let s = min(max(t / duration, 0), 1)
        let height = 1.0 + 1.2 * s + 0.15 * sin(.pi * s)
        let forward = 0.35 * s
        let lateral = 0.05 * sin(2 * .pi * s)
        return SIMD3(forward, lateral, height)
    }
    func jointSpeed(_ t: Double, dt: Double = 1e-4) -> Double {
        norm(jointPosition(t + dt) - jointPosition(t - dt)) / (2 * dt)
    }

    func camera(distance: Double, height: Double, bearing angle: Double) -> Camera {
        let pos = target + SIMD3(-distance * cos(angle), distance * sin(angle), height - target.z)
        return Camera(intrinsics: intrinsics, pose: .lookAt(from: pos, at: target, worldUp: SIMD3(0, 0, 1)))
    }

    func percentile(_ xs: [Double], _ p: Double) -> Double? {
        let v = xs.filter(\.isFinite).sorted()
        guard !v.isEmpty else { return nil }
        let h = (Double(v.count) - 1) * min(max(p, 0), 1)
        let lo = Int(h.rounded(.down)), hi = min(lo + 1, v.count - 1)
        return v[lo] + (h - Double(lo)) * (v[hi] - v[lo])
    }
    func fmt(_ x: Double?, _ f: String = "%.1f") -> String { x.map { String(format: f, $0) } ?? "—" }

    // MARK: - Table 1: error vs. camera bearing separation

    func testBearingSeparationSweep() {
        let samples = stride(from: 0.0, to: duration, by: 1 / fps).map { $0 }
        let cameraDistance = 5.0, cameraHeight = 1.4
        let bearingsDeg: [Double] = [2, 5, 8, 10, 15, 20, 30, 45, 60, 90, 120]
        var summary: [(deg: Double, medianErr: Double?)] = []

        print("\n=== Table 1: recovered-joint error vs. camera bearing separation ===")
        print("| target bearing (deg) | achieved (deg) | refused | median err (mm) | p90 err (mm) | median reported σ (mm) |")
        print("|---:|---:|---:|---:|---:|---:|")
        for bDeg in bearingsDeg {
            let camA = camera(distance: cameraDistance, height: cameraHeight, bearing: 0)
            let camB = camera(distance: cameraDistance, height: cameraHeight, bearing: Angle.radians(bDeg))
            var rng = SeededRNG(seed: 1000 + UInt64(bDeg))
            var errorsMm: [Double] = [], sigmasMm: [Double] = [], achievedDeg: [Double] = []
            var refused = 0
            for t in samples {
                let p = jointPosition(t)
                guard let pxA = camA.project(world: p)?.pixel, let pxB = camB.project(world: p)?.pixel else { refused += 1; continue }
                let noisyA = pxA + SIMD2(rng.gaussian(sd: pixelNoise), rng.gaussian(sd: pixelNoise))
                let noisyB = pxB + SIMD2(rng.gaussian(sd: pixelNoise), rng.gaussian(sd: pixelNoise))
                let obs = [MultiViewFit.Observation(view: "A", camera: camA, pixel: noisyA, confidence: 1),
                           MultiViewFit.Observation(view: "B", camera: camB, pixel: noisyB, confidence: 1)]
                let r = MultiViewFit.triangulate(name: "wrist", observations: obs)
                guard let pos = r.position else { refused += 1; continue }
                errorsMm.append(norm(pos - p) * 1000)
                if let u = r.uncertaintyMetres { sigmasMm.append(u * 1000) }
                if let bear = r.bearingSeparationRadians { achievedDeg.append(Angle.degrees(bear)) }
            }
            let medianErr = percentile(errorsMm, 0.5), p90Err = percentile(errorsMm, 0.9)
            let medianSigma = percentile(sigmasMm, 0.5)
            print("| \(Int(bDeg)) | \(fmt(achievedDeg.first)) | \(refused)/\(samples.count) | \(fmt(medianErr)) | \(fmt(p90Err)) | \(fmt(medianSigma)) |")
            summary.append((bDeg, medianErr))
        }

        // Sanity, not a regression bound: past the near-parallel gate, wider separation should not
        // make the median error dramatically worse, and 8° should already beat 2° (which the default
        // gate refuses outright, so its row above is "refused" throughout).
        if let e8 = summary.first(where: { $0.deg == 8 })?.medianErr, let e60 = summary.first(where: { $0.deg == 60 })?.medianErr {
            XCTAssertLessThan(e60, e8)
        }
    }

    // MARK: - Table 2: error vs. uncorrected sync error, at a fixed, workable bearing

    func testSyncErrorSweep() {
        let cameraDistance = 5.0, cameraHeight = 1.4
        let bearingDeg = 60.0   // the separation Table 1 recommends; see the design doc §4-5.
        let camA = camera(distance: cameraDistance, height: cameraHeight, bearing: 0)
        let camB = camera(distance: cameraDistance, height: cameraHeight, bearing: Angle.radians(bearingDeg))
        let syncErrorsMs: [Double] = [0, 1, 2, 4.167, 8.333, 16.67, 33.3, 66.7]  // 0 … one frame at 240/120/60/30 fps
        let samples = stride(from: 0.05, to: duration - 0.05, by: 1 / fps).map { $0 }   // margin so t+τ stays in range

        print("\n=== Table 2: recovered-joint error vs. uncorrected sync error (bearing fixed at \(Int(bearingDeg))°) ===")
        print("| sync error (ms) | median err (mm) | p90 err (mm) | median joint speed (m/s) | naive speed×τ (mm) |")
        print("|---:|---:|---:|---:|---:|")
        var results: [(ms: Double, medianErr: Double?)] = []
        for msErr in syncErrorsMs {
            let tau = msErr / 1000
            var rng = SeededRNG(seed: 2000 + UInt64(msErr * 100))
            var errorsMm: [Double] = [], speeds: [Double] = []
            for t in samples {
                let pRef = jointPosition(t)          // what a system assuming simultaneity believes it measured
                let pShifted = jointPosition(t + tau) // where camera B's clock actually was pointing
                guard let pxA = camA.project(world: pRef)?.pixel, let pxB = camB.project(world: pShifted)?.pixel else { continue }
                let noisyA = pxA + SIMD2(rng.gaussian(sd: pixelNoise), rng.gaussian(sd: pixelNoise))
                let noisyB = pxB + SIMD2(rng.gaussian(sd: pixelNoise), rng.gaussian(sd: pixelNoise))
                let obs = [MultiViewFit.Observation(view: "A", camera: camA, pixel: noisyA, confidence: 1),
                           MultiViewFit.Observation(view: "B", camera: camB, pixel: noisyB, confidence: 1)]
                guard let pos = MultiViewFit.triangulate(name: "wrist", observations: obs).position else { continue }
                errorsMm.append(norm(pos - pRef) * 1000)
                speeds.append(jointSpeed(t))
            }
            let medianErr = percentile(errorsMm, 0.5), p90Err = percentile(errorsMm, 0.9)
            let medianSpeed = percentile(speeds, 0.5) ?? .nan
            let naive = MultiViewSync.positionErrorEstimateMetres(speedMetresPerSecond: medianSpeed, syncErrorSeconds: tau) * 1000
            print(String(format: "| %.2f | %@ | %@ | %.2f | %.1f |", msErr, fmt(medianErr), fmt(p90Err), medianSpeed, naive))
            results.append((msErr, medianErr))
        }

        // Sanity: error should not be smaller at a larger sync error than at zero.
        if let e0 = results.first(where: { $0.ms == 0 })?.medianErr, let eBig = results.first(where: { $0.ms == 66.7 })?.medianErr {
            XCTAssertLessThanOrEqual(e0, eBig)
        }
    }
}
