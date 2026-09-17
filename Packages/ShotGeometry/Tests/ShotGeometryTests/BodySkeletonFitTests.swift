import XCTest
import simd
@testable import ShotGeometry

/// The per-shot skeleton fit (`BodySkeletonFit`), on a synthetic shooter whose bone lengths and joint
/// angles are known exactly. The body is built in the pinhole camera frame (+x right, +y **down**,
/// +z away from the camera), projected through real intrinsics, and only those pixels — plus the
/// stated height — are handed to the solver. Nothing about depth is given away.
final class BodySkeletonFitTests: XCTestCase {

    // 1080p at hFOV 48°, the measured field of view of the 2026-09-13 footage.
    let K = CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 48)
    let height = 1.83
    let depth = 9.0

    /// A shooter standing at `depth`, arms moving: the right elbow sweeps from `bent` to `straight`
    /// over the window while the whole arm rotates out of the image plane, which is precisely the
    /// case a 2-D angle cannot handle and a fitted skeleton must.
    /// Returns (frames, true right-elbow angle per frame, true bone lengths).
    func synthetic(n: Int = 40, noisePx: Double = 0.0, seed: UInt64 = 7)
        -> (frames: [BodyFrame], elbow: [Double], upperArm: Double, forearm: Double) {
        var rng = SeededRNG(seed: seed)
        let upperArm = 0.186 * height, forearm = 0.146 * height   // Winter's segment fractions
        let shoulderHalf = 0.129 * height, hipHalf = 0.096 * height
        let trunk = 0.288 * height, thigh = 0.245 * height, shin = 0.246 * height
        var frames: [BodyFrame] = [], elbows: [Double] = []

        for i in 0..<n {
            let s = Double(i) / Double(n - 1)
            let flexion = Angle.radians(150 - 130 * s)      // interior elbow angle 150° → 20° of flexion
            let elbowAngle = Double.pi - flexion            // interior angle at the elbow
            let yaw = Angle.radians(-40 + 70 * s)           // the arm swings through the image plane
            let rise = 0.05 * sin(Double.pi * s)            // the hips rise a little

            // Camera frame: +x right, +y down, +z away. Feet on the ground plane at y = +1.0 m.
            let hipY = 0.53 * height - rise
            func P(_ x: Double, _ up: Double, _ z: Double) -> SIMD3<Double> { SIMD3(x, -up, depth + z) }
            let lHip = P(-hipHalf, hipY, 0), rHip = P(hipHalf, hipY, 0)
            let lSh = P(-shoulderHalf, hipY + trunk, 0), rSh = P(shoulderHalf, hipY + trunk, 0)
            let nose = P(0, hipY + trunk + 0.112 * height, 0.02)   // Winter: nose 0.930 H, shoulder 0.818 H
            let lKnee = P(-hipHalf, hipY - thigh, 0.02), rKnee = P(hipHalf, hipY - thigh, 0.02)
            let lAnk = P(-hipHalf, hipY - thigh - shin, 0), rAnk = P(hipHalf, hipY - thigh - shin, 0)
            // Right arm: upper arm raised overhead, forearm folded by `elbowAngle` in a plane yawed by `yaw`.
            let upDir = SIMD3<Double>(0.20, -0.98, 0)
            let rElbow = rSh + simd_normalize(upDir) * upperArm
            let perp = SIMD3<Double>(cos(yaw), 0, sin(yaw))
            let foreDir = simd_normalize(simd_normalize(upDir) * cos(Double.pi - elbowAngle) + perp * sin(Double.pi - elbowAngle))
            let rWrist = rElbow + foreDir * forearm
            let lElbow = lSh + SIMD3(-0.02, upperArm, 0.02), lWrist = lElbow + SIMD3(0.02, forearm, 0.05)

            let named: [(String, SIMD3<Double>)] = [
                (Body2DPoint.nose, nose), (Body2DPoint.leftShoulder, lSh), (Body2DPoint.rightShoulder, rSh),
                (Body2DPoint.leftElbow, lElbow), (Body2DPoint.rightElbow, rElbow),
                (Body2DPoint.leftWrist, lWrist), (Body2DPoint.rightWrist, rWrist),
                (Body2DPoint.leftHip, lHip), (Body2DPoint.rightHip, rHip),
                (Body2DPoint.leftKnee, lKnee), (Body2DPoint.rightKnee, rKnee),
                (Body2DPoint.leftAnkle, lAnk), (Body2DPoint.rightAnkle, rAnk),
            ]
            var pts: [String: BodyPoint2D] = [:]
            for (name, p) in named {
                let u = K.fx * p.x / p.z + K.cx + (noisePx > 0 ? rng.gaussian(sd: noisePx) : 0)
                let v = K.fy * p.y / p.z + K.cy + (noisePx > 0 ? rng.gaussian(sd: noisePx) : 0)
                pts[name] = BodyPoint2D(name: name, u: u, v: v, confidence: 0.9)
            }
            frames.append(BodyFrame(frameIndex: i, fileTime: Double(i) / 30, realTime: Double(i) / 120,
                                    joints3D: [:], points2D: pts, hands: []))
            elbows.append(BodyAngles.angle(rSh, rElbow, rWrist)!)
        }
        return (frames, elbows, upperArm, forearm)
    }

    func timeline(_ frames: [BodyFrame]) -> BodyTimeline {
        BodyTimeline(frames: frames, timeScale: 4, imageWidth: 1920, imageHeight: 1080,
                     everyNthFrame: 1, decodedFrames: frames.count, analysedFrames: frames.count,
                     wallSeconds: 1, notes: [])
    }

    func options(_ scale: BodyScaleProvenance) -> BodySkeletonOptions {
        var o = BodySkeletonOptions(intrinsics: K)
        o.scale = scale
        return o
    }

    // MARK: - noise-free: the fit must recover the truth

    func testRecoversMovingArmAnglesWithoutNoise() {
        let (frames, truth, upperArm, forearm) = synthetic(noisePx: 0)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        XCTAssertEqual(r.framesFitted, frames.count)
        XCTAssertLessThan(r.reprojectionRMSPixels.value!, 1.0, "a noise-free synthetic body must reproject to well under a pixel")

        let fitted = r.timeline.frames.map { BodyKinematics.angles(frame: $0).rightElbow.degrees }
        let errors = zip(fitted, truth).compactMap { f, t in f.map { abs($0 - Angle.degrees(t)) } }
        XCTAssertEqual(errors.count, truth.count)
        // A monocular fit leaves depth as the weak direction; 8° over a 130° sweep is the bar.
        XCTAssertLessThan(Stats.median(errors), 8.0, "median elbow error \(Stats.median(errors))°")

        // The one skeleton: bone lengths within 12 % of the truth they were never told.
        func bone(_ n: String) -> Double { r.bones.first { $0.name == n }!.metres }
        XCTAssertEqual(bone("upperArmRight"), upperArm, accuracy: 0.12 * upperArm)
        XCTAssertEqual(bone("forearmRight"), forearm, accuracy: 0.12 * forearm)
    }

    // MARK: - the point of the exercise: less jitter than the input

    func testSmoothsPixelNoiseIntoLessAngleJitter() {
        let (frames, _, _, _) = synthetic(noisePx: 2.0, seed: 11)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        func jitter(_ v: [Double]) -> Double {
            var d: [Double] = []
            for i in 1..<v.count { d.append(v[i] - v[i - 1]) }
            return Stats.sd(d) / 2.0.squareRoot()
        }
        // The 2-D image angle at the elbow, straight off the same noisy pixels.
        let raw = frames.compactMap { f -> Double? in
            guard let s = f.points2D[Body2DPoint.rightShoulder], let e = f.points2D[Body2DPoint.rightElbow],
                  let w = f.points2D[Body2DPoint.rightWrist] else { return nil }
            return BodyAngles.imageAngle(s.uv, e.uv, w.uv).map(Angle.degrees)
        }
        let fitted = r.timeline.frames.compactMap { BodyKinematics.angles(frame: $0).rightElbow.degrees }
        XCTAssertEqual(fitted.count, frames.count)
        XCTAssertLessThan(jitter(fitted), jitter(raw),
                          "fitted jitter \(jitter(fitted))° should beat the raw 2-D angle's \(jitter(raw))°")
    }

    // MARK: - scale provenance

    func testNoScaleProvenanceRefusesEveryMetreButKeepsAngles() {
        let (frames, truth, _, _) = synthetic(noisePx: 0)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.none))
        XCTAssertFalse(r.scaleIsMeasured)
        XCTAssertNil(r.metresPerPixelAtBody.value)
        XCTAssertNotNil(r.metresPerPixelAtBody.unavailableReason)
        XCTAssertNil(r.bodyDepthMetres.value)
        XCTAssertTrue(r.warnings.contains { $0.contains("no length in it is a metre") })
        // Angles are scale-free and must survive.
        let fitted = r.timeline.frames.map { BodyKinematics.angles(frame: $0).rightElbow.degrees }
        let errors = zip(fitted, truth).compactMap { f, t in f.map { abs($0 - Angle.degrees(t)) } }
        XCTAssertLessThan(Stats.median(errors), 8.0)
    }

    func testStatedHeightRecoversTheCameraDistance() {
        let (frames, _, _, _) = synthetic(noisePx: 0)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        // The synthetic body stands at 9 m; the scale is derived only from the stated height and pixels.
        XCTAssertEqual(r.bodyDepthMetres.value!, depth, accuracy: 0.6)
        XCTAssertEqual(r.standingHeightMetres.value!, height, accuracy: 1e-9)
    }

    func testRimRulerAgreesWithStatedHeightOnTheSameBody() {
        let (frames, _, _, _) = synthetic(noisePx: 0)
        let byHeight = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        // A 0.4572 m ring at the same depth spans this many pixels.
        let ringPx = K.fx * 0.4572 / depth
        let byRim = BodySkeletonFit.fit(timeline: timeline(frames),
                                        options: options(.rimRuler(diameterMetres: 0.4572, majorAxisPx: ringPx)))
        XCTAssertEqual(byRim.metresPerPixelAtBody.value!, byHeight.metresPerPixelAtBody.value!,
                       accuracy: 0.05 * byHeight.metresPerPixelAtBody.value!)
        XCTAssertEqual(byRim.standingHeightMetres.value!, height, accuracy: 0.05 * height)
    }

    func testImpossibleStatedHeightIsRefusedWithAReason() {
        let (frames, _, _, _) = synthetic(noisePx: 0)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: 12)))
        XCTAssertNil(r.metresPerPixelAtBody.value)
        XCTAssertTrue(r.metresPerPixelAtBody.unavailableReason!.contains("plausible standing height"))
    }

    // MARK: - contracts

    func testTooFewFramesRefusesWithAReason() {
        let (frames, _, _, _) = synthetic(n: 2)
        let r = BodySkeletonFit.fit(timeline: timeline(Array(frames.prefix(2))), options: options(.none))
        XCTAssertEqual(r.framesFitted, 0)
        XCTAssertTrue(r.warnings.first!.contains("at least three frames"))
    }

    func testFittedSkeletonReprojectsOntoItsOwn2DPoints() {
        let (frames, _, _, _) = synthetic(noisePx: 1.5, seed: 3)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        // Every fitted joint carries the image point it projects to; it must land on the observation.
        var errs: [Double] = []
        for (f, g) in zip(frames, r.timeline.frames) {
            for name in [Body2DPoint.rightElbow, Body2DPoint.rightWrist, Body2DPoint.leftKnee] {
                guard let o = f.points2D[name], let j = g.joints3D[name], let u = j.imageU, let v = j.imageV else { continue }
                errs.append(simd_length(SIMD2(u, v) - o.uv))
            }
        }
        XCTAssertFalse(errs.isEmpty)
        XCTAssertLessThan(Stats.median(errs), 4.0, "median reprojection \(Stats.median(errs)) px")
    }

    func testMonotoneCostDescent() {
        let (frames, _, _, _) = synthetic(noisePx: 2.0, seed: 5)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        XCTAssertGreaterThan(r.sweepCosts.count, 3)
        XCTAssertLessThan(r.sweepCosts.last!, r.sweepCosts.first!)
    }

    // MARK: - iteration 3 (2026-09-15): the neck, the symmetric prior, clipping, decimated depth

    /// The same synthetic body with Vision's 2-D `neck` point added, plus an optional 3-D depth
    /// seed on only every `seedEvery` frame (what a decimated 3-D request produces).
    func withNeck(_ frames: [BodyFrame], seedEvery: Int = 0) -> [BodyFrame] {
        var out: [BodyFrame] = []
        for (i, f) in frames.enumerated() {
            var g = f
            if let l = f.points2D[Body2DPoint.leftShoulder], let r = f.points2D[Body2DPoint.rightShoulder] {
                // The neck sits above the shoulder midpoint, as Vision's does.
                g.points2D[Body2DPoint.neck] = BodyPoint2D(name: Body2DPoint.neck,
                                                           u: (l.u + r.u) / 2, v: (l.v + r.v) / 2 - 6, confidence: 0.85)
            }
            if seedEvery > 0, i % seedEvery == 0 {
                // Only the front/back sign matters, so a crude camera-space stand-in is enough.
                var js: [String: BodyJoint3D] = [:]
                for (name3D, dz) in [(Body3DJoint.root, 0.0), (Body3DJoint.rightWrist, 0.2), (Body3DJoint.leftWrist, -0.2)] {
                    js[name3D] = BodyJoint3D(name: name3D, position: .zero,
                                             cameraPosition: SIMD3(0, 0, -depth - dz), imageU: nil, imageV: nil)
                }
                g.joints3D = js
            }
            out.append(g)
        }
        return out
    }

    func testNeckIsFittedAndLandsOnItsOwn2DPoint() {
        let (frames, _, _, _) = synthetic(noisePx: 1.0, seed: 11)
        let withNeckFrames = withNeck(frames)
        let r = BodySkeletonFit.fit(timeline: timeline(withNeckFrames), options: options(.statedHeight(metres: height)))
        var errs: [Double] = []
        for (f, g) in zip(withNeckFrames, r.timeline.frames) {
            guard let o = f.points2D[Body2DPoint.neck],
                  let j = g.joints3D[Body3DJoint.centerShoulder], let u = j.imageU, let v = j.imageV else { continue }
            errs.append(simd_length(SIMD2(u, v) - o.uv))
        }
        XCTAssertGreaterThan(errs.count, 30, "the fitted neck must be written to every frame as centerShoulder")
        XCTAssertLessThan(Stats.median(errs), 4.0, "median neck reprojection \(Stats.median(errs)) px")
        XCTAssertTrue(r.bones.contains { $0.name == "neckNose" })
    }

    func testNeckOffLeavesTheCentreShoulderAsTheShoulderMidpointWithNoImagePoint() {
        let (frames, _, _, _) = synthetic(noisePx: 0)
        var o = options(.statedHeight(metres: height))
        o.fitNeck = false
        let r = BodySkeletonFit.fit(timeline: timeline(withNeck(frames)), options: o)
        let j = r.timeline.frames[10].joints3D[Body3DJoint.centerShoulder]
        XCTAssertNotNil(j)
        XCTAssertNil(j?.imageU, "with the neck off, centerShoulder is a derived midpoint and must not claim an image point")
    }

    /// The far limb is the case the symmetric prior exists for: seen on a handful of frames and never
    /// frontoparallel, its own longest projection is a bad floor. Here the left thigh's observations
    /// are deleted on all but a few frames and the true length is known.
    func testSymmetricLimbPriorRecoversTheFarThighLength() {
        let (frames, _, _, _) = synthetic(noisePx: 1.0, seed: 17)
        var starved = frames
        for i in starved.indices where i % 9 != 0 {
            starved[i].points2D[Body2DPoint.leftKnee] = nil
        }
        func thigh(_ symmetric: Bool) -> (left: Double, right: Double) {
            var o = options(.statedHeight(metres: height))
            o.symmetricLimbPrior = symmetric
            let r = BodySkeletonFit.fit(timeline: timeline(starved), options: o)
            let l = r.bones.first { $0.name == "thighLeft" }!.metres
            let rr = r.bones.first { $0.name == "thighRight" }!.metres
            return (l, rr)
        }
        let on = thigh(true), off = thigh(false)
        XCTAssertEqual(on.left, on.right, accuracy: 1e-6, "the prior makes the two thighs one bone")
        // The slack is the fit's own resolution on this synthetic, not a fudge: the 2-D points carry
        // 1 px of noise and the thigh spans ~150 px of a 0.46 m bone, so a pixel is about 3 mm and
        // any difference below that is the noise, not the prior. Comparing at 1e-9 made this a coin
        // flip — iteration 5's depth-smoothness change moved the two by 0.08 mm and flipped it.
        let truth = 0.245 * height
        XCTAssertLessThan(abs(on.left - truth), abs(off.left - truth) + 0.003,
                          "the symmetric thigh \(on.left) m must be no further from the truth than the free one \(off.left) m, to within the fit's own 3 mm resolution here")
        XCTAssertLessThan(abs(on.left - truth) / truth, 0.05,
                          "and it must still be within 5 % of the true thigh: \(on.left) m against \(truth) m")
    }

    func testSymmetricPriorIsDeclaredNotHidden() {
        let (frames, _, _, _) = synthetic(noisePx: 0)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        XCTAssertFalse(r.symmetricBones.isEmpty)
        XCTAssertTrue(r.notes.contains { $0.contains("symmetric-limb prior") && $0.contains("prior, not a measurement") })
    }

    /// The feet are at the bottom of the frame on a side view. A clipped ankle is reported *at* the
    /// border, so the ankle-to-nose span is short and the metres-per-pixel would come out too large.
    func testClippedAnklesRefuseTheHeightScaleWithTheReason() {
        let (frames, _, _, _) = synthetic(noisePx: 0)
        var clipped = frames
        for i in clipped.indices {
            for name in [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle] {
                guard let p = clipped[i].points2D[name] else { continue }
                clipped[i].points2D[name] = BodyPoint2D(name: name, u: p.u, v: 1079, confidence: p.confidence)
            }
        }
        let r = BodySkeletonFit.fit(timeline: timeline(clipped), options: options(.statedHeight(metres: height)))
        XCTAssertNil(r.metresPerPixelAtBody.value)
        XCTAssertTrue(r.metresPerPixelAtBody.unavailableReason!.contains("cut off"),
                      "reason was: \(r.metresPerPixelAtBody.unavailableReason!)")
        // The stated height is still known — it was stated. Only the pixel span is refused.
        XCTAssertEqual(r.standingHeightMetres.value!, height, accuracy: 1e-9)
    }

    func testUnclippedAnklesStillScale() {
        let (frames, _, _, _) = synthetic(noisePx: 0)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        XCTAssertNotNil(r.metresPerPixelAtBody.value)
    }

    /// A 3-D request run on every third frame must still seed every frame's depth sign, and the fit
    /// must say that it held the sign across the gaps rather than pretending it measured them.
    func testDecimatedDepthSeedIsHeldAcrossTheGapAndSaidSo() {
        let (frames, _, _, _) = synthetic(noisePx: 1.0, seed: 23)
        let seeded = withNeck(frames, seedEvery: 3)
        var o = options(.statedHeight(metres: height))
        o.depthSeedHoldSeconds = 0.10           // the frames are 1/120 s apart
        let r = BodySkeletonFit.fit(timeline: timeline(seeded), options: o)
        XCTAssertTrue(r.notes.contains { $0.contains("took the sign from a neighbouring frame") },
                      "notes were: \(r.notes)")
        XCTAssertTrue(r.notes.contains { $0.contains("depth initialised from Vision") && $0.contains("/\(frames.count) frames") })
    }

    func testDepthSeedHoldOfZeroSecondsSeedsOnlyTheFramesThatCarryA3DBody() {
        let (frames, _, _, _) = synthetic(noisePx: 0)
        var o = options(.statedHeight(metres: height))
        o.depthSeedHoldSeconds = 0
        let r = BodySkeletonFit.fit(timeline: timeline(withNeck(frames, seedEvery: 3)), options: o)
        XCTAssertFalse(r.notes.contains { $0.contains("took the sign from a neighbouring frame") })
    }

    func testConfidenceWeightingPullsTowardTheConfidentPoint() {
        let (frames, _, _, _) = synthetic(noisePx: 0)
        // Push the right wrist 30 px away on half the frames and mark those points barely confident.
        var noisy = frames
        for i in noisy.indices where i % 2 == 0 {
            guard let p = noisy[i].points2D[Body2DPoint.rightWrist] else { continue }
            noisy[i].points2D[Body2DPoint.rightWrist] = BodyPoint2D(name: p.name, u: p.u + 30, v: p.v, confidence: 0.31)
        }
        func wristError(_ weighted: Bool) -> Double {
            var o = options(.statedHeight(metres: height))
            o.confidenceWeightedObservations = weighted
            let r = BodySkeletonFit.fit(timeline: timeline(noisy), options: o)
            var errs: [Double] = []
            for (f, g) in zip(frames, r.timeline.frames) {
                guard let truth = f.points2D[Body2DPoint.rightWrist],
                      let j = g.joints3D[Body2DPoint.rightWrist], let u = j.imageU, let v = j.imageV else { continue }
                errs.append(simd_length(SIMD2(u, v) - truth.uv))
            }
            return Stats.median(errs)
        }
        XCTAssertLessThan(wristError(true), wristError(false) + 1e-9,
                          "down-weighting the unconfident, displaced wrist must not make the fit worse")
    }

    func testJointCoverageIsReportedByTheFit() {
        let (frames, _, _, _) = synthetic(noisePx: 1.0, seed: 29)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        let byName = Dictionary(uniqueKeysWithValues: r.jointCoverage.map { ($0.name, $0) })
        XCTAssertEqual(byName[Body2DPoint.rightWrist]?.seenFraction, 1.0)
        XCTAssertEqual(byName[Body2DPoint.neck]?.framesSeen, 0, "this synthetic has no neck point")
        XCTAssertNotNil(byName[Body2DPoint.rightElbow]?.jitterPixels.value)
    }

    // MARK: - iteration 4: bone lengths through foreshortening, and bones that stay one length

    /// A standing shooter whose right arm — elbow bent 30° — sweeps in yaw from `yawDegrees.lowerBound`
    /// to `.upperBound` (0° is frontoparallel, −90° points straight at the camera). The bone fractions
    /// are deliberately **not** Winter's, so a fit that recovers them cannot have taken them from a prior.
    /// `seed3D` supplies what the real pipeline has from Vision's 3-D request: the front/back
    /// *sign* of every joint's depth against the pelvis (the fit uses nothing else from it).
    func swingingArm(upperArmFraction: Double, forearmFraction: Double, yawDegrees: ClosedRange<Double>,
                     n: Int = 60, noisePx: Double = 1.0, seed: UInt64 = 5, seed3D: Bool = true)
        -> (frames: [BodyFrame], upperArm: Double, forearm: Double) {
        var rng = SeededRNG(seed: seed)
        let upperArm = upperArmFraction * height, forearm = forearmFraction * height
        let shoulderHalf = 0.129 * height, hipHalf = 0.096 * height
        let trunk = 0.288 * height, thigh = 0.245 * height, shin = 0.246 * height
        var frames: [BodyFrame] = []
        for i in 0..<n {
            let s = Double(i) / Double(n - 1)
            let yaw = Angle.radians(yawDegrees.lowerBound + (yawDegrees.upperBound - yawDegrees.lowerBound) * s)
            let hipY = 0.53 * height
            func P(_ x: Double, _ up: Double, _ z: Double) -> SIMD3<Double> { SIMD3(x, -up, depth + z) }
            let lHip = P(-hipHalf, hipY, 0), rHip = P(hipHalf, hipY, 0)
            let lSh = P(-shoulderHalf, hipY + trunk, 0), rSh = P(shoulderHalf, hipY + trunk, 0)
            let nose = P(0, hipY + trunk + 0.112 * height, 0.02)
            let lKnee = P(-hipHalf, hipY - thigh, 0.02), rKnee = P(hipHalf, hipY - thigh, 0.02)
            let lAnk = P(-hipHalf, hipY - thigh - shin, 0), rAnk = P(hipHalf, hipY - thigh - shin, 0)
            // Camera frame: +x right, +y down, +z away. Upper arm 20° above horizontal, forearm 50°.
            func dir(_ elevation: Double) -> SIMD3<Double> {
                SIMD3(cos(yaw) * cos(elevation), -sin(elevation), sin(yaw) * cos(elevation))
            }
            let rElbow = rSh + dir(Angle.radians(20)) * upperArm
            let rWrist = rElbow + dir(Angle.radians(50)) * forearm
            // The guide arm mirrors the same yaw (x negated), so it is foreshortened exactly as much:
            // a frontoparallel far arm would hand the near arm its length through the mirrored pair.
            func mirrored(_ d: SIMD3<Double>) -> SIMD3<Double> { SIMD3(-d.x, d.y, d.z) }
            let lElbow = lSh + mirrored(dir(Angle.radians(20))) * upperArm
            let lWrist = lElbow + mirrored(dir(Angle.radians(50))) * forearm
            let named: [(String, SIMD3<Double>)] = [
                (Body2DPoint.nose, nose), (Body2DPoint.leftShoulder, lSh), (Body2DPoint.rightShoulder, rSh),
                (Body2DPoint.leftElbow, lElbow), (Body2DPoint.rightElbow, rElbow),
                (Body2DPoint.leftWrist, lWrist), (Body2DPoint.rightWrist, rWrist),
                (Body2DPoint.leftHip, lHip), (Body2DPoint.rightHip, rHip),
                (Body2DPoint.leftKnee, lKnee), (Body2DPoint.rightKnee, rKnee),
                (Body2DPoint.leftAnkle, lAnk), (Body2DPoint.rightAnkle, rAnk),
            ]
            var pts: [String: BodyPoint2D] = [:]
            var js: [String: BodyJoint3D] = [:]
            let name3D: [String: String] = [Body2DPoint.nose: Body3DJoint.centerHead]
            for (name, p) in named {
                let u = K.fx * p.x / p.z + K.cx + (noisePx > 0 ? rng.gaussian(sd: noisePx) : 0)
                let v = K.fy * p.y / p.z + K.cy + (noisePx > 0 ? rng.gaussian(sd: noisePx) : 0)
                pts[name] = BodyPoint2D(name: name, u: u, v: v, confidence: 0.9)
                if seed3D {
                    // Vision's camera frame: +y up, +z toward the camera — the pinhole z negated.
                    let k = name3D[name] ?? name
                    js[k] = BodyJoint3D(name: k, position: .zero, cameraPosition: SIMD3(p.x, -p.y, -p.z), imageU: nil, imageV: nil)
                }
            }
            if seed3D {
                let root = (lHip + rHip) / 2
                js[Body3DJoint.root] = BodyJoint3D(name: Body3DJoint.root, position: .zero, cameraPosition: SIMD3(root.x, -root.y, -root.z), imageU: nil, imageV: nil)
            }
            frames.append(BodyFrame(frameIndex: i, fileTime: Double(i) / 30, realTime: Double(i) / 120,
                                    joints3D: js, points2D: pts, hands: []))
        }
        return (frames, upperArm, forearm)
    }

    func bone(_ r: BodySkeletonFitResult, _ name: String) -> BodyBoneLength { r.bones.first { $0.name == name }! }

    /// Per-frame fitted length of one bone, over the frames where both ends were observed.
    func fittedLengths(_ r: BodySkeletonFitResult, _ a: String, _ b: String) -> [Double] {
        r.timeline.frames.compactMap { f in
            guard let pa = f.joints3D[a]?.cameraPosition, let pb = f.joints3D[b]?.cameraPosition else { return nil }
            return simd_length(pa - pb)
        }
    }

    /// The arm swings through the image plane, so the longest projection *is* the bone: both
    /// non-population lengths come back within 3 % with the prior off, from the pixels alone.
    func testSwingingArmRecoversNonPopulationLengthsWithin3PercentFromProjection() {
        let (frames, upperArm, forearm) = swingingArm(upperArmFraction: 0.205, forearmFraction: 0.125,
                                                      yawDegrees: -80...60)
        var o = options(.statedHeight(metres: height))
        o.limbLengthPriorFromStature = false
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: o)
        XCTAssertEqual(bone(r, "upperArmRight").metres, upperArm, accuracy: 0.03 * upperArm, "upper arm \(bone(r, "upperArmRight").metres) vs \(upperArm)")
        XCTAssertEqual(bone(r, "forearmRight").metres, forearm, accuracy: 0.03 * forearm, "forearm \(bone(r, "forearmRight").metres) vs \(forearm)")
        XCTAssertEqual(bone(r, "upperArmRight").source, "projection floor")
        XCTAssertLessThan(r.reprojectionRMSPixels.value!, 2.0)
    }

    /// With the prior on, a bone the pixels measured *longer* than the population keeps its
    /// measurement; one measured shorter is raised to the population length and says so. The
    /// asymmetry is deliberate: a too-long bone hides in depth at no pixel cost, a too-short one
    /// cannot reproject — and the label is what keeps it honest.
    func testStaturePriorIsAFlooredDeclaredChoice() {
        let (frames, upperArm, _) = swingingArm(upperArmFraction: 0.205, forearmFraction: 0.125,
                                                yawDegrees: -80...60)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        let ua = bone(r, "upperArmRight"), fa = bone(r, "forearmRight")
        XCTAssertEqual(ua.metres, upperArm, accuracy: 0.03 * upperArm)
        XCTAssertEqual(ua.source, "projection floor")
        XCTAssertEqual(fa.metres, 0.146 * height, accuracy: 0.02 * height, "the short forearm is raised to Winter's 0.146 H")
        XCTAssertTrue(fa.source?.hasPrefix("anthropometric prior") == true, "source: \(fa.source ?? "nil")")
        XCTAssertTrue(r.notes.contains { $0.contains("forearm") && $0.contains("prior, not a measurement") })
    }

    /// The near-side view: the arm never comes within 45° of the image plane, so its longest
    /// projection under-reads by ≥ 25 %. The prior is what closes that; without it the arm is short.
    func testArmThatNeverReachesTheImagePlaneTakesThePriorAndIsShortWithoutIt() {
        let (frames, upperArm, _) = swingingArm(upperArmFraction: 0.186, forearmFraction: 0.146,
                                                yawDegrees: -85...(-45))
        var off = options(.statedHeight(metres: height)); off.limbLengthPriorFromStature = false
        let rOff = BodySkeletonFit.fit(timeline: timeline(frames), options: off)
        XCTAssertLessThan(bone(rOff, "upperArmRight").metres, 0.90 * upperArm, "floor-only must under-read here: \(bone(rOff, "upperArmRight").metres) vs \(upperArm)")
        let rOn = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        XCTAssertEqual(bone(rOn, "upperArmRight").metres, upperArm, accuracy: 0.03 * upperArm)
        XCTAssertTrue(bone(rOn, "upperArmRight").source?.hasPrefix("anthropometric prior") == true)
        // And the reprojection does not pay for the longer bone: it goes into depth.
        XCTAssertLessThan(rOn.reprojectionRMSPixels.value!, rOff.reprojectionRMSPixels.value! + 0.5)
    }

    /// The user's report, as a test. An arm swinging through foreshortening — the shot's own
    /// drive-up, where the projected upper arm loses a fifth of its length — must keep **one**
    /// length frame to frame, not just on average: measured on 36 real free throws, the old fit's
    /// drawn upper arm ran 0.89–1.13 of its own median and read shortest at the release, which is
    /// what "the arms were short and did not follow the body" is.
    func testSwingingArmKeepsOneLengthFrameToFrameThroughForeshortening() {
        let (frames, upperArm, forearm) = swingingArm(upperArmFraction: 0.186, forearmFraction: 0.146,
                                                      yawDegrees: -85...10)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        for (a, b, truth, what) in [(Body2DPoint.rightShoulder, Body2DPoint.rightElbow, upperArm, "upper arm"),
                                    (Body2DPoint.rightElbow, Body2DPoint.rightWrist, forearm, "forearm")] {
            let ls = fittedLengths(r, a, b)
            XCTAssertGreaterThan(ls.count, 50)
            let worst = ls.map { abs($0 - truth) / truth }.max()!
            XCTAssertLessThan(worst, 0.03, "\(what): worst frame is \(String(format: "%.1f", 100 * worst)) % from the true length")
        }
        XCTAssertLessThan(r.reprojectionRMSPixels.value!, 2.5)
    }

    /// "One skeleton per shot" has to be true frame by frame, not just in the summary: every limb
    /// bone's per-frame fitted length stays within 3 % of the skeleton's length.
    func testLimbBonesStayOneLengthFrameToFrame() {
        let (frames, _, _, _) = synthetic(noisePx: 1.5, seed: 11)
        let r = BodySkeletonFit.fit(timeline: timeline(frames), options: options(.statedHeight(metres: height)))
        for (name, a, b) in [("upperArmRight", Body2DPoint.rightShoulder, Body2DPoint.rightElbow),
                             ("forearmRight", Body2DPoint.rightElbow, Body2DPoint.rightWrist),
                             ("thighLeft", Body2DPoint.leftHip, Body2DPoint.leftKnee)] {
            let L = bone(r, name).metres
            let worst = fittedLengths(r, a, b).map { abs($0 - L) / L }.max()!
            XCTAssertLessThan(worst, 0.03, "\(name): worst per-frame deviation \(100 * worst) %")
        }
        XCTAssertLessThan(r.reprojectionRMSPixels.value!, 2.5)
    }
}
