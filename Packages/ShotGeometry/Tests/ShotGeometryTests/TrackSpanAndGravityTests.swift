import XCTest
@testable import ShotGeometry

/// How long an arc has to be before `g` means anything.
///
/// The gravity gate (|g_fit − 9.81| / 9.81 ≤ 0.08) is what refuses 19 of the 31 labelled-real shots
/// the 2026-09-13 corpus still throws away, and their `g_fit / 9.81` is scattered from −2.04 to
/// +16.04. Measured 2026-09-27, those same windows carry a **median 34 samples over a 0.32 s span**,
/// against **122 samples over 1.08 s** for the windows that are accepted — a quarter of the arc.
///
/// Curvature is the only thing that carries `g`, and the sagitta of a parabola over a span `T` is
/// `g·T²/8`, so the signal falls off as `T²` while the noise does not. `TrajectoryFitOptions`
/// currently admits any span ≥ 0.15 s. These tests measure where the gate actually becomes
/// unmeasurable, so that a track too short to carry `g` can be refused *as such* rather than fitted
/// and then rejected for a `g` of −20 m/s² — which is a fabricated number, not a measurement
/// (CLAUDE.md rule 1).
final class TrackSpanAndGravityTests: XCTestCase {

    /// Free flight only, `span` seconds of it, with Gaussian plane noise.
    private func arc(span: Double, fps: Double, noise: Double, seed: UInt64) -> [TrajectorySample] {
        var rng = SeededRNG(seed: seed)
        let theta = Angle.radians(48), speed = 7.1
        let vx = speed * cos(theta), vy = speed * sin(theta)
        var out: [TrajectorySample] = []
        var t = 0.0
        while t <= span + 1e-9 {
            out.append(TrajectorySample(t: t,
                                        x: vx * t + rng.gaussian(sd: noise),
                                        y: vy * t - 0.5 * Court.g * t * t + rng.gaussian(sd: noise)))
            t += 1 / fps
        }
        return out
    }

    /// Fraction of draws whose free-g fit lands inside the 8 % gate.
    private func passRate(span: Double, noise: Double, fps: Double = 120, draws: Int = 200) -> Double {
        var ok = 0, n = 0
        for seed in 0..<UInt64(draws) {
            let s = arc(span: span, fps: fps, noise: noise, seed: seed &+ 1)
            var o = TrajectoryFitOptions(); o.minimumSpan = 0
            guard s.count >= o.minimumSamples, let f = try? TrajectoryFitter.fit(s, anchorTime: 0, options: o) else { continue }
            n += 1
            if GravityGate.verdict(gFit: f.g).verdict == .accept { ok += 1 }
        }
        return n > 0 ? Double(ok) / Double(n) : 0
    }

    func testTheSpanAtWhichGravityStopsBeingMeasurable() {
        // 0.007 m ≈ 1.5 px at 7 m on a 1536 px focal length — the clean case.
        // 0.030 m is what a track the detector is struggling with looks like.
        print("\n  span(s) | pass rate of the 8 % gravity gate, 120 fps")
        print("          |  noise 0.007 m   noise 0.015 m   noise 0.030 m")
        var firstCleanPass: Double? = nil
        for span in [0.15, 0.20, 0.25, 0.32, 0.40, 0.50, 0.70, 1.00] {
            let a = passRate(span: span, noise: 0.007)
            let b = passRate(span: span, noise: 0.015)
            let c = passRate(span: span, noise: 0.030)
            print(String(format: "    %.2f   |     %5.1f %%         %5.1f %%         %5.1f %%", span, a*100, b*100, c*100))
            if firstCleanPass == nil && a >= 0.95 { firstCleanPass = span }
        }
        print("")
        // The corpus's accepted windows span ~1.08 s and its gravity-refused ones ~0.32 s.
        XCTAssertGreaterThanOrEqual(passRate(span: 1.00, noise: 0.007), 0.95,
                                    "a full 1 s arc must pass the gate essentially always when the track is clean")
    }

    /// The headline, stated as what was actually measured rather than what was guessed: at the span
    /// the refused windows have, span alone is **not** the explanation — a cleanly tracked 0.32 s arc
    /// passes the gate 98 % of the time. It is span **and** noise together: at 0.030 m the same span
    /// is a coin toss (measured 51.5 %). So the refusals are short arcs of poorly-tracked ball, and
    /// fixing either one would move them.
    func testAtTheRefusedWindowsSpanItIsNoiseThatDecidesTheGate() {
        let clean = passRate(span: 0.32, noise: 0.007)
        let noisy = passRate(span: 0.32, noise: 0.030)
        print(String(format: "\n  at the refused windows' median span (0.32 s): clean %.0f %%, noisy %.0f %%\n", clean*100, noisy*100))
        XCTAssertGreaterThan(clean, 0.95,
                             "a cleanly tracked 0.32 s arc does determine g — so span on its own does not explain the refusals")
        XCTAssertLessThan(noisy, 0.70,
                          "and at detector-struggling noise the same span is close to a coin toss, which is what does")
        XCTAssertGreaterThan(clean - noisy, 0.25,
                             "the gap between the two is the size of the effect noise has at this span")
    }

    /// And the converse, so the claim is two-sided: at the accepted windows' span the gate is not
    /// the thing standing in the way, even with poor tracking.
    func testAtTheAcceptedWindowsSpanTheGateIsForgiving() {
        let noisy = passRate(span: 1.00, noise: 0.030)
        print(String(format: "\n  at the accepted windows' median span (1.08 s), noise 0.030 m: %.0f %%\n", noisy*100))
        XCTAssertGreaterThan(noisy, 0.5)
    }

    /// `minimumSpan` is a stated convention and currently sits below where `g` is recoverable.
    func testTheCurrentMinimumSpanIsBelowWhereGravityIsRecoverable() {
        XCTAssertEqual(TrajectoryFitOptions().minimumSpan, 0.15,
                       "pinned: if this moves, the note below and BIG-CHANGES B14 need revisiting")
        XCTAssertLessThan(passRate(span: 0.15, noise: 0.015), 0.95,
                          "0.15 s admits arcs whose g is not determined; that is the point of B14")
    }
}
