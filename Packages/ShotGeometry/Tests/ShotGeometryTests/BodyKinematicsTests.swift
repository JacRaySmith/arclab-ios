import XCTest
import simd
@testable import ShotGeometry

/// Synthetic skeletons with known angles, and the nil-with-a-reason contract.
/// Camera space here is Vision's: +x camera-right, +y up, +z toward the camera. A subject facing
/// the camera therefore has their **left** shoulder at larger x (digest Ch 11 §11.1: left/right are
/// the subject's).
final class BodyKinematicsTests: XCTestCase {

    // MARK: builders

    func j(_ name: String, _ p: SIMD3<Double>) -> BodyJoint3D {
        BodyJoint3D(name: name, position: p, cameraPosition: p)
    }
    func p(_ name: String, _ u: Double, _ v: Double, _ c: Double = 0.9) -> BodyPoint2D {
        BodyPoint2D(name: name, u: u, v: v, confidence: c)
    }
    func frame(_ joints: [BodyJoint3D], points: [BodyPoint2D] = [], hands: [BodyHandFrame] = [],
               t: Double = 0, index: Int = 0) -> BodyFrame {
        BodyFrame(frameIndex: index, fileTime: t * 4, realTime: t,
                  joints3D: Dictionary(uniqueKeysWithValues: joints.map { ($0.name, $0) }),
                  points2D: Dictionary(uniqueKeysWithValues: points.map { ($0.name, $0) }),
                  hands: hands)
    }
    /// Three points whose angle at `b` is exactly `theta`.
    func bend(_ b: SIMD3<Double>, theta: Double, length: Double = 0.3) -> (SIMD3<Double>, SIMD3<Double>) {
        (b + SIMD3(0, length, 0), b + length * SIMD3(sin(theta), cos(theta), 0))
    }
    func deg(_ r: Double?) -> Double { r.map(Angle.degrees) ?? .nan }

    // MARK: 3-D joint angles

    func testStraightArmReadsOneEighty() {
        // Exactly anti-parallel segments: arccos would have to be clipped here (Ch 12 §12.5).
        let f = frame([j(Body3DJoint.rightShoulder, SIMD3(0, 1.4, 0)),
                       j(Body3DJoint.rightElbow, SIMD3(0, 1.1, 0)),
                       j(Body3DJoint.rightWrist, SIMD3(0, 0.8, 0))])
        let a = BodyKinematics.angles(frame: f)
        XCTAssertEqual(deg(a.rightElbow.value), 180.0, accuracy: 1e-9)
        XCTAssertFalse(a.rightElbow.value!.isNaN)
    }

    func testNinetyDegreeElbow() {
        let (shoulder, wrist) = bend(SIMD3(0, 1.1, 0), theta: .pi / 2)
        let f = frame([j(Body3DJoint.leftShoulder, shoulder),
                       j(Body3DJoint.leftElbow, SIMD3(0, 1.1, 0)),
                       j(Body3DJoint.leftWrist, wrist)])
        XCTAssertEqual(deg(BodyKinematics.angles(frame: f).leftElbow.value), 90.0, accuracy: 1e-9)
    }

    func testKneeAngleAtSixtyDegrees() {
        let (hip, ankle) = bend(SIMD3(0, 0.5, 0), theta: Angle.radians(60), length: 0.45)
        let f = frame([j(Body3DJoint.rightHip, hip), j(Body3DJoint.rightKnee, SIMD3(0, 0.5, 0)),
                       j(Body3DJoint.rightAnkle, ankle)])
        XCTAssertEqual(deg(BodyKinematics.angles(frame: f).rightKnee.value), 60.0, accuracy: 1e-9)
    }

    /// Out-of-plane rotation must not change a true 3-D angle — the whole point of the 3-D model
    /// (digest Ch 12 §12.3 shows a true 90° elbow reading 109.5° in 2-D at φ = 45°).
    func testThreeDAngleIsInvariantToTorsoRotation() {
        let theta = Angle.radians(95)
        let (shoulder, wrist) = bend(SIMD3(0, 1.1, 0), theta: theta)
        func rotateY(_ v: SIMD3<Double>, _ phi: Double) -> SIMD3<Double> {
            SIMD3(v.x * cos(phi) + v.z * sin(phi), v.y, -v.x * sin(phi) + v.z * cos(phi))
        }
        for phiDeg in [0.0, 20.0, 45.0, 80.0] {
            let phi = Angle.radians(phiDeg)
            let f = frame([j(Body3DJoint.leftShoulder, rotateY(shoulder, phi)),
                           j(Body3DJoint.leftElbow, rotateY(SIMD3(0, 1.1, 0), phi)),
                           j(Body3DJoint.leftWrist, rotateY(wrist, phi))])
            XCTAssertEqual(deg(BodyKinematics.angles(frame: f).leftElbow.value), 95.0, accuracy: 1e-9,
                           "3-D elbow changed at φ = \(phiDeg)°")
        }
    }

    func testShoulderElevationIsZeroWithTheArmAtTheSide() {
        // Arm hanging straight down alongside an upright trunk.
        let joints = [j(Body3DJoint.leftShoulder, SIMD3(0.2, 1.4, 0)), j(Body3DJoint.rightShoulder, SIMD3(-0.2, 1.4, 0)),
                      j(Body3DJoint.leftHip, SIMD3(0.15, 0.95, 0)), j(Body3DJoint.rightHip, SIMD3(-0.15, 0.95, 0)),
                      j(Body3DJoint.rightElbow, SIMD3(-0.2, 1.1, 0))]
        let a = BodyKinematics.angles(frame: frame(joints))
        XCTAssertEqual(deg(a.rightShoulderElevation.value), 0.0, accuracy: 1e-6)
        XCTAssertEqual(deg(a.rightShoulderAbduction.value), 0.0, accuracy: 1e-6)
    }

