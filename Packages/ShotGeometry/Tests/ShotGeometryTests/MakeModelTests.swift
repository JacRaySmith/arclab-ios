import XCTest
@testable import ShotGeometry

final class MakeModelTests: XCTestCase {
    func testDepthIsInsensitiveToAngleNearTurnover() throws {
        // 2026-09-13 simulation: at the FT line (h 2.1 m) ∂depth/∂θ crosses zero near 51°, ∂depth/∂v ≈ 1.5 m per m/s.
        let L = 4.191, h = 2.1
        let turnover = try XCTUnwrap(ReleaseSensitivity.depthTurnoverAngle(v: 7.17, h: h, L: L))
        XCTAssertEqual(Angle.degrees(turnover), 51.3, accuracy: 1.5)
        let s = try XCTUnwrap(ReleaseSensitivity.at(theta: Angle.radians(50), v: 7.18, h: h, L: L))
        XCTAssertEqual(s.dDepth_dV, 1.52, accuracy: 0.1)                       // 0.1 m/s ≈ 15 cm
        XCTAssertLessThan(abs(s.dDepth_dTheta) * Angle.radians(1), 0.02)      // < 2 cm per degree
        let flat = try XCTUnwrap(ReleaseSensitivity.at(theta: Angle.radians(44), v: 7.33, h: h, L: L))
        XCTAssertEqual(flat.dDepth_dTheta * Angle.radians(1), 0.072, accuracy: 0.015)   // 7 cm per degree when flat
    }

    func testCleanPassGeometry() {
        let entry = Angle.radians(45)
        XCTAssertTrue(MakeGeometry.cleanPass(RimCrossing(along: 0, lateral: 0, entryAngle: entry)))
        XCTAssertFalse(MakeGeometry.cleanPass(RimCrossing(along: 0.12, lateral: 0, entryAngle: entry)))
        XCTAssertFalse(MakeGeometry.cleanPass(RimCrossing(along: 0, lateral: 0.12, entryAngle: entry)))
        // Below the entry floor nothing passes cleanly, even dead centre.
        XCTAssertFalse(MakeGeometry.cleanPass(RimCrossing(along: 0, lateral: 0, entryAngle: Physics.entryFloor() - 0.01)))
        XCTAssertTrue(MakeGeometry.cleanPass(RimCrossing(along: 0, lateral: 0, entryAngle: Physics.entryFloor() + 0.02)))
    }

    func testSpeedDominatesDepthVariance() throws {
        // Worked shooter from the Ch 5 digest: mean (52°, 7.10, 2.20), SD (2°, 0.09, 0.035), corr θv −0.45, θh 0.20, vh 0.10.
        let s = try XCTUnwrap(ReleaseSensitivity.at(theta: Angle.radians(52), v: 7.10, h: 2.20, L: 4.19))
        let sd = [Angle.radians(2), 0.09, 0.035]
        let corr = [[1.0, -0.45, 0.20], [-0.45, 1.0, 0.10], [0.20, 0.10, 1.0]]
        var cov = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { cov[i][j] = sd[i] * sd[j] * corr[i][j] } }
        let a = try XCTUnwrap(DepthVarianceAttribution.compute(sensitivity: s, covariance: cov))
        XCTAssertEqual(a.sdDepth, 0.149, accuracy: 0.01)          // digest: 14.92 cm
        XCTAssertEqual(a.speedShare, 0.771, accuracy: 0.03)       // digest: 77.1 %
        XCTAssertEqual(a.thetaShare, 0.018, accuracy: 0.01)
        XCTAssertEqual(a.thetaShare + a.speedShare + a.heightShare + a.covarianceShare, 1, accuracy: 1e-9)
    }

    func testPlaceholderSoftModelIsFlagged() {
        let m = SoftMakeModel()
        XCTAssertFalse(m.isFitted)
        XCTAssertEqual(m.probability(RimCrossing(along: 0.03, lateral: 0, entryAngle: 0.7)), 0.92, accuracy: 1e-9)
        XCTAssertLessThan(m.probability(RimCrossing(along: 0.25, lateral: 0, entryAngle: 0.7)), 0.15)
        XCTAssertEqual(m.expectedMakesPer100([nil, nil]), 0)
    }
}
