import Foundation

//  JumpTest.swift — the vertical jump test's arithmetic (1.4, 2026-09-19)
//
//  Two independent measurements of the same jump, and an honest comparison of the two.
//
//  * **Method A — flight time.** The feet leave a baseline and come back to it. Between those two
//    instants the body is a projectile, so the rise of its centre of mass is `g·t²/8`. It needs no
//    scale at all: the only measuring instrument is the frame clock, which is why it is the primary
//    method here and the one a contact mat uses.
//  * **Method B — hip rise.** How far the mid-hip travelled up the image, converted to metres by a
//    stated scale. It needs a scale, it carries that scale's error, and it reads *low* because the
//    legs tuck in the air: the hips do not travel as far as the centre of mass does. It is a
//    cross-check, never the headline.
//
//  Units: metres and seconds in code. Pixels stay pixels and are named so. Nothing here converts to
//  centimetres or inches — that happens at the UI boundary.
//
//  Foundation only (CLAUDE.md rule 2). No Vision, no AVFoundation: the input is a `BodyTimeline`,
//  which `ShotVideo` produces and this layer only reads.

public enum VerticalJump {

    /// Standard gravity, 9.80665 m/s² rounded to the 9.81 the rest of the app uses.
    ///
    /// **This is a constant, not a fit, and it does not break CLAUDE.md rule 3.** That rule says g is
    /// the *check* in `TrajectoryFit`: there, g falls out of a fitted parabola and is compared with
    /// 9.81 as evidence that the fit and the calibration are sound. Nothing is fitted here. Flight
    /// time is measured directly off the frame clock, and g is the textbook constant that turns a
    /// measured time into a height. There is no free parameter for a wrong scale to hide in — which
    /// is exactly why the flight-time method is the primary one.
    public static let standardGravity = 9.81

    // MARK: - Pulling the two signals out of a body timeline

    public struct SeriesOptions: Sendable {
        /// Confidence floor for a 2-D point, the same 0.30 the body model uses for Apple's body pose.
        public var minimumConfidence: Double = 0.30
        public init() {}
    }

    /// The two vertical signals a jump is measured from, on the **real** clock, in up-positive pixels.
    ///
    /// Image `v` grows downwards (NOTATION.md), so "up" is `−v` throughout; the absolute offset does
    /// not matter because every number below is a difference.
    public struct JumpSeries: Sendable, Codable {
        /// Real seconds, strictly increasing.
        public var times: [Double]
        /// The **lower** of the two ankles on each frame, up-positive. The lower foot is the one still
        /// on the floor, so this signal leaves the baseline when the *last* foot leaves and returns
        /// when the *first* foot lands — which is the definition of flight time.
        public var footUpPixels: [Double]
        /// Mid-hip, up-positive. Empty when no frame carried both hips.
        public var hipUpPixels: [Double]
        /// The 90th-percentile ankle-to-nose pixel span over the window — the body model's own ruler.
        /// Nil when no frame carried both a nose and an ankle.
        public var ankleToNosePixels: Double?
        public var framesWithFoot: Int
        public var framesTotal: Int
        public var notes: [String]
        public init(times: [Double], footUpPixels: [Double], hipUpPixels: [Double],
                    ankleToNosePixels: Double?, framesWithFoot: Int, framesTotal: Int, notes: [String]) {
            self.times = times; self.footUpPixels = footUpPixels; self.hipUpPixels = hipUpPixels
            self.ankleToNosePixels = ankleToNosePixels
            self.framesWithFoot = framesWithFoot; self.framesTotal = framesTotal; self.notes = notes
        }
    }

