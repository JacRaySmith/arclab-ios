import XCTest
import simd
@testable import ShotGeometry

/// Synthetic shooters, built in image space, so the footwork reader is tested against footwork it
/// was *told* to see. The generator never touches `FootworkMetrics`: it writes 2-D points the way
/// Vision would and lets the reader find the steps on its own.
final class FootworkMetricsTests: XCTestCase {

    // MARK: A shooter made of pixels

    /// One flight of one foot (or of the whole body), as a parabola in stature units.
    struct Flight {
        var foot: FootSide?          // nil = the whole body leaves the floor
        var start: Double
        var end: Double
        var peakStature: Double = 0.08
        func height(_ t: Double) -> Double {
            guard t > start, t < end, end > start else { return 0 }
            let x = (t - start) / (end - start)
            return peakStature * 4 * x * (1 - x)
        }
        /// A take-off with no landing inside the window: rises and stays up.
        var openEnded = false
        func value(_ t: Double) -> Double {
            guard openEnded else { return height(t) }
            guard t > start else { return 0 }
            let x = min(1, (t - start) / max(1e-9, end - start))
            return peakStature * (1 - (1 - x) * (1 - x))
        }
    }

    struct Shooter {
        var centreU = 640.0
        var statureImagePixels = 600.0
        var noseV = 280.0
        var hipV = 700.0
        var floorV = 880.0
        var imageWidth = 1280
        var imageHeight = 960
        /// Hip-line image span ÷ stature. 0.2144 is a square-on frontal view (Winter's biiliac
        /// breadth over the ankle-to-nose span); anything near 0 is a side view.
        var hipSpanStature = 0.020
        /// Ankle separation along the image horizontal ÷ stature.
        var ankleSeparationStature = 0.030
        var frameRate = 100.0
        var duration = 1.40
        var flights: [Flight] = []

        static let frontalHipSpan = 0.191 / 0.891

        func timeline() -> BodyTimeline {
            var frames: [BodyFrame] = []
            var i = 0
            var t = 0.0
            while t <= duration + 1e-9 {
                let body = flights.filter { $0.foot == nil }.map { $0.value(t) }.reduce(0, +)
                func ankleRise(_ f: FootSide) -> Double {
                    body + flights.filter { $0.foot == f }.map { $0.value(t) }.reduce(0, +)
                }
                let half = ankleSeparationStature * statureImagePixels / 2
                let hipHalf = hipSpanStature * statureImagePixels / 2
                var p: [String: BodyPoint2D] = [:]
                func put(_ n: String, _ u: Double, _ v: Double) {
                    p[n] = BodyPoint2D(name: n, u: u, v: v, confidence: 0.9)
                }
                put(Body2DPoint.nose, centreU, noseV - body * statureImagePixels)
                put(Body2DPoint.neck, centreU, noseV + 60 - body * statureImagePixels)
                put(Body2DPoint.leftHip, centreU - hipHalf, hipV - body * statureImagePixels)
                put(Body2DPoint.rightHip, centreU + hipHalf, hipV - body * statureImagePixels)
                put(Body2DPoint.leftShoulder, centreU - hipHalf, hipV - 200 - body * statureImagePixels)
                put(Body2DPoint.rightShoulder, centreU + hipHalf, hipV - 200 - body * statureImagePixels)
                put(Body2DPoint.leftAnkle, centreU - half, floorV - ankleRise(.left) * statureImagePixels)
                put(Body2DPoint.rightAnkle, centreU + half, floorV - ankleRise(.right) * statureImagePixels)
                frames.append(BodyFrame(frameIndex: i, fileTime: t, realTime: t, joints3D: [:], points2D: p))
                i += 1
                t = Double(i) / frameRate
            }
            return BodyTimeline(frames: frames, timeScale: 1, imageWidth: imageWidth, imageHeight: imageHeight,
                                everyNthFrame: 1, decodedFrames: frames.count, analysedFrames: frames.count,
                                wallSeconds: 0, notes: [])
        }
    }

    /// Right-handed shooter, rim camera-right, side-on camera.
    func options(_ s: Shooter) -> FootworkOptions {
        var o = FootworkOptions(shootingSide: "right")
        o.rimBearingSign = 1
        return o
    }

