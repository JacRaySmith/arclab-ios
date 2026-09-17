import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Accelerate
import ShotGeometry

/// Classical per-frame ball detector for a static camera, ported from `tools/pytrack/track.py` so the phone can run it.
///
/// Per frame: round, orange, moving blobs against a median background (diff = |Y−bgY| + w·|Cr−bgCr|, gated on Cr
/// above the background), connected components with a ball-sized area, low aspect ratio and reasonable circularity,
/// diff²-weighted centroid (or the centre of the loose-threshold local disc when it captures the whole ball), size from
/// the loose local component's smaller side. Linking: seeded from the caller's coarse positions, forward with a
/// constant-velocity / parabolic predictor, a gate that grows while frames are missed, survival of the ball leaving the
/// top of the frame with re-acquisition in the top band, backward extension into the hands. Post-pass: projected-parabola
/// fit on the clean detections plus normalized cross-correlation template matching for the missing frames near release
/// (`source == "template"`). A frame without evidence yields no detection; nothing is interpolated.
public struct BallDetection: Sendable, Codable {
    public var frameIndex: Int
    public var pts: Double
    public var u: Double
    public var v: Double
    public var diameterPx: Double
    public var score: Double        // mean diff intensity of the blob ("detected") or the NCC peak ("template")
    public var predicted: Bool      // kept for API compatibility; always false (no position is ever extrapolated)
    public var source: String       // "detected" | "template"
    public var edge: Bool           // the blob touches the frame edge: its centroid is biased
    public init(frameIndex: Int, pts: Double, u: Double, v: Double, diameterPx: Double,
                score: Double, predicted: Bool, source: String, edge: Bool) {
        self.frameIndex = frameIndex; self.pts = pts; self.u = u; self.v = v; self.diameterPx = diameterPx
        self.score = score; self.predicted = predicted; self.source = source; self.edge = edge
    }
}

public struct BallDetectorOptions: Sendable {
    public var expectedDiameterPx: Double = 60
    public var refineDiameterFromSeeds: Bool = true   // median size of candidates coinciding with the seed positions
    public var backgroundFrames: Int = 25
    public var diffThreshold: Double = 16             // |Y−bgY| + chromaWeight·|Cr−bgCr|
    public var chromaWeight: Double = 3.0
    public var orangeMargin: Double = 6               // Cr above the background
    public var extentThreshold: Double = 14           // loose local threshold used only to measure the ball's size
    public var minAreaFraction: Double = 0.105        // of the expected disc area
    public var maxAreaFraction: Double = 5.2
    public var maxAspect: Double = 2.2
    public var circularityMin: Double = 0.5
    public var extentCentroid: Bool = true            // use the loose disc's centre when it captures the full ball
    // MARK: Frame rate
    //
    // Every gate below that limits how far the ball may move, or how long the tracker may wait, is a
    // **physical** quantity: a speed in ball diameters per real second, or a duration in real seconds. The
    // per-file-frame numbers the linker actually uses are derived from the clip's capture rate, so the same
    // option values behave the same way on a 120 fps clip and on a 240 fps one. They were tuned at
    // `referenceFrameRate`; the comments give the per-frame value there, which is what the 2026-09-14 numbers
    // in `docs/HANDOFF.md` were measured with.

    /// Slow-motion factor of the file: file seconds ÷ this = real seconds. With the file's own frame rate it
    /// gives the **capture rate** — how many frames of real motion there are in a second — which is what every
    /// gate below is divided by. A 30 fps file shot at 120 fps has `timeScale` 4; a true 240 fps file has 1.
    ///
    /// `nil` means the caller did not say, and the gates fall back to `referenceFrameRate` — exactly the
    /// per-frame numbers every caller got before this existed, so no track moves by adding the option.
    public var timeScale: Double? = nil
    /// The capture rate the per-frame numbers in the comments below were tuned at (`docs/HANDOFF.md`,
    /// "Swift tracking parity, 2026-09-14": a 30 fps file at 4× slow motion).
    public var referenceFrameRate: Double = 120

    /// How far the ball may be from the linker's prediction and still be the same ball, as **ball diameters per
    /// real second** — a speed limit, not a distance. 240 D/s is the 2.0 D per frame this was tuned at on 120 fps
    /// footage; on a 240 fps clip it is 1.0 D per frame, because the ball only travels half as far between frames.
    /// Leaving it at 2.0 D per frame regardless of rate is what let a 240 fps track jump to the shooter's hands.
    public var maxLinkDiametersPerSecond: Double = 240
    /// The same gate as a multiple of the ball's own measured step between the last two frames. Dimensionless:
    /// the step already carries the frame rate, so this needs no scaling.
    public var gateSpeedFactor: Double = 2.5
    /// How much the gate grows for each **real second** of missed track (0.15 per frame at 120 fps).
    public var gateGrowthPerSecond: Double = 18
    /// How long the linker may go with no evidence before the track ends, in **real seconds** (6 frames at 120 fps).
    public var maxGapSeconds: Double = 0.05
    /// How long a track may stay alive while the ball is off the top of the frame, in **real seconds**
    /// (120 frames at 120 fps).
    public var maxOffframeSeconds: Double = 1.0
    /// How many forward links may be attempted from the caller's seed positions, **per `referenceFrameRate` of
    /// capture rate**. A pure compute budget — but a budget measured in frames covers half as much real time at
    /// 240 fps, and a window whose first 40 candidates are all rubbish then never reaches the flight.
    public var maxSeedsTried: Int = 40
    /// How far back into the hands the track may be extended, in **real seconds** (40 frames at 120 fps).
    public var extendBackSeconds: Double = 1.0 / 3
    /// How much history the parabolic predictor fits, in **real seconds** (10 frames at 120 fps), and the least
    /// it needs before it switches from constant velocity to the parabola (6 frames at 120 fps). At 240 fps a
    /// 10-frame history spans half the time and carries almost no curvature, so the prediction goes straight and
    /// noisy exactly where the descent needs it most.
    public var historySeconds: Double = 10.0 / 120
    public var minimumHistorySeconds: Double = 6.0 / 120
    /// How long after the track starts the shooter's body box begins excluding blobs, in **real seconds**
    /// (4 frames at 120 fps).
    public var bodyExclusionDelaySeconds: Double = 4.0 / 120
    public var templateFill: Bool = true
    public var templateMinScore: Double = 0.65
    /// How far either side of the tracked span the template fill reaches, and how close a clean detection has to
    /// be for it to fill a gap in the middle, both in **real seconds** (25 and 4 frames at 120 fps).
    public var templateReachSeconds: Double = 25.0 / 120
    public var templateNeighbourSeconds: Double = 4.0 / 120
    public var searchRadiusFactor: Double = 2.5       // unused by the ported linker; kept for callers that set it
    // Core ML per-frame detector (primary; the background-difference candidates stay as the per-frame fallback).
    public var useCoreML: Bool = true
    public var coreMLMinConfidence: Float = 0.30
    /// How long the running Core ML prediction keeps steering the tile, in **real seconds** (8 frames at 120 fps).
    public var coreMLGapSeconds: Double = 8.0 / 120
    /// How often the model may be run while the ball is being tracked, in **inferences per real second**. 120 Hz
    /// is every frame on 120 fps footage — the setting the three labelled free throws were measured with — and
    /// every 2nd frame on a 240 fps clip, which is the *same* sampling of the ball's real motion for half the
    /// inference. Dropping to 60 Hz (every 2nd frame at 120 fps) was measured on 2026-09-14 and rejected: it
    /// changes the track near the hands.
    public var coreMLInferenceRateHz: Double = 120
    /// How often the whole-frame sweep may run when nothing predicts the ball, in **sweeps per real second**.
    /// 60 Hz is every 2nd frame at 120 fps, which produced **bit-identical** tracks on all three labelled free
    /// throws for a third less inference (`docs/HANDOFF.md`, "Speed, 2026-09-14"); 40 Hz (every 3rd frame at
    /// 120 fps) changed the 89 s window, so 60 is where it stops.
    public var coreMLGlobalSweepRateHz: Double = 60
    /// Once the ball has been locked on at least once, stop sweeping the whole frame after this much **real time**
    /// with no box at all (45 frames — 0.375 s — at 120 fps). By then the flight is over and the sweeps return
    /// nothing; it changed none of the three labelled windows.
    public var coreMLGlobalSearchSecondsAfterLock: Double = 45.0 / 120
    /// A hard ceiling on whole-frame sweeps in one window. A window the model never locks on to is the most
    /// expensive window there is — 15 tiles a frame, for a ball that is not there — and it is also the window least
    /// likely to be worth anything. After this many sweeps with nothing found, the classical blobs carry the window.
    public var coreMLMaxGlobalSweeps: Int = 24
    /// When a tracked ball has been missed for a frame or two, re-find it with the most ball-like moving blob from a
    /// sixteenth-area background difference (`MotionProbe`) instead of widening the model's search to nine tiles.
    /// It is used **only** to re-aim at a ball the tracker already had: letting it aim before the ball has ever been
    /// seen puts boxes on the ball while it is still in the hands, and that moved the 313 s free throw's release from
    /// −2.5 to −15.5 file frames.
    public var coreMLAimFromMotion: Bool = true
    /// Skip the model on a tracked frame when the cheap motion probe already answers the only question the box is
    /// asked — *which* moving blob is the ball. With the ball locked on, a single ball-sized moving blob within
    /// `coreMLMotionAgreementDiameters` of the linker's own prediction is not ambiguous, and the hybrid placement
    /// takes the blob's centroid either way, so the box would only confirm what is already known. Off before the
    /// first lock and wherever the probe is silent or disagrees, which is where the model earns its seconds.
    ///
    /// It applies **only above `referenceFrameRate`**, so it can never take away an inference the detector was
    /// tuned with — it only removes some of the extra ones a faster camera adds. Allowing it at 120 fps was
    /// measured on 2026-09-15 and rejected: it moved the 313 s free throw's release from −2.5 to −4.5 file frames
    /// and the 817 s one from +0.5 to +2.5, and took their fit residuals from 5.47/5.68 px to 6.68/6.43 px.
    public var coreMLSkipWhenMotionAgrees: Bool = true
    public var coreMLMotionAgreementDiameters: Double = 0.75
    /// Skip the **whole-frame sweep** on a frame where the motion probe sees nothing ball-sized moving anywhere.
    /// A sweep is 15 tiles at 1080p and it is the whole Core ML bill once the tracked frames are cheap; the first
    /// second of a session window is a shooter standing at the line, where there is nothing for those 15 tiles to
    /// find. This is a **gate**, not an aim: when something is moving the sweep runs over the whole frame exactly
    /// as before, and the model still decides which box is the ball. (Aiming the sweep at the probe's blob before
    /// the first lock was measured on 2026-09-14 and rejected: it puts a box on the ball still in the hands and
    /// moves the 313 s free throw's release from −2.5 to −15.5 file frames.) A skipped sweep does not spend the
    /// `coreMLMaxGlobalSweeps` budget, so the budget still buys 24 sweeps of frames that might hold a ball.
    public var coreMLSweepOnlyWhenMoving: Bool = true
    /// How far a stale prediction widens the search, in extra tile strides, and how much **real time** without a
    /// box buys one. A widened region costs up to nine tiles instead of one, and this is where most of a window's
    /// inference went. A cap of 1 produced **bit-identical** tracks to the old cap of 2 on all three labelled free
    /// throws (`docs/HANDOFF.md`, "Speed, 2026-09-14"); 0 changed the 89 s window, so 1 is where it stops.
    public var coreMLStaleWidenCap: Int = 1
    public var coreMLStaleWidenPerSeconds: Double = 3.0 / 120
    // Hybrid placement. The model is markedly better at *finding* the ball and ~10–12 px worse at *placing* it
    // (docs/PHASE2-PREP.md, "Core ML detector integration"), so a box selects which background-difference blob is the
    // ball and the blob's sub-pixel centroid says where it is. The box centre is used only when no blob is inside it.
    public var coreMLHybridCentroid: Bool = true
    /// A box wider than this multiple of the running ball size has swallowed the rim and the net: with no blob inside
    /// it its centre is not the ball's, so the box is dropped rather than believed.
    public var coreMLMaxBoxDiameterFactor: Double = 1.8
    /// Keep ball-sized blobs that no box claimed as extra candidates for the linker (per-candidate, not per-frame, fallback).
    public var keepUnmatchedBlobs: Bool = true
    /// Dark descent: once the parabola is established, accept a weaker blob very close to its prediction
    /// (`tools/pytrack/track.py`'s `predicted_weak_candidates`).
    public var predictedWeakCandidates: Bool = true
    /// Backward extension into the hands: the link gate as **ball diameters per real second**. 180 D/s is the
    /// 1.5 D per frame pytrack uses on 120 fps footage; at 240 fps it is 0.75 D per frame, because the ball in
    /// the hand has only half as long to move.
    public var extendBackDiametersPerSecond: Double = 180
    /// Cut the track where free flight ends: after the apex the ball's image v only grows, so a rise of this many
    /// diameters off the running low point is a bounce off the rim, the net or the floor — not the shot any more.
    public var trimAfterBounce: Bool = true
    public var bounceRiseDiameters: Double = 0.25
    /// The least track, and the least distance past the apex, before a rise counts as a bounce: in **real
    /// seconds** (12 and 6 frames at 120 fps).
    public var bounceMinimumTrackSeconds: Double = 12.0 / 120
    public var bouncePastApexSeconds: Double = 6.0 / 120
    /// Cut the track where it stops being **free flight**, not merely where it bounces back up.
    ///
    /// `trimAfterBounce` only sees a rebound that climbs: a shot that swishes keeps falling, so the track runs on
    /// through the net to the floor and the analyzer's flight window swallows a metre of net-slowed, no-longer-
    /// ballistic motion. On the 240 fps free throws that put 90–220 px of reprojection residual on three windows
    /// and fitted gravity at 2.9–3.3 m/s² on two more where the ball bounced off the ring and back up above it.
    ///
    /// The test is the model itself: fit the projected parabola on the span around the apex, which is
    /// unambiguously free flight (well clear of the hands, the ring and the floor), then walk forward, refitting
    /// as the track is accepted, and cut at the first sample that leaves the model by more than
    /// `freeFlightResidualDiameters` of a ball and stays out for `freeFlightBreakSeconds`. Nothing is invented:
    /// the samples are still the detector's, they are simply no longer part of the flight being measured.
    public var trimAfterFreeFlight: Bool = true
    /// The seed span, in **real seconds** before and after the apex. 0.35 s back is still well above the release
    /// on a free throw (release to apex is ≈ 0.55 s) and gives the quadratic real curvature to fit.
    public var freeFlightSeedBeforeApexSeconds: Double = 0.35
    public var freeFlightSeedAfterApexSeconds: Double = 0.12
    /// How far a sample may sit from the free-flight model before it stops being part of the flight, in ball
    /// diameters, and how long it has to stay out, in **real seconds** (3 frames at 120 fps).
    public var freeFlightResidualDiameters: Double = 0.6
    public var freeFlightBreakSeconds: Double = 3.0 / 120
    /// The flight may only be declared over once the ball has fallen this many diameters below the apex — the same
    /// guard `trimAfterBounce` uses. Without it the trim cuts near the apex, where an arc that leaves the top of the
    /// frame leaves a hole in the seed and the model extrapolates badly: measured on 2026-09-15, that cost three
    /// 120 fps windows (89 s, 487 s, 741 s) half their inliers each and took the whole-clip count from 13 to 11.
    public var freeFlightMinimumDropDiameters: Double = 1.5
    public init() {}
}