    /// Read the foot and hip signals off a tracked window. Frames with no usable ankle are dropped,
    /// not interpolated — a gap is evidence, and `flightTime` refuses to interpolate across one.
    public static func series(from timeline: BodyTimeline, options: SeriesOptions = SeriesOptions()) -> JumpSeries {
        var times: [Double] = [], feet: [Double] = [], hips: [Double] = []
        var spans: [Double] = []
        var notes: [String] = []
        var oneAnkleFrames = 0

        for f in timeline.frames.sorted(by: { $0.realTime < $1.realTime }) {
            func point(_ name: String) -> BodyPoint2D? {
                guard let p = f.points2D[name], p.confidence >= options.minimumConfidence else { return nil }
                return p
            }
            let la = point(Body2DPoint.leftAnkle), ra = point(Body2DPoint.rightAnkle)
            // Up-positive: −v. The lower foot in the picture is the larger v, so the smaller −v.
            let ankleUps = [la, ra].compactMap { $0.map { -$0.v } }
            if !ankleUps.isEmpty {
                if ankleUps.count == 1 { oneAnkleFrames += 1 }
                // `times` must stay strictly increasing for everything downstream.
                if let last = times.last, f.realTime <= last { continue }
                times.append(f.realTime)
                feet.append(ankleUps.min() ?? 0)
                if let lh = point(Body2DPoint.leftHip), let rh = point(Body2DPoint.rightHip) {
                    hips.append(-(lh.v + rh.v) / 2)
                } else {
                    hips.append(.nan)
                }
                if let nose = point(Body2DPoint.nose) {
                    let ankleV = ([la, ra].compactMap { $0?.v }.reduce(0, +)) / Double(ankleUps.count)
                    spans.append(abs(ankleV - nose.v))
                }
            }
        }
        if oneAnkleFrames > 0 {
            notes.append("\(oneAnkleFrames) of \(times.count) frames showed only one ankle, so on those the foot signal is that ankle alone.")
        }
        if hips.contains(where: { $0.isNaN }) {
            let missing = hips.filter { $0.isNaN }.count
            notes.append("\(missing) of \(times.count) frames had no hip pair, so the hip-rise cross-check skips them.")
        }
        let span: Double? = spans.isEmpty ? nil : percentile(spans, 0.90)
        if span == nil { notes.append("No frame carried both a nose and an ankle, so this window has no body ruler.") }
        return JumpSeries(times: times, footUpPixels: feet, hipUpPixels: hips, ankleToNosePixels: span,
                          framesWithFoot: times.count, framesTotal: timeline.frames.count, notes: notes)
    }

    // MARK: - Method A: flight time

    public struct FlightTimeOptions: Sendable {
        /// Below this the frame clock is too coarse: at 60 fps a ±1-frame edge is ±17 ms, which on a
        /// half-second flight is already ±2 cm of height before anything else goes wrong.
        public var minimumFrameRate: Double = 120
        /// Shorter than this and it is a shuffle, not a jump (150 ms of flight is 2.8 cm).
        public var minimumFlightSeconds: Double = 0.15
        /// Longer than this and something other than a jump is being measured (1.2 s is 1.77 m).
        public var maximumFlightSeconds: Double = 1.2
        /// Take-off and landing are read where the foot signal leaves the floor by this many standard
        /// deviations of the floor's own tracker noise. **As low as the noise allows, on purpose**: the
        /// true take-off is where the foot signal leaves the baseline, so every pixel of threshold
        /// makes the flight read short. `thresholdBiasMetres` says how much that costs on this clip.
        public var thresholdNoiseSigmas: Double = 4
        /// A floor under the threshold in pixels, for a clip with no measurable jitter at all.
        public var thresholdFloorPixels: Double = 2
        /// If the noise forces the threshold above this fraction of the whole foot rise, the clip is
        /// too jittery to read a take-off off and the measurement is refused.
        public var thresholdMaximumFractionOfPeakRise: Double = 0.25
        /// The peak must clear the baseline by this many sigmas before the signal is called a jump.
        public var minimumPeakRiseSigmas: Double = 8
        /// A crossing that does not stay on the other side for this long is chatter, not an edge.
        public var chatterDwellSeconds: Double = 0.02
        /// How far the interpolated edge may be from a real sample: 1 frame each side.
        public var edgeUncertaintyFrames: Double = 1
        /// The widest sample gap an edge may be interpolated across, in median frame intervals.
        public var maximumEdgeGapFrames: Double = 2
        public init() {}
    }

    /// One jump measured from flight time. Every field is measured or derived from measured values.
    public struct FlightTimeJump: Sendable, Codable {
        public var takeOffSeconds: Double
        public var landingSeconds: Double
        public var flightSeconds: Double
        /// ±, one standard uncertainty, from the frame clock alone.
        public var flightSecondsUncertainty: Double
        public var heightMetres: Double
        /// ±, propagated from `flightSecondsUncertainty`.
        public var heightUncertaintyMetres: Double
        /// Measured from the sample times, not assumed.
        public var frameRate: Double
        public var samplingIntervalSeconds: Double
        /// Pixels: how far the lower foot rose above the standing baseline at its peak.
        public var peakRisePixels: Double
        public var baselineNoisePixels: Double
        public var thresholdRisePixels: Double
        /// **One-sided, and the height reads LOW by up to this much.** Take-off is read a fraction of
        /// a frame late and landing a fraction early, because the threshold sits above the floor
        /// rather than on it. If the foot were ballistic between the threshold and its peak the true
        /// flight would be `t/√(1−f)` with `f` the threshold's share of the peak rise, and this is the
        /// height that correction would add. The reported height is **not** corrected by it — a real
        /// ankle tucks in the air and is not ballistic — so it is published as a known one-sided bound
        /// instead of being quietly applied.
        public var thresholdBiasMetres: Double
        public var notes: [String]

