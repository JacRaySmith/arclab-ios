import Foundation
import Observation
import PhotosUI
import ShotGeometry
import ShotVideo
import SwiftUI

/// Drives import → probe → rim → shot → results. All decoding and fitting runs off the main actor
/// in detached tasks; only the published state is touched here.
@MainActor
@Observable
final class AnalysisModel {
    enum Phase: Equatable {
        case idle
        case importing
        case probing
        case probed
        case tracking
        case tracked
        case failed(String)
    }

    // MARK: Clip

    var phase: Phase = .idle
    var clip: ImportedClip?
    var probe: VideoProbeResult?
    var run: TrajectoryRun?
    var progressText: String?

    /// How much of the decoded timeline the survey tracker looks at (seconds of *decoded* PTS, which
    /// for a slo-mo file is the stretched timeline, not wall-clock time).
    static let trackingWindowSeconds = 10.0

    // MARK: Timing and lens

    /// Slow-motion factor: file time ÷ this = real time. A 120 fps clip exported with 30 fps
    /// timestamps plays 4× slow, so every timestamp must be divided by 4 before any physics.
    var timeScale: Double = 1
    /// The user's answer to "is this clip slow motion?" — the app cannot tell when the exporter
    /// rewrote the timestamps instead of using an edit list (`sloMoStretch` is then 1.00×).
    var isSloMo = false
    /// True when the file looks like a slo-mo export with rewritten timestamps (≈30 fps, no stretch).
    var sloMoSuspected = false
    /// Horizontal field of view of the lens that shot the clip. 1080p120 slo-mo on this phone ≈ 48°.
    var hfovDegrees: Double = 48

    static let defaultSloMoFactor = 4.0

    var realFrameRate: Double? {
        guard let p = probe, p.decodedFrames >= 2, p.measuredFrameRate > 0 else { return nil }
        return p.measuredFrameRate * timeScale
    }

    var intrinsics: CameraIntrinsics? {
        guard let p = probe, p.width > 0, p.height > 0 else { return nil }
        return CameraIntrinsics(width: p.width, height: p.height, horizontalFOVDegrees: hfovDegrees)
    }

    var fileDuration: Double {
        guard let p = probe else { return 0 }
        return max(p.lastPTS, p.trackDuration)
    }

    /// What identifies *this video* across imports: the temp file name changes every time a clip is
    /// picked from Photos, but its track duration, frame count and size do not. Two different clips of
    /// the same length to the millisecond and the same frame count are, for this purpose, the same.
    var clipFingerprint: String? {
        guard let p = probe, p.decodedFrames > 0 else { return nil }
        return String(format: "%dx%d/%d/%.3f", p.width, p.height, p.decodedFrames, p.trackDuration)
    }

    /// Applies what the probe measured; leaves the slo-mo question to the user when the file hides it.
    private func applyProbeDefaults(_ p: VideoProbeResult) {
        if p.sloMoStretch > 1.05 {
            timeScale = p.sloMoStretch          // an honest edit list: the file says how slow it is
            isSloMo = true
            sloMoSuspected = false
        } else {
            timeScale = 1
            isSloMo = false
            sloMoSuspected = p.measuredFrameRate > 28 && p.measuredFrameRate < 32
        }
        windowStart = 0
    }

    func setSloMo(_ on: Bool) {
        ActivityLog.shared.event("timing.sloMo", ["on": on])
        isSloMo = on
        if on {
            let stretch = probe?.sloMoStretch ?? 1
            timeScale = stretch > 1.05 ? stretch : Self.defaultSloMoFactor
        } else {
            timeScale = max(1, probe?.sloMoStretch ?? 1)
        }
        invalidateAnalysis()
    }

    // MARK: Rim

    /// Boundary points around the ring, in image pixels (top-left origin).
    var rimPoints: [SIMD2<Double>] = []
    var calibration: RimCalibration?
    var calibrationError: String?
    /// The frame time the rim was marked on, so the UI can say which picture the points came from.
    var rimFrameTime: Double?

