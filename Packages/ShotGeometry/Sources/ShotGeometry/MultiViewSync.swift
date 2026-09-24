import Foundation
import simd

// MultiViewSync — finding the constant time offset between two clips of the *same* shot, from the
// ball's own flight, so the two clips can be handed to `MultiViewFit` as a real triangulation
// (docs/DESIGN-MULTIVIEW-2026-09-24.md §3).
//
// iOS has no shared capture clock across two devices (docs/research/whole-body-landmarks-2026-09-16.md
// §3): each clip's timestamps are on its own clock, offset by however far apart the two "record"
// presses landed — tens to hundreds of ms of human reaction time, not knowable to better than that
// unless it is measured from the footage. The ball is already tracked in both clips and follows a
// parabola, so it is a shared, moving, physically-modelled signal that needs no clap and no screen
// flash: shift one clip's timestamps by a candidate offset τ, triangulate the ball at every instant
// both clips cover under that shift, and see how much the two rays disagree.
//
// Why the disagreement is minimised at the true offset, not just small everywhere: at the correct τ
// the two rays are looking at the *same instant* of a moving ball, so they meet (up to pixel noise
// alone). At any other τ they are being asked to agree on where a moving ball was, off by an amount
// that grows with the ball's speed and the size of the error — the cost is a bowl in τ with its
// floor at the truth, not a flat function of it, which is what makes it possible to find τ this way
// at all (and what "the fit is flat in the offset" below is checking is *not* the case).
//
// What a residual sync error costs, quantified rather than hand-waved: a ball in flight moves at
// roughly 6–9 m/s and a hand can move at a few m/s through release. At 240 fps one frame is
// 4.167 ms. `positionErrorEstimateMetres` below is the first-order arithmetic
// (error ≈ speed × |sync error|) behind the "milliseconds become centimetres" warning;
// `docs/DESIGN-MULTIVIEW-2026-09-24.md` §5 table 2 measures the actual triangulated error against a
// synthetic sweep rather than only asserting this linear model.
public enum MultiViewSync {

    public struct Options: Sendable {
        /// Same default and same citation as `MultiViewFit.Options.pixelNoiseSigmaPx`.
        public var pixelNoiseSigmaPx: Double = 1.85
        /// How far either side of zero to search. ±1 s is generous against reaction-time desync
        /// between two button presses; a flight is a few tenths of a second, so most of the range
        /// finds no overlap and is skipped cheaply.
        public var searchRangeSeconds: Double = 1.0
        /// Grid step for the coarse search — one 240 fps frame. The true optimum is then found by a
        /// local quadratic refinement around the best grid point, not by the grid resolution alone.
        public var searchStepSeconds: Double = 1.0 / 240
        /// Fewer samples than this in either view, or fewer than this many overlapping candidate
        /// instants, and there is not enough ball to time-align against.
        public var minimumSamples: Int = 8
        /// The quadratic fit to cost(τ) around its minimum must rise by at least this many multiples
        /// of its own residual scatter across the fitted window, or the "minimum" is not trusted to
        /// be more than noise (the flat-fit refusal).
        public var minimumCurvatureToNoiseRatio: Double = 4.0

        public init() {}
    }

    public struct Result: Sendable {
        /// Seconds to add to view B's timestamps so they read on view A's clock: `tA ≈ tB - offset`
        /// is the same real instant, i.e. `tA + offset ≈ tB`. Nil with a reason when unresolved.
        public var offsetSeconds: Double?
        /// 1-σ, from the local curvature of cost(τ) at its minimum (see the formula in
        /// `estimateOffset`). A first-order estimate, not a full covariance propagation — stated
        /// plainly because CLAUDE.md rule 1 applies to precision claims, not only to bare numbers.
        public var uncertaintySeconds: Double?
        public var samplesUsed: Int
        /// RMS triangulation residual at the found minimum, metres — the noise floor this offset was
        /// resolved against.
        public var costAtMinimumMetres: Double?
        public var unavailableReason: String?

