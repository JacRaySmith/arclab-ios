import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import simd
import ShotGeometry

// RimFinder: propose the rim ellipse from a single frame so the user only confirms or nudges it.
//
// Why this exists: RimCalibrator needs ≥ 6 boundary points on the ring's INNER edge (its
// 0.4572 m circle). Tapping those by hand is the slowest, most error-prone step in setup — and
// footage/2026-09-13/rim_1766.json shows how wrong a hand trace can be without ever looking wrong.
//
// What it measures. The ring is painted orange on a 5/8" (0.0159 m) tube. At the distances we
// film from, that tube is ~4 px wide but its image band is ~9–10 px wide: lens blur and bloom
// spread it symmetrically. So "walk inward to the last orange pixel" lands ~3 px *inside* the
// true inner circle — a 5 % under-estimate of the ring, hence a 5 % distance error. Instead this
// finder locates the band's two half-maximum crossings along each normal, takes their midpoint
// (blur is symmetric, so the midpoint is the tube centre-line to sub-pixel accuracy), fits the
// centre-line ellipse, and then converts to the inner edge by the known tube radius:
//
//     inner / centre-line = 0.4572 / (0.4572 + 0.0159) = 0.96639
//
// Both ellipses are returned, along with the raw inward half-max crossings, so a caller that
// disagrees with the correction can use the measurement it prefers.
//
// Zero network calls; no Vision, no Core ML. Pure pixels + ShotGeometry's ellipse fitter.

public enum RimEdge: String, Sendable {
    /// The 0.4572 m circle — what `RimCalibrationOptions.rimDiameter` defaults to.
    case inner
    /// The painted tube's centre-line, 0.4731 m across. What a careful hand trace actually marks.
    case tubeCentreLine
}

public struct RimFinderOptions: Sendable {
    /// Only this top fraction of the frame is searched. The rim is never in the bottom of a shot clip.
    public var searchTopFraction: Double = 0.60
    /// Minimum of (R − max(G, B)) for a pixel to count as ring paint, after the luma gate.
    public var minChromaScore: Double = 24
    /// Luma gate. Below `minLuma` the R−max(G,B) difference is noise (dark foliage and deep
    /// shadow read as weakly red); above `maxLuma` the pixel is clipped and hueless. Both are
    /// soft: the score ramps over 10 levels either side so the normal's profile stays smooth
    /// enough to interpolate. `minLuma` is deliberately below the shaded side of the ring
    /// (luma ≈ 55 on the 2026-09-13 footage) — the chroma test, not this one, finds the paint.
    public var minLuma: Double = 34
    public var maxLuma: Double = 250
    /// A pixel is "thin" (arc-like) if its neighbourhood is less than `maxThickDensity` orange.
    /// This deletes the solid interior of the mounting bracket and of the backboard's border,
    /// leaving their outlines, which the angular-coverage test then rejects.
    public var thicknessWindow: Int = 15
    public var maxThickDensity: Double = 0.60
    /// Ellipse priors, in pixels and degrees. Major/minor are full axes.
    public var minMajorAxisPx: Double = 60
    public var maxMajorAxisPx: Double = 400
    public var minAxisRatio: Double = 0.12
    public var maxAxisRatio: Double = 0.70
    public var maxMajorAxisTiltDegrees: Double = 25
    /// A normal must reach this paint score somewhere before its band is measured. It sits
    /// *below* `minChromaScore` on purpose: the half-maximum crossings are read off a profile,
    /// and the shaded side of the ring still has a well-formed one even where no single pixel
    /// clears the mask threshold. Raising it above `minChromaScore` costs coverage on exactly
    /// the angles the fit most needs.
    public var minBandPeakScore: Double = 14
    public var ransacIterations: Int = 1500
    /// The fitted ellipse must find ring paint over at least this fraction of its angular range.
    public var minAngularCoverage: Double = 0.60
    /// The unsupported part may be one contiguous sector this large — the bracket where the ring
    /// meets the backboard. Anything gappier is not a ring.
    public var maxBracketSectorFraction: Double = 0.34
    /// How far along each normal the band is searched, and the sampling step, in pixels.
    public var normalSearchPx: Double = 9
    public var normalStepPx: Double = 0.25
    /// A band wider than this is not the tube — it is a blob the ellipse happens to cross.
    public var maxBandWidthPx: Double = 13
    public var boundaryPointCount: Int = 64
    public var rimInnerDiameter: Double = Court.rimInnerDiameter
    public var rimTubeDiameter: Double = Court.rimTubeDiameter
    /// Which circle `boundaryPoints` and `ellipse` describe. `.inner` matches RimCalibrator's default.
    public var edge: RimEdge = .inner
    /// Fixed so the same frame always gives the same proposal; the user's nudge must be reproducible.
    public var randomSeed: UInt64 = 0x5EED_1EAF
    public init() {}

