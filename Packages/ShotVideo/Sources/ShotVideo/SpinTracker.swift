import Foundation
import simd
import CoreVideo

// SpinTracker — ball spin rate and spin-axis direction from the ball's own surface texture.
//
// Why this can work at all: a basketball in flight is a rigid sphere. Every point of its surface
// moves with v = ω × p. Under the weak-perspective projection that a ball a few metres across the
// frame satisfies, the *image* velocity of a surface point at normalised disc coordinates (x, y)
// — x right, y down, both in units of the ball's apparent radius, with z = √(1 − x² − y²) the
// (unit) depth of the near surface — is, in the same radius units and with ω in rad/frame:
//
//     fx = −ω_y · z − ω_z · y
//     fy =  ω_z · x + ω_x · z
//
// Three unknowns, linear, one equation pair per matched surface patch. ω_z is a plain in-plane
// rotation of the disc; ω_x and ω_y push texture *across* the disc, strongest at the centre and
// vanishing at the limb where z → 0. So a dense-enough set of texture correspondences inside the
// disc determines the full 3-D angular velocity — rate *and* axis — from a single camera, with no
// depth information and no ball model beyond "sphere".
//
// Why it usually fails in practice, and what this file does about it:
//   • The ball must actually carry texture the matcher can lock onto (seams, logo, panel lines).
//     A dim or low-contrast ball is a smooth blob and there is nothing to track. Measured as
//     `dynamicTextureSNR`; below `minDynamicSNR` the rate is nil with a reason.
//   • The strongest image structure on a ball is very often the *specular highlight*, which is
//     fixed in the illumination frame and does NOT rotate with the ball. Left alone it drags every
//     match toward zero displacement and yields a confident-looking spin of ≈ 0. The temporal
//     median of the centre-aligned patches is exactly that static component, so it is subtracted
//     (`suppressStaticIllumination`), and what is left — the part of the ball's appearance that
//     actually moves — is what gets matched. `staticStructureFraction` reports the split.
//   • Motion blur over the exposure smears the texture along the flight direction. Warned about.
//
// Nothing here fabricates a number: every output is optional and carries an `…UnavailableReason`
// when it could not be computed (CLAUDE.md rule 1). Radians in code, degrees only in the reported
// tilt fields, which say so in their names (rule 4).
//
// Camera coordinates throughout: x right, y down, z away from the camera.

// MARK: - Inputs

/// One frame's grayscale pixels. `origin` lets the caller pass a crop rather than a whole frame:
/// pixel (0, 0) of `pixels` is source pixel (originX, originY), so ball centres coming from a
/// track are always written in full-frame source coordinates regardless of cropping.
public struct SpinGrayImage: Sendable {
    public var width: Int
    public var height: Int
    public var originX: Int
    public var originY: Int
    public var pixels: [Float]              // row-major luma, 0…255

    public init(width: Int, height: Int, originX: Int = 0, originY: Int = 0, pixels: [Float]) {
        self.width = width; self.height = height
        self.originX = originX; self.originY = originY
        self.pixels = pixels
    }

    /// Copies the luma plane of a 4:2:0 pixel buffer, cropped to the given rectangle in source
    /// pixels (clipped to the buffer). Returns nil if the rectangle misses the buffer entirely.
    public static func luma(from pixelBuffer: CVPixelBuffer,
                            cropX: Int, cropY: Int, cropWidth: Int, cropHeight: Int) -> SpinGrayImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let full = planeCount == 0
        let w = full ? CVPixelBufferGetWidth(pixelBuffer) : CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = full ? CVPixelBufferGetHeight(pixelBuffer) : CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = full ? CVPixelBufferGetBytesPerRow(pixelBuffer) : CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard let base = (full ? CVPixelBufferGetBaseAddress(pixelBuffer)
                               : CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let x0 = max(0, cropX), y0 = max(0, cropY)
        let x1 = min(w, cropX + cropWidth), y1 = min(h, cropY + cropHeight)
        guard x1 > x0, y1 > y0 else { return nil }
        let cw = x1 - x0, ch = y1 - y0
        var out = [Float](repeating: 0, count: cw * ch)
        out.withUnsafeMutableBufferPointer { dst in
            for row in 0..<ch {
                let src = base + (y0 + row) * stride + x0
                let o = row * cw
                for c in 0..<cw { dst[o + c] = Float(src[c]) }
            }
        }
        return SpinGrayImage(width: cw, height: ch, originX: x0, originY: y0, pixels: out)
    }

    /// Catmull-Rom sample at a source-pixel coordinate. Returns nil when any of the 16 taps falls
    /// outside the image, so the caller can mark the patch pixel invalid rather than invent an edge.
    @inline(__always)
    func sample(sourceX: Double, sourceY: Double) -> Float? {
        let fx = sourceX - Double(originX), fy = sourceY - Double(originY)
        let ix = Int(floor(fx)), iy = Int(floor(fy))
        guard ix - 1 >= 0, iy - 1 >= 0, ix + 2 < width, iy + 2 < height else { return nil }
        let tx = fx - Double(ix), ty = fy - Double(iy)
        func w(_ t: Double) -> (Double, Double, Double, Double) {
            let t2 = t * t, t3 = t2 * t
            return (0.5 * (-t3 + 2 * t2 - t),
                    0.5 * (3 * t3 - 5 * t2 + 2),
                    0.5 * (-3 * t3 + 4 * t2 + t),
                    0.5 * (t3 - t2))
        }
        let (wx0, wx1, wx2, wx3) = w(tx)
        let (wy0, wy1, wy2, wy3) = w(ty)
        var acc = 0.0
        let wys = [wy0, wy1, wy2, wy3], wxs = [wx0, wx1, wx2, wx3]
        for j in 0..<4 {
            let row = (iy - 1 + j) * width + (ix - 1)
            var r = 0.0
            for i in 0..<4 { r += wxs[i] * Double(pixels[row + i]) }
            acc += wys[j] * r
        }
        return Float(acc)
    }
}

/// One tracked ball position. `timeSeconds` must be *real* time — if the clip is a slowed
/// recording, divide file seconds by the slow-motion factor before building these.
public struct SpinSample: Sendable, Codable {
    public var timeSeconds: Double
    public var centre: SIMD2<Double>        // full-frame source pixels
    public var radiusPx: Double

    public init(timeSeconds: Double, centre: SIMD2<Double>, radiusPx: Double) {
        self.timeSeconds = timeSeconds; self.centre = centre; self.radiusPx = radiusPx
    }
}

