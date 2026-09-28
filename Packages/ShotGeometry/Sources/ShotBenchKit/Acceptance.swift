// The acceptance rule used to live here, duplicated from
// `Packages/ShotVideo/Sources/TrajectoryProbe/Probe.swift` (`case "session":`) because that file
// depends on AVFoundation/Vision/CoreML and this package may not. Its doc comment called itself
// "the trip wire" for the two copies drifting apart.
//
// The trip wire did not fire. On 2026-09-27 the copy here and the one the phone applies
// (`App/Sources/BlockSummary.swift`) were found to differ in two ways — no `minimumReleaseDistance`
// here, and a window with no `depthPastFrontRim` refused here but accepted by the app — which means
// every acceptance and recall number in `docs/EXPERIMENTS.md` and `docs/BENCH-RESULTS-*.md` was
// scored with a rule the app does not apply.
//
// The rule now lives once, in `ShotGeometry/ShotAcceptance.swift`, and all three callers import it.
// What is left here is only the bench's *choice* of policy, which is a real bench concern.
import Foundation
import ShotGeometry

public extension ShotAcceptancePolicy {
    /// What `ShotBench` scores with unless `--acceptance legacy` is passed.
    ///
    /// `.shipping` — the phone's rule — is the default on purpose: a bench that does not measure the
    /// rule the product applies is measuring the wrong thing, however self-consistent its numbers are.
    /// `.legacyBench` reproduces the pre-2026-09-27 numbers so the existing ledger stays checkable.
    static var benchDefault: ShotAcceptancePolicy { .shipping }
}
