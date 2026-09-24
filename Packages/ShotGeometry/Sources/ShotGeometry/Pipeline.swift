import Foundation

public struct AnalysisOptions: Sendable {
    /// Time after release excluded from the fit (hand/arm/head occlusion makes those frames the
    /// noisiest): 0.02 s is 5 frames at 240 fps and 1 frame at 30 fps. At least one sample.
    public var postReleaseExclusionTime: Double = 0.02
    /// Samples excluded before the detected flight end.
    public var preEndExclusion: Int = 1
    /// Entry angle requires the arc to be tracked this many samples past apex.
    public var minimumSamplesAfterApex: Int = 3
    public var windowOptions = FlightWindowOptions()
    public var fitOptions = TrajectoryFitOptions()
    public var azimuthGridSteps: Int = 180
    public var ballDiameter: Double = BallSize.size7.diameter
    /// When the shooting distance is known (a routine station, a free throw), the shot-plane azimuth follows from the
    /// first sample's ray meeting the vertical cylinder of that radius around the rim axis; no diameter cue is needed.
    /// Pair with `knownDistanceSampleIndex` (default 0 = first sample, i.e. the release or the earliest detection).
    public var knownReleaseDistance: Double? = nil
    /// Solve the azimuth by a whole-track fixed-g fit instead of the core-window shape solve. Recommended for
    /// footage with a missing apex or unreliable ball diameters. Implied when `knownReleaseDistance` is set.
    public var azimuthByFixedGravity: Bool = false
    /// Bypass the solve entirely with a fixed azimuth (radians, in the calibration's horizontal basis).
    public var fixedAzimuth: Double? = nil
    /// Restrict the fixed-g azimuth solve to samples inside this time range (e.g. an external tracker's release…rim window),
    /// so held-ball and in-net samples cannot contaminate the plane. The window/release detection still sees every sample.
    public var azimuthTimeRange: ClosedRange<Double>? = nil
    /// **Defaulted off.** A court-anchored camera pose (`CourtCalibration`, solved from marked court
    /// features) plus, where it exists, a measured shooter position. When set, the shot-plane azimuth
    /// is searched only inside the azimuth windows the court allows instead of the free 0…2π scan —
    /// the bearing the rim ellipse alone cannot supply. `g` stays the check; nothing else changes.
    public var courtAnchor: CourtShotAnchor? = nil
    public init() {}
}

public enum AnalysisError: Error, CustomStringConvertible, Sendable {
    case tooFewDetections(Int)
    case azimuth(ShotPlaneError)
    case window(FlightWindowError)
    case fit(TrajectoryFitError)
    case projectionFailed
    case gravityRejected(String)

    public var description: String {
        switch self {
        case .tooFewDetections(let n): return "only \(n) ball detections; need ≥ 12"
        case .azimuth(let e): return "shot plane: \(e)"
        case .window(let e): return "flight window: \(e)"
        case .fit(let e): return "trajectory fit: \(e)"
        case .projectionFailed: return "could not project the flight into the solved plane"
        case .gravityRejected(let s): return "gravity check failed: \(s)"
        }
    }
}

public struct ShotAnalysis: Sendable {
    public var metrics: ShotMetrics
    public var confidence: ConfidencePayload
    /// Final fit, anchored at the release instant.
    public var fit: TrajectoryFit
    public var window: FlightWindow
    public var azimuth: AzimuthSolution
    public var planeSamples: [TrajectorySample]
    public var flightIndices: [Int]
    public var calibration: RimCalibration
}

