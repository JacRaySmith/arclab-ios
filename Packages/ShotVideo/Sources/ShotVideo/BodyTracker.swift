import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import CoreML
import Vision
import simd
import ShotGeometry

/// The full body model over a window of a clip: Apple's 3-D body pose (17 joints, metres), 2-D body
/// pose (19 points, including the eyes/ears/nose head-direction cues) and hand pose (up to two hands,
/// 21 landmarks each), all from **one** decode pass.
///
/// Why a crop: at 9 m a 1080p frame puts the shooter about 500 px tall, so the person occupies ~22 %
/// of the frame height and Vision's detectors see a very small subject. Cropping to a padded box
/// around the shooter and handing the detector that box makes the person fill the request. The box is
/// *tracked*: the first analysed frame runs on the whole frame to acquire the body, and every frame
/// after that crops to the previous frame's joint bounding box, padded. Nothing about the shooter's
/// size is assumed — the ball seed only chooses which person, never where the body is.
///
/// Output is `ShotGeometry.BodyTimeline`, which `BodyKinematics` consumes. This file is the only place
/// Vision names appear; the canonical ArcLab joint names live in `ShotGeometry` so the two cannot drift.
public enum BodyTracker {

    // MARK: - Options

    public struct Options: Sendable {
        /// 1 analyses every decoded frame, 2 every other, …
        public var everyNthFrame: Int = 1
        /// File seconds per real second (4 for a 120 fps clip written at 30).
        public var timeScale: Double = 1
        public var detect3DBody = true
        public var detect2DBody = true
        public var detectHands = true
        public var maximumHandCount = 2
        /// Padding added around the previous frame's joint box, as a fraction of that box. Measured on
        /// IMG_1765 (shooter ≈ 500 px tall): 0.3 → 26/30 frames carry a 3-D body, 0.6 → 29/30, 1.5 → 30/30
        /// but the crop is then most of the frame. Tighter than ~0.3 the detector starts losing the person.
        public var cropPadFraction: Double = 0.60
        /// The crop never goes below this many pixels on a side.
        public var minimumCropPx: Double = 224
        /// Set false to run every request on the whole frame (the control condition).
        public var useCrop = true
        /// "left"/"right" — the subject's shooting side, used to label the hands when no ball seed exists.
        public var shootingSide: String?
        /// After this many consecutive empty frames the crop is dropped and the whole frame retried.
        public var reacquireAfterMisses = 2
        /// `DetectHumanBodyPose3DRequest`'s frame spacing. `.zero` = analyse every frame handed over;
        /// the default spacing skips about two frames in three.
        public var frameAnalysisSpacing3D: CMTime = .zero

        // --- iteration 3 (2026-09-15): the three requests decimate independently ------------------
        /// Run the **3-D** request on every Nth analysed frame. The fit uses Vision's 3-D for one
        /// thing only — the front/back *sign* of each joint's depth (`BodySkeletonFit`) — and a
        /// front/back ordering does not change inside a few milliseconds, so at 240 fps this can be
        /// 2 or 3 with no measurable effect while the request is about a quarter of the stage.
        /// `BodySkeletonOptions.depthSeedHoldSeconds` is what carries the sign across the gap.
        /// **2 by default, on measurement**: on the 240 fps clip it took the 3-D request from 1.5 s
        /// to 0.7 s of the window's cost and left the fitted elbow, knee, hip and shoulder jitter,
        /// and the fitted reprojection RMS (1.38 px against 1.32), where they were.
        public var everyNthFrame3D: Int = 2
        /// Run the **hand** request on every Nth analysed frame. The hands matter at the release, and
        /// `handFocusRealTimeRange` already restricts them to that interval.
        public var everyNthFrameHands: Int = 1
        /// Outside `handFocusRealTimeRange`, run the hand request on only every Nth analysed frame.
        /// Everything the hand model is *for* — the fingertips leaving the ball, the wrist snap, the
        /// guide hand's thumb — happens inside the focus window; outside it the hands are context.
        /// **3 by default, on measurement**: 1.77 s → 1.19 s on the 240 fps clip with the
        /// release-window hand rate unchanged at 100 %.
        public var everyNthFrameHandsOutsideFocus: Int = 3
        /// Run the three Vision requests **concurrently** instead of one after another. They are
        /// independent — the only coupling was that the tight hand crop is placed from the 2-D wrist,
        /// and under concurrency it uses the *previous* analysed frame's wrist instead (at 240 fps
        /// that is 8 ms of hand travel, against a 256 px crop). Measured on the 240 fps clip.
        public var concurrentRequests = true
        /// Render the body crop at this fraction of its full-frame size before handing it to the two
        /// body requests. Vision answers in normalised coordinates, so nothing downstream changes —
        /// only how many pixels the detector is given, which is what its cost scales with. The hand
        /// crop is **not** scaled: it is already only 256 px and the fingertips need every pixel.
        ///
        /// **1.0 — tried and rejected.** Vision resizes the input itself, so the request's cost does
        /// not scale with the pixels handed to it: measured on the 240 fps clip, 0.7 left the 2-D
        /// request at 9.6 ms/frame against 9.0 at full size (i.e. no gain at all), and 0.5 pushed the
        /// fitted reprojection RMS from 1.38 to 1.69 px. The option stays because the measurement is
        /// worth keeping reproducible, not because the default should move.
        public var cropRenderScale: Double = 1.0
        /// Put the tight hand crop on the **ball** when the ball track has a sample on this frame,
        /// instead of on the wrist pushed along the forearm. At the release the hand is on the ball
        /// by definition, and the ball is the better-localised of the two: the detector's centroid
        /// is a fitted circle, the wrist is a joint estimate. Measured on the 240 fps clip; the
        /// blend below is what was kept.
        public var handFocusUsesBall = true
        /// How far to move the crop centre from the biased wrist toward the ball centre, 0…1.
        /// 1.0 = the ball centre. A blend rather than the ball itself because the crop must contain
        /// the wrist as well when the ball has already left the hand.
        public var handFocusBallBlend: Double = 0.5