        /// A conservative bound on this jump, in metres: the random ±1-frame error plus the one-sided
        /// threshold bias. A plain sum, not a quadrature — one of the two is a bias, not a sigma.
        public var totalUncertaintyMetres: Double { heightUncertaintyMetres + thresholdBiasMetres }
    }

    /// A flight-time measurement, or the reason there is not one. Never both, never neither.
    public struct FlightTimeMeasurement: Sendable, Codable {
        public var jump: FlightTimeJump?
        public var unavailableReason: String?
        public init(jump: FlightTimeJump) { self.jump = jump; self.unavailableReason = nil }
        public init(unavailable reason: String) { self.jump = nil; self.unavailableReason = reason }
    }

    /// Height from flight time: `h = g·t²/8`.
    ///
    /// Why /8 and not /2: the body leaves the floor at `v₀ = g·t/2` (it is airborne for `t`, half of
    /// it rising), and `v₀²/2g = g·t²/8`.
    ///
    /// - Parameters:
    ///   - times: real seconds, strictly increasing.
    ///   - footUpPixels: the lower foot's height, up-positive, same length as `times`.
    public static func flightTime(times: [Double], footUpPixels: [Double],
                                  options: FlightTimeOptions = FlightTimeOptions()) -> FlightTimeMeasurement {
        guard times.count == footUpPixels.count else {
            return .init(unavailable: "the time and foot-height series are different lengths, so nothing can be read off them")
        }
        guard times.count >= 8 else {
            return .init(unavailable: "only \(times.count) frames carried a foot, which is too few to find a take-off and a landing")
        }
        var intervals: [Double] = []
        for i in 1..<times.count {
            let dt = times[i] - times[i - 1]
            guard dt > 0 else { return .init(unavailable: "the frame times are not in order, so the clock cannot be trusted") }
            intervals.append(dt)
        }
        let q = median(intervals)
        guard q > 0 else { return .init(unavailable: "every frame carries the same timestamp, so there is no clock to measure against") }
        let fps = 1 / q
        guard fps >= options.minimumFrameRate else {
            return .init(unavailable: String(format: "this clip runs at %.0f frames a second. The flight-time test needs at least %.0f, because at %.0f fps one frame is %.0f ms and that alone would be worth more than a centimetre of height.",
                                             fps, options.minimumFrameRate, fps, 1000 * q))
        }

        // The baseline is the floor: the lower half of the signal is time on the ground, and its
        // median and MAD are robust to the jump itself and to a bad frame.
        let sorted = footUpPixels.sorted()
        let lowerHalf = Array(sorted.prefix(max(3, sorted.count / 2)))
        let baseline = median(lowerHalf)
        let sigma = 1.4826 * median(lowerHalf.map { abs($0 - baseline) })
        guard let peak = footUpPixels.max() else { return .init(unavailable: "the foot signal is empty") }
        let peakRise = peak - baseline
        guard peakRise > 0 else {
            return .init(unavailable: "the feet never rose above the floor anywhere in this clip")
        }
        if sigma > 0, peakRise < options.minimumPeakRiseSigmas * sigma {
            return .init(unavailable: String(format: "the feet rose %.1f px above the floor, which is less than the %.1f px of tracker jitter this clip carries. That is not a jump the video can see.",
                                             peakRise, options.minimumPeakRiseSigmas * sigma))
        }
        let thresholdRise = max(options.thresholdNoiseSigmas * sigma, options.thresholdFloorPixels)
        guard thresholdRise <= options.thresholdMaximumFractionOfPeakRise * peakRise else {
            return .init(unavailable: String(format: "the floor carries %.1f px of tracker jitter against a foot rise of only %.1f px, so take-off cannot be separated from standing still. Fill more of the frame with the jumper, or film in better light.",
                                             sigma, peakRise))
        }

        func edges(_ rise: Double) -> Edges? {
            locateFlight(times: times, signal: footUpPixels, threshold: baseline + rise,
                         dwell: options.chatterDwellSeconds)
        }
        guard let found = edges(thresholdRise) else {
            // `locateFlight` says which of the three ways it failed.
            let why = describeFlightFailure(times: times, signal: footUpPixels, threshold: baseline + thresholdRise,
                                            dwell: options.chatterDwellSeconds)
            return .init(unavailable: why)
        }
        if found.takeOffGap > options.maximumEdgeGapFrames * q || found.landingGap > options.maximumEdgeGapFrames * q {
            return .init(unavailable: String(format: "the body was lost for %.0f ms around take-off or landing, so the edge would have to be guessed across the gap",
                                             1000 * max(found.takeOffGap, found.landingGap)))
        }
        let flight = found.landing - found.takeOff
        guard flight >= options.minimumFlightSeconds else {
            return .init(unavailable: String(format: "the feet were off the floor for only %.0f ms. Under %.0f ms this is a shuffle or a mis-read edge, not a jump.",
                                             1000 * flight, 1000 * options.minimumFlightSeconds))
        }
        guard flight <= options.maximumFlightSeconds else {
            return .init(unavailable: String(format: "the feet were off the floor for %.2f s. Over %.2f s it is not a jump the clip is showing — check that the whole body stayed in frame.",
                                             flight, options.maximumFlightSeconds))
        }

        let height = standardGravity * flight * flight / 8
        // Each edge is located to within ±1 frame; the two edges are independent, so the flight time
        // carries √2 frames. At 240 fps that is 5.9 ms.
        let sigmaT = options.edgeUncertaintyFrames * q * 2.0.squareRoot()
        // dh/dt = g·t/4.
        let sigmaH = standardGravity * flight / 4 * sigmaT

        // The threshold sits above the floor, so the flight reads short. How short is arithmetic, not a
        // guess: on a ballistic arc the part above a level `f` of the peak lasts `√(1−f)` of the whole,
        // so the height missed is `h · f/(1−f)`.
        let f = min(0.9, thresholdRise / peakRise)
        let bias = height * f / (1 - f)

        var notes: [String] = []
        notes.append(String(format: "Take-off and landing were read where the lower foot crossed %.1f px above the floor — %.0f%% of the %.1f px it rose, and %.1f px of that is the tracker's own jitter.",
                            thresholdRise, 100 * f, peakRise, sigma))
        notes.append(String(format: "One frame is %.1f ms at %.0f fps, so the flight time is ±%.1f ms and the height ±%.1f cm from the clock alone.",
                            1000 * q, fps, 1000 * sigmaT, 100 * sigmaH))
        notes.append(String(format: "Reading the floor a little above itself makes this number read low, by up to %.1f cm. It is not quietly added on: the height below is what was measured.",
                            100 * bias))
        return .init(jump: FlightTimeJump(
            takeOffSeconds: found.takeOff, landingSeconds: found.landing, flightSeconds: flight,
            flightSecondsUncertainty: sigmaT, heightMetres: height, heightUncertaintyMetres: sigmaH,
            frameRate: fps, samplingIntervalSeconds: q, peakRisePixels: peakRise,
            baselineNoisePixels: sigma, thresholdRisePixels: thresholdRise,
            thresholdBiasMetres: bias, notes: notes))
    }