    func calibrateRim() {
        guard let k = intrinsics else {
            calibrationError = "no clip has been probed yet, so the frame size is unknown"
            return
        }
        do {
            let options = RimCalibrationOptions()
            calibration = try RimCalibrator.calibrate(boundaryPoints: rimPoints, intrinsics: k, options: options)
            calibrationError = nil
            if let c = calibration {
                ActivityLog.shared.event("rim.calibrated", ["points": rimPoints.count, "distance": c.distanceToRim, "axisRatio": c.ellipse.axisRatio,
                                                            "residualPx": c.ellipseResidualPx, "warnings": c.warnings.joined(separator: " | "),
                                                            "frameTime": rimFrameTime, "hfov": hfovDegrees])
            }
        } catch {
            calibration = nil
            calibrationError = "\(error)"
            ActivityLog.shared.event("rim.failed", ["points": rimPoints.count, "error": "\(error)"])
        }
        invalidateAnalysis()
    }

    func clearRim() {
        rimPoints = []
        calibration = nil
        calibrationError = nil
        rimFindNote = nil
        invalidateAnalysis()
    }

    /// What the automatic finder said about its proposal (confidence, warnings) or why it found nothing.
    var rimFindNote: String?
    var rimFinding = false

    /// Propose the rim from the clip itself: try a few ball-free-looking frames spread over the clip, keep
    /// the proposal with the highest confidence, calibrate from it. The user confirms on the marking screen.
    /// `RimFinder` (Packages/ShotVideo) works on one frame: orange-chroma ring, RANSAC ellipse with the rim
    /// priors, inner-edge refinement; it returns a confidence and plain-language warnings, never a guess.
    func findRimAutomatically(frameTimes: [Double]? = nil) async {
        guard let clip, !rimFinding else { return }
        rimFinding = true
        defer { rimFinding = false }
        let duration = fileDuration
        let times = (frameTimes ?? [3, 15, 45, 90, 180].map { min($0, max(0, duration - 0.5)) })
            .reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }
        let url = clip.url
        var best: (result: RimFindResult, time: Double)? = nil
        var failures: [String] = []
        let t0 = Date()
        for t in times {
            let outcome: (RimFindOutcome, Double)? = await Task.detached(priority: .userInitiated) {
                guard let f = try? await FrameLoader.frame(url: url, time: t), let cg = f.image.cgImage else { return nil }
                return (RimFinder.findWithDiagnosis(in: cg), f.pts)
            }.value
            guard let (o, pts) = outcome else { failures.append(String(format: "%.0f s: frame could not be decoded", t)); continue }
            switch o {
            case .found(let r):
                if best == nil || r.confidence > best!.result.confidence { best = (r, pts) }
                if r.confidence >= 0.85 { break }
            case .notFound(let reason):
                failures.append(String(format: "%.0f s: %@", t, reason))
            }
            if let b = best, b.result.confidence >= 0.85 { break }
        }
        let seconds = Date().timeIntervalSince(t0)
        if let b = best {
            rimPoints = b.result.boundaryPoints
            rimFrameTime = b.time
            let conf = b.result.confidence
            var note = String(format: "Ring found on the frame at %.1f s (confidence %.2f, %d of the ring's boundary measured, residual %.1f px).",
                              b.time, conf, b.result.rawInwardEdgePoints.count, b.result.rmsResidualPx)
            if conf < 0.6 { note += " Low confidence: treat this as a starting point — open the marking screen and check both ends of the ring." }
            if !b.result.warnings.isEmpty { note += " " + b.result.warnings.joined(separator: " ") }
            rimFindNote = note
            calibrateRim()
            ActivityLog.shared.event("rim.found", ["confidence": conf, "frameTime": b.time, "residualPx": b.result.rmsResidualPx,
                                                  "warnings": b.result.warnings.joined(separator: " | "), "tried": times.count, "seconds": seconds])
        } else {
            rimFindNote = "The ring was not found automatically (" + (failures.first ?? "no frame examined") + "). Mark it by hand: tap 6 or more points around the inside of the ring."
            ActivityLog.shared.event("rim.notFound", ["reasons": failures.joined(separator: " | "), "tried": times.count, "seconds": seconds])
        }
    }

    // MARK: Shot window (file time)

    var windowStart: Double = 0
    var windowLength: Double = 7
    var windowEnd: Double { windowStart + windowLength }

    // MARK: Analysis

    var analysisBusy = false
    var analysisStage: String?
    var analysisError: String?
    var analysis: ShotAnalysis?
    var analysisSamples: [ImageSample] = []
    var analysisNotes: [String] = []
    var analysisPose: ShotPoseResult?
    var analysisBody: ShotBodyResult?
    var analysisBodyUnavailableReason: String?
    /// Window the current result was produced from, so results can never be read as belonging to
    /// a window the user has since moved.
    var analysedWindow: ClosedRange<Double>?

    private func invalidateAnalysis() {
        analysis = nil
        analysisSamples = []
        analysisNotes = []
        analysisPose = nil
        analysisBody = nil
        analysisBodyUnavailableReason = nil
        analysisError = nil
        analysedWindow = nil
    }

    /// The analysed shot packaged for `ResultsView`, or nil when nothing has been analysed.
    var resultContext: ShotResultContext? {
        guard let clip, let analysis, let k = intrinsics else { return nil }
        return ShotResultContext(title: "Shot", clipURL: clip.url, timeScale: timeScale, intrinsics: k,
                                 rimPoints: rimPoints, analysis: analysis, samples: analysisSamples,
                                 notes: analysisNotes, pose: analysisPose,
                                 body: analysisBody, bodyUnavailableReason: analysisBodyUnavailableReason,
                                 window: analysedWindow, verdict: nil, outcome: nil)
    }

    var canAnalyse: Bool { clip != nil && calibration != nil && !analysisBusy }

    // MARK: Actions

    func importAndProbe(_ item: PhotosPickerItem) {
        phase = .importing
        clip = nil; probe = nil; run = nil; progressText = nil
        probeRetryNote = nil
        clearRim()
        let log = ActivityLog.shared
        Task {
            do {
                let imported = try await log.timed("clip.import") { try await Task.detached { try await ClipImporter.importClip(from: item) }.value }
                clip = imported
                phase = .probing
                let url = imported.url
                let result = try await probeWithRetry(url: url, source: imported.source.rawValue, log: log)
                probe = result
                applyProbeDefaults(result)
                log.event("clip.ready", ["file": url.lastPathComponent, "width": result.width, "height": result.height, "fps": result.measuredFrameRate,
                                         "frames": result.decodedFrames, "stretch": result.sloMoStretch, "timeScale": timeScale, "sloMoSuspected": sloMoSuspected,
                                         "fileSeconds": fileDuration])
                phase = .probed
            } catch {
                log.event("clip.failed", ["error": "\(error)"])
                if SessionModel.isDecodingInterruption(error) {
                    phase = .failed("iOS interrupted the video decoder while the clip was being read — it does that when ArcLab is not on screen. The clip is fine: pick it again with the app in front.")
                } else {
                    phase = .failed("Import/probe failed: \(error)")
                }
            }
        }
    }

    /// Set when the first read of a clip was interrupted and the retry succeeded, so the screen can
    /// say what happened rather than silently hiding a −11847.
    var probeRetryNote: String?

    /// The probe, retried once automatically after AVFoundation's −11847 "Operation Interrupted".
    /// The phone log has five of those in two days, every one of them retried by hand: the file was
    /// never the problem, the app had simply left the screen while the decoder was running.
    private func probeWithRetry(url: URL, source: String, log: ActivityLog) async throws -> VideoProbeResult {
        do {
            return try await log.timed("clip.probe", ["source": source]) { try await Task.detached { try await VideoReader(url: url).probe() }.value }
        } catch {
            guard SessionModel.isDecodingInterruption(error) else { throw error }
            log.event("clip.probe.interrupted", ["error": "\(error)"])
            try? await Task.sleep(for: .milliseconds(500))
            let result = try await log.timed("clip.probe.retry", ["source": source]) { try await Task.detached { try await VideoReader(url: url).probe() }.value }
            probeRetryNote = "The first read of this clip was interrupted by iOS (ArcLab was not on screen). It was read again and the numbers below come from that second read."
            return result
        }
    }

    /// A clip already on disk (the on-device benchmark): the caller states the timing and the lens.
    func useLocalClip(url: URL, timeScale scale: Double, hfovDegrees hfov: Double) {
        phase = .probing
        clip = ImportedClip(url: url, source: .recordedInApp)
        probe = nil; run = nil; progressText = nil
        clearRim()
        hfovDegrees = hfov
        Task {
            do {
                let result = try await ActivityLog.shared.timed("clip.probe", ["source": "local"]) { try await Task.detached { try await VideoReader(url: url).probe() }.value }
                probe = result
                applyProbeDefaults(result)
                timeScale = scale
                isSloMo = scale > 1.05
                sloMoSuspected = false
                ActivityLog.shared.event("clip.ready", ["file": url.lastPathComponent, "width": result.width, "height": result.height, "fps": result.measuredFrameRate,
                                                        "frames": result.decodedFrames, "timeScale": timeScale, "fileSeconds": fileDuration])
                phase = .probed
            } catch {
                phase = .failed("Could not read the clip: \(error)")
            }
        }
    }

    /// A clip recorded in the app: the file carries real high-frame-rate timestamps (factor 1) and the
    /// sidecar carries the lens's horizontal field of view, so neither is asked of the user.
    func useRecordedClip(_ recorded: RecordedClip) {
        phase = .probing
        clip = ImportedClip(url: recorded.url, source: .recordedInApp)
        probe = nil; run = nil; progressText = nil
        clearRim()
        hfovDegrees = recorded.videoFieldOfViewDegrees
        let url = recorded.url
        Task {
            do {
                let result = try await Task.detached { try await VideoReader(url: url).probe() }.value
                probe = result
                applyProbeDefaults(result)
                ActivityLog.shared.event("clip.ready", ["file": url.lastPathComponent, "source": "recordedInApp", "width": result.width, "height": result.height,
                                                        "fps": result.measuredFrameRate, "frames": result.decodedFrames, "hfov": hfovDegrees, "fileSeconds": fileDuration])
                // Real timestamps: the probe's measured rate is the recording rate. Never treat as a 30 fps export.
                timeScale = max(1, result.sloMoStretch)
                isSloMo = result.sloMoStretch > 1.05
                sloMoSuspected = false
                phase = .probed
            } catch {
                phase = .failed("Could not read the recording: \(error)")
            }
        }
    }

    /// The original survey pass: Vision over the first 10 s, listing whatever tracks exist.
    func track() {
        guard let clip else { return }
        phase = .tracking
        progressText = "starting…"
        let url = clip.url
        var options = TrajectoryTrackerOptions()
        options.startTime = 0
        options.endTime = Self.trackingWindowSeconds
        let opts = options
        Task {
            do {
                let result = try await Task.detached { [opts] in
                    try await TrajectoryTracker.run(url: url, options: opts) { frames, pts in
                        Task { @MainActor in
                            self.progressText = String(format: "%d frames, t = %.2f s", frames, pts)
                        }
                    }
                }.value
                run = result
                progressText = nil
                phase = .tracked
            } catch {
                progressText = nil
                phase = .failed("Tracking failed: \(error)")
            }
        }
    }

    /// Analyse the current window. Errors are shown exactly as the pipeline worded them.
    func analyseWindow() {
        guard let clip, let calibration, let k = intrinsics, !analysisBusy else { return }
        let url = clip.url
        let start = windowStart
        let end = windowStart + windowLength
        let scale = timeScale
        invalidateAnalysis()
        analysisBusy = true
        analysisStage = "starting…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { [calibration, k] in
                    // The single-shot flow has no scanner behind it, so the window is wherever the user put it and
                    // there is nothing to seed the detector with. Here — and only here — the Vision trajectory pass
                    // still runs: it costs a few seconds on one shot, and it is also the fallback when the detector
                    // finds too little. The session flow seeds from the scan instead and skips it.
                    try await ShotAnalysisRunner.run(url: url, start: start, end: end, timeScale: scale,
                                                     calibration: calibration, intrinsics: k,
                                                     useVisionSeed: true) { text in
                        Task { @MainActor in self.analysisStage = text }
                    }
                }.value
                analysis = result.analysis
                analysisSamples = result.samples
                analysisNotes = result.notes
                analysisPose = result.pose
                analysisBody = result.body
                analysisBodyUnavailableReason = result.bodyUnavailableReason
                analysedWindow = start...end
                analysisError = nil
            } catch {
                analysis = nil
                analysisSamples = []
                analysisPose = nil
                analysisBody = nil
                analysisBodyUnavailableReason = nil
                analysisError = "\(error)"
            }
            analysisBusy = false
            analysisStage = nil
        }
    }

    var isBusy: Bool {
        switch phase {
        case .importing, .probing, .tracking: return true
        default: return analysisBusy
        }
    }
}
