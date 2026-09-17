import Foundation
import ShotGeometry

/// Scores detector output against a synthetic clip's ground truth, then runs the geometry pipeline on it.
public struct DetectorEvaluation: Codable, Sendable {
    public var flightFrames: Int
    public var flightFramesDetected: Int
    public var recallBelowApexAscending: Double     // brief §8 Phase 2: ≥ 0.90
    public var recallFinalThird: Double             // brief §8 Phase 2: ≥ 0.75
    public var recallOverall: Double
    public var centroidErrorMeanPx: Double
    public var centroidErrorRMSPx: Double
    public var centroidErrorP90Px: Double
    public var centroidErrorMaxPx: Double
    public var diameterErrorMeanPx: Double          // detector diameter − true diameter
    public var falsePositivesDuringFlight: Int      // samples > 3 radii from the true ball while it is visible
    public var samplesOutsideFlight: Int            // detections during hold/push/contact (not necessarily wrong)
    public var firstDetectedFlightFrameOffset: Int? // frames after release before the first detection
    public var tracksUsed: Int
    public var pipeline: PipelineComparison?
    public var pipelineError: String?
}

public struct PipelineComparison: Codable, Sendable {
    public var releaseAngleDeg: Double?
    public var releaseAngleErrorDeg: Double?
    public var releaseUnavailableReason: String?
    public var gFit: Double
    public var gErrorPercent: Double
    public var entryAngleDeg: Double?
    public var entryAngleErrorDeg: Double?
    public var releaseHeightError: Double?
    public var rmsPx: Double
    public var nInliers: Int
    public var viewAngleDeg: Double
    public var warnings: [String]
}

public enum DetectorScorer {
    /// Matches every track sample to the truth frame with the same PTS (within half a frame interval).
    public static func score(run: TrajectoryRun, truth: SyntheticTruth, matchRadiusFactor: Double = 3) -> DetectorEvaluation {
        let dt = 1 / truth.fps
        var byIndex: [Int: SyntheticTruth.Frame] = [:]
        for f in truth.frames { byIndex[f.index] = f }
        // Pool all track samples; dedupe per frame by the sample closest to the truth (a real detector has one ball).
        var perFrame: [Int: TrackSample] = [:]
        var falsePositives = 0
        var outsideFlight = 0
        for track in run.tracks {
            for s in track.samples {
                // The clip's PTS starts at 0 = first simulated frame; truth pts is the same axis.
                let idx = Int((s.pts / dt).rounded())
                guard let tf = byIndex[idx] else { continue }
                if tf.phase != "flight" { outsideFlight += 1; continue }
                let err = ((s.u - tf.u) * (s.u - tf.u) + (s.v - tf.v) * (s.v - tf.v)).squareRoot()
                if tf.visible, err > matchRadiusFactor * tf.diameterPx / 2 { falsePositives += 1; continue }
                if let existing = perFrame[idx] {
                    let e0 = ((existing.u - tf.u) * (existing.u - tf.u) + (existing.v - tf.v) * (existing.v - tf.v)).squareRoot()
                    if err < e0 { perFrame[idx] = s }
                } else { perFrame[idx] = s }
            }
        }
        let flight = truth.frames.filter { $0.phase == "flight" && $0.visible }.sorted { $0.t < $1.t }
        let tApex = truth.releaseSpeed * sin(Angle.radians(truth.releaseAngleDeg)) / Court.g
        let ascending = flight.filter { $0.t < tApex }
        let finalThird = flight.filter { $0.t > truth.timeOfFlight * 2 / 3 }
        func recall(_ fs: [SyntheticTruth.Frame]) -> Double {
            fs.isEmpty ? 0 : Double(fs.filter { perFrame[$0.index] != nil }.count) / Double(fs.count)
        }
        var errs: [Double] = [], dErrs: [Double] = []
        for f in flight { if let s = perFrame[f.index] {
            errs.append(((s.u - f.u) * (s.u - f.u) + (s.v - f.v) * (s.v - f.v)).squareRoot())
            dErrs.append(2 * s.radiusPx - f.diameterPx)
        } }
        let sortedErrs = errs.sorted()
        let firstOffset = flight.first.flatMap { first in
            flight.first(where: { perFrame[$0.index] != nil }).map { $0.index - first.index }
        }
        var eval = DetectorEvaluation(
            flightFrames: flight.count, flightFramesDetected: errs.count,
            recallBelowApexAscending: recall(ascending), recallFinalThird: recall(finalThird), recallOverall: recall(flight),
            centroidErrorMeanPx: errs.isEmpty ? .nan : errs.reduce(0, +) / Double(errs.count),
            centroidErrorRMSPx: errs.isEmpty ? .nan : (errs.map { $0 * $0 }.reduce(0, +) / Double(errs.count)).squareRoot(),
            centroidErrorP90Px: sortedErrs.isEmpty ? .nan : sortedErrs[min(sortedErrs.count - 1, Int(Double(sortedErrs.count) * 0.9))],
            centroidErrorMaxPx: sortedErrs.last ?? .nan,
            diameterErrorMeanPx: dErrs.isEmpty ? .nan : dErrs.reduce(0, +) / Double(dErrs.count),
            falsePositivesDuringFlight: falsePositives, samplesOutsideFlight: outsideFlight,
            firstDetectedFlightFrameOffset: firstOffset, tracksUsed: run.tracks.count, pipeline: nil, pipelineError: nil)

        // Geometry pipeline on the detector's own samples (all frames, so release detection is exercised too).
        var all: [Int: TrackSample] = perFrame
        for track in run.tracks { for s in track.samples {
            let idx = Int((s.pts / dt).rounded())
            if all[idx] == nil, let tf = byIndex[idx], tf.phase != "flight" { all[idx] = s }
        } }
        let samples = all.keys.sorted().compactMap { idx -> ImageSample? in
            guard let s = all[idx], let tf = byIndex[idx] else { return nil }
            return ImageSample(t: tf.t, uv: SIMD2(s.u, s.v), diameterPx: 2 * s.radiusPx)
        }
        do {
            let cal = try RimCalibrator.calibrate(boundaryPoints: truth.rimBoundary.map { SIMD2($0[0], $0[1]) }, intrinsics: truth.intrinsics)
            let a = try ShotAnalyzer.analyze(track: samples, calibration: cal, intrinsics: truth.intrinsics)
            let rel = a.metrics.release
            eval.pipeline = PipelineComparison(
                releaseAngleDeg: rel?.angleDegrees, releaseAngleErrorDeg: rel.map { $0.angleDegrees - truth.releaseAngleDeg },
                releaseUnavailableReason: a.metrics.releaseUnavailableReason,
                gFit: a.confidence.gFit, gErrorPercent: a.confidence.gError * 100,
                entryAngleDeg: a.metrics.entryAngleDegrees, entryAngleErrorDeg: a.metrics.entryAngleDegrees.map { $0 - truth.entryAngleDeg },
                releaseHeightError: rel.map { $0.height - truth.releaseHeight },
                rmsPx: a.confidence.rmsPx, nInliers: a.confidence.nInliers,
                viewAngleDeg: Angle.degrees(a.confidence.viewAngle), warnings: a.confidence.warnings)
        } catch {
            eval.pipelineError = "\(error)"
        }
        return eval
    }
}