public struct SpinOptions: Sendable {
    /// The ball disc is resampled so its radius is about this many pixels; finer rotations become
    /// resolvable, at a cost that grows with the square.
    public var targetUpsampledRadiusPx: Double = 112
    public var maxUpsample: Int = 8
    /// Blocks are taken from inside this fraction of the radius. Near the limb the sphere is seen
    /// at grazing incidence and the texture is compressed into nothing, so the outer rim is useless.
    public var discFraction: Double = 0.80
    public var patchMarginFraction: Double = 1.15
    /// Sets the block-match search radius. A rate above this cannot be measured; it is not a prior.
    public var maxRateRevPerSecond: Double = 8
    public var blockHalfSizeFraction: Double = 0.15      // × upsampled radius
    public var gridStepFraction: Double = 0.15
    public var minBlockNCC: Double = 0.55
    /// A block whose second-best correlation peak is this close to the best is ambiguous (a stripe
    /// sliding along itself, or noise) and is dropped.
    public var peakRatioLimit: Double = 0.92
    public var minInlierBlocks: Int = 12
    public var minDynamicSNR: Double = 2.0
    /// The texture SNR is measured over this much smaller disc. The limb must be excluded: a ball
    /// centre that jitters by a pixel makes the silhouette slide inside the crop, and that crescent
    /// is by far the biggest "moving" thing on a textureless ball. Measured out to 0.8 R it reads
    /// 35–45 on footage whose ball interior is blank.
    public var snrDiscFraction: Double = 0.55
    public var maxResidualFractionOfRadius: Double = 0.03
    public var minPairsFitted: Int = 3
    /// Most frame pairs must produce a fit. When only some do, the matcher is locking onto noise in
    /// the ones that survive, which is how a weak-texture ball produces a confident wrong answer.
    public var minFittedPairFraction: Double = 0.6
    /// The ball's spin barely changes over a shot, so a rate that is not repeatable across frame
    /// pairs is not a measurement. Scatter above this fraction of the rate is refused.
    public var maxRateScatterFraction: Double = 0.35
    public var suppressStaticIllumination: Bool = true
    /// Two extra unknowns that absorb ball-centre error. Off by default: on a disc a uniform shift
    /// is nearly degenerate with ω_x and ω_y (z only ranges 1 → 0.6 over the usable disc), so the
    /// extra freedom raises the normal matrix's condition number from ~2 to ~220 and measurably
    /// *worsens* the recovered axis. Centring error instead shows up as rate error, which is why
    /// the detector's sub-pixel centre matters.
    public var refineTranslation: Bool = false
    /// Warp-and-refine passes after the first fit. Zero reproduces the raw block-matching estimate,
    /// which reads about 10% low because of texture foreshortening; one pass removes most of that.
    public var refinePasses: Int = 1
    /// Flight direction in camera coordinates, if known in 3-D. Without it the direction is taken
    /// from the image track and assumed parallel to the image plane, and a warning says so.
    public var flightDirectionCamera: SIMD3<Double>? = nil
    /// Camera pitch above horizontal, radians. Fixes where "up" is, which fixes the backspin axis.
    public var cameraPitchRadians: Double = 0

    public init() {}
}

// MARK: - Outputs

public struct SpinPairFit: Sendable, Codable {
    public var firstFrame: Int
    public var dtSeconds: Double
    public var omegaRadiansPerFrame: SIMD3<Double>
    public var blocksTried: Int
    public var inliers: Int
    public var residualPx: Double               // in upsampled patch pixels
    public var conditionNumber: Double
}

public struct SpinResult: Sendable, Codable {
    public var rateRevPerSecond: Double?
    public var rateUnavailableReason: String?
    /// Unit spin axis in camera coordinates (x right, y down, z away from camera), right-handed:
    /// the ball turns anticlockwise about it seen from the tip.
    public var axisCamera: SIMD3<Double>?
    public var axisUnavailableReason: String?
    /// 0° = pure backspin (axis horizontal and perpendicular to the flight plane). This is the
    /// number a shooter means by "my rotation is diagonal".
    public var tiltFromBackspinDegrees: Double?
    /// Signed tilt of the axis out of the backspin direction toward vertical (side-spin, the
    /// component that makes the ball curve) and toward the flight direction (rifle spin).
    public var sideTiltDegrees: Double?
    public var rifleTiltDegrees: Double?
    public var backspinFraction: Double?
    public var rateScatterRevPerSecond: Double?
    public var confidence: Double
    public var framesUsed: Int
    public var pairsAttempted: Int
    public var pairsFitted: Int
    public var medianInliers: Int
    public var medianResidualPx: Double
    /// RMS of the *moving* part of the ball's appearance divided by an estimate of the per-pixel
    /// noise, both at native resolution inside the disc. The feasibility number: below ~2 there is
    /// no texture to track and no rate is reported.
    public var dynamicTextureSNR: Double
    /// Fraction of the ball's image structure that does not move with the ball — shading and the
    /// specular highlight. Near 1 means the ball is a lit blob.
    public var staticStructureFraction: Double
    public var ballDiameterPx: Double
    public var effectiveFrameRate: Double
    public var degreesPerFrame: Double?
    public var warnings: [String]
    public var perPair: [SpinPairFit]
}

// MARK: - Tracker

public enum SpinTracker {

