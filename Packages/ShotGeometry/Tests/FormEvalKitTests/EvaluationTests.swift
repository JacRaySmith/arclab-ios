import XCTest
import simd
@testable import FormEvalKit
@testable import ShotGeometry

/// The measurement side of the harness, on skeletons whose answers were chosen before the code ran.
final class EvaluationTests: XCTestCase {

    /// A frame with named 3-D joints (Vision's camera frame: +x right, +y up, +z toward the camera)
    /// and, optionally, a reprojected pixel per joint and a 2-D observation.
    func frame(_ t: Double, _ joints: [String: SIMD3<Double>],
               projected: [String: SIMD2<Double>] = [:],
               observed: [String: (SIMD2<Double>, Double)] = [:]) -> BodyFrame {
        var j3: [String: BodyJoint3D] = [:]
        for (n, p) in joints {
            let uv = projected[n]
            j3[n] = BodyJoint3D(name: n, position: p, cameraPosition: p, imageU: uv?.x, imageV: uv?.y, confidence: 1)
        }
        var p2: [String: BodyPoint2D] = [:]
        for (n, o) in observed { p2[n] = BodyPoint2D(name: n, u: o.0.x, v: o.0.y, confidence: o.1) }
        return BodyFrame(frameIndex: Int(t * 100), fileTime: t, realTime: t, joints3D: j3, points2D: p2)
    }

    // MARK: - reprojection

    func testReprojectionErrorIsTheDistanceBetweenTheFitAndTheDetector() throws {
        let f = [frame(0, ["rightElbow": SIMD3(0, 0, -3)],
                       projected: ["rightElbow": SIMD2(100, 100)],
                       observed: ["rightElbow": (SIMD2(103, 104), 0.9)]),
                 frame(0.1, ["rightElbow": SIMD3(0, 0, -3)],
                       projected: ["rightElbow": SIMD2(100, 100)],
                       observed: ["rightElbow": (SIMD2(100, 100), 0.9)])]
        let e = FormEvaluator.reprojectionErrors(joint: "rightElbow", fitted: f, observedIn: f, gate: 0.3)
        XCTAssertEqual(e, [5.0, 0.0])          // 3–4–5
    }

    func testAnObservationBelowTheConfidenceGateIsNotAnObservation() {
        let f = [frame(0, ["rightElbow": SIMD3(0, 0, -3)],
                       projected: ["rightElbow": SIMD2(100, 100)],
                       observed: ["rightElbow": (SIMD2(130, 140), 0.2)])]
        XCTAssertTrue(FormEvaluator.reprojectionErrors(joint: "rightElbow", fitted: f, observedIn: f, gate: 0.3).isEmpty)
    }

    /// `nose` is stored as `centerHead` and `neck` as `centerShoulder` in the 3-D name space; a
    /// harness that forgets that silently reports "this joint never reprojects".
    func testTheNoseIsLookedUpUnderItsThreeDName() {
        let f = [frame(0, [Body3DJoint.centerHead: SIMD3(0, 0, -3)],
                       projected: [Body3DJoint.centerHead: SIMD2(50, 50)],
                       observed: [Body2DPoint.nose: (SIMD2(50, 60), 0.9)])]
        XCTAssertEqual(FormEvaluator.reprojectionErrors(joint: Body2DPoint.nose, fitted: f, observedIn: f, gate: 0.3), [10.0])
    }

    // MARK: - bones

    /// A forearm that is 0.30, 0.33 and 0.27 long over three frames: median 0.30, sample SD 0.03,
    /// so the reported constancy is exactly 10 %.
    func testBoneSDIsAPercentageOfTheBonesOwnMedianLength() throws {
        let frames = [0.30, 0.33, 0.27].enumerated().map { i, len in
            frame(Double(i) * 0.1, [Body2DPoint.rightElbow: SIMD3(0, 0, -3),
                                    Body2DPoint.rightWrist: SIMD3(len, 0, -3)])
        }
        let sd = try XCTUnwrap(FormEvaluator.boneSDPercent(frames: frames)["forearmRight"])
        XCTAssertEqual(sd, 10.0, accuracy: 1e-9)
    }

