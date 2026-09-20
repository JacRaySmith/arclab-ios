import Foundation
import Observation
import PhotosUI
import ShotGeometry
import ShotVideo
import SwiftUI

/// Runs the vertical jump test: one clip in, one measured jump out, three of them make a test.
///
/// **Two passes, on purpose.** Vision's body pose is the expensive part (about 10 ms a frame on the
/// phone), and a 240 fps clip of a 4-second recording is nearly a thousand frames. So the clip is
/// first swept at roughly 30 Hz — every eighth frame — purely to find *where* the feet are highest,
/// and only a 1.8-second window around that is tracked at the full frame rate. The measurement
/// therefore keeps every one of the 240 frames a second where it matters, which is the whole reason
/// the ±1-frame error is 4 ms and not 33.
@MainActor
@Observable
final class JumpModel {

    /// The protocol: three countermovement jumps with arm swing, 30 s rest between them.
    static let jumpsPerTest = 3
    static let restSeconds = 30

    /// The longest clip worth sweeping. A jump test clip is a few seconds; anything longer is a
    /// mis-tap, and sweeping ten minutes of video would look like a hang.
    static let maximumClipSeconds = 20.0

    /// Real seconds kept before and after the peak for the full-rate pass. Before: enough standing
    /// still for the hip cross-check plus a whole flight. After: the landing and a little floor.
    static let windowBeforeSeconds = 1.0
    static let windowAfterSeconds = 0.8

    private(set) var attempts: [JumpAttempt] = []
    private(set) var busy = false
    private(set) var stage: String?
    private(set) var error: String?
    private(set) var scaleSource: String?
    private var testID = UUID()
    private var startedAt = Date()

    var isComplete: Bool { attempts.count >= JumpModel.jumpsPerTest }
    var nextJumpNumber: Int { attempts.count + 1 }

    var session: JumpTestSession {
        JumpTestSession(id: testID, date: startedAt, attempts: attempts,
                        method: JumpTestSession.flightTimeMethod, scaleSource: scaleSource)
    }

    func reset() {
        attempts = []; error = nil; stage = nil; scaleSource = nil
        testID = UUID(); startedAt = Date()
    }

    func removeLast() {
        guard !attempts.isEmpty else { return }
        attempts.removeLast()
    }

    // MARK: - Ways a clip arrives

    func analyse(recorded: RecordedClip) {
        Task { await analyse(url: recorded.url, clipFileName: recorded.movieFileName) }
    }

    func analyse(picked item: PhotosPickerItem) {
        Task {
            busy = true; stage = "Copying the clip out of Photos"; error = nil
            do {
                let imported = try await ActivityLog.shared.timed("jump.import") {
                    try await Task.detached { try await ClipImporter.importClip(from: item) }.value
                }
                busy = false
                await analyse(url: imported.url, clipFileName: nil)
            } catch {
                busy = false; stage = nil
                self.error = "The clip could not be read out of Photos: \(error)"
            }
        }
    }

    // MARK: - The measurement

