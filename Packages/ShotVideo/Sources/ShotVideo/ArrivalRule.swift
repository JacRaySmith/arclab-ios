import Foundation
import simd

/// One ball-sized candidate on one frame, in full-resolution pixels: all the arrival rule ever sees.
public struct ArrivalCandidate: Sendable {
    public var u: Double
    public var v: Double
    public var diameterPx: Double
    public init(u: Double, v: Double, diameterPx: Double) { self.u = u; self.v = v; self.diameterPx = diameterPx }
}

/// The knobs of `tools/pytrack/session.py` `find_arrivals`, in ball diameters and real seconds.
public struct ArrivalRuleOptions: Sendable {
    public var nearRimDiameters: Double = 2.5
    public var minBallFraction: Double = 0.5
    public var maxBallFraction: Double = 2.0
    public var descentLookbackFrames: Int = 3
    public var descentMinimumDropPx: Double = 2
    public var highLookbackRealSeconds: Double = 1.5
    public var highFrameFraction: Double = 0.4       // "high in the frame" = the upper 40 %
    public var highMinBallFraction: Double = 0.4
    public var minimumHighCandidates: Int = 6
    public var minimumSeparationRealSeconds: Double = 3.0
    public init() {}
}

public struct ArrivalEvent: Sendable {
    public var fileTime: Double
    public var frameIndex: Int
    public var distancePx: Double
    public var diameterPx: Double
    public var high: Int
}

/// `find_arrivals`, frame index for frame index, independent of where the candidates came from.
///
/// It lives here rather than in the app so the desktop probe can run the *same* rule over the Vision
/// scanner's candidates and over the fast scanner's, and the two arrival lists can be compared directly.
public enum ArrivalRule {
    public static func arrivals(slots: [Int: [ArrivalCandidate]], fps: Double, frameHeight: Double,
                                rimCenter: SIMD2<Double>, ballDiameterPx D: Double, timeScale: Double,
                                options: ArrivalRuleOptions = .init()) -> [ArrivalEvent] {
        guard let lo = slots.keys.min(), let hi = slots.keys.max(), D > 0, fps > 0 else { return [] }
        let lookback = max(1, Int((options.highLookbackRealSeconds * timeScale * fps).rounded()))
        let separationFrames = options.minimumSeparationRealSeconds * timeScale * fps
        var out: [ArrivalEvent] = []
        var lastIndex = -Double.infinity

        for i in (lo + options.descentLookbackFrames)...max(lo + options.descentLookbackFrames, hi) {
            guard let here = slots[i], !here.isEmpty else { continue }
            // 1. A ball-sized candidate within 2.5 diameters of the rim centre.
            let near = here.filter {
                let d = (((($0.u - rimCenter.x) * ($0.u - rimCenter.x)) + (($0.v - rimCenter.y) * ($0.v - rimCenter.y)))).squareRoot()
                return d < options.nearRimDiameters * D && $0.diameterPx > options.minBallFraction * D && $0.diameterPx < options.maxBallFraction * D
            }
            guard !near.isEmpty else { continue }
            let c = near.min { a, b in
                let da = ((a.u - rimCenter.x) * (a.u - rimCenter.x)) + ((a.v - rimCenter.y) * (a.v - rimCenter.y))
                let db = ((b.u - rimCenter.x) * (b.u - rimCenter.x)) + ((b.v - rimCenter.y) * (b.v - rimCenter.y))
                return da < db
            }!
            // 2. Moving down: something near it and above it in the previous three frames.
            var descending = false
            for k in (i - options.descentLookbackFrames)..<i {
                for p in slots[k] ?? [] {
                    let d = ((((p.u - c.u) * (p.u - c.u)) + ((p.v - c.v) * (p.v - c.v)))).squareRoot()
                    if d < options.nearRimDiameters * D && p.v < c.v - options.descentMinimumDropPx { descending = true; break }
                }
                if descending { break }
            }
            guard descending else { continue }
            // 3. Preceded by the descent: ball-sized candidates high in the frame within 1.5 s real.
            var high = 0
            let w0 = max(lo, i - lookback)
            if w0 <= i - options.descentLookbackFrames - 1 {
                for k in w0...(i - options.descentLookbackFrames - 1) {
                    for h in slots[k] ?? [] where h.v < options.highFrameFraction * frameHeight
                        && h.u < c.u + 2 * D
                        && h.diameterPx > options.highMinBallFraction * D && h.diameterPx < options.maxBallFraction * D {
                        high += 1
                    }
                }
            }
            guard high >= options.minimumHighCandidates else { continue }
            // 4. One arrival per shot.
            guard Double(i) - lastIndex >= separationFrames else { continue }
            let distance = ((((c.u - rimCenter.x) * (c.u - rimCenter.x)) + ((c.v - rimCenter.y) * (c.v - rimCenter.y)))).squareRoot()
            out.append(ArrivalEvent(fileTime: Double(i) / fps, frameIndex: i, distancePx: distance,
                                    diameterPx: c.diameterPx, high: high))
            lastIndex = Double(i)
        }
        return out
    }
}
