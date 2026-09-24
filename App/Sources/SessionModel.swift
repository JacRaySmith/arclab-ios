import AVFoundation
import Foundation
import Observation
import ShotGeometry
import ShotVideo
import simd
import UIKit
import UserNotifications

/// One shot in a session: the window the scanner found and what the analyzer made of it.
///
/// This lives for as long as the app is open (no SwiftData yet) — but since 2026-09-19 it is no longer
/// the *only* copy. Everything measurable here is mirrored into `GuidedCheckpoint` on disk as it is
/// produced, because a process death used to take an entire session with it.
struct SessionShot: Identifiable, Sendable {
    enum Status: Sendable, Equatable {
        case queued
        case analyzing(String)
        case measured
        case failed(String)
    }

    var id: Int
    var window: ShotWindow
    var status: Status = .queued
    var result: ShotRunResult?
    var row: BlockRow?
    /// Order in which this shot finished analysing (for "last shot" feedback), nil until measured.
    var completionOrder: Int?
    /// The record this shot was restored from after a process death (`GuidedCheckpoint`). Present only
    /// on a restored shot, and only until it is re-analysed. It carries the things a `BlockRow` does not
    /// — the 3-D form, and the reason there is none — so a crash cannot silently drop them on the next
    /// save. There is no `result` behind a restored shot, so its per-shot detail screen is unavailable
    /// and says so rather than showing an empty one.
    var restored: SavedShot?

    var verdict: ShotAcceptance.Verdict? { row?.verdict }
    var outcome: OutcomeInference? { row?.outcome }

    /// The one word (and reason) the list shows.
    var statusLabel: String {
        switch status {
        case .queued: return "queued"
        case .analyzing: return "analyzing"
        case .failed: return "failed"
        case .measured: return verdict?.label ?? "measured"
        }
    }

    var statusDetail: String? {
        switch status {
        case .queued: return nil
        case .analyzing(let s): return s
        case .failed(let reason): return reason
        case .measured: return verdict?.reason
        }
    }
}

/// Drives the session flow: scan the whole clip for shot windows, then analyse them one at a time.
/// The single-shot flow in `AnalysisModel` is untouched. `onCheckpoint` fires at every step that
/// changes what has been measured, and `restore(from:model:)` puts a checkpoint back.
@MainActor
@Observable
final class SessionModel {
    // MARK: Inputs, copied at scan time so a later change to the clip cannot silently re-label results

    private(set) var clipURL: URL?
    private(set) var timeScale: Double = 1
    private(set) var intrinsics: CameraIntrinsics?
    private(set) var calibration: RimCalibration?
    private(set) var rimPoints: [SIMD2<Double>] = []
    /// Which of the two possible "up" directions this session's rim was solved with — the shooter's
    /// trace, or the direction the phone measured while the clip was filmed — in one line, so a
    /// session read back months later never has to guess (`AnalysisModel.rimUpProvenance`).
    private(set) var rimUpProvenance: String?

    // MARK: Scan

    var scanning = false
    var scanProgress: Double = 0
    var scanMessage: String?
    var scanError: String?
    var scan: SessionScanResult?
    /// Only the first `scanLimitSeconds` of file time are scanned when `limitScan` is on — a whole
    /// 20-minute clip is a long wait and most checks only need the start of it.
    var limitScan = false
    var scanLimitSeconds: Double = 200

    // MARK: Shots

    var shots: [SessionShot] = []
    var analysing = false
    var analysisError: String?
    /// True when a decode was interrupted because ArcLab left the screen (AVFoundation −11847).
    /// A pause, not a failure: every finished shot is kept, the interrupted windows go back to the
    /// queue, and `resumeAfterInterruption` picks them up when the scene is active again.
    private(set) var pausedByInterruption = false
    /// The session as the guided flow saved it, so the session screen shows "Saved" instead of
    /// offering to save the same block a second time. Nil until it has been saved.
    var savedSessionID: UUID?
    var savedSpot: ShotSpot?
    /// Set when the lens constant was changed between passes (LensSelection); shown with the provenance.
    var lensNote: String?
    /// How the field of view was established, for the BodyShot record: sidecar | assumed | gravity-calibrated.
    private(set) var hfovProvenance = "assumed"
    var lensPassDone = false
    /// How the batch decided to run: how many windows at a time, and why.
    var analysisNote: String?
    /// Non-nil while the deferred body pass is running: how many form models are done, of how many. Every ball
    /// number is already on screen by then, so this is the only thing still moving.
    private(set) var bodyPhase: (done: Int, total: Int)?
    /// Wall-clock seconds per completed window in this batch, for the time-remaining estimate.
    private(set) var completedWindowSeconds: [Double] = []
    private var batchWallStart: Date?
    private var lastCompletionWall: Date?

