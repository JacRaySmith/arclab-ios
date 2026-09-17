import XCTest
import simd
@testable import ShotGeometry

/// The 3-D form model: one shot in the shooter's own frame on a phase-normalised clock, many shots
/// averaged into a block's form, and the two comparisons (shot against block, block against block).
///
/// The skeletons here are synthetic and exactly known, so every assertion is against a number that
/// was put in on purpose. Camera space is Vision's: +x camera-right, +y up, +z toward the camera.
final class FormModelTests: XCTestCase {

    // MARK: - A synthetic shot

    /// A 1.8 m figure facing camera-right (so the rim is at +x), dipping and then raising the arm.
    /// `tau` is the normalised progress through the shot, so two clips of different tempo can be
    /// built from exactly the same shape.
    ///
    /// The body's left–right axis is camera **z**, i.e. depth — the arrangement that makes the far
    /// side of the body invisible, which is the case the symmetry rule exists for.
    static func cameraSkeleton(tau: Double, armFold: Double? = nil) -> [String: SIMD3<Double>] {
        let dip = 0.15 * exp(-pow((tau - 0.35) / 0.15, 2))
        let hipY = 0.90 - dip
        // The legs are rigid, as a fitted skeleton's are since iteration 4: the dip bends the knee
        // forward, it does not shorten the thigh and the shin. Two equal 0.45 m links from the hip
        // down to an ankle on the floor, so the knee sits on the hip–ankle mid-height and steps
        // forward by however much the dip asks for.
        let legLink = 0.45
        let kneeY = hipY / 2
        let kneeX = max(0, legLink * legLink - kneeY * kneeY).squareRoot()
        let shoulderY = hipY + 0.55
        let noseY = hipY + 0.77
        let halfShoulder = 0.20, halfHip = 0.14           // along camera z: the body's own left–right
        // The shooting arm swings from hanging down to overhead, and unfolds as it goes.
        let thetaE = Angle.radians(170 - 150 * tau)        // from vertical, in the camera x–y plane
        let fold = armFold ?? (100 - 90 * tau)             // the angle the elbow is folded through
        let thetaW = thetaE - Angle.radians(fold)
        func dir(_ t: Double) -> SIMD3<Double> { SIMD3(sin(t), cos(t), 0) }

        let rShoulder = SIMD3(0.0, shoulderY, halfShoulder)
        let lShoulder = SIMD3(0.0, shoulderY, -halfShoulder)
        let rElbow = rShoulder + 0.30 * dir(thetaE)
        let rWrist = rElbow + 0.27 * dir(thetaW)
        let lElbow = lShoulder + 0.30 * dir(Angle.radians(165))
        let lWrist = lElbow + 0.27 * dir(Angle.radians(150))
        return [
            Body2DPoint.nose: SIMD3(0.02, noseY, 0),
            Body2DPoint.rightShoulder: rShoulder, Body2DPoint.leftShoulder: lShoulder,
            Body2DPoint.rightElbow: rElbow, Body2DPoint.leftElbow: lElbow,
            Body2DPoint.rightWrist: rWrist, Body2DPoint.leftWrist: lWrist,
            Body2DPoint.rightHip: SIMD3(0, hipY, halfHip), Body2DPoint.leftHip: SIMD3(0, hipY, -halfHip),
            Body2DPoint.rightKnee: SIMD3(kneeX, kneeY, halfHip), Body2DPoint.leftKnee: SIMD3(kneeX, kneeY, -halfHip),
            Body2DPoint.rightAnkle: SIMD3(0, 0, halfHip), Body2DPoint.leftAnkle: SIMD3(0, 0, -halfHip),
        ]
    }

    /// The anchors a clip is built on, in real seconds.
    struct Anchors { var set: Double, dip: Double, release: Double, follow: Double }

    /// `tau` → real time, the same piecewise-linear map `ShotForm` inverts.
    static func realTime(_ tau: Double, _ a: Anchors) -> Double {
        let ts = [0.0: a.set, 0.35: a.dip, 0.75: a.release, 1.0: a.follow]
        let keys = ts.keys.sorted()
        for i in 1..<keys.count where tau <= keys[i] + 1e-12 {
            let lo = keys[i - 1], hi = keys[i]
            let f = (tau - lo) / (hi - lo)
            return ts[lo]! + f * (ts[hi]! - ts[lo]!)
        }
        return a.follow
    }

    /// A timeline of fitted frames, densely sampled so the resampler's linear interpolation is exact
    /// to well under a millimetre.
    static func timeline(_ a: Anchors, steps: Int = 400, armFold: Double? = nil,
                         hide: Set<String> = [], offset: SIMD3<Double> = .zero,
                         jointOffsets: [String: SIMD3<Double>] = [:],
                         scaleBody: Double = 1.0) -> BodyTimeline {
        var frames: [BodyFrame] = []
        for i in 0...steps {
            let tau = Double(i) / Double(steps)
            let t = realTime(tau, a)
            let sk = cameraSkeleton(tau: tau, armFold: armFold)
            var j3: [String: BodyJoint3D] = [:]
            var p2: [String: BodyPoint2D] = [:]
            for (name, p) in sk {
                let q = scaleBody * p + offset + (jointOffsets[name] ?? .zero)
                j3[name] = BodyJoint3D(name: name, position: q, cameraPosition: q)
                // The 2-D points are what "seen" means. A hidden joint still has a fitted position
                // (the solver puts one there) but no pixels of its own — exactly the case the form
                // must refuse to read a number off.
                if !hide.contains(name) {
                    p2[name] = BodyPoint2D(name: name, u: 960 + 400 * q.x, v: 540 - 400 * q.y, confidence: 0.9)
                }
            }
            frames.append(BodyFrame(frameIndex: i, fileTime: t, realTime: t, joints3D: j3, points2D: p2, hands: []))
        }
        return BodyTimeline(frames: frames, timeScale: 1, imageWidth: 1920, imageHeight: 1080,
                            everyNthFrame: 1, decodedFrames: frames.count, analysedFrames: frames.count,
                            wallSeconds: 0.1, notes: [])
    }