        // --- hands near the release (iteration 2, 2026-09-14) ---
        /// **Real** seconds, the window in which the hand request gets its own tight crop around the
        /// shooting-hand wrist instead of sharing the body crop. Release ± 0.4 s is the interval where
        /// the fingertips decide the shot, and on the body crop the hand is only ~60 px across at 9 m,
        /// which is where the detector starts failing. Nil = the previous behaviour on every frame.
        public var handFocusRealTimeRange: ClosedRange<Double>?
        /// Side of the square hand crop, in full-frame pixels, centred on the 2-D shooting wrist.
        /// Fixed for the pass, like the 3-D body crop, so the request never sees a changing input size.
        /// **256 px, and that is a measurement, not a guess.** Swept on IMG_1765's three labelled
        /// windows (release-window hand rate, best of each row in bold in PHASE2-PREP): 224 px → 57/68 %,
        /// 256 px → 70/78/22 %, 320 px → 69/78 %, 384 px → 7 %, 512 px → 6 %, 160 px → 0 %. The optimum
        /// is the same 256 px whether the shooter is 500 px tall or 275 px tall, so **0 = size it from
        /// the forearm** was tried and rejected: at 3 × the forearm the small-shooter window fell to 0 %.
        /// Vision's hand request wants a fixed input size, not a fixed subject fraction.
        public var handFocusCropPx: Double = 256
        public var handFocusCropForearms: Double = 3.0
        public var handFocusMinimumCropPx: Double = 160

        // --- the hand triangle (1.3, 2026-09-16) ---------------------------------------------------
        /// Confidence floor for a hand **landmark** when it is lifted into the timeline's own 2-D
        /// points. Its own number, not the body's 0.30: measured over 1351 hand observations in the
        /// 37-shot free-throw session the median landmark confidence is 0.31 at the wrist and 0.50 at
        /// the MCPs, so the body floor would discard half of every hand. See
        /// `HandTriangleOptions.minimumHandLandmarkConfidence`.
        public var minimumHandLandmarkConfidence: Double = 0.20
        /// Let a hand-pose wrist stand in for a missing body-pose wrist (stamped "wrist from hand
        /// pose" in the point's provenance). The two detectors mark the same anatomical point, so this
        /// is a second observation, never an inference.
        public var wristFromHandPose = true
        /// Bridge a hand point across at most this many *sampled* frames between two observations.
        /// 1 (13 ms at 79 samples per second here); 0 switches it off. Never bridges two samples.
        public var interpolateHandPointsAcrossSamples: Int = 1
        /// How far beyond the wrist to bias the crop centre, as a multiple of the forearm's pixel
        /// length: the hand is past the wrist along the forearm, never behind it.
        public var handFocusForearmBias: Double = 0.45

        // --- feet (1.3 Track C, 2026-09-16) -------------------------------------------------------
        /// Run `FootPoseDetector` — the RTMPose-m Halpe-26 Core ML model — and add heel, big toe and
        /// little toe per foot to `BodyFrame.points2D`. Vision has no foot landmark at all, so this
        /// is the only source of them. Off by default because the model's training annotations are
        /// non-commercial research-only (`docs/DECISIONS.md` "feet detector"); every internal
        /// measurement path turns it on.
        public var detectFeet = false
        /// Run the foot model on every Nth analysed frame. 1 = the body-request rate.
        public var everyNthFrameFeet: Int = 1
        /// Also write the model's other 20 keypoints under a `footModel.` prefix, so they can be
        /// measured against Vision's own. Off: they are a cross-check, not a second body model.
        public var footModelCrossCheck = false
        /// Compute units for the foot model. `.all` lets Core ML use the ANE where it can.
        public var footComputeUnits: MLComputeUnits = .all
        public init() {}
    }

    // MARK: - Vision ↔ ArcLab name maps (explicit, so a Vision rename cannot pass silently)

    static let name3D: [HumanBodyPose3DObservation.JointName: String] = [
        .topHead: Body3DJoint.topHead, .centerHead: Body3DJoint.centerHead, .centerShoulder: Body3DJoint.centerShoulder,
        .leftShoulder: Body3DJoint.leftShoulder, .rightShoulder: Body3DJoint.rightShoulder,
        .leftElbow: Body3DJoint.leftElbow, .rightElbow: Body3DJoint.rightElbow,
        .leftWrist: Body3DJoint.leftWrist, .rightWrist: Body3DJoint.rightWrist,
        .leftHip: Body3DJoint.leftHip, .rightHip: Body3DJoint.rightHip,
        .leftKnee: Body3DJoint.leftKnee, .rightKnee: Body3DJoint.rightKnee,
        .leftAnkle: Body3DJoint.leftAnkle, .rightAnkle: Body3DJoint.rightAnkle,
        .root: Body3DJoint.root, .spine: Body3DJoint.spine]

    static let name2D: [HumanBodyPoseObservation.JointName: String] = [
        .nose: Body2DPoint.nose, .neck: Body2DPoint.neck, .root: Body2DPoint.root,
        .leftEye: Body2DPoint.leftEye, .rightEye: Body2DPoint.rightEye,
        .leftEar: Body2DPoint.leftEar, .rightEar: Body2DPoint.rightEar,
        .leftShoulder: Body2DPoint.leftShoulder, .rightShoulder: Body2DPoint.rightShoulder,
        .leftElbow: Body2DPoint.leftElbow, .rightElbow: Body2DPoint.rightElbow,
        .leftWrist: Body2DPoint.leftWrist, .rightWrist: Body2DPoint.rightWrist,
        .leftHip: Body2DPoint.leftHip, .rightHip: Body2DPoint.rightHip,
        .leftKnee: Body2DPoint.leftKnee, .rightKnee: Body2DPoint.rightKnee,
        .leftAnkle: Body2DPoint.leftAnkle, .rightAnkle: Body2DPoint.rightAnkle]