    // MARK: - Method B: hip rise

    /// Where a metre came from, and what that costs.
    public struct JumpScale: Sendable, Codable {
        public var metresPerPixel: Double
        /// One sentence naming the ruler, for the screen.
        public var source: String
        /// Fractional, 1-sigma. 0.02 means "this scale is good to about 2 %".
        public var relativeUncertainty: Double
        public init(metresPerPixel: Double, source: String, relativeUncertainty: Double) {
            self.metresPerPixel = metresPerPixel; self.source = source; self.relativeUncertainty = relativeUncertainty
        }

        /// The only body ruler this app accepts: the shooter's stated standing height against their own
        /// ankle-to-nose pixel span, exactly as `BodySkeletonFit` scales the body model.
        ///
        /// The rim is **not** offered as an alternative, and that is a recorded measurement, not a
        /// preference: `ShooterProfile` says the rim ruler implied standing heights of 2.30 / 2.29 /
        /// 1.24 m on the three labelled windows, because on an oblique view the person is not at the
        /// rim's depth. A side-on jump test has the camera even further from the rim's plane, so it
        /// would be worse here, not better.
        public static func fromStatedHeight(metres: Double, ankleToNosePixels: Double,
                                            ankleToNoseFraction: Double = 0.891) -> JumpScale? {
            guard metres > 0.5, metres < 2.5, ankleToNosePixels > 1 else { return nil }
            // A height stated to the nearest centimetre is ±0.5 cm; on 1.80 m that is 0.3 %. The
            // population spread of the 0.891 ankle-to-nose fraction is **not recorded anywhere in
            // this repo**, so it is not put in this number — which is why the result says Method B is
            // a cross-check whose absolute accuracy is unverified, and never the headline.
            let statedHeightRelative = 0.005 / metres
            return JumpScale(metresPerPixel: metres * ankleToNoseFraction / ankleToNosePixels,
                             source: String(format: "your stated height of %.0f cm against your own ankle-to-nose span of %.0f px", 100 * metres, ankleToNosePixels),
                             relativeUncertainty: statedHeightRelative)
        }
    }