    static func form(_ a: Anchors, options: FormOptions = defaultOptions(), armFold: Double? = nil,
                     hide: Set<String> = [], offset: SIMD3<Double> = .zero,
                     jointOffsets: [String: SIMD3<Double>] = [:], measuredScale: Bool = false,
                     shotID: Int = 1, follow: Bool = true) -> ShotForm {
        let tl = timeline(a, armFold: armFold, hide: hide, offset: offset, jointOffsets: jointOffsets)
        let (f, why) = ShotForm.make(timeline: tl, scaleIsMeasured: measuredScale,
                                     scaleNote: measuredScale ? "the shooter's stated standing height" : "no scale was supplied",
                                     setRealTime: a.set, dipRealTime: a.dip, releaseRealTime: a.release,
                                     followThroughRealTime: follow ? a.follow : nil,
                                     shootingSide: "right", shotID: shotID, options: options)
        XCTAssertNil(why, "the synthetic shot should produce a form")
        return f!
    }

    static func defaultOptions() -> FormOptions {
        var o = FormOptions()
        o.facing = .rimImageColumn(rimU: 1900)     // the rim is to camera-right, so +x is camera-right
        return o
    }

    let a1 = Anchors(set: 0.20, dip: 0.60, release: 1.20, follow: 1.60)
    /// The same shot at half the tempo: every phase twice as long.
    let a2 = Anchors(set: 1.00, dip: 1.80, release: 3.00, follow: 3.80)

    func index(_ j: String) -> Int { FormSkeleton.index(of: j)! }


    // MARK: - A rigid figure: fixed bones, random angles

    /// The figure the rigid mean is defined on. Every bone is a **constant put in by hand** and only
    /// the joint angles move, so a mean form that averages bone directions and re-integrates them
    /// has to hand these numbers back. `rootToShoulder` and `rootToNose` are single edges of
    /// `FormSkeleton.tree`, and with the shoulders square on a rigid torso they are constants too.
    enum RigidFigure {
        static let halfHip = 0.14, thigh = 0.45, shin = 0.45
        static let trunk = 0.50, halfShoulder = 0.20, noseAbove = 0.22
        static let upperArm = 0.30, forearm = 0.27
        static let rootToShoulder = (trunk * trunk + halfShoulder * halfShoulder).squareRoot()
        static let rootToNose = trunk + noseAbove
        /// Child joint → the length of the bone that reaches it from its parent in the tree.
        static let lengths: [String: Double] = [
            Body2DPoint.leftHip: halfHip, Body2DPoint.rightHip: halfHip,
            Body2DPoint.leftKnee: thigh, Body2DPoint.rightKnee: thigh,
            Body2DPoint.leftAnkle: shin, Body2DPoint.rightAnkle: shin,
            Body2DPoint.leftShoulder: rootToShoulder, Body2DPoint.rightShoulder: rootToShoulder,
            Body2DPoint.nose: rootToNose,
            Body2DPoint.leftElbow: upperArm, Body2DPoint.rightElbow: upperArm,
            Body2DPoint.leftWrist: forearm, Body2DPoint.rightWrist: forearm,
        ]
    }