/// What the detector did, so a caller can report it instead of guessing.
public struct BallDetectorStats: Sendable {
    public var coreMLFrames = 0               // frames whose candidates came from the Core ML detector
    public var classicalFallbackFrames = 0    // frames where Core ML found nothing and the classical blobs were used
    public var coreMLFramesRun = 0            // frames the model was actually run on
    public var coreMLTiles = 0                // 512-px tiles pushed through the model
    public var coreMLAimedFrames = 0          // frames searched around a prediction or a seed (1 tile, or more when stale)
    public var coreMLGlobalFrames = 0         // frames with nothing to aim at, so the whole frame was swept
    public var coreMLMotionSkippedFrames = 0  // tracked frames the model was skipped on: the motion probe already agreed
    public var coreMLStillFrameSweepsSkipped = 0  // whole-frame sweeps skipped: nothing ball-sized was moving at all
    public var coreMLSingleTileFrames = 0     // frames that cost exactly one tile: the steady state during a flight
    public var coreMLSingleTileSeconds = 0.0
    public var coreMLSeconds = 0.0            // wall time inside crop + inference
    public var coreMLUnavailableReason: String? = nil
    // Where the tracked positions came from, counted over the chosen track only.
    public var hybridRefinedFrames = 0        // a Core ML box chose the blob; the blob's centroid placed it
    public var hybridBoxOnlyFrames = 0        // no blob inside the box: the box centre was used
    public var blobOnlyFrames = 0             // no box on this frame: a plain background-difference blob
    public var weakDescentFrames = 0          // recovered by the relaxed near-prediction rule on the descent
    public var suppressedInflatedBoxes = 0    // boxes far larger than the ball (rim/net swallowed) with no blob inside
    /// Mean wall time per frame the model was run on, in milliseconds (crop included). Zero when it never ran.
    public var meanInferenceMilliseconds: Double {
        coreMLFramesRun > 0 ? coreMLSeconds / Double(coreMLFramesRun) * 1000 : 0
    }
    /// Mean wall time per tile, in milliseconds: the number that scales to a phone budget.
    public var meanTileMilliseconds: Double {
        coreMLTiles > 0 ? coreMLSeconds / Double(coreMLTiles) * 1000 : 0
    }
    /// Mean wall time on the frames that cost one tile — what a frame costs once the ball is being tracked.
    public var meanSingleTileMilliseconds: Double {
        coreMLSingleTileFrames > 0 ? coreMLSingleTileSeconds / Double(coreMLSingleTileFrames) * 1000 : 0
    }
    public var meanTilesPerFrame: Double {
        coreMLFramesRun > 0 ? Double(coreMLTiles) / Double(coreMLFramesRun) : 0
    }
    public init() {}
}

struct Plane8 {
    var width: Int, height: Int, data: [UInt8]
    subscript(x: Int, y: Int) -> Int { Int(data[y * width + x]) }
}

/// One blob on one frame, full-resolution pixels.
/// Which stage placed a candidate. Only the placement differs; the linker treats them all alike.
enum CandidateOrigin: Sendable { case blob, refined, box, weak }

struct BallCandidate {
    var u: Double, v: Double, diameter: Double, meanDiff: Double, circularity: Double, edge: Bool
    var origin: CandidateOrigin = .blob
}

/// The per-file-frame numbers every gate in `BallDetectorOptions` turns into, given the clip's capture rate.
///
/// The detector works in file frames, but nothing it tests is really about frames: how far a ball may move
/// between two images is a speed, and how long the tracker may wait for it is a duration. Both are set by the
/// **capture rate** — file frames per second × the file's slow-motion factor — and the gates were tuned on
/// footage captured at 120 fps. Everything below is that arithmetic in one place, so a gate is stated once, in
/// real units, and converted once.
struct FrameRates: Sendable {
    /// Frames of real motion per second: `file fps × timeScale`, or the reference rate when the caller did not say.
    let captureFPS: Double
    init(fileFPS: Double, options: BallDetectorOptions) {
        let derived = options.timeScale.map { fileFPS * $0 } ?? options.referenceFrameRate
        captureFPS = derived.isFinite && derived > 1 ? derived : options.referenceFrameRate
    }
    /// A real duration as a whole number of file frames, never less than one.
    func frames(_ seconds: Double) -> Int { max(1, Int((seconds * captureFPS).rounded())) }
    /// A rate in "per real second" as the per-file-frame amount.
    func perFrame(_ perSecond: Double) -> Double { perSecond / captureFPS }
    /// A rate in Hz as "run on every n-th file frame", never less than every frame.
    func everyNth(_ hertz: Double) -> Int { max(1, Int((captureFPS / max(1e-6, hertz)).rounded())) }
    /// A count budget that was measured at the reference rate and has to keep covering the same real time.
    func scaledCount(_ atReference: Int, reference: Double) -> Int {
        max(atReference, Int((Double(atReference) * captureFPS / max(1, reference)).rounded()))
    }
}

public enum BallDetector {
    /// Set `ARCLAB_SERIAL_PASSES=1` to run the background median and the per-frame candidate search on one core,
    /// as they ran before 2026-09-16. They are the same arithmetic either way — the split is by tile and by
    /// frame, and neither depends on its neighbours — so this exists only so the before/after can be timed in
    /// one binary rather than two.
    static let serialPasses = ProcessInfo.processInfo.environment["ARCLAB_SERIAL_PASSES"] == "1"

    /// Decodes [start, end] (file time), builds a background model, and tracks the ball through the window.
    /// `seed` supplies coarse positions by absolute frame index (e.g. from Vision) to choose the track.
    /// `bodyBoxes` (optional, full-res pixels, by frame index) excludes blobs on the shooter once the ball has left.
    public static func run(url: URL, start: Double, end: Double, seed: [Int: SIMD2<Double>], fps: Double,
                           options: BallDetectorOptions = .init(), bodyBoxes: [Int: CGRect] = [:]) async throws -> [BallDetection] {
        try await runDetailed(url: url, start: start, end: end, seed: seed, fps: fps,
                              options: options, bodyBoxes: bodyBoxes).detections
    }

    /// `run`, plus what the detector did (which stage produced each frame's candidates, and the inference cost).
    /// `run`, plus what the detector did (which stage produced each frame's candidates, and the inference cost).
    /// Decodes the window and tracks through it in one call; `decodeWindow` + `track` do the same work but let a
    /// caller pay for the decode once and try several parameter sets on it.
    public static func runDetailed(url: URL, start: Double, end: Double, seed: [Int: SIMD2<Double>], fps: Double,
                                   options: BallDetectorOptions = .init(), bodyBoxes: [Int: CGRect] = [:],
                                   timings: StageTimings? = nil)
        async throws -> (detections: [BallDetection], stats: BallDetectorStats)
    {
        let window = try await decodeWindow(url: url, start: start, end: end, seed: seed, fps: fps,
                                            options: options, timings: timings)
        return track(window: window, seed: seed, options: options, bodyBoxes: bodyBoxes, timings: timings)
    }