    static let nameHand: [HumanHandPoseObservation.JointName: String] = [
        .wrist: HandLandmark.wrist,
        .thumbCMC: HandLandmark.thumbCMC, .thumbMP: HandLandmark.thumbMP, .thumbIP: HandLandmark.thumbIP, .thumbTip: HandLandmark.thumbTip,
        .indexMCP: HandLandmark.indexMCP, .indexPIP: HandLandmark.indexPIP, .indexDIP: HandLandmark.indexDIP, .indexTip: HandLandmark.indexTip,
        .middleMCP: HandLandmark.middleMCP, .middlePIP: HandLandmark.middlePIP, .middleDIP: HandLandmark.middleDIP, .middleTip: HandLandmark.middleTip,
        .ringMCP: HandLandmark.ringMCP, .ringPIP: HandLandmark.ringPIP, .ringDIP: HandLandmark.ringDIP, .ringTip: HandLandmark.ringTip,
        .littleMCP: HandLandmark.littleMCP, .littlePIP: HandLandmark.littlePIP, .littleDIP: HandLandmark.littleDIP, .littleTip: HandLandmark.littleTip]

    // MARK: - The pass

    /// One decode pass over `[start, end]` file seconds.
    ///
    /// - Parameters:
    ///   - ballSeed: `(file pts, ball centre in full-frame px)`. Used only to pick the right person and
    ///     to label the shooting hand — never to place the body.
    ///   - fps: when given, `BodyFrame.frameIndex` is `round(pts × fps)`, the key `BallDetector` uses.
    public static func run(url: URL, start: Double, end: Double, options: Options = Options(),
                           ballSeed: [(pts: Double, uv: SIMD2<Double>)] = [],
                           fps: Double? = nil) async throws -> BodyTimeline {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoReaderError.noVideoTrack }
        let natural = try await track.load(.naturalSize)
        let imageSize = CGSize(width: abs(natural.width), height: abs(natural.height))

        let reader = VideoReader(url: url)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        // `DetectHumanBodyPose3DRequest` is a `StatefulRequest`: left at its default spacing it analyses
        // roughly one frame in three and returns nothing on the rest. `.zero` asks for every frame.
        let request3D = DetectHumanBodyPose3DRequest(nil, frameAnalysisSpacing: options.frameAnalysisSpacing3D)
        let request2D = DetectHumanBodyPoseRequest()
        var requestHand = DetectHumanHandPoseRequest()
        requestHand.maximumHandCount = options.maximumHandCount
        let seeds = ballSeed.sorted { $0.pts < $1.pts }
        let step = max(1, options.everyNthFrame)
        let scale = options.timeScale > 0 ? options.timeScale : 1

        // Two croppers, not one. `Cropper` caches a single destination buffer by size, and the body
        // crop and the 256 px hand crop are different sizes — sharing one made it allocate a fresh
        // `CVPixelBuffer` twice per frame. Measured on the 240 fps clip, one window: 10.3 s shared
        // against 5.9 s with a cropper each. It is the single largest cost in the stage.
        let cropper = Cropper()
        let handCropper = Cropper()
        // The feet: a Core ML request, not a Vision one, so it runs after the Vision block on this
        // frame's *own* 2-D points rather than the previous frame's. A top-down pose model locates a
        // foot partly from where the rest of the body is, so it is given the whole-person box
        // (research 2026-09-16 §1.5), which is exactly what those points define.
        var footDetector: FootPoseDetector? = nil
        var footNotes: [String] = []
        if options.detectFeet {
            do { footDetector = try FootPoseDetector(computeUnits: options.footComputeUnits) }
            catch { footNotes.append("the foot model could not be loaded, so no foot landmark exists on any frame of this window: \(error)") }
        }
        var footFrames = 0, footHits = 0, footSeconds = 0.0
        var frames: [BodyFrame] = []
        var cost = BodyStageCost()
        var decoded = 0, analysed = 0, misses = 0, failed3D = 0, failed2D = 0, failedHand = 0
        var handFocusFrames = 0, handFocusHits = 0
        var lockedHandCrop: Double? = nil
        /// The previous analysed frame's 2-D points, which place the hand crop when the requests run
        /// concurrently (this frame's 2-D result is not back yet). At 240 fps that is 8 ms of hand
        /// travel against a 256 px crop.
        var lastPoints2D: [String: BodyPoint2D] = [:]
        var currentCrop: CGRect? = nil
        var lockedCropSize: CGSize? = nil
        var notes: [String] = []
        let t0 = Date()