    func testShoulderAbductionAtSixtyDegreesInTheFrontalPlane() {
        // Arm lifted 60° from the trunk's down direction, purely sideways (frontal plane).
        let s = SIMD3<Double>(-0.2, 1.4, 0)
        let elbow = s + 0.3 * SIMD3<Double>(-sin(Angle.radians(60)), -cos(Angle.radians(60)), 0)
        let joints = [j(Body3DJoint.leftShoulder, SIMD3(0.2, 1.4, 0)), j(Body3DJoint.rightShoulder, s),
                      j(Body3DJoint.leftHip, SIMD3(0.15, 0.95, 0)), j(Body3DJoint.rightHip, SIMD3(-0.15, 0.95, 0)),
                      j(Body3DJoint.rightElbow, elbow)]
        let a = BodyKinematics.angles(frame: frame(joints))
        XCTAssertEqual(deg(a.rightShoulderElevation.value), 60.0, accuracy: 1e-6)
        XCTAssertEqual(deg(a.rightShoulderAbduction.value), 60.0, accuracy: 1e-6)
    }

    // MARK: nil carries a reason

    func testMissingJointsGiveNilWithAReasonNamingTheJoint() {
        let f = frame([j(Body3DJoint.rightShoulder, SIMD3(0, 1.4, 0))])   // no elbow, no wrist
        let a = BodyKinematics.angles(frame: f)
        XCTAssertNil(a.rightElbow.value)
        let why = try! XCTUnwrap(a.rightElbow.unavailableReason)
        XCTAssertTrue(why.contains(Body3DJoint.rightElbow), "the reason must name the missing joint, got: \(why)")
    }

    func testAnkleAngleIsAlwaysNilBecauseVisionHasNoToe() {
        let f = frame([j(Body3DJoint.rightKnee, SIMD3(0, 0.5, 0)), j(Body3DJoint.rightAnkle, SIMD3(0, 0.1, 0))])
        let a = BodyKinematics.angles(frame: f)
        XCTAssertNil(a.rightAnkle.value)
        XCTAssertEqual(a.rightAnkle.unavailableReason, "no toe landmark in the Vision body model")
        XCTAssertNil(a.leftAnkle.value)
        XCTAssertEqual(a.leftAnkle.unavailableReason, "no toe landmark in the Vision body model")
    }

    func testStaggerFromToesIsNilWithTheVisionReason() {
        let f = frame(standing())
        let (s, _) = BodyKinematics.stance(frames: [f], dipTime: nil, setTime: nil, releaseTime: 0)
        XCTAssertEqual(s.feetStaggerFromToes.unavailableReason, "no toe landmark in the Vision body model")
    }

    func testDegreesOnlyForAngularUnits() {
        XCTAssertEqual(BodyMeasure.ok(.pi, .radians).degrees!, 180, accuracy: 1e-12)
        XCTAssertNil(BodyMeasure.ok(1.5, .metres).degrees)
        XCTAssertNil(BodyMeasure.ok(1.5, .pixels).degrees)
    }

    // MARK: stance

    /// A neutral standing skeleton facing the camera: left side at larger x.
    func standing(yaw: Double = 0, lean: Double = 0, stagger: Double = 0) -> [BodyJoint3D] {
        func rotateY(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(v.x * cos(yaw) + v.z * sin(yaw), v.y, -v.x * sin(yaw) + v.z * cos(yaw))
        }
        let hipY = 0.95, trunk = 0.45
        let shoulderCentre = SIMD3<Double>(0, hipY + trunk * cos(lean), trunk * sin(lean))
        return [j(Body3DJoint.leftShoulder, rotateY(shoulderCentre + SIMD3(0.2, 0, 0))),
                j(Body3DJoint.rightShoulder, rotateY(shoulderCentre + SIMD3(-0.2, 0, 0))),
                j(Body3DJoint.leftHip, rotateY(SIMD3(0.15, hipY, 0))),
                j(Body3DJoint.rightHip, rotateY(SIMD3(-0.15, hipY, 0))),
                j(Body3DJoint.leftAnkle, rotateY(SIMD3(0.10, 0, 0))),
                j(Body3DJoint.rightAnkle, rotateY(SIMD3(-0.10, 0, stagger))),
                j(Body3DJoint.root, rotateY(SIMD3(0, hipY, 0)))]
    }

    func testShoulderYawIsZeroSquareToCameraAndThirtyWhenRotated() {
        let square = BodyKinematics.stance(frames: [frame(standing())], dipTime: nil, setTime: nil, releaseTime: 0).0
        XCTAssertEqual(deg(square.shoulderLineYaw.value), 0.0, accuracy: 1e-9)
        XCTAssertEqual(deg(square.hipLineYaw.value), 0.0, accuracy: 1e-9)
        let turned = BodyKinematics.stance(frames: [frame(standing(yaw: Angle.radians(30)))], dipTime: nil, setTime: nil, releaseTime: 0).0
        XCTAssertEqual(abs(deg(turned.shoulderLineYaw.value)), 30.0, accuracy: 1e-9)
        let sideOn = BodyKinematics.stance(frames: [frame(standing(yaw: Angle.radians(85)))], dipTime: nil, setTime: nil, releaseTime: 0).0
        XCTAssertEqual(abs(deg(sideOn.shoulderLineYaw.value)), 85.0, accuracy: 1e-9)
    }

    func testTorsoLeanFifteenDegreesForward() {
        let s = BodyKinematics.stance(frames: [frame(standing(lean: Angle.radians(15)))], dipTime: nil, setTime: nil, releaseTime: 0).0
        // +z is toward the camera and a subject facing the camera leans toward it: positive sagittal lean.
        XCTAssertEqual(deg(s.torsoLeanSagittal.value), 15.0, accuracy: 1e-9)
        XCTAssertEqual(deg(s.torsoLeanFrontal.value), 0.0, accuracy: 1e-9)
    }

    func testFeetSeparationAndStaggerSign() {
        let s = BodyKinematics.stance(frames: [frame(standing(stagger: 0.15))], dipTime: nil, setTime: nil, releaseTime: 0).0
        XCTAssertEqual(s.feetSeparation.value!, (0.2 * 0.2 + 0.15 * 0.15).squareRoot(), accuracy: 1e-9)
        // The right foot was moved toward the camera, which is the way a camera-facing subject faces:
        // stagger is positive when the subject's right foot is in front.
        XCTAssertEqual(s.feetStagger.value!, 0.15, accuracy: 1e-9)
        let mirrored = BodyKinematics.stance(frames: [frame(standing(stagger: -0.15))], dipTime: nil, setTime: nil, releaseTime: 0).0
        XCTAssertEqual(mirrored.feetStagger.value!, -0.15, accuracy: 1e-9)
    }

