import XCTest
@testable import ShotGeometry

/// 1.4 — the vertical jump test's arithmetic, tested where it can be tested exactly: on a synthetic
/// foot signal built from a *known* flight time. If the code cannot recover a flight time it wrote
/// itself, nothing it says about a real jump is worth reading.
///
/// The synthetic clip is the one the protocol asks for: stand still, dip, jump, land, stand still.
/// The feet sit on a flat baseline, rise as a parabola for the flight, and come back.
final class JumpTestTests: XCTestCase {

    let g = VerticalJump.standardGravity

    // MARK: - A jump built to order

    /// A foot-height series, up-positive pixels, for a jump of exactly `flight` seconds.
    ///
    /// The feet follow the body: during the flight the ankle traces the same parabola the centre of
    /// mass does (this is a test of the *timing* code, so no tuck is modelled). `pxPerMetre` only
    /// scales the signal — the flight-time method never sees it.
    func clip(flight: Double, fps: Double, standSeconds: Double = 0.6, pxPerMetre: Double = 400,
              takeOffAt: Double = 0.6, noisePx: Double = 0, seed: UInt64 = 1) -> (t: [Double], y: [Double]) {
        var rng = SplitMix(seed)
        var t: [Double] = [], y: [Double] = []
        let total = takeOffAt + flight + standSeconds
        let n = Int((total * fps).rounded())
        let baseline = -500.0                        // any offset; only differences matter
        for i in 0...n {
            let time = Double(i) / fps
            var h = 0.0
            if time > takeOffAt, time < takeOffAt + flight {
                let s = time - takeOffAt
                h = (g * flight / 2) * s - 0.5 * g * s * s   // metres above the floor
            }
            t.append(time)
            y.append(baseline + h * pxPerMetre + (noisePx > 0 ? noisePx * rng.normal() : 0))
        }
        return (t, y)
    }

    struct SplitMix {
        var state: UInt64
        init(_ s: UInt64) { state = s }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
        /// Box–Muller, so the "sigma" in the code under test is a real sigma.
        mutating func normal() -> Double {
            let u1 = max(1e-12, uniform()), u2 = uniform()
            return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
        }
    }

    // MARK: - Heights from known flight times

    func testKnownFlightTimesRecoverTheirHeights() {
        // 0.40 s → 19.6 cm, 0.50 s → 30.7 cm, 0.60 s → 44.1 cm, 0.72 s → 63.6 cm.
        for flight in [0.40, 0.50, 0.60, 0.72] {
            let c = clip(flight: flight, fps: 240)
            let m = VerticalJump.flightTime(times: c.t, footUpPixels: c.y)
            guard let jump = m.jump else {
                XCTFail("flight \(flight): refused — \(m.unavailableReason ?? "?")"); continue
            }
            let truth = g * flight * flight / 8
            // The threshold sits a couple of pixels above the floor, so the measured flight is
            // *shorter* than the truth and the height reads low — by no more than the one-sided
            // `thresholdBiasMetres` the code publishes for exactly this, and never high.
            let error = truth - jump.heightMetres
            XCTAssertGreaterThan(error, -jump.heightUncertaintyMetres,
                                 String(format: "flight %.2f: the threshold must never make the height read HIGH (measured %.4f, truth %.4f)", flight, jump.heightMetres, truth))
            XCTAssertLessThanOrEqual(error, jump.thresholdBiasMetres + jump.heightUncertaintyMetres,
                                     String(format: "flight %.2f: measured %.4f m vs truth %.4f m; published bias %.4f m, ±%.4f m",
                                            flight, jump.heightMetres, truth, jump.thresholdBiasMetres, jump.heightUncertaintyMetres))
            XCTAssertLessThan(abs(jump.flightSeconds - flight), 0.02, "flight \(flight)")
            XCTAssertEqual(jump.frameRate, 240, accuracy: 1)
        }
    }