    /// Measures ball spin from consecutive frames and the ball track.
    ///
    /// `frames[i]` must be the image the ball position `track[i]` was measured in, and the two
    /// arrays must be the same length and in time order. Returns nil only when the input cannot
    /// support any statement at all (fewer than three usable samples); every other refusal comes
    /// back as a `SpinResult` whose `rateRevPerSecond` is nil next to a `rateUnavailableReason`.
    public static func measure(frames: [SpinGrayImage],
                               track: [SpinSample],
                               options: SpinOptions = SpinOptions()) -> SpinResult? {
        guard frames.count == track.count, track.count >= 3 else { return nil }
        var warnings: [String] = []

        // --- Geometry of the window -------------------------------------------------------------
        let radii = track.map(\.radiusPx).sorted()
        let radius = radii[radii.count / 2]
        guard radius >= 6 else { return nil }
        var dts: [Double] = []
        for i in 1..<track.count { dts.append(track[i].timeSeconds - track[i - 1].timeSeconds) }
        let dt = dts.sorted()[dts.count / 2]
        guard dt > 0 else { return nil }
        let fps = 1.0 / dt

        let upsample = max(1, min(options.maxUpsample, Int((options.targetUpsampledRadiusPx / radius).rounded())))
        let fineRadius = radius * Double(upsample)
        let half = Int(ceil(radius * options.patchMarginFraction))
        let coarseSide = 2 * half
        let fineSide = coarseSide * upsample

        // --- Resample every frame onto a ball-centred patch, coarse (native) and fine (upsampled).
        var coarse: [[Float]] = [], fine: [[Float]] = [], validFine: [[Bool]] = []
        var usable: [Int] = []
        for (i, s) in track.enumerated() {
            guard let (c, f, v) = patches(image: frames[i], centre: s.centre, half: half,
                                          upsample: upsample, side: coarseSide) else { continue }
            coarse.append(c); fine.append(f); validFine.append(v); usable.append(i)
        }
        guard usable.count >= 3 else { return nil }

        // --- Remove shading, then remove whatever does not move with the ball --------------------
        // The blur radius is a quarter of the ball: big enough to leave seams and a logo alone,
        // small enough to flatten the lighting gradient across the sphere.
        let coarseBlur = max(2, Int((radius * 0.25).rounded()))
        let fineBlur = max(2, Int((fineRadius * 0.25).rounded()))
        for k in 0..<coarse.count {
            coarse[k] = highPass(coarse[k], side: coarseSide, blurRadius: coarseBlur)
            fine[k] = highPass(fine[k], side: fineSide, blurRadius: fineBlur)
        }
        let staticCoarse = temporalMedian(coarse, count: coarseSide * coarseSide)
        let staticFine = temporalMedian(fine, count: fineSide * fineSide)
        if options.suppressStaticIllumination {
            for k in 0..<fine.count {
                for p in 0..<fine[k].count { fine[k][p] -= staticFine[p] }
            }
        }

        // --- Feasibility: is there any moving texture, and is it above the noise? ----------------
        let discMaskCoarse = discMask(side: coarseSide, radius: radius * options.snrDiscFraction)
        var dynamicSum = 0.0
        for k in 0..<coarse.count {
            var acc = 0.0, n = 0
            for p in 0..<coarse[k].count where discMaskCoarse[p] {
                let d = Double(coarse[k][p] - staticCoarse[p]); acc += d * d; n += 1
            }
            if n > 0 { dynamicSum += sqrt(acc / Double(n)) }
        }
        let dynamicRMS = dynamicSum / Double(coarse.count)
        var staticAcc = 0.0, staticN = 0
        for p in 0..<staticCoarse.count where discMaskCoarse[p] {
            staticAcc += Double(staticCoarse[p] * staticCoarse[p]); staticN += 1
        }
        let staticRMS = staticN > 0 ? sqrt(staticAcc / Double(staticN)) : 0
        let noise = max(0.3, noiseSigma(coarse: frames, track: track, usable: usable, half: half, options: options))
        let snr = dynamicRMS / noise
        let staticFraction = (staticRMS + dynamicRMS) > 0 ? staticRMS / (staticRMS + dynamicRMS) : 1

        let diameter = 2 * radius
        var result = SpinResult(rateRevPerSecond: nil, rateUnavailableReason: nil,
                                axisCamera: nil, axisUnavailableReason: nil,
                                tiltFromBackspinDegrees: nil, sideTiltDegrees: nil,
                                rifleTiltDegrees: nil, backspinFraction: nil,
                                rateScatterRevPerSecond: nil, confidence: 0,
                                framesUsed: usable.count, pairsAttempted: 0, pairsFitted: 0,
                                medianInliers: 0, medianResidualPx: 0,
                                dynamicTextureSNR: snr, staticStructureFraction: staticFraction,
                                ballDiameterPx: diameter, effectiveFrameRate: fps,
                                degreesPerFrame: nil, warnings: [], perPair: [])

        if staticFraction > 0.85 {
            warnings.append(String(format: "%.0f%% of the ball's image structure is static (shading and specular highlight), not surface texture",
                                   staticFraction * 100))
        }
        var translationPerFrame = 0.0
        for i in 1..<track.count { translationPerFrame += simd_length(track[i].centre - track[i - 1].centre) }
        translationPerFrame /= Double(track.count - 1)
        if translationPerFrame > 0.45 * radius {
            warnings.append(String(format: "ball moves %.0f px per frame (%.2f× its radius): expect motion blur along the flight direction",
                                   translationPerFrame, translationPerFrame / radius))
        }
        if diameter < 40 {
            warnings.append(String(format: "ball is only %.0f px across; seam lines are near or below one pixel wide", diameter))
        }

        if snr < options.minDynamicSNR {
            let reason = String(format: "ball texture too weak to track: moving image structure is %.2f× the pixel noise (need %.1f×) on a %.0f px ball — at this exposure the seams are not resolved",
                                snr, options.minDynamicSNR, diameter)
            result.rateUnavailableReason = reason
            result.axisUnavailableReason = reason
            result.warnings = warnings
            return result
        }

        // --- Per-pair rigid-sphere fit ------------------------------------------------------------
        let maxOmega = 2 * Double.pi * options.maxRateRevPerSecond / fps       // rad/frame
        let searchFine = Int(ceil(maxOmega * fineRadius)) + upsample + 2
        var pairs: [SpinPairFit] = []
        for k in 1..<fine.count {
            guard usable[k] - usable[k - 1] == 1 else { continue }              // consecutive only
            result.pairsAttempted += 1
            let flow = matchBlocks(a: fine[k - 1], b: fine[k],
                                   validA: validFine[k - 1], validB: validFine[k],
                                   side: fineSide, radius: fineRadius, searchRadius: searchFine,
                                   options: options)
            guard var fit = fitAngularVelocity(flow, radius: fineRadius, options: options) else { continue }
            // Warp-and-refine. A block matched rigidly across a rotating sphere is systematically
            // short: the texture inside it is compressed as it swings toward the limb, and the best
            // rigid alignment of a compressed target sits inside the true displacement. Undoing the
            // estimated rotation first removes that compression, so the leftover match is a small,
            // unbiased correction. One pass takes the rate bias from about −10% to a few per cent.
            if options.refinePasses > 0, simd_length(fit.omega) > 1e-9 {
                for _ in 0..<options.refinePasses {
                    let q = simd_quatd(angle: simd_length(fit.omega), axis: simd_normalize(fit.omega))
                    let (warped, warpedValid) = warpSphere(fine[k], valid: validFine[k],
                                                           side: fineSide, radius: fineRadius, rotation: q)
                    let residualFlow = matchBlocks(a: fine[k - 1], b: warped,
                                                   validA: validFine[k - 1], validB: warpedValid,
                                                   side: fineSide, radius: fineRadius,
                                                   searchRadius: searchFine, options: options,
                                                   fineOnlySearch: 6)
                    guard let delta = fitAngularVelocity(residualFlow, radius: fineRadius, options: options),
                          delta.inliers >= options.minInlierBlocks else { break }
                    fit = OmegaFit(omega: fit.omega + delta.omega, inliers: delta.inliers,
                                   residualPx: delta.residualPx, condition: delta.condition)
                }
            }
            guard fit.inliers >= options.minInlierBlocks,
                  fit.residualPx <= options.maxResidualFractionOfRadius * fineRadius,
                  simd_length(fit.omega) <= maxOmega * 1.05 else {
                pairs.append(SpinPairFit(firstFrame: usable[k - 1], dtSeconds: dt,
                                         omegaRadiansPerFrame: fit.omega, blocksTried: flow.count,
                                         inliers: fit.inliers, residualPx: fit.residualPx,
                                         conditionNumber: fit.condition))
                continue
            }
            pairs.append(SpinPairFit(firstFrame: usable[k - 1], dtSeconds: dt,
                                     omegaRadiansPerFrame: fit.omega, blocksTried: flow.count,
                                     inliers: fit.inliers, residualPx: fit.residualPx,
                                     conditionNumber: fit.condition))
            result.pairsFitted += 1
        }
        result.perPair = pairs

        let good = pairs.filter { $0.inliers >= options.minInlierBlocks
                                  && $0.residualPx <= options.maxResidualFractionOfRadius * fineRadius }
        result.medianInliers = good.isEmpty ? 0 : good.map(\.inliers).sorted()[good.count / 2]
        result.medianResidualPx = good.isEmpty ? 0 : good.map(\.residualPx).sorted()[good.count / 2]

        if good.count < options.minPairsFitted
            || Double(good.count) < options.minFittedPairFraction * Double(max(1, result.pairsAttempted)) {
            let reason = String(format: "only %d of %d frame pairs produced a usable rigid-sphere fit (need %d and %.0f%%): not enough matchable surface patches",
                                good.count, result.pairsAttempted, options.minPairsFitted,
                                options.minFittedPairFraction * 100)
            result.rateUnavailableReason = reason
            result.axisUnavailableReason = reason
            result.warnings = warnings
            return result
        }

        // --- Aggregate: component-wise median of ω over pairs, then rate and axis ----------------
        let omega = SIMD3<Double>(median(good.map { $0.omegaRadiansPerFrame.x }),
                                  median(good.map { $0.omegaRadiansPerFrame.y }),
                                  median(good.map { $0.omegaRadiansPerFrame.z }))
        let mag = simd_length(omega)
        guard mag > 1e-6 else {
            let reason = "fitted angular velocity is indistinguishable from zero"
            result.rateUnavailableReason = reason
            result.axisUnavailableReason = reason
            result.warnings = warnings
            return result
        }
        let rate = mag * fps / (2 * Double.pi)
        let perPairRates = good.map { simd_length($0.omegaRadiansPerFrame) * fps / (2 * Double.pi) }
        let scatter = 1.4826 * median(perPairRates.map { abs($0 - median(perPairRates)) })
        if scatter > options.maxRateScatterFraction * rate {
            let reason = String(format: "rate is not repeatable: %.2f rev/s with %.2f rev/s scatter across %d frame pairs (%.0f%%, limit %.0f%%)",
                                rate, scatter, good.count, 100 * scatter / rate, 100 * options.maxRateScatterFraction)
            result.rateUnavailableReason = reason
            result.axisUnavailableReason = reason
            result.warnings = warnings
            return result
        }
        result.rateRevPerSecond = rate
        result.rateScatterRevPerSecond = scatter
        result.degreesPerFrame = mag * 180 / .pi
        result.axisCamera = omega / mag

        if mag * 180 / .pi < 1.0 {
            warnings.append(String(format: "only %.2f° of rotation per frame: the axis direction is poorly determined at this frame rate",
                                   mag * 180 / .pi))
        }
        if scatter > 0.35 * rate {
            warnings.append(String(format: "rate scatters %.2f rev/s across frame pairs (%.0f%% of the value)", scatter, 100 * scatter / rate))
        }

        // --- Express the axis against the flight direction ----------------------------------------
        let up = simd_normalize(SIMD3<Double>(0, -cos(options.cameraPitchRadians), sin(options.cameraPitchRadians)))
        var flight: SIMD3<Double>
        if let f = options.flightDirectionCamera, simd_length(f) > 1e-9 {
            flight = simd_normalize(f)
        } else {
            var d = SIMD2<Double>(0, 0)
            for i in 1..<track.count { d += track[i].centre - track[i - 1].centre }
            guard simd_length(d) > 1e-6 else {
                result.axisUnavailableReason = "ball does not move across the frame, so there is no flight direction to measure the axis against"
                result.warnings = warnings
                result.confidence = confidenceScore(snr: snr, good: good, radius: fineRadius, options: options)
                return result
            }
            d = simd_normalize(d)
            flight = SIMD3<Double>(d.x, d.y, 0)
            warnings.append("flight direction taken from the image track and assumed parallel to the image plane; a shot travelling toward or away from the camera will bias the tilt")
        }
        let backspinAxis = simd_cross(flight, up)
        guard simd_length(backspinAxis) > 1e-6 else {
            result.axisUnavailableReason = "flight direction is parallel to the camera's up direction; the backspin axis is undefined"
            result.warnings = warnings
            result.confidence = confidenceScore(snr: snr, good: good, radius: fineRadius, options: options)
            return result
        }
        let eB = simd_normalize(backspinAxis)                  // pure backspin points along +eB
        let eT = flight                                         // rifle spin
        let eV = simd_normalize(simd_cross(eB, eT))             // side spin (curve)
        let a = omega / mag
        let cB = simd_dot(a, eB), cV = simd_dot(a, eV), cT = simd_dot(a, eT)
        result.backspinFraction = cB
        result.tiltFromBackspinDegrees = acos(max(-1, min(1, abs(cB)))) * 180 / .pi
        result.sideTiltDegrees = atan2(cV, cB) * 180 / .pi
        result.rifleTiltDegrees = atan2(cT, cB) * 180 / .pi
        if cB < 0 {
            warnings.append("axis points against the backspin direction: this reads as top-spin, which is unusual for a shot and is worth checking against the overlay")
        }

        result.confidence = confidenceScore(snr: snr, good: good, radius: fineRadius, options: options)
        result.warnings = warnings
        return result
    }