        public init(offsetSeconds: Double?, uncertaintySeconds: Double?, samplesUsed: Int,
                    costAtMinimumMetres: Double?, unavailableReason: String?) {
            self.offsetSeconds = offsetSeconds; self.uncertaintySeconds = uncertaintySeconds
            self.samplesUsed = samplesUsed; self.costAtMinimumMetres = costAtMinimumMetres
            self.unavailableReason = unavailableReason
        }

        static func refused(_ reason: String, samplesUsed: Int = 0, offset: Double? = nil, cost: Double? = nil) -> Result {
            Result(offsetSeconds: offset, uncertaintySeconds: nil, samplesUsed: samplesUsed, costAtMinimumMetres: cost, unavailableReason: reason)
        }
    }

    /// First-order positional error a residual sync error causes for something moving at a given
    /// speed: `error ≈ speed × |syncError|`. Pure arithmetic, kept in code so the "ms become cm"
    /// warning is never retyped by hand and can be unit-tested.
    public static func positionErrorEstimateMetres(speedMetresPerSecond: Double, syncErrorSeconds: Double) -> Double {
        abs(speedMetresPerSecond * syncErrorSeconds)
    }

    /// Estimate the constant offset between two ball tracks of the same shot, from two
    /// court-anchored cameras, by minimising the disagreement of their triangulated ball position.
    /// Pure function: no video decode, no I/O — the two tracks are already-detected ball samples.
    public static func estimateOffset(viewA: [ImageSample], cameraA: Camera, labelA: String = "A",
                                      viewB: [ImageSample], cameraB: Camera, labelB: String = "B",
                                      options: Options = .init()) -> Result {
        let a = viewA.sorted { $0.t < $1.t }
        let b = viewB.sorted { $0.t < $1.t }
        guard a.count >= options.minimumSamples, b.count >= options.minimumSamples else {
            return .refused("the ball track is too short to fix a sync offset from it: \(a.count) sample(s) in \(labelA), \(b.count) in \(labelB); need at least \(options.minimumSamples) in each")
        }

        let fitOptions = MultiViewFit.Options(pixelNoiseSigmaPx: options.pixelNoiseSigmaPx, minimumBearingSeparationRadians: 0)
        // Mean squared triangulation residual at a candidate offset τ (`tA + τ ≈ tB`), over every A
        // sample whose shifted instant falls inside B's covered time range. The bearing gate is
        // disabled here on purpose: whether the two cameras are usably separated for triangulating a
        // *joint* is `MultiViewFit`'s question, not this search's — a poor bearing still produces a
        // residual that is smallest at the true offset, which is all this needs.
        func cost(_ tau: Double) -> (meanSquare: Double, n: Int)? {
            var sq: [Double] = []
            for sample in a {
                guard let bUV = interpolate(b, at: sample.t + tau) else { continue }
                let obsA = MultiViewFit.Observation(view: labelA, camera: cameraA, pixel: sample.uv, confidence: 1)
                let obsB = MultiViewFit.Observation(view: labelB, camera: cameraB, pixel: bUV, confidence: 1)
                guard let rms = MultiViewFit.triangulate(name: "ball", observations: [obsA, obsB], options: fitOptions).rmsResidualMetres else { continue }
                sq.append(rms * rms)
            }
            guard sq.count >= options.minimumSamples else { return nil }
            return (sq.reduce(0, +) / Double(sq.count), sq.count)
        }

        let n = max(1, Int((options.searchRangeSeconds / options.searchStepSeconds).rounded()))
        var grid: [(tau: Double, meanSquare: Double, n: Int)] = []
        for k in -n...n {
            let tau = Double(k) * options.searchStepSeconds
            if let c = cost(tau) { grid.append((tau, c.meanSquare, c.n)) }
        }
        guard grid.count >= 7 else {
            return .refused("the two tracks overlap at only \(grid.count) candidate offset(s) in a ±\(options.searchRangeSeconds)s search: they may not cover the same real time at any plausible offset")
        }
        guard let bestIndex = grid.indices.min(by: { grid[$0].meanSquare < grid[$1].meanSquare }) else {
            return .refused("no candidate offset produced a usable triangulation")
        }
        let best = grid[bestIndex]

        // Local quadratic refinement of mean-square cost vs τ, over a small window around the best
        // grid point (a parabola near its own minimum, by construction of a least-squares cost).
        let lo = max(0, bestIndex - 3), hi = min(grid.count - 1, bestIndex + 3)
        guard hi - lo >= 4 else {
            return Result(offsetSeconds: best.tau, uncertaintySeconds: nil, samplesUsed: best.n, costAtMinimumMetres: best.meanSquare.squareRoot(),
                          unavailableReason: "the minimum sits at the edge of the searched range; widen `searchRangeSeconds` to refine it")
        }
        let taus = grid[lo...hi].map(\.tau)
        let costs = grid[lo...hi].map(\.meanSquare)
        guard let q = PolyFit.quadratic(taus, costs), q.c2 > 0 else {
            return .refused("the cost is flat (or has no interior minimum) in the offset around its best grid point: no time offset is resolvable from this ball track — it may be too short, too slow, or too straight a line to break the τ symmetry",
                            samplesUsed: best.n, offset: nil, cost: best.meanSquare.squareRoot())
        }
        let tauStar = -q.c1 / (2 * q.c2)
        let rawSD = Stats.sd(taus.indices.map { costs[$0] - q(taus[$0]) })
        let fitResidualSD = rawSD.isFinite ? rawSD : 0
        let halfWindow = (taus.last! - taus.first!) / 2
        let rise = q.c2 * halfWindow * halfWindow
        let ratio = fitResidualSD > 0 ? rise / fitResidualSD : Double.infinity
        guard ratio >= options.minimumCurvatureToNoiseRatio else {
            return .refused(String(format: "the cost curve's curvature (%.3g) is only %.1f× its own noise scatter across the fitted window (need %.1f×): the minimum at %.1f ms is not distinguishable from noise",
                                   q.c2, ratio, options.minimumCurvatureToNoiseRatio, tauStar * 1000),
                            samplesUsed: best.n, offset: nil, cost: best.meanSquare.squareRoot())
        }
        let sigmaTau = fitResidualSD > 0 ? (fitResidualSD / q.c2).squareRoot() : nil

        return Result(offsetSeconds: tauStar, uncertaintySeconds: sigmaTau, samplesUsed: best.n,
                      costAtMinimumMetres: best.meanSquare.squareRoot(), unavailableReason: nil)
    }