    /// One window decoded **exactly once**: the half-resolution Y and Cr planes of every frame and, when the Core ML
    /// detector is on, that frame's boxes — taken while the full-resolution buffer was still in hand. Every detector
    /// attempt on the window works from this, so a retry never decodes again and no tile is ever cut twice.
    public final class WindowFrames: @unchecked Sendable {
        let frames: [(index: Int, pts: Double, y: Plane8, cr: Plane8)]
        let coreMLCands: [[BallCandidate]]
        let coreMLAvailable: Bool
        let decodeStats: BallDetectorStats
        /// The background model, built once from these frames. Every detector attempt on the window uses the same
        /// one: it depends only on the frames and on `backgroundFrames`, never on a threshold.
        private var cachedBackground: (frames: Int, y: [Float], cr: [Float])?
        private let backgroundLock = NSLock()
        public let fps: Double
        public let width: Int            // full resolution
        public let height: Int
        public var frameCount: Int { frames.count }
        public var firstPTS: Double { frames.first?.pts ?? 0 }
        public var lastPTS: Double { frames.last?.pts ?? 0 }
        /// Resident bytes of the cached planes — what a memory-aware concurrency limit has to divide into.
        public var approximateBytes: Int {
            frames.count * (frames.first.map { $0.y.data.count + $0.cr.data.count } ?? 0)
        }
        init(frames: [(index: Int, pts: Double, y: Plane8, cr: Plane8)], coreMLCands: [[BallCandidate]],
             coreMLAvailable: Bool, decodeStats: BallDetectorStats, fps: Double, width: Int, height: Int) {
            self.frames = frames; self.coreMLCands = coreMLCands; self.coreMLAvailable = coreMLAvailable
            self.decodeStats = decodeStats; self.fps = fps; self.width = width; self.height = height
        }

        /// Per-pixel median of `count` frames spread across the window, as Float (what vDSP wants), memoised so
        /// every detector attempt on this window shares one background model.
        func background(count: Int) -> (y: [Float], cr: [Float]) {
            backgroundLock.lock(); defer { backgroundLock.unlock() }
            if let c = cachedBackground, c.frames == count { return (c.y, c.cr) }
            let built = BallDetector.medianBackground(frames: frames, count: count)
            cachedBackground = (count, built.y, built.cr)
            return built
        }
    }

