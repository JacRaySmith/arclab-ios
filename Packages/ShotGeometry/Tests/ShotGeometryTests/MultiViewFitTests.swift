import XCTest
import simd
@testable import ShotGeometry

/// `MultiViewFit`'s own correctness cases: a synthetic point built and projected by this file's own
/// cameras, so a failure here means the triangulation math is wrong, not that some footage was hard
/// (the same reasoning `FootKinematicsTests` uses for the foot triangle).
final class MultiViewFitTests: XCTestCase {

    let intrinsics = CameraPlacement.iPhone14Pro1080p120()

    /// A camera at `distance` from `target`, at `height`, on a bearing `angle` (radians) around it,
    /// always looking at `target`. Court frame: z up, matching the frame `CourtCalibration` is
    /// expected to hand `MultiViewFit` (docs/DESIGN-MULTIVIEW-2026-09-24.md §0).
    func camera(distance: Double, height: Double, bearing angle: Double, target: SIMD3<Double> = .zero) -> Camera {
        let pos = target + SIMD3(-distance * cos(angle), distance * sin(angle), height - target.z)
        return Camera(intrinsics: intrinsics, pose: .lookAt(from: pos, at: target, worldUp: SIMD3(0, 0, 1)))
    }

    func testKnownPointRecoveredToTolerance() throws {
        let truth = SIMD3<Double>(0.3, -0.2, 2.1)
        let camA = camera(distance: 5, height: 1.4, bearing: 0)
        let camB = camera(distance: 5, height: 1.4, bearing: Angle.radians(60))
        let pxA = try XCTUnwrap(camA.project(world: truth)?.pixel)
        let pxB = try XCTUnwrap(camB.project(world: truth)?.pixel)
        let obs = [MultiViewFit.Observation(view: "A", camera: camA, pixel: pxA, confidence: 1),
                   MultiViewFit.Observation(view: "B", camera: camB, pixel: pxB, confidence: 1)]
        let r = MultiViewFit.triangulate(name: "test", observations: obs)
        let p = try XCTUnwrap(r.position)
        // Noiseless, exact rays: recovered to numerical precision, not just "close".
        XCTAssertEqual(norm(p - truth), 0, accuracy: 1e-6)
        // The two cameras are placed 60° apart around the look-at target (the origin); the truth
        // point is offset from that target, so the parallax angle *at the point* is close to but not
        // exactly 60° — this checks it is in the right ballpark, not that it equals the placement angle.
        XCTAssertEqual(Angle.degrees(try XCTUnwrap(r.bearingSeparationRadians)), 60, accuracy: 10)
        XCTAssertEqual(r.rmsResidualMetres ?? .nan, 0, accuracy: 1e-9)
        XCTAssertNil(r.unavailableReason)
    }

    func testKnownPointRecoveredUnderRealisticNoise() throws {
        let truth = SIMD3<Double>(0.1, 0.05, 1.9)
        let camA = camera(distance: 5, height: 1.4, bearing: 0)
        let camB = camera(distance: 5, height: 1.4, bearing: Angle.radians(60))
        let pxA = try XCTUnwrap(camA.project(world: truth)?.pixel)
        let pxB = try XCTUnwrap(camB.project(world: truth)?.pixel)
        var rng = SeededRNG(seed: 7)
        let noisyA = pxA + SIMD2(rng.gaussian(sd: 1.85), rng.gaussian(sd: 1.85))
        let noisyB = pxB + SIMD2(rng.gaussian(sd: 1.85), rng.gaussian(sd: 1.85))
        let obs = [MultiViewFit.Observation(view: "A", camera: camA, pixel: noisyA, confidence: 1),
                   MultiViewFit.Observation(view: "B", camera: camB, pixel: noisyB, confidence: 1)]
        let r = MultiViewFit.triangulate(name: "test", observations: obs)
        let p = try XCTUnwrap(r.position)
        // At 5 m / 1.85 px / 60° separation the error should be a couple of centimetres, not metres.
        XCTAssertLessThan(norm(p - truth), 0.05)
        XCTAssertNotNil(r.uncertaintyMetres)
    }