    var innerOverCentreLine: Double { rimInnerDiameter / (rimInnerDiameter + rimTubeDiameter) }
}

public struct RimFindResult: Sendable {
    /// `boundaryPointCount` points on the requested edge, ready for `RimCalibrator.calibrate`.
    public var boundaryPoints: [SIMD2<Double>]
    /// The ellipse `boundaryPoints` lie on (inner edge unless `options.edge` says otherwise).
    public var ellipse: Ellipse
    /// The measured ellipse of the painted tube's centre-line. This is the direct measurement;
    /// `ellipse` is derived from it.
    public var tubeCentreLineEllipse: Ellipse
    /// Raw inward half-maximum crossings, before any tube correction. One per sampled angle
    /// **where a band was actually measured**, so this is shorter than `boundaryPointCount`
    /// whenever part of the ring is hidden — an unmeasured angle contributes nothing rather
    /// than a point invented from the fit. Systematically ~3 px inside the true inner circle
    /// because of blur, which is why it is diagnostic output and not the answer.
    public var rawInwardEdgePoints: [SIMD2<Double>]
    /// Fraction of the ellipse's angular range where ring paint was found (the "inlier fraction").
    public var inlierFraction: Double
    /// Largest contiguous unsupported sector, as a fraction of the full turn. The bracket sector.
    public var largestGapFraction: Double
    /// RMS Sampson residual of the centre-line points about the fitted centre-line ellipse, px.
    public var rmsResidualPx: Double
    /// Median half-maximum width of the paint band, px. ~9–10 px on the 2026-09-13 footage.
    public var medianBandWidthPx: Double
    /// 0…1. Below ~0.6 the proposal needs a human eye on it before it is used.
    public var confidence: Double
    public var warnings: [String]
    /// Region of the frame that was searched, in image pixels (origin top-left).
    public var searchRegion: CGRect

    /// Public so an app target can build a result from a user-dragged ellipse and feed the same
    /// downstream path as an automatic proposal. A hand-placed ellipse has no measured band, so
    /// pass `confidence: 1` and leave `rawInwardEdgePoints` empty rather than inventing one.
    public init(boundaryPoints: [SIMD2<Double>],
                ellipse: Ellipse,
                tubeCentreLineEllipse: Ellipse,
                rawInwardEdgePoints: [SIMD2<Double>],
                inlierFraction: Double,
                largestGapFraction: Double,
                rmsResidualPx: Double,
                medianBandWidthPx: Double,
                confidence: Double,
                warnings: [String],
                searchRegion: CGRect) {
        self.boundaryPoints = boundaryPoints
        self.ellipse = ellipse
        self.tubeCentreLineEllipse = tubeCentreLineEllipse
        self.rawInwardEdgePoints = rawInwardEdgePoints
        self.inlierFraction = inlierFraction
        self.largestGapFraction = largestGapFraction
        self.rmsResidualPx = rmsResidualPx
        self.medianBandWidthPx = medianBandWidthPx
        self.confidence = confidence
        self.warnings = warnings
        self.searchRegion = searchRegion
    }
}

public enum RimFindOutcome: Sendable {
    case found(RimFindResult)
    /// Plain-language reason, safe to show in the marking UI.
    case notFound(reason: String)

    public var result: RimFindResult? { if case .found(let r) = self { return r }; return nil }
    public var reason: String? { if case .notFound(let s) = self { return s }; return nil }
}

public enum RimFinder {

    // MARK: - Entry points

    public static func find(in image: CGImage, options: RimFinderOptions = .init()) -> RimFindResult? {
        findWithDiagnosis(in: image, options: options).result
    }

    public static func find(in pixelBuffer: CVPixelBuffer, options: RimFinderOptions = .init()) -> RimFindResult? {
        findWithDiagnosis(in: pixelBuffer, options: options).result
    }

    public static func findWithDiagnosis(in image: CGImage, options: RimFinderOptions = .init()) -> RimFindOutcome {
        guard let plane = ChromaPlane(image: image, options: options) else {
            return .notFound(reason: "the frame could not be read as pixels")
        }
        return search(plane, options)
    }