    func testJumpHeightMeasuresHipRiseAboveTheReference() {
        var frames: [BodyFrame] = []
        for (i, rise) in [0.0, 0.05, 0.22, 0.10].enumerated() {
            let lifted = standing().map { BodyJoint3D(name: $0.name, position: $0.position,
                                                      cameraPosition: $0.cameraPosition + SIMD3(0, rise, 0)) }
            frames.append(frame(lifted, t: Double(i) * 0.1, index: i))
        }
        let s = BodyKinematics.stance(frames: frames, dipTime: 0.0, setTime: 0.0, releaseTime: 0.2).0
        XCTAssertEqual(s.jumpHeight.value!, 0.22, accuracy: 1e-9)
    }

    func testHipDriftIsSignedTowardCameraRight() {
        let a = frame(standing(), t: 0, index: 0)
        let moved = standing().map { BodyJoint3D(name: $0.name, position: $0.position,
                                                 cameraPosition: $0.cameraPosition + SIMD3(0.08, 0, -0.03)) }
        let b = frame(moved, t: 0.5, index: 1)
        let s = BodyKinematics.stance(frames: [a, b], dipTime: 0, setTime: nil, releaseTime: 0.5).0
        XCTAssertEqual(s.hipDriftLateral.value!, 0.08, accuracy: 1e-9)
        XCTAssertEqual(s.hipDriftDepth.value!, -0.03, accuracy: 1e-9)
        XCTAssertEqual(s.hipDriftMagnitude.value!, (0.08 * 0.08 + 0.03 * 0.03).squareRoot(), accuracy: 1e-9)
    }

    func testStanceIsNilWithAReasonWhenThereIsNoThreeDBody() {
        let empty = BodyFrame(frameIndex: 0, fileTime: 0, realTime: 0)
        let (s, warnings) = BodyKinematics.stance(frames: [empty], dipTime: nil, setTime: nil, releaseTime: 0)
        XCTAssertNil(s.feetSeparation.value)
        XCTAssertEqual(s.feetSeparation.unavailableReason, "no frame in this window carried a 3-D body")
        XCTAssertEqual(warnings.count, 1)
    }

    // MARK: head

    func testHeadYawFromEarsAndNose() {
        func headFrame(yawDeg: Double, radius: Double = 40) -> BodyFrame {
            let psi = Angle.radians(yawDeg), c = 640.0
            return frame([], points: [p(Body2DPoint.leftEar, c + radius * cos(psi), 300),
                                      p(Body2DPoint.rightEar, c - radius * cos(psi), 300),
                                      p(Body2DPoint.nose, c + radius * sin(psi), 300)])
        }
        for yawDeg in [0.0, 15.0, -25.0, 55.0] {
            let h = BodyKinematics.head(frames: [headFrame(yawDeg: yawDeg)], dipTime: nil, releaseTime: 0, rimImageU: nil)
            XCTAssertEqual(deg(h.yaw.value), yawDeg, accuracy: 1e-9, "head yaw wrong at \(yawDeg)°")
        }
    }

    func testHeadPitchIsPositiveWhenTheNoseIsAboveTheEarLine() {
        let c = 640.0
        let f = frame([], points: [p(Body2DPoint.leftEar, c + 40, 300), p(Body2DPoint.rightEar, c - 40, 300),
                                   p(Body2DPoint.nose, c, 280)])   // v grows downwards: nose 20 px higher
        let h = BodyKinematics.head(frames: [f], dipTime: nil, releaseTime: 0, rimImageU: nil)
        XCTAssertEqual(deg(h.pitchRelative.value), Angle.degrees(asin(20.0 / 40.0)), accuracy: 1e-9)
    }

    func testHeadYawNeedsBothEarsAndSaysSoOnASideView() {
        let f = frame([], points: [p(Body2DPoint.nose, 700, 300), p(Body2DPoint.leftEar, 660, 300, 0.05)])
        let h = BodyKinematics.head(frames: [f], dipTime: nil, releaseTime: 0, rimImageU: nil)
        XCTAssertNil(h.yaw.value)
        XCTAssertTrue(h.yaw.unavailableReason!.contains("both"))
    }

    func testFacesRimUsesTheNoseOffsetSign() {
        let c = 640.0
        let f = frame([], points: [p(Body2DPoint.leftEar, c + 40, 300), p(Body2DPoint.rightEar, c - 40, 300),
                                   p(Body2DPoint.nose, c + 25, 300)])
        XCTAssertEqual(BodyKinematics.head(frames: [f], dipTime: nil, releaseTime: 0, rimImageU: 1500).facesRimDirection, true)
        XCTAssertEqual(BodyKinematics.head(frames: [f], dipTime: nil, releaseTime: 0, rimImageU: 100).facesRimDirection, false)
        // Inside the jitter: refuse rather than guess.
        let ambiguous = frame([], points: [p(Body2DPoint.leftEar, c + 40, 300), p(Body2DPoint.rightEar, c - 40, 300),
                                           p(Body2DPoint.nose, c + 1, 300)])
        let h = BodyKinematics.head(frames: [ambiguous], dipTime: nil, releaseTime: 0, rimImageU: 1500)
        XCTAssertNil(h.facesRimDirection)
        XCTAssertTrue(h.facesRimUnavailableReason!.contains("jitter"))
    }

    // MARK: phases

    func syntheticHeight(_ t: Double) -> Double {
        switch t {
        case ..<0.2: return 1.0
        case ..<0.4: return 1.0 - 2.0 * (t - 0.2)
        case ..<0.75: return 0.6 + (t - 0.4) * (1.2 / 0.35)
        default: return 1.8 - (t - 0.75) * 3.0
        }
    }