    /// Per-pixel median of `count` frames spread across the window.
    ///
    /// Tile by tile: the K planes of one tile are gathered into a ~200 KB buffer that fits in L2 before any medians
    /// are taken, and the median is an insertion sort on a raw pointer rather than `Array.sort()`, which costs a
    /// generic dispatch and a uniqueness check per pixel and collapses in a debug build.
    static func medianBackground(frames: [(index: Int, pts: Double, y: Plane8, cr: Plane8)], count: Int)
        -> (y: [Float], cr: [Float])
    {
        guard let first = frames.first else { return ([], []) }
        let n = first.y.width * first.y.height
        let K = max(1, min(count, frames.count))
        let picks = (0..<K).map { frames[$0 * (frames.count - 1) / max(K - 1, 1)] }
        var outY = [Float](repeating: 0, count: n), outCr = [Float](repeating: 0, count: n)
        let tile = 8192
        // The tiles are independent — each one reads the same K planes and writes its own slice of the output —
        // so they are spread over the cores. Same arithmetic, same result, in a fraction of the wall time.
        let tiles = (n + tile - 1) / tile
        let workers = BallDetector.serialPasses ? 1 : max(1, min(tiles, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        func fill(chroma: Bool, into out: inout [Float]) {
            out.withUnsafeMutableBufferPointer { op in
                let opBase = op.baseAddress!
                let run: (Int) -> Void = { worker in
                    var gather = [UInt8](repeating: 0, count: K * tile)
                    var work = [UInt8](repeating: 0, count: K)
                    gather.withUnsafeMutableBufferPointer { gp in
                    work.withUnsafeMutableBufferPointer { wp in
                        var t = worker
                        while t < tiles {
                            let base = t * tile
                            t += workers
                            let m = min(tile, n - base)
                            for k in 0..<K {
                                let plane = chroma ? picks[k].cr : picks[k].y
                                plane.data.withUnsafeBufferPointer { src in
                                    memcpy(gp.baseAddress! + k * m, src.baseAddress! + base, m)
                                }
                            }
                            for i in 0..<m {
                                for k in 0..<K { wp[k] = gp[k * m + i] }
                                var a = 1
                                while a < K {
                                    let v = wp[a]
                                    var b = a - 1
                                    while b >= 0, wp[b] > v { wp[b + 1] = wp[b]; b -= 1 }
                                    wp[b + 1] = v
                                    a += 1
                                }
                                opBase[base + i] = Float(wp[K / 2])
                            }
                        }
                    }
                    }
                }
                if workers > 1 { DispatchQueue.concurrentPerform(iterations: workers, execute: run) }
                else { run(0) }
            }
        }
        fill(chroma: false, into: &outY)
        fill(chroma: true, into: &outCr)
        return (outY, outCr)
    }

    /// Decodes [start, end] (file time) once, keeping the planes and — when Core ML is on — the per-frame boxes.
    /// `seed` supplies coarse positions by absolute frame index, used only to aim the Core ML tile.
    public static func decodeWindow(url: URL, start: Double, end: Double, seed: [Int: SIMD2<Double>] = [:], fps: Double,
                                    options: BallDetectorOptions = .init(), timings: StageTimings? = nil) async throws -> WindowFrames {
        var stats = BallDetectorStats()
        // Every Core ML throttle below is a rate in real time, so a 240 fps clip is not charged twice the
        // inference a 120 fps clip is for the same shot.
        let rates = FrameRates(fileFPS: fps, options: options)
        let coreMLGapFrames = rates.frames(options.coreMLGapSeconds)
        let coreMLEveryNthFrame = rates.everyNth(options.coreMLInferenceRateHz)
        let globalSweepEveryNthFrame = rates.everyNth(options.coreMLGlobalSweepRateHz)
        let globalSearchFramesAfterLock = rates.frames(options.coreMLGlobalSearchSecondsAfterLock)
        let staleWidenPerFrames = rates.frames(options.coreMLStaleWidenPerSeconds)
        let motionAgreementPx = options.coreMLMotionAgreementDiameters * options.expectedDiameterPx
        // Only a capture rate above the one the gates were tuned at may have inferences taken away.
        let maySkipOnMotion = options.coreMLSkipWhenMotionAgrees && rates.captureFPS > options.referenceFrameRate + 1
        var useCoreML = options.useCoreML
        if useCoreML {
            // Load (and, the first time, compile) the model before the decode loop so the compile is not charged to
            // the first frame's inference time. A model that will not load is a reason to say so, not to invent numbers.
            do { try await CoreMLBallDetector.prepare() }
            catch {
                useCoreML = false
                stats.coreMLUnavailableReason = "\(error)"
                FileHandle.standardError.write("  BallDetector: Core ML detector unavailable (\(error)); using the classical detector\n".data(using: .utf8)!)
            }
        }
        let reader = VideoReader(url: url)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        // Pass 1: half-resolution Y and Cr planes for every frame (~1 MB per frame at 1080p), and — when the Core ML
        // detector is on — that frame's boxes, taken while the full-resolution buffer is still in hand.
        var frames: [(index: Int, pts: Double, y: Plane8, cr: Plane8)] = []
        var coreMLCands: [[BallCandidate]] = []
        var prevSig: [UInt8] = []
        var duplicates = 0
        // Running causal track used only to aim the tile: the last few accepted Core ML picks, by frame-array index.
        var mlTrack: [(k: Int, u: Double, v: Double)] = []
        var coreMLFailures = 0
        var planeSeconds = 0.0
        var planeScratch = [Float](repeating: 0, count: 4096)
        var motion: MotionProbe? = nil
        var motionSeconds = 0.0
        var motionAimed = 0
        var locked = false
        var lastBoxFrame = 0
        var sweeps = 0
        // The Core ML inference runs on its own thread while the loop decodes, halves and motion-probes the
        // **next** frame. Nothing about the answer changes: the tiles are cut from this frame while its buffer is
        // still in hand, and the boxes are applied — to `mlTrack`, `locked`, `lastBoxFrame` and this frame's
        // candidate slot — before the next frame's region is decided, which is the only thing that reads them.
        // What is saved is the plane extraction and the motion probe, which used to wait for the Neural Engine.
        var pending: (k: Int, tiles: Int, width: Int, height: Int, job: InflightInference)? = nil
        var cropSeconds = 0.0
        var waitSeconds = 0.0
        func applyPendingInference() {
            guard let p = pending else { return }
            pending = nil
            let tWait = StageTimings.now()
            let done = p.job.wait()
            waitSeconds += StageTimings.now() - tWait
            if done.failed { coreMLFailures += 1; return }
            stats.coreMLSeconds += done.seconds
            stats.coreMLFramesRun += 1
            stats.coreMLTiles += p.tiles
            if p.tiles == 1 { stats.coreMLSingleTileFrames += 1; stats.coreMLSingleTileSeconds += done.seconds }
            let candidates = done.boxes.map { b -> BallCandidate in
                let edge = b.v - b.diameterPx / 2 < 2 || b.u - b.diameterPx / 2 < 2
                    || b.u + b.diameterPx / 2 > Double(p.width) - 2 || b.v + b.diameterPx / 2 > Double(p.height) - 2
                return BallCandidate(u: b.u, v: b.v, diameter: b.diameterPx, meanDiff: Double(b.confidence),
                                     circularity: 1, edge: edge, origin: .box)
            }
            if p.k < coreMLCands.count { coreMLCands[p.k] = candidates }
            // Update the aiming track: the box nearest the prediction when there is one, else the strongest.
            if let pick = coreMLPick(candidates, prediction: coreMLPrediction(track: mlTrack, at: p.k, gapFrames: coreMLGapFrames)) {
                mlTrack.append((p.k, pick.u, pick.v))
                if mlTrack.count > 10 { mlTrack.removeFirst() }
                locked = true; lastBoxFrame = p.k
            }
        }
        let loopStart = StageTimings.now()
        try await reader.forEachPixelBuffer(timeRange: range) { index, pts, pb in
            if index % 32 == 0 { try Task.checkCancellation() }
            let tPlane = StageTimings.now()
            let y = halfLuma(pb, scratch: &planeScratch)
            // The decoder (and the capture) sometimes hands out the same image twice: an identical frame is not new
            // evidence and would put a stale position at a new timestamp. Skip it, as the Python tracker does.
            let sig = signature(y)
            if sig == prevSig { duplicates += 1; planeSeconds += StageTimings.now() - tPlane; return true }
            prevSig = sig
            let frameIndex = Int((pts * fps).rounded())
            frames.append((frameIndex, pts, y, halfCr(pb, scratch: &planeScratch)))        // absolute frame number, same key as the seed
            planeSeconds += StageTimings.now() - tPlane
            guard useCoreML else { return true }
            let k = frames.count - 1
            coreMLCands.append([])          // this frame's slot; filled in when its inference comes back
            let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
            // The background difference that aims the tile has to see every frame to keep its background, so it runs
            // first — but its answer is only used when nothing better predicts the ball.
            var aim: SIMD2<Double>? = nil
            if options.coreMLAimFromMotion {
                if motion == nil { motion = MotionProbe(width: width, height: height, ballDiameterPx: options.expectedDiameterPx) }
                let tm = StageTimings.now()
                aim = motion?.best(in: pb)
                motionSeconds += StageTimings.now() - tm
            }
            // The previous frame's boxes, which the region below is the only thing that depends on.
            applyPendingInference()
            var (roi, tiles) = coreMLRegion(track: mlTrack, at: k, seed: seed[frameIndex], width: width, height: height,
                                            gapFrames: coreMLGapFrames, motionAim: aim,
                                            widenCap: options.coreMLStaleWidenCap,
                                            widenPerFrames: staleWidenPerFrames)
            // The box is only ever asked *which* moving blob is the ball — the hybrid placement takes the blob's
            // own centroid. When the ball is locked on and the cheap motion probe puts a single moving blob right
            // where the running track predicts, that question has already been answered for free.
            if roi != nil, locked, maySkipOnMotion,
               let a = aim, let pred = coreMLPrediction(track: mlTrack, at: k, gapFrames: coreMLGapFrames),
               hypot(a.x - pred.x, a.y - pred.y) <= motionAgreementPx {
                stats.coreMLMotionSkippedFrames += 1
                mlTrack.append((k, a.x, a.y))
                if mlTrack.count > 10 { mlTrack.removeFirst() }
                lastBoxFrame = k
                return true
            }
            if roi != nil, k % coreMLEveryNthFrame != 0 {
                // A tracked frame the model does not have to see: the blobs are found on every frame anyway and the
                // linker predicts across the gap, so the only thing lost is one frame of hybrid placement.
                return true
            }
            if roi == nil {
                // Nothing predicts the ball. The whole-frame sweep is 15 tiles at 1080p, so it is throttled — and once
                // the ball has been locked on, stopped altogether after `coreMLGlobalSearchFramesAfterLock` frames with
                // no box, because by then the flight is over.
                let every = globalSweepEveryNthFrame
                if locked, k - lastBoxFrame > globalSearchFramesAfterLock { return true }
                if sweeps >= options.coreMLMaxGlobalSweeps { return true }
                if k % every != 0 { return true }
                if options.coreMLSweepOnlyWhenMoving, options.coreMLAimFromMotion, aim == nil {
                    // Nothing ball-sized is moving anywhere in the frame, so 15 tiles have nothing to find.
                    stats.coreMLStillFrameSweepsSkipped += 1
                    return true
                }
                sweeps += 1
                // The motion probe may aim this sweep **only once the ball has been locked on at least once**.
                // Measured on 2026-09-14: before the ball has ever been seen it happily aims at the ball still in the
                // shooter's hands, the model returns a box there, the backward extension believes it, and the 313 s
                // free throw's release moves from −2.5 to −15.5 file frames. After the lock the ball is in free
                // flight and the biggest ball-like moving blob is the ball, so one tile replaces fifteen.
                if locked, options.coreMLAimFromMotion, let a = aim {
                    (roi, tiles) = coreMLRegion(track: [], at: k, seed: a, width: width, height: height,
                                                gapFrames: coreMLGapFrames,
                                                widenCap: options.coreMLStaleWidenCap,
                                                widenPerFrames: staleWidenPerFrames)
                    motionAimed += 1
                    stats.coreMLAimedFrames += 1
                } else {
                    stats.coreMLGlobalFrames += 1
                }
            } else {
                stats.coreMLAimedFrames += 1
            }
            // Cut the tiles here — the provider's pixel buffer may not outlive this closure — and let the model
            // run on them elsewhere. `applyPendingInference` above is what waits for the answer, one frame later.
            let tCrop = StageTimings.now()
            let cut: [CoreMLBallDetector.Tile]
            do { cut = try CoreMLBallDetector.cutTiles(pixelBuffer: pb, roi: roi) }
            catch { coreMLFailures += 1; return true }
            cropSeconds += StageTimings.now() - tCrop
            let job = InflightInference()
            job.start(tiles: cut, minConfidence: options.coreMLMinConfidence)
            pending = (k: k, tiles: tiles, width: width, height: height, job: job)
            // `ARCLAB_SERIAL_PASSES=1` waits for the model here instead of on the next frame: the same answer,
            // the pre-2026-09-16 wall time, so the overlap can be measured in one binary.
            if BallDetector.serialPasses { applyPendingInference() }
            return true
        }
        applyPendingInference()         // the last frame's boxes
        if duplicates > 0 { FileHandle.standardError.write("  BallDetector: skipped \(duplicates) duplicated frame(s) from the decoder\n".data(using: .utf8)!) }
        if coreMLFailures > 0 { FileHandle.standardError.write("  BallDetector: Core ML detector failed on \(coreMLFailures) frame(s)\n".data(using: .utf8)!) }
        let loopSeconds = StageTimings.now() - loopStart
        // The inference now overlaps the next frame's work, so `coreml` is the model's own seconds and no longer
        // a share of the loop's wall time; `coreml.crop` is what the loop itself still spends cutting tiles.
        timings?.add("decode", max(0, loopSeconds - planeSeconds - cropSeconds - motionSeconds - waitSeconds), count: frames.count)
        if cropSeconds > 0 { timings?.add("coreml.crop", cropSeconds, count: stats.coreMLTiles) }
        // What the loop still had to wait for after the frame's own work was done: the part of the model's
        // seconds the overlap could not hide. `coreml` is the model's whole cost; `coreml.wait` is what it cost
        // the loop. The difference between them is what the overlap bought.
        if waitSeconds > 0 { timings?.add("coreml.wait", waitSeconds, count: stats.coreMLFramesRun) }
        timings?.add("planes", max(0, planeSeconds), count: frames.count)
        if motionSeconds > 0 { timings?.add("motion", motionSeconds, count: motionAimed) }
        if stats.coreMLSeconds > 0 { timings?.add("coreml", stats.coreMLSeconds, count: stats.coreMLTiles) }
        var fullW = 0, fullH = 0
        if let f = frames.first { fullW = 2 * f.y.width; fullH = 2 * f.y.height }
        return WindowFrames(frames: frames, coreMLCands: coreMLCands, coreMLAvailable: useCoreML,
                            decodeStats: stats, fps: fps, width: fullW, height: fullH)
    }

    /// Track the ball through an already-decoded window. Pure CPU: it never touches the file, so a caller can try
    /// two or three parameter sets on it for the price of one decode.
    public static func track(window: WindowFrames, seed: [Int: SIMD2<Double>] = [:],
                             options: BallDetectorOptions = .init(), bodyBoxes: [Int: CGRect] = [:],
                             timings: StageTimings? = nil) -> (detections: [BallDetection], stats: BallDetectorStats) {
        let frames = window.frames
        var stats = window.decodeStats
        // Everything the linker gates on is a real speed or a real duration; these are those gates in file frames
        // for *this* clip's capture rate. Tuned on 120 fps footage, so on a 240 fps clip every allowance halves
        // and every wait doubles, which is what keeps the same track coming out of both.
        let rates = FrameRates(fileFPS: window.fps, options: options)
        let maxGapFrames = rates.frames(options.maxGapSeconds)
        let maxOffframeFrames = rates.frames(options.maxOffframeSeconds)
        let extendBackFrames = rates.frames(options.extendBackSeconds)
        let historyFrames = rates.frames(options.historySeconds)
        let minimumHistoryFrames = rates.frames(options.minimumHistorySeconds)
        let bodyExclusionDelayFrames = rates.frames(options.bodyExclusionDelaySeconds)
        let gateFloorDiameters = rates.perFrame(options.maxLinkDiametersPerSecond)
        let extendBackGateDiameters = rates.perFrame(options.extendBackDiametersPerSecond)
        let gateGrowthPerFrame = rates.perFrame(options.gateGrowthPerSecond)
        let maxSeedsTried = rates.scaledCount(options.maxSeedsTried, reference: options.referenceFrameRate)
        let useCoreML = window.coreMLAvailable && options.useCoreML
        let coreMLCands = useCoreML ? window.coreMLCands : []
        guard frames.count >= 3 else { return ([], stats) }
        let W = frames[0].y.width, H = frames[0].y.height          // half-res
        let fullW = 2 * W, fullH = 2 * H
        // Background: the per-pixel median the window already carries (built once, whatever the attempt).
        let tBg = StageTimings.now()
        let (bgY, bgCr) = window.background(count: options.backgroundFrames)
        timings?.add("background", since: tBg)
        let finder = CandidateFinder(options: options, width: W, height: H, bgY: bgY, bgCr: bgCr)
        // One finder per worker: `CandidateFinder` keeps vDSP scratch, so it is not re-entrant, but the work it
        // does on a frame depends only on that frame, the background and the options. Extra finders are made
        // only when there is more than one frame's worth of work to spread.
        let candidateWorkers = serialPasses ? 1 : max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))

        var D = options.expectedDiameterPx
        if useCoreML, options.refineDiameterFromSeeds {
            // The model returns the ball's box, so its diameters are a direct measurement — no threshold, no dark-side
            // under-read. Take the median of the strongest box per frame over the frames that have one.
            let sizes = coreMLCands.compactMap { $0.max(by: { $0.meanDiff < $1.meanDiff })?.diameter }.sorted()
            if sizes.count >= 10 {
                let med = sizes[sizes.count / 2]
                if abs(med / D - 1) > 0.15 { D = med }
            }
        }
        let tCand = StageTimings.now()
        var cands: [[BallCandidate]]
        if candidateWorkers > 1, frames.count >= 2 * candidateWorkers {
            let box = CandidateSlots(count: frames.count)
            let extra = (1..<candidateWorkers).map { _ in CandidateFinder(options: options, width: W, height: H, bgY: bgY, bgCr: bgCr) }
            DispatchQueue.concurrentPerform(iterations: candidateWorkers) { worker in
                let f = worker == 0 ? finder : extra[worker - 1]
                var k = worker
                while k < frames.count {
                    box.set(k, f.candidates(y: frames[k].y.data, cr: frames[k].cr.data, expectedDiameterFull: D))
                    k += candidateWorkers
                }
            }
            cands = box.take()
        } else {
            cands = frames.map { finder.candidates(y: $0.y.data, cr: $0.cr.data, expectedDiameterFull: D) }
        }
        timings?.add("candidates", since: tCand, count: frames.count)
        if !useCoreML, options.refineDiameterFromSeeds {
            // The seeds sit on the ball: candidates coinciding with them measure its true size.
            var sizes: [Double] = []
            for (k, f) in frames.enumerated() {
                guard let s = seed[f.index] else { continue }
                for c in cands[k] where hypot(c.u - s.x, c.v - s.y) < 1.5 * D { sizes.append(c.diameter) }
            }
            if sizes.count >= 10 {
                let med = sizes.sorted()[sizes.count / 2]
                if abs(med / D - 1) > 0.15 {
                    D = med
                    cands = frames.map { finder.candidates(y: $0.y.data, cr: $0.cr.data, expectedDiameterFull: D) }
                }
            }
        }
        // A second, looser, look at the same frame: 0.6x the difference threshold, half the minimum area, circularity
        // 0.3, 3 less orange margin — `tools/pytrack/track.py`'s `relaxed` finder. Computed lazily, and only for the
        // frames that need it: a box with no strict blob inside, or the dark descent.
        var relaxedOptions = options
        relaxedOptions.diffThreshold = 0.6 * options.diffThreshold
        relaxedOptions.minAreaFraction = 0.5 * options.minAreaFraction
        relaxedOptions.circularityMin = min(options.circularityMin, 0.3)
        relaxedOptions.orangeMargin = max(2, options.orangeMargin - 3)
        let relaxedFinder = CandidateFinder(options: relaxedOptions, width: W, height: H, bgY: bgY, bgCr: bgCr)
        var relaxedCache: [Int: [BallCandidate]] = [:]
        func relaxed(_ k: Int, _ diameter: Double) -> [BallCandidate] {
            if let r = relaxedCache[k] { return r }
            let r = relaxedFinder.candidates(y: frames[k].y.data, cr: frames[k].cr.data, expectedDiameterFull: diameter)
            relaxedCache[k] = r
            return r
        }

        if useCoreML, options.coreMLHybridCentroid {
            // Hybrid: the box says *which* blob is the ball, the blob says *where* it is. A box with no moving orange
            // blob inside it keeps its own centre only while it is still ball-sized; one that has swallowed the rim and
            // the net is dropped, because its centre is the rim's, not the ball's.
            func refine(box: BallCandidate, k: Int, diameter D: Double, used: inout Set<Int>) -> BallCandidate? {
                let half = max(box.diameter, 0.8 * D) / 2 + 0.25 * D
                func pick(_ list: [BallCandidate]) -> (index: Int, c: BallCandidate)? {
                    var best: (Int, BallCandidate, Double)? = nil
                    for (i, c) in list.enumerated() {
                        guard abs(c.u - box.u) <= half, abs(c.v - box.v) <= half else { continue }
                        guard c.diameter >= 0.45 * D, c.diameter <= 1.7 * D else { continue }
                        let sc = hypot(c.u - box.u, c.v - box.v) / D + 0.8 * abs(log(c.diameter / D))
                        if best == nil || sc < best!.2 { best = (i, c, sc) }
                    }
                    return best.map { (index: $0.0, c: $0.1) }
                }
                if let hit = pick(cands[k]) {
                    used.insert(hit.index)
                    var c = hit.c; c.origin = .refined; return c
                }
                if let hit = pick(relaxed(k, D)) { var c = hit.c; c.origin = .refined; return c }
                // No moving orange blob inside the box. A box still the size of the ball is believed (its centre is
                // ~10 px noisier, which is better than nothing); one that has swallowed the rim and the net is not.
                if box.diameter > options.coreMLMaxBoxDiameterFactor * D { stats.suppressedInflatedBoxes += 1; return nil }
                return box
            }
            func hybrid(_ k: Int, diameter D: Double) -> [BallCandidate] {
                guard k < coreMLCands.count, !coreMLCands[k].isEmpty else { return cands[k] }
                var used = Set<Int>()
                var out: [BallCandidate] = []
                for b in coreMLCands[k].sorted(by: { $0.meanDiff > $1.meanDiff }) {
                    if let c = refine(box: b, k: k, diameter: D, used: &used) { out.append(c) }
                }
                if options.keepUnmatchedBlobs {
                    for (i, c) in cands[k].enumerated() where !used.contains(i) && c.diameter >= 0.5 * D && c.diameter <= 1.6 * D {
                        out.append(c)
                    }
                }
                return out
            }
            var merged = (0..<frames.count).map { hybrid($0, diameter: D) }
            if options.refineDiameterFromSeeds {
                // The boxes read large (they inflate near the rim); the blobs they selected are a direct measurement
                // of the ball, so re-derive the expected size from those and, if it moved, find the blobs again.
                let sizes = merged.flatMap { $0.filter { $0.origin == .refined }.map(\.diameter) }.sorted()
                if sizes.count >= 15 {
                    let med = sizes[sizes.count / 2]
                    if abs(med / D - 1) > 0.15 {
                        D = med
                        cands = frames.map { finder.candidates(y: $0.y.data, cr: $0.cr.data, expectedDiameterFull: D) }
                        relaxedCache.removeAll()
                        stats.suppressedInflatedBoxes = 0
                        merged = (0..<frames.count).map { hybrid($0, diameter: D) }
                    }
                }
            }
            for k in 0..<frames.count {
                if k < coreMLCands.count, !coreMLCands[k].isEmpty { stats.coreMLFrames += 1 }
                else if !cands[k].isEmpty { stats.classicalFallbackFrames += 1 }
            }
            cands = merged
        } else if useCoreML {
            // Core ML is the per-frame detector; the background-difference blobs stay as the fallback on frames where
            // it returns nothing. Everything downstream — linker, re-entry, backward extension, template fill — is
            // unchanged and cannot tell which stage produced a candidate.
            for k in 0..<frames.count where k < coreMLCands.count {
                if !coreMLCands[k].isEmpty {
                    cands[k] = coreMLCands[k]
                    stats.coreMLFrames += 1
                } else if !cands[k].isEmpty {
                    stats.classicalFallbackFrames += 1
                }
            }
        }
        let tLink = StageTimings.now()
        let templateBefore = timings?.seconds("template") ?? 0
        defer { timings?.add("link", max(0, StageTimings.now() - tLink - ((timings?.seconds("template") ?? 0) - templateBefore))) }
        let boxes: [CGRect?] = frames.map { bodyBoxes[$0.index] }
        func inBox(_ c: BallCandidate, _ k: Int) -> Bool { boxes[k].map { $0.contains(CGPoint(x: c.u, y: c.v)) } ?? false }

        // Forward linking from one seed candidate. Returns frame-array index → candidate.
        func linkForward(from i0: Int, _ c0: BallCandidate) -> [Int: BallCandidate] {
            var track: [Int: BallCandidate] = [i0: c0]
            var hist: [(i: Int, u: Double, v: Double)] = [(i0, c0.u, c0.v)]
            var lost = 0, lastI = i0, exitedTop = false
            var i = i0 + 1
            while i < frames.count {
                let pred: SIMD2<Double>
                if hist.count >= minimumHistoryFrames {
                    let h = hist.suffix(historyFrames)
                    let ii = h.map { Double($0.i - i0) }
                    let pu = polyfit(ii, h.map(\.u), degree: 1), pv = polyfit(ii, h.map(\.v), degree: 2)
                    let x = Double(i - i0)
                    pred = SIMD2(polyval(pu, x), polyval(pv, x))
                } else if hist.count >= 2 {
                    let a = hist[hist.count - 2], b = hist[hist.count - 1]
                    let k = Double(i - b.i) / Double(max(1, b.i - a.i))
                    pred = SIMD2(b.u + (b.u - a.u) * k, b.v + (b.v - a.v) * k)
                } else { pred = SIMD2(hist[0].u, hist[0].v) }
                let offframe = exitedTop || pred.y < -0.5 * D || pred.x < -D || pred.x > Double(fullW) + D
                let step = hist.count >= 2 ? hypot(hist[hist.count - 1].u - hist[hist.count - 2].u, hist[hist.count - 1].v - hist[hist.count - 2].v) : D
                let gate = max(gateFloorDiameters * D, options.gateSpeedFactor * step)
                    * (1 + gateGrowthPerFrame * Double(i - lastI - 1))
                // direction of travel for the re-entry test (the Python tracker assumed left→right)
                let dir: Double = hist.count >= 2 ? (hist[hist.count - 1].u - hist[0].u >= 0 ? 1 : -1) : 1
                var best: (score: Double, c: BallCandidate)? = nil
                for c in cands[i] {
                    if i - i0 > bodyExclusionDelayFrames, inBox(c, i) { continue }   // ignore body blobs once the ball has left
                    let sc: Double
                    if offframe {
                        // re-entry: any ball-sized blob in the top band, ahead of the exit point
                        if c.v > 0.35 * Double(fullH) || dir * (c.u - hist[hist.count - 1].u) < -D { continue }
                        sc = abs(log(c.diameter / D)) + c.v / Double(fullH)
                    } else {
                        let dist = hypot(c.u - pred.x, c.v - pred.y)
                        if dist > gate { continue }
                        sc = dist / D + 0.8 * abs(log(c.diameter / D))
                    }
                    if best == nil || sc < best!.score { best = (sc, c) }
                }
                if best == nil, !offframe, let sd = seed[frames[i].index] {
                    // the linker's own prediction failed but the caller has a coarse position on this frame: re-acquire there
                    for c in cands[i] where !(i - i0 > bodyExclusionDelayFrames && inBox(c, i)) {
                        let dist = hypot(c.u - sd.x, c.v - sd.y)
                        guard dist <= 1.5 * D else { continue }
                        let sc = dist / D + 0.8 * abs(log(c.diameter / D))
                        if best == nil || sc < best!.score { best = (sc, c) }
                    }
                }
                if best == nil, options.predictedWeakCandidates, !offframe, hist.count >= historyFrames,
                   lost < maxGapFrames + rates.frames(options.maxGapSeconds) {
                    // The descent: the ball is small, dark and moving fast, and the strict mask loses it. With a
                    // parabola this well established, a weaker blob within 0.8 D of the prediction is image evidence,
                    // not an extrapolation — the position still comes from pixels. (pytrack `predicted_weak_candidates`.)
                    for c in relaxed(i, D) {
                        if i - i0 > bodyExclusionDelayFrames, inBox(c, i) { continue }
                        let dist = hypot(c.u - pred.x, c.v - pred.y)
                        guard dist <= 0.8 * D, c.diameter >= 0.4 * D, c.diameter <= 1.6 * D else { continue }
                        let sc = dist / D + 0.5 * abs(log(c.diameter / D))
                        var w = c; w.origin = .weak
                        if best == nil || sc < best!.score { best = (sc, w) }
                    }
                }
                if let b = best {
                    track[i] = b.c; hist.append((i, b.c.u, b.c.v)); lost = 0; lastI = i; exitedTop = false
                } else {
                    lost += 1
                    // the ball left through the top edge: keep the track alive and search for re-entry in the top band
                    if !exitedTop, hist[hist.count - 1].v < 1.5 * D, lost >= rates.frames(2.0 / 120) { exitedTop = true }
                    if !offframe, lost > maxGapFrames { break }
                    if offframe, i - lastI > maxOffframeFrames { break }
                    if !offframe, pred.y > Double(fullH) + 2 * D { break }        // below the floor: gone
                }
                i += 1
            }
            return track
        }

        // Seeds: candidates coinciding with the caller's positions, earliest first; keep the longest track.
        var bestTrack: [Int: BallCandidate] = [:]
        var tried = 0
        outer: for (k, f) in frames.enumerated() {
            guard let s = seed[f.index] else { continue }
            for c in cands[k] where hypot(c.u - s.x, c.v - s.y) < 2.0 * D {
                tried += 1
                if tried > maxSeedsTried { break outer }
                let tr = linkForward(from: k, c)
                if tr.count > bestTrack.count { bestTrack = tr }
            }
        }
        // Fallback: no candidate under any seed — start from the candidate nearest a seed within 4 D.
        if bestTrack.isEmpty {
            var fallback: (dist: Double, k: Int, c: BallCandidate)? = nil
            for (k, f) in frames.enumerated() {
                guard let s = seed[f.index] else { continue }
                for c in cands[k] {
                    let d = hypot(c.u - s.x, c.v - s.y)
                    if d < 4 * D, fallback == nil || d < fallback!.dist { fallback = (d, k, c) }
                }
            }
            if let fb = fallback { bestTrack = linkForward(from: fb.k, fb.c) }
        }
        guard !bestTrack.isEmpty else { return ([], stats) }

        // Backward extension into the hands: nearest candidate within 1 D, stop when the blob is no longer ball-sized.
        let i0 = bestTrack.keys.min()!
        var prev = bestTrack[i0]!
        var i = i0 - 1, extended = 0
        while i >= 0, extended < extendBackFrames {
            let backGate = extendBackGateDiameters * D
            var cb: (dist: Double, c: BallCandidate)? = nil
            // Only image blobs may extend the track backwards. This is the shooter's hands: a Core ML box here
            // swallows ball and hand together and its centre is not the ball's, which moves the pose release rule.
            for c in cands[i] where c.origin != .box {
                let d = hypot(c.u - prev.u, c.v - prev.v)
                if d <= backGate, cb == nil || d < cb!.dist { cb = (d, c) }
            }
            if cb == nil, let c = finder.localBlob(y: frames[i].y.data, cr: frames[i].cr.data, near: SIMD2(prev.u, prev.v), expectedDiameterFull: D) {
                // the strict whole-frame candidate failed (ball merging with the hands): a local blob with an adaptive threshold
                let d = hypot(c.u - prev.u, c.v - prev.v)
                if d <= backGate { cb = (d, c) }
            }
            guard let cb, cb.c.diameter <= 1.7 * D else { break }
            bestTrack[i] = cb.c; prev = cb.c; extended += 1; i -= 1
        }

        if options.trimAfterFreeFlight, bestTrack.count >= rates.frames(options.bounceMinimumTrackSeconds) + 8,
           let cut = freeFlightEnd(bestTrack, frames: frames, D: D, options: options, rates: rates) {
            for k in bestTrack.keys where k >= cut { bestTrack[k] = nil }
        }
        if options.trimAfterBounce, bestTrack.count >= rates.frames(options.bounceMinimumTrackSeconds) {
            // In free flight the image v rises to the apex and then only falls. The first frame that climbs back up
            // by more than `bounceRiseDiameters` of a ball, well past the apex, is where the flight ended.
            let keys = bestTrack.keys.sorted()
            let apexAt = keys.min { bestTrack[$0]!.v < bestTrack[$1]!.v }!
            let apexV = bestTrack[apexAt]!.v
            var lowest = apexV
            var cut: Int? = nil
            for k in keys where k > apexAt {
                let v = bestTrack[k]!.v
                if v > lowest { lowest = v; continue }
                if k - apexAt >= rates.frames(options.bouncePastApexSeconds), lowest - apexV >= 1.5 * D,
                   v < lowest - options.bounceRiseDiameters * D { cut = k; break }
            }
            if let cut { for k in keys where k >= cut { bestTrack[k] = nil } }
        }
        for c in bestTrack.values {
            switch c.origin {
            case .refined: stats.hybridRefinedFrames += 1
            case .box: stats.hybridBoxOnlyFrames += 1
            case .weak: stats.weakDescentFrames += 1
            case .blob: stats.blobOnlyFrames += 1
            }
        }
        var out: [BallDetection] = bestTrack.keys.sorted().map { k in
            let c = bestTrack[k]!
            return BallDetection(frameIndex: frames[k].index, pts: frames[k].pts, u: c.u, v: c.v, diameterPx: c.diameter,
                                 score: c.meanDiff, predicted: false, source: "detected", edge: c.edge)
        }
        if options.templateFill {
            let tTpl = StageTimings.now()
            let filled = templateFill(out, frames: frames, D: D, options: options, rates: rates)
            timings?.add("template", since: tTpl)
            if !filled.isEmpty { out = (out + filled).sorted { $0.frameIndex < $1.frameIndex } }
        }
        return (out, stats)
    }