    /// `h = g·t²/8` exactly, with no series involved: the arithmetic itself.
    func testHeightFormula() {
        let flight = 0.5
        XCTAssertEqual(g * flight * flight / 8, 0.3065625, accuracy: 1e-9)
    }

    // MARK: - The uncertainty maths

    func testUncertaintyIsOneFramePerEdgeAndScalesWithFlightTime() {
        let c = clip(flight: 0.50, fps: 240)
        guard let jump = VerticalJump.flightTime(times: c.t, footUpPixels: c.y).jump else {
            return XCTFail("refused")
        }
        // Two independent ±1-frame edges at 240 fps: √2 × 4.167 ms = 5.89 ms.
        XCTAssertEqual(jump.flightSecondsUncertainty, 2.0.squareRoot() / 240, accuracy: 1e-6)
        // dh/dt = g·t/4 → 9.81 × 0.5 / 4 × 0.00589 = 7.2 mm.
        XCTAssertEqual(jump.heightUncertaintyMetres, g * jump.flightSeconds / 4 * jump.flightSecondsUncertainty, accuracy: 1e-9)
        // 9.81 × 0.50 / 4 × 5.89 ms = 7.2 mm, so a 30 cm jump is 30.7 ± 0.7 cm from the clock alone.
        XCTAssertEqual(jump.heightUncertaintyMetres, 0.0072, accuracy: 0.0008)
        // And the threshold's one-sided share is small but not zero, and always reported.
        XCTAssertGreaterThan(jump.thresholdBiasMetres, 0)
        XCTAssertLessThan(jump.thresholdBiasMetres, 0.03)
    }

    func testHalvingTheFrameRateDoublesTheUncertainty() {
        let fast = VerticalJump.flightTime(times: clip(flight: 0.5, fps: 240).t,
                                           footUpPixels: clip(flight: 0.5, fps: 240).y).jump
        let slow = VerticalJump.flightTime(times: clip(flight: 0.5, fps: 120).t,
                                           footUpPixels: clip(flight: 0.5, fps: 120).y).jump
        XCTAssertNotNil(fast); XCTAssertNotNil(slow)
        guard let fast, let slow else { return }
        XCTAssertEqual(slow.heightUncertaintyMetres / fast.heightUncertaintyMetres, 2, accuracy: 0.05)
    }

    /// Noise on the signal must not move the answer outside what the code publishes as its error.
    func testSurvivesTrackerJitter() {
        for seed in UInt64(1)...6 {
            let c = clip(flight: 0.55, fps: 240, noisePx: 1.5, seed: seed)
            guard let jump = VerticalJump.flightTime(times: c.t, footUpPixels: c.y).jump else {
                XCTFail("seed \(seed): refused"); continue
            }
            let truth = g * 0.55 * 0.55 / 8
            XCTAssertLessThan(abs(jump.heightMetres - truth), 3 * jump.totalUncertaintyMetres,
                              "seed \(seed): \(jump.heightMetres) vs \(truth) bound \(jump.totalUncertaintyMetres)")
        }
    }

    // MARK: - The rejections, one at a time

    func testRejectsSlowFrameRate() {
        let c = clip(flight: 0.5, fps: 60)
        let m = VerticalJump.flightTime(times: c.t, footUpPixels: c.y)
        XCTAssertNil(m.jump)
        XCTAssertTrue(m.unavailableReason?.contains("at least 120") == true, m.unavailableReason ?? "?")
    }

    func testRejectsFlightUnder150ms() {
        // Filmed close enough that the 1.2 cm hop is 49 px — so the refusal has to be about the
        // *duration*, not about the hop being too small to see.
        let c = clip(flight: 0.10, fps: 240, pxPerMetre: 4000)
        let m = VerticalJump.flightTime(times: c.t, footUpPixels: c.y)
        XCTAssertNil(m.jump)
        XCTAssertTrue(m.unavailableReason?.contains("shuffle") == true, m.unavailableReason ?? "?")
    }

