import Foundation
import ShotGeometry
import ShotVideo

/// The pose stage's output for one shot: the release instant it found (which the analyzer then used),
/// the camera-side 2-D joint angles, and the reason when either could not be produced.
///
/// The angles are image-plane angles. A 2-D angle between two limb segments equals the true 3-D angle
/// only when the limb lies in the image plane, so `viewWarning` carries the analyzer's own view class
/// and must be shown wherever the angles are shown (brief §11, `docs/reference/digest-ch10-11-events-pose.md`).
struct ShotPoseResult: Sendable {
    var poseFrames: Int                 // frames on which Vision found a body
    var everyNthFrame: Int              // 1 = every frame; 2 = every other frame
    var ballDiameterPx: Double          // median detection diameter, the scale the release rule uses
    var releaseFileTime: Double?        // file seconds
    var releaseRealTime: Double?        // file seconds ÷ time scale
    var angles: PoseAngles2D?
    /// Dip bottom → release, in **real** seconds: the shot's rhythm, measurable from the wrist alone.
    var dipToReleaseSeconds: Double?
    var dipUnavailableReason: String?
    /// Why there is no release instant (and therefore no angles).
    var releaseUnavailableReason: String?
    /// Why there are no angles even though a release was found.
    var anglesUnavailableReason: String?
    /// The analyzer's view classification, in words, attached after the fit: filled in by the runner.
    var viewWarning: String?
    /// Provenance, shown in the results screen.
    var notes: [String] = []
}

/// Everything one analysed shot produced. `Sendable` so the whole thing can cross back to the
/// main actor from the detached task that computed it.
struct ShotRunResult: Sendable {
    var analysis: ShotAnalysis
    var samples: [ImageSample]          // the detections the fit actually used, in real seconds
    var notes: [String]                 // provenance: which detector, how many samples, the time scale
    var visionTracks: Int
    var framesProcessed: Int
    var measuredFrameRate: Double       // file-time fps, from the decoded PTS
    var pose: ShotPoseResult?           // nil when the pose stage was switched off
    /// The per-shot body model over the dip → follow-through span, or nil with `bodyUnavailableReason`.
    var body: ShotBodyResult?
    var bodyUnavailableReason: String?
}

enum ShotRunError: Error, CustomStringConvertible {
    case noVisionSamples(tracks: Int, frames: Int)
    case noDetections(frames: Int)
    case tooFewSamples(Int)
    case emptyWindow

    var description: String {
        switch self {
        case .noVisionSamples(let tracks, let frames):
            return "Vision found no ball-sized track in this window (\(tracks) tracks over \(frames) frames). Move the window over the flight, or widen it."
        case .noDetections(let frames):
            return "no ball was found in this window (\(frames) frames decoded). Move the window over the flight, or widen it."
        case .tooFewSamples(let n):
            return "only \(n) ball detections in this window; the analyzer needs ≥ 12"
        case .emptyWindow:
            return "the window is empty: set an end time after the start time"
        }
    }
}

/// Clip + window + rim calibration → `ShotAnalysis`, exactly the sequence `TrajectoryProbe analyze
/// --classical --pose --fixed-g-azimuth` runs: Vision trajectory pass over the window, best ball-sized
/// sample per frame, those positions as the seed for the classical detector, Vision body pose for the
/// release instant, then `ShotAnalyzer` with the fixed-g azimuth solve. Nothing here invents a sample:
/// when a stage produces nothing it says so and the next stage is fed what actually exists.
enum ShotAnalysisRunner {
    /// Ball-size gate on the Vision samples, in pixels of diameter (the same numbers the desktop
    /// probe defaults to). Heads and hands are usually outside it at 1080p.
    static let minBallPx = 10.0
    static let maxBallPx = 140.0

    /// How often the body-pose pass samples the clip, in **pose frames per real second**. Vision's body request
    /// is the second-slowest stage on a phone and it does not get cheaper because the camera got faster, so the
    /// pass is throttled by real time rather than by file frames: 80 Hz is every 2nd frame on a 120 fps capture —
    /// the setting the three labelled free throws were measured with — and every 3rd frame on a 240 fps one.
    ///
    /// The cost is release quantisation: the rule only fires on a detection that has a pose frame within 0.75 of
    /// the median detection gap, so it waits for the next sampled frame. At 80 Hz that is ≤ 12.5 ms of real time,
    /// well inside the ±37 ms the rule itself was measured to in `docs/footage-2026-09-13/SHOOTER-REPORT.md`.
    /// Measured on the 240 fps clip (`docs/HANDOFF.md`, "Tracking at 240 fps", 13 windows, 10 accepted either
    /// way): against running the pose request on **every** frame, every 3rd moves the release instant by at
    /// most **9 ms** (2.2 frames at 240 fps) and the release angle by 0.24°, for 2.4× less Vision. Every 4th
    /// (60 Hz) also holds — 13 ms, 0.35° — and was **rejected**: it buys another 18 % of a stage that is no
    /// longer the bottleneck, and it doubles the quantisation floor that every `BodyShot` timing has to declare.
    static let poseSampleRateHz = 80.0