    public static func findWithDiagnosis(in pixelBuffer: CVPixelBuffer, options: RimFinderOptions = .init()) -> RimFindOutcome {
        guard let cg = makeCGImage(pixelBuffer) else {
            return .notFound(reason: "the video frame could not be converted to an image")
        }
        return findWithDiagnosis(in: cg, options: options)
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func makeCGImage(_ pb: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pb)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    // MARK: - The search

    static func search(_ plane: ChromaPlane, _ opt: RimFinderOptions) -> RimFindOutcome {
        let mask = plane.mask(minScore: opt.minChromaScore)
        if mask.count == 0 {
            return .notFound(reason: "no orange ring paint in the upper part of the frame — is the basket in shot, and is the ring painted?")
        }
        let thin = mask.thinned(window: opt.thicknessWindow, maxDensity: opt.maxThickDensity)
        let seeds = thin.components().filter {
            $0.count >= 120 && $0.width >= 45 && $0.width <= 420 && $0.height <= Int(1.1 * Double($0.width))
        }.sorted { $0.count > $1.count }
        if seeds.isEmpty {
            return .notFound(reason: "found orange pixels but no wide, flat arc that could be a ring (the ring may be edge-on, cut off, or hidden)")
        }

        var candidates: [Candidate] = []
        for seed in seeds.prefix(4) {
            let pad = max(60, Int(0.7 * Double(seed.width)))
            let pts = thin.points(inX: (seed.minX - pad)...(seed.maxX + pad),
                                  y: (seed.minY - pad)...(seed.maxY + pad))
            candidates += ransac(points: pts, mask: mask, options: opt, seedSalt: UInt64(seed.minX &* 131 &+ seed.minY))
        }
        if candidates.isEmpty {
            return .notFound(reason: "no ellipse through the orange pixels matched a rim's size, flatness and tilt")
        }
        candidates.sort { $0.rawScore > $1.rawScore }

        var solutions: [Scored] = []
        for cand in candidates.prefix(8) {
            guard let polished = polish(cand.ellipse, plane: plane, mask: mask, options: opt) else { continue }
            // Several RANSAC seeds normally converge on the same ellipse; that agreement is
            // evidence, not competition. Only a *different* ellipse counts as a rival.
            if let i = solutions.firstIndex(where: { sameSolution($0.ellipse, polished.ellipse) }) {
                if polished.score > solutions[i].score { solutions[i] = polished }
            } else {
                solutions.append(polished)
            }
        }
        solutions.sort { $0.score > $1.score }
        guard let best = solutions.first else {
            return .notFound(reason: "the ellipse never settled on a continuous orange band — the ring is probably partly hidden or badly blurred")
        }
        // Score ranks how well an ellipse follows the paint; the coverage and gap tests ask
        // whether it is a *ring* at all. A near-miss that scores highest must not veto a slightly
        // worse-scoring ellipse that actually passes, so walk down the list instead of giving up.
        func passes(_ s: Scored) -> Bool {
            s.coverage >= opt.minAngularCoverage && s.largestGap <= opt.maxBracketSectorFraction
        }
        guard let winIndex = solutions.firstIndex(where: passes) else {
            if best.coverage < opt.minAngularCoverage {
                return .notFound(reason: String(format: "only %.0f%% of the proposed ring outline is orange (need %.0f%%) — the ring is too occluded in this frame",
                                                best.coverage * 100, opt.minAngularCoverage * 100))
            }
            return .notFound(reason: String(format: "%.0f%% of the ring in a row is missing, more than the backboard bracket can explain",
                                            best.largestGap * 100))
        }
        let win = solutions[winIndex]
        // The margin below asks "is there a *rival* answer?", so the runner-up is the best other
        // distinct ellipse — which is not solutions[1] when the winner was not solutions[0].
        let runnerUp = solutions.enumerated().filter { $0.offset != winIndex }.map(\.element.score).max() ?? 0

        let centreLine = win.ellipse
        let k = opt.edge == .inner ? opt.innerOverCentreLine : 1.0
        let target = Ellipse(center: centreLine.center,
                             semiMajor: centreLine.semiMajor * k,
                             semiMinor: centreLine.semiMinor * k,
                             angle: centreLine.angle)

        var boundary: [SIMD2<Double>] = []
        boundary.reserveCapacity(opt.boundaryPointCount)
        for i in 0..<opt.boundaryPointCount {
            let phi = 2 * Double.pi * Double(i) / Double(opt.boundaryPointCount)
            boundary.append(target.point(at: phi))
        }

        // Confidence: how much of the ring was seen, how well it fitted, how gappy it was, and
        // how far clear the winner finished from the next distinct ellipse. The last term is the
        // one that matters on IMG_1766, where two plausible ellipses score within a whisker.
        // The ring always meets the backboard at a bracket, so one tip normally ends in solid
        // orange. That is where an under-sized proposal hides (see IMG_1766, where the ring and
        // the backboard's border merge): the fit is self-consistent and the residual is small,
        // but the ellipse stops short. One frame cannot settle it — point the user at that tip.
        let buriedTip = majorAxisTipBuried(centreLine, mask: mask, thin: thin)
        let covTerm = clamp((win.coverage - opt.minAngularCoverage) / (1 - opt.minAngularCoverage), 0, 1)
        let resTerm = clamp(1 - win.rms / 3.0, 0, 1)
        let gapTerm = clamp(1 - win.largestGap / opt.maxBracketSectorFraction, 0, 1)
        let margin = win.score - runnerUp
        let marginTerm = runnerUp <= 0 ? 0.7 : clamp(margin / 0.10, 0, 1)
        let confidence = clamp(0.40 * covTerm + 0.25 * resTerm + 0.15 * gapTerm + 0.20 * marginTerm, 0, 1)

        var warnings: [String] = []
        if margin < 0.05 && runnerUp > 0 {
            warnings.append("a second, differently sized ellipse fits almost as well — check the proposal against the ring's left and right tips before accepting")
        }
        if let side = buriedTip {
            warnings.append("the \(side) end of the ring runs into solid orange (mounting bracket or backboard border), so its exact tip is inferred, not seen — check that end first")
        }
        if win.largestGap > 0.25 {
            warnings.append(String(format: "%.0f%% of the ring is not visible as paint (bracket or backboard); the far side of the ellipse is extrapolated", win.largestGap * 100))
        }
        if win.medianBandWidth > 0.85 * opt.maxBandWidthPx {
            warnings.append(String(format: "the paint band is %.1f px wide, close to the %.0f px limit — the frame is soft or over-exposed, so the inner-edge correction is less reliable here",
                                   win.medianBandWidth, opt.maxBandWidthPx))
        }
        if target.axisRatio < 0.15 {
            warnings.append("the ring is nearly edge-on; the camera is close to rim height, which makes the pose fragile")
        }
        if confidence < 0.6 {
            warnings.append("low confidence — treat this as a starting point for the user to drag, not a measurement")
        }

        return .found(RimFindResult(boundaryPoints: boundary,
                                    ellipse: target,
                                    tubeCentreLineEllipse: centreLine,
                                    rawInwardEdgePoints: win.inwardPoints,
                                    inlierFraction: win.coverage,
                                    largestGapFraction: win.largestGap,
                                    rmsResidualPx: win.rms,
                                    medianBandWidthPx: win.medianBandWidth,
                                    confidence: confidence,
                                    warnings: warnings,
                                    searchRegion: CGRect(x: 0, y: 0, width: plane.width, height: plane.height)))
    }

    // MARK: - RANSAC

    struct Candidate { var ellipse: Ellipse; var rawScore: Double }

    static func ransac(points: [SIMD2<Double>], mask: Mask, options opt: RimFinderOptions, seedSalt: UInt64) -> [Candidate] {
        guard points.count >= 40 else { return [] }
        var rng = SplitMix64(seed: opt.randomSeed &+ seedSalt)
        var found: [Candidate] = []
        let n = points.count
        for _ in 0..<opt.ransacIterations {
            var idx = [Int](repeating: 0, count: 5)
            var ok = true
            for i in 0..<5 {
                let j = Int(rng.next() % UInt64(n))
                if idx[0..<i].contains(j) { ok = false; break }
                idx[i] = j
            }
            if !ok { continue }
            let sample = idx.map { points[$0] }
            let uMin = sample.map(\.x).min()!, uMax = sample.map(\.x).max()!
            if uMax - uMin < 45 { continue }
            guard let e = algebraicEllipse(sample), passesPriors(e, opt) else { continue }
            let support = coverage(of: e, mask: mask, rays: 36, tolerance: 2)
            let k = Double(support.filter { $0 }.count) / 36.0
            if k >= 20.0 / 36.0 { found.append(Candidate(ellipse: e, rawScore: k)) }
        }
        found.sort { $0.rawScore > $1.rawScore }
        var deduped: [Candidate] = []
        for c in found {
            let dup = deduped.contains {
                abs($0.ellipse.center.x - c.ellipse.center.x) < 8 &&
                abs($0.ellipse.center.y - c.ellipse.center.y) < 6 &&
                abs($0.ellipse.semiMajor - c.ellipse.semiMajor) < 8
            }
            if dup { continue }
            deduped.append(c)
            if deduped.count >= 6 { break }
        }
        return deduped
    }

    static func passesPriors(_ e: Ellipse, _ opt: RimFinderOptions) -> Bool {
        guard e.semiMajor >= opt.minMajorAxisPx / 2, e.semiMajor <= opt.maxMajorAxisPx / 2 else { return false }
        let r = e.axisRatio
        guard r >= opt.minAxisRatio, r <= opt.maxAxisRatio else { return false }
        var deg = e.angle * 180 / .pi
        deg = deg.truncatingRemainder(dividingBy: 180)
        if deg > 90 { deg -= 180 }
        if deg < -90 { deg += 180 }
        return abs(deg) <= opt.maxMajorAxisTiltDegrees
    }

    // MARK: - Band measurement and polish

    struct Scored {
        var ellipse: Ellipse
        var inwardPoints: [SIMD2<Double>]
        var coverage: Double
        var largestGap: Double
        var rms: Double
        var medianBandWidth: Double
        var score: Double
    }

    /// One pass of: walk the normal at each angle, find the paint band's half-maximum crossings,
    /// take the midpoint (tube centre-line) and the inward crossing, and refit.
    struct BandSample {
        var centre: [SIMD2<Double>] = []
        var inward: [SIMD2<Double>] = []
        var widths: [Double] = []
        var supported: [Bool] = []
    }

    static func sampleBand(_ e: Ellipse, plane: ChromaPlane, count: Int, options opt: RimFinderOptions) -> BandSample {
        var out = BandSample()
        out.supported = [Bool](repeating: false, count: count)
        out.centre = [SIMD2<Double>](repeating: .zero, count: count)
        out.inward = [SIMD2<Double>](repeating: .zero, count: count)
        out.widths = [Double](repeating: .nan, count: count)
        let ct = cos(e.angle), st = sin(e.angle)
        let step = opt.normalStepPx, span = opt.normalSearchPx
        let steps = Int((2 * span / step).rounded()) + 1
        var profile = [Double](repeating: 0, count: steps)
        let peakMin = opt.minBandPeakScore

        for i in 0..<count {
            let phi = 2 * Double.pi * Double(i) / Double(count)
            let cp = cos(phi), sp = sin(phi)
            let px = e.center.x + e.semiMajor * cp * ct - e.semiMinor * sp * st
            let py = e.center.y + e.semiMajor * cp * st + e.semiMinor * sp * ct
            var nx = e.semiMinor * cp * ct - e.semiMajor * sp * st
            var ny = e.semiMinor * cp * st + e.semiMajor * sp * ct
            let nl = (nx * nx + ny * ny).squareRoot()
            if nl < 1e-9 { out.centre[i] = SIMD2(px, py); out.inward[i] = out.centre[i]; continue }
            nx /= nl; ny /= nl
            // t runs from +span (outward) down to −span (inward), matching the walk in the brief.
            var peak = -1.0, peakIdx = 0
            for s in 0..<steps {
                let t = span - Double(s) * step
                let v = plane.score(px + nx * t, py + ny * t)
                profile[s] = v
                if v > peak { peak = v; peakIdx = s }
            }
            out.centre[i] = SIMD2(px, py); out.inward[i] = out.centre[i]
            if peak < peakMin { continue }
            let half = 0.5 * peak
            var kIn = peakIdx
            while kIn + 1 < steps && profile[kIn + 1] >= half { kIn += 1 }
            var kOut = peakIdx
            while kOut - 1 >= 0 && profile[kOut - 1] >= half { kOut -= 1 }
            let tOfIndex = { (s: Int) in span - Double(s) * step }
            var tIn = tOfIndex(kIn)
            if kIn + 1 < steps {
                let drop = profile[kIn] - profile[kIn + 1]
                if drop > 1e-9 { tIn -= step * (profile[kIn] - half) / drop }
            }
            var tOut = tOfIndex(kOut)
            if kOut - 1 >= 0 {
                let drop = profile[kOut] - profile[kOut - 1]
                if drop > 1e-9 { tOut += step * (profile[kOut] - half) / drop }
            }
            let width = tOut - tIn
            out.widths[i] = width
            if width > opt.maxBandWidthPx { continue }   // a blob, not the tube
            let tMid = 0.5 * (tIn + tOut)
            out.centre[i] = SIMD2(px + nx * tMid, py + ny * tMid)
            out.inward[i] = SIMD2(px + nx * tIn, py + ny * tIn)
            out.supported[i] = true
        }
        return out
    }

    static func polish(_ start: Ellipse, plane: ChromaPlane, mask: Mask, options opt: RimFinderOptions) -> Scored? {
        var e = start
        for _ in 0..<3 {
            let band = sampleBand(e, plane: plane, count: opt.boundaryPointCount, options: opt)
            let pts = zip(band.centre, band.supported).filter(\.1).map(\.0)
            guard pts.count >= 14, let fit = EllipseFitter.fit(pts), passesPriors(fit.ellipse, opt) else { return nil }
            // One robust pass: drop points more than 2.5 medians off the fresh fit.
            let conic = fit.ellipse.conic
            let d = pts.map { conic.sampsonDistance($0) }
            let med = median(d)
            let keep = zip(pts, d).filter { $0.1 < max(1.2, 2.5 * med) }.map(\.0)
            if keep.count >= 14, let refit = EllipseFitter.fit(keep), passesPriors(refit.ellipse, opt) {
                e = refit.ellipse
            } else {
                e = fit.ellipse
            }
        }
        let band = sampleBand(e, plane: plane, count: opt.boundaryPointCount, options: opt)
        let pts = zip(band.centre, band.supported).filter(\.1).map(\.0)
        guard pts.count >= 20 else { return nil }
        let conic = e.conic
        let rms = (pts.map { pow(conic.sampsonDistance($0), 2) }.reduce(0, +) / Double(pts.count)).squareRoot()
        let sup = coverage(of: e, mask: mask, rays: 72, tolerance: 2)
        let cov = Double(sup.filter { $0 }.count) / Double(sup.count)
        let gap = largestGapFraction(sup)
        // Only the angles whose band passed: a profile that cleared `minBandPeakScore` but was
        // then rejected as too wide is not a measurement of the tube, and including it would let
        // a stray blob set the number the blur warning is read from.
        let widths = zip(band.widths, band.supported).filter { $0.1 && $0.0.isFinite }.map(\.0)
        let mw = widths.isEmpty ? Double.nan : median(widths)
        return Scored(ellipse: e,
                      inwardPoints: zip(band.inward, band.supported).filter(\.1).map(\.0),
                      coverage: cov, largestGap: gap,
                      rms: rms, medianBandWidth: mw, score: cov - 0.05 * rms)
    }

    // MARK: - Angular coverage

    static func coverage(of e: Ellipse, mask: Mask, rays: Int, tolerance: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: rays)
        let ct = cos(e.angle), st = sin(e.angle)
        for i in 0..<rays {
            let phi = 2 * Double.pi * Double(i) / Double(rays)
            let cp = cos(phi), sp = sin(phi)
            let px = e.center.x + e.semiMajor * cp * ct - e.semiMinor * sp * st
            let py = e.center.y + e.semiMajor * cp * st + e.semiMinor * sp * ct
            var nx = e.semiMinor * cp * ct - e.semiMajor * sp * st
            var ny = e.semiMinor * cp * st + e.semiMajor * sp * ct
            let nl = (nx * nx + ny * ny).squareRoot()
            if nl < 1e-9 { continue }
            nx /= nl; ny /= nl
            for t in (-tolerance)...tolerance {
                if mask.at(Int((px + nx * Double(t)).rounded()), Int((py + ny * Double(t)).rounded())) {
                    out[i] = true; break
                }
            }
        }
        return out
    }