    /// One shot's joint angles: a seeded sine per channel, so each shot's angles are its own and
    /// every one of them is smooth in tau. Smooth matters — the resampler lerps between frames, and
    /// a lerp between two unrelated poses is the one thing that could shorten a bone in the *input*.
    struct AngleChannels {
        var freq: [Double] = [], phase: [Double] = []
        init(seed: UInt64, count: Int) {
            var state = seed &* 6364136223846793005 &+ 1442695040888963407
            func next() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / Double(UInt64(1) << 53)
            }
            for _ in 0..<count { freq.append(next()); phase.append(next()) }
        }
        /// Channel `k` at `tau`, in 0…1.
        func unit(_ k: Int, _ tau: Double) -> Double {
            0.5 + 0.5 * sin(2 * Double.pi * (0.5 + 1.5 * freq[k]) * tau + 2 * Double.pi * phase[k])
        }
    }

    /// A unit vector `theta` from `axis`, turned `phi` about it.
    static func direction(about axis: SIMD3<Double>, theta: Double, phi: Double) -> SIMD3<Double> {
        let a = simd_normalize(axis)
        var t = SIMD3<Double>(1, 0, 0)
        if abs(simd_dot(a, t)) > 0.9 { t = SIMD3(0, 0, 1) }
        let u = simd_normalize(simd_cross(a, t)), v = simd_cross(a, u)
        return cos(theta) * a + sin(theta) * (cos(phi) * u + sin(phi) * v)
    }

    static func rigidSkeleton(tau: Double, _ c: AngleChannels) -> [String: SIMD3<Double>] {
        typealias F = RigidFigure
        func dir(_ k: Int, about axis: SIMD3<Double>, spread: Double) -> SIMD3<Double> {
            direction(about: axis, theta: spread * c.unit(k, tau), phi: 2 * Double.pi * c.unit(k + 1, tau))
        }
        let up = dir(0, about: SIMD3(0, 1, 0), spread: Angle.radians(25))
        let side = simd_normalize(simd_cross(up, SIMD3(1, 0, 0)))
        let midHip = SIMD3(0.0, 0.90, 0.0)
        let shoulderCentre = midHip + F.trunk * up
        let rHip = midHip + F.halfHip * side, lHip = midHip - F.halfHip * side
        let rShoulder = shoulderCentre + F.halfShoulder * side, lShoulder = shoulderCentre - F.halfShoulder * side
        let rKnee = rHip + F.thigh * dir(2, about: -up, spread: Angle.radians(50))
        let rAnkle = rKnee + F.shin * dir(4, about: -up, spread: Angle.radians(50))
        let lKnee = lHip + F.thigh * dir(6, about: -up, spread: Angle.radians(50))
        let lAnkle = lKnee + F.shin * dir(8, about: -up, spread: Angle.radians(50))
        let rElbow = rShoulder + F.upperArm * dir(10, about: -up, spread: Angle.radians(140))
        let rWrist = rElbow + F.forearm * dir(12, about: rElbow - rShoulder, spread: Angle.radians(120))
        let lElbow = lShoulder + F.upperArm * dir(14, about: -up, spread: Angle.radians(140))
        let lWrist = lElbow + F.forearm * dir(16, about: lElbow - lShoulder, spread: Angle.radians(120))
        return [
            Body2DPoint.nose: shoulderCentre + F.noseAbove * up,
            Body2DPoint.rightShoulder: rShoulder, Body2DPoint.leftShoulder: lShoulder,
            Body2DPoint.rightElbow: rElbow, Body2DPoint.leftElbow: lElbow,
            Body2DPoint.rightWrist: rWrist, Body2DPoint.leftWrist: lWrist,
            Body2DPoint.rightHip: rHip, Body2DPoint.leftHip: lHip,
            Body2DPoint.rightKnee: rKnee, Body2DPoint.leftKnee: lKnee,
            Body2DPoint.rightAnkle: rAnkle, Body2DPoint.leftAnkle: lAnkle,
        ]
    }

    /// One shot of the rigid figure, in metres (a stated height, so no divisor stands between the
    /// lengths put in and the lengths the form carries).
    static func rigidForm(seed: UInt64, shotID: Int) -> ShotForm {
        let a = Anchors(set: 0.20, dip: 0.60, release: 1.20, follow: 1.60)
        let c = AngleChannels(seed: seed, count: 18)
        let steps = 384
        var frames: [BodyFrame] = []
        for i in 0...steps {
            let tau = Double(i) / Double(steps)
            let t = realTime(tau, a)
            var j3: [String: BodyJoint3D] = [:], p2: [String: BodyPoint2D] = [:]
            for (name, p) in rigidSkeleton(tau: tau, c) {
                j3[name] = BodyJoint3D(name: name, position: p, cameraPosition: p)
                p2[name] = BodyPoint2D(name: name, u: 960 + 400 * p.x, v: 540 - 400 * p.y, confidence: 0.9)
            }
            frames.append(BodyFrame(frameIndex: i, fileTime: t, realTime: t, joints3D: j3, points2D: p2, hands: []))
        }
        let tl = BodyTimeline(frames: frames, timeScale: 1, imageWidth: 1920, imageHeight: 1080,
                              everyNthFrame: 1, decodedFrames: frames.count, analysedFrames: frames.count,
                              wallSeconds: 0.1, notes: [])
        let (f, why) = ShotForm.make(timeline: tl, scaleIsMeasured: true,
                                     scaleNote: "the shooter's stated standing height",
                                     setRealTime: a.set, dipRealTime: a.dip, releaseRealTime: a.release,
                                     followThroughRealTime: a.follow, shootingSide: "right",
                                     shotID: shotID, options: defaultOptions())
        XCTAssertNil(why, "the rigid synthetic shot should produce a form")
        return f!
    }

    // MARK: - The body frame

    func testOriginIsTheMidHipAtTheSetPoint() {
        let f = Self.form(a1)
        let s = f.sample(at: .set)!
        let l = s.position(index(Body2DPoint.leftHip))!, r = s.position(index(Body2DPoint.rightHip))!
        let mid = (l + r) / 2
        XCTAssertEqual(simd_length(mid), 0, accuracy: 1e-6, "the mid-hip at the set point is the origin")
    }

    func testAxesAreRimForwardAndUp() {
        let f = Self.form(a1)
        let s = f.sample(at: .set)!
        let nose = s.position(index(Body2DPoint.nose))!
        let ankle = s.position(index(Body2DPoint.rightAnkle))!
        // z is up: the nose is above the origin, the ankle below it.
        XCTAssertGreaterThan(nose.z, 0.3)
        XCTAssertLessThan(ankle.z, -0.3)
        // x is toward the rim, which the synthetic camera puts at +x: the nose leads the hips by 2 cm.
        XCTAssertGreaterThan(nose.x, 0)
        // y is the body's own left–right: the two hips straddle it.
        let l = s.position(index(Body2DPoint.leftHip))!, r = s.position(index(Body2DPoint.rightHip))!
        XCTAssertGreaterThan(abs(l.y - r.y), 0.1)
        XCTAssertEqual(l.z, r.z, accuracy: 1e-6)
    }

    func testTheRimColumnFlipsTheForwardAxis() {
        var o = Self.defaultOptions()
        o.facing = .rimImageColumn(rimU: 0)        // the rim is now to camera-left
        let f = Self.form(a1, options: o)
        let nose = f.sample(at: .set)!.position(index(Body2DPoint.nose))!
        XCTAssertLessThan(nose.x, 0, "with the rim on the other side the forward axis flips")
        XCTAssertTrue(f.facingNote.contains("left"))
    }

    func testTheFitsOwnNameForTheHeadIsFound() {
        // `BodySkeletonFit` files the nose under the 3-D model's `centerHead`. A form that looked
        // only for "nose" lost the head and then refused the whole shot for want of a height span —
        // which is exactly what happened on the first real 240 fps window.
        var tl = Self.timeline(a1)
        tl.frames = tl.frames.map { f in
            var g = f
            if let nose = g.joints3D[Body2DPoint.nose] {
                g.joints3D[Body3DJoint.centerHead] = nose
                g.joints3D[Body2DPoint.nose] = nil
            }
            return g
        }
        let (f, why) = ShotForm.make(timeline: tl, scaleIsMeasured: false, scaleNote: "test",
                                     setRealTime: a1.set, dipRealTime: a1.dip,
                                     releaseRealTime: a1.release, followThroughRealTime: a1.follow,
                                     options: Self.defaultOptions())
        XCTAssertNil(why)
        XCTAssertNotNil(f?.sample(at: .release)?.position(index(Body2DPoint.nose)))
    }

    // MARK: - Units

    func testWithoutAHeightTheFormIsInShooterHeightsAndSaysSo() {
        let f = Self.form(a1)
        XCTAssertEqual(f.unit, .shooterHeights)
        XCTAssertTrue(f.unitNote.contains("shooter heights"))
        XCTAssertTrue(f.unitNote.contains("ratios, not metres"))
        // The figure is 1.8 m tall and the form is unit-height: the ankle-to-nose span must come out
        // at Winter's 0.891 of a standing height, whatever the metres were.
        let s = f.sample(at: .set)!
        let nose = s.position(index(Body2DPoint.nose))!, ankle = s.position(index(Body2DPoint.rightAnkle))!
        XCTAssertEqual(simd_length(nose - ankle), 0.891, accuracy: 0.005)
    }

    func testWithAStatedHeightTheFormIsInMetres() {
        let f = Self.form(a1, measuredScale: true)
        XCTAssertEqual(f.unit, .metres)
        let s = f.sample(at: .set)!
        let nose = s.position(index(Body2DPoint.nose))!, ankle = s.position(index(Body2DPoint.rightAnkle))!
        // The synthetic figure's own ankle-to-nose distance, in the metres the fit was handed.
        XCTAssertEqual(simd_length(nose - ankle), 1.67, accuracy: 0.02)
    }

    // MARK: - The normalised clock

    func testTwoTemposAlignOnTheNormalisedAxis() {
        let fast = Self.form(a1), slow = Self.form(a2)
        XCTAssertEqual(fast.samples.count, slow.samples.count)
        var worst = 0.0
        for (x, y) in zip(fast.samples, slow.samples) {
            XCTAssertEqual(x.t, y.t, accuracy: 1e-9)
            for j in 0..<fast.jointCount {
                guard let p = x.position(j), let q = y.position(j) else { continue }
                worst = max(worst, simd_length(p - q))
            }
        }
        XCTAssertLessThan(worst, 1e-3, "the same shape at half the tempo lands on the same normalised positions")
    }

    func testTheRealDurationsSurviveTheNormalisation() {
        let fast = Self.form(a1), slow = Self.form(a2)
        XCTAssertEqual(fast.durations.dipToRelease.value!, 600, accuracy: 1e-6)
        XCTAssertEqual(slow.durations.dipToRelease.value!, 1200, accuracy: 1e-6)
        XCTAssertEqual(fast.durations.total.value!, 1400, accuracy: 1e-6)
        // And the real clock is on every sample, relative to the release.
        XCTAssertEqual(fast.sample(at: .release)!.dt, 0, accuracy: 1e-4)
        XCTAssertEqual(fast.sample(at: .dip)!.dt, -0.6, accuracy: 1e-3)
        XCTAssertEqual(slow.sample(at: .dip)!.dt, -1.2, accuracy: 1e-3)
    }

    func testAMissingFollowThroughLeavesAGapWithAReasonAndNoSamples() {
        let f = Self.form(a1, follow: false)
        XCTAssertNil(f.sample(at: .followThrough))
        XCTAssertTrue(f.samples.allSatisfy { $0.t <= 0.75 + 1e-9 }, "nothing is invented past the last anchor")
        XCTAssertEqual(f.gaps.count, 1)
        XCTAssertTrue(f.gaps[0].reason.contains("follow-through was not found"))
        XCTAssertNil(f.durations.releaseToFollowThrough.value)
        XCTAssertTrue(f.durations.releaseToFollowThrough.unavailableReason!.contains("follow-through"))
    }

    func testPhasesOutOfOrderAreRefusedNotReordered() {
        var out = Anchors(set: 0.20, dip: 0.60, release: 1.20, follow: 1.60)
        out.dip = 0.10                                   // a "dip" before the set point
        let tl = Self.timeline(a1)
        let (f, why) = ShotForm.make(timeline: tl, scaleIsMeasured: false, scaleNote: "test",
                                     setRealTime: out.set, dipRealTime: out.dip,
                                     releaseRealTime: out.release, followThroughRealTime: out.follow,
                                     options: Self.defaultOptions())
        XCTAssertNil(why)
        XCTAssertTrue(f!.warnings.contains { $0.contains("not after") })
        XCTAssertNil(f!.durations.setToDip.value)
    }

    func testTooFewFramesIsNilWithAReason() {
        var tl = Self.timeline(a1)
        tl.frames = Array(tl.frames.prefix(4))
        let (f, why) = ShotForm.make(timeline: tl, scaleIsMeasured: false, scaleNote: "test",
                                     setRealTime: a1.set, dipRealTime: a1.dip,
                                     releaseRealTime: a1.release, followThroughRealTime: a1.follow,
                                     options: Self.defaultOptions())
        XCTAssertNil(f)
        XCTAssertTrue(why!.contains("fewer than the 8"))
    }

    // MARK: - The far side of the body

    func testAnUnseenJointIsMirroredAndFlagged() {
        let hidden: Set<String> = [Body2DPoint.leftElbow, Body2DPoint.leftWrist]
        let f = Self.form(a1, hide: hidden)
        for name in hidden {
            let j = index(name)
            XCTAssertTrue(f.inferredBySymmetry[j], "\(name) was never seen, so it is inferred")
            XCTAssertEqual(f.seenFraction[j], 0, accuracy: 1e-9)
        }
        XCTAssertFalse(f.inferredBySymmetry[index(Body2DPoint.rightElbow)])
        XCTAssertTrue(f.notes.contains { $0.contains("mirrored from") && $0.contains("not measured") })
        // The mirror really is a mirror: same height, same forward position, opposite side.
        let s = f.sample(at: .release)!
        let l = s.position(index(Body2DPoint.leftElbow))!, r = s.position(index(Body2DPoint.rightElbow))!
        XCTAssertEqual(l.z, r.z, accuracy: 1e-3)
        XCTAssertEqual(l.x, r.x, accuracy: 1e-3)
        XCTAssertEqual(l.y, -r.y, accuracy: 1e-2)
    }

    func testAJointWithNoMirrorToBorrowFromIsRefusedWithAReason() {
        let f = Self.form(a1, hide: [Body2DPoint.nose])
        XCTAssertFalse(f.inferredBySymmetry[index(Body2DPoint.nose)])
        let why = f.refusedJoints[Body2DPoint.nose]
        XCTAssertNotNil(why)
        XCTAssertTrue(why!.contains("no confident joint on the other side"))
        XCTAssertNil(f.sample(at: .release)!.position(index(Body2DPoint.nose)))
    }

    func testBothSidesUnseenRefusesBoth() {
        let f = Self.form(a1, hide: [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle])
        XCTAssertNotNil(f.refusedJoints[Body2DPoint.leftAnkle])
        XCTAssertNotNil(f.refusedJoints[Body2DPoint.rightAnkle])
        XCTAssertFalse(f.inferredBySymmetry[index(Body2DPoint.leftAnkle)])
    }

    // MARK: - Angles

    func testTheElbowAngleIsTheOnePutIn() {
        // `armFold` is the angle the elbow is folded through, so the joint angle is 180° − fold.
        let f = Self.form(a1, armFold: 60)
        let s = f.sample(at: .release)!
        let theta = FormSkeleton.angles(at: s.positions)["rightElbow"]
        XCTAssertEqual(Angle.degrees(theta!), 120, accuracy: 0.5)
    }

    func testTrunkLeanIsMeasuredFromVertical() {
        let f = Self.form(a1)
        let theta = FormSkeleton.angles(at: f.sample(at: .set)!.positions)[FormSkeleton.trunkLeanName]
        XCTAssertNotNil(theta)
        XCTAssertEqual(Angle.degrees(theta!), 0, accuracy: 2, "the synthetic trunk is upright")
    }

    // MARK: - The block's form

    func testIdenticalShotsGiveZeroSpreadAndTheSameMean() {
        let forms = (1...5).map { Self.form(a1, shotID: $0) }
        let m = FormModel.build(forms: forms, label: "block")
        XCTAssertNil(m.unavailableReason)
        XCTAssertEqual(m.shots, 5)
        XCTAssertEqual(m.samples.count, forms[0].sampleCount)
        let ms = m.sample(at: .release)!, fs = forms[0].sample(at: .release)!
        for j in 0..<m.joints.count {
            guard let p = ms.position(j), let q = fs.position(j) else { continue }
            // The mean is re-integrated from the mid-hip along the block's mean bone directions, so
            // against one shot repeated it reproduces that shot to the 1e-4 the positions are rounded
            // at, accumulated down a three-bone chain — under `FormOptions.minimumSpread`, which is
            // why a spread that size is treated as none at all.
            XCTAssertEqual(simd_length(p - q), 0, accuracy: 5e-4)
            XCTAssertEqual(simd_length(ms.spread(j)!), 0, accuracy: 5e-4)
            XCTAssertLessThan(simd_length(ms.spread(j)!), FormOptions().minimumSpread)
        }
    }

    /// The rigid mean, stated as the thing it is for: shots that share a skeleton and share nothing
    /// else give a mean with **that** skeleton, on every sample, not a shorter one.
    func testShotsWithTheSameBonesAndRandomAnglesGiveAMeanWithExactlyThoseBones() {
        let forms = (1...6).map { Self.rigidForm(seed: UInt64($0), shotID: $0) }
        let m = FormModel.build(forms: forms, label: "rigid")
        XCTAssertNil(m.unavailableReason)
        XCTAssertEqual(m.unit, .metres)
        XCTAssertEqual(m.bones.count, Self.RigidFigure.lengths.count)
        // 1. The block's bone table is the figure's own lengths.
        for b in m.bones {
            guard let want = Self.RigidFigure.lengths[b.b] else { XCTFail("unexpected bone \(b.a)→\(b.b)"); continue }
            XCTAssertEqual(b.length, want, accuracy: 5e-4, "\(b.a)→\(b.b)")
            XCTAssertEqual(b.n, 6)
        }
        // 2. Every bone of the mean form is that length on *every* sample — the mean is a body at
        //    every instant, not a body on average.
        func at(_ s: FormModelSample, _ name: String) -> SIMD3<Double>? {
            guard name == FormSkeleton.root else { return FormSkeleton.index(of: name).flatMap { s.position($0) } }
            guard let l = s.position(index(Body2DPoint.leftHip)), let r = s.position(index(Body2DPoint.rightHip)) else { return nil }
            return (l + r) / 2
        }
        var worst = 0.0
        for s in m.samples {
            for b in m.bones {
                guard let p = at(s, b.a), let q = at(s, b.b) else { XCTFail("the mean lost \(b.b)"); continue }
                let want = Self.RigidFigure.lengths[b.b]!
                worst = max(worst, abs(simd_length(q - p) / want - 1))
            }
        }
        XCTAssertLessThan(worst, 0.002, String(format: "every bone of the mean form is the shooter's own length on every sample: worst %.4f %%", 100 * worst))
        // 3. The control: averaging the *positions* of the same shots — what the mean used to be —
        //    shortens the arm, which is why this test exists.
        let phase = FormPhase.release
        let here = forms.compactMap { $0.sample(at: phase) }
        func positionMean(_ j: Int) -> SIMD3<Double> {
            let xs = here.compactMap { $0.position(j) }
            return xs.reduce(.zero, +) / Double(xs.count)
        }
        let shoulder = positionMean(index(Body2DPoint.rightShoulder)), elbow = positionMean(index(Body2DPoint.rightElbow))
        XCTAssertLessThan(simd_length(elbow - shoulder), 0.97 * Self.RigidFigure.upperArm,
                          "the randomised angles must actually differ, or this test proves nothing")
    }

    func testASpreadNeedsThreeShotsAndSaysSoWhenItCannotHaveOne() {
        let m = FormModel.build(forms: [Self.form(a1, shotID: 1), Self.form(a2, shotID: 2)], label: "two")
        XCTAssertNil(m.unavailableReason)
        XCTAssertTrue(m.warnings.contains { $0.contains("every SD here is unavailable") })
        XCTAssertNil(m.sample(at: .release)!.spread(index(Body2DPoint.rightWrist)))
        XCTAssertNil(m.tempo.dipToRelease.sd.value)
        XCTAssertTrue(m.tempo.dipToRelease.sd.unavailableReason!.contains("fewer than the 3"))
    }

    func testTempoCarriesTheRealDurationsWithTheirSpread() {
        // Three tempos: dip → release of 600, 1200 and 900 ms.
        let mid = Anchors(set: 0.6, dip: 1.2, release: 2.1, follow: 2.5)
        let m = FormModel.build(forms: [Self.form(a1, shotID: 1), Self.form(a2, shotID: 2), Self.form(mid, shotID: 3)],
                                label: "tempo")
        XCTAssertEqual(m.tempo.dipToRelease.mean.value!, 900, accuracy: 1e-6)
        XCTAssertEqual(m.tempo.dipToRelease.sd.value!, 300, accuracy: 1e-6)
        XCTAssertEqual(m.tempo.dipToRelease.n, 3)
    }

    func testMixedUnitsAreRefusedNotPooled() {
        let m = FormModel.build(forms: [Self.form(a1, shotID: 1), Self.form(a1, measuredScale: true, shotID: 2)],
                                label: "mixed")
        XCTAssertNotNil(m.unavailableReason)
        XCTAssertTrue(m.unavailableReason!.contains("do not average"))
        XCTAssertFalse(m.isAvailable)
    }

    func testAJointNeverSeenInTheBlockIsMarkedInferredForTheBlock() {
        let forms = (1...4).map { Self.form(a1, hide: [Body2DPoint.leftWrist], shotID: $0) }
        let m = FormModel.build(forms: forms, label: "block")
        XCTAssertTrue(m.inferredBySymmetry[index(Body2DPoint.leftWrist)])
        XCTAssertTrue(m.notes.contains { $0.contains("draw it dashed") })
        XCTAssertEqual(m.seenFraction[index(Body2DPoint.leftWrist)], 0, accuracy: 1e-9)
        XCTAssertGreaterThan(m.seenFraction[index(Body2DPoint.rightWrist)], 0.9)
    }

    func testAnEmptyBlockIsNilWithAReason() {
        let m = FormModel.build(forms: [], label: "empty")
        XCTAssertFalse(m.isAvailable)
        XCTAssertEqual(m.unavailableReason, "no shot in this block carried a form")
    }

    // MARK: - Shot against the block

    /// Five shots whose shooting wrist sits at five known depths, so the block's spread is known
    /// exactly: offsets of −0.02 … +0.02 m along camera z have SD 0.0158 m.
    ///
    /// The *wrist* and not the whole body, on purpose: the body frame's origin is each shot's own
    /// mid-hip at its own set point, so translating a whole shot moves nothing in the form. That is
    /// the point of the frame — it compares shapes, not where the shooter stood.
    func spreadBlock(label: String = "block", extra: Double = 0) -> (FormModel, [ShotForm]) {
        let offsets = [-0.02, -0.01, 0.0, 0.01, 0.02]
        let forms = offsets.enumerated().map { i, dz in
            Self.form(a1, jointOffsets: [Body2DPoint.rightWrist: SIMD3(0, 0, dz + extra)],
                      measuredScale: true, shotID: i + 1)
        }
        return (FormModel.build(forms: forms, label: label), forms)
    }

    func testMovingAWholeShotMovesNothingInItsForm() {
        let here = Self.form(a1), there = Self.form(a1, offset: SIMD3(1.5, 0.4, -2.0))
        var worst = 0.0
        for (x, y) in zip(here.samples, there.samples) {
            for j in 0..<here.jointCount {
                guard let p = x.position(j), let q = y.position(j) else { continue }
                worst = max(worst, simd_length(p - q))
            }
        }
        XCTAssertLessThan(worst, 1e-6, "the form is where the shooter's joints are relative to themselves")
    }

    func testAShotOnTheBlocksMeanDeviatesByNothing() {
        let (m, forms) = spreadBlock()
        let c = m.compare(shot: forms[2])           // the middle shot is the mean
        XCTAssertNil(c.unavailableReason)
        let wrist = c.joints.first { $0.joint == Body2DPoint.rightWrist && $0.phase == "release" }!
        XCTAssertEqual(wrist.deviationSDs.value!, 0, accuracy: 1e-6)
    }

    func testAShotOffTheMeanIsMeasuredInTheBlocksOwnSDs() {
        let (m, _) = spreadBlock()
        // One more shot, 0.0316 m further away — exactly 2 SDs of the block's depth spread.
        let sd = Stats.sd([-0.02, -0.01, 0.0, 0.01, 0.02])
        let odd = Self.form(a1, jointOffsets: [Body2DPoint.rightWrist: SIMD3(0, 0, 2 * sd)],
                            measuredScale: true, shotID: 99)
        let c = m.compare(shot: odd)
        let wrist = c.joints.first { $0.joint == Body2DPoint.rightWrist && $0.phase == "release" }!
        // Camera z is the body's own y axis, and only that axis moved.
        XCTAssertEqual(wrist.axisSDs[1]!, -2, accuracy: 0.05)
        XCTAssertEqual(wrist.displacement.value!, 2 * sd, accuracy: 1e-3)
        XCTAssertEqual(c.ranked.first!.deviationSDs.value!, wrist.deviationSDs.value!, accuracy: 0.5)
    }

    func testTheHipsHaveNoSpreadAtTheSetPointByConstructionAndSaySo() {
        let (m, forms) = spreadBlock()
        let c = m.compare(shot: forms[0])
        let hip = c.joints.first { $0.joint == Body2DPoint.leftHip && $0.phase == "set" }!
        XCTAssertNil(hip.deviationSDs.value)
        XCTAssertTrue(hip.deviationSDs.unavailableReason!.contains("origin is the mid-hip at the set point"))
    }

    func testTooFewShotsToCompareAgainstIsNilWithAReason() {
        let m = FormModel.build(forms: [Self.form(a1, shotID: 1), Self.form(a1, shotID: 2)], label: "two")
        let c = m.compare(shot: Self.form(a1, shotID: 3))
        XCTAssertNotNil(c.unavailableReason)
        XCTAssertTrue(c.unavailableReason!.contains("needs at least 3"))
    }

    func testComparingAcrossUnitsIsRefused() {
        let (m, _) = spreadBlock()
        let c = m.compare(shot: Self.form(a1, shotID: 7))     // unit-height shot, metre block
        XCTAssertTrue(c.unavailableReason!.contains("not comparable"))
    }

    func testAngleDeviationsAreInDegreesAndSDs() {
        // A block whose elbows fold through 100° → 10°, and one shot that folds 20° further.
        let block = (1...5).map { Self.form(a1, armFold: Double($0 - 3) * 2 + 40, measuredScale: true, shotID: $0) }
        let m = FormModel.build(forms: block, label: "elbows")
        let odd = Self.form(a1, armFold: 60, measuredScale: true, shotID: 9)
        let c = m.compare(shot: odd)
        let e = c.angles.first { $0.name == "rightElbow" && $0.phase == "release" }!
        XCTAssertEqual(e.shotDegrees!, 120, accuracy: 0.5)          // 180 − 60
        XCTAssertEqual(e.modelMeanDegrees!, 140, accuracy: 0.5)     // 180 − 40
        XCTAssertNotNil(e.deviationSDs.value)
        XCTAssertLessThan(e.deviationSDs.value!, 0, "this shot's elbow is more folded than the block's")
    }

    // MARK: - Block against block

    func testTwoBlocksDifferInPooledSDs() {
        let (a, _) = spreadBlock(label: "September")
        let (b, _) = spreadBlock(label: "October", extra: 0.0316)   // 2 pooled SDs further in depth
        let d = FormModel.compare(a, with: b)
        XCTAssertNil(d.unavailableReason)
        let wrist = d.joints.first { $0.joint == Body2DPoint.rightWrist && $0.phase == "release" }!
        XCTAssertEqual(wrist.axisSDs[1]!, -2, accuracy: 0.1)
        XCTAssertEqual(wrist.displacement.value!, 0.0316, accuracy: 1e-3)
        XCTAssertEqual(d.a, "September")
        XCTAssertEqual(d.b, "October")
    }

    func testTwoBlocksInDifferentUnitsDoNotCompare() {
        let (a, _) = spreadBlock()
        let b = FormModel.build(forms: (1...4).map { Self.form(a1, shotID: $0) }, label: "no height")
        let d = FormModel.compare(a, with: b)
        XCTAssertNotNil(d.unavailableReason)
        XCTAssertTrue(d.unavailableReason!.contains("do not compare"))
    }

    func testBlockTempoDifferenceCarriesBothMeans() {
        let a = FormModel.build(forms: (1...3).map { Self.form(a1, shotID: $0) }, label: "A")
        let b = FormModel.build(forms: (1...3).map { Self.form(a2, shotID: $0) }, label: "B")
        let d = FormModel.compare(a, with: b)
        let t = d.tempo["dipToRelease"]!
        XCTAssertEqual(t.aMilliseconds.value!, 600, accuracy: 1e-6)
        XCTAssertEqual(t.bMilliseconds.value!, 1200, accuracy: 1e-6)
        XCTAssertEqual(t.differenceMilliseconds.value!, 600, accuracy: 1e-6)
        // Both blocks have zero spread in tempo, so the difference in SDs is refused, not infinite.
        XCTAssertNil(t.differenceSDs.value)
    }

    // MARK: - The export

    func testTheFormRoundTripsThroughJSON() throws {
        let f = Self.form(a1, hide: [Body2DPoint.leftWrist])
        let data = try FormJSON.encode(f)
        let back = try FormJSON.decodeForm(data)
        XCTAssertEqual(back, f)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("\n"), "the export is compact")
    }

    func testTheModelRoundTripsThroughJSON() throws {
        let (m, _) = spreadBlock()
        let data = try FormJSON.encode(m)
        let back = try FormJSON.decodeModel(data)
        XCTAssertEqual(back, m)
    }

    func testAFormFromAnotherFormatVersionIsRefusedNotGuessedAt() throws {
        var f = Self.form(a1)
        f.version = 99
        let data = try FormJSON.encode(f)
        XCTAssertThrowsError(try FormJSON.decodeForm(data)) { error in
            XCTAssertTrue("\(error)".contains("not decoded rather than guessed at"))
        }
    }

    func testTheExportIsSmallEnoughToKeepPerShot() throws {
        let f = Self.form(a1)
        let data = try FormJSON.encode(f)
        XCTAssertLessThan(data.count, 40_000, "a session keeps one of these per accepted shot")
    }

    // MARK: - The self-model ghost: the shooter's own best reps

    /// One form, cloned with a shot id — the rule reads only the verdict and the two ball numbers,
    /// never the skeleton, so one synthetic body is enough and the test stays fast.
    static func rep(_ id: Int, accepted: Bool = true, depth: Double?, speed: Double?) -> FormRep {
        var f = bestRepBase
        f.shotID = id
        return FormRep(shotID: id, form: f, accepted: accepted, depthPastFrontRim: depth, releaseSpeed: speed)
    }
    static let bestRepBase = rigidForm(seed: 7, shotID: 0)

    func testBestRepsAreTheMakeBandShotsOnTheShootersOwnSpeed() {
        // Six in the band on 7.0 m/s, two out of the band that only give the pool its spread.
        var reps = (1...6).map { Self.rep($0, depth: 0.26, speed: 7.0) }
        reps.append(Self.rep(7, depth: 0.40, speed: 6.0))
        reps.append(Self.rep(8, depth: 0.05, speed: 8.0))
        let best = FormModel.bestReps(reps)
        XCTAssertTrue(best.isBestRepGhost)
        XCTAssertEqual(best.shotIDs, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(best.forms.count, 6)
        XCTAssertEqual(best.inMakeBand, 6)
        XCTAssertEqual(best.accepted, 8)
        XCTAssertEqual(best.speedMeanMetresPerSecond ?? 0, 7.0, accuracy: 1e-9)
        XCTAssertTrue(best.legend.contains("6 best reps"), best.legend)
        XCTAssertTrue(best.legend.contains("25–28 cm"), best.legend)
    }

    func testTooFewMakeBandShotsGhostsTheBlockMeanAndSaysHowMany() {
        var reps = (1...2).map { Self.rep($0, depth: 0.26, speed: 7.0) }
        reps.append(contentsOf: (3...9).map { Self.rep($0, depth: 0.45, speed: Double($0) * 0.1 + 6.6) })
        let best = FormModel.bestReps(reps)
        XCTAssertFalse(best.isBestRepGhost)
        XCTAssertEqual(best.legend, "ghost = block mean, best-rep ghost needs 5 make-band shots; you have 2")
        XCTAssertEqual(best.forms.count, 9, "the fallback ghost is every accepted form")
        XCTAssertNil(best.unavailableReason)
    }

    func testAShotOffTheShootersOwnSpeedIsNotABestRepEvenInTheBand() {
        var reps = (1...4).map { Self.rep($0, depth: 0.26, speed: 7.0) }
        reps.append(contentsOf: (5...6).map { Self.rep($0, depth: 0.27, speed: 9.0) })
        reps.append(contentsOf: (7...8).map { Self.rep($0, depth: 0.50, speed: 7.0) })
        let best = FormModel.bestReps(reps)
        XCTAssertFalse(best.isBestRepGhost)
        XCTAssertEqual(best.inMakeBand, 6)
        XCTAssertEqual(best.chosen, 4)
        XCTAssertTrue(best.legend.contains("6 landed in the band but only 4 of those were on speed"), best.legend)
    }

    func testARejectedShotIsNeverABestRepHoweverGoodItsNumbersAre() {
        var reps = (1...6).map { Self.rep($0, accepted: false, depth: 0.26, speed: 7.0) }
        reps.append(Self.rep(7, depth: 0.26, speed: 7.0))
        reps.append(Self.rep(8, depth: 0.26, speed: 7.2))
        let best = FormModel.bestReps(reps)
        XCTAssertEqual(best.accepted, 2)
        XCTAssertFalse(best.isBestRepGhost)
        XCTAssertEqual(best.forms.count, 2, "only the two accepted forms can be ghosted")
    }

    func testWithoutACrossingDepthTheGhostIsTheMeanAndTheReasonIsTheMissingRim() {
        let reps = (1...8).map { Self.rep($0, depth: nil, speed: 6.5 + Double($0) * 0.05) }
        let best = FormModel.bestReps(reps)
        XCTAssertFalse(best.isBestRepGhost)
        XCTAssertTrue(best.legend.contains("no shot in this block has a crossing depth"), best.legend)
        XCTAssertNotNil(best.speedMeanMetresPerSecond, "the speed pool is still reported")
        XCTAssertEqual(best.forms.count, 8)
    }

    func testNothingAcceptedIsUnavailableWithAReasonNotAnEmptyGhost() {
        let reps = (1...3).map { Self.rep($0, accepted: false, depth: 0.26, speed: 7.0) }
        let best = FormModel.bestReps(reps)
        XCTAssertFalse(best.isAvailable)
        XCTAssertTrue((best.unavailableReason ?? "").contains("accepted by the block rule"), best.unavailableReason ?? "")
        XCTAssertTrue(FormModel.bestReps([]).unavailableReason?.contains("nothing of your own to draw") == true)
    }
}