    /// A retry is only worth its seconds when the first attempt did not *see* enough of the ball. A window that
    /// produced a long, well-covered track and still fitted the wrong gravity will fit the wrong gravity again with
    /// looser thresholds — the geometry is what failed, not the detector. (Measured on the phone, 2026-09-14: three
    /// windows went through all three attempts, the loosened pass cost 12–14 s each, and none was rescued.)
    static let retryMinimumDetections = 20
    static let retryMinimumInliers = 15

    /// How far back the knee-bend search looks, in **real** seconds (converted to file seconds inside).
    static let kneeLookbackRealSeconds = 0.6

    /// How far past the ball's first detection the body-pose pass runs, in **real** seconds. The release rule only
    /// looks at frames where the ball is leaving the wrist, and the backward extension already puts the track's first
    /// detection in the hands, so half a second past it is more than the rule can use. Everything after that is the
    /// ball in free flight, where no wrist matters.
    static let poseTailRealSeconds = 0.5

    /// How far back the dip-bottom search looks, in **real** seconds. `report.py pose_metrics` uses the
    /// same 1.2 s: the lowest camera-side wrist in that span is the bottom of the dip.
    static let dipLookbackRealSeconds = 1.2
    /// A wrist below this confidence is not trusted to place the hand (the same floor `PoseMetrics2D` uses).
    static let jointConfidenceFloor = 0.4

    /// The body pass's span, in **real** seconds either side of the release: dip to follow-through.
    /// 1.5 s is `BodyKinematicsOptions.dipLookbackSeconds`, so the dip search never looks outside the
    /// frames that were actually analysed, and 0.4 s past release is `followThroughEnd` plus the hand
    /// window. Everything before the dip is the shooter standing still; everything after is the ball.
    static let bodyLookbackRealSeconds = 1.5
    static let bodyTailRealSeconds = 0.4

    /// At or above this **real** frame rate the body pass samples every 2nd frame. At 120 fps real
    /// that halves the Vision cost and leaves a 16.7 ms floor under every chain lag — which is stated
    /// with the lags rather than hidden. Below it (60 fps and under) every frame is analysed, because
    /// halving 60 fps would put the floor at 33 ms, above the lags the sequence is read from.
    static let bodyEveryNthFrameThresholdFPS = 100.0