        // Only the analysed frames are re-wrapped into a `CMSampleBuffer`; the decoder still decodes every
        // frame (inter-frame coding), but a frame this pass never looks at costs nothing beyond that.
        try await reader.forEachFrame(timeRange: range, stride: step) { frame in
            defer { decoded = frame.index + 1 }
            if frame.pts > end + 1e-6 { return false }
            guard let full = frame.pixelBuffer else { return true }
            analysed += 1
            let seed = nearestSeed(seeds, pts: frame.pts)

            // Measured on macOS 26 (see PoseTracker): the body-pose requests return *nothing* for a
            // buffer carrying the decoder's `CVCleanAperture` attachment, even the degenerate
            // full-frame one AVAssetReader attaches to every frame of these clips. Strip it for the
            // duration of the requests and put it back. (A rendered crop has no attachment at all.)
            let cleanAperture = CVBufferCopyAttachment(full, kCVImageBufferCleanApertureKey, nil)
            if cleanAperture != nil { CVBufferRemoveAttachment(full, kCVImageBufferCleanApertureKey) }
            defer { if let c = cleanAperture { CVBufferSetAttachment(full, kCVImageBufferCleanApertureKey, c, .shouldPropagate) } }

            let cropRect = options.useCrop ? currentCrop : nil
            let target: CVPixelBuffer
            let targetSize: CGSize
            let origin: CGPoint
            let tCrop = Date()
            let croppedBuffer = cropRect.flatMap { cropper.crop(full, to: $0, imageSize: imageSize, renderScale: options.cropRenderScale) }
            cost.cropSeconds += Date().timeIntervalSince(tCrop)
            if let cropRect, let cropped = croppedBuffer {
                target = cropped; targetSize = cropRect.size; origin = cropRect.origin
            } else {
                target = full; targetSize = imageSize; origin = .zero
            }
            func toFull(_ p: Vision.NormalizedPoint) -> SIMD2<Double> {
                let q = p.toImageCoordinates(targetSize, origin: .upperLeft)
                return SIMD2(Double(q.x) + Double(origin.x), Double(q.y) + Double(origin.y))
            }

            var joints3D: [String: BodyJoint3D] = [:]
            var points2D: [String: BodyPoint2D] = [:]
            var hands: [BodyHandFrame] = []
            var bodyHeight: Double? = nil, technique: String? = nil
            var confidence3D: Double? = nil, confidence2D: Double? = nil

            // What runs on this frame. The three requests decimate independently; the hands decimate
            // again outside the release window, where nothing the hand model is for happens.
            let inFocus = options.handFocusRealTimeRange.map { $0.contains(frame.pts / scale) } ?? true
            let handsEvery = max(1, options.everyNthFrameHands) * (inFocus ? 1 : max(1, options.everyNthFrameHandsOutsideFocus))
            let run3D = options.detect3DBody && (analysed - 1) % max(1, options.everyNthFrame3D) == 0
            let runHands = options.detectHands && (analysed - 1) % handsEvery == 0

            func apply2D(_ observations: [HumanBodyPoseObservation]) {
                guard let o = choose2D(observations, targetSize: targetSize, origin: origin, seed: seed) else { return }
                confidence2D = Double(o.confidence)
                for (visionName, label) in name2D {
                    guard let j = o.joint(for: visionName) else { continue }
                    let uv = toFull(j.location)
                    points2D[label] = BodyPoint2D(name: label, u: uv.x, v: uv.y, confidence: Double(j.confidence))
                }
            }
            func apply3D(_ observations: [HumanBodyPose3DObservation]) {
                guard let o = choose3D(observations, targetSize: targetSize, origin: origin, seed: seed) else { return }
                confidence3D = Double(o.confidence)
                bodyHeight = o.bodyHeight.converted(to: .meters).value
                technique = o.heightEstimationTechnique == .measured ? "measured" : "reference"
                for (visionName, label) in name3D {
                    guard let j = o.joint(for: visionName) else { continue }
                    let model = translation(j.position)
                    let camera = translation(o.cameraRelativePosition(for: visionName))
                    let image = toFull(o.pointInImage(for: visionName))
                    joints3D[label] = BodyJoint3D(name: label, position: model, cameraPosition: camera,
                                                  imageU: image.x, imageV: image.y,
                                                  // Apple's `Joint3D` publishes no per-joint confidence;
                                                  // the observation-level one is on the frame instead.
                                                  confidence: nil)
                }
            }
            /// Near the release, hand the request its own tight crop around the shooting wrist —
            /// blended toward the ball when the ball track has a sample here. Everywhere else it
            /// shares the body crop. `from` is which frame's 2-D points place it: this frame's when
            /// the requests run one after another, the previous frame's when they run together.
            func placeHandCrop(from source: [String: BodyPoint2D]) -> (buffer: CVPixelBuffer, size: CGSize, origin: CGPoint, focused: Bool) {
                guard let window = options.handFocusRealTimeRange, window.contains(frame.pts / scale),
                      let centre = handCentre(points2D: source, shootingSide: options.shootingSide, seed: seed,
                                              bias: options.handFocusForearmBias,
                                              ballBlend: options.handFocusUsesBall ? options.handFocusBallBlend : 0),
                      let box = squareCrop(around: centre.uv,
                                           side: lockedHandCrop ?? {
                                               let s = options.handFocusCropPx > 0 ? options.handFocusCropPx
                                                     : max(options.handFocusMinimumCropPx, options.handFocusCropForearms * centre.forearmPx)
                                               lockedHandCrop = s
                                               return s
                                           }(),
                                           in: imageSize),
                      let cropped = handCropper.crop(full, to: box, imageSize: imageSize)
                else { return (target, targetSize, origin, false) }
                return (cropped, box.size, box.origin, true)
            }

            if options.concurrentRequests {
                // The three requests are independent work on the same frame; run them together.
                // Measured on the 240 fps clip: the serial sum is ~33 ms/frame and the concurrent
                // block ~14 ms, because the 2-D request is the long pole and the other two overlap it.
                let crop: (buffer: CVPixelBuffer, size: CGSize, origin: CGPoint, focused: Bool) =
                    runHands ? placeHandCrop(from: lastPoints2D) : (target, targetSize, origin, false)
                let bodyBox = Unchecked(target), handBox = Unchecked(crop.buffer)
                let r2 = Unchecked(request2D), r3 = Unchecked(request3D), rh = Unchecked(requestHand)
                let want2D = options.detect2DBody
                let t = Date()
                async let a2: [HumanBodyPoseObservation] = want2D ? ((try? await r2.value.perform(on: bodyBox.value)) ?? []) : []
                async let a3: [HumanBodyPose3DObservation] = run3D ? ((try? await r3.value.perform(on: bodyBox.value)) ?? []) : []
                async let ah: [HumanHandPoseObservation] = runHands ? ((try? await rh.value.perform(on: handBox.value)) ?? []) : []
                let (o2, o3, oh) = await (a2, a3, ah)
                cost.concurrentSeconds += Date().timeIntervalSince(t)
                cost.concurrentFrames += 1
                if want2D { cost.body2DFrames += 1; apply2D(o2) }
                if run3D { cost.body3DFrames += 1; apply3D(o3) }
                if runHands {
                    cost.handsFrames += 1
                    hands = label(oh, targetSize: crop.size, origin: crop.origin, seed: seed, shootingSide: options.shootingSide)
                    if crop.focused { handFocusFrames += 1; if !hands.isEmpty { handFocusHits += 1 } }
                }
            } else {
                if options.detect2DBody {
                    let t = Date()
                    defer { cost.body2DSeconds += Date().timeIntervalSince(t); cost.body2DFrames += 1 }
                    do { apply2D(try await request2D.perform(on: target)) } catch { failed2D += 1 }
                }
                if run3D {
                    let t = Date()
                    defer { cost.body3DSeconds += Date().timeIntervalSince(t); cost.body3DFrames += 1 }
                    do { apply3D(try await request3D.perform(on: target)) } catch { failed3D += 1 }
                }
                if runHands {
                    let t = Date()
                    defer { cost.handsSeconds += Date().timeIntervalSince(t); cost.handsFrames += 1 }
                    let crop = placeHandCrop(from: points2D)
                    do {
                        let observations = try await requestHand.perform(on: crop.buffer)
                        hands = label(observations, targetSize: crop.size, origin: crop.origin, seed: seed,
                                      shootingSide: options.shootingSide)
                        if crop.focused { handFocusFrames += 1; if !hands.isEmpty { handFocusHits += 1 } }
                    } catch { failedHand += 1 }
                }
            }
            if !points2D.isEmpty { lastPoints2D = points2D }

            // ---- feet -------------------------------------------------------------------------
            // `footPoints2D` is kept apart from `points2D` until the frame is built, so the tracked
            // crop (`jointBox`) still sees exactly the 19 Vision points it always saw: turning the
            // feet on must not move the crop and so change every other number in the pass.
            var footPoints2D: [String: BodyPoint2D] = [:]
            if let footDetector, (analysed - 1) % max(1, options.everyNthFrameFeet) == 0 {
                footFrames += 1
                if let box = FootPoseDetector.personBox(points2D: points2D) {
                    do {
                        let r = try footDetector.run(full, imageSize: imageSize, crop: box)
                        footSeconds += r.seconds
                        for (index, kp) in r.keypoints {
                            if let name = FootPoseDetector.footIndexToName[index] {
                                footPoints2D[name] = BodyPoint2D(name: name, u: kp.uv.x, v: kp.uv.y, confidence: kp.confidence)
                            } else if options.footModelCrossCheck {
                                let name = FootPoseDetector.crossCheckPrefix + FootPoseDetector.halpe26[index]
                                footPoints2D[name] = BodyPoint2D(name: name, u: kp.uv.x, v: kp.uv.y, confidence: kp.confidence)
                            }
                        }
                        if !footPoints2D.isEmpty { footHits += 1 }
                    } catch {
                        if footNotes.count < 3 { footNotes.append("the foot model threw on the frame at \(String(format: "%.3f", frame.pts)) s: \(error)") }
                    }
                }
            }

            let index = fps.map { Int((frame.pts * $0).rounded()) } ?? frame.index
            if !joints3D.isEmpty || !points2D.isEmpty || !hands.isEmpty || !footPoints2D.isEmpty {
                frames.append(BodyFrame(frameIndex: index, fileTime: frame.pts, realTime: frame.pts / scale,
                                        joints3D: joints3D, points2D: points2D.merging(footPoints2D) { a, _ in a }, hands: hands,
                                        crop: cropRect.map { BodyCrop(x: Double($0.origin.x), y: Double($0.origin.y),
                                                                      width: Double($0.width), height: Double($0.height)) },
                                        bodyHeightMetres: bodyHeight, heightEstimationTechnique: technique,
                                        confidence3D: confidence3D, confidence2D: confidence2D))
                misses = 0
                if options.useCrop, let box = jointBox(joints3D: joints3D, points2D: points2D) {
                    var next = pad(box, by: options.cropPadFraction, minimum: options.minimumCropPx, in: imageSize)
                    // The crop keeps **one size** for the whole pass. `DetectHumanBodyPose3DRequest` is a
                    // stateful request and returns nothing on almost every frame when the input size changes
                    // frame to frame (measured: 1/12 frames with a per-frame size, 12/12 with a fixed one).
                    if let locked = lockedCropSize {
                        if next.width > locked.width || next.height > locked.height {
                            lockedCropSize = CGSize(width: max(next.width, locked.width), height: max(next.height, locked.height))
                        }
                        next = centre(next, size: lockedCropSize!, in: imageSize)
                    } else {
                        lockedCropSize = next.size
                    }
                    currentCrop = next
                }
            } else {
                misses += 1
                if misses >= options.reacquireAfterMisses { currentCrop = nil; misses = 0 }
            }
            return true
        }

