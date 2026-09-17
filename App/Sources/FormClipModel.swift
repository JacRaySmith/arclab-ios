import Foundation
import Observation
import PhotosUI
import ShotGeometry
import SwiftUI
import ShotVideo
import simd

// ================================================================================================
// MARK: - Form-clip mode
// ================================================================================================
//
// The filming guide's second clip: the phone 3–4 m away, side-on, the whole body in frame, 240 fps,
// **and no rim**. At that distance the shooter is about 1,500 px tall instead of 500, which is what
// makes the ankle, the neck and the fingers readable — and it is also why the rim cannot be in shot
// and why the ball leaves the frame a few frames after it leaves the hand.
//
// So this path shares no step with the session path except the body model itself:
//
//   · the shots are found by the **body**, from the wrist's rise-and-release pattern
//     (`FormClipScanner`), not by a ball arriving at the rim;
//   · the release instant comes from the **ball leaving the shooting hand** while the ball is still
//     in frame near the hands, and from the **wrist's own highest point** when it is not, with the
//     spread of that substitute stated rather than hidden (`FormClipReleaseEstimator`);
//   · every ball number — release speed, angle, entry angle, depth, make or miss — is unavailable
//     with one sentence: *form clip: no rim in frame*. Nothing is estimated in its place.
//
// What comes out is the same per-shot body model the session path produces (`ShotBodyResult`) and
// the same block `FormModel`, so the 3-D viewer, the per-shot card and the progress screen all work
// on a form clip without knowing it was one.

@MainActor
@Observable
final class FormClipModel {

    // MARK: What the screen shows

    enum Phase: Equatable {
        case empty
        case importing
        case probing
        case ready
        case scanning
        case analysing
        case done
        case failed(String)
    }

    enum ShotStatus: Equatable {
        case queued
        case analysing(String)
        case measured
        case failed(String)
    }

    struct Shot: Identifiable {
        var id: Int
        var window: FormClipWindow
        var status: ShotStatus = .queued
        var body: ShotBodyResult?
        var release: FormClipRelease?
        var releaseUnavailableReason: String?
        /// Seconds of wall time this window cost, so the screen can say how long the rest will take.
        var seconds: Double?

        var isMeasured: Bool { if case .measured = status { return true }; return false }
        var form: ShotForm? { body?.form }
    }

    /// The reason every ball number on a form clip carries. One sentence, used everywhere.
    /// `nonisolated` because the measurement runs off the main actor and writes it into the result.
    nonisolated static let ballUnavailableReason = "form clip: no rim in frame"

    // MARK: State

    var phase: Phase = .empty
    var clip: ImportedClip?
    var recorded: RecordedClip?
    var probe: VideoProbeResult?
    var shots: [Shot] = []
    var scanMessage: String?
    var scanProgress: Double = 0
    var scanSeconds: Double?
    var scanNotes: [String] = []
    var samples: [FormClipSample] = []
    /// Wrist high points the scan looked at and refused, each with its reason (a dribble, a catch,
    /// a tip with no set): listed on the screen so a shot the shooter expected to see is accounted for.
    var rejected: [FormClipRejectedCandidate] = []
    /// "left"/"right": the shooting side, voted from the shots themselves (the wrist extended further
    /// from the body at the top of the rise — `FormClipScanner.shootingSide`). Nil when no shot showed
    /// both wrists, in which case each window carries whichever wrist rose.
    var shootingSide: String?
    /// Only set shots — a rise from a held set position — count as shots (`FormClipScanOptions.requireSetPlateau`).
    /// On by default: a form clip measures the set shot, and on the reference clip every quick tip
    /// and catch from under the rim lacked the set while every free throw had one. Off, a rise with
    /// no set is still reported, with that on its card.
    var setShotsOnly = true
    var analysisIndex: Int?
    var saved: SavedSession?
    var saveNote = ""
    var spot: ShotSpot?

