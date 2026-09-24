import XCTest
@testable import ShotGeometry

/// `RimGravity.arbitrate` — the rule that picks between a shooter's hand trace and an automatically
/// found trace of the same rim, using nothing but how far each disagrees with a measured gravity
/// direction (`RimGravity.compare(...).disagreement` on each candidate).
///
/// The real numbers below are `RimGravity.compare` run on `footage/2026-09-13/rim_1766.json` (hand)
/// and `rim_1766_found.json` (auto-found) against that clip's measured vertical — reproduced here to
/// 3 significant figures matching both `docs/research/three-point-acceptance-2026-09-24.md` §2 and
/// `RimGravityCheckTests`'s own record of the same comparison. Recomputing them directly against the
/// gitignored footage during this task (same method, same hFOV 64°, same `MeasuredVertical` up
/// vector) reproduced 15.019° and 0.538° — no discrepancy from the recorded 15.02° / 0.54°.
final class RimGravityArbitrationTests: XCTestCase {

    /// The case this rule exists for: a hand trace that wandered onto the backboard bracket, 15.02°
    /// off gravity, against an auto-found trace 0.54° off — the gap (14.48°) is nowhere near the 3°
    /// margin, so the auto-found candidate must win.
    func testTheRealThreePointCorpusCaseAutoFoundWins() {
        let a = RimGravity.arbitrate(tracedDisagreement: Angle.radians(15.02),
                                     autoFoundDisagreement: Angle.radians(0.54))
        XCTAssertEqual(a.winner, .autoFound)
        XCTAssertTrue(a.usedRimTheShooterDidNotDraw)
        XCTAssertEqual(Angle.degrees(a.tracedDisagreement!), 15.02, accuracy: 1e-9)
        XCTAssertEqual(Angle.degrees(a.autoFoundDisagreement!), 0.54, accuracy: 1e-9)
    }

    /// The two 2026-09-13 control clips, both hand traces already close to gravity: the auto-found
    /// candidate is a little closer on each (1.37° vs 1.24°, 3.26° vs 1.72°) but the gap is well under
    /// the margin, so the shooter's own trace must be kept — switching here would be relitigating a
    /// trace that was never in question. Also pins that "closer" alone is not the rule; "closer by
    /// more than the margin" is.
    func testNearTiesKeepTheShootersTrace() {
        let elbow = RimGravity.arbitrate(tracedDisagreement: Angle.radians(1.37),
                                         autoFoundDisagreement: Angle.radians(1.24))
        XCTAssertEqual(elbow.winner, .traced)
        XCTAssertFalse(elbow.usedRimTheShooterDidNotDraw)

        let freeThrow = RimGravity.arbitrate(tracedDisagreement: Angle.radians(3.26),
                                             autoFoundDisagreement: Angle.radians(1.72))
        XCTAssertEqual(freeThrow.winner, .traced)

        // Exactly at the margin: the auto-found side must beat the trace by *more* than the margin,
        // not merely by it — a boundary a flaky ">=" would get wrong silently.
        let atMargin = RimGravity.arbitrate(tracedDisagreement: Angle.radians(5),
                                            autoFoundDisagreement: Angle.radians(5) - RimGravity.arbitrationMargin)
        XCTAssertEqual(atMargin.winner, .traced, "exactly at the margin must not flip the shooter's trace")

        let justPastMargin = RimGravity.arbitrate(tracedDisagreement: Angle.radians(5),
                                                   autoFoundDisagreement: Angle.radians(5) - RimGravity.arbitrationMargin - Angle.radians(0.01))
        XCTAssertEqual(justPastMargin.winner, .autoFound, "a hair past the margin must flip it")
    }

    /// No measured gravity for the clip: there is nothing to arbitrate with, so today's behaviour is
    /// unchanged — the trace wins, and both disagreements come back nil rather than a guessed zero.
    func testGravityUnavailableKeepsTheTraceAndReportsNil() {
        let a = RimGravity.arbitrate(tracedDisagreement: nil, autoFoundDisagreement: nil)
        XCTAssertEqual(a.winner, .traced)
        XCTAssertFalse(a.usedRimTheShooterDidNotDraw)
        XCTAssertNil(a.tracedDisagreement)
        XCTAssertNil(a.autoFoundDisagreement)
    }

    /// The finder never ran, found nothing, or its candidate would not solve: only the trace's own
    /// disagreement exists. Nothing to arbitrate with a single candidate, so the trace wins.
    func testFinderFailedKeepsTheTrace() {
        let a = RimGravity.arbitrate(tracedDisagreement: Angle.radians(15.02), autoFoundDisagreement: nil)
        XCTAssertEqual(a.winner, .traced)
        XCTAssertFalse(a.usedRimTheShooterDidNotDraw)
        XCTAssertEqual(Angle.degrees(a.tracedDisagreement!), 15.02, accuracy: 1e-9)
        XCTAssertNil(a.autoFoundDisagreement)

        // The reverse gap — gravity has no opinion on the trace itself (it would not solve) but the
        // auto-found candidate does. Still nothing to arbitrate: a lone auto-found number is not
        // grounds to override a trace whose own disagreement is unknown.
        let b = RimGravity.arbitrate(tracedDisagreement: nil, autoFoundDisagreement: Angle.radians(0.54))
        XCTAssertEqual(b.winner, .traced)
        XCTAssertNil(b.tracedDisagreement)
        XCTAssertEqual(Angle.degrees(b.autoFoundDisagreement!), 0.54, accuracy: 1e-9)
    }
}