        let wall = Date().timeIntervalSince(t0)

        // ---- shooting vs guide hand, decided over the whole window ------------------------------
        // Per frame, the hand nearer the ball shoots. That is right on average and wrong whenever the
        // guide hand happens to pass in front, which flips the label for a few frames in the middle of
        // the release — exactly where the label matters. The ball track settles it once for the
        // window: the chirality that was nearer the ball on more frames is the shooting hand, and
        // every frame is then labelled by chirality. With no ball track, or with no chirality from
        // the detector, the per-frame labels stand and nothing is invented.
        if !seeds.isEmpty {
            var votes: [String: Int] = [:]
            for f in frames where f.hands.count >= 1 {
                guard let ball = nearestSeed(seeds, pts: f.fileTime) else { continue }
                var best: (c: String, d: Double)? = nil
                for h in f.hands {
                    guard let c = h.chirality,
                          let a = h.landmarks[HandLandmark.middleMCP] ?? h.landmarks[HandLandmark.wrist] else { continue }
                    let d = simd_length(a.uv - ball)
                    if best == nil || d < best!.d { best = (c, d) }
                }
                if let best { votes[best.c, default: 0] += 1 }
            }
            if let winner = votes.max(by: { $0.value < $1.value })?.key, votes.count >= 1 {
                let total = votes.values.reduce(0, +)
                let share = total > 0 ? Double(votes[winner] ?? 0) / Double(total) : 0
                for i in frames.indices {
                    for j in frames[i].hands.indices {
                        guard let c = frames[i].hands[j].chirality else { continue }
                        frames[i].hands[j].role = (c == winner) ? "shooting" : "guide"
                    }
                }
                notes.append(String(format: "shooting hand: the %@ hand was the one nearer the ball on %.0f %% of the %d frames that carried a ball sample and a chirality; every frame is labelled by that one decision rather than frame by frame",
                                    winner, 100 * share, total))
            }
        }