    /// "about N min left": the median window time so far times the windows still queued or running.
    /// Nil until two windows have completed (one is not an estimate).
    var estimatedSecondsRemaining: Double? {
        guard completedWindowSeconds.count >= 2 else { return nil }
        let sorted = completedWindowSeconds.sorted()
        let median = sorted[sorted.count / 2]
        let remaining = shots.filter { if case .measured = $0.status { return false }; if case .failed = $0.status { return false }; return true }.count
        // Nothing left to wait for is not "about 0 s left": the deferred body pass has its own line.
        guard remaining > 0 else { return nil }
        return median * Double(remaining)
    }

    /// The most recently measured shot, for the immediate feedback line.
    var lastMeasured: SessionShot? {
        shots.filter { $0.row != nil }.max { ($0.completionOrder ?? 0) < ($1.completionOrder ?? 0) }
    }
    private var completionCounter = 0
    /// The peak resident bytes one decoded window is allowed to hold. Brief §8's phone budget.
    static let memoryBudgetBytes = 320 * 1024 * 1024
    /// Never more than two, however much memory there is: past two, the Neural Engine and the video decoder are
    /// the bottleneck and extra lanes only add heat.
    static let maxConcurrentWindows = 2

    private var scanTask: Task<Void, Never>?
    private var analyseTask: Task<Void, Never>?

    /// Called after every step that changes what has been measured: the scan finishing, each shot
    /// finishing, each body model finishing, and the batch ending. The guided and practice screens use
    /// it to write their crash checkpoint, which is why it is a closure and not a store reference —
    /// this model still knows nothing about where anything is kept.
    var onCheckpoint: (@MainActor (SessionModel) -> Void)?

    /// True when the shots in this model came back from a checkpoint rather than from a scan in this
    /// run of the app. Restored shots carry their numbers but not the tracked samples behind them, so
    /// anything that would re-derive a measurement from the samples must not run.
    private(set) var restoredFromCheckpoint = false
    /// What the restore could and could not bring back, shown on the screen that resumed it.
    private(set) var restoreNote: String?

    private func checkpoint() { onCheckpoint?(self) }

    var rimCenterPx: SIMD2<Double>? { scan?.rimCenterPx ?? calibration?.ellipse.center }

    /// The clip's file name, for the saved-session list. Never the path: the file is a temporary copy.
    var clipURLName: String { clipURL?.lastPathComponent ?? "clip" }

    var summary: BlockSummary {
        let rows = shots.compactMap(\.row)
        let failed = shots.filter { if case .failed = $0.status { return true }; return false }.count
        return BlockSummary.build(windows: shots.count, failed: failed, rows: rows)
    }

    var isBusy: Bool { scanning || analysing }

    /// AVFoundation's −11847, "Operation Interrupted": iOS stops video decoding when the app is not
    /// on screen. It is not a bad clip and not a failed measurement, so it is never reported as one.
    nonisolated static func isDecodingInterruption(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == AVFoundationErrorDomain, ns.code == -11847 { return true }
        return isDecodingInterruption("\(error)")
    }

    nonisolated static func isDecodingInterruption(_ text: String) -> Bool {
        text.contains("-11847") || text.localizedCaseInsensitiveContains("operation interrupted")
    }

    nonisolated static let pauseMessage = "Paused — iOS stops video decoding when ArcLab is not on screen. Nothing measured is lost; the rest continues when you come back."