    static func largestGapFraction(_ sup: [Bool]) -> Double {
        let n = sup.count
        guard n > 0, sup.contains(false) else { return 0 }
        if !sup.contains(true) { return 1 }
        var best = 0, run = 0
        for i in 0..<(2 * n) {
            if sup[i % n] { run = 0 } else { run += 1; best = max(best, run) }
        }
        return Double(min(best, n)) / Double(n)
    }

    // MARK: - Minimal algebraic ellipse fit (RANSAC proposals only)

    /// Direct algebraic conic fit on a minimal sample. ShotGeometry's `EllipseFitter` is the
    /// right tool for the final fits (it is Sampson-weighted and needs ≥ 6 points); this one is
    /// deliberately cheap because RANSAC calls it thousands of times with exactly 5 points.
    static func algebraicEllipse(_ points: [SIMD2<Double>]) -> Ellipse? {
        let n = points.count
        guard n >= 5 else { return nil }
        var mean = SIMD2<Double>(0, 0)
        for p in points { mean += p }
        mean /= Double(n)
        var msr = 0.0
        for p in points { let d = p - mean; msr += d.x * d.x + d.y * d.y }
        let scale = (msr / (2 * Double(n))).squareRoot()
        guard scale > 1e-9 else { return nil }
        var S = [Double](repeating: 0, count: 36)
        for p in points {
            let q = (p - mean) / scale
            let row = [q.x * q.x, q.x * q.y, q.y * q.y, q.x, q.y, 1.0]
            for i in 0..<6 { for j in 0..<6 { S[i * 6 + j] += row[i] * row[j] } }
        }
        guard let v = smallestEigenvector6(S) else { return nil }
        let c = Conic(a: v[0], b: v[1], c: v[2], d: v[3], e: v[4], f: v[5])
        guard var ell = c.ellipse() else { return nil }
        ell.center = mean + ell.center * scale
        ell.semiMajor *= scale
        ell.semiMinor *= scale
        guard ell.semiMajor.isFinite, ell.semiMinor.isFinite, ell.semiMinor > 0 else { return nil }
        return ell
    }