        // ---- the hand triangle's own 2-D points (1.3) ---------------------------------------------
        // Vision's hand landmarks are lifted into the canonical `Body2DPoint` names here, in the one
        // place Vision names appear, so that everything downstream — the skeleton fit, the coverage
        // table, the export, the form — sees a knuckle the way it sees a shoulder. `HandPoints.lift`
        // is in ShotGeometry (Foundation + simd) and does the naming, the wrist fallback and the
        // one-sample bridge; each of the three stamps a provenance on the point it writes.
        if options.detectHands {
            var lo = HandPoints.Options()
            lo.minimumHandLandmarkConfidence = options.minimumHandLandmarkConfidence
            lo.wristFromHandPose = options.wristFromHandPose
            lo.interpolateAcrossSamples = options.interpolateHandPointsAcrossSamples
            let lifted = HandPoints.lift(frames: frames, options: lo)
            frames = lifted.frames
            notes.append(contentsOf: lifted.report.notes)
            let withCorner = frames.filter { f in Body2DPoint.handCorners.contains { (f.points2D[$0]?.confidence ?? -1) >= lo.minimumHandLandmarkConfidence } }.count
            notes.append("hand triangle: \(withCorner) of \(frames.count) frame(s) carry at least one index/little MCP above \(String(format: "%.2f", lo.minimumHandLandmarkConfidence)) — the floor the hand detector needs, which is below the body pose's 0.30 because its landmark confidences run lower on a hand this small")
        }