    /// A scan or an analysis takes minutes; if the screen auto-locks iOS suspends the app and the work
    /// stalls. Keep the screen awake while busy, and only while busy.
    private func keepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
        ActivityLog.shared.event("keepAwake", ["on": on])
    }

    /// The view class most of the measured shots came out as. 2-D pose angles are only meaningful in a
    /// side view, so the coaching card asks this before it says anything about the body.
    var dominantViewClass: ViewClass? {
        let classes = shots.compactMap { $0.result?.analysis.confidence.viewClass }
        guard !classes.isEmpty else { return nil }
        return Dictionary(grouping: classes, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    var rimAxisRatio: Double? { calibration?.ellipse.axisRatio }

    var coaching: CoachingCard {
        SessionCoach.card(summary: summary, viewClass: dominantViewClass, rimAxisRatio: rimAxisRatio)
    }

    // MARK: Scanning

    func startScan(model: AnalysisModel) {
        guard let clip = model.clip, let cal = model.calibration, let k = model.intrinsics, !isBusy else { return }
        clipURL = clip.url
        timeScale = model.timeScale
        intrinsics = k
        hfovProvenance = clip.source == .recordedInApp ? "sidecar" : "assumed"
        calibration = cal
        rimUpProvenance = model.rimUpProvenance
        rimPoints = model.rimPoints
        shots = []
        scan = nil
        scanError = nil
        analysisError = nil
        scanning = true
        keepAwake(true)
        scanProgress = 0
        scanMessage = "starting…"

        var options = SessionScanOptions()
        if limitScan { options.scanEnd = scanLimitSeconds }
        let url = clip.url, scale = model.timeScale, points = model.rimPoints
        let opts = options
        let log = ActivityLog.shared
        let heartbeat = ActivityLog.Heartbeat()
        log.event("scan.start", ["clip": url.lastPathComponent, "timeScale": scale, "hfov": model.hfovDegrees, "limit": limitScan ? scanLimitSeconds : nil,
                                 "fileSeconds": model.fileDuration, "thermal": ActivityLog.thermal()])
        let scanTimings = StageTimings()
        scanTask = Task { [cal] in
            do {
                let result = try await log.timed("scan.run") {
                    try await Task.detached(priority: .userInitiated) { [cal, opts] in
                        try await SessionScanner.run(url: url, timeScale: scale, calibration: cal, rimPoints: points,
                                                     options: opts, timings: scanTimings) { fraction, message in
                            heartbeat.tick("scan", ["fraction": fraction, "message": message])
                            Task { @MainActor in
                                self.scanProgress = fraction
                                self.scanMessage = message
                            }
                        }
                    }.value
                }
                scan = result
                shots = result.windows.map { SessionShot(id: $0.id, window: $0) }
                scanMessage = nil
                log.event("scan.end", ["windows": result.windows.count, "frames": result.framesScanned, "mode": result.mode.rawValue,
                                       "candidates": result.candidateCount,
                                       "scanned": result.scanned.upperBound - result.scanned.lowerBound,
                                       "arrivals": result.windows.map { String(format: "%.1f", $0.arrivalFileTime) }.joined(separator: ","),
                                       "thermal": ActivityLog.thermal()])
                // Where the scan's seconds went. Summed over the scanner's lanes, so decode + detect is CPU
                // time and will exceed the wall time `scan.run` reports when more than one lane ran.
                var stageRow = result.stageSeconds.mapValues { $0 as Any }
                stageRow["stage"] = "scan"
                stageRow["frames"] = result.framesScanned
                log.event("scan.stages", stageRow)
                // The scan is minutes of work. It is on disk before the first shot is analysed.
                checkpoint()
            } catch is CancellationError {
                scanMessage = nil
                scanError = "the scan was cancelled"
                log.event("scan.cancelled")
            } catch {
                scanMessage = nil
                if Self.isDecodingInterruption(error) {
                    pausedByInterruption = true
                    scanError = nil
                    scanMessage = Self.pauseMessage
                    log.event("scan.paused", ["error": "\(error)"])
                } else {
                    scanError = "\(error)"
                    log.event("scan.failed", ["error": "\(error)"])
                }
            }
            scanning = false
            keepAwake(analysing)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: Coming back after the app died

    /// Rebuild this block from a checkpoint an earlier run of the app wrote, instead of scanning and
    /// measuring it all again.
    ///
    /// What comes back and what does not, stated rather than hidden:
    /// * Every **measured** shot returns with the numbers, the verdict and the reasons it was measured
    ///   with — and with the calibration it was measured with, because the rim points are restored from
    ///   the checkpoint and re-calibrated by the caller before this is called. It does *not* come back
    ///   with its tracked samples, so its per-shot detail screen cannot be opened; `resultContext`
    ///   already returns nil for a shot with no result and the UI says why.
    /// * Every **failed** window returns failed, with the reason it failed.
    /// * Every other window returns **queued** and is measured now. Nothing is shown as a zero.
    /// * The scan's own hints (frame rate, ball size, per-frame seeds) are not kept, so the remaining
    ///   windows are measured without them. They are hints to the detector, not inputs to any
    ///   measurement, so the numbers are the same; it simply takes a little longer.
    @discardableResult
    func restore(from checkpoint: GuidedCheckpoint, model: AnalysisModel) -> Bool {
        guard let clip = model.clip, let cal = model.calibration, let k = model.intrinsics, !isBusy else { return false }
        cancelScan()
        cancelAnalysis()
        clipURL = clip.url
        timeScale = model.timeScale
        intrinsics = k
        calibration = cal
        rimUpProvenance = model.rimUpProvenance
        rimPoints = model.rimPoints
        hfovProvenance = clip.source == .recordedInApp ? "sidecar" : "assumed"
        scan = nil
        scanError = nil
        analysisError = nil
        scanProgress = 0
        scanMessage = nil
        pausedByInterruption = false
        savedSessionID = checkpoint.savedSessionID
        savedSpot = checkpoint.spot

        let savedByID = Dictionary(checkpoint.measured.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reasonByID = Dictionary(checkpoint.failed.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
        shots = checkpoint.windows.map { window in
            var shot = SessionShot(id: window.id, window: window)
            if let saved = savedByID[window.id] {
                shot.row = saved.row
                shot.restored = saved
                shot.status = .measured
                completionCounter += 1
                shot.completionOrder = completionCounter
            } else if let reason = reasonByID[window.id] {
                shot.status = .failed(reason)
            } else {
                shot.status = .queued
            }
            return shot
        }
        restoredFromCheckpoint = true
        // The lens re-pass re-analyses *every* window from scratch, which would throw away exactly the
        // shots this restore just rescued. It runs off the tracked samples, and restored shots have
        // none, so it could not decide honestly anyway. Marked done, with the reason kept for the UI.
        lensPassDone = true

        let queued = shots.filter { if case .queued = $0.status { return true }; return false }.count
        let measured = shots.filter { $0.row != nil }.count
        var notes: [String] = []
        notes.append("\(measured) shot\(measured == 1 ? "" : "s") measured before ArcLab closed were restored with the numbers, the verdicts and the ring they were measured with.")
        if queued > 0 {
            notes.append("\(queued) window\(queued == 1 ? "" : "s") \(queued == 1 ? "was" : "were") never measured and \(queued == 1 ? "is" : "are") being measured now.")
        }
        if !checkpoint.failed.isEmpty {
            notes.append("\(checkpoint.failed.count) window\(checkpoint.failed.count == 1 ? "" : "s") could not be measured before and \(checkpoint.failed.count == 1 ? "is" : "are") still listed with the reason.")
        }
        notes.append("A restored shot's own tracked path is not kept, so its detail screen cannot be opened; its numbers are unchanged.")
        notes.append("The lens check does not re-run on a restored session: it would re-measure every shot, including the ones just recovered.")
        restoreNote = notes.joined(separator: " ")
        lensNote = restoreNote
        ActivityLog.shared.event("checkpoint.restored", ["windows": shots.count, "measured": measured,
                                                         "queued": queued, "failed": checkpoint.failed.count,
                                                         "clip": checkpoint.clipFileName,
                                                         "spot": checkpoint.spot?.rawValue,
                                                         "step": checkpoint.step.rawValue])
        return true
    }

    // MARK: Analysing

    /// Analyse every queued shot, in clip order, one at a time. Each one uses exactly the runner the
    /// single-shot flow uses, so a shot opened from the session list and a shot analysed by hand are
    /// the same measurement.
    /// Gravity fits of the measured shots, for the lens check: (g_fit, reprojection rms in px).
    var gravityFits: [(g: Double, rmsPx: Double)] {
        shots.compactMap { s in s.result.map { (g: $0.analysis.confidence.gFit, rmsPx: $0.analysis.confidence.rmsPx) } }
    }

    /// Second pass with a corrected lens constant: take the model's re-calibrated rim and intrinsics,
    /// keep the windows, forget every measurement, and analyse again. The gravity check on the new
    /// pass is the check; nothing from the first pass is kept.
    func reanalyse(model: AnalysisModel, note: String) {
        guard let cal = model.calibration, let k = model.intrinsics, !isBusy else { return }
        calibration = cal
        rimUpProvenance = model.rimUpProvenance
        intrinsics = k
        timeScale = model.timeScale
        lensNote = note
        lensPassDone = true
        hfovProvenance = "gravity-calibrated"
        for i in shots.indices { shots[i].status = .queued; shots[i].result = nil; shots[i].row = nil }
        ActivityLog.shared.event("lens.repass", ["hfov": model.hfovDegrees, "note": note])
        analyseAll()
    }

    func analyseAll(redoFailed: Bool = false) {
        guard let url = clipURL, let cal = calibration, let k = intrinsics, !isBusy else { return }
        analysing = true
        keepAwake(true)
        analysisError = nil
        pausedByInterruption = false
        SessionNotifier.requestPermissionIfNeeded()
        let scale = timeScale
        let center = rimCenterPx ?? cal.ellipse.center
        let queue = shots.compactMap { shot -> Int? in
            switch shot.status {
            case .measured: return nil
            case .failed: return redoFailed ? shot.id : nil
            default: return shot.id
            }
        }
        let log = ActivityLog.shared
        let heartbeat = ActivityLog.Heartbeat()
        // How many windows can be in flight at once. One decoded window holds its half-resolution Y and Cr planes
        // for every frame — about 1 MB a frame at 1080p, so a 2 s real window at a 4× factor is ~255 MB — and the
        // brief's budget is 300 MB. The limit is therefore computed from the clip, never assumed; and a phone that
        // is already hot gets one at a time whatever the arithmetic says.
        let thermal = ProcessInfo.processInfo.thermalState
        let windowBytes = estimatedWindowBytes
        var lanes = windowBytes > 0 ? max(1, min(Self.maxConcurrentWindows, Int(Self.memoryBudgetBytes / windowBytes))) : 1
        let memoryLanes = lanes
        var laneReason = String(format: "%d window(s) at a time: one decoded window is about %.0f MB and the budget is %.0f MB",
                                lanes, Double(windowBytes) / 1e6, Double(Self.memoryBudgetBytes) / 1e6)
        // Only `critical` forces one lane now. `serious` used to, and on the 1080p120 footage that rule never
        // once decided anything: a 2.8 s window holds ~336 MB of half-resolution planes, which is already over
        // the 320 MB budget, so the arithmetic above had returned 1 before the thermal state was even read
        // (phone log 2026-09-15: `lanes 1, windowMB 335.9` on every run, thermal fair *and* serious). Leaving the
        // rule in place hid that. A clip whose windows do fit two lanes now keeps them when the phone is merely
        // hot, and the log says which of the two limits bound.
        if thermal == .critical {
            lanes = 1
            laneReason = "one window at a time: the phone is in a critical thermal state"
        } else if thermal == .serious, lanes > 1 {
            laneReason += "; the phone is in a serious thermal state but the decoder and the Neural Engine, not the CPU, are the limit here"
        }
        analysisNote = laneReason
        let laneCount = lanes
        log.event("analysis.start", ["queued": queue.count, "shots": shots.count, "lanes": lanes,
                                     "memoryLanes": memoryLanes,
                                     "windowMB": Double(windowBytes) / 1e6, "budgetMB": Double(Self.memoryBudgetBytes) / 1e6,
                                     "deferBody": Self.deferBodyStage, "thermal": ActivityLog.thermal()])
        let batchStart = DispatchTime.now()
        completedWindowSeconds = []
        batchWallStart = Date()
        lastCompletionWall = Date()
        let fps = scan?.measuredFrameRate
        let frameSize = scan.map { ($0.frameSize.width, $0.frameSize.height) }
        let ballPx = scan?.ballDiameterPx
        let seeds = scan?.seedsByFrame ?? [:]
        analyseTask = Task { [cal, k] in
            await withTaskGroup(of: (Int, Result<ShotRunResult, any Error>).self) { @MainActor group in
                var pending = queue
                var running = 0

                @MainActor func launch(_ id: Int, into group: inout TaskGroup<(Int, Result<ShotRunResult, any Error>)>) {
                    guard let i = shots.firstIndex(where: { $0.id == id }) else { return }
                    let w = shots[i].window
                    shots[i].status = .analyzing("starting…")
                    shots[i].result = nil
                    shots[i].row = nil
                    let watch = ActivityLog.Stopwatch("analysis.shot", ["shot": id, "windowStart": w.start, "windowEnd": w.end])
                    // Only the seeds that fall inside this window: the rest are other shots.
                    let lo = Int((w.start * (fps ?? 30)).rounded()), hi = Int((w.end * (fps ?? 30)).rounded())
                    let windowSeeds = seeds.filter { $0.key >= lo && $0.key <= hi }
                    running += 1
                    group.addTask(priority: .userInitiated) { [cal, k] in
                        let timings = StageTimings()
                        do {
                            let r = try await ShotAnalysisRunner.run(url: url, start: w.start, end: w.end, timeScale: scale,
                                                                     calibration: cal, intrinsics: k,
                                                                     runBody: !Self.deferBodyStage,
                                                                     fps: fps, frameSize: frameSize,
                                                                     ballDiameterPxHint: ballPx, seed: windowSeeds,
                                                                     timings: timings) { text in
                                heartbeat.tick("analysis", ["shot": id, "message": text])
                                watch.lap(text)
                                Task { @MainActor in
                                    if let j = self.shots.firstIndex(where: { $0.id == id }) {
                                        self.shots[j].status = .analyzing(text)
                                    }
                                }
                            }
                            var row = timings.dictionary.mapValues { $0 as Any }
                            row["lanes"] = laneCount
                            row["thermal"] = ActivityLog.thermal()
                            row["phase"] = Self.deferBodyStage ? "ball" : "ball+body"
                            watch.lap("stages", row)
                            return (id, .success(r))
                        } catch {
                            var row = timings.dictionary.mapValues { $0 as Any }
                            row["lanes"] = laneCount
                            row["thermal"] = ActivityLog.thermal()
                            row["phase"] = Self.deferBodyStage ? "ball" : "ball+body"
                            watch.lap("stages", row)
                            return (id, .failure(error))
                        }
                    }
                }

                while running < lanes, !pending.isEmpty { launch(pending.removeFirst(), into: &group) }
                while let (id, outcome) = await group.next() {
                    running -= 1
                    switch outcome {
                    case .success(let result):
                        if let i = shots.firstIndex(where: { $0.id == id }) {
                            shots[i].result = result
                            let tRow = StageTimings.now()
                            let row = BlockRow(id: id, result: result, rimCenterPx: center)
                            let rowSeconds = StageTimings.now() - tRow
                            shots[i].row = row
                            completionCounter += 1
                            shots[i].completionOrder = completionCounter
                            if let last = lastCompletionWall { completedWindowSeconds.append(Date().timeIntervalSince(last) / Double(max(1, lanes))) }
                            lastCompletionWall = Date()
                            shots[i].status = .measured
                            if !Self.deferBodyStage, row.verdict.isAccepted, let shot = result.body?.bodyShot {
                                Self.export(shot, key: clipURL?.deletingPathExtension().lastPathComponent ?? "clip",
                                            shotID: id, provenance: hfovProvenance)
                            }
                            log.event("analysis.shot.done", ["shot": id, "verdict": row.verdict.label, "reason": row.verdict.reason,
                                                             "gFit": row.gFit, "rmsPx": result.analysis.confidence.rmsPx,
                                                             "release": row.releaseSpeed, "angle": row.releaseAngleDegrees,
                                                             "height": row.releaseHeight, "entry": row.entryAngleDegrees,
                                                             "depth": row.depthPastFrontRim, "outcome": row.outcome.outcome.rawValue,
                                                             "samples": result.samples.count, "view": row.viewClass.rawValue,
                                                             "elbow": row.elbowAtReleaseDegrees, "dipToRelease": row.dipToReleaseSeconds,
                                                             "rowSeconds": rowSeconds, "thermal": ActivityLog.thermal()])
                        }
                    case .failure(let error):
                        if error is CancellationError {
                            if let i = shots.firstIndex(where: { $0.id == id }) { shots[i].status = .queued }
                        } else if Self.isDecodingInterruption(error) {
                            // The checkpoint: this window goes back to the queue with nothing invented,
                            // every window already measured keeps its numbers, and no more are started.
                            if let i = shots.firstIndex(where: { $0.id == id }) { shots[i].status = .queued }
                            pausedByInterruption = true
                            log.event("analysis.shot.interrupted", ["shot": id, "error": "\(error)"])
                        } else if let i = shots.firstIndex(where: { $0.id == id }) {
                            shots[i].status = .failed("\(error)")
                            log.event("analysis.shot.failed", ["shot": id, "error": "\(error)"])
                        }
                    }
                    // Every shot, as it lands. A death after this line costs the shot being analysed
                    // and nothing else.
                    checkpoint()
                    if Task.isCancelled || pausedByInterruption { pending.removeAll() }
                    while running < lanes, !pending.isEmpty { launch(pending.removeFirst(), into: &group) }
                }
            }
            let ballSeconds = Double(DispatchTime.now().uptimeNanoseconds - batchStart.uptimeNanoseconds) / 1e9
            let s0 = summary
            log.event("analysis.ball.end", ["seconds": ballSeconds, "tracked": s0.tracked,
                                            "accepted": s0.accepted, "failed": s0.failed, "thermal": ActivityLog.thermal()])
            // Second pass: the body models. Every ball number is already on screen — this only fills in the form
            // card — so it runs after the whole block has been measured rather than inside each window.
            if Self.deferBodyStage {
                await self.runBodyPhase(ids: queue, url: url, scale: scale, intrinsics: k,
                                        rimCentre: center, log: log)
            }
            analysing = false
            keepAwake(scanning)
            let s = summary
            if pausedByInterruption {
                analysisNote = Self.pauseMessage
                log.event("analysis.paused", ["measured": s.tracked, "accepted": s.accepted,
                                              "queued": shots.filter { if case .queued = $0.status { return true }; return false }.count])
            } else {
                SessionNotifier.analysisFinished(accepted: s.accepted, of: shots.count)
            }
            log.event("analysis.end", ["seconds": Double(DispatchTime.now().uptimeNanoseconds - batchStart.uptimeNanoseconds) / 1e9,
                                       "ballSeconds": ballSeconds,
                                       "tracked": s.tracked, "accepted": s.accepted, "failed": s.failed, "thermal": ActivityLog.thermal()])
            checkpoint()
        }
    }

    /// Analyse the ball for every window first, then come back for the body models. What the shooter waits for
    /// is the shot's numbers; the body model is a card that can arrive a minute later without anyone noticing,
    /// and on a hot phone it is a quarter of the window's cost. Nothing about the ball numbers changes — the
    /// body stage never feeds the fit; it is handed the release the analyzer already used.
    nonisolated static let deferBodyStage = true

    /// The second pass. One shot at a time, in completion order, so the first shots the shooter looks at are the
    /// first to gain a body card.
    private func runBodyPhase(ids attempted: [Int], url: URL, scale: Double, intrinsics: CameraIntrinsics,
                              rimCentre: SIMD2<Double>, log: ActivityLog) async {
        // Only the windows this batch measured, in the order they were queued, and only those still without a
        // body model. A window whose ball flight failed is skipped by `bodyOnly` itself, with the reason.
        let ids = attempted.filter { id in
            guard let i = shots.firstIndex(where: { $0.id == id }), let r = shots[i].result else { return false }
            return r.body == nil
        }
        guard !ids.isEmpty else { return }
        let start = DispatchTime.now()
        log.event("analysis.body.start", ["shots": ids.count, "thermal": ActivityLog.thermal()])
        analysisNote = "measuring the body model for \(ids.count) shot(s)…"
        bodyPhase = (0, ids.count)
        var done = 0
        for id in ids {
            if Task.isCancelled { break }
            guard let idx = shots.firstIndex(where: { $0.id == id }), let result = shots[idx].result else { continue }
            let watch = ActivityLog.Stopwatch("analysis.body", ["shot": id])
            let timings = StageTimings()
            let (body, why) = await ShotAnalysisRunner.bodyOnly(url: url, result: result, timeScale: scale,
                                                               intrinsics: intrinsics, rimImageU: rimCentre.x,
                                                               timings: timings)
            guard let j = shots.firstIndex(where: { $0.id == id }) else { continue }
            var updated = shots[j].result ?? result
            updated.body = body
            updated.bodyUnavailableReason = why
            shots[j].result = updated
            let row = BlockRow(id: id, result: updated, rimCenterPx: rimCentre)
            shots[j].row = row
            done += 1
            bodyPhase = (done, ids.count)
            analysisNote = "body model \(done) of \(ids.count)…"
            var stageRow = timings.dictionary.mapValues { $0 as Any }
            stageRow["phase"] = "body"
            stageRow["thermal"] = ActivityLog.thermal()
            watch.lap("stages", stageRow)
            if row.verdict.isAccepted, let shot = body?.bodyShot {
                Self.export(shot, key: clipURL?.deletingPathExtension().lastPathComponent ?? "clip",
                            shotID: id, provenance: hfovProvenance)
            }
            // The body pass rewrites the row, so the checkpoint has to follow it.
            checkpoint()
        }
        analysisNote = nil
        bodyPhase = nil
        log.event("analysis.body.end", ["seconds": Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9,
                                        "shots": done, "thermal": ActivityLog.thermal()])
    }

    /// `BodyShotWriter.write` already encodes and writes on its own utility queue — checked, not assumed — so
    /// this is only the one place that decides *when* a record is written. Its cost is logged by `body.export`.
    private static func export(_ shot: BodyShot, key: String, shotID: Int, provenance: String) {
        BodyShotWriter.write(shot, sessionKey: key, shotID: shotID, hfovProvenance: provenance)
    }

    /// Roughly how much a decoded window holds: one half-resolution luma plane and one chroma plane per frame.
    private var estimatedWindowBytes: Int {
        guard let scan, scan.measuredFrameRate > 0, scan.frameSize.width > 0, let w = shots.first?.window else { return 0 }
        let frames = Int(((w.end - w.start) * scan.measuredFrameRate).rounded())
        let perFrame = (scan.frameSize.width / 2) * (scan.frameSize.height / 2) * 2
        return max(0, frames * perFrame)
    }

    /// Pick up after a pause. Everything measured is kept: the interrupted windows were put back in
    /// the queue, so this is the same batch continuing, not a re-measurement.
    func resumeAfterInterruption(model: AnalysisModel) {
        guard pausedByInterruption, !isBusy else { return }
        pausedByInterruption = false
        analysisNote = nil
        scanMessage = nil
        let queued = shots.filter { if case .queued = $0.status { return true }; return false }.count
        ActivityLog.shared.event("analysis.resume", ["queued": queued, "measured": shots.filter { $0.row != nil }.count,
                                                     "shots": shots.count])
        if shots.isEmpty {
            startScan(model: model)
        } else if queued > 0 {
            analyseAll()
        }
    }

    func cancelAnalysis() {
        ActivityLog.shared.event("analysis.cancel")
        analyseTask?.cancel()
        analyseTask = nil
    }

    func reset() {
        cancelScan()
        cancelAnalysis()
        shots = []
        scan = nil
        scanError = nil
        analysisError = nil
        scanProgress = 0
        scanMessage = nil
        lensNote = nil
        lensPassDone = false
        pausedByInterruption = false
        savedSessionID = nil
        savedSpot = nil
        restoredFromCheckpoint = false
        restoreNote = nil
    }

    // MARK: Results

    func resultContext(for shot: SessionShot) -> ShotResultContext? {
        guard let url = clipURL, let k = intrinsics, let r = shot.result else { return nil }
        return ShotResultContext(title: "Shot \(shot.id)", clipURL: url, timeScale: timeScale, intrinsics: k,
                                 rimPoints: rimPoints, analysis: r.analysis, samples: r.samples, notes: r.notes,
                                 pose: r.pose, body: r.body, bodyUnavailableReason: r.bodyUnavailableReason,
                                 window: shot.window.start...shot.window.end,
                                 verdict: shot.verdict, outcome: shot.outcome)
    }
}

// ================================================================================================
// MARK: - Telling the shooter it finished
// ================================================================================================

/// One local notification when a block finishes and the phone is not being looked at. Local only:
/// `UNUserNotificationCenter` schedules it on this device, nothing is sent anywhere (CLAUDE.md §6).
/// Permission is asked the first time an analysis starts, not at launch, so the ask has a reason
/// the shooter can see.
@MainActor
enum SessionNotifier {
    static func requestPermissionIfNeeded() {
        // The unattended benchmark drives the same models; it must never stop on a permission sheet.
        guard !BenchRunner.requested else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                ActivityLog.shared.event("notify.permission", ["granted": granted, "error": error.map { "\($0)" }])
            }
        }
    }

    /// Only when ArcLab is not on screen: a banner over the screen the shooter is already reading
    /// would say nothing the feed has not said.
    static func analysisFinished(accepted: Int, of windows: Int) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Session analysed"
        content.body = "\(accepted) of \(windows) shots accepted."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "arclab.analysis.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            ActivityLog.shared.event("notify.sent", ["accepted": accepted, "windows": windows, "error": error.map { "\($0)" }])
        }
    }
}