    /// Cyclic Jacobi on a 6×6 symmetric matrix; returns the eigenvector of the smallest eigenvalue.
    static func smallestEigenvector6(_ input: [Double]) -> [Double]? {
        var a = input
        var v = [Double](repeating: 0, count: 36)
        for i in 0..<6 { v[i * 6 + i] = 1 }
        for _ in 0..<40 {
            var off = 0.0
            for p in 0..<6 { for q in (p + 1)..<6 { off += a[p * 6 + q] * a[p * 6 + q] } }
            if off < 1e-24 { break }
            for p in 0..<6 {
                for q in (p + 1)..<6 {
                    let apq = a[p * 6 + q]
                    if abs(apq) < 1e-18 { continue }
                    let theta = (a[q * 6 + q] - a[p * 6 + p]) / (2 * apq)
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let cth = 1 / (t * t + 1).squareRoot(), sth = t * cth
                    for k in 0..<6 {
                        let akp = a[k * 6 + p], akq = a[k * 6 + q]
                        a[k * 6 + p] = cth * akp - sth * akq
                        a[k * 6 + q] = sth * akp + cth * akq
                    }
                    for k in 0..<6 {
                        let apk = a[p * 6 + k], aqk = a[q * 6 + k]
                        a[p * 6 + k] = cth * apk - sth * aqk
                        a[q * 6 + k] = sth * apk + cth * aqk
                    }
                    for k in 0..<6 {
                        let vkp = v[k * 6 + p], vkq = v[k * 6 + q]
                        v[k * 6 + p] = cth * vkp - sth * vkq
                        v[k * 6 + q] = sth * vkp + cth * vkq
                    }
                }
            }
        }
        var best = 0
        for k in 1..<6 where a[k * 6 + k] < a[best * 6 + best] { best = k }
        let vec = (0..<6).map { v[$0 * 6 + best] }
        return vec.allSatisfy(\.isFinite) ? vec : nil
    }