    static func run(url: URL,
                    start: Double,
                    end: Double,
                    timeScale: Double,
                    calibration: RimCalibration,
                    intrinsics: CameraIntrinsics,
                    poseEveryNthFrame: Int? = nil,
                    runPose: Bool = true,
                    runBody: Bool = true,
                    shooterHeightMetres: Double? = ShooterProfile.heightMetres,
                    fps knownFPS: Double? = nil,
                    frameSize knownSize: (width: Int, height: Int)? = nil,
                    ballDiameterPxHint: Double? = nil,
                    seed seedIn: [Int: SIMD2<Double>] = [:],
                    useVisionSeed: Bool = false,
                    timings: StageTimings? = nil,
                    stage: @escaping @Sendable (String) -> Void) async throws -> ShotRunResult {
        guard end > start else { throw ShotRunError.emptyWindow }

        // The clip's true frame rate and frame size. The session already measured them during the scan, so a
        // window normally costs nothing here; a single-shot run pays for a 30-frame probe once.
        var fps = knownFPS ?? 0
        var frameWidth = knownSize?.width ?? 0, frameHeight = knownSize?.height ?? 0
        if fps <= 0 || frameWidth == 0 {
            stage("measuring the clip's true frame rate…")
            let probe = try await timings.measureAsync("probe") { try await VideoReader(url: url).quickProbe(maxFrames: 30) }
            fps = probe.measuredFrameRate
            frameWidth = probe.width; frameHeight = probe.height
        }
        guard fps > 0 else { throw ShotRunError.noDetections(frames: 0) }
        // Both throttles below are rates in **real** time, so a 240 fps clip is not charged twice what a 120 fps
        // clip is for the same shot (docs/HANDOFF.md, "Tracking at 240 fps").
        let realFPS = fps * timeScale
        let poseStep = poseEveryNthFrame ?? max(1, Int((realFPS / poseSampleRateHz).rounded()))

        // The Vision trajectory pass inside the window used to do two jobs: seed the detector, and stand in for it
        // when it found too little. It costs a whole extra decode plus ~5 ms a frame, and the session scanner
        // already knows where the ball is, so it is off by default and the scanner's candidates seed instead.
        var visionSamples: [ImageSample] = []
        var visionDetections: [BallDetection] = []
        var seed = seedIn
        var visionTracks = 0
        var framesProcessed = 0
        var visionRadiusDiameter: Double? = nil
        if useVisionSeed {
            var opt = TrajectoryTrackerOptions()
            opt.startTime = start
            opt.endTime = end
            stage("Vision trajectory pass over the window…")
            let run = try await timings.measureAsync("vision.trajectory") {
                try await TrajectoryTracker.run(url: url, options: opt) { frames, pts in
                    stage(String(format: "Vision trajectory pass: %d frames, t = %.2f s", frames, pts))
                }
            }
            visionTracks = run.tracks.count
            framesProcessed = run.framesProcessed
            var perFrame: [Int: TrackSample] = [:]
            for track in run.tracks {
                for smp in track.samples where 2 * smp.radiusPx >= minBallPx && 2 * smp.radiusPx <= maxBallPx {
                    let idx = Int((smp.pts * fps).rounded())
                    if let existing = perFrame[idx], existing.confidence >= smp.confidence { continue }
                    perFrame[idx] = smp
                }
            }
            guard !perFrame.isEmpty else {
                throw ShotRunError.noVisionSamples(tracks: run.tracks.count, frames: run.framesProcessed)
            }
            visionSamples = perFrame.keys.sorted().map { i -> ImageSample in
                let s = perFrame[i]!
                return ImageSample(t: s.pts / timeScale, uv: SIMD2(s.u, s.v), diameterPx: 2 * s.radiusPx)
            }
            visionDetections = perFrame.keys.sorted().map { i in
                let s = perFrame[i]!
                return BallDetection(frameIndex: i, pts: s.pts, u: s.u, v: s.v, diameterPx: 2 * s.radiusPx,
                                     score: Double(s.confidence), predicted: false, source: "detected", edge: false)
            }
            seed = Dictionary(uniqueKeysWithValues: perFrame.map { ($0.key, SIMD2($0.value.u, $0.value.v)) })
            if !visionSamples.isEmpty {
                let radii = perFrame.values.map(\.radiusPx).sorted()
                if !radii.isEmpty { visionRadiusDiameter = 1.6 * radii[radii.count / 2] }
            }
        }

        // The three parameter sets `tools/pytrack/run_loop.py` tries, in order. They differ only in thresholds,
        // so they all run on the **same decoded window**: the decode, the Core ML tiles and the background model
        // are paid for once and a retry is pure arithmetic.
        var base = BallDetectorOptions()
        // The detector's gates are speeds and durations; without the slow-motion factor it cannot turn them into
        // per-frame numbers and a 240 fps clip gets a 120 fps clip's allowances.
        base.timeScale = timeScale
        if let hint = ballDiameterPxHint, hint > 0 { base.expectedDiameterPx = hint }
        else if let d = visionRadiusDiameter { base.expectedDiameterPx = d }
        var classical = base
        classical.useCoreML = false                       // pure background difference: cheapest, and the most precise
        var loosened = base                               // `run_loop.py` LEVEL1 for BALL_COVERAGE_LOW / BALL_NO_FLIGHT
        loosened.diffThreshold = 0.8 * base.diffThreshold
        loosened.circularityMin = max(0.3, base.circularityMin - 0.1)
        loosened.minAreaFraction = 0.7 * base.minAreaFraction
        loosened.maxAreaFraction = 1.3 * base.maxAreaFraction
        loosened.maxGapSeconds = base.maxGapSeconds + 4.0 / 120
        loosened.templateMinScore = max(0.5, base.templateMinScore - 0.1)
        let attempts: [(name: String, options: BallDetectorOptions)] = [
            ("Core ML box + blob centroid", base),
            ("background difference only", classical),
            ("background difference, loosened thresholds", loosened),
        ]

        stage(String(format: "decoding the window once (ball ≈ %.0f px, %d seed position(s))…", base.expectedDiameterPx, seed.count))
        let window = try await BallDetector.decodeWindow(url: url, start: start, end: end, seed: seed, fps: fps,
                                                         options: base, timings: timings)
        guard window.frameCount >= 3 else { throw ShotRunError.noDetections(frames: window.frameCount) }
        if framesProcessed == 0 { framesProcessed = window.frameCount }

        let sizeNote = String(format: "time scale %.2f×: %.2f s of file time over the window; measured %.2f fps in the file → %.1f fps real",
                              timeScale, end - start, fps, fps * timeScale)
        var poses: [PoseFrame] = []
        var poseFailure: String? = nil
        var posesCaptured = false
        var poseRange: ClosedRange<Double> = start...end
        var best: (result: ShotRunResult, accepted: Bool, gError: Double)? = nil
        var firstError: Error? = nil
        var notesForSkip: String? = nil

        for (attempt, plan) in attempts.enumerated() {
            if attempt > 0 { stage("that window did not come out measurable; trying the \(plan.name) detector (no decode)…") }
            else { stage(String(format: "ball detector, %@ (%d frames, ball ≈ %.0f px)…", plan.name, window.frameCount, plan.options.expectedDiameterPx)) }

            var notes: [String] = []
            var samples = visionSamples
            var ballDetections = visionDetections
            let dets = BallDetector.track(window: window, seed: seed, options: plan.options, timings: timings).detections
            let templates = dets.filter { $0.source == "template" }.count
            // A blob cut by the frame edge has its centroid pulled inward — the apex of an arc that leaves the
            // top of the frame reads flatter than it is, and g fits low. Those frames stay in `ballDetections`
            // (the pose stage still wants them) but never reach the fit.
            let clipped = dets.filter(\.edge).count
            let fitted = dets.filter { !$0.edge }
            if fitted.count >= 12 {
                samples = fitted.map { ImageSample(t: $0.pts / timeScale, uv: SIMD2($0.u, $0.v), diameterPx: $0.diameterPx) }
                ballDetections = dets
                notes.append("ball positions: \(plan.name), \(dets.count) detections (\(dets.count - templates) blob, \(templates) template)"
                             + (seed.isEmpty ? "" : ", \(seed.count) scanner seed position(s)"))
                if clipped > 0 { notes.append("\(clipped) detection(s) touch the frame edge and were left out of the fit: a clipped blob's centroid is biased inward") }
            } else if !visionSamples.isEmpty {
                notes.append("the \(plan.name) detector returned \(fitted.count) unclipped detections (< 12): using the \(visionSamples.count) Vision samples instead")
            }
            guard samples.count >= 12 else {
                if firstError == nil { firstError = dets.isEmpty ? ShotRunError.noDetections(frames: window.frameCount) : ShotRunError.tooFewSamples(samples.count) }
                continue
            }
            notes.append(sizeNote)
            if frameWidth != intrinsics.width || frameHeight != intrinsics.height {
                notes.append("frame size \(frameWidth)×\(frameHeight) differs from the size the rim was marked on (\(intrinsics.width)×\(intrinsics.height)); re-mark the rim")
            }
            if attempt > 0 { notes.append("this window was retried: the \(attempts[0].name) detector did not produce a measurable shot, so the same decoded frames were re-tracked with \(plan.name)") }

            // Pose: the release instant, from the ball leaving the shooter's wrist. This is what made the
            // Python pipeline's release accurate; the ball alone cannot say when the hand let go, because the
            // tracker follows the ball while it is still held. Captured once, on the first attempt's detections.
            var pose: ShotPoseResult? = nil
            if runPose {
                if !posesCaptured {
                    // Only the part of the window that can carry the release is worth a body-pose pass: from the
                    // window's start (the dip is already clipped by it) to a little after the ball has left the
                    // hand. The rest is the ball in free flight, where no wrist matters.
                    let firstBall = ballDetections.map(\.pts).min() ?? start
                    let poseEnd = min(end, firstBall + poseTailRealSeconds * timeScale)
                    poseRange = start...max(start + 0.05, poseEnd)
                    let captured = await capturePoses(url: url, start: poseRange.lowerBound, end: poseRange.upperBound, fps: fps,
                                                      detections: ballDetections, everyNthFrame: poseStep,
                                                      timings: timings, stage: stage)
                    poses = captured.poses; poseFailure = captured.failure; posesCaptured = true
                }
                pose = poseResult(detections: ballDetections, poses: poses, poseFailure: poseFailure,
                                  timeScale: timeScale, fps: fps, start: poseRange.lowerBound, end: poseRange.upperBound,
                                  everyNthFrame: poseStep, realFPS: realFPS)
                if poseRange.upperBound < end - 1e-6 {
                    pose?.notes.append(String(format: "body pose ran over %.2f–%.2f s of the %.2f–%.2f s window (%.0f %% of it): the rest is the ball in free flight",
                                              poseRange.lowerBound, poseRange.upperBound, start, end,
                                              100 * (poseRange.upperBound - poseRange.lowerBound) / (end - start)))
                }
            }

            stage("solving the shot plane and fitting the parabola…")
            var ao = AnalysisOptions()
            ao.azimuthByFixedGravity = true
            if let rt = pose?.releaseRealTime {
                ao.windowOptions.releaseTimeOverride = rt
                notes.append(String(format: "release instant from the pose observer: %.3f s file time (%.4f s real); the ramp search was skipped", rt * timeScale, rt))
            }
            let analysis: ShotAnalysis
            do { analysis = try timings.measure("fit") { try ShotAnalyzer.analyze(track: samples, calibration: calibration, intrinsics: intrinsics, options: ao) } }
            catch { if firstError == nil { firstError = error }; continue }

            // 2-D pose angles are only meaningful in a near-side view, so they never travel without the
            // analyzer's own view classification.
            if var p = pose, p.angles != nil {
                let c = analysis.confidence
                p.viewWarning = String(format: "2-D pose angles are the %@-side limb projected into the image; valid only for a near-side view — this shot is %.0f° from side (%@)",
                                       p.angles!.side, Angle.degrees(c.viewAngle), c.viewClass.rawValue)
                pose = p
            }
            let result = ShotRunResult(analysis: analysis, samples: samples, notes: notes,
                                       visionTracks: visionTracks, framesProcessed: framesProcessed,
                                       measuredFrameRate: fps, pose: pose)
            let ok = ShotAcceptance.evaluate(analysis).isAccepted
            let gErr = analysis.confidence.gError
            // Keep the attempt that the block rule accepts; among equals, the one whose fitted gravity is closest
            // to 9.81 — g is the check, so it is the only tie-break that is not a preference.
            if best == nil || (ok && !best!.accepted) || (ok == best!.accepted && gErr < best!.gError) {
                best = (result, ok, gErr)
            }
            if ok { break }
            // Retry only a coverage failure. A long, well-covered track whose gravity came out wrong is a geometry
            // failure, and looser detector thresholds cannot mend geometry — they only cost seconds.
            let coverageFailure = fitted.count < retryMinimumDetections || analysis.confidence.nInliers < retryMinimumInliers
            if !coverageFailure {
                notesForSkip = String(format: "not retried with a looser detector: the ball was tracked on %d unclipped frames with %d inliers, so what failed is the plane/gravity solve, not the detection",
                                      fitted.count, analysis.confidence.nInliers)
                break
            }
        }
        if let skip = notesForSkip, var r = best?.result {
            r.notes.append(skip)
            best?.result = r
        }
        guard let chosen = best else { throw firstError ?? ShotRunError.noDetections(frames: window.frameCount) }
        var result = chosen.result

        // The body model. It runs once, on the attempt that was kept, and only over the frames that
        // carry a shot: ~1.5 s of real time before the release (the dip) to 0.4 s after it (the
        // follow-through). It never changes a ball number — the release it is given is the one the
        // analyzer already used — so a failure here costs the body card and nothing else.
        if runBody, result.analysis.confidence.gravityVerdict == .reject {
            // A window whose ball flight failed the gravity check is a contaminated window (a rebound, two
            // balls, a walk-through); its body numbers would be excluded from every statistic, so the
            // ~4.5 s stage is not spent on it. The card says why.
            result.bodyUnavailableReason = "the body model is not run on a window whose ball flight was rejected by the gravity check"
        } else if runBody {
            let releaseReal = result.pose?.releaseRealTime ?? result.analysis.window.releaseTime
            let side: String? = result.pose?.angles.map { $0.side == "l" ? "left" : "right" }
            let (body, why) = await bodyStage(url: url, releaseRealTime: releaseReal, timeScale: timeScale, fps: fps,
                                              samples: result.samples, intrinsics: intrinsics,
                                              rimImageU: calibration.ellipse.center.x, shootingSide: side,
                                              heightMetres: shooterHeightMetres, shotID: nil,
                                              timings: timings, stage: stage)
            result.body = body
            result.bodyUnavailableReason = why
        } else {
            result.bodyUnavailableReason = "the body model has not been measured for this shot yet"
        }
        return result
    }