    private static func confidenceScore(snr: Double, good: [SpinPairFit], radius: Double, options: SpinOptions) -> Double {
        let s = min(1, max(0, (snr - options.minDynamicSNR) / 6))
        let inl = min(1, Double(good.map(\.inliers).reduce(0, +)) / Double(max(1, good.count)) / 40)
        let res = min(1, max(0, 1 - median(good.map(\.residualPx)) / (options.maxResidualFractionOfRadius * radius)))
        let cond = min(1, max(0, 1 - (median(good.map(\.conditionNumber)) - 10) / 200))
        let pairs = min(1, Double(good.count) / 10)
        return pow(s * inl * res * cond * pairs, 1.0 / 5.0)
    }

    // MARK: Patch extraction

    /// Ball-centred square patches at native resolution and at `upsample`×. The fine patch carries
    /// a validity mask so blocks that reach outside the frame can be dropped instead of matched
    /// against replicated edge pixels.
    private static func patches(image: SpinGrayImage, centre: SIMD2<Double>, half: Int,
                                upsample: Int, side: Int) -> ([Float], [Float], [Bool])? {
        var c = [Float](repeating: 0, count: side * side)
        var okCount = 0
        for py in 0..<side {
            let sy = centre.y - Double(half) + Double(py) + 0.5
            for px in 0..<side {
                let sx = centre.x - Double(half) + Double(px) + 0.5
                if let v = image.sample(sourceX: sx, sourceY: sy) { c[py * side + px] = v; okCount += 1 }
            }
        }
        guard okCount > side * side / 2 else { return nil }
        let fs = side * upsample
        var f = [Float](repeating: 0, count: fs * fs)
        var valid = [Bool](repeating: false, count: fs * fs)
        let step = 1.0 / Double(upsample)
        for py in 0..<fs {
            let sy = centre.y - Double(half) + (Double(py) + 0.5) * step
            for px in 0..<fs {
                let sx = centre.x - Double(half) + (Double(px) + 0.5) * step
                if let v = image.sample(sourceX: sx, sourceY: sy) { f[py * fs + px] = v; valid[py * fs + px] = true }
            }
        }
        return (c, f, valid)
    }

    /// Image minus a box-blurred copy of itself: kills the lighting gradient across the sphere and
    /// the mean level, keeps seams and panel edges. Three box passes approximate a Gaussian.
    private static func highPass(_ src: [Float], side: Int, blurRadius: Int) -> [Float] {
        var blurred = src
        for _ in 0..<3 { blurred = boxBlur(blurred, side: side, radius: blurRadius) }
        var out = [Float](repeating: 0, count: src.count)
        for i in 0..<src.count { out[i] = src[i] - blurred[i] }
        return out
    }