    func testPhasesFindTheDipSetPointAndFollowThrough() {
        let times = stride(from: 0.0, through: 1.0, by: 0.02).map { $0 }
        let height = times.map(syntheticHeight)
        let ph = BodyKinematics.phases(times: times, height: height, releaseRealTime: 0.6, signalSource: "synthetic")
        XCTAssertEqual(ph.dip.value!, 0.4, accuracy: 0.021)
        XCTAssertEqual(ph.dipToReleaseMilliseconds.value!, 200, accuracy: 25)
        let setPoint = try! XCTUnwrap(ph.setPoint.value)
        XCTAssertLessThan(setPoint, ph.dip.value!)
        XCTAssertGreaterThan(setPoint, 0.05)
        let follow = try! XCTUnwrap(ph.followThroughEnd.value)
        XCTAssertGreaterThan(follow, 0.75)
        XCTAssertLessThan(follow, 0.90)
        XCTAssertLessThan(ph.setPoint.value!, ph.dip.value!)
        XCTAssertLessThan(ph.dip.value!, ph.release.value!)
        XCTAssertLessThan(ph.release.value!, follow)
    }

    func testPhasesRefuseAShortSignal() {
        let ph = BodyKinematics.phases(times: [0, 0.1], height: [1, 2], releaseRealTime: 0.05, signalSource: "synthetic")
        XCTAssertNil(ph.dip.value)
        XCTAssertTrue(ph.dip.unavailableReason!.contains("at least 5"))
        XCTAssertEqual(ph.release.value!, 0.05)     // the caller's release is never discarded
    }

    // MARK: kinetic chain

    func angleRow(_ t: Double, knee: Double, hip: Double, shoulder: Double, elbow: Double, wrist: Double) -> JointAngles3D {
        let n = BodyMeasure.missing(.radians, "not part of this synthetic row")
        return JointAngles3D(realTime: t,
                             leftElbow: n, rightElbow: .ok(elbow, .radians),
                             leftKnee: n, rightKnee: .ok(knee, .radians),
                             leftHip: n, rightHip: .ok(hip, .radians),
                             leftShoulderElevation: n, rightShoulderElevation: .ok(shoulder, .radians),
                             leftShoulderAbduction: n, rightShoulderAbduction: n,
                             leftAnkle: n, rightAnkle: n,
                             shootingWristFlexion: .ok(wrist, .radians))
    }

    /// Each joint's angle is a logistic ramp; its peak rate is at the ramp's centre. Centres are set
    /// 40 ms apart in proximal-to-distal order, so the recovered order and lags are known exactly.
    func testKineticChainRecoversOrderAndLags() {
        func ramp(_ t: Double, centre: Double) -> Double { 1.0 / (1.0 + exp(-(t - centre) / 0.012)) }
        var rows: [JointAngles3D] = []
        for k in 0...60 {
            let t = Double(k) * 0.005
            rows.append(angleRow(t, knee: ramp(t, centre: 0.05), hip: ramp(t, centre: 0.09),
                                 shoulder: ramp(t, centre: 0.13), elbow: ramp(t, centre: 0.17),
                                 wrist: ramp(t, centre: 0.21)))
        }
        let chain = BodyKinematics.kineticChain(angles: rows, from: 0, to: 0.30, side: "right")
        XCTAssertNil(chain.unavailableReason)
        XCTAssertEqual(chain.order, ["knee", "hip", "shoulder", "elbow", "wrist"])
        XCTAssertEqual(chain.proximalToDistal, true)
        XCTAssertEqual(chain.lagsMilliseconds.count, 4)
        for lag in chain.lagsMilliseconds { XCTAssertEqual(lag, 40, accuracy: 6) }
        XCTAssertEqual(chain.events.first!.realTime, 0.05, accuracy: 0.006)
    }

    func testKineticChainFlagsAnOutOfOrderSequence() {
        func ramp(_ t: Double, centre: Double) -> Double { 1.0 / (1.0 + exp(-(t - centre) / 0.012)) }
        var rows: [JointAngles3D] = []
        for k in 0...60 {
            let t = Double(k) * 0.005
            // elbow fires before the shoulder: the chain is broken.
            rows.append(angleRow(t, knee: ramp(t, centre: 0.05), hip: ramp(t, centre: 0.09),
                                 shoulder: ramp(t, centre: 0.17), elbow: ramp(t, centre: 0.13),
                                 wrist: ramp(t, centre: 0.21)))
        }
        let chain = BodyKinematics.kineticChain(angles: rows, from: 0, to: 0.30, side: "right")
        XCTAssertEqual(chain.order, ["knee", "hip", "elbow", "shoulder", "wrist"])
        XCTAssertEqual(chain.proximalToDistal, false)
    }

    func testKineticChainReportsWhichJointsWereMissing() {
        var rows: [JointAngles3D] = []
        for k in 0...40 {
            let t = Double(k) * 0.005
            var r = angleRow(t, knee: Double(k) * 0.01, hip: 0.5, shoulder: 0.5, elbow: 0.5, wrist: 0.5)
            r.rightHip = .missing(.radians, "no 3-D rightHip on this frame")
            rows.append(r)
        }
        let chain = BodyKinematics.kineticChain(angles: rows, from: 0, to: 0.30, side: "right")
        XCTAssertNotNil(chain.missing["hip"])
        XCTAssertFalse(chain.order.contains("hip"))
    }

    func testKineticChainRefusesTooFewFrames() {
        let rows = (0..<3).map { angleRow(Double($0) * 0.01, knee: 0.1, hip: 0.1, shoulder: 0.1, elbow: 0.1, wrist: 0.1) }
        let chain = BodyKinematics.kineticChain(angles: rows, from: 0, to: 1, side: "right")
        XCTAssertNotNil(chain.unavailableReason)
        XCTAssertTrue(chain.events.isEmpty)
    }

    // MARK: hands

    func hand(_ chirality: String, role: String, wrist: SIMD2<Double>, mcp: SIMD2<Double>,
              tips: [String: SIMD2<Double>] = [:]) -> BodyHandFrame {
        var l: [String: BodyPoint2D] = [
            HandLandmark.wrist: p(HandLandmark.wrist, wrist.x, wrist.y),
            HandLandmark.middleMCP: p(HandLandmark.middleMCP, mcp.x, mcp.y)]
        for (k, v) in tips { l[k] = p(k, v.x, v.y) }
        return BodyHandFrame(chirality: chirality, role: role, confidence: 0.9, landmarks: l)
    }