    public struct HipRiseOptions: Sendable {
        /// How much standing-still time before take-off sets the standing hip height.
        public var standingWindowSeconds: Double = 0.30
        /// Margin before take-off, so the last instants of the push are not counted as standing.
        public var standingMarginSeconds: Double = 0.05
        public var minimumStandingSamples: Int = 5
        public init() {}
    }

    public struct HipRiseJump: Sendable, Codable {
        public var riseMetres: Double
        public var riseUncertaintyMetres: Double
        public var standingSamples: Int
        public var risePixels: Double
        public var scale: JumpScale
        public var notes: [String]
    }

    public struct HipRiseMeasurement: Sendable, Codable {
        public var jump: HipRiseJump?
        public var unavailableReason: String?
        public init(jump: HipRiseJump) { self.jump = jump; self.unavailableReason = nil }
        public init(unavailable reason: String) { self.jump = nil; self.unavailableReason = reason }
    }

    /// Peak hip rise above the **standing** hip height — not above the dip. A countermovement drops
    /// the hips before it raises them, and measuring from the bottom of the dip would add the dip's
    /// depth to the jump.
    ///
    /// `takeOffSeconds` comes from Method A; without it there is no way to know which part of the clip
    /// was "standing still", and the measurement is refused rather than guessed.
    public static func hipRise(times: [Double], hipUpPixels: [Double], takeOffSeconds: Double?,
                               scale: JumpScale?, options: HipRiseOptions = HipRiseOptions()) -> HipRiseMeasurement {
        guard let scale else {
            return .init(unavailable: "nothing in this clip gives a metre scale. Add your height in Settings and the hip cross-check can run; the flight-time number above does not need it.")
        }
        guard times.count == hipUpPixels.count, !times.isEmpty else {
            return .init(unavailable: "the hip signal and the frame times do not line up")
        }
        guard let takeOff = takeOffSeconds else {
            return .init(unavailable: "take-off was never found, so there is no 'standing still' stretch to measure the hips against")
        }
        let cutoff = takeOff - options.standingMarginSeconds
        var standing: [Double] = []
        for (t, h) in zip(times, hipUpPixels) where h.isFinite && t <= cutoff && t >= cutoff - options.standingWindowSeconds {
            standing.append(h)
        }
        guard standing.count >= options.minimumStandingSamples else {
            return .init(unavailable: String(format: "only %d frames of standing still were found before take-off (at least %d are needed). Start the recording standing upright and still.",
                                             standing.count, options.minimumStandingSamples))
        }
        let standingHip = median(standing)
        let usable = hipUpPixels.filter { $0.isFinite }
        guard let peak = usable.max() else { return .init(unavailable: "no frame carried both hips") }
        let risePx = peak - standingHip
        guard risePx > 0 else { return .init(unavailable: "the hips never rose above where they stood") }
        let noise = 1.4826 * median(standing.map { abs($0 - standingHip) })
        let rise = risePx * scale.metresPerPixel
        // The scale's fractional error plus the pixel noise on the two ends (√2 × the standing noise).
        let pixelPart = 2.0.squareRoot() * noise * scale.metresPerPixel
        let scalePart = rise * scale.relativeUncertainty
        let sigma = (pixelPart * pixelPart + scalePart * scalePart).squareRoot()
        var notes: [String] = []
        notes.append("The metre scale here is \(scale.source).")
        notes.append("This number reads low on purpose: the legs tuck in the air, so the hips travel less than the body's middle does. It is a cross-check on the flight-time number, not a replacement for it.")
        return .init(jump: HipRiseJump(riseMetres: rise, riseUncertaintyMetres: sigma,
                                       standingSamples: standing.count, risePixels: risePx,
                                       scale: scale, notes: notes))
    }

