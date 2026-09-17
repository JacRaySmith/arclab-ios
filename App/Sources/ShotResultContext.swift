import Foundation
import ShotGeometry
import simd

/// Everything the results screen needs about one analysed shot, detached from where it came from, so
/// the single-shot flow and the session list can both open the same screen.
struct ShotResultContext: Sendable {
    var title: String
    var clipURL: URL
    var timeScale: Double
    var intrinsics: CameraIntrinsics
    var rimPoints: [SIMD2<Double>]
    var analysis: ShotAnalysis
    var samples: [ImageSample]
    var notes: [String]
    var pose: ShotPoseResult?
    /// The per-shot body model, or nil with `bodyUnavailableReason`.
    var body: ShotBodyResult?
    var bodyUnavailableReason: String?
    /// The window the result was produced from, in file seconds, so a result can never be read as
    /// belonging to a window the user has since moved.
    var window: ClosedRange<Double>?
    /// The block rule's verdict on this shot, when it was analysed as part of a session.
    var verdict: ShotAcceptance.Verdict?
    var outcome: OutcomeInference?
}