    /// The other short-jump refusal: a real hop, filmed so far away that it is a handful of pixels.
    func testRejectsAJumpTooSmallInPixelsToRead() {
        let c = clip(flight: 0.10, fps: 240, pxPerMetre: 400)
        let m = VerticalJump.flightTime(times: c.t, footUpPixels: c.y)
        XCTAssertNil(m.jump)
        XCTAssertTrue(m.unavailableReason?.contains("separated from standing still") == true, m.unavailableReason ?? "?")
    }

    func testRejectsFlightOver1point2s() {
        // 1.4 s of flight is 2.4 m of rise: not a jump, so it must be refused rather than reported.
        let c = clip(flight: 1.40, fps: 240, standSeconds: 0.5)
        let m = VerticalJump.flightTime(times: c.t, footUpPixels: c.y)
        XCTAssertNil(m.jump)
        XCTAssertTrue(m.unavailableReason?.contains("1.20 s") == true, m.unavailableReason ?? "?")
    }

    func testRejectsStandingStill() {
        var t: [Double] = [], y: [Double] = []
        var rng = SplitMix(9)
        for i in 0...480 { t.append(Double(i) / 240); y.append(-500 + 1.2 * rng.normal()) }
        let m = VerticalJump.flightTime(times: t, footUpPixels: y)
        XCTAssertNil(m.jump)
        XCTAssertNotNil(m.unavailableReason)
    }

    func testRejectsTwoJumpsInOneClip() {
        let a = clip(flight: 0.45, fps: 240, standSeconds: 0.3, takeOffAt: 0.4)
        let b = clip(flight: 0.45, fps: 240, standSeconds: 0.3, takeOffAt: 0.4)
        let offset = a.t.last! + 1 / 240.0
        let t = a.t + b.t.map { $0 + offset }
        let y = a.y + b.y
        let m = VerticalJump.flightTime(times: t, footUpPixels: y)
        XCTAssertNil(m.jump)
        XCTAssertTrue(m.unavailableReason?.contains("2 separate times") == true, m.unavailableReason ?? "?")
    }

    func testRejectsClipThatStartsInTheAir() {
        let c = clip(flight: 0.5, fps: 240, takeOffAt: 0.6)
        // Cut the standing-still start away: the clip now opens mid-flight.
        let cut = Int(0.75 * 240)
        let m = VerticalJump.flightTime(times: Array(c.t[cut...]), footUpPixels: Array(c.y[cut...]))
        XCTAssertNil(m.jump)
        XCTAssertTrue(m.unavailableReason?.contains("already off the floor") == true, m.unavailableReason ?? "?")
    }

    func testRejectsClipThatEndsBeforeLanding() {
        let c = clip(flight: 0.5, fps: 240, takeOffAt: 0.6)
        let cut = Int(0.95 * 240)
        let m = VerticalJump.flightTime(times: Array(c.t[..<cut]), footUpPixels: Array(c.y[..<cut]))
        XCTAssertNil(m.jump)
        XCTAssertTrue(m.unavailableReason?.contains("before the feet come back down") == true, m.unavailableReason ?? "?")
    }

    func testRejectsAGapAroundTakeOff() {
        var c = clip(flight: 0.5, fps: 240)
        // Drop 12 frames (50 ms) straddling take-off: the body was lost exactly where it mattered.
        let firstAir = c.y.indices.first { c.y[$0] > c.y[0] + 5 } ?? 0
        let lo = max(0, firstAir - 6), hi = min(c.y.count - 1, firstAir + 6)
        c.t.removeSubrange(lo...hi); c.y.removeSubrange(lo...hi)
        let m = VerticalJump.flightTime(times: c.t, footUpPixels: c.y)
        XCTAssertNil(m.jump)
        XCTAssertTrue(m.unavailableReason?.contains("lost") == true, m.unavailableReason ?? "?")
    }