    // MARK: - Comparing the two

    public struct MethodComparison: Sendable, Codable {
        public var flightMetres: Double
        public var hipMetres: Double
        public var differenceMetres: Double
        public var combinedUncertaintyMetres: Double
        public var agree: Bool
        /// Plain English, for the screen.
        public var sentence: String
    }

    public static func compare(flight: FlightTimeJump, hip: HipRiseJump) -> MethodComparison {
        let diff = flight.heightMetres - hip.riseMetres
        let combined = (flight.totalUncertaintyMetres * flight.totalUncertaintyMetres
                        + hip.riseUncertaintyMetres * hip.riseUncertaintyMetres).squareRoot()
        let agree = abs(diff) <= combined
        let sentence: String
        if agree {
            sentence = String(format: "The two ways of measuring agree: %.1f cm from flight time and %.1f cm from hip rise, a gap of %.1f cm against a combined error of ±%.1f cm.",
                              100 * flight.heightMetres, 100 * hip.riseMetres, 100 * abs(diff), 100 * combined)
        } else if diff > 0 {
            sentence = String(format: "They disagree: %.1f cm from flight time against %.1f cm from hip rise, a gap of %.1f cm where the two errors together only allow ±%.1f cm. Trust the flight-time number. It only needs the clock, and hip rise reads low whenever the legs tuck in the air — which they almost always do.",
                              100 * flight.heightMetres, 100 * hip.riseMetres, 100 * diff, 100 * combined)
        } else {
            sentence = String(format: "They disagree the other way: hip rise says %.1f cm and flight time says %.1f cm. Hip rise should not beat flight time, so something is off — usually a wrong stated height, or the hips being tracked while the feet were not fully in frame. Trust neither until the clip is refilmed with the whole body in shot.",
                              100 * hip.riseMetres, 100 * flight.heightMetres)
        }
        return MethodComparison(flightMetres: flight.heightMetres, hipMetres: hip.riseMetres,
                                differenceMetres: diff, combinedUncertaintyMetres: combined,
                                agree: agree, sentence: sentence)
    }

    // MARK: - A test is three jumps

    /// Best, mean and spread over the jumps that produced a number. `n` is always carried: three
    /// jumps is three jumps, and a standard deviation from three of anything is a wide one.
    public struct TestSummary: Sendable, Codable {
        public var n: Int
        public var bestMetres: Double
        public var meanMetres: Double
        /// Best minus worst.
        public var spreadMetres: Double
        /// Sample standard deviation, or nil with a reason when fewer than two jumps landed.
        public var sdMetres: Double?
        public var sdUnavailableReason: String?
        /// The mean of the per-jump ±, so the summary carries the measurement error too.
        public var typicalUncertaintyMetres: Double
    }

    public static func summarise(heightsMetres: [Double], uncertaintiesMetres: [Double]) -> TestSummary? {
        guard !heightsMetres.isEmpty, heightsMetres.count == uncertaintiesMetres.count else { return nil }
        let n = heightsMetres.count
        let mean = heightsMetres.reduce(0, +) / Double(n)
        var sd: Double? = nil
        var sdWhy: String? = "a spread needs at least two jumps that produced a number; only one did"
        if n >= 2 {
            let ss = heightsMetres.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            sd = (ss / Double(n - 1)).squareRoot()
            sdWhy = nil
        }
        return TestSummary(n: n, bestMetres: heightsMetres.max() ?? mean, meanMetres: mean,
                           spreadMetres: (heightsMetres.max() ?? mean) - (heightsMetres.min() ?? mean),
                           sdMetres: sd, sdUnavailableReason: sdWhy,
                           typicalUncertaintyMetres: uncertaintiesMetres.reduce(0, +) / Double(n))
    }

    // MARK: - Trend across test days

    public struct TrendPoint: Sendable, Codable {
        public var date: Date
        public var bestMetres: Double
        public var n: Int
        public init(date: Date, bestMetres: Double, n: Int) { self.date = date; self.bestMetres = bestMetres; self.n = n }
    }