    /// The body stage for a shot whose ball numbers are already in hand, so a session can show every shot's
    /// numbers first and pay for the body models afterwards (`SessionModel` runs the queue twice). It is exactly
    /// the work `run` does at its end — the same span, the same options, the same reasons — and it changes no
    /// ball number, so running it later cannot move one.
    static func bodyOnly(url: URL, result: ShotRunResult, timeScale: Double,
                         intrinsics: CameraIntrinsics, rimImageU: Double?,
                         shooterHeightMetres: Double? = ShooterProfile.heightMetres,
                         timings: StageTimings? = nil,
                         stage: @escaping @Sendable (String) -> Void = { _ in }) async -> (ShotBodyResult?, String?) {
        guard result.analysis.confidence.gravityVerdict != .reject else {
            return (nil, "the body model is not run on a window whose ball flight was rejected by the gravity check")
        }
        let releaseReal = result.pose?.releaseRealTime ?? result.analysis.window.releaseTime
        let side: String? = result.pose?.angles.map { $0.side == "l" ? "left" : "right" }
        return await bodyStage(url: url, releaseRealTime: releaseReal, timeScale: timeScale, fps: result.measuredFrameRate,
                               samples: result.samples, intrinsics: intrinsics,
                               rimImageU: rimImageU, shootingSide: side,
                               heightMetres: shooterHeightMetres, shotID: nil,
                               timings: timings, stage: stage)
    }