    // MARK: - Small helpers

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

    /// Is either end of the major axis sitting inside a solid (non-thin) orange region?
    /// Returns "left"/"right" (image sense) for the buried end, or nil.
    static func majorAxisTipBuried(_ e: Ellipse, mask: Mask, thin: Mask) -> String? {
        let ct = cos(e.angle), st = sin(e.angle)
        for sign in [1.0, -1.0] {
            let x = e.center.x + sign * e.semiMajor * ct
            let y = e.center.y + sign * e.semiMajor * st
            var buried = 0
            for dy in -1...1 {
                for dx in -1...1 {
                    let xi = Int(x.rounded()) + dx, yi = Int(y.rounded()) + dy
                    if mask.at(xi, yi) && !thin.at(xi, yi) { buried += 1 }
                }
            }
            if buried >= 5 { return (sign * ct >= 0) ? "right" : "left" }
        }
        return nil
    }

    /// Two polished ellipses are the same answer if a user could not tell them apart by eye.
    static func sameSolution(_ a: Ellipse, _ b: Ellipse) -> Bool {
        abs(a.center.x - b.center.x) < 4 && abs(a.center.y - b.center.y) < 3
            && abs(a.semiMajor - b.semiMajor) < 4 && abs(a.semiMinor - b.semiMinor) < 3
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }
}