/// Import and capture both end here: timestamps + pixel detections + rim calibration → metrics.
public enum ShotAnalyzer {
    public static func analyze(track input: [ImageSample], calibration: RimCalibration, intrinsics: CameraIntrinsics,
                               options: AnalysisOptions = .init()) throws -> ShotAnalysis {
        let track = input.sorted { $0.t < $1.t }
        guard track.count >= 12 else { throw AnalysisError.tooFewDetections(track.count) }
        var warnings = calibration.warnings

        // 1. Image-space apex → anchor set that is certainly free flight.
        let apexPx = (0..<track.count).min { track[$0].uv.y < track[$1].uv.y }!
        let tApex = track[apexPx].t
        // The ascent lasts ≥ 0.4 s for any real shot and the descent can be as short as 0.15 s, so
        // [apex − 0.3 s, apex + 0.1 s] is free flight for every shot.
        let anchorSet = track.filter { $0.t >= tApex - 0.30 && $0.t <= tApex + 0.10 }

        // 2. First azimuth solve on the anchor set — or a constrained azimuth when the distance is known.
        var azimuth: AzimuthSolution
        var azimuthFixed = false
        if let fixed = options.fixedAzimuth {
            azimuth = AzimuthSolution(frame: ShotPlaneSolver.frame(calibration: calibration, azimuth: fixed), pixelRMS: 0, curve: [],
                                      ambiguityRatio: 0, azimuthSigma: 0, warnings: ["azimuth fixed by caller"])
            azimuthFixed = true
        } else if let anchor = options.courtAnchor {
            // Court-anchored: the bearing is measured, so the azimuth is a search over the windows
            // the court allows, not over the whole circle. An anchor that allows nothing is a
            // refusal, not a fall back to the free scan.
            let windows = anchor.azimuthWindows()
            guard !windows.isEmpty else { throw AnalysisError.azimuth(.noValidAzimuth) }
            let azTrack = options.azimuthTimeRange.map { r in track.filter { r.contains($0.t) } } ?? track
            guard let az = ShotPlaneSolver.solveByFixedGravity(azTrack.count >= 8 ? azTrack : track, calibration: calibration,
                                                               intrinsics: intrinsics,
                                                               knownDistance: anchor.knownReleaseDistance,
                                                               allowedAzimuths: windows) else {
                throw AnalysisError.azimuth(.noValidAzimuth)
            }
            azimuth = az; azimuthFixed = true
            warnings.append("shot plane court-anchored (" + anchor.provenance + String(format: "); residual %.3f", az.pixelRMS))
        } else if options.knownReleaseDistance != nil || options.azimuthByFixedGravity {
            let azTrack = options.azimuthTimeRange.map { r in track.filter { r.contains($0.t) } } ?? track
            guard let az = ShotPlaneSolver.solveByFixedGravity(azTrack.count >= 8 ? azTrack : track, calibration: calibration, intrinsics: intrinsics,
                                                               knownDistance: options.knownReleaseDistance) else {
                throw AnalysisError.azimuth(.noValidAzimuth)
            }
            azimuth = az; azimuthFixed = true
            warnings.append(String(format: "shot plane by whole-track fixed-g fit (residual %.3f m)%@", az.pixelRMS,
                                   options.knownReleaseDistance.map { String(format: ", constrained to a %.2f m release distance", $0) } ?? ""))
        } else {
            do { azimuth = try ShotPlaneSolver.solve(anchorSet, calibration: calibration, intrinsics: intrinsics, gridSteps: options.azimuthGridSteps) }
            catch let e as ShotPlaneError { throw AnalysisError.azimuth(e) }
        }

        // 3. Project everything, find the flight window.
        guard var plane = ShotPlaneSolver.project(track, intrinsics: intrinsics, frame: azimuth.frame) else { throw AnalysisError.projectionFailed }
        var window: FlightWindow
        do { window = try FlightWindowFinder.find(plane, options: options.windowOptions) }
        catch let e as FlightWindowError { throw AnalysisError.window(e) }

        func flightIndices(_ w: FlightWindow) -> [Int] {
            var lo = w.releaseIndex + 1
            while lo < plane.count && plane[lo].t - w.releaseTime < options.postReleaseExclusionTime { lo += 1 }
            let hi = w.endIndex - options.preEndExclusion
            return lo <= hi ? Array(lo...hi) : []
        }

        // 4. Alternate: re-solve the azimuth on the current flight window, re-project, re-find the
        //    window. The first azimuth solve only saw the 0.4 s core; each round sees more flight.
        for _ in 0..<5 where !azimuthFixed {
            let idx1 = flightIndices(window)
            guard idx1.count >= 8,
                  let az2 = try? ShotPlaneSolver.solve(idx1.map { track[$0] }, calibration: calibration, intrinsics: intrinsics, gridSteps: options.azimuthGridSteps),
                  let plane2 = ShotPlaneSolver.project(track, intrinsics: intrinsics, frame: az2.frame),
                  let w2 = try? FlightWindowFinder.find(plane2, options: options.windowOptions) else { break }
            let unchanged = w2.releaseIndex == window.releaseIndex && w2.endIndex == window.endIndex
            azimuth = az2; plane = plane2; window = w2
            if unchanged { break }
        }
        warnings += azimuth.warnings + window.notes

        // 5. Final robust fit anchored at the sub-frame release time.
        let idx = flightIndices(window)
        let flight = idx.map { plane[$0] }
        let fit: TrajectoryFit
        do { fit = try TrajectoryFitter.fit(flight, anchorTime: window.releaseTime, options: options.fitOptions) }
        catch let e as TrajectoryFitError { throw AnalysisError.fit(e) }

        // Pixel-space residual of the final fit (the number the g-test gate reads).
        var sse = 0.0
        for i in idx {
            let p = fit.position(at: plane[i].t)
            let P = azimuth.frame.point3D(x: p.x, y: p.y)
            let px = intrinsics.pixel(fromNormalized: SIMD2(P.x / P.z, P.y / P.z))
            let d = px - track[i].uv
            sse += d.x * d.x + d.y * d.y
        }
        let rmsPx = (sse / Double(max(idx.count, 1))).squareRoot()

        // 6. Metrics.
        let (gVerdict, gErr) = GravityGate.verdict(gFit: fit.g)
        if gVerdict == .reject { warnings.append(GravityGate.explain(gFit: fit.g)) }
        let viewAngle = azimuth.frame.viewAngle
        let viewClass = ViewClassifier.classify(viewAngle: viewAngle)

        var m = ShotMetrics()
        if window.releaseObserved {
            m.release = ReleaseMetrics(angle: fit.releaseAngle, height: fit.y0 + Court.rimHeight, speed: fit.releaseSpeed, distance: -fit.x0)
        } else {
            m.releaseUnavailableReason = "release instant not in the footage (track starts in flight); frame the shooter"
            warnings.append(m.releaseUnavailableReason!)
        }
        let tApexFit = fit.timeOfApex
        let afterApex = flight.filter { $0.t > tApexFit }.count
        if fit.vy > 0 { m.apexHeight = fit.y0 + fit.vy * fit.vy / (2 * fit.g) + Court.rimHeight }

        if afterApex < options.minimumSamplesAfterApex {
            m.entryAngleUnavailableReason = "arc not tracked past apex (\(afterApex) samples after apex)"
        } else if viewClass == .frontal {
            m.entryAngleUnavailableReason = "frontal view: arc angles are not measurable from this camera position"
        } else {
            // Rim-plane crossing: y = 0 at the rim centre height. Descending root.
            let disc = fit.vy * fit.vy + 2 * fit.g * fit.y0
            if disc >= 0 && fit.vx > 0 {
                let tau = (fit.vy + disc.squareRoot()) / fit.g
                let vyAt = fit.vy - fit.g * tau
                m.entryAngle = atan(abs(vyAt) / fit.vx)
                m.timeOfFlight = tau
                let xCross = fit.x0 + fit.vx * tau
                m.rimCrossingOffset = xCross
                m.depthPastFrontRim = xCross + Court.rimInnerRadius
                let clean = Court.rimInnerRadius - options.ballDiameter / 2
                m.depthClass = xCross < -clean ? .front : (xCross > clean ? .back : .center)
            } else {
                m.entryAngleUnavailableReason = "fitted arc never reaches rim height"
            }
        }
        if viewClass == .frontal { warnings.append("frontal view: release/entry angles are unreliable; only lateral deviation is supported") }
        if viewClass == .oblique { warnings.append(String(format: "oblique view (%.0f° from side): angle metrics depend on the solved shot plane", Angle.degrees(viewAngle))) }

        let conf = ConfidencePayload(gFit: fit.g, gError: gErr, gravityVerdict: gVerdict, rmsPx: rmsPx, rmsM: fit.rms,
                                     nDetections: idx.count, nInliers: fit.nInliers, flightSpan: fit.span,
                                     samplesAfterApex: afterApex, calibrationPath: .rimEllipse, viewClass: viewClass,
                                     viewAngle: viewAngle, azimuthSigma: azimuth.azimuthSigma, releaseTime: window.releaseTime,
                                     releaseObserved: window.releaseObserved, warnings: warnings)
        return ShotAnalysis(metrics: m, confidence: conf, fit: fit, window: window, azimuth: azimuth,
                            planeSamples: plane, flightIndices: idx, calibration: calibration)
    }
}

