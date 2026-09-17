import XCTest
import simd
@testable import ShotGeometry

/// The hand plate (1.3): a rigid triangle of **declared prior** size, attached at the fitted wrist,
/// whose orientation is recovered from the two knuckles' own view rays.
///
/// What these tests hold:
///   · three confident points recover the orientation a synthetic hand was built with;
///   · two confident points give a direction and **refuse** the roll, with a reason;
///   · the size prior is declared as a prior, in the type and in the exported record;
///   · lifting Vision's hand landmarks into the timeline names them, stamps a provenance on a wrist
///     borrowed from the hand pose, and bridges a gap of one sampled frame but never two;
///   · τ 0.75 maps to the measured release even when the dip was never found — the coverage bug.
final class HandTriangleTests: XCTestCase {

    let K = CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 48)
    let stature = 1.83

    /// A hand at `wrist` (Vision camera space: +x right, +y up, +z toward the camera) whose plate is
    /// rotated by `q`. Returns the true corners and the pixels they project to.
    func syntheticHand(wrist: SIMD3<Double>, rotation q: simd_quatd, side: String,
                       prior: HandSizePrior) -> (index: SIMD3<Double>, little: SIMD3<Double>,
                                                 xIndex: SIMD2<Double>, xLittle: SIMD2<Double>) {
        // Local frame: +y the pointing direction, +x from little toward index (right hand), +z the
        // palm normal — the frame `HandTriangleFit.axes` reads back out.
        let sign: Double = side == "left" ? -1 : 1
        let iLocal = SIMD3<Double>(sign * prior.breadth / 2, prior.palmLength, 0)
        let lLocal = SIMD3<Double>(-sign * prior.breadth / 2, prior.palmLength, 0)
        let i = wrist + q.act(iLocal), l = wrist + q.act(lLocal)
        func px(_ cam: SIMD3<Double>) -> SIMD2<Double> {
            let p = pinhole(cam)
            return SIMD2(K.fx * p.x / p.z + K.cx, K.fy * p.y / p.z + K.cy)
        }
        return (i, l, px(i), px(l))
    }

    // MARK: Orientation from three points

    func testOrientationFromThreePoints() {
        let prior = HandSizePrior(stature: stature, statureProvenance: "a test")
        let wrist = SIMD3<Double>(0.35, 1.90, -8.0)          // 8 m in front of the lens, arm up
        // Several attitudes, including ones well out of the image plane.
        let attitudes: [simd_quatd] = [
            simd_quatd(angle: 0, axis: SIMD3(0, 0, 1)),
            simd_quatd(angle: .pi / 6, axis: simd_normalize(SIMD3(1, 0, 0))),
            simd_quatd(angle: -.pi / 4, axis: simd_normalize(SIMD3(0, 1, 0))),
            simd_quatd(angle: .pi / 3, axis: simd_normalize(SIMD3(0.3, 0.5, 0.8))),
        ]
        for side in ["left", "right"] {
            for q in attitudes {
                let truth = syntheticHand(wrist: wrist, rotation: q, side: side, prior: prior)
                guard let axesTrue = HandTriangleFit.axes(wrist: wrist, indexMCP: truth.index,
                                                          littleMCP: truth.little, side: side) else {
                    return XCTFail("the synthetic plate has no axes")
                }
                // Recover: each knuckle is where its ray meets the prior's sphere about the wrist.
                let wPin = pinhole(wrist)
                guard let pi = HandTriangleFit.placeKnuckle(pixel: truth.xIndex, wrist: wPin, radius: prior.wristToMCP,
                                                            K: K, prefer: pinhole(truth.index), tolerance: 0.35),
                      let pl = HandTriangleFit.placeKnuckle(pixel: truth.xLittle, wrist: wPin, radius: prior.wristToMCP,
                                                            K: K, prefer: pinhole(truth.little), tolerance: 0.35)
                else { return XCTFail("no intersection for a plate that was built on the sphere") }
                XCTAssertFalse(pi.clamped); XCTAssertFalse(pl.clamped)
                guard let rigid = HandTriangleFit.rigidify(wrist: wPin, rawIndex: pi.point, rawLittle: pl.point, prior: prior),
                      let axes = HandTriangleFit.axes(wrist: wrist, indexMCP: visionCamera(rigid.index),
                                                      littleMCP: visionCamera(rigid.little), side: side)
                else { return XCTFail("the recovered plate has no axes") }
                let pointingError = Angle.degrees(BodyAngles.angleBetween(axes.pointing, axesTrue.pointing) ?? .pi)
                let normalError = Angle.degrees(BodyAngles.angleBetween(axes.palmNormal, axesTrue.palmNormal) ?? .pi)
                XCTAssertLessThan(pointingError, 1.0, "pointing direction, \(side) hand")
                XCTAssertLessThan(normalError, 2.0, "palm normal, \(side) hand")
                // And the plate came back the size it went in: rigid means rigid.
                XCTAssertEqual(simd_length(rigid.index - rigid.little), prior.breadth, accuracy: 1e-9)
                // Roll agrees with the truth's own roll.
                let rollTrue = HandTriangleFit.roll(pointing: axesTrue.pointing, palmNormal: axesTrue.palmNormal)
                let roll = HandTriangleFit.roll(pointing: axes.pointing, palmNormal: axes.palmNormal)
                if let a = rollTrue.value, let b = roll.value {
                    XCTAssertEqual(Angle.degrees(a), Angle.degrees(b), accuracy: 2.5)
                }
            }
        }
    }

    /// The palm normal points out of the palm, not out of the back of the hand: a right hand held
    /// palm-up must give a normal with a positive vertical component, and its mirror the same.
    func testPalmNormalSignIsAnatomical() {
        let prior = HandSizePrior(stature: stature, statureProvenance: "a test")
        let wrist = SIMD3<Double>(0, 1.8, -8)
        // Palm up, fingers pointing away from the camera (into the screen, −z is away here).
        let index = wrist + SIMD3(0.5 * prior.breadth, 0, -prior.palmLength)
        let little = wrist + SIMD3(-0.5 * prior.breadth, 0, -prior.palmLength)
        let right = HandTriangleFit.axes(wrist: wrist, indexMCP: index, littleMCP: little, side: "right")
        XCTAssertNotNil(right)
        XCTAssertGreaterThan(right!.palmNormal.y, 0.9, "a right hand with the index knuckle camera-right of the little one, fingers away, is palm-up")
        let left = HandTriangleFit.axes(wrist: wrist, indexMCP: index, littleMCP: little, side: "left")
        XCTAssertNotNil(left)
        XCTAssertLessThan(left!.palmNormal.y, -0.9, "the same two corners on a left hand are the back of the hand: the normal flips")
    }

    // MARK: Two points: a direction, and no roll

    func testTwoPointsRefuseTheRoll() {
        let prior = HandSizePrior(stature: stature, statureProvenance: "a test")
        var o = HandTriangleOptions(intrinsics: K)
        o.stature = stature
        o.shootingSide = "right"
        let wrist = SIMD3<Double>(0.3, 1.9, -8.0)
        let q = simd_quatd(angle: .pi / 5, axis: simd_normalize(SIMD3(0.2, 0.6, 0.7)))
        let truth = syntheticHand(wrist: wrist, rotation: q, side: "right", prior: prior)

        // Both knuckles → an orientation.
        let both = timeline(wrist: wrist, index: truth.xIndex, little: truth.xLittle)
        let full = HandTriangleFit.fit(timeline: both, releaseRealTime: 0.5, options: o)
        let fullRow = full.tracks.first { $0.side == "right" }?.frames.first
        XCTAssertEqual(fullRow?.pointsUsed, 3)
        XCTAssertNotNil(fullRow?.palmNormal)
        XCTAssertTrue(fullRow?.roll.isAvailable ?? false)

        // Only the index knuckle → a direction, and the roll is refused **with a reason**.
        let one = timeline(wrist: wrist, index: truth.xIndex, little: nil)
        let partial = HandTriangleFit.fit(timeline: one, releaseRealTime: 0.5, options: o)
        guard let row = partial.tracks.first(where: { $0.side == "right" })?.frames.first else {
            return XCTFail("two confident points should still make a row")
        }
        XCTAssertEqual(row.pointsUsed, 2)
        XCTAssertNotNil(row.pointing, "two points fix a direction")
        XCTAssertNil(row.palmNormal, "two points do not fix a plane")
        XCTAssertFalse(row.roll.isAvailable)
        let why = row.roll.unavailableReason ?? ""
        XCTAssertTrue(why.contains("two of the three"), "the reason must say what was missing: \(why)")
        XCTAssertTrue(why.contains("roll"), why)
        // And the shot-level flexion inherits the refusal rather than guessing a sign.
        XCTAssertFalse(partial.measures.wristFlexionAtRelease.isAvailable)
        XCTAssertNotNil(partial.measures.wristFlexionAtRelease.unavailableReason)
    }

    /// Both knuckles returned, and on top of each other in the image: this view is looking along the
    /// hand's own width, so there is nothing to orient and the plate is refused entirely — not fitted
    /// to the landmark noise, and not drawn.
    func testKnucklesTooCloseInTheImageRefuseThePlate() {
        var o = HandTriangleOptions(intrinsics: K)
        o.stature = stature
        o.shootingSide = "right"
        // A real plate, then the same plate with its two knuckles squashed to 2 px apart — under the
        // 6 px keypoint-noise floor — which is what an edge-on hand looks like to the detector.
        let prior = HandSizePrior(stature: stature, statureProvenance: "a test")
        let wrist = SIMD3<Double>(0.3, 1.9, -8.0)
        let truth = syntheticHand(wrist: wrist, rotation: simd_quatd(angle: .pi / 5, axis: simd_normalize(SIMD3(0.2, 0.6, 0.7))),
                                  side: "right", prior: prior)
        let mid = (truth.xIndex + truth.xLittle) / 2
        let narrow = simd_normalize(truth.xIndex - truth.xLittle)
        let t = timeline(wrist: wrist, index: mid + narrow, little: mid - narrow)   // 2 px apart
        let r = HandTriangleFit.fit(timeline: t, releaseRealTime: 0.5, options: o)
        let track = r.tracks.first { $0.side == "right" }
        XCTAssertEqual(track?.frames.count, 0, "no plate at all when the plate's width is not observable")
        XCTAssertNotNil(track?.unavailableReason)
        XCTAssertTrue((track?.notes ?? []).contains { $0.contains("keypoint-noise floor") }, "the refusal has to say why: \(track?.notes ?? [])")
        // The knuckles are not written into the timeline either — a corner nobody can place is absent.
        XCTAssertNil(r.timeline.frames[0].joints3D[Body3DJoint.rightIndexMCP])
        // The unsquashed plate, same wrist and same frames, does produce one.
        let ok = HandTriangleFit.fit(timeline: timeline(wrist: wrist, index: truth.xIndex, little: truth.xLittle),
                                     releaseRealTime: 0.5, options: o)
        XCTAssertGreaterThan(ok.tracks.first { $0.side == "right" }?.frames.count ?? 0, 0)
    }

    // MARK: The prior is declared as a prior

    func testSizePriorIsDeclared() {
        let prior = HandSizePrior(stature: stature, statureProvenance: "the shooter's stated height")
        XCTAssertTrue(prior.isPopulationPrior)
        XCTAssertEqual(prior.breadth, stature * 0.049, accuracy: 1e-12)
        XCTAssertEqual(prior.palmLength, stature * 0.058, accuracy: 1e-12)
        XCTAssertEqual(prior.wristToMCP, (pow(prior.palmLength, 2) + pow(prior.breadth / 2, 2)).squareRoot(), accuracy: 1e-12)
        XCTAssertTrue(HandSizePrior.breadthFractionRange.contains(HandSizePrior.breadthFraction))
        // The note has to say it is a prior and where it came from, because it is what the export and
        // the viewer's legend print.
        XCTAssertTrue(prior.note.contains("prior"), prior.note)
        XCTAssertTrue(prior.note.contains("Pheasant"), prior.note)
        XCTAssertTrue(prior.note.contains("NASA"), prior.note)
        XCTAssertTrue(prior.note.contains("the shooter's stated height"), prior.note)
        XCTAssertTrue(prior.note.contains("isoceles"), "the isoceles simplification is part of the prior")
    }

    func testNoStatureMeansNoPlate() {
        var o = HandTriangleOptions(intrinsics: K)
        o.stature = nil                      // and the synthetic timeline has no ankles or nose
        let t = timeline(wrist: SIMD3(0.3, 1.9, -8), index: SIMD2(980, 420), little: SIMD2(960, 424))
        let r = HandTriangleFit.fit(timeline: t, releaseRealTime: 0.5, options: o)
        XCTAssertTrue(r.tracks.isEmpty)
        XCTAssertFalse(r.warnings.isEmpty)
        XCTAssertTrue(r.warnings[0].contains("stature"), r.warnings[0])
    }

    // MARK: Lifting the landmarks

    func testLiftNamesSidesAndStampsProvenance() {
        var frames: [BodyFrame] = []
        for i in 0..<5 {
            var points: [String: BodyPoint2D] = [:]
            // The body pose loses the right wrist on frame 2 only.
            if i != 2 { points["rightWrist"] = BodyPoint2D(name: "rightWrist", u: 900, v: 400, confidence: 0.9) }
            let hand = BodyHandFrame(chirality: "right", role: "shooting", confidence: 0.8, landmarks: [
                HandLandmark.wrist: BodyPoint2D(name: "", u: 902, v: 402, confidence: 0.6),
                HandLandmark.indexMCP: BodyPoint2D(name: "", u: 915, v: 386, confidence: 0.7),
                HandLandmark.littleMCP: BodyPoint2D(name: "", u: 893, v: 390, confidence: 0.5),
            ])
            frames.append(BodyFrame(frameIndex: i, fileTime: Double(i) / 100, realTime: Double(i) / 100,
                                    points2D: points, hands: [hand]))
        }
        let (lifted, report) = HandPoints.lift(frames: frames)
        XCTAssertEqual(report.sidedByChirality, 5)
        XCTAssertEqual(report.sidedByNearestWrist, 0)
        XCTAssertEqual(report.wristsFilledFromHandPose, 1, "exactly the one frame the body pose lost")
        XCTAssertNotNil(lifted[0].points2D[Body2DPoint.rightIndexMCP])
        XCTAssertNotNil(lifted[0].points2D[Body2DPoint.rightLittleMCP])
        XCTAssertNotNil(lifted[0].points2D[Body2DPoint.rightHandWrist])
        XCTAssertNil(lifted[0].points2D[Body2DPoint.leftIndexMCP], "one hand, one side")
        // The borrowed wrist says it is borrowed; the body's own wrist says nothing.
        XCTAssertEqual(lifted[2].points2D["rightWrist"]?.u, 902)
        XCTAssertTrue(lifted[2].points2D["rightWrist"]!.provenance!.hasPrefix("wrist from hand pose"))
        XCTAssertNil(lifted[1].points2D["rightWrist"]?.provenance)
    }

    func testBridgeCrossesOneSampleAndNeverTwo() {
        func hand(_ ok: Bool) -> [BodyHandFrame] {
            ok ? [BodyHandFrame(chirality: "right", role: "shooting", confidence: 0.8, landmarks: [
                HandLandmark.indexMCP: BodyPoint2D(name: "", u: 900, v: 400, confidence: 0.7)])] : []
        }
        // seen . seen . . seen   → the single gap is bridged, the double gap is not.
        let pattern = [true, false, true, false, false, true]
        var frames: [BodyFrame] = []
        for (i, ok) in pattern.enumerated() {
            frames.append(BodyFrame(frameIndex: i, fileTime: Double(i) / 100, realTime: Double(i) / 100, hands: hand(ok)))
        }
        let (lifted, report) = HandPoints.lift(frames: frames)
        XCTAssertEqual(report.pointsInterpolated, 1)
        XCTAssertNotNil(lifted[1].points2D[Body2DPoint.rightIndexMCP])
        XCTAssertTrue(lifted[1].points2D[Body2DPoint.rightIndexMCP]!.provenance!.contains("interpolated across one sampled frame"))
        XCTAssertNil(lifted[3].points2D[Body2DPoint.rightIndexMCP], "a two-sample gap is not bridged")
        XCTAssertNil(lifted[4].points2D[Body2DPoint.rightIndexMCP])
        // And with the bridge switched off, nothing is filled in at all.
        var o = HandPoints.Options()
        o.interpolateAcrossSamples = 0
        let (plain, plainReport) = HandPoints.lift(frames: frames, options: o)
        XCTAssertEqual(plainReport.pointsInterpolated, 0)
        XCTAssertNil(plain[1].points2D[Body2DPoint.rightIndexMCP])
    }

    // MARK: The release instant on the normalised axis (the coverage bug)

    /// τ 0.75 **is** the release, and the release time is measured. A shot with no dip used to lose
    /// it — the dip → release segment was reached first, had a missing end, and gave up — which is
    /// why 33 of 37 free throws carried nothing at all at their own release instant.
    func testReleaseInstantSurvivesAMissingDip() {
        let anchors: [(phase: FormPhase, time: Double?)] =
            [(.set, 10.0), (.dip, nil), (.release, 11.0), (.followThrough, 11.4)]
        XCTAssertEqual(ShotForm.realTime(forNormalised: 0.75, anchors: anchors), 11.0)
        XCTAssertEqual(ShotForm.realTime(forNormalised: 0.0, anchors: anchors), 10.0)
        XCTAssertEqual(ShotForm.realTime(forNormalised: 1.0, anchors: anchors), 11.4)
        // The stretch that genuinely has no map still has none: nothing is interpolated over the gap.
        XCTAssertNil(ShotForm.realTime(forNormalised: 0.50, anchors: anchors))
        XCTAssertNil(ShotForm.realTime(forNormalised: 0.20, anchors: anchors))
        // Between release and follow-through it is a straight interpolation, as before.
        XCTAssertEqual(ShotForm.realTime(forNormalised: 0.875, anchors: anchors)!, 11.2, accuracy: 1e-9)
        // A release that was never dated is still nil: the fix admits measurements, not guesses.
        let noRelease: [(phase: FormPhase, time: Double?)] =
            [(.set, 10.0), (.dip, 10.5), (.release, nil), (.followThrough, 11.4)]
        XCTAssertNil(ShotForm.realTime(forNormalised: 0.75, anchors: noRelease))
    }

    // MARK: Helper

    /// One frame carrying a fitted wrist, a fitted elbow and the two knuckle pixels, plus enough of a
    /// body for the stature fallback to have something to chew on.
    func timeline(wrist: SIMD3<Double>, index: SIMD2<Double>?, little: SIMD2<Double>?) -> BodyTimeline {
        var frames: [BodyFrame] = []
        for i in 0..<5 {
            var points: [String: BodyPoint2D] = [
                "rightWrist": BodyPoint2D(name: "rightWrist", u: 900, v: 400, confidence: 0.9),
            ]
            if let index { points[Body2DPoint.rightIndexMCP] = BodyPoint2D(name: Body2DPoint.rightIndexMCP, u: index.x, v: index.y, confidence: 0.7) }
            if let little { points[Body2DPoint.rightLittleMCP] = BodyPoint2D(name: Body2DPoint.rightLittleMCP, u: little.x, v: little.y, confidence: 0.6) }
            let elbow = wrist - SIMD3(0, 0.30, 0)
            let joints: [String: BodyJoint3D] = [
                "rightWrist": BodyJoint3D(name: "rightWrist", position: wrist, cameraPosition: wrist),
                "rightElbow": BodyJoint3D(name: "rightElbow", position: elbow, cameraPosition: elbow),
            ]
            frames.append(BodyFrame(frameIndex: i, fileTime: 0.5 + Double(i) / 100, realTime: 0.5 + Double(i) / 100,
                                    joints3D: joints, points2D: points,
                                    hands: [BodyHandFrame(chirality: "right", role: "shooting", confidence: 0.8, landmarks: [:])]))
        }
        return BodyTimeline(frames: frames, timeScale: 1, imageWidth: 1920, imageHeight: 1080,
                            everyNthFrame: 1, decodedFrames: 5, analysedFrames: 5, wallSeconds: 0, notes: [])
    }
}
