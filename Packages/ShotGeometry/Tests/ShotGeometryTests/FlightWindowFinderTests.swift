import XCTest
@testable import ShotGeometry

/// `FlightWindowFinder` decides which samples reach the final fit, and therefore what `g` comes out
/// as. Measured on the 2026-09-13 corpus (2026-09-27, `docs/EXPERIMENTS.md`): of the 31 labelled-real
/// shots still refused, **19 are refused by the gravity gate**, and their `g_fit / 9.81` is scattered
/// from −2.04 to +16.04 rather than clustered on the 2×/4× signatures of a timing or units bug. A fit
/// whose g lands there is not being handed one free flight — which makes this file, and the window it
/// tests, the project's top open lead (`BIG-CHANGES.md` B14).
///
/// Until now it had no tests at all. These work in plane coordinates (metres), synthesised directly
/// from physics with no camera in the loop, so a failure here is the segmentation and nothing else.
final class FlightWindowFinderTests: XCTestCase {

    // MARK: - synthetic tracks, release at t = 0 exactly

    /// Hold at the set point, a constant-acceleration push over `push` seconds, then free flight.
    /// Matches `ShotSimulator`'s model but in the shot plane, so the release instant is exact.
    private func track(fps: Double = 120, pre: Double = 0.35, push: Double = 0.18,
                       flight: Double = 0.95, theta: Double = Angle.radians(48), speed: Double = 7.1,
                       x0: Double = -4.19, y0: Double = -0.7, noise: Double = 0, seed: UInt64 = 7)
        -> [TrajectorySample]
    {
        var rng = SeededRNG(seed: seed)
        let vx = speed * cos(theta), vy = speed * sin(theta)
        var out: [TrajectorySample] = []
        var t = -pre
        while t <= flight + 1e-9 {
            var x: Double, y: Double
            if t < -push {
                x = x0; y = y0                                   // held still
            } else if t < 0 {
                // constant acceleration from rest to (vx, vy) over `push`, ending at (x0, y0)
                let s = t + push                                 // 0 … push
                let ax = vx / push, ay = vy / push
                x = x0 - (vx * push / 2) + 0.5 * ax * s * s
                y = y0 - (vy * push / 2) + 0.5 * ay * s * s
            } else {
                x = x0 + vx * t
                y = y0 + vy * t - 0.5 * Court.g * t * t
            }
            if noise > 0 { x += rng.gaussian(sd: noise); y += rng.gaussian(sd: noise) }
            out.append(TrajectorySample(t: t, x: x, y: y))
            t += 1 / fps
        }
        return out
    }

    // MARK: - the release instant

    func testRecoversTheReleaseInstantOnACleanTrack() throws {
        let w = try FlightWindowFinder.find(track())
        XCTAssertTrue(w.releaseObserved, "the push is in the track, so the release was seen")
        XCTAssertEqual(w.releaseTime, 0, accuracy: 1.0 / 120.0,
                       "release recovered to better than one frame at 120 fps")
    }

    func testTheReleaseInstantSurvivesRealisticNoise() throws {
        // 1.5 px at 7 m on a 1536 px focal length is ~7 mm in the plane.
        for seed in UInt64(1)...5 {
            let w = try FlightWindowFinder.find(track(noise: 0.007, seed: seed))
            XCTAssertEqual(w.releaseTime, 0, accuracy: 2.0 / 120.0, "seed \(seed)")
            XCTAssertTrue(w.releaseObserved, "seed \(seed)")
        }
    }

    func testAtThirtyFramesPerSecondTheReleaseIsStillFoundWithinAFrame() throws {
        let w = try FlightWindowFinder.find(track(fps: 30))
        XCTAssertEqual(w.releaseTime, 0, accuracy: 1.0 / 30.0)
    }

    // MARK: - what must never be fabricated

    func testATrackThatStartsInFlightIsNotGivenAReleaseItNeverSaw() throws {
        // No hold, no push: the camera started late. CLAUDE.md rule 1.
        let flightOnly = track(pre: 0, push: 0.0001).filter { $0.t >= 0.12 }
        let w = try FlightWindowFinder.find(flightOnly)
        XCTAssertFalse(w.releaseObserved,
                       "a track with no push in it must report the release as unobserved, not guess one")
    }