    func testRejectsMismatchedSeries() {
        let m = VerticalJump.flightTime(times: [0, 1, 2], footUpPixels: [0, 1])
        XCTAssertNil(m.jump)
        XCTAssertTrue(m.unavailableReason?.contains("different lengths") == true, m.unavailableReason ?? "?")
    }

    // MARK: - Method B and the comparison

    func testHipRiseNeedsAScaleAndSaysSoWhenItHasNone() {
        let m = VerticalJump.hipRise(times: [0, 1], hipUpPixels: [0, 1], takeOffSeconds: 0.5, scale: nil)
        XCTAssertNil(m.jump)
        XCTAssertTrue(m.unavailableReason?.contains("metre scale") == true, m.unavailableReason ?? "?")
    }

    func testHipRiseRecoversAKnownRise() {
        // 1.80 m shooter, ankle-to-nose 0.891 × 1.80 = 1.604 m spanning 640 px → 2.506 mm/px.
        guard let scale = VerticalJump.JumpScale.fromStatedHeight(metres: 1.80, ankleToNosePixels: 640) else {
            return XCTFail("the stated-height scale was refused")
        }
        XCTAssertEqual(scale.metresPerPixel, 1.80 * 0.891 / 640, accuracy: 1e-9)
        // Hips stand flat, then rise 100 px (0.2506 m) and come back.
        var t: [Double] = [], h: [Double] = []
        for i in 0...480 {
            let time = Double(i) / 240
            let rise = (time > 0.6 && time < 1.1) ? 100 * Foundation.sin(.pi * (time - 0.6) / 0.5) : 0
            t.append(time); h.append(-300 + rise)
        }
        let m = VerticalJump.hipRise(times: t, hipUpPixels: h, takeOffSeconds: 0.62, scale: scale)
        guard let jump = m.jump else { return XCTFail(m.unavailableReason ?? "?") }
        XCTAssertEqual(jump.riseMetres, 100 * scale.metresPerPixel, accuracy: 1e-6)
        XCTAssertGreaterThan(jump.riseUncertaintyMetres, 0)
        XCTAssertGreaterThanOrEqual(jump.standingSamples, 5)
    }

    func testHipRiseRefusesWithoutStandingStillBeforeTakeOff() {
        let t = (0...60).map { Double($0) / 240 }
        let m = VerticalJump.hipRise(times: t, hipUpPixels: t.map { _ in -300 }, takeOffSeconds: 0.01,
                                     scale: VerticalJump.JumpScale(metresPerPixel: 0.0025, source: "a test", relativeUncertainty: 0.01))
        XCTAssertNil(m.jump)
        XCTAssertTrue(m.unavailableReason?.contains("standing still") == true, m.unavailableReason ?? "?")
    }

    func testComparisonNamesFlightTimeWhenTheyDisagree() {
        let c = clip(flight: 0.55, fps: 240)
        guard let flight = VerticalJump.flightTime(times: c.t, footUpPixels: c.y).jump else { return XCTFail("refused") }
        let hip = VerticalJump.HipRiseJump(riseMetres: flight.heightMetres - 0.15, riseUncertaintyMetres: 0.01,
                                           standingSamples: 40, risePixels: 100,
                                           scale: .init(metresPerPixel: 0.0025, source: "a test", relativeUncertainty: 0.01),
                                           notes: [])
        let c1 = VerticalJump.compare(flight: flight, hip: hip)
        XCTAssertFalse(c1.agree)
        XCTAssertTrue(c1.sentence.contains("Trust the flight-time number"), c1.sentence)

        let close = VerticalJump.HipRiseJump(riseMetres: flight.heightMetres - 0.002, riseUncertaintyMetres: 0.01,
                                             standingSamples: 40, risePixels: 100,
                                             scale: .init(metresPerPixel: 0.0025, source: "a test", relativeUncertainty: 0.01),
                                             notes: [])
        XCTAssertTrue(VerticalJump.compare(flight: flight, hip: close).agree)
    }

    // MARK: - Three jumps make a test

