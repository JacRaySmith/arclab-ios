import Foundation

/// Free-flight window of a ball track: where the hand let go and where the flight stopped
/// being a parabola (rim, backboard, net).
public struct FlightWindow: Sendable {
    /// Index of the first sample in free flight.
    public var releaseIndex: Int
    /// Sub-frame release time, from the pre-release residual ramp. This is the anchor for `t = 0`.
    public var releaseTime: Double
    /// Index of the last free-flight sample.
    public var endIndex: Int
    public var anchorRange: ClosedRange<Int>
    public var anchorFit: TrajectoryFit
    /// Local-window RMS threshold that separates free flight from push/contact, metres.
    public var tau: Double
    /// Fitted pre-release deviation growth ½·Δa (m/s²) — sanity: hand push ≈ 20–60 m/s² so ½Δa ≈ 10–30.
    public var rampCoefficient: Double
    public var noiseFloor: Double
    /// False when the track already starts in free flight: the release instant was not seen, so
    /// `releaseTime` is the first detection and release metrics must not be reported as such.
    public var releaseObserved: Bool
    public var notes: [String]
}

public enum FlightWindowError: Error, CustomStringConvertible, Sendable {
    case tooFewSamples(Int)
    case anchorTooShort(Int)
    case anchorFitFailed(String)
    case noFreeFlight

    public var description: String {
        switch self {
        case .tooFewSamples(let n): return "flight window needs ≥ 10 samples, got \(n)"
        case .anchorTooShort(let n): return "anchor window around the apex has only \(n) samples"
        case .anchorFitFailed(let s): return "anchor fit failed: \(s)"
        case .noFreeFlight: return "no sustained free-flight segment found"
        }
    }
}

public struct FlightWindowOptions: Sendable {
    /// Duration of the sliding local-physics window, seconds (at least `minimumLocalSamples` samples).
    /// A curvature error Δa over a window T misfits by ≈ Δa·T²/27 RMS: at 0.3 s the hand push
    /// (Δa ≈ 30 m/s²) misfits by 10 cm and a held ball (Δa = g) by 3 cm, against ≤ 1.5 cm of noise.
    public var localWindow: Double = 0.30
    public var minimumLocalSamples: Int = 6
    /// A local window counts as free flight when its fixed-g fit RMS is below
    /// `localFactor` × the RMS of the windows around the apex …
    public var localFactor: Double = 2.0
    public var localFloor: Double = 0.002
    /// … and the ball is moving: a held ball fits gravity to within g·T²/27, which is not always
    /// distinguishable from noise, but its speed is.
    public var minimumSpeed: Double = 2.0
    /// Half-width of the region around the apex used to estimate the noise level, seconds.
    public var apexRegion: Double = 0.2
    /// How far the ramp refinement searches around the coarse release, in samples.
    public var refineHalfWidthSamples: Int = 10
    /// Diagnostic: when set, the finder records one line per local window (t, RMS, speed, flight-like) in `notes`.
    public var debugWindows: Bool = false
    /// Release instant supplied by an external observer (e.g. wrist–ball separation from pose). The ramp search is
    /// skipped; the flight window starts at the first sample at or after this time and the release counts as observed.
    public var releaseTimeOverride: Double? = nil
    public init() {}
}