    private static func boxBlur(_ src: [Float], side: Int, radius: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        let n = Float(2 * radius + 1)
        for y in 0..<side {
            var acc: Float = 0
            let row = y * side
            for x in -radius...radius { acc += src[row + min(side - 1, max(0, x))] }
            for x in 0..<side {
                tmp[row + x] = acc / n
                acc += src[row + min(side - 1, x + radius + 1)] - src[row + max(0, x - radius)]
            }
        }
        for x in 0..<side {
            var acc: Float = 0
            for y in -radius...radius { acc += tmp[min(side - 1, max(0, y)) * side + x] }
            for y in 0..<side {
                out[y * side + x] = acc / n
                acc += tmp[min(side - 1, y + radius + 1) * side + x] - tmp[max(0, y - radius) * side + x]
            }
        }
        return out
    }

    /// Per-pixel temporal median of the centre-aligned patches. Because the texture rotates and the
    /// lighting does not, this is the static component: shading plus the specular highlight.
    private static func temporalMedian(_ stack: [[Float]], count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        var column = [Float](repeating: 0, count: stack.count)
        for p in 0..<count {
            for k in 0..<stack.count { column[k] = stack[k][p] }
            column.sort()
            out[p] = column[column.count / 2]
        }
        return out
    }

    private static func discMask(side: Int, radius: Double) -> [Bool] {
        var m = [Bool](repeating: false, count: side * side)
        let c = Double(side) / 2
        for y in 0..<side {
            let dy = Double(y) + 0.5 - c
            for x in 0..<side {
                let dx = Double(x) + 0.5 - c
                m[y * side + x] = dx * dx + dy * dy <= radius * radius
            }
        }
        return m
    }

    /// Immerkær's Laplacian estimate of additive noise, taken on native-resolution ball pixels so
    /// the resampling does not correlate neighbouring samples and flatter the number. Fine texture
    /// inflates it, which makes the feasibility gate conservative rather than optimistic.
    private static func noiseSigma(coarse frames: [SpinGrayImage], track: [SpinSample],
                                   usable: [Int], half: Int, options: SpinOptions) -> Double {
        var acc = 0.0, n = 0
        for i in usable {
            let img = frames[i], s = track[i]
            let r = Int(s.radiusPx * options.snrDiscFraction)
            let cx = Int(s.centre.x.rounded()), cy = Int(s.centre.y.rounded())
            for y in max(1, cy - r)..<min(img.height + img.originY - 1, cy + r) {
                for x in max(1, cx - r)..<min(img.width + img.originX - 1, cx + r) {
                    let lx = x - img.originX, ly = y - img.originY
                    guard lx >= 1, ly >= 1, lx < img.width - 1, ly < img.height - 1 else { continue }
                    let p = ly * img.width + lx
                    let v = 4 * img.pixels[p]
                        - 2 * (img.pixels[p - 1] + img.pixels[p + 1] + img.pixels[p - img.width] + img.pixels[p + img.width])
                        + img.pixels[p - img.width - 1] + img.pixels[p - img.width + 1]
                        + img.pixels[p + img.width - 1] + img.pixels[p + img.width + 1]
                    acc += Double(abs(v)); n += 1
                }
            }
            if n > 200_000 { break }
        }
        guard n > 0 else { return 1 }
        return sqrt(Double.pi / 2) * acc / (6 * Double(n))
    }

    // MARK: Block matching

    struct FlowSample { var x: Double; var y: Double; var z: Double; var fx: Double; var fy: Double; var weight: Double }

    /// Normalised cross-correlation block match from patch `a` into patch `b`, coarse-to-fine so
    /// the search stays affordable: an integer search on a 4×-decimated copy, then a small integer
    /// search at full resolution, then a parabolic sub-pixel peak. Displacements come back in units
    /// of the ball radius, together with the starting position on the unit disc.
    private static func matchBlocks(a: [Float], b: [Float], validA: [Bool], validB: [Bool],
                                    side: Int, radius: Double, searchRadius: Int,
                                    options: SpinOptions, fineOnlySearch: Int? = nil) -> [FlowSample] {
        let decim = 4
        let dSide = side / decim
        guard dSide > 8 else { return [] }
        let skipCoarse = fineOnlySearch != nil
        let aD = skipCoarse ? [] : decimate(a, side: side, by: decim)
        let bD = skipCoarse ? [] : decimate(b, side: side, by: decim)
        let vD = skipCoarse ? [] : decimateValid(validB, side: side, by: decim)

        let bh = max(4, Int((radius * options.blockHalfSizeFraction).rounded()))
        let step = max(4, Int((radius * options.gridStepFraction).rounded()))
        let inner = radius * options.discFraction
        let centre = Double(side) / 2
        let bhD = max(2, bh / decim)
        let searchD = searchRadius / decim + 2

        var out: [FlowSample] = []
        var gy = Int(centre - inner)
        while gy <= Int(centre + inner) {
            var gx = Int(centre - inner)
            while gx <= Int(centre + inner) {
                defer { gx += step }
                let nx = (Double(gx) + 0.5 - centre) / radius, ny = (Double(gy) + 0.5 - centre) / radius
                let rr = nx * nx + ny * ny
                if rr > options.discFraction * options.discFraction { continue }
                // The whole block must be real pixels in both frames.
                if !blockValid(validA, side: side, cx: gx, cy: gy, half: bh) { continue }

                // Coarse pass — skipped when the caller has already removed the bulk of the motion.
                var guessX = 0, guessY = 0
                if let _ = fineOnlySearch {
                    // nothing to seed: the warp has already taken the texture back to frame a
                } else {
                    let cxD = gx / decim, cyD = gy / decim
                    guard let c = ncc(aD, bD, side: dSide, cx: cxD, cy: cyD, half: bhD,
                                      search: searchD, validB: vD,
                                      minNCC: options.minBlockNCC * 0.8,
                                      peakRatioLimit: options.peakRatioLimit, excludeRadius: bhD)
                    else { continue }
                    guessX = Int(c.dx.rounded()) * decim
                    guessY = Int(c.dy.rounded()) * decim
                }
                // Fine pass: a small window around the coarse answer. The ambiguity test is not
                // repeated here — inside a window this narrow the correlation surface is one broad
                // lobe by construction, so a "second peak" would mean nothing.
                guard let f = ncc(a, b, side: side, cx: gx, cy: gy, half: bh,
                                  search: fineOnlySearch ?? (decim + 2), validB: validB,
                                  minNCC: options.minBlockNCC, peakRatioLimit: 1.0, excludeRadius: 2,
                                  offsetX: guessX, offsetY: guessY)
                else { continue }

                let z = sqrt(max(0, 1 - rr))
                out.append(FlowSample(x: nx, y: ny, z: z,
                                      fx: f.dx / radius, fy: f.dy / radius, weight: max(0, f.peak)))
            }
            gy += step
        }
        return out
    }