    /// The change from the first test day to the last, with both n's — never a slope through two
    /// points dressed up as a rate.
    public static func trendSentence(_ points: [TrendPoint]) -> String {
        let sorted = points.sorted { $0.date < $1.date }
        guard let first = sorted.first, let last = sorted.last else { return "No jump tests saved yet." }
        guard sorted.count >= 2 else {
            return String(format: "One test day so far: best %.1f cm from %d jump", 100 * first.bestMetres, first.n)
                + (first.n == 1 ? "." : "s.")
        }
        let change = last.bestMetres - first.bestMetres
        let word = change >= 0 ? "up" : "down"
        // Built by concatenation rather than one format string: `String(format:)` mixing `%@` with
        // `%f` on arm64 silently printed 0.0 for the number (caught by `testTrendSentenceAlwaysCarriesN`).
        return String(format: "%d test days. Your best went from %.1f cm (n %d) to %.1f cm (n %d) — ",
                      sorted.count, 100 * first.bestMetres, first.n, 100 * last.bestMetres, last.n)
            + word + String(format: " %.1f cm", 100 * abs(change))
            + ". With three jumps a day, a change smaller than your own spread is not yet a change."
    }

    // MARK: - Private helpers

    struct Edges { var takeOff: Double; var landing: Double; var takeOffGap: Double; var landingGap: Double }

    /// The one stretch where the signal is above `threshold` for longer than `dwell`, with both edges
    /// linearly interpolated. Nil when there is not exactly one such stretch, or when it touches
    /// either end of the series (the clip started or finished in the air).
    static func locateFlight(times: [Double], signal: [Double], threshold: Double, dwell: Double) -> Edges? {
        let runs = airborneRuns(times: times, signal: signal, threshold: threshold, dwell: dwell)
        guard runs.count == 1 else { return nil }
        let (lo, hi) = runs[0]
        guard lo > 0, hi < times.count - 1 else { return nil }
        let takeOff = crossing(times[lo - 1], signal[lo - 1], times[lo], signal[lo], threshold)
        let landing = crossing(times[hi], signal[hi], times[hi + 1], signal[hi + 1], threshold)
        return Edges(takeOff: takeOff, landing: landing,
                     takeOffGap: times[lo] - times[lo - 1], landingGap: times[hi + 1] - times[hi])
    }

    static func describeFlightFailure(times: [Double], signal: [Double], threshold: Double, dwell: Double) -> String {
        let runs = airborneRuns(times: times, signal: signal, threshold: threshold, dwell: dwell)
        if runs.isEmpty { return "no stretch of this clip has both feet off the floor for long enough to be a jump" }
        if runs.count > 1 {
            return "the feet left the floor \(runs.count) separate times in this clip, so there is no single jump to measure. Record one jump per clip."
        }
        let (lo, hi) = runs[0]
        if lo == 0 { return "the clip starts with the feet already off the floor, so take-off was never filmed. Start recording before the jump." }
        if hi == times.count - 1 { return "the clip ends before the feet come back down, so the landing was never filmed. Keep recording until after you land." }
        return "take-off and landing could not be separated from standing still"
    }

    /// Index ranges (inclusive) where the signal sits above the threshold for at least `dwell`.
    static func airborneRuns(times: [Double], signal: [Double], threshold: Double, dwell: Double) -> [(Int, Int)] {
        var runs: [(Int, Int)] = []
        var start: Int? = nil
        for i in signal.indices {
            let above = signal[i] > threshold
            if above, start == nil { start = i }
            if !above, let s = start {
                if times[i - 1] - times[s] >= dwell { runs.append((s, i - 1)) }
                start = nil
            }
        }
        if let s = start, times[times.count - 1] - times[s] >= dwell { runs.append((s, times.count - 1)) }
        return runs
    }

    /// Where a straight line between two samples crosses `level`, in time.
    static func crossing(_ t0: Double, _ y0: Double, _ t1: Double, _ y1: Double, _ level: Double) -> Double {
        guard y1 != y0 else { return (t0 + t1) / 2 }
        let f = (level - y0) / (y1 - y0)
        return t0 + max(0, min(1, f)) * (t1 - t0)
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let idx = max(0, min(s.count - 1, Int((p * Double(s.count - 1)).rounded())))
        return s[idx]
    }
}