    // MARK: - interpolation

    /// The track's position at time `t`, from a local quadratic fit through the samples nearest `t`
    /// (falls back to linear between the two bracketing samples when fewer than 3 are available).
    /// Never extrapolates: nil outside the track's own time span.
    static func interpolate(_ track: [ImageSample], at t: Double, halfWindow: Int = 4) -> SIMD2<Double>? {
        guard let first = track.first, let last = track.last, t >= first.t, t <= last.t else { return nil }
        guard let i = track.indices.min(by: { abs(track[$0].t - t) < abs(track[$1].t - t) }) else { return nil }
        let lo = max(0, i - halfWindow), hi = min(track.count - 1, i + halfWindow)
        if hi - lo >= 2 {
            let times = (lo...hi).map { track[$0].t }
            if Set(times).count == times.count,
               let qu = PolyFit.quadratic(times, (lo...hi).map { track[$0].uv.x }),
               let qv = PolyFit.quadratic(times, (lo...hi).map { track[$0].uv.y }) {
                return SIMD2(qu(t), qv(t))
            }
        }
        guard let j = track.indices.first(where: { track[$0].t >= t }), j > 0 else { return track[i].uv }
        let p = track[j - 1], q = track[j]
        guard q.t > p.t else { return p.uv }
        let f = (t - p.t) / (q.t - p.t)
        return p.uv + f * (q.uv - p.uv)
    }
}