    /// Resamples a ball patch so the sphere's surface appears where it was one rotation `q` earlier:
    /// for each pixel of the *previous* frame's disc, the surface normal is rotated forward and read
    /// from this frame at the position it moved to. Pixels whose surface has swung around the limb
    /// out of sight come back invalid.
    private static func warpSphere(_ src: [Float], valid: [Bool], side: Int, radius: Double,
                                   rotation q: simd_quatd) -> ([Float], [Bool]) {
        var out = [Float](repeating: 0, count: src.count)
        var outValid = [Bool](repeating: false, count: src.count)
        let c = Double(side) / 2
        for py in 0..<side {
            let y = (Double(py) + 0.5 - c) / radius
            for px in 0..<side {
                let x = (Double(px) + 0.5 - c) / radius
                let rr = x * x + y * y
                if rr >= 1 { continue }
                let n = SIMD3<Double>(x, y, -sqrt(1 - rr))
                let m = q.act(n)
                if m.z >= 0 { continue }                       // rotated round to the far side
                let sx = c + m.x * radius - 0.5, sy = c + m.y * radius - 0.5
                let ix = Int(floor(sx)), iy = Int(floor(sy))
                guard ix >= 0, iy >= 0, ix + 1 < side, iy + 1 < side else { continue }
                guard valid[iy * side + ix], valid[iy * side + ix + 1],
                      valid[(iy + 1) * side + ix], valid[(iy + 1) * side + ix + 1] else { continue }
                let fx = Float(sx - Double(ix)), fy = Float(sy - Double(iy))
                let a0 = src[iy * side + ix], a1 = src[iy * side + ix + 1]
                let b0 = src[(iy + 1) * side + ix], b1 = src[(iy + 1) * side + ix + 1]
                out[py * side + px] = (a0 + (a1 - a0) * fx) + ((b0 + (b1 - b0) * fx) - (a0 + (a1 - a0) * fx)) * fy
                outValid[py * side + px] = true
            }
        }
        return (out, outValid)
    }

    private static func blockValid(_ valid: [Bool], side: Int, cx: Int, cy: Int, half: Int) -> Bool {
        guard cx - half >= 0, cy - half >= 0, cx + half < side, cy + half < side else { return false }
        for y in stride(from: cy - half, through: cy + half, by: max(1, half / 2)) {
            for x in stride(from: cx - half, through: cx + half, by: max(1, half / 2)) {
                if !valid[y * side + x] { return false }
            }
        }
        return true
    }

    private static func decimate(_ src: [Float], side: Int, by f: Int) -> [Float] {
        let n = side / f
        var out = [Float](repeating: 0, count: n * n)
        let inv = Float(f * f)
        for y in 0..<n {
            for x in 0..<n {
                var acc: Float = 0
                for j in 0..<f { let row = (y * f + j) * side + x * f; for i in 0..<f { acc += src[row + i] } }
                out[y * n + x] = acc / inv
            }
        }
        return out
    }

    private static func decimateValid(_ src: [Bool], side: Int, by f: Int) -> [Bool] {
        let n = side / f
        var out = [Bool](repeating: true, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                var ok = true
                for j in 0..<f { let row = (y * f + j) * side + x * f; for i in 0..<f where !src[row + i] { ok = false } }
                out[y * n + x] = ok
            }
        }
        return out
    }

    private struct Match { var dx: Double; var dy: Double; var peak: Double }

    /// Zero-mean normalised cross-correlation of one block over an integer search window, with a
    /// parabolic sub-pixel refinement and an ambiguity test: a block whose second peak (outside the
    /// main lobe) rivals the best has no unique match and is rejected.
    private static func ncc(_ a: [Float], _ b: [Float], side: Int, cx: Int, cy: Int, half: Int,
                            search: Int, validB: [Bool], minNCC: Double, peakRatioLimit: Double,
                            excludeRadius: Int = 2, offsetX: Int = 0, offsetY: Int = 0) -> Match? {
        let n = (2 * half + 1) * (2 * half + 1)
        var tmpl = [Double](repeating: 0, count: n)
        var mean = 0.0
        var idx = 0
        for y in (cy - half)...(cy + half) {
            let row = y * side
            for x in (cx - half)...(cx + half) { let v = Double(a[row + x]); tmpl[idx] = v; mean += v; idx += 1 }
        }
        mean /= Double(n)
        var norm = 0.0
        for i in 0..<n { tmpl[i] -= mean; norm += tmpl[i] * tmpl[i] }
        guard norm > 1e-6 else { return nil }
        norm = sqrt(norm)

        let span = 2 * search + 1
        var scores = [Double](repeating: -2, count: span * span)
        for dy in -search...search {
            for dx in -search...search {
                let bx = cx + offsetX + dx, by = cy + offsetY + dy
                guard bx - half >= 0, by - half >= 0, bx + half < side, by + half < side else { continue }
                var m = 0.0, s2 = 0.0, cross = 0.0
                var bad = false
                var i = 0
                for y in (by - half)...(by + half) {
                    let row = y * side
                    for x in (bx - half)...(bx + half) {
                        if !validB[row + x] { bad = true; break }
                        let v = Double(b[row + x]); m += v; s2 += v * v; cross += v * tmpl[i]; i += 1
                    }
                    if bad { break }
                }
                if bad { continue }
                let dn = Double(n)
                let varB = s2 - m * m / dn
                guard varB > 1e-6 else { continue }
                scores[(dy + search) * span + (dx + search)] = cross / (norm * sqrt(varB))
            }
        }
        var best = -2.0, bi = -1
        for i in 0..<scores.count where scores[i] > best { best = scores[i]; bi = i }
        guard bi >= 0, best >= minNCC else { return nil }
        let by0 = bi / span, bx0 = bi % span
        if peakRatioLimit < 1.0 {
            var second = -2.0
            for i in 0..<scores.count {
                let y = i / span, x = i % span
                if abs(y - by0) <= excludeRadius && abs(x - bx0) <= excludeRadius { continue }
                if scores[i] > second { second = scores[i] }
            }
            if second > peakRatioLimit * best { return nil }
        }
        // Parabolic sub-pixel peak; fall back to the integer peak at the search edge.
        func refine(_ m: Double, _ c: Double, _ p: Double) -> Double {
            let d = m - 2 * c + p
            guard abs(d) > 1e-9 else { return 0 }
            return max(-0.5, min(0.5, 0.5 * (m - p) / d))
        }
        var sx = 0.0, sy = 0.0
        if bx0 > 0, bx0 < span - 1, scores[by0 * span + bx0 - 1] > -1.5, scores[by0 * span + bx0 + 1] > -1.5 {
            sx = refine(scores[by0 * span + bx0 - 1], best, scores[by0 * span + bx0 + 1])
        }
        if by0 > 0, by0 < span - 1, scores[(by0 - 1) * span + bx0] > -1.5, scores[(by0 + 1) * span + bx0] > -1.5 {
            sy = refine(scores[(by0 - 1) * span + bx0], best, scores[(by0 + 1) * span + bx0])
        }
        return Match(dx: Double(bx0 - search + offsetX) + sx, dy: Double(by0 - search + offsetY) + sy, peak: best)
    }

    // MARK: Rigid-sphere fit

    struct OmegaFit { var omega: SIMD3<Double>; var inliers: Int; var residualPx: Double; var condition: Double }

    /// Least squares over the projected velocity field of a rotating sphere, reweighted with a
    /// Tukey biweight so a handful of bad matches cannot steer the axis. Two optional unknowns
    /// absorb ball-centre error, which would otherwise leak into ω_x and ω_y.
    private static func fitAngularVelocity(_ flow: [FlowSample], radius: Double, options: SpinOptions) -> OmegaFit? {
        let nUnknown = options.refineTranslation ? 5 : 3
        guard flow.count >= nUnknown + 3 else { return nil }
        var weights = flow.map(\.weight)
        var theta = [Double](repeating: 0, count: nUnknown)
        var condition = Double.infinity

        for iteration in 0..<6 {
            var ata = [Double](repeating: 0, count: nUnknown * nUnknown)
            var atb = [Double](repeating: 0, count: nUnknown)
            for (i, s) in flow.enumerated() {
                let w = weights[i]
                guard w > 0 else { continue }
                // fx = -wy*z - wz*y + tx ;  fy = wz*x + wx*z + ty
                var rowX = [Double](repeating: 0, count: nUnknown)
                var rowY = [Double](repeating: 0, count: nUnknown)
                rowX[1] = -s.z; rowX[2] = -s.y
                rowY[0] = s.z;  rowY[2] = s.x
                if nUnknown == 5 { rowX[3] = 1; rowY[4] = 1 }
                for r in 0..<nUnknown {
                    atb[r] += w * (rowX[r] * s.fx + rowY[r] * s.fy)
                    for c in 0..<nUnknown { ata[r * nUnknown + c] += w * (rowX[r] * rowX[c] + rowY[r] * rowY[c]) }
                }
            }
            guard let sol = solveSPD(ata, atb, n: nUnknown) else { return nil }
            theta = sol
            if iteration == 0 { condition = conditionNumber(ata, n: nUnknown) }

            // Residuals, then Tukey weights on a MAD scale.
            var res = [Double](repeating: 0, count: flow.count)
            for (i, s) in flow.enumerated() {
                let tx = nUnknown == 5 ? theta[3] : 0, ty = nUnknown == 5 ? theta[4] : 0
                let px = -theta[1] * s.z - theta[2] * s.y + tx
                let py = theta[2] * s.x + theta[0] * s.z + ty
                res[i] = hypot(s.fx - px, s.fy - py)
            }
            let med = median(res)
            let scale = max(1e-4, 1.4826 * median(res.map { abs($0 - med) }))
            let c = 4.685 * scale
            for i in 0..<flow.count {
                let u = res[i] / c
                weights[i] = u < 1 ? flow[i].weight * pow(1 - u * u, 2) : 0
            }
        }

        var sumSq = 0.0, inliers = 0
        let tx = nUnknown == 5 ? theta[3] : 0, ty = nUnknown == 5 ? theta[4] : 0
        for (i, s) in flow.enumerated() where weights[i] > 0 {
            let px = -theta[1] * s.z - theta[2] * s.y + tx
            let py = theta[2] * s.x + theta[0] * s.z + ty
            sumSq += pow(s.fx - px, 2) + pow(s.fy - py, 2)
            inliers += 1
        }
        guard inliers >= 3 else { return nil }
        let residual = sqrt(sumSq / Double(2 * inliers)) * radius
        return OmegaFit(omega: SIMD3(theta[0], theta[1], theta[2]), inliers: inliers,
                        residualPx: residual, condition: condition)
    }

    /// Cholesky solve with a small ridge; returns nil if the normal matrix is not positive definite.
    private static func solveSPD(_ aIn: [Double], _ b: [Double], n: Int) -> [Double]? {
        var a = aIn
        var trace = 0.0
        for i in 0..<n { trace += a[i * n + i] }
        let ridge = 1e-9 * max(trace / Double(n), 1e-12)
        for i in 0..<n { a[i * n + i] += ridge }
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var s = a[i * n + j]
                for k in 0..<j { s -= l[i * n + k] * l[j * n + k] }
                if i == j { guard s > 0 else { return nil }; l[i * n + i] = sqrt(s) }
                else { l[i * n + j] = s / l[j * n + j] }
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = b[i]
            for k in 0..<i { s -= l[i * n + k] * y[k] }
            y[i] = s / l[i * n + i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = y[i]
            for k in (i + 1)..<n { s -= l[k * n + i] * x[k] }
            x[i] = s / l[i * n + i]
        }
        return x
    }

    /// Ratio of the extreme eigenvalues of the normal matrix, by cyclic Jacobi. A large value means
    /// the flow samples do not separate the unknowns — typically too few blocks, or all of them
    /// bunched near the limb where z is small and ω_x, ω_y barely act.
    private static func conditionNumber(_ m: [Double], n: Int) -> Double {
        var a = m
        for _ in 0..<40 {
            var off = 0.0
            for p in 0..<n { for q in (p + 1)..<n { off += a[p * n + q] * a[p * n + q] } }
            if off < 1e-18 { break }
            for p in 0..<n {
                for q in (p + 1)..<n {
                    let apq = a[p * n + q]
                    if abs(apq) < 1e-15 { continue }
                    let theta = (a[q * n + q] - a[p * n + p]) / (2 * apq)
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + sqrt(theta * theta + 1))
                    let c = 1 / sqrt(t * t + 1), s = t * c
                    for k in 0..<n {
                        let akp = a[k * n + p], akq = a[k * n + q]
                        a[k * n + p] = c * akp - s * akq
                        a[k * n + q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p * n + k], aqk = a[q * n + k]
                        a[p * n + k] = c * apk - s * aqk
                        a[q * n + k] = s * apk + c * aqk
                    }
                }
            }
        }
        var lo = Double.infinity, hi = 0.0
        for i in 0..<n { let v = abs(a[i * n + i]); lo = min(lo, v); hi = max(hi, v) }
        return lo > 0 ? hi / lo : .infinity
    }

    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }
}

