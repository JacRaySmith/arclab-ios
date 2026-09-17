import Foundation
import ShotVideo
import ShotGeometry
import simd

/// `TrajectoryProbe body <clip> --start s --end s --release-time s [...]`
///
/// Runs `BodyTracker` over one shot window and prints the `BodyKinematics` body model: how many
/// joints Vision found per frame, the true 3-D angles at release next to the existing camera-side
/// 2-D value, the kinetic chain, stance, head and hand numbers, the frame-to-frame jitter of each
/// signal (so a number can be compared with the effect size it is supposed to resolve), and the
/// frames/s the pass achieved on this machine.
enum BodyCommand {

    struct PyBall: Decodable { var u: Double?; var v: Double?; var r: Double?; var source: String }
    struct PyFrame: Decodable { var t: Double; var t_file: Double; var ball: PyBall }
    struct PyTrack: Decodable { var frames: [PyFrame] }

    static func run(clip: URL, args: [String]) async throws {
        func flag(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let start = flag("--start").flatMap(Double.init), let end = flag("--end").flatMap(Double.init) else {
            print("""
            usage: TrajectoryProbe body <clip.mov> --start <file s> --end <file s> [--time-scale 4]
                     [--release-time <file s>] [--track-json pytrack.json] [--every N] [--no-crop]
                     [--no-hands] [--no-3d] [--shooting-side left|right] [--rim-u <px>] [--json out.json]
                   iteration 2 — the fitted skeleton, the scale and the release-window hands:
                     [--fit] [--no-fit] [--hfov <deg, default 48>] [--height <shooter metres>]
                     [--rim-major-px <px>] [--rim-diameter <m, default 0.4572>]
                     [--hand-focus <real s each side of release, default 0.4; 0 disables>]
                     [--form-json out.json] [--form-samples N] [--shot-id N]
                   iteration 3 — independent decimation, the ball-placed hand crop, the new priors:
                     [--every-3d N] [--every-hands N] [--no-2d] [--detect-ball] [--ball-px D]
                     [--no-ball-crop] [--ball-blend 0…1] [--no-neck] [--no-symmetric]
                     [--no-conf-weight] [--depth-hold <real s>]
                   1.3 Track C — the feet:
                     [--feet] [--feet-cross-check] [--every-feet N] [--foot-conf 0.35]
                     [--toe-pair-px 4]  (--feet needs --height or the triangle's size prior has no scale)
            """)
            return
        }
        let scale = flag("--time-scale").flatMap(Double.init) ?? 1
        let step = flag("--every").flatMap(Int.init) ?? 1
        let side = flag("--shooting-side") ?? "right"
        let rimU = flag("--rim-u").flatMap(Double.init)

        let probe = try await VideoReader(url: clip).quickProbe(maxFrames: 60)
        let fps = probe.measuredFrameRate

        // Ball track (optional): pytrack's per-frame JSON, the same format `analyze --track-json` reads.
        var seed: [(pts: Double, uv: SIMD2<Double>)] = []
        var ballTrack: [BodyBallSample] = []
        if let tj = flag("--track-json") {
            let py = try JSONDecoder().decode(PyTrack.self, from: Data(contentsOf: URL(fileURLWithPath: tj)))
            for f in py.frames {
                guard let u = f.ball.u, let v = f.ball.v, let r = f.ball.r,
                      ["detected", "held", "template", "merged"].contains(f.ball.source),
                      f.t_file >= start, f.t_file <= end else { continue }
                seed.append((pts: f.t_file, uv: SIMD2(u, v)))
                ballTrack.append(BodyBallSample(t: f.t_file / scale, u: u, v: v, diameterPx: 2 * r))
            }
        }
        // `--detect-ball`: run the app's own ball detector over this window instead of reading a
        // track from disk, so the hand crop, the shooting/guide labelling and the fingertip metrics
        // get exactly the ball the analyser had. One extra decode pass — measurement tooling, not
        // part of the body stage's cost.
        if args.contains("--detect-ball") {
            let probe0 = try await VideoReader(url: clip).quickProbe(maxFrames: 60)
            var dopt = BallDetectorOptions()
            // The detector is a *seeded* tracker: with an empty seed it finds nothing (measured on
            // this clip: 0 detections at every expected diameter). `session` seeds it from the fast
            // rim scanner's candidates, so `--rim` does the same here and the two agree by construction.
            var ballSeed: [Int: SIMD2<Double>] = [:]
            if let rimPath = flag("--rim") {
                struct RimFile: Decodable { var points: [[Double]] }
                let rim = try JSONDecoder().decode(RimFile.self, from: Data(contentsOf: URL(fileURLWithPath: rimPath)))
                let k = CameraIntrinsics(width: probe0.width, height: probe0.height,
                                         horizontalFOVDegrees: flag("--hfov").flatMap(Double.init) ?? 48)
                var ro = RimCalibrationOptions(); ro.rimDiameter = flag("--rim-diameter").flatMap(Double.init) ?? Court.rimInnerDiameter
                let cal = try RimCalibrator.calibrate(boundaryPoints: rim.points.map { SIMD2($0[0], $0[1]) }, intrinsics: k, options: ro)
                let ballPxAtRim = 2 * cal.ellipse.semiMajor * (BallSize.size7.diameter / cal.rimDiameterUsed)
                var so = RimScanOptions(); so.startTime = start; so.endTime = end
                if let r = try? await RimArrivalScanner.scan(url: clip, rimCenter: cal.ellipse.center,
                                                             ballDiameterPx: ballPxAtRim, options: so) {
                    var radii: [Double] = []
                    for c in r.candidates where c.pts >= start && c.pts <= end {
                        ballSeed[c.frameIndex] = SIMD2(c.u, c.v); radii.append(c.diameterPx / 2)
                    }
                    if !radii.isEmpty { dopt.expectedDiameterPx = 1.6 * radii.sorted()[radii.count / 2] }
                    print("  --detect-ball: \(ballSeed.count) rim-scan seeds, ball ≈ \(Int(ballPxAtRim)) px at the rim")
                }
            }
            if let px = flag("--ball-px").flatMap(Double.init) { dopt.expectedDiameterPx = px }
            if let win = try? await BallDetector.decodeWindow(url: clip, start: start, end: end, seed: ballSeed,
                                                              fps: probe0.measuredFrameRate, options: dopt) {
                let r = BallDetector.track(window: win, seed: ballSeed, options: dopt)
                for d in r.detections where !d.edge {
                    seed.append((pts: d.pts, uv: SIMD2(d.u, d.v)))
                    ballTrack.append(BodyBallSample(t: d.pts / scale, u: d.u, v: d.v, diameterPx: d.diameterPx))
                }
                print("  --detect-ball: \(r.detections.count) detections, \(ballTrack.count) used as evidence")
            } else { print("  --detect-ball: the detector could not decode this window; no ball track") }
        }

        var options = BodyTracker.Options()
        options.everyNthFrame = step
        options.timeScale = scale
        options.useCrop = !args.contains("--no-crop")
        options.detectHands = !args.contains("--no-hands")
        options.detect3DBody = !args.contains("--no-3d")
        options.detect2DBody = !args.contains("--no-2d")
        options.shootingSide = side
        // iteration 3: the three requests decimate independently.
        if let n = flag("--every-3d").flatMap(Int.init) { options.everyNthFrame3D = n }
        if let n = flag("--every-hands").flatMap(Int.init) { options.everyNthFrameHands = n }
        if let n = flag("--hands-outside").flatMap(Int.init) { options.everyNthFrameHandsOutsideFocus = n }
        if args.contains("--no-concurrent") { options.concurrentRequests = false }
        if let s = flag("--crop-scale").flatMap(Double.init) { options.cropRenderScale = s }
        if args.contains("--no-ball-crop") { options.handFocusUsesBall = false }
        if let b = flag("--ball-blend").flatMap(Double.init) { options.handFocusBallBlend = b }
        if let pad = flag("--pad").flatMap(Double.init) { options.cropPadFraction = pad }
        let releaseFileTime = flag("--release-time").flatMap(Double.init)
        let handFocus = flag("--hand-focus").flatMap(Double.init) ?? 0.4
        if let px = flag("--hand-crop-px").flatMap(Double.init) { options.handFocusCropPx = px }
        if let b = flag("--hand-bias").flatMap(Double.init) { options.handFocusForearmBias = b }
        // 1.3 Track C: the feet. Off unless asked for — the model is internal-only (see DECISIONS.md).
        options.detectFeet = args.contains("--feet")
        options.footModelCrossCheck = args.contains("--feet-cross-check")
        if let n = flag("--every-feet").flatMap(Int.init) { options.everyNthFrameFeet = n }
        if let r = releaseFileTime, handFocus > 0, options.detectHands {
            options.handFocusRealTimeRange = (r / scale - handFocus)...(r / scale + handFocus)
        }

        print(String(format: "body: %@  window %.3f→%.3f file s (%.3f→%.3f real), %dx%d at %.2f fps, time scale %.0f",
                     clip.lastPathComponent, start, end, start / scale, end / scale, probe.width, probe.height, fps, scale))
        if !ballTrack.isEmpty { print("  ball track: \(ballTrack.count) evidence samples in the window") }

        // `--timeline-json` re-runs everything downstream of Vision on a timeline this command wrote
        // earlier: the decode and the three requests are the expensive part, and nothing about the fit,
        // the scale or the gates needs them again. It is how the weights below were chosen.
        struct Payload: Codable { var timeline: BodyTimeline }
        let timeline: BodyTimeline
        if let tj = flag("--timeline-json") {
            timeline = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: URL(fileURLWithPath: tj))).timeline
            print("  timeline re-read from \(tj): \(timeline.frames.count) frames (no decode, no Vision)")
        } else {
            timeline = try await BodyTracker.run(url: clip, start: start, end: end, options: options,
                                                 ballSeed: seed, fps: fps)
        }
        for n in timeline.notes { print("  · \(n)") }
        print(String(format: "  speed: %d frames analysed in %.1f s = %.2f frames/s on this Mac (%.0f ms/frame)",
                     timeline.analysedFrames, timeline.wallSeconds, timeline.framesPerSecondAchieved,
                     timeline.wallSeconds / Double(max(1, timeline.analysedFrames)) * 1000))
        if let c = timeline.cost {
            func part(_ label: String, _ s: Double, _ n: Int) -> String {
                String(format: "%@ %.2f s on %d frames (%.1f ms each)", label, s, n, c.msPerFrame(s, n) ?? .nan)
            }
            let requests = c.concurrentFrames > 0
                ? [String(format: "requests together %.2f s on %d frames (%.1f ms each; 2-D on %d, 3-D on %d, hands on %d)",
                          c.concurrentSeconds, c.concurrentFrames, c.msPerFrame(c.concurrentSeconds, c.concurrentFrames) ?? .nan,
                          c.body2DFrames, c.body3DFrames, c.handsFrames)]
                : [part("2-D", c.body2DSeconds, c.body2DFrames), part("3-D", c.body3DSeconds, c.body3DFrames),
                   part("hands", c.handsSeconds, c.handsFrames)]
            let measured = c.concurrentSeconds + c.body2DSeconds + c.body3DSeconds + c.handsSeconds + c.cropSeconds
            print("  cost: " + (requests + [String(format: "crop %.2f s", c.cropSeconds),
                                            String(format: "decode+other %.2f s", max(0, timeline.wallSeconds - measured))])
                    .joined(separator: ", "))
        }