    /// `BodyTracker` over the dip → follow-through span, then the per-shot skeleton fit, then
    /// `BodyKinematics.model`. Never throws: a body failure leaves every ball number untouched and
    /// records the reason.
    ///
    /// The second decode is deliberate. The ball pass keeps half-resolution Y and Cr planes, which is
    /// all a blob detector needs and far less than Vision's three requests need; and the body span
    /// starts up to 1.5 s of real time before the analysis window does, because the dip usually
    /// happens before the scanner's window opens. So the frames are decoded again, but only the ~1.9 s
    /// of real time that carry a body.
    private static func bodyStage(url: URL, releaseRealTime: Double, timeScale: Double, fps: Double,
                                  samples: [ImageSample], intrinsics: CameraIntrinsics, rimImageU: Double?,
                                  shootingSide: String?, heightMetres: Double?, shotID: Int?,
                                  timings: StageTimings?,
                                  stage: @escaping @Sendable (String) -> Void) async -> (ShotBodyResult?, String?) {
        let realFPS = fps * timeScale
        guard realFPS > 0 else { return (nil, "the clip's real frame rate is not known, so the body span cannot be placed") }
        let step = realFPS >= bodyEveryNthFrameThresholdFPS ? 2 : 1
        let releaseFile = releaseRealTime * timeScale
        let startFile = max(0, releaseFile - bodyLookbackRealSeconds * timeScale)
        let endFile = max(startFile + 0.05, releaseFile + bodyTailRealSeconds * timeScale)

        var options = BodyTracker.Options()
        options.everyNthFrame = step
        options.timeScale = timeScale
        options.shootingSide = shootingSide
        // The hand request gets its own fixed 256 px crop on the wrist over release ± 0.4 s: measured
        // in `docs/PHASE2-PREP.md` (iteration 2) to lift the hand rate from 35/59 % to 67/72 %.
        options.handFocusRealTimeRange = (releaseRealTime - ShotBodyResult.handFocusRealSeconds)...(releaseRealTime + ShotBodyResult.handFocusRealSeconds)
        // The feet (1.3): heel, big toe and little toe from the foot detector on the same person crop.
        // On unless the shooter turned it off under You › Advanced; its cost is logged as `body.feet`.
        options.detectFeet = ShotBodyResult.feetEnabled

        stage(String(format: "body model over %.2f s of real time around the release (every %d%@ frame)…",
                     (endFile - startFile) / timeScale, step, step == 1 ? "" : "nd"))
        let tVision = StageTimings.now()
        let timeline: BodyTimeline
        do {
            let seed = samples.map { (pts: $0.t * timeScale, uv: $0.uv) }
            timeline = try await BodyTracker.run(url: url, start: startFile, end: endFile,
                                                 options: options, ballSeed: seed, fps: fps)
        } catch {
            return (nil, "the body pass failed (\(error))")
        }
        let visionSeconds = StageTimings.now() - tVision
        timings?.add("body.vision", visionSeconds)
        guard timeline.frames.contains(where: { !$0.points2D.isEmpty }) else {
            return (nil, "Vision found no body on any frame of the dip-to-follow-through span (the shooter may be outside the frame or too small)")
        }

        stage("fitting one skeleton to the whole shot…")
        var fitOptions = BodySkeletonOptions(intrinsics: intrinsics)
        // The rim ruler is never used as a body scale: on an oblique view the shooter is not at the
        // rim's depth, and it was measured to over-scale by 26 % (PHASE2-PREP, iteration 2).
        if let h = heightMetres { fitOptions.scale = .statedHeight(metres: h) }
        let tFit = StageTimings.now()
        var fit = BodySkeletonFit.fit(timeline: timeline, options: fitOptions)
        let fitSeconds = StageTimings.now() - tFit
        timings?.add("body.fit", fitSeconds)

        // The hand plates (1.3). They hang off the fitted wrist, so they run after the fit and before
        // the kinematics — `HandTriangleFit` returns the same timeline with the two knuckles added to
        // `joints3D`, which is what the model, the form and the record then see. The ball track goes in
        // because the guide hand's contact plane is defined at its last frame touching the ball.
        let ballTrack = samples.map { BodyBallSample(t: $0.t, u: $0.uv.x, v: $0.uv.y, diameterPx: $0.diameterPx ?? 0) }
        var handOptions = HandTriangleOptions(intrinsics: intrinsics)
        handOptions.shootingSide = shootingSide
        handOptions.rimImageU = rimImageU
        handOptions.ballTrack = ballTrack
        let tHands = StageTimings.now()
        let handFit = HandTriangleFit.fit(timeline: fit.timeline, releaseRealTime: releaseRealTime, options: handOptions)
        fit.timeline = handFit.timeline
        timings?.add("body.hands", since: tHands)

        var kOptions = BodyKinematicsOptions(shootingSide: shootingSide)
        kOptions.transverseYawUnavailableReason = fit.transverseYawUnavailableReason
        // Over a 1.5 s lookback the lowest hand is the shooter still holding the ball, not the dip:
        // on the three labelled free throws the lowest-frame rule returned 1500/1500/1454 ms, i.e.
        // the length of the window. The turning-point rule returns 0.36–0.44 s on the same frames.
        kOptions.dipIsLastTurningPoint = true
        let tModel = StageTimings.now()
        let model = BodyKinematics.model(timeline: fit.timeline, releaseRealTime: releaseRealTime,
                                         ballTrack: ballTrack, rimImageU: rimImageU, options: kOptions)
        // The foot triangles hang off the fitted ankles and read the set instant the model found, so
        // they run last; the model itself does not use them.
        var footFit: FootTriangleResult? = nil
        if options.detectFeet {
            let tFeet = StageTimings.now()
            var footOptions = FootTriangleOptions(intrinsics: intrinsics)
            footOptions.shootingSide = shootingSide
            footOptions.rimImageU = rimImageU
            footOptions.stature = fit.standingHeightMetres.value
            footOptions.statureProvenance = fit.scaleProvenance
            let feet = FootTriangleFit.run(timeline: fit.timeline, releaseRealTime: releaseRealTime,
                                           setRealTime: model.phases.setPoint.value, options: footOptions)
            fit.timeline = feet.timeline
            footFit = feet
            timings?.add("body.feet", since: tFeet)
        }
        let out = ShotBodyResult.make(model: model, fit: fit, timeline: fit.timeline,
                                      releaseRealTime: releaseRealTime, realFrameRate: realFPS,
                                      visionSeconds: visionSeconds, fitSeconds: fitSeconds,
                                      heightMetres: heightMetres, rimImageU: rimImageU, shotID: shotID,
                                      rawTimeline: timeline, handTriangles: handFit, footTriangles: footFit,
                                      source: BodyShotSource(kind: "app", build: nil, device: nil,
                                                             format: BodyShotFormat(w: intrinsics.width, h: intrinsics.height, fps: realFPS,
                                                                                    hfovDegrees: Angle.degrees(2 * atan(Double(intrinsics.width) / 2 / intrinsics.fx)),
                                                                                    provenance: "unstated")))
        // The kinematics and the `BodyShot` payload the export writes: small next to the Vision pass, but they
        // were the last part of the window that nothing counted.
        timings?.add("body.model", since: tModel)
        return (out, nil)
    }