public enum FlightWindowFinder {
    /// Free-flight window by a *local gravity test*, then a physics-based sub-frame release time.
    ///
    /// A short window is slid along the track and fitted with the free-flight model with g held at
    /// 9.81 (the plane is metric). Inside free flight the residual is detector noise. A window that
    /// overlaps the hand push (acceleration ≈ 20–60 m/s², not g) or rim contact misfits by
    /// centimetres. Because the test is local it is indifferent to the slow bending that a slightly
    /// wrong shot-plane azimuth or scale error produces — those bend the track over the whole flight,
    /// with second derivatives ≪ 1 m/s². The textbook's walk-back against one anchor parabola
    /// (§10.3) is not: a 3° azimuth error bends the projected track by centimetres at the ends.
    ///
    /// The release instant is then refined below the frame by fitting the pre-release deviation
    /// ramp ½·Δa·(t_r − t)² (the kink is invisible within ~2 frames of release, but the ramp is not).
    public static func find(_ samples: [TrajectorySample], options: FlightWindowOptions = .init()) throws -> FlightWindow {
        let n = samples.count
        guard n >= 10 else { throw FlightWindowError.tooFewSamples(n) }
        var notes: [String] = []
        let apex = (0..<n).max { samples[$0].y < samples[$1].y }!
        let tApex = samples[apex].t
        var dts: [Double] = []
        for i in 1..<n { dts.append(samples[i].t - samples[i - 1].t) }
        let dt = max(Stats.median(dts), 1e-4)
        let Tw = max(options.localWindow, Double(options.minimumLocalSamples) * dt)

        var fitOpts = TrajectoryFitOptions()
        fitOpts.minimumSamples = options.minimumLocalSamples; fitOpts.minimumSpan = 0; fitOpts.fixedG = Court.g; fitOpts.robust = false

        // Local RMS for the window starting at each sample (NaN where too few samples).
        var localRMS = [Double](repeating: .nan, count: n)
        var localSpeed = [Double](repeating: 0, count: n)
        var windowEnd = [Int](repeating: -1, count: n)
        for s in 0..<n {
            var e = s
            while e + 1 < n && samples[e + 1].t - samples[s].t <= Tw { e += 1 }
            if e - s + 1 < options.minimumLocalSamples { continue }
            guard let f = try? TrajectoryFitter.fit((samples[s...e]), anchorTime: samples[s].t, options: fitOpts) else { continue }
            localRMS[s] = f.rms; windowEnd[s] = e
            let vmid = f.velocity(at: 0.5 * (samples[s].t + samples[e].t))
            localSpeed[s] = (vmid.x * vmid.x + vmid.y * vmid.y).squareRoot()
        }
        let apexWindows = (0..<n).filter { localRMS[$0].isFinite && abs(samples[$0].t + Tw / 2 - tApex) <= options.apexRegion }
        guard apexWindows.count >= 1 else { throw FlightWindowError.anchorTooShort(apexWindows.count) }
        let r0 = Stats.median(apexWindows.map { localRMS[$0] })
        let tauLocal = max(options.localFactor * r0, options.localFloor)

        // Maximal run of flight-like windows containing the apex.
        func isFlight(_ s: Int) -> Bool { localRMS[s].isFinite && localRMS[s] < tauLocal && localSpeed[s] >= options.minimumSpeed }
        if options.debugWindows {
            notes.append(String(format: "debug: tauLocal %.4f m (r0 %.4f), apex sample %d at t %.3f", tauLocal, r0, apex, tApex))
            for s in stride(from: 0, to: n, by: max(1, n / 40)) where localRMS[s].isFinite {
                notes.append(String(format: "debug: s %3d t %.3f rms %.4f speed %.2f %@", s, samples[s].t, localRMS[s], localSpeed[s], isFlight(s) ? "FLIGHT" : "-"))
            }
        }
        var seed = apexWindows.min { abs(samples[$0].t + Tw / 2 - tApex) < abs(samples[$1].t + Tw / 2 - tApex) }!
        if !isFlight(seed) { seed = apexWindows.min { localRMS[$0] < localRMS[$1] }! }
        var first = seed, last = seed
        while first > 0 && isFlight(first - 1) { first -= 1 }
        while last + 1 < n && isFlight(last + 1) { last += 1 }
        var coarseRelease = first
        var end = windowEnd[last] >= 0 ? windowEnd[last] : min(n - 1, last + options.minimumLocalSamples - 1)
        guard end > coarseRelease + 5 else { throw FlightWindowError.noFreeFlight }

        // Anchor fit over the coarse window (robust, g fixed) for residual profiles.
        var anchorOpts = TrajectoryFitOptions(); anchorOpts.minimumSamples = 5; anchorOpts.minimumSpan = 0.05; anchorOpts.fixedG = Court.g
        var anchorFit: TrajectoryFit
        do { anchorFit = try TrajectoryFitter.fit((samples[coarseRelease...end]), anchorTime: tApex, options: anchorOpts) }
        catch { throw FlightWindowError.anchorFitFailed("\(error)") }

        // Gap bridging: when the apex leaves the frame the track has a hole and the flight-like run stops at it.
        // If a later run of flight-like windows exists, adopt it when a joint fixed-g fit over both halves keeps the
        // residual at the level of the first half. Entry angle then comes from the descent, as required.
        if end < n - 1 {
            var s = last + 1
            while s < n && !isFlight(s) { s += 1 }
            if s < n {
                var runEnd = s
                while runEnd + 1 < n && isFlight(runEnd + 1) { runEnd += 1 }
                let cand = windowEnd[runEnd] >= 0 ? windowEnd[runEnd] : min(n - 1, runEnd + options.minimumLocalSamples - 1)
                if cand > end + 4, samples[s].t - samples[end].t > 0.05 {
                    var joint: [TrajectorySample] = Array(samples[coarseRelease...end])
                    joint.append(contentsOf: samples[s...cand])
                    let candRMS = (try? TrajectoryFitter.fit((samples[s...cand]), anchorTime: samples[s].t, options: anchorOpts).rms) ?? .infinity
                    if let jf = try? TrajectoryFitter.fit(joint, anchorTime: tApex, options: anchorOpts),
                       jf.rms <= max(1.5 * max(anchorFit.rms, candRMS), 0.02) {
                        notes.append(String(format: "bridged a %.2f s gap (apex out of frame): joint fixed-g RMS %.4f vs %.4f before", samples[s].t - samples[end].t, jf.rms, anchorFit.rms))
                        end = cand
                        anchorFit = jf
                    } else {
                        notes.append("a later flight-like segment was not adopted: joint fixed-g fit inconsistent")
                    }
                }
            }
        }
        // Same backwards: an earlier flight-like run (the ascent before the apex left the frame).
        if first > 0 {
            var s = first - 1
            while s >= 0 && !isFlight(s) { s -= 1 }
            if s >= 0 {
                var runStart = s
                while runStart - 1 >= 0 && isFlight(runStart - 1) { runStart -= 1 }
                let candEnd = windowEnd[s] >= 0 ? windowEnd[s] : min(n - 1, s + options.minimumLocalSamples - 1)
                if candEnd < coarseRelease, samples[coarseRelease].t - samples[candEnd].t > 0.05 {
                    var joint: [TrajectorySample] = Array(samples[runStart...candEnd])
                    joint.append(contentsOf: samples[coarseRelease...end])
                    let candRMS = (try? TrajectoryFitter.fit((samples[runStart...candEnd]), anchorTime: samples[runStart].t, options: anchorOpts).rms) ?? .infinity
                    if let jf = try? TrajectoryFitter.fit(joint, anchorTime: tApex, options: anchorOpts),
                       jf.rms <= max(1.5 * max(anchorFit.rms, candRMS), 0.02) {
                        notes.append(String(format: "bridged a %.2f s gap backwards (ascent recovered): joint fixed-g RMS %.4f vs %.4f", samples[coarseRelease].t - samples[candEnd].t, jf.rms, anchorFit.rms))
                        coarseRelease = runStart
                        anchorFit = jf
                    } else {
                        notes.append("an earlier flight-like segment was not adopted: joint fixed-g fit inconsistent")
                    }
                }
            }
        }
        var releaseObserved = coarseRelease > 0
        var overrideTime: Double? = nil
        if let tr = options.releaseTimeOverride, let idx = samples.firstIndex(where: { $0.t >= tr - 1e-6 }), idx < end - 5 {
            coarseRelease = max(coarseRelease, idx) == coarseRelease && coarseRelease > idx ? coarseRelease : idx
            releaseObserved = true; overrideTime = tr
            notes.append(String(format: "release instant taken from the pose observer at t = %.3f s (sample %d)", tr, idx))
        }
        if !releaseObserved { notes.append("track starts in free flight: release instant not observed") }
        if end == n - 1 { notes.append("track ends in free flight; no rim contact seen") }
        let res: [Double] = samples.map { s in
            let p = anchorFit.position(at: s.t)
            return ((s.x - p.x) * (s.x - p.x) + (s.y - p.y) * (s.y - p.y)).squareRoot()
        }
        let noiseFloor = Stats.median((coarseRelease...end).map { res[$0] })
        let tau = max(2.5 * noiseFloor, options.localFloor)
        // A 0.3 s window tolerates a few contact frames at its tail before its RMS trips; drop them
        // individually (rim contact reverses the vertical velocity, so they stand out at once).
        var trimmed = 0
        while end > coarseRelease + 5 && res[end] > 3 * tau && trimmed < 8 { end -= 1; trimmed += 1 }

        // Ramp refinement: signed residual along the push direction ≈ c0 + c1·(t − t_r) + k·(t_r − t)²₊.
        // The linear term absorbs any slow bend left in the anchor fit near the release end.
        // The coarse release is early (the kink is invisible for the last few push frames), so the
        // search region reaches further into the flight than before it: the post-release frames pin
        // the zero level of the ramp.
        let halfW = min(options.refineHalfWidthSamples, max(3, Int((0.06 / dt).rounded())))
        let lo = max(0, coarseRelease - halfW)
        let hiR = min(end - 1, coarseRelease + max(2 * halfW, Int((0.12 / dt).rounded())))
        var bestT = samples[coarseRelease].t
        var bestSSE = Double.infinity
        var bestK = 0.0
        if let ot = overrideTime {
            bestT = ot
        } else if !releaseObserved {
            bestT = samples[0].t
        } else if hiR > lo + 4 {
            var dirX = 0.0, dirY = 0.0
            for m in max(0, lo - halfW)..<coarseRelease where res[m] > 3 * tau {
                let p = anchorFit.position(at: samples[m].t)
                dirX += samples[m].x - p.x; dirY += samples[m].y - p.y
            }
            let dn = (dirX * dirX + dirY * dirY).squareRoot()
            let signed: [Double] = (lo...hiR).map { m in
                if dn > 0 {
                    let p = anchorFit.position(at: samples[m].t)
                    return ((samples[m].x - p.x) * dirX + (samples[m].y - p.y) * dirY) / dn
                }
                return res[m] - noiseFloor
            }
            let tMin = samples[lo].t, tMax = samples[hiR].t
            let steps = Int(((tMax - tMin) / dt * 20).rounded())
            for k in 0...max(steps, 1) {
                let tr = tMin + (tMax - tMin) * Double(k) / Double(max(steps, 1))
                // Flat, row-major: this runs once per grid step and an array-of-rows put every
                // one of its rows behind its own allocation.
                let rowCount = hiR - lo + 1
                var rows = [Double](repeating: 1, count: 3 * rowCount)
                for (j, m) in (lo...hiR).enumerated() {
                    let d = tr - samples[m].t
                    rows[3 * j + 1] = samples[m].t - tr
                    rows[3 * j + 2] = d > 0 ? d * d : 0
                }
                guard let c = LinAlg.leastSquaresRowMajor(rows, signed, rows: rowCount, columns: 3), c[2] >= 0 else { continue }
                var sse = 0.0
                for j in 0..<rowCount {
                    let e = signed[j] - (c[0] + c[1] * rows[3 * j + 1] + c[2] * rows[3 * j + 2])
                    sse += e * e
                }
                if sse < bestSSE { bestSSE = sse; bestT = tr; bestK = c[2] }
            }
        } else {
            notes.append("too few samples around the release for ramp refinement; release time is the coarse frame")
        }
        var releaseIndex = coarseRelease
        while releaseIndex < n - 1 && samples[releaseIndex].t < bestT { releaseIndex += 1 }
        while releaseIndex > 0 && samples[releaseIndex - 1].t >= bestT { releaseIndex -= 1 }
        guard releaseIndex < end else { throw FlightWindowError.noFreeFlight }

        return FlightWindow(releaseIndex: releaseIndex, releaseTime: bestT, endIndex: end, anchorRange: coarseRelease...end,
                            anchorFit: anchorFit, tau: tauLocal, rampCoefficient: bestK, noiseFloor: r0,
                            releaseObserved: releaseObserved, notes: notes)
    }
}