    /// Left forearm 0.30, right 0.33: |L−R| ÷ mean = 0.03 / 0.315 = 9.5238 %.
    func testAsymmetryIsTheDifferenceOverTheMean() throws {
        let frames = (0..<3).map { i in
            frame(Double(i) * 0.1, [Body2DPoint.leftElbow: SIMD3(0, 0, -3), Body2DPoint.leftWrist: SIMD3(0.30, 0, -3),
                                    Body2DPoint.rightElbow: SIMD3(0, 1, -3), Body2DPoint.rightWrist: SIMD3(0.33, 1, -3)])
        }
        let a = try XCTUnwrap(FormEvaluator.asymmetryPercent(frames: frames)["forearm"])
        XCTAssertEqual(a, 200 * 0.03 / 0.63, accuracy: 1e-9)
    }

    // MARK: - the shoulder-width ruler

    func testShoulderWidthIsWintersBreadthCarriedByTheAnkleToNoseSpan() throws {
        // A 400 px ankle-to-nose span is 0.891 H, so 0.245 H is 400 × 0.245/0.891 = 109.99 px.
        let frames = (0..<5).map { i in
            frame(Double(i) * 0.1, [:], observed: [Body2DPoint.nose: (SIMD2(100, 100), 0.9),
                                                   Body2DPoint.leftAnkle: (SIMD2(100, 500), 0.9),
                                                   Body2DPoint.rightAnkle: (SIMD2(100, 480), 0.9)])
        }
        let (w, note) = FormEvaluator.shoulderWidthPixels(frames: frames, gate: 0.3)
        XCTAssertEqual(try XCTUnwrap(w), 400 * 0.245 / 0.891, accuracy: 1e-9)
        XCTAssertTrue(note.contains("prior-scaled"))
    }

    func testShoulderWidthRefusesRatherThanGuessing() {
        let frames = [frame(0, [:], observed: [Body2DPoint.nose: (SIMD2(100, 100), 0.9)])]
        let (w, note) = FormEvaluator.shoulderWidthPixels(frames: frames, gate: 0.3)
        XCTAssertNil(w)
        XCTAssertTrue(note.contains("no frame carried"))
    }

    // MARK: - phase instants

    func testNearestFrameRefusesAnInstantOutsideItsTolerance() {
        let frames = (0..<10).map { frame(Double($0) * 0.1, [:]) }
        XCTAssertEqual(FormEvaluator.medianFrameSpacing(frames), 0.1, accuracy: 1e-9)
        XCTAssertNotNil(FormEvaluator.nearestFrame(frames, 0.44, tolerance: 0.15))
        XCTAssertNil(FormEvaluator.nearestFrame(frames, 5.0, tolerance: 0.15))
    }

    // MARK: - form measures