    // MARK: - Patterns

    func testStationaryShotHasNoStepAndNoGather() {
        var s = Shooter()
        // Nothing but the shot's own take-off at 1.00 s.
        s.flights = [Flight(foot: nil, start: 1.00, end: 1.20, peakStature: 0.10, openEnded: true)]
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.15,
                                        setRealTime: 0.80, options: options(s))
        XCTAssertNil(m.unavailableReason)
        XCTAssertEqual(m.pattern, .stationary, m.patternReason)
        XCTAssertEqual(m.stepCount.value, 0)
        XCTAssertNil(m.gatherSeconds.value)
        XCTAssertNotNil(m.gatherSeconds.unavailableReason)
        XCTAssertTrue(m.gatherSeconds.unavailableReason!.contains("no foot touched down"),
                      m.gatherSeconds.unavailableReason!)
        // The take-off is still found, and the release is after it.
        XCTAssertNotNil(m.liftRealTime, m.liftUnavailableReason ?? "")
        XCTAssertEqual(m.liftToReleaseSeconds.value ?? -1, 0.15, accuracy: 0.04)
        XCTAssertGreaterThan(m.jumpRise.value ?? -1, 0.0)
    }

    func testHopIsReadAsAHop() {
        var s = Shooter()
        s.flights = [
            Flight(foot: .left, start: 0.25, end: 0.45),
            Flight(foot: .right, start: 0.25, end: 0.47),          // lands 20 ms after the left
            Flight(foot: nil, start: 0.95, end: 1.20, peakStature: 0.10, openEnded: true),
        ]
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.12,
                                        setRealTime: 0.80, options: options(s))
        XCTAssertEqual(m.pattern, .hop, m.patternReason)
        XCTAssertEqual(m.stepCount.value, 2)
        XCTAssertNotNil(m.stepSeparationSeconds.value)
        XCTAssertLessThanOrEqual(m.stepSeparationSeconds.value!, 0.06)
        XCTAssertNotNil(m.gatherSeconds.value)
        XCTAssertEqual(m.gatherSeconds.value!, 1.12 - 0.45, accuracy: 0.05)
    }

    func testOneTwoIsReadAsAOneTwoWithTheRightFootFirst() {
        var s = Shooter()
        s.flights = [
            Flight(foot: .right, start: 0.20, end: 0.42),           // right lands first
            Flight(foot: .left, start: 0.20, end: 0.62),            // left 200 ms later
            Flight(foot: nil, start: 0.95, end: 1.20, peakStature: 0.10, openEnded: true),
        ]
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.12,
                                        setRealTime: 0.80, options: options(s))
        XCTAssertEqual(m.pattern, .oneTwo, m.patternReason)
        XCTAssertEqual(m.firstFootDown, .right)
        XCTAssertEqual(m.firstFootDownIsShootingSide, true)          // shooting side is "right"
        XCTAssertEqual(m.stepSeparationSeconds.value ?? 0, 0.20, accuracy: 0.05)
        XCTAssertEqual(m.stepCount.value, 2)
    }

    func testALandingWhoseTakeOffPredatesTheWindowIsNotCountedAsAStep() {
        var s = Shooter()
        // The window opens with the left foot already in the air; it lands at 0.15 s. We never saw
        // it leave, so it is not evidence of a step into this shot.
        s.flights = [
            Flight(foot: .left, start: -0.20, end: 0.15),
            Flight(foot: nil, start: 0.95, end: 1.20, peakStature: 0.10, openEnded: true),
        ]
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.12,
                                        setRealTime: 0.80, options: options(s))
        XCTAssertEqual(m.stepCount.value, 0, m.patternReason)
        XCTAssertEqual(m.pattern, .stationary, m.patternReason)
        XCTAssertTrue(m.notes.contains { $0.contains("not counted as a step") }, "\(m.notes)")
    }

    func testLeftHandedShooterIsJudgedAgainstTheLeftFoot() {
        var s = Shooter()
        s.flights = [
            Flight(foot: .right, start: 0.20, end: 0.42),
            Flight(foot: .left, start: 0.20, end: 0.62),
            Flight(foot: nil, start: 0.95, end: 1.20, peakStature: 0.10, openEnded: true),
        ]
        var o = options(s); o.shootingSide = "left"
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.12,
                                        setRealTime: 0.80, options: o)
        XCTAssertEqual(m.firstFootDown, .right)
        XCTAssertEqual(m.firstFootDownIsShootingSide, false)
    }

    // MARK: - What a view can and cannot carry

    func testSideViewRefusesStanceWidthAndFootAngleButGivesStagger() {
        var s = Shooter()
        s.hipSpanStature = 0.020                                     // hips edge-on: a side view
        s.flights = [Flight(foot: nil, start: 1.00, end: 1.20, peakStature: 0.10, openEnded: true)]
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.15,
                                        setRealTime: 0.80, options: options(s))

        XCTAssertNotNil(m.viewAzimuth.degrees)
        XCTAssertGreaterThan(m.viewAzimuth.degrees!, 75)             // near-side

        XCTAssertNil(m.stanceWidth.value)
        XCTAssertTrue(m.stanceWidth.unavailableReason!.contains("near-side"), m.stanceWidth.unavailableReason!)
        XCTAssertTrue(m.stanceWidth.unavailableReason!.contains("from in front"), m.stanceWidth.unavailableReason!)

        // The stagger is the axis this camera *does* see, and the shooting-side foot is camera-right,
        // which is where the rim is, so the sign is positive.
        XCTAssertNotNil(m.stanceStagger.value, m.stanceStagger.unavailableReason ?? "")
        XCTAssertEqual(m.stanceStagger.value!, 0.030, accuracy: 0.006)
        XCTAssertTrue(m.stanceStagger.provenance.contains("nearer the rim"), m.stanceStagger.provenance)

        // Lateral drift is refused for the same reason; drift toward the rim is not.
        XCTAssertNil(m.hipDriftLateral.value)
        XCTAssertNotNil(m.hipDriftTowardRim.value, m.hipDriftTowardRim.unavailableReason ?? "")

        // The foot's angle is refused on a timeline with no foot landmarks in it — which is every
        // timeline from a pass that did not run the foot detector (1.3 Track C changed this from
        // "never available" to "not available without the detector", and the reason says so).
        XCTAssertNil(m.footAngleToRim.value)
        XCTAssertNil(m.otherFootAngleToRim.value)
        XCTAssertNil(m.stanceOpenness.value)
        XCTAssertTrue(m.footStrikes.isEmpty)
        let why = m.footAngleToRim.unavailableReason!
        XCTAssertTrue(why.contains("no toe"), why)
        XCTAssertTrue(why.contains("detectFeet"), why)
        XCTAssertEqual(why, FootworkMetrics.footAngleWithoutDetectorReason)
    }

    func testFrontalViewGivesStanceWidthAndRefusesStagger() {
        var s = Shooter()
        s.hipSpanStature = Shooter.frontalHipSpan                    // square on
        s.flights = [Flight(foot: nil, start: 1.00, end: 1.20, peakStature: 0.10, openEnded: true)]
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.15,
                                        setRealTime: 0.80, options: options(s))
        XCTAssertLessThan(m.viewAzimuth.degrees ?? 90, 20)
        XCTAssertNotNil(m.stanceWidth.value, m.stanceWidth.unavailableReason ?? "")
        XCTAssertEqual(m.stanceWidth.value!, 0.030, accuracy: 0.004)
        XCTAssertNil(m.stanceStagger.value)
        XCTAssertTrue(m.stanceStagger.unavailableReason!.contains("from the side"), m.stanceStagger.unavailableReason!)
        XCTAssertNotNil(m.hipDriftLateral.value, m.hipDriftLateral.unavailableReason ?? "")
        XCTAssertNil(m.jumpForwardTravel.value)
    }

    func testFortyFiveDegreeViewRefusesBothWidthAndStagger() {
        var s = Shooter()
        s.hipSpanStature = Shooter.frontalHipSpan * cos(.pi / 4)     // 45°
        s.flights = [Flight(foot: nil, start: 1.00, end: 1.20, peakStature: 0.10, openEnded: true)]
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.15,
                                        setRealTime: 0.80, options: options(s))
        XCTAssertNil(m.stanceWidth.value)
        XCTAssertNil(m.stanceStagger.value)
        XCTAssertTrue(m.stanceWidth.unavailableReason!.contains("mixes"), m.stanceWidth.unavailableReason!)
        // The separation the camera actually measured is still reported.
        XCTAssertNotNil(m.ankleSeparationImage.value)
    }

    func testClippedAnklesRefuseTheirContacts() {
        var s = Shooter()
        s.floorV = Double(s.imageHeight) - 2                          // feet on the frame's bottom edge
        s.flights = []
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.15,
                                        setRealTime: 0.80, options: options(s))
        XCTAssertEqual(m.contactsUnavailable.count, 2)
        for why in m.contactsUnavailable.values {
            XCTAssertTrue(why.contains("bottom edge"), why)
        }
        XCTAssertEqual(m.pattern, .unknown)
        XCTAssertNil(m.stepCount.value)
    }

    func testTooFewFramesRefusesEverythingWithOneReason() {
        let m = FootworkMetrics.compute(timeline: BodyTimeline(frames: [], timeScale: 1, imageWidth: 1280,
                                                               imageHeight: 960, everyNthFrame: 1,
                                                               decodedFrames: 0, analysedFrames: 0,
                                                               wallSeconds: 0, notes: []),
                                        releaseRealTime: 1.0, setRealTime: nil)
        XCTAssertNotNil(m.unavailableReason)
        XCTAssertNil(m.stanceWidth.value)
        XCTAssertNil(m.jumpRise.value)
        XCTAssertEqual(m.pattern, .unknown)
    }

    func testMetresAreRefusedWithoutAStatedHeightAndLabelledStatedWithOne() {
        var s = Shooter()
        s.flights = [Flight(foot: nil, start: 1.00, end: 1.20, peakStature: 0.10, openEnded: true)]
        let bare = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.15,
                                           setRealTime: 0.80, options: options(s))
        XCTAssertNil(bare.metresPerStatureUnit.value)
        XCTAssertTrue(bare.metresPerStatureUnit.unavailableReason!.contains("no standing height"),
                      bare.metresPerStatureUnit.unavailableReason!)

        var o = options(s); o.standingHeightMetres = 1.70
        let withHeight = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.15,
                                                 setRealTime: 0.80, options: o)
        XCTAssertEqual(withHeight.metresPerStatureUnit.value ?? 0, 1.70 * 0.891, accuracy: 1e-9)
        XCTAssertTrue(withHeight.metresPerStatureUnit.provenance.contains("stated"),
                      withHeight.metresPerStatureUnit.provenance)
    }

    func testJumpTravelIsSignedTowardTheRim() {
        // Two identical shooters, the rim on opposite sides of the image: the same physical drift
        // must come back with opposite signs. (digest Ch 12 §12.8: "test toward-rim positive".)
        var s = Shooter()
        s.flights = [Flight(foot: nil, start: 1.00, end: 1.20, peakStature: 0.10, openEnded: true)]
        let timeline = s.timeline()
        var right = options(s); right.rimBearingSign = 1
        var left = options(s); left.rimBearingSign = -1
        let a = FootworkMetrics.compute(timeline: timeline, releaseRealTime: 1.15, setRealTime: 0.80, options: right)
        let b = FootworkMetrics.compute(timeline: timeline, releaseRealTime: 1.15, setRealTime: 0.80, options: left)
        XCTAssertEqual(a.rimBearingSign, 1)
        XCTAssertEqual(b.rimBearingSign, -1)
        XCTAssertEqual(a.stanceStagger.value ?? 0, -(b.stanceStagger.value ?? 0), accuracy: 1e-9)
    }

    // MARK: - The rules

    func testAStationaryShotFailsAPullUpDrillAndSaysSoInWords() {
        var s = Shooter()
        s.flights = [Flight(foot: nil, start: 1.00, end: 1.20, peakStature: 0.10, openEnded: true)]
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.15,
                                        setRealTime: 0.80, options: options(s))
        let e = FootworkEvaluation.evaluate(m, drill: .pullUpStrongSide, shootingSide: "right")
        let pattern = e.findings.first { $0.id == "pattern" }!
        XCTAssertEqual(pattern.severity, .fault)
        XCTAssertTrue(pattern.headline.contains("never stepped"), pattern.headline)
        XCTAssertEqual(e.summary, pattern.headline)

        // A rule the camera could not check is present and marked, never silently absent.
        let width = e.findings.first { $0.id == "stanceWidth" }!
        XCTAssertEqual(width.severity, .unmeasured)
        XCTAssertFalse(width.detail.isEmpty)
    }

    func testTheOneTwoOnTheWrongFootIsAWatchNotAFault() {
        var s = Shooter()
        s.flights = [
            Flight(foot: .left, start: 0.20, end: 0.42),              // left first: not the taught order
            Flight(foot: .right, start: 0.20, end: 0.62),
            Flight(foot: nil, start: 0.95, end: 1.20, peakStature: 0.10, openEnded: true),
        ]
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.12,
                                        setRealTime: 0.80, options: options(s))
        XCTAssertEqual(m.pattern, .oneTwo, m.patternReason)
        let e = FootworkEvaluation.evaluate(m, drill: .pullUpStrongSide, shootingSide: "right")
        let f = e.findings.first { $0.id == "firstFoot" }!
        XCTAssertEqual(f.severity, .watch)
        XCTAssertEqual(f.grade, .c)
        XCTAssertFalse(f.source.isEmpty)
    }

    func testFolkloreIsLabelledAndCarriesGradeD() {
        var s = Shooter()
        s.flights = [Flight(foot: nil, start: 1.00, end: 1.20, peakStature: 0.10, openEnded: true)]
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.15,
                                        setRealTime: 0.80, options: options(s))
        let e = FootworkEvaluation.evaluate(m, drill: .stationaryCatch, shootingSide: "right")
        let folk = e.findings.first { $0.isFolklore }
        XCTAssertNotNil(folk, "the foot-angle folklore must be listed, not omitted")
        XCTAssertEqual(folk!.grade, .d)
        XCTAssertEqual(folk!.severity, .unmeasured)
        XCTAssertEqual(e.findings.filter { $0.id == "footAngle" }.count, 1)
    }

    func testEveryNormCarriesAGradeAndASource() {
        for n in FootworkNorms().all {
            XCTAssertFalse(n.source.isEmpty, n.id)
            XCTAssertTrue(n.value.isFinite, n.id)
            XCTAssertTrue(ShotEvidenceGrade.allCases.contains(n.grade), n.id)
        }
        // The two ArcLab guessed at say so.
        XCTAssertEqual(FootworkNorms().gatherCeilingSeconds.grade, .d)
        XCTAssertTrue(FootworkNorms().gatherCeilingSeconds.source.contains("ArcLab's own"))
    }

    func testEveryFindingHasATextualDetailAndEveryDrillProducesFindings() {
        var s = Shooter()
        s.flights = [Flight(foot: nil, start: 1.00, end: 1.20, peakStature: 0.10, openEnded: true)]
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.15,
                                        setRealTime: 0.80, options: options(s))
        for drill in FootworkDrill.allCases {
            let e = FootworkEvaluation.evaluate(m, drill: drill, shootingSide: "right")
            XCTAssertFalse(e.findings.isEmpty, drill.rawValue)
            XCTAssertFalse(e.summary.isEmpty, drill.rawValue)
            for f in e.findings {
                XCTAssertFalse(f.headline.isEmpty, "\(drill.rawValue)/\(f.id)")
                XCTAssertFalse(f.detail.isEmpty, "\(drill.rawValue)/\(f.id)")
                XCTAssertFalse(f.source.isEmpty, "\(drill.rawValue)/\(f.id)")
            }
        }
    }

    func testMetricsRoundTripThroughJSON() throws {
        var s = Shooter()
        s.flights = [Flight(foot: nil, start: 1.00, end: 1.20, peakStature: 0.10, openEnded: true)]
        let m = FootworkMetrics.compute(timeline: s.timeline(), releaseRealTime: 1.15,
                                        setRealTime: 0.80, options: options(s))
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(FootworkMetrics.self, from: data)
        XCTAssertEqual(back.pattern, m.pattern)
        XCTAssertEqual(back.jumpRise.value, m.jumpRise.value)
        XCTAssertEqual(back.stanceWidth.unavailableReason, m.stanceWidth.unavailableReason)
    }
}