    func testSummaryCarriesNAndSpread() {
        let s = VerticalJump.summarise(heightsMetres: [0.52, 0.48, 0.55], uncertaintiesMetres: [0.01, 0.01, 0.01])
        guard let s else { return XCTFail("nil summary") }
        XCTAssertEqual(s.n, 3)
        XCTAssertEqual(s.bestMetres, 0.55, accuracy: 1e-9)
        XCTAssertEqual(s.meanMetres, (0.52 + 0.48 + 0.55) / 3, accuracy: 1e-9)
        XCTAssertEqual(s.spreadMetres, 0.07, accuracy: 1e-9)
        XCTAssertNotNil(s.sdMetres)
        XCTAssertNil(s.sdUnavailableReason)
    }

    func testOneJumpHasNoSpreadAndSaysWhy() {
        guard let s = VerticalJump.summarise(heightsMetres: [0.5], uncertaintiesMetres: [0.01]) else {
            return XCTFail("nil summary")
        }
        XCTAssertNil(s.sdMetres)
        XCTAssertNotNil(s.sdUnavailableReason)
    }

    func testTrendSentenceAlwaysCarriesN() {
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(7 * 86400)
        let text = VerticalJump.trendSentence([.init(date: day1, bestMetres: 0.50, n: 3),
                                               .init(date: day2, bestMetres: 0.545, n: 3)])
        XCTAssertTrue(text.contains("n 3"), text)
        XCTAssertTrue(text.contains("up 4.5 cm"), text)
        XCTAssertEqual(VerticalJump.trendSentence([]), "No jump tests saved yet.")
    }

    // MARK: - Reading the signals off a timeline

    func testSeriesTakesTheLowerAnkleAndDropsLowConfidenceFrames() {
        func frame(_ i: Int, leftV: Double, rightV: Double, confidence: Double) -> BodyFrame {
            BodyFrame(frameIndex: i, fileTime: Double(i) / 240, realTime: Double(i) / 240,
                      points2D: [Body2DPoint.leftAnkle: .init(name: Body2DPoint.leftAnkle, u: 100, v: leftV, confidence: confidence),
                                 Body2DPoint.rightAnkle: .init(name: Body2DPoint.rightAnkle, u: 120, v: rightV, confidence: confidence),
                                 Body2DPoint.leftHip: .init(name: Body2DPoint.leftHip, u: 100, v: leftV - 400, confidence: confidence),
                                 Body2DPoint.rightHip: .init(name: Body2DPoint.rightHip, u: 120, v: rightV - 400, confidence: confidence),
                                 Body2DPoint.nose: .init(name: Body2DPoint.nose, u: 110, v: leftV - 640, confidence: confidence)])
        }
        let timeline = BodyTimeline(frames: [frame(0, leftV: 900, rightV: 880, confidence: 0.9),
                                             frame(1, leftV: 899, rightV: 700, confidence: 0.9),
                                             frame(2, leftV: 898, rightV: 880, confidence: 0.05)],
                                    timeScale: 1, imageWidth: 1280, imageHeight: 720, everyNthFrame: 1,
                                    decodedFrames: 3, analysedFrames: 3, wallSeconds: 1, notes: [])
        let s = VerticalJump.series(from: timeline)
        XCTAssertEqual(s.times.count, 2, "the low-confidence frame must be dropped, not interpolated")
        // Up-positive is −v, and the *lower* foot is the larger v, so the smaller −v.
        XCTAssertEqual(s.footUpPixels[0], -900, accuracy: 1e-9)
        XCTAssertEqual(s.footUpPixels[1], -899, accuracy: 1e-9, "one foot lifted; the grounded one still sets the signal")
        XCTAssertEqual(s.hipUpPixels[0], -(500 + 480) / 2, accuracy: 1e-9)
        XCTAssertEqual(s.ankleToNosePixels ?? 0, 640, accuracy: 60)
        XCTAssertEqual(s.framesTotal, 3)
    }
}