    // MARK: - Aiming the Core ML tile

    /// Where the ball is expected on frame-array index `k`, from the running Core ML track: constant velocity from the
    /// last two picks, or the last pick itself. `nil` when the track is empty or too stale to trust.
    static func coreMLPrediction(track: [(k: Int, u: Double, v: Double)], at k: Int, gapFrames: Int) -> SIMD2<Double>? {
        guard let last = track.last, k - last.k <= max(1, gapFrames) else { return nil }
        guard track.count >= 2 else { return SIMD2(last.u, last.v) }
        let previous = track[track.count - 2]
        let span = Double(max(1, last.k - previous.k))
        let step = Double(k - last.k) / span
        return SIMD2(last.u + (last.u - previous.u) * step, last.v + (last.v - previous.v) * step)
    }

    /// The region of the frame to hand the model, and how many tiles that costs. A prediction (or, failing that, the
    /// caller's coarse seed) buys a single 512-px tile; with nothing to go on the whole frame is searched.
    static func coreMLRegion(track: [(k: Int, u: Double, v: Double)], at k: Int, seed: SIMD2<Double>?,
                             width: Int, height: Int, gapFrames: Int,
                             motionAim: SIMD2<Double>? = nil,
                             widenCap: Int = 2, widenPerFrames: Int = 3) -> (roi: CGRect?, tiles: Int) {
        let tile = Double(CoreMLBallDetector.tilePixels)
        var centre = coreMLPrediction(track: track, at: k, gapFrames: gapFrames)
        var stale = 0
        if let last = track.last, centre != nil { stale = k - last.k }
        // A stale prediction used to be handled by widening the search, which costs up to nine tiles. The cheap
        // motion probe answers the same question — "where did it go?" — for a fraction of a millisecond, so when it
        // has a ball-like blob near the prediction, one tile there replaces the widened search.
        if stale >= 2, let m = motionAim, let c0 = centre,
           hypot(m.x - c0.x, m.y - c0.y) <= 2 * tile {
            centre = m; stale = 0
        }

        if centre == nil, let s = seed { centre = s }
        guard let c = centre else {
            let across = CoreMLBallDetector.origins(from: 0, to: width, span: min(Int(tile), min(width, height)), limit: width).count
            let down = CoreMLBallDetector.origins(from: 0, to: height, span: min(Int(tile), min(width, height)), limit: height).count
            return (nil, across * down)
        }
        // Frames missed since the last box widen the search: one extra tile per `widenPerFrames` missed frames,
        // capped at `widenCap`. This is where most of a window's inference used to go — a widened region is up to
        // nine tiles instead of one — so the cap is a measured number, not a guess.
        let extra = min(widenCap, stale / max(1, widenPerFrames)) * CoreMLBallDetector.tileStride
        let side = Int(tile) + 2 * extra
        // Snap to whole pixels: a region 513 px wide costs four tiles instead of one, for nothing.
        let x0 = (c.x - Double(side) / 2).rounded(), y0 = (c.y - Double(side) / 2).rounded()
        let roi = CGRect(x: x0, y: y0, width: Double(side), height: Double(side))
        let span = min(Int(tile), min(width, height))
        let across = CoreMLBallDetector.origins(from: Int(x0), to: Int(x0) + side, span: span, limit: width).count
        let down = CoreMLBallDetector.origins(from: Int(y0), to: Int(y0) + side, span: span, limit: height).count
        return (roi, across * down)
    }