// MARK: - Pixels

/// The searched band of the frame, reduced to one "ring paint" score per pixel.
///
/// score = max(0, R − max(G, B)), gated to the luma range where that difference means anything.
/// Orange paint on the ring scores 30–50 in this footage; the white backboard scores ~20 but is
/// clipped out by the upper luma gate; foliage scores 0 (green dominates); and the dark sky,
/// which has a nonsense R:G *ratio*, is removed by the lower gate rather than by a hue test.
struct ChromaPlane {
    let width: Int
    let height: Int          // the searched height (top fraction of the frame)
    let fullHeight: Int
    var values: [Float]

    init?(image: CGImage, options: RimFinderOptions) {
        let w = image.width, h = image.height
        guard w > 8, h > 8 else { return nil }
        let searched = max(8, min(h, Int(Double(h) * options.searchTopFraction)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let px = base.assumingMemoryBound(to: UInt8.self)
        self.width = w; self.height = searched; self.fullHeight = h
        self.values = [Float](repeating: 0, count: w * searched)
        let lo = Float(options.minLuma), hi = Float(options.maxLuma)
        values.withUnsafeMutableBufferPointer { out in
            for y in 0..<searched {
                let row = y * w * 4
                for x in 0..<w {
                    let i = row + x * 4
                    let r = Float(px[i]), g = Float(px[i + 1]), b = Float(px[i + 2])
                    let chroma = r - max(g, b)
                    if chroma <= 0 { continue }
                    // Gate on luma, not on R. Gating on R is wrong in both directions: a sunlit
                    // ring clips its red channel to 255 while the pixel is still strongly orange,
                    // so an R-based upper gate eats the band's *core* and biases the half-maximum
                    // midpoint the whole measurement rests on; and R alone calls a dark, noisy
                    // pixel bright. On the 2026-09-13 clips the ring's luma runs 55–140.
                    let luma = 0.299 * r + 0.587 * g + 0.114 * b
                    // Soft gates so the profile stays continuous for sub-pixel interpolation.
                    let gLo = min(max((luma - lo) / 10, 0), 1)
                    let gHi = min(max((hi + 10 - luma) / 10, 0), 1)
                    out[y * w + x] = chroma * gLo * gHi
                }
            }
        }
    }

    @inline(__always) func score(_ x: Int, _ y: Int) -> Double {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return Double(values[y * width + x])
    }

    /// Bilinear, for sub-pixel walks along the normal.
    @inline(__always) func score(_ x: Double, _ y: Double) -> Double {
        let xc = min(max(x, 0), Double(width) - 1.001)
        let yc = min(max(y, 0), Double(height) - 1.001)
        let x0 = Int(xc), y0 = Int(yc)
        let fx = xc - Double(x0), fy = yc - Double(y0)
        let i = y0 * width + x0
        let a = Double(values[i]), b = Double(values[i + 1])
        let c = Double(values[i + width]), d = Double(values[i + width + 1])
        return a * (1 - fx) * (1 - fy) + b * fx * (1 - fy) + c * (1 - fx) * fy + d * fx * fy
    }

    func mask(minScore: Double) -> Mask {
        var bits = [Bool](repeating: false, count: width * height)
        var n = 0
        let t = Float(minScore)
        for i in 0..<bits.count where values[i] >= t { bits[i] = true; n += 1 }
        return Mask(width: width, height: height, bits: bits, count: n)
    }
}

struct Mask {
    let width: Int
    let height: Int
    var bits: [Bool]
    var count: Int

    @inline(__always) func at(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return bits[y * width + x]
    }

    /// Keeps only mask pixels whose `window`×`window` neighbourhood is less than `maxDensity`
    /// orange. The ring's band is ~9 px in a 15 px window (40 %); the mounting bracket and the
    /// backboard's painted border are solid, so their interiors go and only outlines remain.
    func thinned(window: Int, maxDensity: Double) -> Mask {
        let w = width, h = height
        var integral = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum: Int32 = 0
            for x in 0..<w {
                rowSum += bits[y * w + x] ? 1 : 0
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + rowSum
            }
        }
        let r = window / 2
        var out = [Bool](repeating: false, count: w * h)
        var n = 0
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h - 1, y + r)
            for x in 0..<w where bits[y * w + x] {
                let x0 = max(0, x - r), x1 = min(w - 1, x + r)
                let s = integral[(y1 + 1) * (w + 1) + x1 + 1] - integral[y0 * (w + 1) + x1 + 1]
                      - integral[(y1 + 1) * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                let area = Double((y1 - y0 + 1) * (x1 - x0 + 1))
                if Double(s) / area < maxDensity { out[y * w + x] = true; n += 1 }
            }
        }
        return Mask(width: w, height: h, bits: out, count: n)
    }

