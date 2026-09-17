import XCTest
import simd
@testable import ShotGeometry

/// 1.3 Track C. The foot triangle, tested where it can be tested exactly: on a synthetic foot of
/// **the prior's own shape**, at a known yaw, projected through known intrinsics. If the fit cannot
/// recover the yaw of a foot it built itself, nothing it says about a real one is worth reading —
/// and the same synthetic case pins the reprojection residual at ~0, which is what makes the 15–20 px
/// residual measured on real footage readable as "the prior's shape is wrong", not "the code is".
final class FootKinematicsTests: XCTestCase {

    let stature = 1.83
    var intrinsics: CameraIntrinsics { CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 73.83) }
    var prior: FootSizePrior { FootSizePrior(stature: stature, statureProvenance: "a test") }

    // MARK: - A foot built from the prior, at a known pose

    /// Vision camera space: +x right, +y up, +z toward the camera, so a point 6 m in front has z = −6.
    /// The foot is flat on the floor (its up is camera up) and yawed by `yaw` from the optical axis.
    func foot(side: FootSide, yaw: Double, ankle A: SIMD3<Double>)
        -> (ankle: SIMD3<Double>, heel: SIMD3<Double>, bigToe: SIMD3<Double>, littleToe: SIMD3<Double>)
    {
        let u = SIMD3<Double>(0, 1, 0)
        let f = SIMD3<Double>(sin(yaw), 0, -cos(yaw))
        let l = simd_cross(u, f)                       // the foot's own left
        let p = prior
        func place(_ local: SIMD3<Double>) -> SIMD3<Double> {
            let d = local - p.ankleLocal
            return A + d.x * f + d.y * l + d.z * u
        }
        return (A, place(p.heelLocal), place(p.bigToeLocal(side: side)), place(p.littleToeLocal(side: side)))
    }

    func project(_ visionPoint: SIMD3<Double>) -> SIMD2<Double> {
        let p = pinhole(visionPoint)
        return intrinsics.pixel(fromNormalized: SIMD2(p.x / p.z, p.y / p.z))
    }

    func timeline(side: FootSide, yaw: Double, frames n: Int = 9,
                  toeJitterPixels: Double = 0) -> BodyTimeline {
        let A = SIMD3<Double>(0.30, -0.90, -6.00)
        let g = foot(side: side, yaw: yaw, ankle: A)
        let heelName = side == .left ? Body2DPoint.leftHeel : Body2DPoint.rightHeel
        let bigName = side == .left ? Body2DPoint.leftBigToe : Body2DPoint.rightBigToe
        let littleName = side == .left ? Body2DPoint.leftLittleToe : Body2DPoint.rightLittleToe
        let ankleName = side == .left ? Body3DJoint.leftAnkle : Body3DJoint.rightAnkle
        var out: [BodyFrame] = []
        for i in 0..<n {
            let t = 1.0 + 0.01 * Double(i)
            var points: [String: BodyPoint2D] = [:]
            func add(_ name: String, _ p: SIMD3<Double>, _ jitter: Double) {
                let q = project(p)
                points[name] = BodyPoint2D(name: name, u: q.x + jitter, v: q.y, confidence: 0.85)
            }
            add(heelName, g.heel, 0)
            add(bigName, g.bigToe, i % 2 == 0 ? toeJitterPixels : -toeJitterPixels)
            add(littleName, g.littleToe, i % 2 == 0 ? -toeJitterPixels : toeJitterPixels)
            // The ankle, as the skeleton fit would have left it, plus a 2-D ankle so the rim-bearing
            // parallax has a shooter column to measure against.
            let ankleUV = project(A)
            points[side == .left ? Body2DPoint.leftAnkle : Body2DPoint.rightAnkle] =
                BodyPoint2D(name: side == .left ? Body2DPoint.leftAnkle : Body2DPoint.rightAnkle,
                            u: ankleUV.x, v: ankleUV.y, confidence: 0.9)
            let joint = BodyJoint3D(name: ankleName, position: A, cameraPosition: A,
                                    imageU: ankleUV.x, imageV: ankleUV.y, confidence: nil)
            out.append(BodyFrame(frameIndex: i, fileTime: t, realTime: t,
                                 joints3D: [ankleName: joint], points2D: points))
        }
        return BodyTimeline(frames: out, timeScale: 1, imageWidth: 1920, imageHeight: 1080,
                            everyNthFrame: 1, decodedFrames: n, analysedFrames: n,
                            wallSeconds: 0.1, notes: [])
    }

    func options(rimU: Double? = nil, side: FootSide = .right) -> FootTriangleOptions {
        var o = FootTriangleOptions(intrinsics: intrinsics)
        o.stature = stature
        o.statureProvenance = "a test"
        o.shootingSide = side.rawValue
        o.rimImageU = rimU
        o.setWindowSeconds = 0.2
        return o
    }

    // MARK: - The prior itself

    func testPriorIsWinterSegmentTable() {
        let p = prior
        XCTAssertEqual(p.footLength, 0.152 * stature, accuracy: 1e-12)
        XCTAssertEqual(p.ballWidth, 0.055 * stature, accuracy: 1e-12)
        XCTAssertEqual(p.ankleHeight, 0.039 * stature, accuracy: 1e-12)
        XCTAssertTrue(p.isPopulationPrior)
        XCTAssertTrue(p.note.contains("population prior"), p.note)
        XCTAssertTrue(p.note.contains("Drillis"), p.note)
        // The big toe is medial: on the left foot it sits on that foot's right (−y in the foot frame).
        XCTAssertLessThan(p.bigToeLocal(side: .left).y, 0)
        XCTAssertGreaterThan(p.bigToeLocal(side: .right).y, 0)
        // The three radii are ordered heel < little toe < big toe, and all of them are real lengths.
        let r = p.radii(side: .right)
        XCTAssertLessThan(r.heel, r.littleToe)
        XCTAssertLessThan(r.littleToe, r.bigToe)
    }

    // MARK: - The fit recovers a pose it was given

    func testRecoversKnownYawOnBothFeet() {
        for side in FootSide.allCases {
            for yawDegrees in [-40.0, 0.0, 25.0, 70.0] {
                let yaw = Angle.radians(yawDegrees)
                let r = FootTriangleFit.run(timeline: timeline(side: side, yaw: yaw),
                                            releaseRealTime: 1.05, setRealTime: 1.04,
                                            options: options(side: side))
                guard let track = r.tracks.first(where: { $0.side == side.rawValue }),
                      let f = track.frames.first else {
                    return XCTFail("\(side.rawValue) at \(yawDegrees)°: no frame was fitted — \(r.tracks.map { $0.unavailableReason ?? "" })")
                }
                XCTAssertEqual(f.pointsUsed, 3)
                guard let got = f.yawFromCameraAxis.degrees else {
                    return XCTFail("\(side.rawValue) at \(yawDegrees)°: \(f.yawFromCameraAxis.unavailableReason ?? "")")
                }
                XCTAssertEqual(got, yawDegrees, accuracy: 1.0,
                               "\(side.rawValue) foot at \(yawDegrees)° came back at \(got)°")
            }
        }
    }

    /// A flat foot has zero roll, and the handedness must be right for **both** feet: get the
    /// `across` sign wrong on one of them and its roll comes back at 180°, not 0°.
    func testFlatFootHasZeroRollOnBothFeet() {
        for side in FootSide.allCases {
            let r = FootTriangleFit.run(timeline: timeline(side: side, yaw: Angle.radians(30)),
                                        releaseRealTime: 1.05, setRealTime: 1.04, options: options(side: side))
            guard let f = r.tracks.first(where: { $0.side == side.rawValue })?.frames.first else {
                return XCTFail("no frame for the \(side.rawValue) foot")
            }
            guard let roll = f.roll.degrees else { return XCTFail(f.roll.unavailableReason ?? "") }
            XCTAssertEqual(abs(roll), 0, accuracy: 3.0, "\(side.rawValue) foot flat on the floor rolled \(roll)°")
            XCTAssertGreaterThan(f.footUp?.y ?? -1, 0.9, "the \(side.rawValue) foot's up must point up")
        }
    }

    /// The whole point of the rigid reprojection: on a foot that really is the prior's shape it is
    /// ~0, so a large value on real footage is a statement about the prior, not about the code.
    func testRigidReprojectionIsNearZeroOnAPriorShapedFoot() {
        let r = FootTriangleFit.run(timeline: timeline(side: .right, yaw: Angle.radians(-35)),
                                    releaseRealTime: 1.05, setRealTime: 1.04, options: options())
        guard let f = r.tracks.first(where: { $0.side == "right" })?.frames.first else {
            return XCTFail("no frame")
        }
        guard let rms = f.reprojectionPixels.value else { return XCTFail(f.reprojectionPixels.unavailableReason ?? "") }
        XCTAssertLessThan(rms, 1.0, "a foot of the prior's own shape reprojected \(rms) px away from itself")
        XCTAssertEqual(f.lengthResidual.value ?? 9, 0, accuracy: 0.02)
        XCTAssertEqual(f.widthResidual.value ?? 9, 0, accuracy: 0.02)
    }

    /// A ±1 px landmark error has to turn into an angle, and that angle has to be finite and small
    /// at this framing — that is the error bar the foot angle is published with.
    func testPixelNoiseSigmaIsPublishedAndSane() {
        let r = FootTriangleFit.run(timeline: timeline(side: .right, yaw: Angle.radians(-35)),
                                    releaseRealTime: 1.05, setRealTime: 1.04, options: options(rimU: 545.5))
        guard let f = r.tracks.first(where: { $0.side == "right" })?.frames.first,
              let sigma = f.yawSigmaFromPixelNoise.degrees else {
            return XCTFail("no propagated σ")
        }
        XCTAssertGreaterThan(sigma, 0)
        XCTAssertLessThan(sigma, 20, "a ±1 px error should not swing the yaw by \(sigma)°")
        XCTAssertNotNil(f.pointingImagePixels.value)
        XCTAssertNotNil(r.measures.footAnglePixelNoiseSigmaAtSet.value,
                        r.measures.footAnglePixelNoiseSigmaAtSet.unavailableReason ?? "")
    }

    // MARK: - What it refuses

    func testNoStatureRefusesEverythingWithAReason() {
        var o = options()
        o.stature = nil
        let r = FootTriangleFit.run(timeline: timeline(side: .right, yaw: 0),
                                    releaseRealTime: 1.05, setRealTime: 1.04, options: o)
        XCTAssertTrue(r.tracks.isEmpty)
        XCTAssertNil(r.measures.footAngleToRimAtSet.value)
        XCTAssertTrue(r.measures.footAngleToRimAtSet.unavailableReason!.contains("stature"),
                      r.measures.footAngleToRimAtSet.unavailableReason!)
    }

    func testNoRimColumnRefusesTheRimAngleButKeepsTheCameraYaw() {
        let r = FootTriangleFit.run(timeline: timeline(side: .right, yaw: Angle.radians(20)),
                                    releaseRealTime: 1.05, setRealTime: 1.04, options: options(rimU: nil))
        XCTAssertNil(r.measures.footAngleToRimAtSet.value)
        XCTAssertTrue(r.measures.footAngleToRimAtSet.unavailableReason!.contains("rim"),
                      r.measures.footAngleToRimAtSet.unavailableReason!)
        // The yaw that needs no rim survives.
        XCTAssertNotNil(r.tracks.first(where: { $0.side == "right" })?.frames.first?.yawFromCameraAxis.value)
    }

    func testRollIsRefusedWhenTheToePairIsTooCloseInTheImage() {
        // A foot pointing almost straight at the camera projects its two toes on top of each other.
        var o = options()
        o.minimumToePairPixels = 40          // far above what this framing gives, so the gate must bite
        let r = FootTriangleFit.run(timeline: timeline(side: .right, yaw: 0),
                                    releaseRealTime: 1.05, setRealTime: 1.04, options: o)
        guard let f = r.tracks.first(where: { $0.side == "right" })?.frames.first else { return XCTFail("no frame") }
        XCTAssertNil(f.roll.value)
        XCTAssertTrue(f.roll.unavailableReason!.contains("px apart"), f.roll.unavailableReason!)
        XCTAssertNil(f.footUp, "with the roll refused the foot's up must be refused with it, not kept")
        // …and the toe separation that refused it is published as a number.
        XCTAssertNotNil(f.toePairPixels.value)
    }

    func testLowConfidenceLandmarksAreAbsentWithTheNumberThatRefusedThem() {
        var tl = timeline(side: .right, yaw: Angle.radians(20))
        for i in tl.frames.indices {
            if var p = tl.frames[i].points2D[Body2DPoint.rightBigToe] {
                p.confidence = 0.10
                tl.frames[i].points2D[Body2DPoint.rightBigToe] = p
            }
        }
        let r = FootTriangleFit.run(timeline: tl, releaseRealTime: 1.05, setRealTime: 1.04, options: options())
        guard let f = r.tracks.first(where: { $0.side == "right" })?.frames.first else { return XCTFail("no frame") }
        XCTAssertNil(f.bigToe)
        XCTAssertEqual(f.pointsUsed, 2)
        XCTAssertNil(f.roll.value)
        XCTAssertTrue(f.refusedPoints[Body2DPoint.rightBigToe]?.contains("0.10") ?? false,
                      f.refusedPoints.description)
    }

    // MARK: - Heel-first / toe-first

    func testStrikeOrderReadsHeelFirstAndToeFirstFromTheImageRows() {
        // Two touchdowns: the left foot lands heel-down (heel row *below* the toes in the image),
        // the right foot toe-down. Image v increases downwards, so "heel lower" = larger v.
        func frame(_ t: Double, heelDrop: Double) -> BodyFrame {
            var points: [String: BodyPoint2D] = [:]
            func p(_ n: String, _ u: Double, _ v: Double) { points[n] = BodyPoint2D(name: n, u: u, v: v, confidence: 0.8) }
            p(Body2DPoint.leftHeel, 900, 800 + heelDrop)
            p(Body2DPoint.leftBigToe, 940, 800)
            p(Body2DPoint.leftLittleToe, 945, 800)
            p(Body2DPoint.rightHeel, 800, 800 - heelDrop)
            p(Body2DPoint.rightBigToe, 840, 800)
            p(Body2DPoint.rightLittleToe, 845, 800)
            return BodyFrame(frameIndex: Int(t * 100), fileTime: t, realTime: t, points2D: points)
        }
        let tl = BodyTimeline(frames: [frame(1.00, heelDrop: 12), frame(1.10, heelDrop: 12)],
                              timeScale: 1, imageWidth: 1920, imageHeight: 1080, everyNthFrame: 1,
                              decodedFrames: 2, analysedFrames: 2, wallSeconds: 0, notes: [])
        let contacts = [
            FootContact(foot: .left, startRealTime: 1.00, endRealTime: 1.30, isTouchdown: true,
                        precedingFlightFullySeen: true, isTakeoff: true, samples: 8, meanHeightStature: 0.01),
            FootContact(foot: .right, startRealTime: 1.10, endRealTime: 1.30, isTouchdown: true,
                        precedingFlightFullySeen: true, isTakeoff: true, samples: 6, meanHeightStature: 0.01)]
        let e = FootTriangleFit.strikes(timeline: tl, contacts: contacts, statureImagePixels: 500,
                                        liftRealTime: 1.30, releaseRealTime: 1.45)
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e.first(where: { $0.foot == "left" })?.strike, FootStrike.heelFirst.rawValue)
        XCTAssertEqual(e.first(where: { $0.foot == "right" })?.strike, FootStrike.toeFirst.rawValue)
        XCTAssertEqual(e.first(where: { $0.foot == "left" })?.heelMinusToeStature.value ?? 0, 12.0 / 500, accuracy: 1e-9)
    }

    func testStrikeOrderRefusesWithAReasonWhenThereIsNoHeel() {
        let f = BodyFrame(frameIndex: 100, fileTime: 1.0, realTime: 1.0,
                          points2D: [Body2DPoint.leftBigToe: BodyPoint2D(name: Body2DPoint.leftBigToe, u: 940, v: 800, confidence: 0.8)])
        let tl = BodyTimeline(frames: [f], timeScale: 1, imageWidth: 1920, imageHeight: 1080, everyNthFrame: 1,
                              decodedFrames: 1, analysedFrames: 1, wallSeconds: 0, notes: [])
        let contacts = [FootContact(foot: .left, startRealTime: 1.00, endRealTime: 1.30, isTouchdown: true,
                                    precedingFlightFullySeen: true, isTakeoff: true, samples: 8, meanHeightStature: 0.01)]
        let e = FootTriangleFit.strikes(timeline: tl, contacts: contacts, statureImagePixels: 500,
                                        liftRealTime: 1.30, releaseRealTime: 1.45)
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].strike, FootStrike.unknown.rawValue)
        XCTAssertNil(e[0].heelMinusToeStature.value)
        XCTAssertTrue(e[0].unavailableReason!.contains("heel"), e[0].unavailableReason!)
    }

    // MARK: - The name space

    func testTheSixNamesExistAndAreNotPartOfApplesNineteen() {
        XCTAssertEqual(Body2DPoint.footPoints.count, 6)
        for n in Body2DPoint.footPoints {
            XCTAssertTrue(Body2DPoint.isFootPoint(n))
            XCTAssertFalse(Body2DPoint.all.contains(n), "\(n) must not be one of Apple's 19")
        }
    }
}