    /// A right arm bent to exactly 90° at the elbow, with the wrist 1.0 m above the ankles on a
    /// 2.0 m stature: the harness must report 90° and 0.5 stature, not something near them.
    func testFormMeasuresReadTheAnglesTheSkeletonWasBuiltWith() throws {
        let joints: [String: SIMD3<Double>] = [
            Body2DPoint.rightShoulder: SIMD3(0, 1.4, -3),
            Body2DPoint.rightElbow: SIMD3(0, 1.1, -3),
            Body2DPoint.rightWrist: SIMD3(0.3, 1.1, -3),
            Body2DPoint.leftShoulder: SIMD3(-0.4, 1.4, -3),
            Body2DPoint.rightHip: SIMD3(0, 0.9, -3),
            Body2DPoint.leftHip: SIMD3(-0.4, 0.9, -3),
            Body2DPoint.rightKnee: SIMD3(0, 0.5, -3),
            Body2DPoint.rightAnkle: SIMD3(0, 0.1, -3),
            Body2DPoint.leftAnkle: SIMD3(-0.4, 0.1, -3),
            Body3DJoint.centerHead: SIMD3(0, 1.6, -3),
        ]
        let frames = (0..<9).map { frame(Double($0) * 0.05, joints) }
        let m = FormMeasures.all(frames: frames, side: "right",
                                 phases: [.set: 0.0, .dip: 0.1, .release: 0.3, .followThrough: 0.4], stature: 2.0)
        XCTAssertEqual(try XCTUnwrap(m["elbowAtRelease"]), 90.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(m["kneeMinimum"]), 180.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(m["trunkLeanAtRelease"]), 0.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(m["releaseHeight"]), (1.1 - 0.1) / 2.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m["jumpHeight"]), 0.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m["dipDepth"]), 0.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m["headHorizontalRange"]), 0.0, accuracy: 1e-9)
    }

    /// A shot the body model refused a dip for has no dip depth — not a zero.
    func testDipDepthIsAbsentWhenTheShotHasNoDip() {
        let joints: [String: SIMD3<Double>] = [
            Body2DPoint.leftHip: SIMD3(-0.2, 0.9, -3), Body2DPoint.rightHip: SIMD3(0.2, 0.9, -3),
        ]
        let frames = (0..<9).map { frame(Double($0) * 0.05, joints) }
        let m = FormMeasures.all(frames: frames, side: "right", phases: [.set: 0.0, .release: 0.3], stature: 2.0)
        XCTAssertNil(m["dipDepth"])
    }

    func testAMeasureWithoutItsInputsIsAbsentRatherThanZero() {
        let frames = (0..<5).map { frame(Double($0) * 0.05, [Body2DPoint.rightShoulder: SIMD3(0, 1.4, -3)]) }
        let m = FormMeasures.all(frames: frames, side: "right", phases: [.release: 0.1], stature: 2.0)
        XCTAssertNil(m["elbowAtRelease"])
        XCTAssertNil(m["kneeMinimum"])
        XCTAssertNil(m["releaseHeight"])
    }

    func testAShotWithNoReleaseHasNoMeasuresAtAll() {
        let frames = (0..<5).map { frame(Double($0) * 0.05, [Body2DPoint.rightShoulder: SIMD3(0, 1.4, -3)]) }
        XCTAssertTrue(FormMeasures.all(frames: frames, side: "right", phases: [:], stature: 2.0).isEmpty)
    }

    // MARK: - the held-out idea, end to end on a synthetic shot

    /// Build a rigid two-segment arm swinging in front of a pinhole camera, project it exactly, feed
    /// the projections in as the 2-D observations, and check the three things the whole harness rests
    /// on:
    ///
    ///   a. a perfect input reprojects to well under a pixel;
    ///   b. the **blink** design — the joint hidden on a few frames — is harder than being driven by
    ///      it and still lands close, so it is measuring prediction rather than nothing;
    ///   c. the **absent** design, where the joint is hidden on every frame, produces *no point at
    ///      all* on this build's fit. That is the behaviour the harness reports as `no point`, and
    ///      pinning it here means the report's wording stops being true the moment the fit learns to
    ///      carry an unobserved joint.
    func testHeldOutRefitOnASyntheticSkeletonStaysCloseWithoutItsOwnPixels() throws {
        let K = CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 48)
        var frames: [BodyFrame] = []
        for i in 0..<24 {
            let t = Double(i) / 60.0
            let swing = 0.5 * Foundation.sin(2 * .pi * t)          // the arm opening and closing
            var positions: [String: SIMD3<Double>] = [
                Body2DPoint.leftShoulder: SIMD3(-0.20, 0.25, 5.0),
                Body2DPoint.rightShoulder: SIMD3(0.20, 0.25, 5.0),
                Body2DPoint.leftHip: SIMD3(-0.15, -0.25, 5.0),
                Body2DPoint.rightHip: SIMD3(0.15, -0.25, 5.0),
                Body2DPoint.leftKnee: SIMD3(-0.15, -0.70, 5.0),
                Body2DPoint.rightKnee: SIMD3(0.15, -0.70, 5.0),
                Body2DPoint.leftAnkle: SIMD3(-0.15, -1.15, 5.0),
                Body2DPoint.rightAnkle: SIMD3(0.15, -1.15, 5.0),
                Body2DPoint.nose: SIMD3(0.0, 0.55, 5.0),
                Body2DPoint.neck: SIMD3(0.0, 0.35, 5.0),
                Body2DPoint.leftElbow: SIMD3(-0.25, -0.05, 5.0),
                Body2DPoint.leftWrist: SIMD3(-0.25, -0.35, 5.0),
            ]
            positions[Body2DPoint.rightElbow] = SIMD3(0.20 + 0.30 * Foundation.sin(swing), 0.25 - 0.30 * Foundation.cos(swing), 5.0)
            let e = positions[Body2DPoint.rightElbow]!
            positions[Body2DPoint.rightWrist] = SIMD3(e.x + 0.25 * Foundation.sin(2 * swing), e.y - 0.25 * Foundation.cos(2 * swing), 5.0)

            var p2: [String: BodyPoint2D] = [:]
            for (n, p) in positions {
                // Pinhole, +y down in the image: the fit's own convention.
                let u = K.fx * p.x / p.z + K.cx, v = K.fy * (-p.y) / p.z + K.cy
                p2[n] = BodyPoint2D(name: n, u: u, v: v, confidence: 0.9)
            }
            frames.append(BodyFrame(frameIndex: i, fileTime: t, realTime: t, joints3D: [:], points2D: p2))
        }
        let timeline = BodyTimeline(frames: frames, timeScale: 1, imageWidth: 1920, imageHeight: 1080,
                                    everyNthFrame: 1, decodedFrames: frames.count, analysedFrames: frames.count,
                                    wallSeconds: 0, notes: [])
        var o = BodySkeletonOptions(intrinsics: K)
        o.scale = .statedHeight(metres: 1.90)

        let driven = BodySkeletonFit.fit(timeline: timeline, options: o)
        let drivenErr = FormEvaluator.reprojectionErrors(joint: Body2DPoint.rightWrist,
                                                         fitted: driven.timeline.frames, observedIn: frames, gate: 0.3)
        let drivenMedian = try XCTUnwrap(EvalStats.median(drivenErr))
        XCTAssertLessThan(drivenMedian, 1.0, "a perfect synthetic input must reproject to well under a pixel")

        // (b) blink: hide the wrist on every 4th frame, score those frames only.
        var holes = timeline
        var hidden: Set<Int> = []
        for i in holes.frames.indices where i % 4 == 2 {
            holes.frames[i].points2D.removeValue(forKey: Body2DPoint.rightWrist)
            hidden.insert(i)
        }
        let blinkFit = BodySkeletonFit.fit(timeline: holes, options: o)
        let blinkErr = FormEvaluator.reprojectionErrors(joint: Body2DPoint.rightWrist,
                                                        fitted: blinkFit.timeline.frames, observedIn: frames,
                                                        gate: 0.3, onlyFrames: hidden)
        XCTAssertEqual(blinkErr.count, hidden.count, "the blink pass must be scored on exactly the hidden frames")
        let blinkMedian = try XCTUnwrap(EvalStats.median(blinkErr))
        XCTAssertGreaterThan(blinkMedian, drivenMedian, "predicting a joint cannot be easier than fitting it")
        XCTAssertLessThan(blinkMedian, 100.0, "a wrist bracketed by observed frames should not fly off the frame")

        // (c) absent: hide it everywhere. This build's fit declines to place it.
        var stripped = timeline
        for i in stripped.frames.indices { stripped.frames[i].points2D.removeValue(forKey: Body2DPoint.rightWrist) }
        let held = BodySkeletonFit.fit(timeline: stripped, options: o)
        let heldErr = FormEvaluator.reprojectionErrors(joint: Body2DPoint.rightWrist,
                                                       fitted: held.timeline.frames, observedIn: frames, gate: 0.3)
        XCTAssertTrue(heldErr.isEmpty,
                      "a joint this build never observed is dropped, not predicted — if that changes, the report's `no point` column changes meaning")
    }
}
