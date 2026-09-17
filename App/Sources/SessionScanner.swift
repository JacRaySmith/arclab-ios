import Foundation
import ShotGeometry
import ShotVideo
import simd

/// One shot window found by the whole-clip scan. All times are **file** seconds, the clock the
/// decoder and every window control in the app use.
struct ShotWindow: Sendable, Identifiable, Equatable {
    var id: Int                      // 1-based, in clip order
    var arrivalFileTime: Double      // the frame on which the ball arrived at the rim
    var start: Double
    var end: Double
    /// Evidence that made this an arrival, kept so the UI can say why a window exists.
    var descentCandidates: Int       // ball-sized candidates high in the frame in the 1.5 s real before it
    var arrivalDistancePx: Double    // how close to the rim centre the arriving candidate was
    var arrivalDiameterPx: Double
}

/// How the whole-clip pass finds its candidates.
enum SessionScanMode: String, Sendable {
    /// Decode once and look for ball-sized moving blobs on a crop around the rim (`RimArrivalScanner`).
    case fast
    /// The old pass: Vision's `DetectTrajectoriesRequest` over the whole clip, in chunks.
    case vision
}

struct SessionScanOptions: Sendable {
    /// `.fast` unless something needs the old scanner for comparison.
    var mode: SessionScanMode = .fast
    /// Fast scanner: process every n-th decoded frame, at 1/`downscale` resolution.
    /// 1 = every decoded frame. 0 would let `RimArrivalScanner` choose the stride from the clip's real frame
    /// rate (`RimScanOptions.processHz`); that is measured in PHASE2-PREP and is **not** the default, because a
    /// stride moves the arrival frame and the release instant moves with it.
    var everyNthFrame: Int = 1
    var downscale: Int = 4
    /// `TrajectoryTracker` holds one stateful Vision request, so the scan runs it once per chunk of
    /// file time. 60 s is long enough that the per-chunk probe is a small fraction of the work.
    var chunkSeconds: Double = 60
    /// Chunks overlap so a flight that straddles a boundary is still seen whole by one of them.
    var chunkOverlapSeconds: Double = 3
    var scanStart: Double = 0
    var scanEnd: Double? = nil
    // The window, in *real* seconds around the arrival (converted to file time with the time scale).
    var preRollRealSeconds: Double = 1.3
    var preMarginRealSeconds: Double = 0.35
    var postRollRealSeconds: Double = 0.4
    /// The arrival rule (tools/pytrack/session.py `find_arrivals`), in ball diameters and real seconds.
    var rule = ArrivalRuleOptions()
    init() {}
}

struct SessionScanResult: Sendable {
    var windows: [ShotWindow]
    var framesScanned: Int
    /// Ball-sized candidates the scan produced (blobs for `.fast`, Vision samples for `.vision`).
    var candidateCount: Int
    var chunks: Int
    var measuredFrameRate: Double
    var ballDiameterPx: Double
    var rimCenterPx: SIMD2<Double>
    var frameSize: (width: Int, height: Int)
    /// One coarse ball position per frame index, good enough to aim the detector's Core ML tile.
    var seedsByFrame: [Int: SIMD2<Double>]
    var mode: SessionScanMode
    var scanned: ClosedRange<Double>
    var notes: [String]
    /// Where the scan's seconds went (`scan.decode`, `scan.detect`), so the phone log shows the split rather
    /// than one total. Summed across the scanner's lanes, so it is CPU seconds, not wall time.
    var stageSeconds: [String: Double] = [:]
}

enum SessionScanError: Error, CustomStringConvertible {
    case emptyRange
    case noRimPoints

    var description: String {
        switch self {
        case .emptyRange: return "the scan range is empty: set an end time after the start time"
        case .noRimPoints: return "the rim has not been marked, so the scan has no rim centre to measure arrivals against"
        }
    }
}

/// A fast whole-clip pass that finds *where the shots are*, so the expensive per-shot analysis only
/// runs on windows that contain one.
///
/// The rule is `tools/pytrack/session.py` `find_arrivals`, ported: a shot is a **ball arriving at the
/// rim** — a ball-sized candidate within 2.5 diameters of the rim centre, moving down (a candidate
/// near it and above it in the previous three frames), preceded within 1.5 s of real time by at least
/// six ball-sized candidates high in the frame (the descent into the rim has to come from somewhere).
/// At most one arrival per 3 s of real time. Nothing about the shot is measured here; the window is
/// only a place to point the analyzer.
///
/// The candidates come from `RimArrivalScanner` (`.fast`, the default): the clip is decoded once and, on a
/// downscaled crop of the rows the rule actually reads — the upper 40 % of the frame plus the rim's own
/// neighbourhood — ball-sized moving blobs are found against a running background. Vision's whole-clip
/// `DetectTrajectoriesRequest` (`.vision`) is kept for comparison: it costs about five milliseconds a frame,
/// which is minutes on a phone, and the rule never wanted trajectories in the first place. On
/// `footage/2026-09-13/IMG_1765.mov` the two scanners agree on 28 of 30 arrivals (see
/// `docs/HANDOFF.md` "Speed, 2026-09-14").
enum SessionScanner {
    /// The ball's apparent diameter *at the rim*, from the one calibrated ruler in the picture: the rim
    /// ellipse. `2 · semiMajor` pixels span `rimDiameterUsed` metres at the rim's distance, and an
    /// arriving ball is at that distance.
    static func ballDiameterPxAtRim(calibration: RimCalibration, ballDiameter: Double = BallSize.size7.diameter) -> Double {
        2 * calibration.ellipse.semiMajor * (ballDiameter / calibration.rimDiameterUsed)
    }