        notes += footNotes
        if options.detectFeet {
            notes.append(String(format: "feet: the RTMPose-m Halpe-26 model ran on %d analysed frame(s) and returned at least one foot landmark on %d (%.0f %%), at %.1f ms/frame; Vision has no foot landmark at all, so these six points per frame have no second source to be checked against in-app",
                                footFrames, footHits, footFrames > 0 ? 100 * Double(footHits) / Double(footFrames) : 0,
                                footFrames > 0 ? 1000 * footSeconds / Double(footFrames) : 0))
        }
        if failed3D > 0 { notes.append("the 3-D body request threw on \(failed3D) frame(s)") }
        if failed2D > 0 { notes.append("the 2-D body request threw on \(failed2D) frame(s)") }
        if failedHand > 0 { notes.append("the hand request threw on \(failedHand) frame(s)") }
        let with3D = frames.filter { !$0.joints3D.isEmpty }.count
        notes.append("\(analysed) frame(s) analysed of \(decoded) decoded (every \(step)); 3-D body on \(with3D), 2-D body on \(frames.filter { !$0.points2D.isEmpty }.count), hands on \(frames.filter { !$0.hands.isEmpty }.count)")
        if options.useCrop { notes.append("tracked crop: the first frame runs full-frame to acquire the body, then each frame crops to the previous frame's joint box padded by \(Int(options.cropPadFraction * 100))%") }
        if let w = options.handFocusRealTimeRange {
            notes.append(String(format: "hand focus: a fixed %.0f px crop on the 2-D shooting wrist over real %.3f–%.3f s; a hand was found on %d of %d focused frames (%.0f %%)",
                                lockedHandCrop ?? options.handFocusCropPx, w.lowerBound, w.upperBound, handFocusHits, handFocusFrames,
                                handFocusFrames > 0 ? 100 * Double(handFocusHits) / Double(handFocusFrames) : 0))
        }
        let techniques = Set(frames.compactMap(\.heightEstimationTechnique))
        if techniques == ["reference"] {
            notes.append("every 3-D observation used the *reference* height estimate: there is no depth in this clip, so the metric scale is a population prior, not a measurement")
        }
        if options.everyNthFrame3D > 1 {
            notes.append("the 3-D body request ran on every \(options.everyNthFrame3D) analysed frame(s): the fit takes only the front/back sign of each joint's depth from it, and that sign is held across the gap (BodySkeletonOptions.depthSeedHoldSeconds)")
        }
        if options.everyNthFrameHands > 1 {
            notes.append("the hand request ran on every \(options.everyNthFrameHands) analysed frame(s)")
        }
        return BodyTimeline(frames: frames, timeScale: scale, imageWidth: Int(imageSize.width), imageHeight: Int(imageSize.height),
                            everyNthFrame: step, decodedFrames: decoded, analysedFrames: analysed, wallSeconds: wall,
                            notes: notes, cost: cost)
    }

    // MARK: - Helpers

    /// Where to centre the tight hand crop: the shooting wrist, pushed a little further along the
    /// forearm because the hand is beyond the wrist, never behind it. Nil when the 2-D body did not
    /// give a wrist on this frame — the caller then falls back to the body crop rather than guessing.
    /// - Parameter ballBlend: 0…1, how far from the biased wrist toward the ball centre the crop is
    ///   moved when the ball track has a sample on this frame. The ball is the better-localised of
    ///   the two (a fitted circle against a joint estimate) and at the release the hand is on it.
    static func handCentre(points2D: [String: BodyPoint2D], shootingSide: String?, seed: SIMD2<Double>?,
                           bias: Double, ballBlend: Double = 0) -> (uv: SIMD2<Double>, forearmPx: Double)? {
        func pt(_ n: String) -> SIMD2<Double>? {
            guard let p = points2D[n], p.confidence >= 0.2 else { return nil }
            return p.uv
        }
        let left = pt(Body2DPoint.leftWrist), right = pt(Body2DPoint.rightWrist)
        var side = shootingSide
        if side == nil, let s = seed {
            let dl = left.map { simd_length($0 - s) } ?? .infinity
            let dr = right.map { simd_length($0 - s) } ?? .infinity
            side = dl < dr ? "left" : "right"
        }
        let wrist = (side == "left" ? left : right) ?? right ?? left
        guard let wrist else { return nil }
        /// Move the centre toward the ball, but never further than one forearm from the wrist: past
        /// the release the ball leaves and the hand does not go with it.
        func toBall(_ p: SIMD2<Double>, _ forearmPx: Double) -> SIMD2<Double> {
            guard ballBlend > 0, let s = seed else { return p }
            let d = (s - p) * ballBlend
            let limit = forearmPx > 1 ? forearmPx : 80
            let n = simd_length(d)
            return p + (n > limit ? d / n * limit : d)
        }
        let elbow = pt(side == "left" ? Body2DPoint.leftElbow : Body2DPoint.rightElbow)
        guard let elbow else { return (toBall(wrist, 0), 0) }
        let forearm = wrist - elbow
        let n = simd_length(forearm)
        guard n > 1e-6 else { return (toBall(wrist, 0), 0) }
        return (toBall(wrist + (forearm / n) * (bias * n), n), n)
    }

    /// A fixed-size square crop centred as close to `centre` as the frame allows.
    static func squareCrop(around centre: SIMD2<Double>, side: Double, in imageSize: CGSize) -> CGRect? {
        let s = min(side, min(Double(imageSize.width), Double(imageSize.height)))
        guard s >= 32 else { return nil }
        let x = min(max(0, centre.x - s / 2), Double(imageSize.width) - s)
        let y = min(max(0, centre.y - s / 2), Double(imageSize.height) - s)
        return CGRect(x: x, y: y, width: s, height: s)
    }

    static func translation(_ m: simd_float4x4) -> SIMD3<Double> {
        SIMD3(Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z))
    }

    /// The pixel box that contains everything found on a frame, in full-frame coordinates.
    static func jointBox(joints3D: [String: BodyJoint3D], points2D: [String: BodyPoint2D]) -> CGRect? {
        var us: [Double] = [], vs: [Double] = []
        for j in joints3D.values { if let u = j.imageU, let v = j.imageV { us.append(u); vs.append(v) } }
        for p in points2D.values where p.confidence >= 0.2 { us.append(p.u); vs.append(p.v) }
        guard us.count >= 3, let u0 = us.min(), let u1 = us.max(), let v0 = vs.min(), let v1 = vs.max(), u1 > u0, v1 > v0 else { return nil }
        return CGRect(x: u0, y: v0, width: u1 - u0, height: v1 - v0)
    }

    /// Pad a box, keep it inside the frame, and round it to even pixels (4:2:0 chroma siting).
    static func pad(_ box: CGRect, by fraction: Double, minimum: Double, in imageSize: CGSize) -> CGRect {
        let padX = max(box.width * fraction, (minimum - box.width) / 2, 8)
        let padY = max(box.height * fraction, (minimum - box.height) / 2, 8)
        var r = box.insetBy(dx: -padX, dy: -padY)
        r.origin.x = max(0, (r.origin.x / 2).rounded(.down) * 2)
        r.origin.y = max(0, (r.origin.y / 2).rounded(.down) * 2)
        r.size.width = min((r.width / 2).rounded(.up) * 2, imageSize.width - r.origin.x)
        r.size.height = min((r.height / 2).rounded(.up) * 2, imageSize.height - r.origin.y)
        return r
    }

    /// Re-centre a box on `rect`'s centre at a fixed size, kept inside the frame.
    static func centre(_ rect: CGRect, size: CGSize, in imageSize: CGSize) -> CGRect {
        let w = min(size.width, imageSize.width), h = min(size.height, imageSize.height)
        var x = rect.midX - w / 2, y = rect.midY - h / 2
        x = min(max(0, (x / 2).rounded(.down) * 2), imageSize.width - w)
        y = min(max(0, (y / 2).rounded(.down) * 2), imageSize.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func choose2D(_ observations: [HumanBodyPoseObservation], targetSize: CGSize, origin: CGPoint,
                         seed: SIMD2<Double>?) -> HumanBodyPoseObservation? {
        guard observations.count > 1 else { return observations.first }
        func wristDistance(_ o: HumanBodyPoseObservation) -> Double {
            guard let s = seed else { return .infinity }
            var best = Double.infinity
            for name in [HumanBodyPoseObservation.JointName.leftWrist, .rightWrist] {
                guard let j = o.joint(for: name), j.confidence >= 0.1 else { continue }
                let q = j.location.toImageCoordinates(targetSize, origin: .upperLeft)
                best = min(best, simd_length(SIMD2(Double(q.x) + Double(origin.x), Double(q.y) + Double(origin.y)) - s))
            }
            return best
        }
        if seed != nil, let best = observations.min(by: { wristDistance($0) < wristDistance($1) }), wristDistance(best).isFinite { return best }
        return observations.max(by: { $0.confidence < $1.confidence })
    }

    static func choose3D(_ observations: [HumanBodyPose3DObservation], targetSize: CGSize, origin: CGPoint,
                         seed: SIMD2<Double>?) -> HumanBodyPose3DObservation? {
        guard observations.count > 1 else { return observations.first }
        func wristDistance(_ o: HumanBodyPose3DObservation) -> Double {
            guard let s = seed else { return .infinity }
            var best = Double.infinity
            for name in [HumanBodyPose3DObservation.JointName.leftWrist, .rightWrist] {
                let q = o.pointInImage(for: name).toImageCoordinates(targetSize, origin: .upperLeft)
                best = min(best, simd_length(SIMD2(Double(q.x) + Double(origin.x), Double(q.y) + Double(origin.y)) - s))
            }
            return best
        }
        if seed != nil, let best = observations.min(by: { wristDistance($0) < wristDistance($1) }), wristDistance(best).isFinite { return best }
        return observations.max(by: { $0.confidence < $1.confidence })
    }

    /// Hands, with the shooting/guide roles assigned. With a ball seed the nearer hand shoots; without
    /// one the caller's `shootingSide` decides; with neither the role stays nil rather than guessed.
    static func label(_ observations: [HumanHandPoseObservation], targetSize: CGSize, origin: CGPoint,
                      seed: SIMD2<Double>?, shootingSide: String?) -> [BodyHandFrame] {
        var out: [(frame: BodyHandFrame, toBall: Double)] = []
        for o in observations {
            var landmarks: [String: BodyPoint2D] = [:]
            for (visionName, label) in nameHand {
                guard let j = o.joint(for: visionName) else { continue }
                let q = j.location.toImageCoordinates(targetSize, origin: .upperLeft)
                landmarks[label] = BodyPoint2D(name: label, u: Double(q.x) + Double(origin.x), v: Double(q.y) + Double(origin.y),
                                               confidence: Double(j.confidence))
            }
            guard !landmarks.isEmpty else { continue }
            let chirality: String? = o.chirality.map { $0 == .left ? "left" : "right" }
            var distance = Double.infinity
            if let s = seed {
                let anchor = landmarks[HandLandmark.middleMCP] ?? landmarks[HandLandmark.wrist] ?? landmarks.values.first!
                distance = simd_length(SIMD2(anchor.u, anchor.v) - s)
            }
            out.append((BodyHandFrame(chirality: chirality, role: nil, confidence: Double(o.confidence), landmarks: landmarks), distance))
        }
        guard !out.isEmpty else { return [] }
        if seed != nil, out.contains(where: { $0.toBall.isFinite }) {
            let nearest = out.indices.min(by: { out[$0].toBall < out[$1].toBall })!
            for i in out.indices { out[i].frame.role = (i == nearest) ? "shooting" : "guide" }
        } else if let side = shootingSide {
            for i in out.indices {
                guard let c = out[i].frame.chirality else { continue }
                out[i].frame.role = (c == side) ? "shooting" : "guide"
            }
        }
        return out.map(\.frame)
    }

    /// Nearest seed in time; nil when none is within `tolerance`.
    static func nearestSeed(_ seeds: [(pts: Double, uv: SIMD2<Double>)], pts: Double, tolerance: Double = 0.05) -> SIMD2<Double>? {
        guard !seeds.isEmpty else { return nil }
        var lo = 0, hi = seeds.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if seeds[mid].pts < pts { lo = mid + 1 } else { hi = mid }
        }
        var best = lo
        if lo > 0, abs(seeds[lo - 1].pts - pts) < abs(seeds[lo].pts - pts) { best = lo - 1 }
        return abs(seeds[best].pts - pts) <= tolerance ? seeds[best].uv : nil
    }
}