    func testNearParallelRaysAreRefused() throws {
        let truth = SIMD3<Double>(0, 0, 2.0)
        let camA = camera(distance: 6, height: 1.5, bearing: 0)
        let camB = camera(distance: 6, height: 1.5, bearing: Angle.radians(2))
        let pxA = try XCTUnwrap(camA.project(world: truth)?.pixel)
        let pxB = try XCTUnwrap(camB.project(world: truth)?.pixel)
        let obs = [MultiViewFit.Observation(view: "A", camera: camA, pixel: pxA, confidence: 1),
                   MultiViewFit.Observation(view: "B", camera: camB, pixel: pxB, confidence: 1)]
        let r = MultiViewFit.triangulate(name: "test", observations: obs)
        XCTAssertNil(r.position)
        let reason = try XCTUnwrap(r.unavailableReason)
        XCTAssertTrue(reason.contains("parallel"), reason)
    }

    func testSingleViewIsRefused() {
        let camA = camera(distance: 6, height: 1.5, bearing: 0)
        let obs = [MultiViewFit.Observation(view: "A", camera: camA, pixel: SIMD2(960, 540), confidence: 1)]
        let r = MultiViewFit.triangulate(name: "test", observations: obs)
        XCTAssertNil(r.position)
        XCTAssertTrue((r.unavailableReason ?? "").contains("only 1 view"))
    }

    func testNoViewIsRefused() {
        let r = MultiViewFit.triangulate(name: "test", observations: [])
        XCTAssertNil(r.position)
        XCTAssertEqual(r.unavailableReason, "no view observed this joint")
    }

    func testLowConfidenceViewIsDroppedNotTrusted() throws {
        let truth = SIMD3<Double>(0, 0, 2.0)
        let camA = camera(distance: 6, height: 1.5, bearing: 0)
        let camB = camera(distance: 6, height: 1.5, bearing: Angle.radians(50))
        let pxA = try XCTUnwrap(camA.project(world: truth)?.pixel)
        let pxB = try XCTUnwrap(camB.project(world: truth)?.pixel)
        let obs = [MultiViewFit.Observation(view: "A", camera: camA, pixel: pxA, confidence: 1),
                   MultiViewFit.Observation(view: "B", camera: camB, pixel: pxB, confidence: 0.1)]
        let r = MultiViewFit.triangulate(name: "test", observations: obs, options: MultiViewFit.Options())
        XCTAssertNil(r.position)
        XCTAssertTrue((r.unavailableReason ?? "").contains("only 1 view"))
    }

    func testThirdViewImprovesOverTwo() throws {
        let truth = SIMD3<Double>(0.2, -0.1, 2.0)
        let cams = [camera(distance: 5, height: 1.4, bearing: 0), camera(distance: 5, height: 1.4, bearing: Angle.radians(40)),
                    camera(distance: 5, height: 1.4, bearing: Angle.radians(80))]
        var rng = SeededRNG(seed: 42)
        func observe(_ cams: [Camera]) throws -> [MultiViewFit.Observation] {
            try cams.enumerated().map { i, c in
                let px = try XCTUnwrap(c.project(world: truth)?.pixel)
                let noisy = px + SIMD2(rng.gaussian(sd: 1.85), rng.gaussian(sd: 1.85))
                return MultiViewFit.Observation(view: "\(i)", camera: c, pixel: noisy, confidence: 1)
            }
        }
        let twoView = try observe(Array(cams.prefix(2)))
        rng = SeededRNG(seed: 42)
        let threeView = try observe(cams)
        let r2 = MultiViewFit.triangulate(name: "test", observations: twoView)
        let r3 = MultiViewFit.triangulate(name: "test", observations: threeView)
        XCTAssertNotNil(r2.position); XCTAssertNotNil(r3.position)
        // A third, well-separated ray adds information: the reported uncertainty should not grow.
        if let u2 = r2.uncertaintyMetres, let u3 = r3.uncertaintyMetres { XCTAssertLessThanOrEqual(u3, u2 * 1.01) }
    }
}