    /// File seconds per real second. 1 for a clip recorded in the app (real timestamps).
    var timeScale: Double = 1
    var hfovDegrees: Double = 73.83
    var hfovProvenance = "assumed: the 1080p240 format of the phone this app was built against"

    private var analysisTask: Task<Void, Never>?

    var isBusy: Bool { phase == .importing || phase == .probing || phase == .scanning || phase == .analysing }

    var measuredShots: [Shot] { shots.filter(\.isMeasured) }

    /// The block's mean form, from the shots that produced one. Never recomputed from video.
    var blockFormModel: FormModel {
        let forms = measuredShots.compactMap(\.form)
        guard !forms.isEmpty else {
            return FormModel.unavailable(shots.isEmpty
                ? "no shot has been measured from this clip yet"
                : "no shot in this clip produced a 3-D form: the reasons are on each shot's card",
                label: "Form clip")
        }
        return FormModel.build(forms: forms, label: "Form clip", spot: spot?.rawValue, sessionID: nil,
                               date: Date().timeIntervalSince1970)
    }

    /// What identifies *this video*, computed exactly as `AnalysisModel.clipFingerprint` computes it,
    /// so one recording is one recording whichever screen read it. The temp file's name changes on
    /// every import; its size, frame count and track duration do not.
    var clipFingerprint: String? {
        guard let p = probe, p.decodedFrames > 0 else { return nil }
        return String(format: "%dx%d/%d/%.3f", p.width, p.height, p.decodedFrames, p.trackDuration)
    }

    /// Real seconds of clip, for the screen's estimate of the scan.
    var realDuration: Double {
        guard let p = probe, p.trackDuration > 0 else { return 0 }
        return p.trackDuration / max(timeScale, 0.001)
    }

    // MARK: Getting a clip

    func reset() {
        analysisTask?.cancel()
        analysisTask = nil
        shots = []; samples = []; rejected = []; scanNotes = []; scanMessage = nil; scanProgress = 0; scanSeconds = nil; shootingSide = nil
        saved = nil; analysisIndex = nil
        phase = clip == nil ? .empty : .ready
    }

    func useRecordedClip(_ r: RecordedClip) {
        reset()
        recorded = r
        clip = ImportedClip(url: r.url, source: .recordedInApp)
        hfovDegrees = r.videoFieldOfViewDegrees
        hfovProvenance = "read from the recording itself"
        phase = .probing
        let url = r.url
        Task {
            do {
                let result = try await Task.detached { try await VideoReader(url: url).probe() }.value
                probe = result
                timeScale = max(1, result.sloMoStretch)
                phase = .ready
                ActivityLog.shared.event("formclip.clip", ["source": "recordedInApp", "fps": result.measuredFrameRate,
                                                           "seconds": result.trackDuration, "hfov": hfovDegrees])
            } catch {
                phase = .failed("Could not read the recording: \(error)")
            }
        }
    }

    func importAndProbe(_ item: PhotosPickerItem) {
        reset()
        recorded = nil
        phase = .importing
        Task {
            do {
                let imported = try await Task.detached { try await ClipImporter.importClip(from: item) }.value
                clip = imported
                phase = .probing
                let url = imported.url
                let result = try await Task.detached { try await VideoReader(url: url).probe() }.value
                probe = result
                // A clip from Photos carries no lens: the file cannot say what field of view made it.
                // The time base it *can* say, through the edit list; a slo-mo export that rewrote its
                // timestamps reads 1.00× and is treated as real time, which is right for the body
                // model — every phase is measured on the clip's own clock, and only the *labels* in
                // milliseconds would be wrong. The screen says so.
                timeScale = max(1, result.sloMoStretch)
                phase = .ready
                ActivityLog.shared.event("formclip.clip", ["source": imported.source.rawValue, "fps": result.measuredFrameRate,
                                                           "seconds": result.trackDuration, "stretch": result.sloMoStretch])
            } catch {
                phase = .failed("Import failed: \(error)")
            }
        }
    }

    // MARK: 2 — find the shots, from the body