    /// Vision body pose over the window → release instant (`ReleaseFromPose`) and camera-side angles
    /// (`PoseMetrics2D`). Never throws: a pose failure leaves the shot measurable from the ball alone,
    /// with the reason recorded.
    private static func capturePoses(url: URL, start: Double, end: Double, fps: Double,
                                     detections: [BallDetection], everyNthFrame: Int,
                                     timings: StageTimings?,
                                     stage: @escaping @Sendable (String) -> Void) async -> (poses: [PoseFrame], failure: String?) {
        let step = max(1, everyNthFrame)
        stage(step == 1 ? "Vision body pose over the window (every frame)…"
                        : "Vision body pose over the window (every \(step)nd frame)…")
        do {
            let seed = detections.map { (pts: $0.pts, uv: SIMD2($0.u, $0.v)) }
            return (try await timings.measureAsync("vision.pose") {
                try await PoseTracker.run(url: url, start: start, end: end, everyNthFrame: step,
                                          ballSeed: seed, fps: fps)
            }, nil)
        } catch {
            return ([], "the body-pose pass failed (\(error))")
        }
    }

    /// The release instant and the camera-side angles, from ball detections and already-captured pose frames.
    /// Pure: a retry with different detections reuses the same pose pass.
    private static func poseResult(detections: [BallDetection], poses: [PoseFrame], poseFailure: String?,
                                   timeScale: Double, fps: Double, start: Double, end: Double,
                                   everyNthFrame: Int, realFPS: Double) -> ShotPoseResult {
        let step = max(1, everyNthFrame)
        // An edge-clipped blob measures only the visible part of the ball, so it under-reads the diameter, and the
        // release rule is a distance in diameters: take the size from the unclipped frames.
        let clean = detections.filter { !$0.edge }
        let diameters = (clean.count >= 8 ? clean : detections).map(\.diameterPx).sorted()
        let ballPx = diameters.isEmpty ? 0 : diameters[diameters.count / 2]
        var out = ShotPoseResult(poseFrames: 0, everyNthFrame: step, ballDiameterPx: ballPx)
        guard ballPx > 0 else {
            out.releaseUnavailableReason = "no ball detection carried a diameter, so the release rule has no scale"
            return out
        }
        if let poseFailure {
            out.releaseUnavailableReason = poseFailure
            return out
        }
        out.poseFrames = poses.count
        out.notes.append(String(format: "body pose on %d of about %.0f frames in the window (every %d%@ frame), ball ≈ %.0f px over %d detections",
                                poses.count, (end - start) * fps / Double(step), step, step == 1 ? "" : (step == 2 ? "nd" : "th"),
                                ballPx, detections.count))
        if step > 1 {
            out.notes.append(String(format: "body pose runs on every %d%@ frame (about %.0f Hz of real time), which cuts the Vision cost by %d×; the release can land at most %d file frames late, %.0f ms of real time",
                                    step, step == 2 ? "nd" : (step == 3 ? "rd" : "th"), realFPS / Double(step), step,
                                    step - 1, 1000 * Double(step - 1) / max(1, realFPS)))
        }
        guard !poses.isEmpty else {
            out.releaseUnavailableReason = "Vision found no body in this window (the shooter may be outside the frame or too small)"
            return out
        }
        guard let r = ReleaseFromPose.estimate(detections: detections, poses: poses, ballDiameterPx: ballPx) else {
            out.releaseUnavailableReason = "no frame satisfied the release rule (ball ≥ 1 diameter from the nearer wrist, above it, and rising)"
            return out
        }
        out.releaseFileTime = r.pts
        out.releaseRealTime = r.pts / timeScale

        // Dip bottom → release: the lowest camera-side wrist in the 1.2 s of real time before release.
        // This is the rhythm number, and it needs no scale, so it survives a failed plane solve.
        let side = PoseMetrics2D.cameraSide(poses)
        let dip = poses
            .filter { $0.pts >= r.pts - dipLookbackRealSeconds * timeScale && $0.pts < r.pts }
            .compactMap { f -> (pts: Double, v: Double)? in
                guard let w = f.joints["\(side)_wrist"], w.confidence >= jointConfidenceFloor else { return nil }
                return (f.pts, w.v)
            }
            .max { $0.v < $1.v }                        // v grows downwards: the largest v is the lowest hand
        if let dip {
            out.dipToReleaseSeconds = (r.pts - dip.pts) / timeScale
        } else {
            out.dipUnavailableReason = "the \(side == "l" ? "left" : "right") wrist was never confident in the 1.2 s before release"
        }
        // `kneeLookbackPTS` is in the pose frames' own units, which are file seconds.
        // ± 0.1 s of real time around release, in pose frames — the same span whatever the capture rate.
        let extensionHalf = max(2, Int((0.1 * realFPS / Double(step)).rounded()))
        guard let angles = PoseMetrics2D.angles(poses: poses, releasePTS: r.pts, extensionHalfWindowFrames: extensionHalf,
                                                kneeLookbackPTS: kneeLookbackRealSeconds * timeScale) else {
            out.anglesUnavailableReason = "no pose frame near release carried a confident shoulder, elbow and wrist on the camera side"
            return out
        }
        out.angles = angles
        return out
    }
}