// MARK: - Synthetic ball, for validating the recovery against a known ω

public extension SpinTracker {

    struct SyntheticSpinClip: Sendable {
        public var frames: [SpinGrayImage]
        public var track: [SpinSample]
        public var trueOmegaRadiansPerFrame: SIMD3<Double>
        public var frameRate: Double
    }

    /// Renders a textured sphere rotating with a known angular velocity: three seam great circles
    /// plus band-limited mottle, Lambertian shading with a camera-fixed specular highlight (the
    /// thing that fools naive registration), box motion blur over the exposure, and Gaussian noise.
    /// The ball also translates, and the returned track carries sub-pixel centring error, so the
    /// recovery is tested under the same nuisances as real footage.
    static func renderSyntheticBall(radiusPx: Double,
                                    omegaRadiansPerFrame: SIMD3<Double>,
                                    frameCount: Int,
                                    frameRate: Double = 120,
                                    velocityPxPerFrame: SIMD2<Double> = SIMD2(6, -4),
                                    blurSubsteps: Int = 4,
                                    noiseSigma: Double = 1.5,
                                    centreErrorPx: Double = 0.4,
                                    textureContrast: Double = 1.0,
                                    seed: UInt64 = 1) -> SyntheticSpinClip {
        var rng = SplitMix64(seed: seed)
        // Band-limited surface mottle: a few spherical sinusoids, exact under rotation.
        var bands: [(SIMD3<Double>, Double, Double)] = []
        for _ in 0..<10 {
            let f = simd_normalize(SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian())) * (2 + 3 * rng.uniform())
            bands.append((f, rng.uniform() * 2 * .pi, 0.05 + 0.05 * rng.uniform()))
        }
        func albedo(_ n: SIMD3<Double>) -> Double {
            var v = 0.62
            for axis in [SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1)] {
                let d = abs(simd_dot(n, axis)) / 0.06
                v -= 0.42 * exp(-d * d)
            }
            for (f, p, a) in bands { v += a * sin(simd_dot(f, n) * 3 + p) }
            v = 0.62 + (v - 0.62) * textureContrast
            return max(0.04, min(1.0, v))
        }

        let light = simd_normalize(SIMD3<Double>(-0.55, -0.75, -0.45))
        let halfVec = simd_normalize(light + SIMD3<Double>(0, 0, -1))
        let side = Int((radiusPx * 4 + 48).rounded())
        let start = SIMD2<Double>(Double(side) / 2 - velocityPxPerFrame.x * Double(frameCount) / 2,
                                  Double(side) / 2 - velocityPxPerFrame.y * Double(frameCount) / 2)

        var frames: [SpinGrayImage] = [], track: [SpinSample] = []
        for k in 0..<frameCount {
            var img = [Float](repeating: 0, count: side * side)
            let centre = start + velocityPxPerFrame * Double(k)
            for py in 0..<side {
                for px in 0..<side {
                    var acc = 0.0
                    for sub in 0..<blurSubsteps {
                        let frac = (Double(sub) + 0.5) / Double(blurSubsteps) - 0.5
                        let c = centre + velocityPxPerFrame * frac
                        let angle = simd_length(omegaRadiansPerFrame) * (Double(k) + frac)
                        let q = simd_length(omegaRadiansPerFrame) > 1e-12
                            ? simd_quatd(angle: angle, axis: simd_normalize(omegaRadiansPerFrame))
                            : simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
                        // 2×2 supersample to keep the limb from aliasing.
                        var sample = 0.0
                        for sy in 0..<2 {
                            for sx in 0..<2 {
                                let x = (Double(px) + 0.25 + 0.5 * Double(sx) - c.x) / radiusPx
                                let y = (Double(py) + 0.25 + 0.5 * Double(sy) - c.y) / radiusPx
                                let rr = x * x + y * y
                                if rr >= 1 { sample += 26; continue }
                                let z = sqrt(1 - rr)
                                let nCam = SIMD3<Double>(x, y, -z)
                                let nBody = q.inverse.act(nCam)
                                let ndl = max(0, simd_dot(nCam, light))
                                let spec = 0.55 * pow(max(0, simd_dot(nCam, halfVec)), 40)
                                sample += 255 * min(1, albedo(nBody) * (0.22 + 0.80 * ndl) + spec)
                            }
                        }
                        acc += sample / 4
                    }
                    img[py * side + px] = Float(min(255, max(0, acc / Double(blurSubsteps) + noiseSigma * rng.gaussian())))
                }
            }
            frames.append(SpinGrayImage(width: side, height: side, pixels: img))
            track.append(SpinSample(timeSeconds: Double(k) / frameRate,
                                    centre: centre + SIMD2(centreErrorPx * rng.gaussian(), centreErrorPx * rng.gaussian()),
                                    radiusPx: radiusPx))
        }
        return SyntheticSpinClip(frames: frames, track: track,
                                 trueOmegaRadiansPerFrame: omegaRadiansPerFrame, frameRate: frameRate)
    }

    struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 0x1234_5678 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
        mutating func gaussian() -> Double {
            let u1 = max(1e-12, uniform()), u2 = uniform()
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
    }
}