    /// - Parameters:
    ///   - timeScale: file time ÷ this = real time.
    ///   - ballDiameterPx: nil = derive it from the rim ellipse.
    ///   - progress: (fraction 0…1, message). Called on an arbitrary executor.
    /// - Throws: `CancellationError` when the task is cancelled, so the UI can stop a long scan.
    static func run(url: URL,
                    timeScale: Double,
                    calibration: RimCalibration,
                    rimPoints: [SIMD2<Double>],
                    ballDiameterPx: Double? = nil,
                    options: SessionScanOptions = .init(),
                    timings: StageTimings? = nil,
                    progress: @escaping @Sendable (Double, String) -> Void) async throws -> SessionScanResult {
        guard !rimPoints.isEmpty else { throw SessionScanError.noRimPoints }
        let scanEnd = options.scanEnd ?? .infinity
        guard scanEnd > options.scanStart else { throw SessionScanError.emptyRange }

        let D = ballDiameterPx ?? ballDiameterPxAtRim(calibration: calibration)
        let rimCenter = calibration.ellipse.center
        let rimMean = rimPoints.reduce(SIMD2<Double>(0, 0), +) / Double(rimPoints.count)

        var notes: [String] = []
        notes.append(String(format: "rim centre (fitted ellipse) %.1f, %.1f px; the mean of the %d marked points is %.1f, %.1f px (%.1f px apart)",
                            rimCenter.x, rimCenter.y, rimPoints.count, rimMean.x, rimMean.y,
                            (((rimCenter.x - rimMean.x) * (rimCenter.x - rimMean.x)) + ((rimCenter.y - rimMean.y) * (rimCenter.y - rimMean.y))).squareRoot()))
        notes.append(String(format: "ball ≈ %.0f px at the rim, from the rim ellipse (%.0f px across = %.4f m)", D, 2 * calibration.ellipse.semiMajor, calibration.rimDiameterUsed))

        // One dense slot per frame index over the scanned range, so "the previous three frames" means the same
        // thing it means in the Python scanner even where nothing was seen.
        var slots: [Int: [ArrivalCandidate]] = [:]
        var seeds: [Int: SIMD2<Double>] = [:]
        var framesScanned = 0
        var candidateCount = 0
        var chunks = 0
        var fps = 0.0
        var width = 0, height = 0
        var lastEnd = options.scanStart

        switch options.mode {
        case .fast:
            var so = RimScanOptions()
            so.startTime = options.scanStart
            so.endTime = options.scanEnd
            so.everyNthFrame = options.everyNthFrame
            so.downscale = options.downscale
            // The scanner turns `processHz` into a stride, and a 120 fps clip written at 30 is 120 fps of real
            // motion, not 30 — so it has to be told the file's slow-motion factor.
            so.timeScale = timeScale
            let span = scanEnd.isFinite ? scanEnd - options.scanStart : 0
            let scanFrom = options.scanStart
            let result = try await RimArrivalScanner.scan(url: url, rimCenter: rimCenter, ballDiameterPx: D,
                                                          options: so, timings: timings) { frames, pts in
                let f = span > 0 ? min(1, max(0, (pts - scanFrom) / span)) : 0
                progress(f, String(format: "scanning: %d frames, t = %.1f s", frames, pts))
            }
            chunks = 1
            framesScanned = result.framesDecoded
            candidateCount = result.candidates.count
            fps = result.measuredFrameRate
            width = result.width; height = result.height
            lastEnd = result.candidates.last?.pts ?? options.scanStart
            for c in result.candidates {
                slots[c.frameIndex, default: []].append(ArrivalCandidate(u: c.u, v: c.v, diameterPx: c.diameterPx))
                if seeds[c.frameIndex] == nil { seeds[c.frameIndex] = SIMD2(c.u, c.v) }
            }
            notes.append(contentsOf: result.notes)

        case .vision:
            var chunkStart = options.scanStart
            while chunkStart < scanEnd {
                try Task.checkCancellation()
                let from = chunkStart
                let chunkEnd = min(from + options.chunkSeconds, scanEnd)
                var opt = TrajectoryTrackerOptions()
                opt.startTime = from
                opt.endTime = chunkEnd
                let span = scanEnd.isFinite ? scanEnd - options.scanStart : 0
                let base = span > 0 ? (from - options.scanStart) / span : 0
                let scanFrom = options.scanStart
                let run = try await TrajectoryTracker.run(url: url, options: opt) { frames, pts in
                    let f = span > 0 ? min(1, max(0, (pts - scanFrom) / span)) : base
                    progress(f, String(format: "scanning %.0f–%.0f s: %d frames, t = %.1f s", from, chunkEnd, frames, pts))
                }
                chunks += 1
                framesScanned += run.framesProcessed
                if fps == 0 { fps = run.probe.measuredFrameRate; width = run.probe.width; height = run.probe.height }
                for track in run.tracks {
                    for s in track.samples {
                        candidateCount += 1
                        let idx = Int((s.pts * fps).rounded())
                        let c = ArrivalCandidate(u: s.u, v: s.v, diameterPx: 2 * s.radiusPx)
                        // Overlapping chunks can report the same object twice; drop a duplicate within 2 px.
                        if let existing = slots[idx], existing.contains(where: { abs($0.u - c.u) < 2 && abs($0.v - c.v) < 2 }) { continue }
                        slots[idx, default: []].append(c)
                        if seeds[idx] == nil { seeds[idx] = SIMD2(c.u, c.v) }
                    }
                }
                lastEnd = max(lastEnd, chunkEnd)
                if run.framesProcessed == 0 { break }         // the clip ended before this chunk did
                if chunkEnd >= scanEnd { break }
                chunkStart = chunkEnd - options.chunkOverlapSeconds
            }
            notes.append("candidates from Vision's whole-clip trajectory detector (the pre-2026-09-14 scanner)")
        }

        guard fps > 0 else {
            notes.append("no frames were decoded in the scan range")
            return SessionScanResult(windows: [], framesScanned: framesScanned, candidateCount: 0, chunks: chunks,
                                     measuredFrameRate: 0, ballDiameterPx: D, rimCenterPx: rimCenter,
                                     frameSize: (0, 0), seedsByFrame: [:], mode: options.mode,
                                     scanned: options.scanStart...max(options.scanStart, lastEnd), notes: notes,
                                     stageSeconds: timings?.dictionary ?? [:])
        }

        progress(1, "applying the rim-arrival rule…")
        let found = ArrivalRule.arrivals(slots: slots, fps: fps, frameHeight: Double(height), rimCenter: rimCenter,
                                         ballDiameterPx: D, timeScale: timeScale, options: options.rule)
        var windows: [ShotWindow] = []
        for (i, a) in found.enumerated() {
            let start = max(0, a.fileTime - (options.preRollRealSeconds + options.preMarginRealSeconds) * timeScale)
            let end = a.fileTime + options.postRollRealSeconds * timeScale
            windows.append(ShotWindow(id: i + 1, arrivalFileTime: a.fileTime, start: start, end: end,
                                      descentCandidates: a.high, arrivalDistancePx: a.distancePx,
                                      arrivalDiameterPx: a.diameterPx))
        }
        notes.append(String(format: "window = arrival − %.2f s real (%.2f s flight + %.2f s margin) → arrival + %.2f s real, i.e. %.2f s of file time at a %.2f× factor",
                            options.preRollRealSeconds + options.preMarginRealSeconds, options.preRollRealSeconds,
                            options.preMarginRealSeconds, options.postRollRealSeconds,
                            (options.preRollRealSeconds + options.preMarginRealSeconds + options.postRollRealSeconds) * timeScale, timeScale))
        return SessionScanResult(windows: windows, framesScanned: framesScanned, candidateCount: candidateCount,
                                 chunks: chunks, measuredFrameRate: fps, ballDiameterPx: D, rimCenterPx: rimCenter,
                                 frameSize: (width, height), seedsByFrame: seeds, mode: options.mode,
                                 scanned: options.scanStart...max(options.scanStart, lastEnd), notes: notes,
                                 stageSeconds: timings?.dictionary ?? [:])
    }

    /// `find_arrivals` now lives in `ShotVideo.ArrivalRule` so the desktop probe can run the same rule over the
    /// old scanner's candidates and the new one's and compare the two lists directly.
    typealias Arrival = ArrivalEvent

    static func arrivals(slots: [Int: [ArrivalCandidate]], fps: Double, frameHeight: Double,
                         rimCenter: SIMD2<Double>, ballDiameterPx D: Double, timeScale: Double,
                         options: ArrivalRuleOptions = .init()) -> [ArrivalEvent] {
        ArrivalRule.arrivals(slots: slots, fps: fps, frameHeight: frameHeight, rimCenter: rimCenter,
                             ballDiameterPx: D, timeScale: timeScale, options: options)
    }
}