    private func analyse(url: URL, clipFileName: String?) async {
        guard !busy else { return }
        busy = true; error = nil
        let wall = Date()
        defer { busy = false; stage = nil }

        stage = "Reading the clip"
        let probe: VideoProbeResult
        do {
            probe = try await Task.detached(priority: .userInitiated) { try await VideoReader(url: url).probe() }.value
        } catch {
            self.error = "The clip could not be read: \(error)"
            return
        }

        // A slow-motion file may carry an edit list that stretches time; real time is file time ÷ this.
        let timeScale = probe.sloMoStretch > 1.01 ? probe.sloMoStretch : 1
        let realFps = probe.measuredFrameRate * timeScale
        let fileSeconds = min(JumpModel.maximumClipSeconds, max(probe.lastPTS, probe.trackDuration))

        guard realFps >= 120 else {
            record(JumpAttempt(index: nextJumpNumber, recordedAt: Date(),
                               unavailableReason: String(format: "This clip runs at %.0f frames a second and the flight-time test needs at least 120. Record the jump in ArcLab — it films at 240 — or film in your phone's Slo-mo mode and import the original from Photos.", realFps),
                               secondsAnalysed: Date().timeIntervalSince(wall), clipFileName: clipFileName))
            return
        }

        // --- pass 1: find the jump -----------------------------------------------------------
        stage = "Finding the jump"
        let coarseStep = max(1, Int((realFps / 30).rounded()))
        let coarse: BodyTimeline
        do {
            coarse = try await track(url: url, startFile: 0, endFile: fileSeconds,
                                     timeScale: timeScale, everyNth: coarseStep)
        } catch {
            self.error = "The body tracker could not read this clip: \(error)"
            return
        }
        let coarseSeries = VerticalJump.series(from: coarse)
        guard coarseSeries.times.count >= 4, let peak = coarseSeries.footUpPixels.max(),
              let peakIndex = coarseSeries.footUpPixels.firstIndex(of: peak) else {
            record(JumpAttempt(index: nextJumpNumber, recordedAt: Date(),
                               unavailableReason: "The body was not found anywhere in this clip. Stand side-on, whole body in the frame, and make sure you are the only person in shot.",
                               secondsAnalysed: Date().timeIntervalSince(wall), clipFileName: clipFileName))
            return
        }
        let peakReal = coarseSeries.times[peakIndex]

        // --- pass 2: measure it at the full frame rate ----------------------------------------
        stage = "Measuring the flight"
        let realStart = max(0, peakReal - JumpModel.windowBeforeSeconds)
        let realEnd = min(fileSeconds / timeScale, peakReal + JumpModel.windowAfterSeconds)
        let fine: BodyTimeline
        do {
            fine = try await track(url: url, startFile: realStart * timeScale, endFile: realEnd * timeScale,
                                   timeScale: timeScale, everyNth: 1)
        } catch {
            self.error = "The body tracker could not read the jump window: \(error)"
            return
        }
        let s = VerticalJump.series(from: fine)
        let flight = VerticalJump.flightTime(times: s.times, footUpPixels: s.footUpPixels)

        // The hip cross-check, and only when something really does supply a metre scale.
        var scale: VerticalJump.JumpScale? = nil
        if let height = ShooterProfile.heightMetres, let span = s.ankleToNosePixels {
            scale = VerticalJump.JumpScale.fromStatedHeight(metres: height, ankleToNosePixels: span)
        }
        if let scale { scaleSource = scale.source }
        let hip = VerticalJump.hipRise(times: s.times, hipUpPixels: s.hipUpPixels,
                                       takeOffSeconds: flight.jump?.takeOffSeconds, scale: scale)

        var attempt = JumpAttempt(index: nextJumpNumber, recordedAt: Date(),
                                  secondsAnalysed: Date().timeIntervalSince(wall), clipFileName: clipFileName)
        if let j = flight.jump {
            attempt.heightMetres = j.heightMetres
            attempt.uncertaintyMetres = j.heightUncertaintyMetres
            attempt.thresholdBiasMetres = j.thresholdBiasMetres
            attempt.flightSeconds = j.flightSeconds
            attempt.frameRate = j.frameRate
            attempt.notes = j.notes
        } else {
            attempt.unavailableReason = flight.unavailableReason ?? "no reason recorded"
        }
        if let h = hip.jump {
            attempt.hipRiseMetres = h.riseMetres
            attempt.hipRiseUncertaintyMetres = h.riseUncertaintyMetres
            attempt.notes += h.notes
        } else {
            attempt.hipUnavailableReason = hip.unavailableReason
        }
        if let j = flight.jump, let h = hip.jump {
            attempt.comparisonSentence = VerticalJump.compare(flight: j, hip: h).sentence
        }
        attempt.notes += s.notes
        attempt.secondsAnalysed = Date().timeIntervalSince(wall)
        record(attempt)
    }

    /// One Vision pass. 2-D body only: the 3-D request and the hands cost most of the tracker's time
    /// and neither has anything to say about how long the feet were off the floor.
    private func track(url: URL, startFile: Double, endFile: Double,
                       timeScale: Double, everyNth: Int) async throws -> BodyTimeline {
        var options = BodyTracker.Options()
        options.everyNthFrame = everyNth
        options.timeScale = timeScale
        options.detect3DBody = false
        options.detectHands = false
        options.detectFeet = false
        let opts = options
        return try await Task.detached(priority: .userInitiated) {
            try await BodyTracker.run(url: url, start: startFile, end: endFile, options: opts)
        }.value
    }

    private func record(_ attempt: JumpAttempt) {
        attempts.append(attempt)
        ActivityLog.shared.event("jump.attempt", [
            "index": attempt.index,
            "heightCm": attempt.heightMetres.map { 100 * $0 },
            "uncertaintyCm": attempt.uncertaintyMetres.map { 100 * $0 },
            "biasCm": attempt.thresholdBiasMetres.map { 100 * $0 },
            "flightSeconds": attempt.flightSeconds,
            "fps": attempt.frameRate,
            "hipRiseCm": attempt.hipRiseMetres.map { 100 * $0 },
            "seconds": attempt.secondsAnalysed,
            "reason": attempt.unavailableReason,
        ])
    }

    /// Called when the test is saved. This is the event the brief asks for.
    func logTest(_ test: JumpTestSession) {
        let summary = test.summary
        ActivityLog.shared.event("jump.test", [
            "jumps": test.attempts.count,
            "measured": summary?.n ?? 0,
            "bestCm": summary.map { 100 * $0.bestMetres },
            "meanCm": summary.map { 100 * $0.meanMetres },
            "spreadCm": summary.map { 100 * $0.spreadMetres },
            "method": test.method,
            "uncertaintyCm": summary.map { 100 * $0.typicalUncertaintyMetres },
            "seconds": test.attempts.reduce(0) { $0 + $1.secondsAnalysed },
            "scale": test.scaleSource,
        ])
    }
}