    func testLastFingertipsOnTheBall() {
        var frames: [BodyFrame] = []
        var ball: [BodyBallSample] = []
        for k in 0...10 {
            let t = Double(k) * 0.01
            // The ball moves away along +u; the index tip stays with it one frame longer than the little tip.
            let ballU = 500.0 + Double(k) * 12
            ball.append(BodyBallSample(t: t, u: ballU, v: 300, diameterPx: 40))
            let index = SIMD2(ballU - Double(k) * 2, 300.0)          // stays inside the radius longest
            let little = SIMD2(500.0 - Double(k) * 4, 300.0)         // falls behind immediately
            frames.append(frame([], hands: [hand("right", role: "shooting", wrist: SIMD2(480, 320), mcp: SIMD2(495, 305),
                                                 tips: [HandLandmark.indexTip: index, HandLandmark.littleTip: little])],
                                t: t, index: k))
        }
        let h = BodyKinematics.hands(frames: frames, ballTrack: ball, releaseTime: 0.10, shootingSide: "right")
        XCTAssertEqual(h.lastFingertipsOnBall, [HandLandmark.indexTip])
        XCTAssertNil(h.fingertipsUnavailableReason)
    }

    func testFingertipsNeedABallTrack() {
        let f = frame([], hands: [hand("right", role: "shooting", wrist: SIMD2(480, 320), mcp: SIMD2(495, 305))])
        let h = BodyKinematics.hands(frames: [f], ballTrack: [], releaseTime: 0, shootingSide: "right")
        XCTAssertTrue(h.fingertipsUnavailableReason!.contains("no ball track"))
        XCTAssertTrue(h.lastFingertipsOnBall.isEmpty)
    }

    func testWristSnapRateIsTheHandDirectionRate() {
        // The hand rotates at a known 6 rad/s in the image plane.
        var frames: [BodyFrame] = []
        for k in 0...20 {
            let t = Double(k) * 0.01
            let a = 6.0 * t
            let mcp = SIMD2(480 + 30 * cos(a), 320 - 30 * sin(a))   // v grows downwards
            frames.append(frame([], hands: [hand("right", role: "shooting", wrist: SIMD2(480, 320), mcp: mcp)], t: t, index: k))
        }
        let h = BodyKinematics.hands(frames: frames, ballTrack: [], releaseTime: 0.10, shootingSide: "right")
        XCTAssertEqual(h.wristSnapRate.value!, 6.0, accuracy: 0.05)
        XCTAssertEqual(h.wristSnapRate.unit, .radiansPerSecond)
    }

    func testNoHandsGivesAReason() {
        let h = BodyKinematics.hands(frames: [frame([])], ballTrack: [], releaseTime: 0, shootingSide: "right")
        XCTAssertEqual(h.fingertipsUnavailableReason, "Vision detected no hands anywhere in this window")
        XCTAssertNil(h.wristSnapRate.value)
    }

    // MARK: summaries

    func testSummaryReportsMeanSdAndN() {
        let values: [BodyMeasure] = [.ok(Angle.radians(160), .radians), .ok(Angle.radians(164), .radians),
                                     .missing(.radians, "no 3-D rightElbow on this frame (right elbow)"),
                                     .ok(Angle.radians(168), .radians)]
        let s = BodySummaries.summarise("elbowAtRelease", values)
        XCTAssertEqual(s.n, 3)
        XCTAssertEqual(s.nMissing, 1)
        XCTAssertEqual(Angle.degrees(s.mean.value!), 164, accuracy: 1e-9)
        XCTAssertEqual(Angle.degrees(s.sd.value!), 4.0, accuracy: 1e-9)
        XCTAssertEqual(s.missingReasons.count, 1)
    }

    func testSummaryRefusesAnSdFromOneShot() {
        let s = BodySummaries.summarise("jumpHeight", [.ok(0.12, .metres), .missing(.metres, "no 3-D mid-hip")])
        XCTAssertEqual(s.n, 1)
        XCTAssertNil(s.sd.value)
        XCTAssertTrue(s.sd.unavailableReason!.contains("n = 1"))
    }

    func testSummaryOfNothingIsNilWithAReason() {
        let s = BodySummaries.summarise("headYaw", [.missing(.radians, "head yaw needs both ears")])
        XCTAssertEqual(s.n, 0)
        XCTAssertNil(s.mean.value)
        XCTAssertNotNil(s.mean.unavailableReason)
    }

    // MARK: whole model

    func testModelRunsEndToEndAndReportsScaleProvenance() {
        var frames: [BodyFrame] = []
        for k in 0...40 {
            let t = Double(k) * 0.01
            let rise = 0.3 * sin(Double(k) * 0.08)
            var joints = standing()
            joints.append(j(Body3DJoint.rightElbow, SIMD3(-0.25, 1.15 + rise, 0.05)))
            joints.append(j(Body3DJoint.rightWrist, SIMD3(-0.25, 1.35 + rise, 0.10)))
            joints.append(j(Body3DJoint.rightKnee, SIMD3(-0.15, 0.50, 0)))
            var f = frame(joints, points: [p(Body2DPoint.rightWrist, 700, 400 - rise * 100),
                                           p(Body2DPoint.nose, 660, 250)],
                          t: t, index: k)
            f.heightEstimationTechnique = "reference"
            f.bodyHeightMetres = 1.80
            frames.append(f)
        }
        let timeline = BodyTimeline(frames: frames, timeScale: 4, imageWidth: 1920, imageHeight: 1080,
                                    everyNthFrame: 1, decodedFrames: 41, analysedFrames: 41, wallSeconds: 2, notes: [])
        let m = BodyKinematics.model(timeline: timeline, releaseRealTime: 0.30, options: BodyKinematicsOptions(shootingSide: "right"))
        XCTAssertEqual(m.framesWith3D, 41)
        XCTAssertEqual(m.scaleIsMeasured, false)
        XCTAssertTrue(m.warnings.contains { $0.contains("reference") })
        XCTAssertNotNil(m.anglesAtRelease)
        XCTAssertEqual(timeline.framesPerSecondAchieved, 20.5, accuracy: 1e-9)
    }
}