    struct Component { var minX = 0, minY = 0, maxX = 0, maxY = 0, count = 0
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    /// 8-connected components, iterative flood fill.
    func components() -> [Component] {
        var seen = [Bool](repeating: false, count: width * height)
        var out: [Component] = []
        var stack: [Int] = []
        for start in 0..<(width * height) where bits[start] && !seen[start] {
            seen[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            var c = Component(minX: start % width, minY: start / width,
                              maxX: start % width, maxY: start / width, count: 0)
            while let i = stack.popLast() {
                c.count += 1
                let x = i % width, y = i / width
                if x < c.minX { c.minX = x }; if x > c.maxX { c.maxX = x }
                if y < c.minY { c.minY = y }; if y > c.maxY { c.maxY = y }
                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= height { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        if nx < 0 || nx >= width { continue }
                        let j = ny * width + nx
                        if bits[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            out.append(c)
        }
        return out
    }

    func points(inX xr: ClosedRange<Int>, y yr: ClosedRange<Int>) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        let x0 = max(0, xr.lowerBound), x1 = min(width - 1, xr.upperBound)
        let y0 = max(0, yr.lowerBound), y1 = min(height - 1, yr.upperBound)
        guard x0 <= x1, y0 <= y1 else { return out }
        for y in y0...y1 {
            for x in x0...x1 where bits[y * width + x] {
                out.append(SIMD2(Double(x), Double(y)))
            }
        }
        return out
    }
}

/// Deterministic PRNG so the same frame always yields the same proposal.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
