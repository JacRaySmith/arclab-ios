import XCTest
import simd
@testable import ShotGeometry

/// The `BodyShot` record (docs/BIOMETRIC-SCHEMA.md v1): round-trips exactly, keeps an unobserved joint
/// absent rather than inventing it, refuses a version it does not know, and stays under the size budget
/// with every frame carrying two hands.
final class BodyShotExportTests: XCTestCase {

    let K = CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 48)
    let height = 1.83
    let depth = 9.0

    /// A standing shooter at 9 m whose right arm extends over the window, with raw and fitted 3-D
    /// joints, 19 2-D points and two hands on every frame. Frame `dropJointOn` has no left ankle.
    func synthetic(n: Int, dropJointOn: Int? = nil) -> (raw: BodyTimeline, fitted: BodyTimeline) {
        let upperArm = 0.186 * height, forearm = 0.146 * height, shoulderHalf = 0.129 * height, hipHalf = 0.096 * height
        let trunk = 0.288 * height, thigh = 0.245 * height, shin = 0.246 * height
        var raw: [BodyFrame] = [], fitted: [BodyFrame] = []
        for i in 0..<n {
            let s = Double(i) / Double(max(1, n - 1))
            let elbowAngle = Double.pi - Angle.radians(150 - 130 * s)
            let yaw = Angle.radians(-40 + 70 * s)
            let rise = 0.05 * sin(Double.pi * s)
            let hipY = 0.53 * height - rise
            func P(_ x: Double, _ up: Double, _ z: Double) -> SIMD3<Double> { SIMD3(x, -up, depth + z) }   // y down, z away
            let lHip = P(-hipHalf, hipY, 0), rHip = P(hipHalf, hipY, 0)
            let lSh = P(-shoulderHalf, hipY + trunk, 0), rSh = P(shoulderHalf, hipY + trunk, 0)
            let nose = P(0, hipY + trunk + 0.112 * height, 0.02)
            let lKnee = P(-hipHalf, hipY - thigh, 0.02), rKnee = P(hipHalf, hipY - thigh, 0.02)
            let lAnk = P(-hipHalf, hipY - thigh - shin, 0), rAnk = P(hipHalf, hipY - thigh - shin, 0)
            let upDir = simd_normalize(SIMD3<Double>(0.20, -0.98, 0))
            let rElbow = rSh + upDir * upperArm
            let perp = SIMD3<Double>(cos(yaw), 0, sin(yaw))
            let rWrist = rElbow + simd_normalize(upDir * cos(Double.pi - elbowAngle) + perp * sin(Double.pi - elbowAngle)) * forearm
            let lElbow = lSh + SIMD3(-0.02, upperArm, 0.02), lWrist = lElbow + SIMD3(0.02, forearm, 0.05)
            let neck = (lSh + rSh) / 2
            var named: [(String, SIMD3<Double>)] = [
                (Body2DPoint.nose, nose), (Body2DPoint.neck, neck),
                (Body2DPoint.leftShoulder, lSh), (Body2DPoint.rightShoulder, rSh),
                (Body2DPoint.leftElbow, lElbow), (Body2DPoint.rightElbow, rElbow),
                (Body2DPoint.leftWrist, lWrist), (Body2DPoint.rightWrist, rWrist),
                (Body2DPoint.leftHip, lHip), (Body2DPoint.rightHip, rHip),
                (Body2DPoint.leftKnee, lKnee), (Body2DPoint.rightKnee, rKnee),
                (Body2DPoint.leftAnkle, lAnk), (Body2DPoint.rightAnkle, rAnk),
            ]
            if dropJointOn == i { named.removeAll { $0.0 == Body2DPoint.leftAnkle } }
            var pts: [String: BodyPoint2D] = [:]
            var j3: [String: BodyJoint3D] = [:]
            var rawJ: [String: BodyJoint3D] = [:]
            for (name, p) in named {
                let u = K.fx * p.x / p.z + K.cx, v = K.fy * p.y / p.z + K.cy
                pts[name] = BodyPoint2D(name: name, u: u, v: v, confidence: 0.9)
                let cam = SIMD3(p.x, -p.y, -p.z)                       // Vision: +y up, +z toward the camera
                j3[name] = BodyJoint3D(name: name, position: cam - SIMD3(0, -hipY, -depth), cameraPosition: cam, imageU: u, imageV: v)
                let stored = SIMD3(p.x + 0.03, -p.y, p.z)            // raw Vision as stored: +y up, subject at +z
                rawJ[name] = BodyJoint3D(name: name, position: stored, cameraPosition: stored)
            }
            for name in [Body2DPoint.leftEye, Body2DPoint.rightEye, Body2DPoint.leftEar, Body2DPoint.rightEar, Body2DPoint.root] {
                let base = pts[Body2DPoint.nose]!
                pts[name] = BodyPoint2D(name: name, u: base.u + 4, v: base.v - 3, confidence: 0.8)
            }
            let hands = ["left", "right"].map { side -> BodyHandFrame in
                let w = pts[side == "left" ? Body2DPoint.leftWrist : Body2DPoint.rightWrist]!
                var lm: [String: BodyPoint2D] = [:]
                for (k, l) in HandLandmark.all.enumerated() { lm[l] = BodyPoint2D(name: l, u: w.u + Double(k), v: w.v - Double(k) * 0.7, confidence: 0.75) }
                return BodyHandFrame(chirality: side, role: side == "right" ? "shooting" : "guide", confidence: 0.8, landmarks: lm)
            }
            let crop = BodyCrop(x: 600, y: 100, width: 700, height: 900)
            raw.append(BodyFrame(frameIndex: i * 2, fileTime: Double(i) / 120, realTime: Double(i) / 120, joints3D: rawJ, points2D: pts, hands: hands, crop: crop))
            fitted.append(BodyFrame(frameIndex: i * 2, fileTime: Double(i) / 120, realTime: Double(i) / 120, joints3D: j3, points2D: pts, hands: hands, crop: crop))
        }
        func tl(_ f: [BodyFrame]) -> BodyTimeline {
            BodyTimeline(frames: f, timeScale: 1, imageWidth: 1920, imageHeight: 1080, everyNthFrame: 2,
                         decodedFrames: 2 * n, analysedFrames: n, wallSeconds: 1, notes: ["synthetic"])
        }
        return (tl(raw), tl(fitted))
    }

    func fitResult(_ fitted: BodyTimeline, measured: Bool) -> BodySkeletonFitResult {
        let coverage = BodySkeletonFit.joints.map {
            BodyJointCoverage(name: $0, source: "2D", framesSeen: fitted.frames.count, framesTotal: fitted.frames.count, seenFraction: 1,
                              medianConfidence: .ok(0.9, .ratio), jitterPixels: .ok(0.5, .pixels), clippedFraction: 0, symmetryInferred: false, note: nil)
        }
        return BodySkeletonFitResult(
            timeline: fitted,
            bones: [BodyBoneLength(name: "forearmRight", a: Body2DPoint.rightElbow, b: Body2DPoint.rightWrist, metres: 0.146 * height, maximumProjectedPixels: 40, madMetres: 0.001, frames: fitted.frames.count)],
            metresPerPixelAtBody: .ok(0.006, .metres), bodyDepthMetres: .ok(depth, .metres),
            standingHeightMetres: measured ? .ok(height, .metres) : .missing(.metres, "no stated height"),
            scaleProvenance: measured ? "stated height 1.83 m" : "1.80 m population prior",
            scaleIsMeasured: measured,
            reprojectionRMSPixels: .ok(0.4, .pixels), visionReprojectionRMSPixels: .ok(60, .pixels), framesFitted: fitted.frames.count,
            depthSigmaMetres: .ok(0.08, .metres), lateralSigmaMetres: .ok(0.004, .metres),
            priorBones: ["biiliac"], symmetricBones: ["forearmRight", "forearmLeft"], jointCoverage: coverage,
            symmetryInferredJoints: [], transverseYawUnavailableReason: nil, sweepCosts: [], notes: ["fit note"], warnings: [])
    }

    func makeShot(n: Int, dropJointOn: Int? = nil, measured: Bool = true) -> (BodyShot, BodyTimeline) {
        let (raw, fitted) = synthetic(n: n, dropJointOn: dropJointOn)
        let fit = fitResult(fitted, measured: measured)
        let release = fitted.frames[fitted.frames.count * 3 / 4].realTime
        let model = BodyKinematics.model(timeline: fitted, releaseRealTime: release, rimImageU: 1800,
                                         options: BodyKinematicsOptions(shootingSide: "right"))
        let source = BodyShotSource(kind: "cli", build: "test", device: "synthetic",
                                    format: BodyShotFormat(w: 1920, h: 1080, fps: 240, hfovDegrees: 48, provenance: "assumed"))
        let shot = BodyShot.make(rawTimeline: raw, fit: fit, model: model, releaseRealTime: release,
                                 setRealTime: model.phases.setPoint, dipRealTime: BodyShot.vettedDip(model.phases),
                                 followThroughPeakRealTime: model.phases.followThroughPeak, realFrameRate: 240,
                                 source: source, rimImageU: 1800, shotID: 3)
        return (shot, raw)
    }

    func testRoundTripIsExact() throws {
        let (shot, _) = makeShot(n: 30)
        let data = try shot.encoded()
        let back = try BodyShot.decode(data)
        XCTAssertEqual(back, shot)
        XCTAssertEqual(back.version, 2, "the record writes the current schema")
        XCTAssertEqual(back.frames.count, 30)
        XCTAssertEqual(back.timing.everyNthFrame, 2)
        XCTAssertEqual(back.timing.quantisationFloor, 2.0 / 240, accuracy: 1e-12)
        XCTAssertEqual(back.skeleton.unit, "metres")
        XCTAssertEqual(back.skeleton.scaleProvenance, "statedHeight")
        XCTAssertEqual(Set(back.angles.keys), Set(BodyShot.angleTrackNames))
        XCTAssertFalse(back.angles["elbowRight"]!.samples.isEmpty)
        XCTAssertNotNil(back.angles["headYaw"]!.unavailableReason, "no per-frame head track exists; the record must say so, not print zeros")
        XCTAssertEqual(back.frames[0].hands.count, 2)
        XCTAssertEqual(back.frames[0].hands.map(\.role).sorted(), ["guide", "shooting"])
        XCTAssertEqual(back.frames[0].hands[0].landmarks.count, 21)
        // Raw camera frame is x right, y down, z forward: a joint 9 m in front of the lens has z ≈ +9.
        let z = back.frames[0].joints3D[Body2DPoint.nose]!.z
        XCTAssertEqual(z, depth + 0.02, accuracy: 1e-3)
        XCTAssertGreaterThan(back.frames[0].joints3D[Body2DPoint.rightAnkle]!.y, back.frames[0].joints3D[Body2DPoint.nose]!.y, "y grows downward")
        // Body frame: z up, origin at the mid-hip on the set (or first) frame.
        let f0 = back.frames[0].fitted3D
        XCTAssertGreaterThan(f0[Body2DPoint.nose]!.z, f0[Body2DPoint.rightAnkle]!.z)
        XCTAssertTrue(back.summary.handRateAtRelease.isAvailable)
        XCTAssertEqual(back.summary.handRateAtRelease.value, 1)
    }

    func testMissingJointStaysAbsent() throws {
        let (shot, raw) = makeShot(n: 30, dropJointOn: 7)
        let data = try shot.encoded()
        let back = try BodyShot.decode(data)
        let frame = back.frames.first { $0.frameIndex == raw.frames[7].frameIndex }!
        XCTAssertNil(frame.points2D[Body2DPoint.leftAnkle])
        XCTAssertNil(frame.joints3D[Body2DPoint.leftAnkle])
        XCTAssertNil(frame.fitted3D[Body2DPoint.leftAnkle])
        XCTAssertNil(frame.seen[Body2DPoint.leftAnkle])
        XCTAssertNotNil(back.frames[6].points2D[Body2DPoint.leftAnkle])
        XCTAssertEqual(back.frames[6].seen[Body2DPoint.leftAnkle], true)
        // The JSON itself has no such key on that frame either — absence is the encoding, not a null.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("\"leftAnkle\":null"))
    }

    func testNoStatedHeightMeansNoMetres() throws {
        let (shot, _) = makeShot(n: 20, measured: false)
        XCTAssertEqual(shot.skeleton.unit, "unitHeight")
        XCTAssertEqual(shot.skeleton.scaleProvenance, "unitHeight")
        XCTAssertNil(shot.summary.jumpHeight.value)
        XCTAssertNotNil(shot.summary.jumpHeight.unavailableReason)
        XCTAssertNil(shot.skeleton.standingHeight.value)
        // Unit-height lengths: the nose sits about 0.93 H above the ankle, so ~0.4 H above the mid-hip.
        let f0 = shot.frames[0].fitted3D
        XCTAssertEqual(f0[Body2DPoint.nose]!.z - f0[Body2DPoint.rightAnkle]!.z, 0.93, accuracy: 0.05)
    }

    func testUnknownVersionIsRefused() throws {
        let (shot, _) = makeShot(n: 5)
        var text = String(decoding: try shot.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"version\":2"))
        text = text.replacingOccurrences(of: "\"version\":2", with: "\"version\":7")
        XCTAssertThrowsError(try BodyShot.decode(Data(text.utf8))) { error in
            XCTAssertEqual(error as? BodyShotError, .unsupportedVersion(7))
        }
    }

    /// v2 is **additive**: a file written by 1.2 — version 1, no `hands` block, no `handTriangles`,
    /// no `provenance` on a point — still decodes, and decodes to the same thing it always did. This
    /// is the test that stops a schema bump from stranding the 110 shots already on the phone.
    func testVersionOneStillDecodes() throws {
        let (shot, _) = makeShot(n: 8)
        var text = String(decoding: try shot.encoded(), as: UTF8.self)
        // Strip everything v2 added, exactly as a 1.2 file would not have had it.
        text = text.replacingOccurrences(of: "\"version\":2", with: "\"version\":1")
        XCTAssertFalse(text.contains("\"handTriangles\""), "this synthetic shot was built without plates")
        let back = try BodyShot.decode(Data(text.utf8))
        XCTAssertEqual(back.version, 1)
        XCTAssertNil(back.hands, "a v1 file has no hand block, and the reader must not invent one")
        XCTAssertEqual(back.frames.count, 8)
        XCTAssertNil(back.frames[0].handTriangles)
        XCTAssertNil(back.frames[0].points2D[Body2DPoint.nose]?.provenance)
        XCTAssertEqual(back.frames[0].hands.count, 2, "the v1 raw hand landmarks are untouched")
        XCTAssertEqual(back.skeleton.unit, "metres")
    }

    func testTwoHundredFramesFitTheBudget() throws {
        let (shot, _) = makeShot(n: 200)
        let data = try shot.encoded()
        XCTAssertEqual(shot.frames.count, 200)
        print("BodyShot 200 frames with two hands: \(data.count) bytes")
        XCTAssertLessThanOrEqual(data.count, 2_000_000, "200 frames with two full hands each must stay ≤ 2 MB; got \(data.count) bytes")
    }
}