    /// The box to carry the aiming track forward: nearest the prediction when there is one (within two tiles), else the
    /// most confident. This only steers the next tile — the linker does its own, stricter, gating.
    static func coreMLPick(_ candidates: [BallCandidate], prediction: SIMD2<Double>?) -> BallCandidate? {
        guard !candidates.isEmpty else { return nil }
        if let p = prediction {
            let near = candidates.filter { hypot($0.u - p.x, $0.v - p.y) <= Double(CoreMLBallDetector.tilePixels) }
            if let best = near.min(by: { hypot($0.u - p.x, $0.v - p.y) < hypot($1.u - p.x, $1.v - p.y) }) { return best }
        }
        return candidates.max(by: { $0.meanDiff < $1.meanDiff })
    }


    // MARK: - Where free flight ends

    /// The first frame-array index at which the track stops being one ballistic flight, or nil when it never does.
    ///
    /// The span around the apex is free flight by construction — the ball is at the top of its arc, far from the
    /// hands, the ring and the floor — so the projected parabola fitted there is the flight's own model. Walking
    /// forward from it, the first sample that leaves the model by more than `freeFlightResidualDiameters` of a
    /// ball and stays out for `freeFlightBreakSeconds` is where the net, the ring or the floor took over. The model
    /// is refitted as samples are accepted, so it never has to extrapolate far.
    ///
    /// Edge-clipped samples have an inward-biased centroid and are never allowed to *start* a break; they are cut
    /// only when they fall after one.
    static func freeFlightEnd(_ track: [Int: BallCandidate], frames: [(index: Int, pts: Double, y: Plane8, cr: Plane8)],
                              D: Double, options: BallDetectorOptions, rates: FrameRates) -> Int? {
        let keys = track.keys.sorted()
        // The **first** apex, not the lowest v in the track: a ball that bounces off the ring can climb back to
        // the height it came from, and the global minimum then lands inside the bounce, which is the one place the
        // seed must not be. Walk forward and take the running minimum at the moment the ball has clearly turned.
        var minV = Double.greatestFiniteMagnitude, minAt = keys[0]
        var firstApex: Int? = nil
        for k in keys {
            let v = track[k]!.v
            if v < minV { minV = v; minAt = k }
            else if v > minV + 0.5 * D { firstApex = minAt; break }
        }
        guard let apexAt = firstApex ?? keys.min(by: { track[$0]!.v < track[$1]!.v }) else { return nil }
        let before = rates.frames(options.freeFlightSeedBeforeApexSeconds)
        let after = rates.frames(options.freeFlightSeedAfterApexSeconds)
        var seed = keys.filter { $0 >= apexAt - before && $0 <= apexAt + after && !track[$0]!.edge }
        if seed.count < 8 { seed = keys.filter { $0 >= apexAt - 2 * before && $0 <= apexAt + after && !track[$0]!.edge } }
        guard seed.count >= 8, let last = seed.last else { return nil }
        func fit(_ idx: [Int]) -> ProjectedParabola? {
            ProjectedParabola.fit(t: idx.map { frames[$0].pts }, u: idx.map { track[$0]!.u }, v: idx.map { track[$0]!.v })
        }
        guard var model = fit(seed) else { return nil }
        let tolerance = options.freeFlightResidualDiameters * D
        let breakFrames = rates.frames(options.freeFlightBreakSeconds)
        let refitEvery = rates.frames(0.05)
        var accepted = seed
        var sinceRefit = 0
        var runStart: Int? = nil
        var run = 0
        // The ball has to be well down the descent before a break can mean the flight is over.
        let apexV = track[apexAt]!.v
        let dropped = options.freeFlightMinimumDropDiameters * D
        for k in keys where k > last {
            let c = track[k]!
            let (pu, pv) = model.predict(frames[k].pts)
            let residual = hypot(c.u - pu, c.v - pv)
            if residual > tolerance, c.v > apexV + dropped {
                if c.edge, runStart == nil { continue }        // a clipped blob's bias is not evidence of a break
                if runStart == nil { runStart = k }
                run += 1
                if run >= breakFrames { return runStart }
            } else {
                runStart = nil; run = 0
                accepted.append(k)
                sinceRefit += 1
                if sinceRefit >= refitEvery, let m = fit(accepted) { model = m; sinceRefit = 0 }
            }
        }
        return nil
    }

    // MARK: - Template fill

    /// Fill missing flight frames near the release (and short gaps elsewhere) with NCC template matches confirmed near
    /// the projected-parabola prediction. Labelled "template". Never invents a position: no match → no detection.
    static func templateFill(_ out: [BallDetection], frames: [(index: Int, pts: Double, y: Plane8, cr: Plane8)], D: Double,
                             options: BallDetectorOptions, rates: FrameRates) -> [BallDetection] {
        let det = out.filter { $0.source == "detected" && !$0.edge }
        guard det.count >= 8 else { return [] }
        guard let model = ProjectedParabola.fit(t: det.map(\.pts), u: det.map(\.u), v: det.map(\.v)) else { return [] }
        let W = frames[0].y.width, H = frames[0].y.height
        let have = Set(out.map(\.frameIndex))
        let detIdx = det.map(\.frameIndex)
        let i0 = detIdx[0], iLast = detIdx[detIdx.count - 1]
        let rH = max(4, Int(D / 4))                           // template half-size at half-res (= D/2 full-res)
        var filled: [BallDetection] = []
        let reach = rates.frames(options.templateReachSeconds)
        let neighbour = rates.frames(options.templateNeighbourSeconds)
        for f in frames where f.index >= i0 - reach && f.index <= iLast && !have.contains(f.index) {
            if f.index > i0 + reach, !detIdx.contains(where: { abs($0 - f.index) <= neighbour }) { continue }
            let (pu, pv) = model.predict(f.pts)
            guard pu >= 0, pv >= 0, pu < Double(2 * W), pv < Double(2 * H) else { continue }
            // template: the ball crop from the nearest clean detection
            let j = det.min { abs($0.frameIndex - f.index) < abs($1.frameIndex - f.index) }!
            guard let jf = frames.first(where: { $0.index == j.frameIndex }) else { continue }
            let cx = Int(j.u / 2), cy = Int(j.v / 2)
            let tx0 = max(0, cx - rH), ty0 = max(0, cy - rH), tx1 = min(W, cx + rH), ty1 = min(H, cy + rH)
            let tw = tx1 - tx0, th = ty1 - ty0
            guard min(tw, th) >= 8 else { continue }
            let R = Int(1.2 * D / 2)
            let wx0 = max(0, Int(pu / 2) - R), wy0 = max(0, Int(pv / 2) - R), wx1 = min(W, Int(pu / 2) + R), wy1 = min(H, Int(pv / 2) + R)
            guard wx1 - wx0 > tw, wy1 - wy0 > th else { continue }
            guard let m = ncc(image: f.y, window: (wx0, wy0, wx1, wy1), template: jf.y, rect: (tx0, ty0, tw, th)) else { continue }
            guard m.score >= options.templateMinScore else { continue }
            let cu = 2 * (Double(wx0) + m.x + Double(tw) / 2), cv = 2 * (Double(wy0) + m.y + Double(th) / 2)
            guard hypot(cu - pu, cv - pv) <= 1.0 * D else { continue }
            filled.append(BallDetection(frameIndex: f.index, pts: f.pts, u: cu, v: cv, diameterPx: D, score: m.score,
                                        predicted: false, source: "template", edge: false))
        }
        return filled
    }