/// Refusals that the real footage forced: a 3-D skeleton whose pelvis is a rigid prior and whose
/// camera-relative translation teleports between frames must not yield metres or a hip yaw.
extension BodyKinematicsTests {

    func testHipYawIsRefusedWhenTheHipLineIsARigidSegment() {
        // Vision's 3-D model holds the two hips on a fixed segment: on IMG_1765 the hip vector is
        // (-0.3130, 0, 5e-6) m on every single frame while the shoulders move.
        var frames: [BodyFrame] = []
        for k in 0...9 {
            var joints = standing()
            joints.removeAll { $0.name == Body3DJoint.leftHip || $0.name == Body3DJoint.rightHip
                               || $0.name == Body3DJoint.leftShoulder || $0.name == Body3DJoint.rightShoulder }
            joints.append(j(Body3DJoint.leftHip, SIMD3(0.1565, 0.95, 0)))
            joints.append(j(Body3DJoint.rightHip, SIMD3(-0.1565, 0.95, 5e-6)))
            let wobble = Double(k) * 0.004
            joints.append(j(Body3DJoint.leftShoulder, SIMD3(0.2, 1.40, wobble)))
            joints.append(j(Body3DJoint.rightShoulder, SIMD3(-0.2, 1.40, -wobble)))
            frames.append(frame(joints, t: Double(k) / 120.0, index: k))
        }
        let (s, warnings) = BodyKinematics.stance(frames: frames, dipTime: nil, setTime: nil, releaseTime: 0)
        XCTAssertNil(s.hipLineYaw.value)
        XCTAssertTrue(s.hipLineYaw.unavailableReason!.contains("rigid segment"))
        XCTAssertTrue(warnings.contains { $0.contains("hip line") })
        XCTAssertNotNil(s.shoulderLineYaw.value)   // the shoulders do move, so they are still measured
    }

    func testMetresAreRefusedWhenTheMidHipTeleports() {
        var frames: [BodyFrame] = []
        for k in 0...15 {
            let shift = SIMD3<Double>(Double(k % 2) * 2.0, 0, 0)     // 2 m of jitter per frame
            let joints = standing().map { BodyJoint3D(name: $0.name, position: $0.position, cameraPosition: $0.cameraPosition + shift) }
            frames.append(frame(joints, t: Double(k) / 120.0, index: k))
        }
        let (s, warnings) = BodyKinematics.stance(frames: frames, dipTime: 0, setTime: 0, releaseTime: 15 / 120.0)
        XCTAssertNil(s.jumpHeight.value)
        XCTAssertNil(s.hipDriftLateral.value)
        XCTAssertNil(s.feetSeparation.value)
        XCTAssertTrue(s.jumpHeight.unavailableReason!.contains("m/s"))
        XCTAssertTrue(warnings.contains { $0.contains("not tracking the body") })
    }
}

/// Iteration 3 (2026-09-15): the neck/trunk attitude and the per-joint coverage table.
final class BodyPostureAndCoverageTests: XCTestCase {

    /// A 2-D body whose trunk leans `leanDegrees` from vertical in the image plane, with a neck, both
    /// hips, both shoulders and a full set of head cues. `farSide` off deletes every left-side point,
    /// which is what a true side-on view gives.
    func timeline(leanDegrees: Double, n: Int = 40, jitterPx: Double = 0, farSide: Bool = true,
                  ankleAtFrameBottom: Bool = false, headTiltDegrees: Double = 0) -> BodyTimeline {
        var rng = SeededRNG(seed: 4)
        var frames: [BodyFrame] = []
        let lean = Angle.radians(leanDegrees), tilt = Angle.radians(headTiltDegrees)
        for k in 0..<n {
            let hip = SIMD2<Double>(900, 700)
            // v grows downward, so "up" is −v; a positive lean puts the neck to camera-right.
            let up = SIMD2(sin(lean), -cos(lean))
            let neck = hip + up * 260
            let head = neck + SIMD2(sin(lean + tilt), -cos(lean + tilt)) * 90
            var pts: [String: BodyPoint2D] = [:]
            func put(_ name: String, _ p: SIMD2<Double>, _ c: Double = 0.9) {
                pts[name] = BodyPoint2D(name: name, u: p.x + (jitterPx > 0 ? rng.gaussian(sd: jitterPx) : 0),
                                        v: p.y + (jitterPx > 0 ? rng.gaussian(sd: jitterPx) : 0), confidence: c)
            }
            put(Body2DPoint.neck, neck)
            put(Body2DPoint.nose, head + SIMD2(12, 6))
            put(Body2DPoint.leftEar, head + SIMD2(-8, 0))
            put(Body2DPoint.rightEar, head + SIMD2(8, 0))
            put(Body2DPoint.rightShoulder, neck + SIMD2(22, 12))
            put(Body2DPoint.rightHip, hip + SIMD2(10, 0))
            put(Body2DPoint.rightKnee, hip + SIMD2(12, 180))
            put(Body2DPoint.rightAnkle, ankleAtFrameBottom ? SIMD2(912, 1079) : hip + SIMD2(10, 340))
            if farSide {
                put(Body2DPoint.leftShoulder, neck + SIMD2(-22, 12), 0.5)
                put(Body2DPoint.leftHip, hip + SIMD2(-10, 0), 0.5)
            }
            frames.append(BodyFrame(frameIndex: k, fileTime: Double(k) / 240, realTime: Double(k) / 240,
                                    joints3D: [:], points2D: pts, hands: []))
        }
        return BodyTimeline(frames: frames, timeScale: 1, imageWidth: 1920, imageHeight: 1080,
                            everyNthFrame: 1, decodedFrames: n, analysedFrames: n, wallSeconds: 1, notes: [])
    }