    func scan() {
        guard let clip, !isBusy else { return }
        phase = .scanning
        shots = []; scanNotes = []; scanProgress = 0
        scanMessage = "reading the whole clip and following your wrists…"
        var options = FormClipScanOptions()
        options.timeScale = timeScale
        options.requireSetPlateau = setShotsOnly
        let url = clip.url
        let total = realDuration
        let opts = options
        let t0 = Date()
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { [opts] in
                    try await FormClipScanner.scan(url: url, options: opts) { reached, _ in
                        Task { @MainActor in
                            self.scanProgress = total > 0 ? min(1, reached / total) : 0
                            self.scanMessage = String(format: "%.0f s of %.0f s read", reached, total)
                        }
                    }
                }.value
                samples = result.samples
                shootingSide = result.shootingSide
                rejected = result.rejected
                scanNotes = result.notes
                scanSeconds = Date().timeIntervalSince(t0)
                shots = result.windows.map { Shot(id: $0.id, window: $0) }
                scanMessage = shots.isEmpty
                    ? (rejected.isEmpty
                       ? "no shot was found: nothing in this clip lifted a wrist above the shoulder line by more than half a torso length"
                       : "no shot was found; \(rejected.count) wrist high point\(rejected.count == 1 ? " was" : "s were") refused, listed below with the reason")
                    : "\(shots.count) shot\(shots.count == 1 ? "" : "s") found"
                phase = shots.isEmpty ? .ready : .analysing
                ActivityLog.shared.event("formclip.scan", ["windows": shots.count, "refused": rejected.count, "samples": samples.count,
                                                           "seconds": scanSeconds, "bodyFrames": result.framesWithBody,
                                                           "analysed": result.analysedFrames, "side": shootingSide,
                                                           "setShotsOnly": setShotsOnly])
                if !shots.isEmpty { analyseAll() }
            } catch {
                phase = .failed("The scan failed: \(error)")
            }
        }
    }

    // MARK: 3 — the body model, one window at a time

    func analyseAll() {
        guard let clip, analysisTask == nil else { return }
        phase = .analysing
        let url = clip.url
        let scale = timeScale
        let hfov = hfovDegrees
        let height = ShooterProfile.heightMetres
        let fps = (probe?.measuredFrameRate ?? 0) > 0 ? probe!.measuredFrameRate : 240
        let series = samples
        let hfovProvenance = recorded != nil ? "sidecar" : "assumed"
        analysisTask = Task {
            for index in shots.indices {
                if Task.isCancelled { break }
                guard !shots[index].isMeasured else { continue }
                analysisIndex = index
                let window = shots[index].window
                shots[index].status = .analysing("body model over the 1.9 s around the release…")
                let t0 = Date()
                let outcome = await Self.measure(url: url, window: window, samples: series, fps: fps,
                                                 timeScale: scale, hfovDegrees: hfov, heightMetres: height)
                shots[index].seconds = Date().timeIntervalSince(t0)
                shots[index].body = outcome.body
                shots[index].release = outcome.release
                shots[index].releaseUnavailableReason = outcome.releaseReason
                shots[index].status = outcome.body == nil ? .failed(outcome.failure ?? "the body model produced nothing") : .measured
                // Every measured shot is filed, the way the session path files each accepted shot:
                // there is no ball verdict here to gate on, and the body model is the whole result.
                if let record = outcome.body?.bodyShot {
                    BodyShotWriter.write(record, sessionKey: "formclip-" + url.deletingPathExtension().lastPathComponent,
                                         shotID: window.id, hfovProvenance: hfovProvenance)
                }
                ActivityLog.shared.event("formclip.shot", ["id": window.id, "seconds": shots[index].seconds,
                                                           "release": outcome.release?.realTime,
                                                           "source": outcome.release?.source.rawValue,
                                                           "failed": outcome.failure])
            }
            analysisIndex = nil
            analysisTask = nil
            phase = .done
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        phase = .done
    }

    /// Estimated seconds left, from the windows already measured. Nil until one has finished — an
    /// estimate with no measurement behind it is a guess.
    var estimatedSecondsRemaining: Double? {
        let done = shots.compactMap(\.seconds)
        guard !done.isEmpty else { return nil }
        let median = done.sorted()[done.count / 2]
        let left = shots.filter { !$0.isMeasured && { if case .failed = $0.status { return false }; return true }($0) }.count
        return left > 0 ? median * Double(left) : nil
    }

    // MARK: The measurement itself (pure of the UI, so it runs off the main actor)

    struct Outcome: Sendable {
        var body: ShotBodyResult?
        var release: FormClipRelease?
        var releaseReason: String?
        var failure: String?
    }

    /// One window: the ball near the hands (seeded from the hand, because there is no rim), the
    /// release instant, `BodyTracker` → `BodySkeletonFit` → `BodyKinematics` → `ShotBodyResult`.
    ///
    /// The order matters and is the opposite of the session path's. There the release is already
    /// known from the ball's flight before the body model runs; here the body pass is what *finds*
    /// the release, so the tracker runs first with the scanner's apex as the provisional centre of
    /// the hand window, and the model is built on the release that pass produced.
    nonisolated static func measure(url: URL, window: FormClipWindow, samples: [FormClipSample], fps: Double,
                                    timeScale: Double, hfovDegrees: Double, heightMetres: Double?) async -> Outcome {
        let realFPS = fps / max(timeScale, 0.001)
        let step = realFPS >= 100 ? 2 : 1

        // The ball, while it is still in frame near the hands. A form clip has no rim to seed the
        // detector from, so the seed is the shooting hand itself over the last third of a second of
        // the drive — the one place the ball is certainly at.
        var ballTrack: [BodyBallSample] = []
        let seeds = FormClipBall.seeds(from: samples, side: window.shootingSide,
                                       realTimeRange: (window.apexRealTime - 0.35)...(window.apexRealTime + 0.05))
        if !seeds.isEmpty {
            let diameter = FormClipBall.ballDiametersPerTorsoSpan * window.torsoSpanPx
            if let detections = try? await FormClipBall.track(url: url, start: window.startFile, end: window.endFile,
                                                              fps: fps, seeds: seeds, expectedDiameterPx: diameter) {
                ballTrack = detections.filter { !$0.edge }
                    .map { BodyBallSample(t: $0.pts / timeScale, u: $0.u, v: $0.v, diameterPx: $0.diameterPx) }
            }
        }

        var options = BodyTracker.Options()
        options.everyNthFrame = step
        options.timeScale = timeScale
        options.shootingSide = window.shootingSide
        options.handFocusRealTimeRange = (window.apexRealTime - ShotBodyResult.handFocusRealSeconds)...(window.apexRealTime + ShotBodyResult.handFocusRealSeconds)
        options.handFocusUsesBall = !ballTrack.isEmpty
        options.detectFeet = ShotBodyResult.feetEnabled

        let tVision = Date()
        let timeline: BodyTimeline
        do {
            timeline = try await BodyTracker.run(url: url, start: window.startFile, end: window.endFile,
                                                 options: options,
                                                 ballSeed: ballTrack.map { (pts: $0.t * timeScale, uv: SIMD2($0.u, $0.v)) },
                                                 fps: fps)
        } catch {
            return Outcome(failure: "the body pass failed (\(error))")
        }
        let visionSeconds = Date().timeIntervalSince(tVision)
        guard timeline.frames.contains(where: { !$0.points2D.isEmpty }) else {
            return Outcome(failure: "Vision found no body on any frame of this window (the shooter may have stepped out of frame)")
        }

        let (release, releaseReason) = FormClipReleaseEstimator.estimate(timeline: timeline, ball: ballTrack,
                                                                        apexRealTime: window.apexRealTime,
                                                                        shootingSide: window.shootingSide)
        guard let release else {
            return Outcome(releaseReason: releaseReason,
                           failure: releaseReason ?? "the release instant could not be dated from this window")
        }

        var fitOptions = BodySkeletonOptions(intrinsics: CameraIntrinsics(width: timeline.imageWidth,
                                                                          height: timeline.imageHeight,
                                                                          horizontalFOVDegrees: hfovDegrees))
        if let heightMetres { fitOptions.scale = .statedHeight(metres: heightMetres) }
        let tFit = Date()
        var fit = BodySkeletonFit.fit(timeline: timeline, options: fitOptions)
        let fitSeconds = Date().timeIntervalSince(tFit)

        // The hand plates (1.3), on the fitted wrist. A form clip is filmed close, so this is the
        // path where the plates are most often oriented; no rim column here, so the palm's angle to
        // the rim is refused with that reason and only its angle to vertical is reported.
        var handOptions = HandTriangleOptions(intrinsics: fitOptions.intrinsics)
        handOptions.shootingSide = window.shootingSide
        handOptions.ballTrack = ballTrack
        let handFit = HandTriangleFit.fit(timeline: fit.timeline, releaseRealTime: release.realTime, options: handOptions)
        fit.timeline = handFit.timeline

        var kOptions = BodyKinematicsOptions(shootingSide: window.shootingSide)
        kOptions.transverseYawUnavailableReason = fit.transverseYawUnavailableReason
        kOptions.dipIsLastTurningPoint = true
        // No rim column: the form's forward axis falls back to the camera's own axes and says so.
        let model = BodyKinematics.model(timeline: fit.timeline, releaseRealTime: release.realTime,
                                         ballTrack: ballTrack, rimImageU: nil, options: kOptions)
        var footFit: FootTriangleResult? = nil
        if options.detectFeet {
            var footOptions = FootTriangleOptions(intrinsics: fitOptions.intrinsics)
            footOptions.shootingSide = window.shootingSide
            footOptions.stature = fit.standingHeightMetres.value
            footOptions.statureProvenance = fit.scaleProvenance
            let feet = FootTriangleFit.run(timeline: fit.timeline, releaseRealTime: release.realTime,
                                           setRealTime: model.phases.setPoint.value, options: footOptions)
            fit.timeline = feet.timeline
            footFit = feet
        }
        // The raw timeline and the source go in exactly as the session path's `bodyStage` passes
        // them: that is what makes `bodyShot` — the per-shot export the 3-D viewer reads — exist.
        var body = ShotBodyResult.make(model: model, fit: fit, timeline: fit.timeline,
                                       releaseRealTime: release.realTime, realFrameRate: realFPS,
                                       visionSeconds: visionSeconds, fitSeconds: fitSeconds,
                                       heightMetres: heightMetres, rimImageU: nil, shotID: window.id,
                                       rawTimeline: timeline, handTriangles: handFit, footTriangles: footFit,
                                       source: BodyShotSource(kind: "app", build: nil, device: nil,
                                                              format: BodyShotFormat(w: timeline.imageWidth, h: timeline.imageHeight,
                                                                                     fps: realFPS, hfovDegrees: hfovDegrees,
                                                                                     provenance: "unstated")))
        body.warnings.append(release.note)
        body.notes.append(Self.ballUnavailableReason + ", so release speed, release angle, entry angle, depth at the rim and make-or-miss are not measured here — this clip measures the body")
        if release.source != .ballLeftHand {
            body.notes.append("every time on this card is dated from that instant, so a systematic shift of about its stated spread moves all of them together")
        }
        return Outcome(body: body, release: release, releaseReason: nil)
    }

    // MARK: 4 — saving

    func save(store: SessionStore, spot: ShotSpot) -> SavedSession? {
        guard let clip else { return nil }
        let session = store.saveFormClip(shots: shots.map { shot in
            SavedShot(formClipShot: shot.id,
                      windowStart: shot.window.startFile, windowEnd: shot.window.endFile,
                      body: shot.body,
                      releaseNote: shot.release?.note ?? shot.releaseUnavailableReason,
                      bodyUnavailableReason: { if case .failed(let why) = shot.status { return why }; return nil }())
        }, spot: spot, note: saveNote, clipName: clip.url.lastPathComponent,
           hfovDegrees: hfovDegrees, timeScale: timeScale, windows: shots.count,
           failed: shots.filter { if case .failed = $0.status { return true }; return false }.count,
           clipFingerprint: clipFingerprint)
        saved = session
        self.spot = spot
        return session
    }
}

