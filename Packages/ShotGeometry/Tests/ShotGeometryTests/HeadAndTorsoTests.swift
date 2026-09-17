import XCTest
import simd
@testable import ShotGeometry

/// Iteration 5 (the 3-D model, 1.1): which way the shooter faces, the torso's transverse axis on a
/// view that cannot see it, and where a skull sits on a neck.
///
/// The fit tests build a **side-on** shooter — the shoulder line pointing along the view ray, which
/// is what every clip in this project's footage actually is — so the collapse the 1.1 work was about
/// is reproduced rather than assumed.
final class HeadAndTorsoTests: XCTestCase {

    let K = CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 48)
    let height = 1.83
    let depth = 9.0

    // MARK: - A side-on shooter

    /// A shooter at `depth`, **side on**: they face image-`right` (or left), so their shoulder and hip
    /// lines run along the camera's view ray and project to a few pixels. The shooting (right) arm
    /// swings in the sagittal plane, which on this view is the image plane. Nothing about depth
    /// reaches the solver: only the projected pixels and the stated height.
    func sideOn(n: Int = 30, facesRight: Bool = true) -> [BodyFrame] {
        let f = facesRight ? 1.0 : -1.0
        let upperArm = 0.186 * height, forearm = 0.146 * height
        let shoulderHalf = 0.1225 * height          // Winter's biacromial 0.245 H
        let hipHalf = 0.0955 * height               // biiliac 0.191 H
        let trunk = 0.288 * height, thigh = 0.245 * height, shin = 0.246 * height
        var frames: [BodyFrame] = []
        for i in 0..<n {
            let s = Double(i) / Double(n - 1)
            let flexion = Angle.radians(80 + 90 * s)     // the elbow opens from 80° to 170°
            let dip = 0.06 * sin(Double.pi * s)
            let hipY = 0.53 * height - dip

            /// `forwardOfMidline` is +x·f, `across` is +z for the shooter's **left** (forward × left = up).
            func P(_ forwardOfMidline: Double, _ up: Double, _ across: Double) -> SIMD3<Double> {
                SIMD3(f * forwardOfMidline, -up, depth + across)
            }
            let lHip = P(0, hipY, shoulderHalf * 0 + hipHalf), rHip = P(0, hipY, -hipHalf)
            let lSh = P(0, hipY + trunk, shoulderHalf), rSh = P(0, hipY + trunk, -shoulderHalf)
            let neck = P(0, hipY + trunk + 0.03 * height, 0)
            let nose = P(0.075 * height, hipY + trunk + 0.105 * height, 0)     // the nose leads the neck
            // The knees lead the hip-to-ankle line when the shooter dips: the second facing cue.
            let kneeLead = 0.02 * height + 0.5 * dip
            let lKnee = P(kneeLead, hipY - thigh + dip, hipHalf), rKnee = P(kneeLead, hipY - thigh + dip, -hipHalf)
            let lAnk = P(0, hipY - thigh - shin, hipHalf), rAnk = P(0, hipY - thigh - shin, -hipHalf)
            // Shooting arm, in the sagittal (here: image) plane.
            let rElbow = rSh + SIMD3(f * 0.05 * height, -upperArm * 0.9, 0)
            let dir = SIMD3<Double>(f * cos(flexion - .pi / 2), -sin(flexion - .pi / 2), 0)
            let rWrist = rElbow + simd_normalize(dir) * forearm
            let lElbow = lSh + SIMD3(f * 0.04 * height, -upperArm * 0.85, 0.02)
            let lWrist = lElbow + SIMD3(f * 0.02 * height, -forearm * 0.9, -0.02)

            let named: [(String, SIMD3<Double>)] = [
                (Body2DPoint.nose, nose), (Body2DPoint.neck, neck),
                (Body2DPoint.leftShoulder, lSh), (Body2DPoint.rightShoulder, rSh),
                (Body2DPoint.leftElbow, lElbow), (Body2DPoint.rightElbow, rElbow),
                (Body2DPoint.leftWrist, lWrist), (Body2DPoint.rightWrist, rWrist),
                (Body2DPoint.leftHip, lHip), (Body2DPoint.rightHip, rHip),
                (Body2DPoint.leftKnee, lKnee), (Body2DPoint.rightKnee, rKnee),
                (Body2DPoint.leftAnkle, lAnk), (Body2DPoint.rightAnkle, rAnk),
            ]
            var pts: [String: BodyPoint2D] = [:]
            for (name, p) in named {
                pts[name] = BodyPoint2D(name: name, u: K.fx * p.x / p.z + K.cx,
                                        v: K.fy * p.y / p.z + K.cy, confidence: 0.9)
            }
            frames.append(BodyFrame(frameIndex: i, fileTime: Double(i) / 60, realTime: Double(i) / 60,
                                    joints3D: [:], points2D: pts, hands: []))
        }
        return frames
    }

    func timeline(_ frames: [BodyFrame]) -> BodyTimeline {
        BodyTimeline(frames: frames, timeScale: 1, imageWidth: 1920, imageHeight: 1080, everyNthFrame: 1,
                     decodedFrames: frames.count, analysedFrames: frames.count, wallSeconds: 1, notes: [])
    }

    func options(_ torso: Bool) -> BodySkeletonOptions {
        var o = BodySkeletonOptions(intrinsics: K)
        o.scale = .statedHeight(metres: height)
        o.torsoBreadthWhenUnobservable = torso
        return o
    }

    // MARK: - the facing cue

    func testFacingRightIsReadFromTheHeadAndTheLegsTogether() {
        let cue = BodyFacing.fromImage(frames: sideOn(facesRight: true))
        XCTAssertEqual(cue.imageSign, 1)
        XCTAssertNil(cue.unavailableReason)
        XCTAssertTrue(cue.note.contains("head and the legs agree"), cue.note)
        XCTAssertGreaterThan(cue.headOffsetPx ?? 0, 0)
        XCTAssertGreaterThan(cue.legOffsetPx ?? 0, 0)
    }

    func testFacingLeftIsTheOtherSign() {
        XCTAssertEqual(BodyFacing.fromImage(frames: sideOn(facesRight: false)).imageSign, -1)
    }

    func testAnOffsetInsideTheJitterFloorIsRefusedWithAReason() {
        let cue = BodyFacing.fromImage(frames: sideOn(), minimumConfidence2D: 0.3, minimumOffsetPx: 10_000)
        XCTAssertNil(cue.imageSign)
        XCTAssertTrue(cue.unavailableReason?.contains("jitter floor") == true, cue.unavailableReason ?? "")
    }

    func testDisagreeingCuesRefuseRatherThanVote() {
        // Mirror only the legs: the head still says right, the knees now say left.
        var frames = sideOn(facesRight: true)
        for i in frames.indices {
            for name in ["leftKnee", "rightKnee"] {
                guard let p = frames[i].points2D[name], let hip = frames[i].points2D[name.replacingOccurrences(of: "Knee", with: "Hip")],
                      let ankle = frames[i].points2D[name.replacingOccurrences(of: "Knee", with: "Ankle")] else { continue }
                let line = (hip.u + ankle.u) / 2
                frames[i].points2D[name] = BodyPoint2D(name: name, u: line - (p.u - line), v: p.v, confidence: p.confidence)
            }
        }
        let cue = BodyFacing.fromImage(frames: frames)
        XCTAssertNil(cue.imageSign)
        XCTAssertTrue(cue.unavailableReason?.contains("disagree") == true, cue.unavailableReason ?? "")
    }

    // MARK: - the torso's transverse axis

    func testSideOnBreadthCollapsesWithoutThePriorAndIsRecoveredWithIt() {
        let frames = sideOn()
        let off = BodySkeletonFit.fit(timeline: timeline(frames), options: options(false))
        let on = BodySkeletonFit.fit(timeline: timeline(frames), options: options(true))
        let truth = 0.245 * height
        let collapsed = off.bones.first { $0.name == "biacromial" }!.metres
        let pinned = on.bones.first { $0.name == "biacromial" }!.metres
        XCTAssertLessThan(collapsed, 0.5 * truth,
                          "a near-side view cannot see the shoulder line, so the free fit must collapse it — it came out \(collapsed) m against \(truth) m")
        XCTAssertEqual(pinned, truth, accuracy: 0.02 * truth)
        XCTAssertTrue(on.priorBones.contains("biacromial"))
        XCTAssertTrue(on.priorBones.contains("biiliac"))
        XCTAssertEqual(on.bones.first { $0.name == "biacromial" }!.source, "population breadth (pinned)")
    }

    func testThePinnedBreadthIsDeclaredAPriorAndTheYawStaysRefused() {
        let on = BodySkeletonFit.fit(timeline: timeline(sideOn()), options: options(true))
        XCTAssertNotNil(on.transverseYawUnavailableReason,
                        "the yaw must stay refused: pinning the breadth changes the skeleton's shape, not what may be read off it")
        XCTAssertTrue(on.notes.contains { $0.contains("Winter") && $0.contains("prior") },
                      "the note must say the breadth is a prior: \(on.notes)")
        XCTAssertEqual(on.facing?.imageSign, 1)
    }

    func testTheShootersLeftIsTheFarSideWhenTheyFaceImageRight() {
        // Right-handed anatomy: forward × left = up. Facing image-right puts the left side away from
        // the camera, which in the output's Vision frame (+z toward the camera) is the *smaller* z.
        for (facesRight, expectLeftFarther) in [(true, true), (false, false)] {
            let r = BodySkeletonFit.fit(timeline: timeline(sideOn(facesRight: facesRight)), options: options(true))
            let mid = r.timeline.frames[r.timeline.frames.count / 2]
            let l = mid.joints3D[Body2DPoint.leftShoulder]!.cameraPosition.z
            let rr = mid.joints3D[Body2DPoint.rightShoulder]!.cameraPosition.z
            if expectLeftFarther {
                XCTAssertLessThan(l, rr, "facing image-right, the shooter's left shoulder is the far one")
            } else {
                XCTAssertGreaterThan(l, rr, "facing image-left, the shooter's left shoulder is the near one")
            }
            XCTAssertGreaterThan(abs(l - rr), 0.6 * 0.245 * height,
                                 "and the two shoulders must actually be apart in depth, not on one line")
        }
    }

    func testWithoutAFacingCueTheTorsoIsLeftFlatAndSaidSo() {
        // Put the nose directly over the neck and the knees on the hip-to-ankle line: the shooter is
        // still fully tracked — the ankle-to-nose span survives, so the breadth is still *known* to be
        // unobservable — but neither facing cue clears its floor, so nothing may be oriented.
        var frames = sideOn()
        for i in frames.indices {
            if let nose = frames[i].points2D[Body2DPoint.nose], let neck = frames[i].points2D[Body2DPoint.neck] {
                frames[i].points2D[Body2DPoint.nose] = BodyPoint2D(name: Body2DPoint.nose, u: neck.u, v: nose.v,
                                                                   confidence: nose.confidence)
            }
            for side in ["left", "right"] {
                guard let k = frames[i].points2D[side + "Knee"], let hip = frames[i].points2D[side + "Hip"],
                      let ankle = frames[i].points2D[side + "Ankle"] else { continue }
                frames[i].points2D[side + "Knee"] = BodyPoint2D(name: side + "Knee", u: (hip.u + ankle.u) / 2,
                                                                v: k.v, confidence: k.confidence)
            }
        }
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(true))
        XCTAssertFalse(r.priorBones.contains("biacromial"))
        XCTAssertTrue(r.warnings.contains { $0.contains("as flat as the pixels leave them") },
                      "the refusal has to be said out loud: \(r.warnings)")
    }

    func testVisionDepthPriorIsOffByDefault() {
        XCTAssertEqual(BodySkeletonOptions(intrinsics: K).visionDepthPriorWeight, 0,
                       "Vision's 3-D placement is near-planar on a side view (its own left/right hip depth separation is 0.0007 H); only its sign is used")
    }

    // MARK: - the head

    func testFacingIsTheHorizontalPartOfNeckToNose() {
        let neck = SIMD3<Double>(0, 0, 1.4), nose = SIMD3<Double>(0.07, 0, 1.55)
        let f = HeadGeometry.facing(nose: nose, neck: neck, up: SIMD3(0, 0, 1), stature: 1.83)
        XCTAssertNotNil(f)
        XCTAssertEqual(f!.direction.x, 1, accuracy: 1e-9)
        XCTAssertEqual(f!.direction.z, 0, accuracy: 1e-9)
        XCTAssertEqual(f!.offset, 0.07, accuracy: 1e-9)
    }

    func testANoseDirectlyOverItsNeckSaysNothingAboutFacing() {
        XCTAssertNil(HeadGeometry.facing(nose: SIMD3(0, 0, 1.55), neck: SIMD3(0, 0, 1.4),
                                         up: SIMD3(0, 0, 1), stature: 1.83))
    }

    func testTheSkullSitsBehindTheNoseAndOnTheNeck() {
        let S = 1.83
        let neck = SIMD3<Double>(0, 0, 1.40), nose = SIMD3<Double>(0.07, 0, 1.55)
        let h = HeadGeometry.frame(nose: nose, neck: neck, trunkUp: SIMD3(0, 0, 1), stature: S)
        XCTAssertNil(h.faceUnavailableReason)
        let forward = h.forward!
        // The skull's centre is behind the nose along the facing direction, by the documented amount.
        XCTAssertEqual(simd_dot(h.nose - h.skullCentre, forward), HeadProportions.noseToCentre * S, accuracy: 1e-9)
        XCTAssertGreaterThan(simd_dot(h.skullCentre - h.nose, h.up), 0, "and a little above it, so the brow is over the nose")
        // The base is below the centre and above the neck: the neck meets a skull, not a nose.
        XCTAssertLessThan(h.skullBase.z, h.skullCentre.z)
        XCTAssertGreaterThan(h.skullBase.z, neck.z)
        // The nose is on (not inside) the skull's front: its distance along forward exceeds the semi-axis.
        XCTAssertGreaterThan(simd_dot(h.nose - h.skullCentre, forward), h.semiAxes.z)
    }

    func testTheEyesStraddleTheFaceAndTheChinIsBelowThem() {
        let S = 1.83
        let h = HeadGeometry.frame(nose: SIMD3(0.07, 0, 1.55), neck: SIMD3(0, 0, 1.40),
                                   trunkUp: SIMD3(0, 0, 1), stature: S)
        let side = h.side!, forward = h.forward!
        let l = h.eyeLeft!, r = h.eyeRight!
        XCTAssertEqual(simd_dot(l - h.skullCentre, side), HeadProportions.halfEyeSpan * S, accuracy: 1e-9)
        XCTAssertEqual(simd_dot(r - h.skullCentre, side), -HeadProportions.halfEyeSpan * S, accuracy: 1e-9)
        XCTAssertGreaterThan(simd_dot(l - h.skullCentre, forward), 0, "the eyes are on the face side")
        XCTAssertGreaterThan(simd_dot(l - h.skullCentre, h.up), 0, "and above the skull's middle")
        XCTAssertLessThan(simd_dot(h.chinLeft! - h.skullCentre, h.up), 0, "the chin is below it")
        XCTAssertGreaterThan(simd_dot(h.chinLeft! - h.skullCentre, forward), 0, "and on the face side")
        // `side` is the shooter's left: forward × left = up.
        XCTAssertGreaterThan(simd_dot(simd_cross(forward, side), h.up), 0.99)
    }

    func testNoFacingCueMeansNoFaceAndASentenceSayingWhy() {
        let h = HeadGeometry.frame(nose: SIMD3(0, 0, 1.55), neck: SIMD3(0, 0, 1.40),
                                   trunkUp: SIMD3(0, 0, 1), stature: 1.83)
        XCTAssertNil(h.forward)
        XCTAssertNil(h.eyeLeft)
        XCTAssertNil(h.chinLeft)
        XCTAssertTrue(h.faceUnavailableReason?.contains("does not say which way the shooter faces") == true,
                      h.faceUnavailableReason ?? "")
    }

    func testTheFacingLockStopsOneBadFrameTurningTheHeadRound() {
        let up = SIMD3<Double>(0, 0, 1), neck = SIMD3<Double>(0, 0, 1.40)
        var samples: [(nose: SIMD3<Double>, neck: SIMD3<Double>, up: SIMD3<Double>)] = []
        for i in 0..<20 {
            let flipped = i == 7                   // one frame's nose lands on the wrong side
            samples.append((SIMD3(flipped ? -0.07 : 0.07, 0, 1.55), neck, up))
        }
        let lock = HeadGeometry.facingLock(noseNeckUp: samples, stature: 1.83)!
        XCTAssertGreaterThan(lock.x, 0.9, "nineteen frames out of twenty face +x")
        let bad = HeadGeometry.frame(nose: SIMD3(-0.07, 0, 1.55), neck: neck, trunkUp: up,
                                     stature: 1.83, facingLock: lock)
        XCTAssertGreaterThan(bad.forward!.x, 0, "and the odd frame is turned back to face with them")
    }

    func testNoNeckMeansNoFace() {
        let h = HeadGeometry.frame(nose: SIMD3(0.07, 0, 1.55), neck: nil, trunkUp: SIMD3(0, 0, 1), stature: 1.83)
        XCTAssertNil(h.forward)
        XCTAssertTrue(h.faceUnavailableReason?.contains("no neck joint") == true, h.faceUnavailableReason ?? "")
    }
}