    func testTrunkToVerticalRecoversAKnownLean() {
        for truth in [-12.0, 0.0, 9.0] {
            let m = BodyKinematics.model(timeline: timeline(leanDegrees: truth),
                                         releaseRealTime: 20.0 / 240,
                                         options: BodyKinematicsOptions(shootingSide: "right"))
            XCTAssertEqual(m.posture.trunkToVerticalAtRelease.degrees!, truth, accuracy: 0.6,
                           "lean \(truth)° came back as \(m.posture.trunkToVerticalAtRelease.describe())")
        }
    }

    func testHeadToTrunkRecoversAKnownTilt() {
        let m = BodyKinematics.model(timeline: timeline(leanDegrees: 5, headTiltDegrees: 14),
                                     releaseRealTime: 20.0 / 240,
                                     options: BodyKinematicsOptions(shootingSide: "right"))
        // The head point is the mid-ear, which sits exactly on the tilt axis in this synthetic.
        XCTAssertEqual(m.posture.headToTrunkAtRelease.degrees!, 14, accuracy: 1.0)
        XCTAssertEqual(m.posture.headSource, "mid-ear")
        XCTAssertEqual(m.posture.neckSource, "neck")
    }

    func testPostureJitterIsTheMeasuresOwnPrecision() {
        let clean = BodyKinematics.model(timeline: timeline(leanDegrees: 5, jitterPx: 0),
                                         releaseRealTime: 20.0 / 240, options: BodyKinematicsOptions())
        let noisy = BodyKinematics.model(timeline: timeline(leanDegrees: 5, jitterPx: 2),
                                         releaseRealTime: 20.0 / 240, options: BodyKinematicsOptions())
        XCTAssertLessThan(clean.posture.trunkToVerticalJitter.degrees!, 0.01)
        XCTAssertGreaterThan(noisy.posture.trunkToVerticalJitter.degrees!, 0.1)
    }

    func testPostureRefusesWithAReasonWhenThereIsNoTrunk() {
        let empty = BodyTimeline(frames: (0..<8).map { BodyFrame(frameIndex: $0, fileTime: Double($0) / 240,
                                                                 realTime: Double($0) / 240) },
                                 timeScale: 1, imageWidth: 1920, imageHeight: 1080, everyNthFrame: 1,
                                 decodedFrames: 8, analysedFrames: 8, wallSeconds: 1, notes: [])
        let m = BodyKinematics.model(timeline: empty, releaseRealTime: 0.01, options: BodyKinematicsOptions())
        XCTAssertNil(m.posture.trunkToVerticalAtRelease.value)
        XCTAssertTrue(m.posture.trunkToVerticalAtRelease.unavailableReason!.contains("neck"))
    }

    func testCoverageCountsEveryJointAndFlagsTheUnseenFarSide() {
        let m = BodyKinematics.model(timeline: timeline(leanDegrees: 0, farSide: false),
                                     releaseRealTime: 20.0 / 240, options: BodyKinematicsOptions())
        let by = Dictionary(uniqueKeysWithValues: m.coverage.map { ($0.name, $0) })
        XCTAssertEqual(by[Body2DPoint.neck]?.seenFraction, 1.0)
        XCTAssertEqual(by[Body2DPoint.rightAnkle]?.seenFraction, 1.0)
        XCTAssertEqual(by[Body2DPoint.leftShoulder]?.framesSeen, 0)
        XCTAssertTrue(by[Body2DPoint.leftShoulder]!.symmetryInferred,
                      "an unseen joint whose mirror partner is seen must be flagged, not silently filled in")
        XCTAssertFalse(by[Body2DPoint.rightShoulder]!.symmetryInferred)
        // A joint whose mirror partner is *also* unseen is not symmetry-inferred: there is nothing to
        // infer it from, and the row says the detector never returned it.
        XCTAssertFalse(by[Body2DPoint.leftEye]!.symmetryInferred)
        XCTAssertEqual(by[Body2DPoint.leftEye]?.note, "the detector never returned this point in this window")
    }

    func testCoverageFlagsAClippedAnkleAndTheModelWarns() {
        let m = BodyKinematics.model(timeline: timeline(leanDegrees: 0, ankleAtFrameBottom: true),
                                     releaseRealTime: 20.0 / 240, options: BodyKinematicsOptions())
        let ankle = m.coverage.first { $0.name == Body2DPoint.rightAnkle }!
        XCTAssertEqual(ankle.clippedFraction, 1.0)
        XCTAssertTrue(m.warnings.contains { $0.contains("rightAnkle") && $0.contains("clipped") },
                      "warnings were: \(m.warnings)")
    }

    func testCoverageJitterTracksTheInputNoise() {
        let m = BodyKinematics.model(timeline: timeline(leanDegrees: 0, jitterPx: 2),
                                     releaseRealTime: 20.0 / 240, options: BodyKinematicsOptions())
        let nose = m.coverage.first { $0.name == Body2DPoint.nose }!
        XCTAssertEqual(nose.jitterPixels.value!, 2.0, accuracy: 0.6)
    }

    func testHandCoverageIsReportedByChirality() {
        var tl = timeline(leanDegrees: 0)
        for i in tl.frames.indices where i % 2 == 0 {
            tl.frames[i].hands = [BodyHandFrame(chirality: "right", role: "shooting", confidence: 0.8,
                                                landmarks: [HandLandmark.middleMCP:
                                                    BodyPoint2D(name: HandLandmark.middleMCP, u: 950, v: 430, confidence: 0.8)])]
        }
        let m = BodyKinematics.model(timeline: tl, releaseRealTime: 20.0 / 240, options: BodyKinematicsOptions())
        let hand = m.coverage.first { $0.name == "rightHand" }
        XCTAssertNotNil(hand)
        XCTAssertEqual(hand!.seenFraction, 0.5, accuracy: 1e-9)
        XCTAssertNil(m.coverage.first { $0.name == "leftHand" })
    }
}

/// Iteration 3 (2026-09-15): the phase definitions, after the 240 fps free throws showed the old
/// ones producing a set point one frame before the dip and a 14 ms follow-through.
final class ShotPhaseDefinitionTests: XCTestCase {