// MARK: - Ball-scale-only fallback (no rim, no backboard)

/// Image-plane analysis for the ball-scale calibration path. Fits u(t) linear and v(t) quadratic in
/// pixels, recovers the scale that makes g = 9.81 (textbook §4.7 inverted), and cross-checks against
/// the ball's apparent diameter. Angles are corrected for an *estimated* yaw and flagged low-confidence.
public struct BallScaleAnalysis: Sendable {
    public var releaseAngle: Double             // yaw-corrected, radians
    public var releaseAngleMeasured: Double     // in the image plane, before correction
    public var scaleFromGravity: Double         // m/px
    public var scaleFromBall: Double?           // m/px
    public var scaleDisagreement: Double?       // (s_ball − s_g)/s_g
    public var rmsPx: Double
    public var warnings: [String]
}

public enum BallScaleAnalyzer {
    public static func analyze(flight: [ImageSample], releaseTime: Double, assumedYaw: Double = 0,
                               ballDiameter: Double = BallSize.size7.diameter) throws -> BallScaleAnalysis {
        // Up-positive pixel coordinate: ỹ = −v. Then b₂ = −g/(2s) < 0.
        let pts = flight.map { TrajectorySample(t: $0.t, x: $0.uv.x, y: -$0.uv.y) }
        var opts = TrajectoryFitOptions(); opts.sigmaFloor = 0.05; opts.minimumSpan = 0.15
        let fit = try TrajectoryFitter.fit(pts, anchorTime: releaseTime, options: opts)
        var warnings = ["ball-scale calibration: scale solved from gravity, so g is not an independent check"]
        guard fit.g > 0 else { throw AnalysisError.gravityRejected("fitted curvature has the wrong sign (ball falls upward): image v axis not flipped, or not free flight") }
        let sG = Court.g / fit.g                       // g_px = g / s  ⇒  s = g / g_px
        let measured = atan2(fit.vy, abs(fit.vx))      // the ball may travel left or right in the image
        let corrected = Perspective.yawCorrectedAngle(measured: measured, yaw: assumedYaw)
        if assumedYaw != 0 { warnings.append(String(format: "release angle corrected for an assumed %.0f° yaw; low confidence", Angle.degrees(assumedYaw))) }
        var sBall: Double? = nil, disagreement: Double? = nil
        let diams = flight.compactMap { $0.diameterPx }
        if diams.count >= 5 {
            let dpx = Stats.median(diams)
            let s = ballDiameter / dpx
            sBall = s
            disagreement = (s - sG) / sG
            if abs(disagreement!) > 0.05 { warnings.append(String(format: "scale disagreement %+.1f%% between gravity and ball diameter: wrong ball size, blur, or yaw", disagreement! * 100)) }
        }
        return BallScaleAnalysis(releaseAngle: corrected, releaseAngleMeasured: measured, scaleFromGravity: sG,
                                 scaleFromBall: sBall, scaleDisagreement: disagreement, rmsPx: fit.rms, warnings: warnings)
    }
}