// ================================================================================================
// MARK: - A saved shot with no ball in it
// ================================================================================================

extension SavedShot {
    /// One form-clip shot. Every ball field is nil with `FormClipModel.ballUnavailableReason`, and the
    /// verdict is `low confidence` **for the ball's purposes**: without a rim there is no gravity fit
    /// to check the shot against, so this row may never join a block's release-speed or entry-angle
    /// statistics. Its body fields are exactly the ones a session shot carries, and its form is kept
    /// whenever the body model produced one — that is what the block's mean form is built from.
    init(formClipShot id: Int, windowStart: Double, windowEnd: Double, body: ShotBodyResult?,
         releaseNote: String?, bodyUnavailableReason: String?) {
        self.id = id
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        verdict = "low confidence"
        verdictReason = FormClipModel.ballUnavailableReason + ", so gravity cannot be checked and this shot never joins a ball statistic"
        outcome = InferredOutcome.unknown.rawValue
        outcomeReason = FormClipModel.ballUnavailableReason + ", so make or miss was not seen"
        outcomeStrength = nil
        // Not a measurement and never read as one: every consumer of `gFit` tests `isFinite` first,
        // and a form clip has no trajectory to fit gravity to.
        gFit = .nan
        releaseAngleDegrees = nil
        releaseHeight = nil
        releaseSpeed = nil
        entryAngleDegrees = nil
        depthPastFrontRim = nil
        lateralDeviation = nil
        viewClass = ViewClass.side.rawValue
        elbowAtReleaseDegrees = nil
        elbowMaxNearReleaseDegrees = nil
        kneeMinimumDegrees = nil
        dipToReleaseSeconds = nil
        ballTopMarginPx = nil
        releaseDistance = nil
        self.bodyUnavailableReason = bodyUnavailableReason
        fittedElbowAtReleaseDegrees = body?.elbowAtRelease.value.map(Angle.degrees)
        fittedElbowJitterDegrees = body?.elbowJitterDegrees
        elbowExtensionPeakDegreesPerSecond = body?.elbowExtensionPeakRate.value.map(Angle.degrees)
        kneeExtensionPeakDegreesPerSecond = body?.kneeExtensionPeakRate.value.map(Angle.degrees)
        fittedKneeMinimumDegrees = body?.kneeMinimum.value.map(Angle.degrees)
        jumpHeightMetres = body?.jumpHeight.value
        dipDepthMetres = body?.dipDepthMetres.value
        dipDepthNormalised = body?.dipDepthNormalised.value
        bodyDipToReleaseMilliseconds = body?.dipToReleaseMilliseconds.value
        chainOrder = body?.chainOrder
        chainLagsMilliseconds = body?.chainLagsMilliseconds
        chainFrameFloorMilliseconds = body?.frameFloorMilliseconds
        proximalToDistal = body?.chainProximalToDistal
        headStabilityPx = body?.headStabilityPx.value
        headStabilityNormalised = body?.headStabilityNormalised.value
        handRateAtRelease = body?.handRateAtRelease.value
        shoulderLineYawDegrees = body?.shoulderLineYaw.value.map(Angle.degrees)
        shooterPixelHeight = body?.shooterPixelHeight
        if var f = body?.form {
            f.shotID = id
            form = f
            formUnavailableReason = nil
        } else {
            form = nil
            formUnavailableReason = body?.formUnavailableReason ?? bodyUnavailableReason
                ?? releaseNote ?? "this window produced no body model, so it has no form"
        }
    }
}
