import AVFoundation
import Foundation
import ShotGeometry

/// The lens constant the geometry needs, chosen among the phone's REAL video formats rather than guessed.
///
/// Why this exists: on 2026-09-14 the shooter's own 42-shot session fitted gravity at 8.21 ± 0.3 m/s²
/// (33 of 42 windows "low confidence", tracks clean at 4 px) with the assumed 48° field of view. The
/// phone's 1080p120 format reports 41.17°; the implied scale correction 9.81/8.21 = 1.19 puts the true
/// field of view at 40.9°. Same phone, same footage, and the constant was simply the wrong format's.
///
/// The rule keeps CLAUDE.md rule 3 honest: gravity is not fitted to 9.81. The first pass runs with the
/// stated field of view; if the accepted-or-clean shots fit gravity consistently off by one scale factor,
/// that factor is compared with the *discrete* set of formats this phone can record, and only an
/// unambiguous match is offered. The second pass then reports g_fit as the check it always was.
enum LensSelection {
    struct Candidate: Equatable {
        var hfovDegrees: Double
        var label: String
    }

    struct Proposal {
        var current: Double
        var impliedHFOV: Double
        var medianG: Double
        var n: Int
        var match: Candidate
        var explanation: String
    }

    /// Formats of the back wide camera with their horizontal field of view, plus the value a Camera.app
    /// slo-mo export with stabilisation cropping has measured at on this project (48°, gravity-checked on
    /// the 2026-09-13 footage). Deduplicated to 0.1°.
    static func candidates() -> [Candidate] {
        var out: [Candidate] = [Candidate(hfovDegrees: 48.0, label: "Camera.app slo-mo export (stabilised crop, measured on 2026-09-13 footage)")]
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            for f in device.formats {
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let maxFps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                guard d.width >= 1280, maxFps >= 60 else { continue }
                let fov = Double(f.videoFieldOfView)
                if out.contains(where: { abs($0.hfovDegrees - fov) < 0.1 }) { continue }
                out.append(Candidate(hfovDegrees: fov, label: String(format: "this phone's %d×%d @ %.0f fps format", d.width, d.height, maxFps)))
            }
        } else {
            for (fov, label) in [(41.17, "1080p120 format (iPhone 14 Pro)"), (73.83, "1080p240 binned format (iPhone 14 Pro)")] {
                out.append(Candidate(hfovDegrees: fov, label: label))
            }
        }
        return out.sorted { $0.hfovDegrees < $1.hfovDegrees }
    }

    /// The field of view implied by a consistent gravity scale error: g ∝ focal length, so
    /// tan(hfov'/2) = tan(hfov/2) · g_fit / 9.81.
    static func impliedHFOV(current: Double, medianG: Double) -> Double {
        2 * atan(tan(Angle.radians(current) / 2) * medianG / Court.g) * 180 / .pi
    }

    /// A proposal only when: at least `minShots` clean fits (reprojection rms ≤ `maxRmsPx`), their g_fit
    /// spread is tight (IQR ≤ `maxIQRFraction` of the median: one scale error, not noise), the median is
    /// off by more than `minErrorFraction`, and exactly one candidate lies within `matchDegrees`.
    static func propose(current: Double, gFits: [(g: Double, rmsPx: Double)],
                        minShots: Int = 5, maxRmsPx: Double = 12, maxIQRFraction: Double = 0.12,
                        minErrorFraction: Double = 0.05, matchDegrees: Double = 3.0) -> Proposal? {
        let clean = gFits.filter { $0.rmsPx <= maxRmsPx && $0.g > 0 && $0.g.isFinite }.map(\.g).sorted()
        guard clean.count >= minShots else { return nil }
        let median = clean[clean.count / 2]
        let q1 = clean[clean.count / 4], q3 = clean[(3 * clean.count) / 4]
        guard median > 0, (q3 - q1) / median <= maxIQRFraction else { return nil }
        guard abs(median / Court.g - 1) >= minErrorFraction else { return nil }
        let implied = impliedHFOV(current: current, medianG: median)
        let near = candidates().filter { abs($0.hfovDegrees - implied) <= matchDegrees && abs($0.hfovDegrees - current) > 0.5 }
        if near.count != 1 {
            // Camera.app's slo-mo exports carry a stabilisation crop that no raw format has (measured ≈ 46–48° at
            // 120 fps and ≈ 51° at 240 fps on this phone). When no format explains the scale but ≥ 8 clean shots
            // agree on one factor, the clip's own gravity median calibrates the lens. The provenance says so, and the
            // per-shot gravity check on the second pass still flags every shot that disagrees with the rest.
            guard clean.count >= 8, near.isEmpty else { return nil }
            let fallback = Candidate(hfovDegrees: (implied * 10).rounded() / 10, label: "calibrated from this clip's own gravity median (no camera format matched)")
            let text = String(format: "The first pass fitted gravity at %.2f m/s² over %d clean shots (%+.0f %% with a tight spread), which is one scale factor, not noise. No camera format explains it (Camera.app's slow-motion export crops the frame), so the lens was calibrated from the clip itself: %.1f° instead of the assumed %.1f°. The shots were re-run with it; the gravity check below is from that pass and still judges each shot against the rest.",
                              median, clean.count, (median / Court.g - 1) * 100, fallback.hfovDegrees, current)
            return Proposal(current: current, impliedHFOV: implied, medianG: median, n: clean.count, match: fallback, explanation: text)
        }
        guard let match = near.first else { return nil }
        let text = String(format: "The first pass fitted gravity at %.2f m/s² over %d clean shots (%+.0f %% with a tight spread), which is one scale factor, not noise. With the %.1f° field of view assumed, that implies %.1f°, and this phone's only format near it is %.2f°: %@. The shots were re-run with it; the gravity check below is from that pass.",
                          median, clean.count, (median / Court.g - 1) * 100, current, implied, match.hfovDegrees, match.label)
        return Proposal(current: current, impliedHFOV: implied, medianG: median, n: clean.count, match: match, explanation: text)
    }
}