/// Carries a value across a child-task boundary that the compiler cannot prove safe. Used only for
/// a `CVPixelBuffer` that is read — never written — by the concurrent Vision requests on one frame,
/// and for the request values themselves, which are stateless from this file's point of view.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Renders a sub-rectangle of a decoded frame into its own pixel buffer, so the detector sees a
/// person that fills the image. Buffers are cached by size: the tracked crop changes size rarely.
final class Cropper: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var buffer: CVPixelBuffer?
    private var bufferSize: CGSize = .zero
    private var dumped = false

    /// - Parameters:
    ///   - rect: the crop in **top-left** full-frame pixel coordinates.
    ///   - renderScale: render the crop at this fraction of its full-frame size. Vision's requests
    ///     answer in *normalised* coordinates, which are resolution-independent, so the caller still
    ///     maps them through `rect.size` and nothing downstream changes — only how many pixels the
    ///     detector is given, which is what its cost scales with.
    func crop(_ source: CVPixelBuffer, to rect: CGRect, imageSize: CGSize, renderScale: Double = 1) -> CVPixelBuffer? {
        let s = max(0.1, min(1.0, renderScale))
        let w = Int((rect.width * s).rounded()), h = Int((rect.height * s).rounded())
        guard w >= 32, h >= 32 else { return nil }
        if buffer == nil || Int(bufferSize.width) != w || Int(bufferSize.height) != h {
            var made: CVPixelBuffer?
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
            guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &made) == kCVReturnSuccess,
                  let made else { return nil }
            buffer = made; bufferSize = CGSize(width: w, height: h)
        }
        guard let destination = buffer else { return nil }
        // CIImage is y-up with its origin at the bottom-left of the extent; the pixel buffer's first
        // row is the top of that extent. Flip the rect's y before cropping.
        let image = CIImage(cvPixelBuffer: source)
        let ciRect = CGRect(x: rect.origin.x, y: imageSize.height - rect.origin.y - rect.height, width: rect.width, height: rect.height)
        let cropped = image.cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.origin.x, y: -ciRect.origin.y))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        context.render(cropped, to: destination, bounds: CGRect(x: 0, y: 0, width: Double(w), height: Double(h)),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        // Debug hatch: ARCLAB_DUMP_CROP=<path.png> writes the first crop so the rectangle can be eyeballed.
        if let path = ProcessInfo.processInfo.environment["ARCLAB_DUMP_CROP"], !dumped {
            dumped = true
            try? context.writePNGRepresentation(of: CIImage(cvPixelBuffer: destination), to: URL(fileURLWithPath: path),
                                                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return destination
    }
}