// MARK: - Debug rendering support

public extension SpinTracker {

    struct SpinPatches: Sendable {
        public var side: Int
        public var upsample: Int
        public var radiusPx: Double             // ball radius in patch pixels
        public var frameIndices: [Int]
        /// Ball-centred, upsampled crops as they came out of the video.
        public var raw: [[Float]]
        /// The same crops high-passed and with the static (illumination) component removed: this is
        /// what the matcher actually sees. A blank disc here means there is no spin signal.
        public var dynamic: [[Float]]
    }

    /// Exposes the intermediate patches so a caller can render a strip and *look* at what the
    /// matcher is being asked to track. Same preprocessing as `measure`.
    static func patchStrip(frames: [SpinGrayImage], track: [SpinSample],
                           options: SpinOptions = SpinOptions()) -> SpinPatches? {
        guard frames.count == track.count, track.count >= 2 else { return nil }
        let radii = track.map(\.radiusPx).sorted()
        let radius = radii[radii.count / 2]
        guard radius >= 6 else { return nil }
        let upsample = max(1, min(options.maxUpsample, Int((options.targetUpsampledRadiusPx / radius).rounded())))
        let half = Int(ceil(radius * options.patchMarginFraction))
        let side = 2 * half * upsample
        var raw: [[Float]] = [], indices: [Int] = []
        for (i, s) in track.enumerated() {
            guard let p = patchesPublic(image: frames[i], centre: s.centre, half: half,
                                        upsample: upsample) else { continue }
            raw.append(p); indices.append(i)
        }
        guard !raw.isEmpty else { return nil }
        let blur = max(2, Int((radius * Double(upsample) * 0.25).rounded()))
        var hp = raw.map { highPassPublic($0, side: side, blurRadius: blur) }
        let stat = temporalMedianPublic(hp, count: side * side)
        if options.suppressStaticIllumination {
            for k in 0..<hp.count { for p in 0..<hp[k].count { hp[k][p] -= stat[p] } }
        }
        return SpinPatches(side: side, upsample: upsample, radiusPx: radius * Double(upsample),
                           frameIndices: indices, raw: raw, dynamic: hp)
    }

    private static func patchesPublic(image: SpinGrayImage, centre: SIMD2<Double>,
                                      half: Int, upsample: Int) -> [Float]? {
        let fs = 2 * half * upsample
        var f = [Float](repeating: 0, count: fs * fs)
        let step = 1.0 / Double(upsample)
        var ok = 0
        for py in 0..<fs {
            let sy = centre.y - Double(half) + (Double(py) + 0.5) * step
            for px in 0..<fs {
                let sx = centre.x - Double(half) + (Double(px) + 0.5) * step
                if let v = image.sample(sourceX: sx, sourceY: sy) { f[py * fs + px] = v; ok += 1 }
            }
        }
        return ok > fs * fs / 2 ? f : nil
    }

    private static func highPassPublic(_ src: [Float], side: Int, blurRadius: Int) -> [Float] {
        var blurred = src
        for _ in 0..<3 { blurred = boxBlurPublic(blurred, side: side, radius: blurRadius) }
        var out = [Float](repeating: 0, count: src.count)
        for i in 0..<src.count { out[i] = src[i] - blurred[i] }
        return out
    }

    private static func boxBlurPublic(_ src: [Float], side: Int, radius: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        let n = Float(2 * radius + 1)
        for y in 0..<side {
            var acc: Float = 0
            let row = y * side
            for x in -radius...radius { acc += src[row + min(side - 1, max(0, x))] }
            for x in 0..<side {
                tmp[row + x] = acc / n
                acc += src[row + min(side - 1, x + radius + 1)] - src[row + max(0, x - radius)]
            }
        }
        for x in 0..<side {
            var acc: Float = 0
            for y in -radius...radius { acc += tmp[min(side - 1, max(0, y)) * side + x] }
            for y in 0..<side {
                out[y * side + x] = acc / n
                acc += tmp[min(side - 1, y + radius + 1) * side + x] - tmp[max(0, y - radius) * side + x]
            }
        }
        return out
    }

    private static func temporalMedianPublic(_ stack: [[Float]], count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        var column = [Float](repeating: 0, count: stack.count)
        for p in 0..<count {
            for k in 0..<stack.count { column[k] = stack[k][p] }
            column.sort()
            out[p] = column[column.count / 2]
        }
        return out
    }
}