    /// Zero-mean normalized cross-correlation (OpenCV's TM_CCOEFF_NORMED) of `template` over `window` in `image`.
    /// Returns the peak (top-left offset within the window, sub-pixel via a parabola through the neighbours) and its score.
    static func ncc(image: Plane8, window: (Int, Int, Int, Int), template: Plane8, rect: (Int, Int, Int, Int)) -> (x: Double, y: Double, score: Double)? {
        let (wx0, wy0, wx1, wy1) = window, (tx0, ty0, tw, th) = rect
        let n = Double(tw * th)
        var t = [Double](repeating: 0, count: tw * th)
        var mean = 0.0
        for y in 0..<th { for x in 0..<tw { let v = Double(template.data[(ty0 + y) * template.width + tx0 + x]); t[y * tw + x] = v; mean += v } }
        mean /= n
        var tss = 0.0
        for k in 0..<t.count { t[k] -= mean; tss += t[k] * t[k] }
        guard tss > 1e-9 else { return nil }
        let ow = wx1 - wx0 - tw + 1, oh = wy1 - wy0 - th + 1
        guard ow > 0, oh > 0 else { return nil }
        var map = [Double](repeating: -1, count: ow * oh)
        var patch = [Double](repeating: 0, count: tw * th)
        var best = (-2.0, 0, 0)
        for oy in 0..<oh { for ox in 0..<ow {
            var pm = 0.0
            for y in 0..<th { let row = (wy0 + oy + y) * image.width + wx0 + ox
                for x in 0..<tw { let v = Double(image.data[row + x]); patch[y * tw + x] = v; pm += v } }
            pm /= n
            var num = 0.0, pss = 0.0
            for k in 0..<patch.count { let p = patch[k] - pm; num += p * t[k]; pss += p * p }
            let s = pss > 1e-9 ? num / (tss * pss).squareRoot() : -1
            map[oy * ow + ox] = s
            if s > best.0 { best = (s, ox, oy) }
        } }
        // sub-pixel refinement: parabola through the three values on each axis
        var bx = Double(best.1), by = Double(best.2)
        if best.1 > 0, best.1 < ow - 1 {
            let l = map[best.2 * ow + best.1 - 1], c = best.0, r = map[best.2 * ow + best.1 + 1]
            let den = l - 2 * c + r; if den < 0 { bx += 0.5 * (l - r) / den }
        }
        if best.2 > 0, best.2 < oh - 1 {
            let u = map[(best.2 - 1) * ow + best.1], c = best.0, d = map[(best.2 + 1) * ow + best.1]
            let den = u - 2 * c + d; if den < 0 { by += 0.5 * (u - d) / den }
        }
        return (bx, by, best.0)
    }

    // MARK: - Planes

    /// 48×27 block-mean thumbnail of the half-res luma: equal thumbnails mean the decoder repeated the frame.
    /// A 48×27 thumbnail of the frame, used only to recognise a frame the decoder handed out twice. Every 4th
    /// pixel of each cell is enough for that and costs a sixteenth of the reads: two genuinely identical frames
    /// still produce identical signatures, which is the only property the test needs.
    static func signature(_ p: Plane8) -> [UInt8] {
        let gw = 48, gh = 27, step = 4
        var out = [UInt8](repeating: 0, count: gw * gh)
        let bw = max(1, p.width / gw), bh = max(1, p.height / gh)
        p.data.withUnsafeBufferPointer { src in
            for gy in 0..<gh {
                for gx in 0..<gw {
                    var s = 0, count = 0
                    var y = gy * bh
                    let yEnd = min(p.height, (gy + 1) * bh), xEnd = min(p.width, (gx + 1) * bw)
                    while y < yEnd {
                        var x = gx * bw
                        let row = y * p.width
                        while x < xEnd { s += Int(src[row + x]); count += 1; x += step }
                        y += step
                    }
                    out[gy * gw + gx] = UInt8(s / max(1, count))
                }
            }
        }
        return out
    }

    /// Half-resolution luma: each output pixel is the truncated mean of a 2×2 block, done with vDSP so it costs
    /// the same whatever the optimisation level.
    static func halfLuma(_ pb: CVPixelBuffer, scratch: inout [Float]) -> Plane8 {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let hw = w / 2, hh = h / 2
        var out = [UInt8](repeating: 0, count: hw * hh)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else {
            return Plane8(width: hw, height: hh, data: out)
        }
        RimArrivalScanner.boxRows(base: base, stride: CVPixelBufferGetBytesPerRowOfPlane(pb, 0), rows: h,
                                  block: 2, sampleStride: 1, workWidth: hw, workHeight: hh,
                                  scratch: &scratch, out: &out)
        return Plane8(width: hw, height: hh, data: out)
    }

    /// The Cr channel of the (already half-resolution) interleaved chroma plane.
    static func halfCr(_ pb: CVPixelBuffer, scratch: inout [Float]) -> Plane8 {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 1), h = CVPixelBufferGetHeightOfPlane(pb, 1)
        var out = [UInt8](repeating: 0, count: w * h)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) else {
            return Plane8(width: w, height: h, data: out)
        }
        RimArrivalScanner.boxRows(base: base + 1, stride: CVPixelBufferGetBytesPerRowOfPlane(pb, 1), rows: h,
                                  block: 1, sampleStride: 2, workWidth: w, workHeight: h,
                                  scratch: &scratch, out: &out)
        return Plane8(width: w, height: h, data: out)
    }
}

// MARK: - Candidate finder

/// Per-frame round, orange, moving blobs from the background difference (half resolution).
final class CandidateFinder {
    let o: BallDetectorOptions
    let W: Int, H: Int
    let bgY: [Float], bgCr: [Float]
    // vDSP working space, allocated once for the whole window rather than once a frame.
    private var fy: [Float], fc: [Float], dC: [Float], scratch: [Float]

    init(options: BallDetectorOptions, width: Int, height: Int, bgY: [Float], bgCr: [Float]) {
        o = options; W = width; H = height; self.bgY = bgY; self.bgCr = bgCr
        let n = width * height
        fy = [Float](repeating: 0, count: n); fc = [Float](repeating: 0, count: n)
        dC = [Float](repeating: 0, count: n); scratch = [Float](repeating: 0, count: n)
    }

    /// Returns candidates in full-res px.
    func candidates(y: [UInt8], cr: [UInt8], expectedDiameterFull: Double) -> [BallCandidate] {
        let D = max(4.0, expectedDiameterFull / 2)
        let expArea = Double.pi * D * D / 4
        let n = W * H
        var diff = [Float](repeating: 0, count: n)
        var mask = [UInt8](repeating: 0, count: n)
        let cw = Float(o.chromaWeight), thr = Float(o.diffThreshold), om = Float(o.orangeMargin.rounded())
        // diff = |Y − bgY| + w·|Cr − bgCr|, mask = diff ≥ threshold and the pixel is *more* orange than the
        // background. Identical arithmetic to the scalar loop it replaces, but as vDSP calls, which are vectorised
        // whatever the optimisation level.
        let N = vDSP_Length(n)
        vDSP_vfltu8(y, 1, &fy, 1, N)
        vDSP_vfltu8(cr, 1, &fc, 1, N)
        vDSP_vsub(bgY, 1, fy, 1, &scratch, 1, N)              // Y − bgY
        vDSP_vabs(scratch, 1, &diff, 1, N)
        vDSP_vsub(bgCr, 1, fc, 1, &dC, 1, N)                  // Cr − bgCr, signed: the orange gate needs the sign
        vDSP_vabs(dC, 1, &scratch, 1, N)
        var weight = cw
        vDSP_vsma(scratch, 1, &weight, diff, 1, &diff, 1, N)
        diff.withUnsafeBufferPointer { df in dC.withUnsafeBufferPointer { dc in
            mask.withUnsafeMutableBufferPointer { mk in
                for i in 0..<n where df[i] >= thr && dc[i] > om { mk[i] = 1 }
            }
        } }
        var label = [Int32](repeating: 0, count: n)
        var stack: [Int] = []
        var next: Int32 = 1
        var out: [BallCandidate] = []
        for s in 0..<n where mask[s] == 1 && label[s] == 0 {
            stack.removeAll(keepingCapacity: true); stack.append(s); label[s] = next
            var pixels: [Int] = []
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            while let q = stack.popLast() {
                pixels.append(q)
                let qx = q % W, qy = q / W
                if qx < minX { minX = qx }; if qx > maxX { maxX = qx }; if qy < minY { minY = qy }; if qy > maxY { maxY = qy }
                if qx > 0 { let m = q - 1; if mask[m] == 1 && label[m] == 0 { label[m] = next; stack.append(m) } }
                if qx < W - 1 { let m = q + 1; if mask[m] == 1 && label[m] == 0 { label[m] = next; stack.append(m) } }
                if qy > 0 { let m = q - W; if mask[m] == 1 && label[m] == 0 { label[m] = next; stack.append(m) } }
                if qy < H - 1 { let m = q + W; if mask[m] == 1 && label[m] == 0 { label[m] = next; stack.append(m) } }
            }
            next += 1
            let area = Double(pixels.count)
            guard area >= o.minAreaFraction * expArea, area <= o.maxAreaFraction * expArea else { continue }
            let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
            guard max(bw, bh) / max(1, min(bw, bh)) <= o.maxAspect else { continue }
            let circ = area / (Double.pi * pow(max(bw, bh) / 2, 2))
            guard circ >= o.circularityMin else { continue }
            var sw = 0.0, su = 0.0, sv = 0.0, sd = 0.0
            for q in pixels {
                let d = Double(diff[q]); let w = d * d
                sw += w; su += w * Double(q % W); sv += w * Double(q / W); sd += d
            }
            guard sw > 0 else { continue }
            var mu = su / sw, mv = sv / sw
            // size: re-segment locally with a loose threshold (no orange gate) so the dark side of the ball counts
            var ext: Double
            let R = Int(1.5 * D), cx = Int(mu), cy = Int(mv)
            let lx0 = max(0, cx - R), ly0 = max(0, cy - R), lx1 = min(W - 1, cx + R), ly1 = min(H - 1, cy + R)
            if let lc = looseComponent(diff: diff, x0: lx0, y0: ly0, x1: lx1, y1: ly1, seedX: min(cx, lx1), seedY: min(cy, ly1)), Double(lc.area) <= 6 * expArea {
                let lw = Double(lc.maxX - lc.minX + 1), lh = Double(lc.maxY - lc.minY + 1)
                ext = min(max(min(lw, lh), max(bw, bh)), 2.2 * D)                       // smaller side: motion smear stretches the other
                if o.extentCentroid, min(lw, lh) >= 0.8 * D, min(lw, lh) <= 1.3 * D, max(lw, lh) <= 1.8 * D {
                    // full disc captured: its bounding-box centre does not move with the lit side
                    mu = Double(lc.minX) + lw / 2 - 0.5; mv = Double(lc.minY) + lh / 2 - 0.5
                }
            } else { ext = max(bw, bh) }
            let fu = (mu + 0.5) * 2, fv = (mv + 0.5) * 2, fd = ext * 2
            let edge = fv - fd / 2 < 2 || fu - fd / 2 < 2 || fu + fd / 2 > Double(2 * W) - 2
            out.append(BallCandidate(u: fu, v: fv, diameter: fd, meanDiff: sd / area, circularity: circ, edge: edge))
        }
        return out
    }

