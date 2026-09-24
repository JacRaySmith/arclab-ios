// The app's acceptance rule, mirrored from `Packages/ShotVideo/Sources/TrajectoryProbe/Probe.swift`
// (`case "session":`, functions `plausible`/`accepted`, ~line 361). That file cannot be imported
// here (it depends on AVFoundation/Vision/CoreML; this package may depend only on Foundation +
// simd + ShotGeometry), so the rule is duplicated on purpose. If the live rule changes, update both
// — this file's doc comment is the trip wire.
import Foundation
import ShotGeometry

public enum ShotAcceptance {
    public static let maxReprojectionRmsPx = 25.0
    public static let maxGError = 0.08

    public static func plausible(_ m: ShotMetrics) -> Bool {
        guard let r = m.release, let depth = m.depthPastFrontRim else { return false }
        return r.height >= 1.6 && r.height <= 3.3 && r.speed >= 4.5 && r.speed <= 11 && depth >= -0.6 && depth <= 1.0
    }

    public static func accepted(_ a: ShotAnalysis) -> Bool {
        a.confidence.gError <= maxGError && plausible(a.metrics) && a.confidence.rmsPx <= maxReprojectionRmsPx
    }

    /// Why `accepted` returned false, for a window that *did* produce an analysis (as opposed to
    /// one where `ShotAnalyzer.analyze` threw — that reason is the thrown error's description).
    public static func refusalReason(_ a: ShotAnalysis) -> String? {
        guard !accepted(a) else { return nil }
        var reasons: [String] = []
        if a.confidence.gError > maxGError {
            reasons.append(String(format: "gravity error %.1f%% > %.0f%%", a.confidence.gError * 100, maxGError * 100))
        }
        if !plausible(a.metrics) {
            if let r = a.metrics.release {
                var bits: [String] = []
                if r.height < 1.6 || r.height > 3.3 { bits.append(String(format: "release height %.2f m outside 1.6–3.3", r.height)) }
                if r.speed < 4.5 || r.speed > 11 { bits.append(String(format: "release speed %.2f m/s outside 4.5–11", r.speed)) }
                if let d = a.metrics.depthPastFrontRim {
                    if d < -0.6 || d > 1.0 { bits.append(String(format: "depth %.2f m outside −0.6…1.0", d)) }
                } else {
                    bits.append("depth past front rim unavailable: " + (a.metrics.entryAngleUnavailableReason ?? "not computed"))
                }
                reasons.append(bits.isEmpty ? "implausible release/depth" : bits.joined(separator: ", "))
            } else {
                reasons.append("release unavailable: " + (a.metrics.releaseUnavailableReason ?? "not observed"))
            }
        }
        if a.confidence.rmsPx > maxReprojectionRmsPx {
            reasons.append(String(format: "fit residual %.1f px > %.0f px", a.confidence.rmsPx, maxReprojectionRmsPx))
        }
        return reasons.joined(separator: "; ")
    }
}