    /// The jump-shot shape the original rule was written for: still at 1.0 m to t = 0.2, dip to
    /// 0.6 m at t = 0.4, drive up, release at 0.6, apex at 0.75, then down.
    func jumpShot(_ t: Double) -> Double {
        switch t {
        case ..<0.2: return 1.0
        case ..<0.4: return 1.0 - 2.0 * (t - 0.2)
        case ..<0.75: return 0.6 + (t - 0.4) * (1.2 / 0.35)
        default: return 1.8 - (t - 0.75) * 3.0
        }
    }

    /// This shooter's free throw, as measured on the 240 fps clip: the hand rises from the waist,
    /// **holds still for half a second** at the set position, drives up, and the release *is* the
    /// highest point — the wrist never rises after the ball leaves, it falls.
    func freeThrow(_ t: Double) -> Double {
        switch t {
        case ..<0.80: return -1.07 + 0.80 * t              // waist → set
        case ..<1.31: return -0.43 + 0.004 * sin(40 * t)   // the set plateau, with a 4 mm wobble
        case ..<1.50: return -0.43 + (t - 1.31) * (0.38 / 0.19)   // the drive
        default: return -0.05 - (t - 1.50) * 0.5           // after release the wrist falls
        }
    }

    func series(_ f: (Double) -> Double, dt: Double = 1.0 / 120, to: Double) -> ([Double], [Double]) {
        let times = stride(from: 0.0, through: to, by: dt).map { $0 }
        return (times, times.map(f))
    }

    // MARK: the bug the 240 fps clip exposed

    func testSetPointIsThePlateauNotTheFrameBeforeTheDip() {
        let (t, h) = series(freeThrow, to: 1.9)
        var o = BodyKinematicsOptions()
        o.dipIsLastTurningPoint = true
        let ph = BodyKinematics.phases(times: t, height: h, releaseRealTime: 1.50, signalSource: "test", options: o)
        let set = try! XCTUnwrap(ph.setPoint.value)
        // The plateau ends at 1.31 s; the set point is where the hand leaves it, not a wobble inside it.
        XCTAssertEqual(set, 1.31, accuracy: 0.06, "set point \(set) s")
        XCTAssertEqual(ph.setToReleaseMilliseconds.value!, 190, accuracy: 60)
    }

    func testAFreeThrowWithNoDescentHasNoDipAndSaysSo() {
        let (t, h) = series(freeThrow, to: 1.9)
        var o = BodyKinematicsOptions()
        o.dipIsLastTurningPoint = true
        let ph = BodyKinematics.phases(times: t, height: h, releaseRealTime: 1.50, signalSource: "test", options: o)
        XCTAssertNil(ph.dip.value, "a 4 mm wobble inside the set plateau is not a dip")
        XCTAssertTrue(ph.dip.unavailableReason!.contains("no dip"), ph.dip.unavailableReason!)
        XCTAssertNil(ph.dipToReleaseMilliseconds.value)
    }

    func testNoFollowThroughPeakWhenTheReleaseIsTheHighestPoint() {
        let (t, h) = series(freeThrow, to: 1.9)
        let ph = BodyKinematics.phases(times: t, height: h, releaseRealTime: 1.50, signalSource: "test")
        XCTAssertNil(ph.followThroughPeak.value)
        XCTAssertTrue(ph.followThroughPeak.unavailableReason!.contains("highest point is the release"),
                      ph.followThroughPeak.unavailableReason!)
    }

    func testFollowThroughEndIsMeasuredAgainstTheShotsOwnRise() {
        let (t, h) = series(freeThrow, to: 1.9)
        let ph = BodyKinematics.phases(times: t, height: h, releaseRealTime: 1.50, signalSource: "test")
        // Rise into the release is 0.38 m; 25 % of it is 0.095 m; the wrist falls at 0.5 m/s.
        let end = try! XCTUnwrap(ph.followThroughEnd.value)
        XCTAssertEqual((end - 1.50) * 1000, 190, accuracy: 60, "follow-through end \(1000 * (end - 1.50)) ms after release")
    }

    // MARK: the jump-shot shape still behaves

    func testJumpShotStillFindsSetDipAndFollowThroughInOrder() {
        let (t, h) = series(jumpShot, dt: 0.02, to: 1.0)
        let ph = BodyKinematics.phases(times: t, height: h, releaseRealTime: 0.6, signalSource: "test")
        let set = try! XCTUnwrap(ph.setPoint.value)
        let dip = try! XCTUnwrap(ph.dip.value)
        let peak = try! XCTUnwrap(ph.followThroughPeak.value)
        let end = try! XCTUnwrap(ph.followThroughEnd.value)
        XCTAssertLessThan(set, dip)
        XCTAssertLessThan(dip, 0.6)
        XCTAssertEqual(dip, 0.4, accuracy: 0.03)
        XCTAssertEqual(peak, 0.75, accuracy: 0.03)
        XCTAssertLessThan(0.6, end)
        XCTAssertGreaterThan(dip - set, 0.15, "the set point must precede the dip by a visible margin, not one frame")
    }

    func testSetPointRefusedWhenTheHandIsNeverStill() {
        let (t, h) = series({ 0.5 * $0 }, to: 1.0)      // a pure ramp: no plateau anywhere
        let ph = BodyKinematics.phases(times: t, height: h, releaseRealTime: 0.8, signalSource: "test")
        XCTAssertNil(ph.setPoint.value)
        XCTAssertTrue(ph.setPoint.unavailableReason!.contains("never still"), ph.setPoint.unavailableReason!)
        XCTAssertNil(ph.setToReleaseMilliseconds.value)
    }

    func testADeepDipIsStillADip() {
        let (t, h) = series(jumpShot, dt: 0.01, to: 1.0)
        var o = BodyKinematicsOptions()
        o.dipIsLastTurningPoint = true
        let ph = BodyKinematics.phases(times: t, height: h, releaseRealTime: 0.6, signalSource: "test", options: o)
        XCTAssertEqual(ph.dip.value!, 0.4, accuracy: 0.03)
        XCTAssertEqual(ph.dipToReleaseMilliseconds.value!, 200, accuracy: 35)
    }
}