    func testTooFewSamplesIsAnErrorRatherThanAWindow() {
        let short = Array(track().prefix(9))
        XCTAssertThrowsError(try FlightWindowFinder.find(short)) { e in
            guard case FlightWindowError.tooFewSamples(let n) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertEqual(n, 9)
        }
    }

    // MARK: - the end of the flight

    func testContactFramesAfterTheRimAreLeftOutOfTheWindow() throws {
        // The ball reaches the rim and rebounds: vertical velocity reverses. Those frames are not
        // free flight and must not reach the fit, or `g` comes out of a V rather than a parabola.
        var t = track(flight: 0.80)
        let last = t.last!
        let vx = 7.1 * cos(Angle.radians(48))
        var s = last.t + 1 / 120.0
        while s <= last.t + 0.15 {
            let dt = s - last.t
            t.append(TrajectorySample(t: s, x: last.x + vx * dt, y: last.y + 2.0 * dt - 0.5 * Court.g * dt * dt))
            s += 1 / 120.0
        }
        let w = try FlightWindowFinder.find(t)
        XCTAssertLessThanOrEqual(t[w.endIndex].t, last.t + 1e-9,
                                 "the window ran past the rim into the rebound")
    }

    // MARK: - the failure mode B14 is about

    /// A window that also contains the ball being *caught and held* before the shot. This is the
    /// shape of contamination the corpus's scattered `g_fit` implies, and it is the single most
    /// valuable behaviour to pin: whatever the finder does here, it must not quietly hand the fit a
    /// segment that is two different motions.
    func testHeldBallFramesBeforeTheShotDoNotEnterTheWindow() throws {
        var pre: [TrajectorySample] = []
        var t = -1.20
        while t < -0.40 { pre.append(TrajectorySample(t: t, x: -4.30, y: -0.95)); t += 1 / 120.0 }
        let full = pre + track(pre: 0.35)
        let w = try FlightWindowFinder.find(full)
        XCTAssertGreaterThanOrEqual(full[w.releaseIndex].t, -0.05,
                                    "the window reached back into the held ball")
        XCTAssertEqual(w.releaseTime, 0, accuracy: 3.0 / 120.0)
    }

    /// The fit the window produces must itself be gravity-consistent. This is the property the whole
    /// acceptance rule rests on, asserted here directly rather than inferred from a corpus.
    func testTheWindowedFitRecoversGravity() throws {
        let samples = track(noise: 0.005, seed: 11)
        let w = try FlightWindowFinder.find(samples)
        let flight = Array(samples[(w.releaseIndex + 1)...(w.endIndex - 1)])
        var o = TrajectoryFitOptions()
        let fit = try TrajectoryFitter.fit(flight, anchorTime: w.releaseTime, options: o)
        XCTAssertEqual(fit.g, Court.g, accuracy: 0.08 * Court.g,
                       "a clean window must pass the 8 % gravity gate; it came out at \(fit.g)")
        o.fixedG = nil
        XCTAssertEqual(fit.releaseAngle, Angle.radians(48), accuracy: Angle.radians(1.5))
        XCTAssertEqual(fit.releaseSpeed, 7.1, accuracy: 0.15)
    }

    /// The options are conventions, so they are pinned: a silent change to any of them moves every
    /// window in the corpus and therefore every number downstream of it.
    func testTheWindowConventionsAreWhatTheDocumentationSays() {
        let o = FlightWindowOptions()
        XCTAssertEqual(o.localWindow, 0.30)
        XCTAssertEqual(o.minimumLocalSamples, 6)
        XCTAssertEqual(o.localFactor, 2.0)
        XCTAssertEqual(o.minimumSpeed, 2.0)
        XCTAssertEqual(o.apexRegion, 0.2)
        XCTAssertNil(o.releaseTimeOverride, "an override that defaults to a value would fabricate a release")
    }
}
