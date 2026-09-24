import XCTest
import simd
@testable import ShotGeometry

/// `MultiViewSync`'s correctness cases, built on `ShotSimulator`'s own free-throw parabola so the
/// "known synthetic case" is the same physics the rest of this package already trusts.
final class MultiViewSyncTests: XCTestCase {

    let params = ShotParameters(releaseAngle: Angle.radians(50), releaseSpeed: 7.0, releaseHeight: 2.2,
                                releaseDistance: Court.freeThrowLineToRimCenter)

    func cameras(viewADeg: Double, viewBDeg: Double, distance: Double = 8, height: Double = 1.5) -> (Camera, Camera) {
        let plA = CameraPlacement(viewAngle: Angle.radians(viewADeg), distance: distance, height: height, intrinsics: CameraPlacement.iPhone14Pro1080p120())
        let plB = CameraPlacement(viewAngle: Angle.radians(viewBDeg), distance: distance, height: height, intrinsics: CameraPlacement.iPhone14Pro1080p120())
        return (ShotSimulator.makeCamera(params, placement: plA), ShotSimulator.makeCamera(params, placement: plB))
    }

    /// Two views of the same flight. `offsetTrue` is stamped onto view B's own timestamps, so a
    /// correct `estimateOffset` call should recover it (per the offset's stated convention:
    /// `tA + offset ≈ tB` for the same real instant).
    func ballTracks(camA: Camera, camB: Camera, offsetTrue: Double, seed: UInt64 = 11) -> ([ImageSample], [ImageSample]) {
        var rngA = SeededRNG(seed: seed), rngB = SeededRNG(seed: seed &+ 1)
        let tStar = ShotSimulator.flightTime(params)
        var vA: [ImageSample] = [], vB: [ImageSample] = []
        var t = 0.0
        while t <= tStar {
            let (w, _) = ShotSimulator.worldPosition(params, t: t, options: SimulationOptions())
            if let pxA = camA.project(world: w)?.pixel {
                vA.append(ImageSample(t: t, uv: pxA + SIMD2(rngA.gaussian(sd: 1.85), rngA.gaussian(sd: 1.85))))
            }
            if let pxB = camB.project(world: w)?.pixel {
                vB.append(ImageSample(t: t + offsetTrue, uv: pxB + SIMD2(rngB.gaussian(sd: 1.85), rngB.gaussian(sd: 1.85))))
            }
            t += 1.0 / 240
        }
        return (vA, vB)
    }

    func testKnownOffsetRecoveredToTolerance() throws {
        let (camA, camB) = cameras(viewADeg: 0, viewBDeg: 60)
        let trueOffset = 0.015   // 15 ms: a plausible "two thumbs hit record" desync
        let (vA, vB) = ballTracks(camA: camA, camB: camB, offsetTrue: trueOffset)
        let r = MultiViewSync.estimateOffset(viewA: vA, cameraA: camA, viewB: vB, cameraB: camB)
        let recovered = try XCTUnwrap(r.offsetSeconds, "sync estimator refused: \(r.unavailableReason ?? "")")
        XCTAssertEqual(recovered, trueOffset, accuracy: 0.003)   // within ~0.7 frame at 240 fps
        if let sigma = r.uncertaintySeconds { XCTAssertLessThan(sigma, 0.01) }
    }

    func testLargerKnownOffsetRecoveredToTolerance() throws {
        let (camA, camB) = cameras(viewADeg: 0, viewBDeg: 60)
        let trueOffset = -0.180   // 180 ms the other way, still well inside the ±1 s search range
        let (vA, vB) = ballTracks(camA: camA, camB: camB, offsetTrue: trueOffset, seed: 21)
        let r = MultiViewSync.estimateOffset(viewA: vA, cameraA: camA, viewB: vB, cameraB: camB)
        let recovered = try XCTUnwrap(r.offsetSeconds, "sync estimator refused: \(r.unavailableReason ?? "")")
        XCTAssertEqual(recovered, trueOffset, accuracy: 0.004)
    }

    func testStationaryPointRefusesFlatFit() {
        let (camA, camB) = cameras(viewADeg: 0, viewBDeg: 60)
        // A point that does not move carries no timing information: the triangulation residual is
        // (noise alone) flat in the candidate offset, which is exactly the case the curvature/noise
        // gate exists to catch.
        let truth = SIMD3<Double>(0, 0, -Court.rimHeight + 2.2)
        guard let pxA = camA.project(world: truth)?.pixel, let pxB = camB.project(world: truth)?.pixel else {
            XCTFail("truth point not visible"); return
        }
        var rngA = SeededRNG(seed: 5), rngB = SeededRNG(seed: 6)
        let times = stride(from: 0.0, through: 0.3, by: 1.0 / 240).map { $0 }
        let vA = times.map { ImageSample(t: $0, uv: pxA + SIMD2(rngA.gaussian(sd: 1.85), rngA.gaussian(sd: 1.85))) }
        let vB = times.map { ImageSample(t: $0, uv: pxB + SIMD2(rngB.gaussian(sd: 1.85), rngB.gaussian(sd: 1.85))) }
        let r = MultiViewSync.estimateOffset(viewA: vA, cameraA: camA, viewB: vB, cameraB: camB)
        XCTAssertNil(r.offsetSeconds)
        XCTAssertNotNil(r.unavailableReason)
    }

    func testShortTrackIsRefused() {
        let (camA, camB) = cameras(viewADeg: 0, viewBDeg: 60)
        let (vAFull, vBFull) = ballTracks(camA: camA, camB: camB, offsetTrue: 0.0)
        let vA = Array(vAFull.prefix(3)), vB = Array(vBFull.prefix(3))   // fewer than Options.minimumSamples
        let r = MultiViewSync.estimateOffset(viewA: vA, cameraA: camA, viewB: vB, cameraB: camB)
        XCTAssertNil(r.offsetSeconds)
        XCTAssertTrue((r.unavailableReason ?? "").contains("too short"), r.unavailableReason ?? "")
    }

    func testPositionErrorEstimateIsSpeedTimesTime() {
        XCTAssertEqual(MultiViewSync.positionErrorEstimateMetres(speedMetresPerSecond: 7, syncErrorSeconds: 1.0 / 240), 7.0 / 240, accuracy: 1e-9)
        XCTAssertEqual(MultiViewSync.positionErrorEstimateMetres(speedMetresPerSecond: -3, syncErrorSeconds: -0.01), 0.03, accuracy: 1e-9)
    }
}