        // Coverage: how much of the model Vision actually filled in.
        let with3D = timeline.frames.filter { !$0.joints3D.isEmpty }
        let with2D = timeline.frames.filter { !$0.points2D.isEmpty }
        let withHands = timeline.frames.filter { !$0.hands.isEmpty }
        func mean(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count) }
        print(String(format: "  coverage: 3-D body on %d/%d frames (%.1f joints/frame of 17), 2-D body on %d (%.1f of 19 at conf ≥ 0.3), hands on %d (%.1f landmarks, %.2f hands/frame)",
                     with3D.count, timeline.analysedFrames, mean(with3D.map { Double($0.joints3D.count) }),
                     with2D.count, mean(with2D.map { Double($0.points2D.values.filter { $0.confidence >= 0.3 }.count) }),
                     withHands.count, mean(withHands.flatMap { $0.hands.map { Double($0.landmarks.count) } }),
                     mean(withHands.map { Double($0.hands.count) })))
        if let h = with3D.compactMap(\.bodyHeightMetres).first, let t = with3D.compactMap(\.heightEstimationTechnique).first {
            print(String(format: "  body height %.2f m by the '%@' technique", h, t))
        }
        let conf2D = with2D.compactMap { $0.points2D[Body2DPoint.rightShoulder]?.confidence }
        if !conf2D.isEmpty { print(String(format: "  2-D right-shoulder confidence: median %.2f", Stats.median(conf2D))) }

        // --check-3d: is `Joint3D.position` (model space) or `cameraRelativePosition` the usable one?
        // Compare the elbow angle and the limb lengths each implies against real anatomy.
        if args.contains("--check-3d"), let f = with3D.first(where: { $0.joints3D[Body3DJoint.rightWrist] != nil }) {
            func report(_ label: String, _ get: (BodyJoint3D) -> SIMD3<Double>) {
                guard let s3 = f.joints3D[Body3DJoint.rightShoulder], let e = f.joints3D[Body3DJoint.rightElbow],
                      let w = f.joints3D[Body3DJoint.rightWrist], let hip = f.joints3D[Body3DJoint.rightHip],
                      let knee = f.joints3D[Body3DJoint.rightKnee], let ank = f.joints3D[Body3DJoint.rightAnkle],
                      let head = f.joints3D[Body3DJoint.topHead], let root = f.joints3D[Body3DJoint.root] else { return }
                let S = get(s3), E = get(e), W = get(w)
                print(String(format: "    %@: elbow %.1f°  upper arm %.3f m  forearm %.3f m  thigh %.3f m  shin %.3f m  root→head %.3f m",
                             label, Angle.degrees(BodyAngles.angle(S, E, W) ?? .nan),
                             simd_length(S - E), simd_length(E - W), simd_length(get(hip) - get(knee)),
                             simd_length(get(knee) - get(ank)), simd_length(get(root) - get(head))))
                print(String(format: "      shoulder %@  elbow %@  wrist %@", String(describing: S), String(describing: E), String(describing: W)))
            }
            print("  --check-3d on the first frame with a right wrist (t \(f.realTime)):")
            report("model-space position     ", { $0.position })
            report("cameraRelativePosition   ", { $0.cameraPosition })
        }

        // Hands in the release window, the number `--hand-focus` is meant to move.
        if let r = releaseFileTime {
            let lo = r / scale - max(handFocus, 0.4), hi = r / scale + max(handFocus, 0.4)
            let inWindow = timeline.frames.filter { $0.realTime >= lo && $0.realTime <= hi }
            let withHand = inWindow.filter { !$0.hands.isEmpty }
            print(String(format: "  hands in release ±%.2f s real: %d/%d frames (%.0f %%), %.2f hands/frame where found",
                         max(handFocus, 0.4), withHand.count, inWindow.count,
                         inWindow.isEmpty ? 0 : 100 * Double(withHand.count) / Double(inWindow.count),
                         withHand.isEmpty ? 0 : mean(withHand.map { Double($0.hands.count) })))
        }

        guard let releaseFile = flag("--release-time").flatMap(Double.init) else {
            print("  (no --release-time: the body model needs a release instant; stopping after the tracker report)")
            return
        }
        let releaseReal = releaseFile / scale

        var kOptions = BodyKinematicsOptions(shootingSide: side)
        // `--last-turning-dip`: the dip rule the app uses over its 1.5 s lookback (see the option's note).
        if args.contains("--last-turning-dip") { kOptions.dipIsLastTurningPoint = true }
        let visionModel = BodyKinematics.model(timeline: timeline, releaseRealTime: releaseReal,
                                               ballTrack: ballTrack, rimImageU: rimU, options: kOptions)

        // ---- iteration 2: one skeleton per shot, fitted to the 2-D points ------------------------
        var fit: BodySkeletonFitResult? = nil
        if !args.contains("--no-fit") {
            let hfov = flag("--hfov").flatMap(Double.init) ?? 48
            var fo = BodySkeletonOptions(intrinsics: CameraIntrinsics(width: timeline.imageWidth,
                                                                     height: timeline.imageHeight,
                                                                     horizontalFOVDegrees: hfov))
            if let w = flag("--bone-weight").flatMap(Double.init) { fo.boneWeight = w }
            if let w = flag("--smooth-weight").flatMap(Double.init) { fo.smoothnessWeight = w }
            if let n = flag("--sweeps").flatMap(Int.init) { fo.sweeps = n }
            if args.contains("--no-breadth-prior") { fo.transverseBreadthFromHeight = false }
            // iteration 3: each of the three new priors can be switched off, so each can be measured.
            if args.contains("--no-neck") { fo.fitNeck = false }
            if args.contains("--no-symmetric") { fo.symmetricLimbPrior = false }
            if args.contains("--no-conf-weight") { fo.confidenceWeightedObservations = false }
            if let s = flag("--depth-hold").flatMap(Double.init) { fo.depthSeedHoldSeconds = s }
            if let h = flag("--height").flatMap(Double.init) {
                fo.scale = .statedHeight(metres: h)
            } else if let px = flag("--rim-major-px").flatMap(Double.init) {
                fo.scale = .rimRuler(diameterMetres: flag("--rim-diameter").flatMap(Double.init) ?? 0.4572, majorAxisPx: px)
            }
            let t0 = Date()
            let r = BodySkeletonFit.fit(timeline: timeline, options: fo)
            fit = r
            print(String(format: "  skeleton fit: %d frames, %d bones, %.2f s (hFOV %.1f°, fx %.0f px)",
                         r.framesFitted, r.bones.count, Date().timeIntervalSince(t0), hfov, fo.intrinsics.fx))
            for n in r.notes { print("    · \(n)") }
            for w in r.warnings { print("    ! \(w)") }
            print("    reprojection RMS: fitted \(r.reprojectionRMSPixels.describe("%.2f"))  vs Vision's own 3-D \(r.visionReprojectionRMSPixels.describe("%.2f"))")
            print("    scale: \(r.metresPerPixelAtBody.describe("%.5f"))/px, body depth \(r.bodyDepthMetres.describe("%.2f")), standing height \(r.standingHeightMetres.describe("%.3f"))")
            print("    mid-hip 1σ: depth \(r.depthSigmaMetres.describe("%.3f")), image plane \(r.lateralSigmaMetres.describe("%.3f"))")
            if r.scaleIsMeasured {
                print("    bones (metres, MAD over frames):")
                for b in r.bones.sorted(by: { $0.name < $1.name }) {
                    print(String(format: "      %-16@ %.3f m  ±%.3f  (longest projection %.1f px on %d frames)",
                                 b.name, b.metres, b.madMetres, b.maximumProjectedPixels, b.frames))
                }
            }
        }
        // What the fit found it cannot see, the kinematics must refuse.
        if let f = fit { kOptions.transverseYawUnavailableReason = f.transverseYawUnavailableReason }
        let model = fit.map { BodyKinematics.model(timeline: $0.timeline, releaseRealTime: releaseReal,
                                                   ballTrack: ballTrack, rimImageU: rimU, options: kOptions) } ?? visionModel

        print(String(format: "  release %.3f file s = %.4f real s; shooting side %@", releaseFile, releaseReal, model.shootingSide ?? "unknown"))
        for w in model.warnings { print("  ! \(w)") }

        if let a = model.anglesAtRelease {
            print("  3-D angles at release:")
            print("    elbow     \(a.rightElbow.describe())  (left \(a.leftElbow.describe()))")
            print("    knee      \(a.rightKnee.describe())  (left \(a.leftKnee.describe()))")
            print("    hip       \(a.rightHip.describe())  (left \(a.leftHip.describe()))")
            print("    shoulder  elevation \(a.rightShoulderElevation.describe())  abduction \(a.rightShoulderAbduction.describe())")
            print("    ankle     \(a.rightAnkle.describe())")
            print("    wrist     \(a.shootingWristFlexion.describe())")
        }

        // The existing camera-side 2-D value, from the same clip, for comparison (a second decode pass).
        let poses = try await PoseTracker.run(url: clip, start: start, end: end, everyNthFrame: step, ballSeed: seed, fps: fps)
        if let angles2D = PoseMetrics2D.angles(poses: poses, releasePTS: releaseFile, extensionHalfWindowFrames: 6,
                                               kneeLookbackPTS: 1.2 * scale) {
            let e2 = angles2D.elbowAtReleaseDegrees
            let e3 = model.anglesAtRelease?.rightElbow.degrees ?? model.anglesAtRelease?.leftElbow.degrees
            print(String(format: "  2-D (existing PoseMetrics2D, side %@): elbow at release %@, max near release %@, knee min %@",
                         angles2D.side,
                         e2.map { String(format: "%.2f°", $0) } ?? "nil",
                         angles2D.elbowMaxNearReleaseDegrees.map { String(format: "%.2f°", $0) } ?? "nil",
                         angles2D.kneeMinimumDegrees.map { String(format: "%.2f°", $0) } ?? "nil"))
            if let e2, let e3 { print(String(format: "  elbow 3-D − 2-D = %+.2f°", e3 - e2)) }
        }

        print("  phases (real s, source: \(model.phases.signalSource)):")
        print("    set \(model.phases.setPoint.describe("%.4f"))   dip \(model.phases.dip.describe("%.4f"))   release \(model.phases.release.describe("%.4f"))")
        print("    follow peak \(model.phases.followThroughPeak.describe("%.4f"))   follow end \(model.phases.followThroughEnd.describe("%.4f"))")
        print("    set→release \(model.phases.setToReleaseMilliseconds.describe("%.0f"))   dip→release \(model.phases.dipToReleaseMilliseconds.describe("%.0f"))")
        if let s0 = model.phases.setPoint.value, let f = model.phases.followThroughEnd.value {
            print(String(format: "    release→follow end %.0f ms   (set→release %.0f ms)", 1000 * (f - releaseReal), 1000 * (releaseReal - s0)))
        }
        for n in model.phases.notes { print("    · \(n)") }

        if let why = model.chain.unavailableReason {
            print("  kinetic chain: nil (\(why))")
        } else {
            print("  kinetic chain: \(model.chain.order.joined(separator: " → "))  proximal-to-distal: \(model.chain.proximalToDistal.map { $0 ? "yes" : "NO" } ?? "unknown")")
            for (i, e) in model.chain.events.enumerated() {
                let lag = i == 0 ? "" : String(format: "   +%.0f ms", model.chain.lagsMilliseconds[i - 1])
                print(String(format: "    %-9@ t %.4f s  peak %.0f °/s%@", e.joint, e.realTime, e.peakRateDegreesPerSecond, lag))
            }
        }
        for (joint, why) in model.chain.missing.sorted(by: { $0.key < $1.key }) { print("    \(joint): nil (\(why))") }

        let s = model.stance
        print("  stance: feet separation \(s.feetSeparation.describe()), stagger \(s.feetStagger.describe()), from toes \(s.feetStaggerFromToes.describe())")
        print("          shoulder yaw \(s.shoulderLineYaw.describe()), hip yaw \(s.hipLineYaw.describe()), squareness ratio \(s.squarenessRatio.describe("%.3f"))")
        print("          lean sagittal \(s.torsoLeanSagittal.describe()), frontal \(s.torsoLeanFrontal.describe())")
        print("          jump \(s.jumpHeight.describe("%.3f")), hip drift lateral \(s.hipDriftLateral.describe("%.3f")) depth \(s.hipDriftDepth.describe("%.3f"))")
        let h = model.head
        print("  head: yaw \(h.yaw.describe()), pitch(relative) \(h.pitchRelative.describe()), stability \(h.stabilityPx.describe("%.1f")), max displacement \(h.maximumDisplacementPx.describe("%.1f"))")
        print("        nose offset \(h.noseOffsetPx.describe("%.1f")), faces rim: \(h.facesRimDirection.map { $0 ? "yes" : "no" } ?? "nil (\(h.facesRimUnavailableReason ?? "—"))")")
        let hn = model.hands
        print("  hands: seen on \(hn.handsSeenFrames) frames, shooting chirality \(hn.shootingHandChirality ?? "nil")")
        print("         last fingertips on the ball: \(hn.lastFingertipsOnBall.isEmpty ? "nil (\(hn.fingertipsUnavailableReason ?? "—"))" : hn.lastFingertipsOnBall.joined(separator: ", "))")
        print("         wrist snap \(hn.wristSnapRate.describe("%.0f")), guide thumb toward ball \(hn.guideThumbTowardBall.describe("%.0f"))")

        // Noise floor: SD of the frame-to-frame difference / √2 (digest Ch 10 §10.5.1 — differencing
        // doubles the variance). Compare this with the effect a metric is supposed to resolve.
        // Two columns: Vision's own 3-D body, and the per-shot skeleton fitted to the 2-D points.
        func jitterOf(_ values: [Double]) -> Double? {
            guard values.count >= 6 else { return nil }
            var diffs: [Double] = []
            for i in 1..<values.count { diffs.append(values[i] - values[i - 1]) }
            return Stats.sd(diffs) / 2.0.squareRoot()
        }
        func fmt(_ x: Double?, _ f: String = "%6.2f") -> String { x.map { String(format: f, $0) } ?? "   nil" }
        func row(_ label: String, _ before: [Double], _ after: [Double], _ unit: String) {
            let b = jitterOf(before), a = jitterOf(after)
            let change = (b != nil && a != nil && b! > 0) ? String(format: "  ×%.2f", a! / b!) : ""
            print(String(format: "    %-26@ Vision 3-D %@ %@   fitted %@ %@ (n %d → %d)%@",
                         label, fmt(b), unit, fmt(a), unit, before.count, after.count, change))
        }
        func angleSeries(_ m: BodyModel, _ get: (JointAngles3D) -> BodyMeasure) -> [Double] {
            m.angles.compactMap { get($0).value }.map(Angle.degrees)
        }
        func lineYaw(_ tl: BodyTimeline, _ a: String, _ b: String) -> [Double] {
            tl.frames.compactMap { f in
                guard let l = f.joints3D[a], let r = f.joints3D[b] else { return nil }
                let d = r.cameraPosition - l.cameraPosition
                var x = atan2(d.z, d.x)
                while x > .pi / 2 { x -= .pi }
                while x <= -.pi / 2 { x += .pi }
                return Angle.degrees(x)
            }
        }
        func midHip(_ tl: BodyTimeline) -> [Double] {
            tl.frames.compactMap { f in
                guard let l = f.joints3D[Body3DJoint.leftHip], let r = f.joints3D[Body3DJoint.rightHip] else { return nil }
                return (l.cameraPosition.y + r.cameraPosition.y) / 2
            }
        }
        let after = fit?.timeline ?? timeline
        print("  frame-to-frame noise (sd of differences / √2, over the whole window):")
        let L = side == "left"
        row("3-D elbow", angleSeries(visionModel) { L ? $0.leftElbow : $0.rightElbow },
            angleSeries(model) { L ? $0.leftElbow : $0.rightElbow }, "°")
        row("3-D knee", angleSeries(visionModel) { L ? $0.leftKnee : $0.rightKnee },
            angleSeries(model) { L ? $0.leftKnee : $0.rightKnee }, "°")
        row("3-D shoulder elevation", angleSeries(visionModel) { L ? $0.leftShoulderElevation : $0.rightShoulderElevation },
            angleSeries(model) { L ? $0.leftShoulderElevation : $0.rightShoulderElevation }, "°")
        row("3-D hip", angleSeries(visionModel) { L ? $0.leftHip : $0.rightHip },
            angleSeries(model) { L ? $0.leftHip : $0.rightHip }, "°")
        row("3-D shoulder-line yaw", lineYaw(timeline, Body3DJoint.leftShoulder, Body3DJoint.rightShoulder),
            lineYaw(after, Body3DJoint.leftShoulder, Body3DJoint.rightShoulder), "°")
        row("3-D hip-line yaw", lineYaw(timeline, Body3DJoint.leftHip, Body3DJoint.rightHip),
            lineYaw(after, Body3DJoint.leftHip, Body3DJoint.rightHip), "°")
        row("3-D mid-hip height", midHip(timeline), midHip(after), "m")
        // The 2-D inputs, unchanged by the fit: the floor everything above is measured against.
        print(String(format: "    %-26@ %@ px   (2-D nose u, the input)", "", fmt(jitterOf(timeline.frames.compactMap { $0.points2D[Body2DPoint.nose].flatMap { $0.confidence >= 0.3 ? $0.u : nil } }))))
        print(String(format: "    %-26@ %@ px   (2-D shooting wrist v, the input)", "", fmt(jitterOf(timeline.frames.compactMap { f in f.points2D[L ? Body2DPoint.leftWrist : Body2DPoint.rightWrist].flatMap { $0.confidence >= 0.3 ? $0.v : nil } }))))

        print("  angles at release, Vision 3-D → fitted:")
        func atRelease(_ label: String, _ get: (JointAngles3D) -> BodyMeasure) {
            let b = visionModel.anglesAtRelease.map(get)?.degrees
            let a = model.anglesAtRelease.map(get)?.degrees
            print(String(format: "    %-22@ %@° → %@°", label, fmt(b), fmt(a)))
        }
        atRelease("elbow") { L ? $0.leftElbow : $0.rightElbow }
        atRelease("knee") { L ? $0.leftKnee : $0.rightKnee }
        atRelease("shoulder elevation") { L ? $0.leftShoulderElevation : $0.rightShoulderElevation }

        print("  metres, Vision 3-D → fitted (every one carries its provenance):")
        func metric(_ label: String, _ get: (StanceMetrics) -> BodyMeasure) {
            print("    \(label): \(get(visionModel.stance).describe("%.3f")) → \(get(model.stance).describe("%.3f"))")
        }
        metric("jump height      ") { $0.jumpHeight }
        metric("feet separation  ") { $0.feetSeparation }
        metric("feet stagger     ") { $0.feetStagger }
        metric("hip drift lateral") { $0.hipDriftLateral }
        // Depth-direction lengths are held to the fit's own depth uncertainty: a drift smaller than
        // the 1σ the camera can resolve is not a measurement, and says so instead of printing a number.
        if let f = fit, let sigma = f.depthSigmaMetres.value, let d = model.stance.hipDriftDepth.value {
            if abs(d) < 2 * sigma {
                print(String(format: "    hip drift depth  : nil (the fit's own mid-hip depth 1σ is %.3f m and the drift is %.3f m: a single camera cannot resolve it) → Vision: %@", sigma, d, visionModel.stance.hipDriftDepth.describe("%.3f")))
            } else {
                print(String(format: "    hip drift depth  : %.3f m ± %.3f (1σ, depth direction) → Vision: %@", d, sigma, visionModel.stance.hipDriftDepth.describe("%.3f")))
            }
        } else {
            metric("hip drift depth  ") { $0.hipDriftDepth }
        }
        if let f = fit, f.scaleIsMeasured { print("    scale provenance: \(f.scaleProvenance)") }

        // Phase timing against the frame-quantisation floor: one file frame is 1/(fps) file seconds,
        // which is 1/(fps·timeScale) of real time. No phase difference smaller than that is a finding.
        let realFrame = 1.0 / (fps * scale)
        print(String(format: "  timing floor: 1 file frame = %.1f ms of real time at %.0f fps real; any lag at or below that is quantisation, not a measurement",
                     realFrame * 1000, fps * scale))

        // ---- iteration 3: per joint, what was seen and how noisy it is ---------------------------
        print("  per-joint coverage (2-D input; jitter = sd of consecutive differences ÷ √2):")
        print("    joint             seen    conf   jitter px  clipped  note")
        for c in model.coverage where c.source == "body2D" {
            print(String(format: "    %-16@ %4.0f %%  %5@  %9@  %5.0f %%  %@",
                         c.name, 100 * c.seenFraction, c.medianConfidence.value.map { String(format: "%.2f", $0) } ?? "  nil",
                         c.jitterPixels.value.map { String(format: "%.2f", $0) } ?? "nil",
                         100 * c.clippedFraction,
                         c.symmetryInferred ? "SYMMETRY-INFERRED" : (c.note ?? "")))
        }
        for c in model.coverage where c.source == "hand" {
            print(String(format: "    %-16@ %4.0f %%  %5@  %9@", c.name, 100 * c.seenFraction,
                         c.medianConfidence.value.map { String(format: "%.2f", $0) } ?? "  nil",
                         c.jitterPixels.value.map { String(format: "%.2f", $0) } ?? "nil"))
        }
        if let f = fit, !f.symmetryInferredJoints.isEmpty {
            print("    joints carried by their mirror partner: " + f.symmetryInferredJoints.joined(separator: ", "))
        }
        if let f = fit, !f.symmetricBones.isEmpty {
            print("    symmetric-limb prior on: " + f.symmetricBones.joined(separator: ", "))
        }

        // ---- iteration 3: neck and trunk attitude, with its own precision ------------------------
        let po = model.posture
        print("  posture (image plane, \(po.frames) frames; neck from \(po.neckSource), head from \(po.headSource)):")
        print("    trunk to vertical at release  \(po.trunkToVerticalAtRelease.describe("%.2f"))  ± \(po.trunkToVerticalJitter.describe("%.2f")) per frame   (max over dip→release \(po.trunkToVerticalMaximum.describe("%.2f")))")
        print("    head to trunk at release      \(po.headToTrunkAtRelease.describe("%.2f"))  ± \(po.headToTrunkJitter.describe("%.2f")) per frame")
        print("    head to shoulder-line normal  \(po.headToShoulderLineAtRelease.describe("%.2f"))  ± \(po.headToShoulderLineJitter.describe("%.2f")) per frame")
        print("    · \(po.note)")

        // ---- iteration 3: the fitted angle jitter, every joint, both sides -----------------------
        print("  fitted-angle jitter, °/frame (both sides; the far side is the one to read sceptically):")
        func pair(_ label: String, _ l: KeyPath<JointAngles3D, BodyMeasure>, _ r: KeyPath<JointAngles3D, BodyMeasure>) {
            let lj = jitterOf(model.angles.compactMap { $0[keyPath: l].value }.map(Angle.degrees))
            let rj = jitterOf(model.angles.compactMap { $0[keyPath: r].value }.map(Angle.degrees))
            print(String(format: "    %-20@ left %@   right %@", label, fmt(lj), fmt(rj)))
        }
        pair("elbow", \.leftElbow, \.rightElbow)
        pair("knee", \.leftKnee, \.rightKnee)
        pair("hip", \.leftHip, \.rightHip)
        pair("shoulder elevation", \.leftShoulderElevation, \.rightShoulderElevation)
        pair("shoulder abduction", \.leftShoulderAbduction, \.rightShoulderAbduction)

        // ---- the 3-D form (FormModel.swift) ------------------------------------------------------
        // One shot in the shooter's own frame on the phase-normalised clock. Written per shot; the
        // `form` command averages many of them into a block's FormModel.
        if let out = flag("--form-json") {
            guard let f = fit else {
                print("  --form-json needs the fitted skeleton (do not pass --no-fit)")
                return
            }
            var fo = FormOptions()
            if let n = flag("--form-samples").flatMap(Int.init) { fo.samples = n }
            if let u = rimU { fo.facing = .rimImageColumn(rimU: u) }
            // The same edge check the app applies: a dip sitting on the first frame of the lookback is
            // the window's length, not a dip, and `phases` says so in its notes.
            let edge = model.phases.notes.first { $0.hasPrefix("the dip is the first frame of the lookback")
                                               || $0.hasPrefix("the hand only rose inside the lookback") }
            let (form, why) = ShotForm.make(fit: f,
                                            setRealTime: model.phases.setPoint.value,
                                            dipRealTime: edge == nil ? model.phases.dip.value : nil,
                                            releaseRealTime: releaseReal,
                                            followThroughRealTime: model.phases.followThroughEnd.value,
                                            shootingSide: model.shootingSide,
                                            shotID: flag("--shot-id").flatMap(Int.init),
                                            options: fo)
            guard let form else {
                print("  form: nil (\(why ?? "no reason given"))")
                return
            }
            try FormJSON.encode(form).write(to: URL(fileURLWithPath: out))
            let seen = zip(form.joints, form.seenFraction).map { String(format: "%@ %.0f%%", $0.0, 100 * $0.1) }
            print("  form: \(form.samples.count)/\(form.sampleCount) samples, \(form.unit.rawValue)")
            print("    seen: " + seen.joined(separator: ", "))
            let inferred = zip(form.joints, form.inferredBySymmetry).filter(\.1).map(\.0)
            if !inferred.isEmpty { print("    inferred by symmetry: " + inferred.joined(separator: ", ")) }
            for (j, r) in form.refusedJoints.sorted(by: { $0.key < $1.key }) { print("    refused \(j): \(r)") }
            for g in form.gaps { print("    gap \(g.from)–\(g.to): \(g.reason)") }
            print("    tempo: set→dip \(form.durations.setToDip.describe("%.0f")), dip→release \(form.durations.dipToRelease.describe("%.0f")), release→follow \(form.durations.releaseToFollowThrough.describe("%.0f"))")
            for n in form.notes { print("    · \(n)") }
            print("  wrote \(out)")
        }

        // ---- 1.3 Track C: foot triangles, the foot angle, heel-first / toe-first ----------------
        if options.detectFeet, let f = fit {
            let hfov = flag("--hfov").flatMap(Double.init) ?? 48
            var fto = FootTriangleOptions(intrinsics: CameraIntrinsics(width: timeline.imageWidth,
                                                                      height: timeline.imageHeight,
                                                                      horizontalFOVDegrees: hfov))
            fto.shootingSide = side
            fto.rimImageU = rimU
            fto.stature = f.standingHeightMetres.value
            fto.statureProvenance = f.scaleProvenance
            if let c = flag("--foot-conf").flatMap(Double.init) { fto.minimumFootConfidence = c }
            if let t = flag("--toe-pair-px").flatMap(Double.init) { fto.minimumToePairPixels = t }
            let t0 = Date()
            var feet = FootTriangleFit.run(timeline: f.timeline, releaseRealTime: releaseReal,
                                           setRealTime: model.phases.setPoint.value, options: fto)
            print(String(format: "  feet: %.2f s", Date().timeIntervalSince(t0)))
            for t in feet.tracks {
                if let why = t.unavailableReason { print("    \(t.side): \(why)"); continue }
                let pairs = t.frames.compactMap { $0.toePairPixels.value }.sorted()
                let rms = t.frames.compactMap { $0.reprojectionPixels.value }
                let len = t.frames.compactMap { $0.lengthResidual.value }
                let wid = t.frames.compactMap { $0.widthResidual.value }
                func pct(_ xs: [Double], _ p: Double) -> Double { xs.isEmpty ? .nan : xs[min(xs.count - 1, max(0, Int((p * Double(xs.count - 1)).rounded())))] }
                print(String(format: "    %-5@ %3d/%3d frames fitted (detector saw all three on %3d), %3d with all three vertices, %3d with a roll",
                             t.side, t.frames.count, t.framesInWindow, t.framesDetected, t.framesWithOrientation, t.framesWithRoll))
                if !rms.isEmpty {
                    let meanRMS: Double = rms.reduce(0, +) / Double(rms.count)
                    let p90RMS: Double = pct(rms.sorted(), 0.9)
                    let meanLen: Double = len.isEmpty ? Double.nan : 100 * len.reduce(0, +) / Double(len.count)
                    let meanWid: Double = wid.isEmpty ? Double.nan : 100 * wid.reduce(0, +) / Double(wid.count)
                    print(String(format: "          reprojection RMS %.2f px (p90 %.2f) · toe pair %.1f px median (p10 %.1f, p90 %.1f) · length residual %+.0f %% · width residual %+.0f %%",
                                 meanRMS, p90RMS, pct(pairs, 0.5), pct(pairs, 0.1), pct(pairs, 0.9), meanLen, meanWid))
                }
            }
            for n in feet.notes { print("    · \(n)") }
            for w in feet.warnings { print("    ! \(w)") }

            // Footwork twice: once to get the contacts the strike order is read at, then again with
            // the feet folded in. The second pass is what the report and the export carry.
            var fo = FootworkOptions(shootingSide: side, rimImageU: rimU,
                                     standingHeightMetres: flag("--height").flatMap(Double.init))
            fo.rimBearingSign = nil
            let first = FootworkMetrics.compute(timeline: feet.timeline, releaseRealTime: releaseReal,
                                                setRealTime: model.phases.setPoint.value, options: fo)
            if let stature = first.statureImagePixels {
                feet.measures.strikes = FootTriangleFit.strikes(
                    timeline: feet.timeline, contacts: first.contacts, statureImagePixels: stature,
                    liftRealTime: first.liftRealTime, releaseRealTime: releaseReal,
                    minimumConfidence: fto.minimumFootConfidence)
            }
            let footwork = FootworkMetrics.compute(timeline: feet.timeline, releaseRealTime: releaseReal,
                                                   setRealTime: model.phases.setPoint.value, options: fo,
                                                   feet: feet.measures)
            print("  footwork with the feet:")
            print("    pattern \(footwork.pattern.title) — \(footwork.patternReason)")
            print("    foot angle to rim at the set: shooting \(footwork.footAngleToRim.describe("%.1f")), other \(footwork.otherFootAngleToRim.describe("%.1f")), openness \(footwork.stanceOpenness.describe("%.1f"))")
            print("    ± \(feet.measures.footAnglePixelNoiseSigmaAtSet.describe("%.1f")) propagated from ±1 px · frame-to-frame spread \(feet.measures.footAngleSigmaAtSet.describe("%.1f")) · foot axis \(feet.measures.footPointingPixelsAtSet.describe("%.0f")) in the image · rim/shooter bearing parallax \(feet.measures.rimBearingParallax.describe("%.1f"))")
            for e in footwork.footStrikes {
                print(String(format: "    strike: %-5@ at %.3f s  %@  (heel − toe %@)", e.foot, e.touchdownRealTime,
                             FootStrike(rawValue: e.strike)?.title ?? e.strike, e.heelMinusToeStature.describe("%+.4f")))
            }
            for n in footwork.notes where n.contains("foot angle") { print("    · \(n)") }
            for w in footwork.warnings { print("    ! \(w)") }
        } else if options.detectFeet {
            print("  feet: the foot triangle needs the fitted skeleton's ankles; this run had --no-fit")
        }

        if let out = flag("--json") {
            // The fitted timeline when there is one — that is the model the numbers above describe;
            // `visionTimeline` keeps Vision's own 3-D joints alongside so the two can still be diffed.
            struct Out: Encodable { var timeline: BodyTimeline; var visionTimeline: BodyTimeline; var model: BodyModel; var visionModel: BodyModel }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Out(timeline: fit?.timeline ?? timeline, visionTimeline: timeline,
                                   model: model, visionModel: visionModel)).write(to: URL(fileURLWithPath: out))
            print("  wrote \(out)")
        }
    }
}