    /// Local search around `near` (full-res px) with a threshold adapted to the local maximum, no circularity test:
    /// used only by the backward extension, where the ball is merging with the hands. Same size/edge conventions as
    /// `candidates`, blobs limited to 2 D across. Returns the blob closest to `near` with a ball-like area.
    func localBlob(y: [UInt8], cr: [UInt8], near p: SIMD2<Double>, expectedDiameterFull: Double) -> BallCandidate? {
        let D = max(4.0, expectedDiameterFull / 2)
        let expArea = Double.pi * D * D / 4
        let R = Int(2.5 * D), cx = Int(p.x / 2), cy = Int(p.y / 2)
        let x0 = max(0, cx - R), x1 = min(W - 1, cx + R), y0 = max(0, cy - R), y1 = min(H - 1, cy + R)
        guard x1 > x0, y1 > y0 else { return nil }
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        var diff = [Float](repeating: 0, count: bw * bh), orange = [Bool](repeating: false, count: bw * bh)
        var maxD: Float = 0
        let cw = Float(o.chromaWeight), om = Float(o.orangeMargin.rounded())
        for yy in y0...y1 { for xx in x0...x1 {
            let i = yy * W + xx, l = (yy - y0) * bw + (xx - x0)
            let dcr = Float(cr[i]) - bgCr[i]
            let d = abs(Float(y[i]) - bgY[i]) + cw * abs(dcr)
            diff[l] = d; orange[l] = dcr > om; maxD = max(maxD, d)
        } }
        let thr = max(Float(o.diffThreshold), 0.25 * maxD)
        var label = [Bool](repeating: false, count: bw * bh)
        var stack: [Int] = []
        var best: (score: Double, c: BallCandidate)? = nil
        for s in 0..<(bw * bh) where diff[s] >= thr && orange[s] && !label[s] {
            stack.removeAll(keepingCapacity: true); stack.append(s); label[s] = true
            var sw = 0.0, su = 0.0, sv = 0.0, sd = 0.0, area = 0
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            while let q = stack.popLast() {
                let qx = q % bw, qy = q / bw
                minX = min(minX, qx); maxX = max(maxX, qx); minY = min(minY, qy); maxY = max(maxY, qy)
                let d = Double(diff[q]); let w = d * d
                sw += w; su += w * Double(qx); sv += w * Double(qy); sd += d; area += 1
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = qx + dx, ny = qy + dy
                    guard nx >= 0, ny >= 0, nx < bw, ny < bh else { continue }
                    let n = ny * bw + nx
                    if diff[n] >= thr && orange[n] && !label[n] { label[n] = true; stack.append(n) }
                }
            }
            let a = Double(area)
            guard a >= o.minAreaFraction * expArea, a <= o.maxAreaFraction * expArea, sw > 0 else { continue }
            let bwid = Double(maxX - minX + 1), bhei = Double(maxY - minY + 1)
            guard max(bwid, bhei) / min(bwid, bhei) <= o.maxAspect, max(bwid, bhei) <= 2.0 * D else { continue }
            let mu = su / sw + Double(x0), mv = sv / sw + Double(y0)
            let dist = hypot((mu + 0.5) * 2 - p.x, (mv + 0.5) * 2 - p.y)
            let score = dist / (2 * D) + 1.5 * abs(log(a / expArea))
            let ext = Double(min(maxX - minX, maxY - minY) + 1)
            let fu = (mu + 0.5) * 2, fv = (mv + 0.5) * 2, fd = ext * 2
            let edge = fv - fd / 2 < 2 || fu - fd / 2 < 2 || fu + fd / 2 > Double(2 * W) - 2
            if best == nil || score < best!.score { best = (score, BallCandidate(u: fu, v: fv, diameter: fd, meanDiff: sd / a, circularity: 0, edge: edge)) }
        }
        return best?.c
    }

    /// 8-connected component of `diff >= extentThreshold` containing (seedX, seedY) within the given box (absolute coords).
    private func looseComponent(diff: [Float], x0: Int, y0: Int, x1: Int, y1: Int, seedX: Int, seedY: Int) -> (area: Int, minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        let thr = Float(o.extentThreshold)
        guard seedX >= x0, seedX <= x1, seedY >= y0, seedY <= y1, diff[seedY * W + seedX] >= thr else { return nil }
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        var seen = [Bool](repeating: false, count: bw * bh)
        var stack = [(seedX, seedY)]
        seen[(seedY - y0) * bw + (seedX - x0)] = true
        var area = 0, minX = seedX, maxX = seedX, minY = seedY, maxY = seedY
        while let (x, y) = stack.popLast() {
            area += 1
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard nx >= x0, nx <= x1, ny >= y0, ny <= y1 else { continue }
                let li = (ny - y0) * bw + (nx - x0)
                if !seen[li], diff[ny * W + nx] >= thr { seen[li] = true; stack.append((nx, ny)) }
            } }
        }
        return (area, minX, maxX, minY, maxY)
    }
}

// MARK: - Small numerics (no external dependencies)

/// Least-squares polynomial fit, coefficients highest degree first (numpy.polyfit order).
func polyfit(_ x: [Double], _ y: [Double], degree: Int) -> [Double] {
    let m = degree + 1
    var ata = [Double](repeating: 0, count: m * m), atb = [Double](repeating: 0, count: m)
    for k in 0..<x.count {
        var pw = [Double](repeating: 1, count: m)
        for j in 1..<m { pw[j] = pw[j - 1] * x[k] }
        for r in 0..<m { atb[r] += pw[r] * y[k]; for c in 0..<m { ata[r * m + c] += pw[r] * pw[c] } }
    }
    let sol = solveLinear(ata, atb, n: m) ?? [Double](repeating: 0, count: m)
    return sol.reversed()
}

func polyval(_ p: [Double], _ x: Double) -> Double { p.reduce(0) { $0 * x + $1 } }

/// Gaussian elimination with partial pivoting on a dense n×n row-major system.
func solveLinear(_ aIn: [Double], _ bIn: [Double], n: Int) -> [Double]? {
    var a = aIn, b = bIn
    for col in 0..<n {
        var piv = col
        for r in (col + 1)..<max(col + 1, n) where abs(a[r * n + col]) > abs(a[piv * n + col]) { piv = r }
        guard abs(a[piv * n + col]) > 1e-12 else { return nil }
        if piv != col { for c in 0..<n { a.swapAt(piv * n + c, col * n + c) }; b.swapAt(piv, col) }
        for r in (col + 1)..<max(col + 1, n) {
            let f = a[r * n + col] / a[col * n + col]
            if f == 0 { continue }
            for c in col..<n { a[r * n + c] -= f * a[col * n + c] }
            b[r] -= f * b[col]
        }
    }
    var x = [Double](repeating: 0, count: n)
    for r in stride(from: n - 1, through: 0, by: -1) {
        var s = b[r]
        for c in (r + 1)..<max(r + 1, n) { s -= a[r * n + c] * x[c] }
        x[r] = s / a[r * n + r]
    }
    return x
}

/// A parabola in a vertical plane seen by a pinhole camera: u = (a + b t)/(1 + c t), v = (d + e t + f t²)/(1 + c t).
/// Robust fit by IRLS Gauss–Newton with the soft-L1 loss (scale 3 px), matching the Python tracker's `least_squares` call.
struct ProjectedParabola {
    var t0: Double
    var p: [Double]     // a, b, d, e, f, c

    static func fit(t: [Double], u: [Double], v: [Double], scale: Double = 3.0, iterations: Int = 12) -> ProjectedParabola? {
        guard t.count >= 6, t.count == u.count, t.count == v.count else { return nil }
        let t0 = t[0]; let tt = t.map { $0 - t0 }
        let pu = polyfit(tt, u, degree: 1), pv = polyfit(tt, v, degree: 2)
        var x = [pu[1], pu[0], pv[2], pv[1], pv[0], 0.0]
        let n = tt.count
        for _ in 0..<iterations {
            var jtj = [Double](repeating: 0, count: 36), jtr = [Double](repeating: 0, count: 6)
            for k in 0..<n {
                let s = tt[k], den = 1 + x[5] * s
                guard abs(den) > 1e-9 else { return nil }
                let nu = x[0] + x[1] * s, nv = x[2] + x[3] * s + x[4] * s * s
                let ru = nu / den - u[k], rv = nv / den - v[k]
                let ju: [Double] = [1 / den, s / den, 0, 0, 0, -nu * s / (den * den)]
                let jv: [Double] = [0, 0, 1 / den, s / den, s * s / den, -nv * s / (den * den)]
                for (r, j) in [(ru, ju), (rv, jv)] {
                    let z = (r / scale) * (r / scale); let w = 1 / (1 + z).squareRoot()      // soft-L1 IRLS weight
                    for i in 0..<6 { jtr[i] += w * j[i] * r; for l in 0..<6 { jtj[i * 6 + l] += w * j[i] * j[l] } }
                }
            }
            for i in 0..<6 { jtj[i * 6 + i] *= 1 + 1e-6 }                                   // tiny Levenberg damping
            guard let dx = solveLinear(jtj, jtr, n: 6) else { break }
            var stepNorm = 0.0
            for i in 0..<6 { x[i] -= dx[i]; stepNorm += dx[i] * dx[i] }
            if stepNorm < 1e-12 { break }
        }
        guard x.allSatisfy({ $0.isFinite }) else { return nil }
        return ProjectedParabola(t0: t0, p: x)
    }

    func predict(_ t: Double) -> (Double, Double) {
        let s = t - t0, den = 1 + p[5] * s
        return ((p[0] + p[1] * s) / den, (p[2] + p[3] * s + p[4] * s * s) / den)
    }
}

/// One slot per frame for the parallel candidate pass. Each worker writes slots no other worker touches, so the
/// array is only unsafe to Swift's exclusivity checker, never to the program; the lock makes that explicit and
/// costs one uncontended acquire per frame.
final class CandidateSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [[BallCandidate]]
    init(count: Int) { slots = Array(repeating: [], count: count) }
    func set(_ i: Int, _ v: [BallCandidate]) { lock.lock(); slots[i] = v; lock.unlock() }
    func take() -> [[BallCandidate]] { lock.lock(); defer { lock.unlock() }; return slots }
}

/// One Core ML inference in flight: started from the decode loop, waited for on the next frame.
///
/// The loop's body is synchronous (the reader hands over a pixel buffer that must not escape it), so this is a
/// plain dispatch and a semaphore rather than a task. Only one is ever outstanding, so nothing here contends.
final class InflightInference: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var boxes: [(u: Double, v: Double, diameterPx: Double, confidence: Float)] = []
    private var seconds = 0.0
    private var failed = false

    func start(tiles: [CoreMLBallDetector.Tile], minConfidence: Float) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let t0 = StageTimings.now()
            do { boxes = try CoreMLBallDetector.detect(tiles: tiles, minConfidence: minConfidence) }
            catch { failed = true; boxes = [] }
            seconds = StageTimings.now() - t0
            semaphore.signal()
        }
    }

    func wait() -> (boxes: [(u: Double, v: Double, diameterPx: Double, confidence: Float)], seconds: Double, failed: Bool) {
        semaphore.wait()
        return (boxes, seconds, failed)
    }
}
