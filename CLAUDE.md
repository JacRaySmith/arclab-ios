# CLAUDE.md — ArcLab iOS

This repo is the **iOS app** from "Project Brief v2" (`docs/BRIEF.md`). It is *not* the Python
textbook project in `../arclab` (whose CLAUDE.md forbids writing implementation code — that rule
does not apply here; the user asked for this app to be built).

## Rules that override convenience
1. **Never fabricate a number.** A metric that cannot be computed reliably is `nil` with a reason
   (`ShotMetrics.releaseUnavailableReason`, `entryAngleUnavailableReason`, warnings).
2. **`Packages/ShotGeometry` depends only on Foundation and simd.** No Vision/AVFoundation/UIKit.
3. **g is the check, not an input** in the final fit (`TrajectoryFit.g`). Only window detection
   holds g fixed (`TrajectoryFitOptions.fixedG`), and only because the plane is rim-calibrated.
4. **Radians in code, degrees at the boundary.** Names say the unit when it could be ambiguous.
5. **Do not pass a phase gate that fails.** Gates are in `docs/BRIEF.md` §8; results go in
   `docs/PHASE<N>-REPORT.md`. Run `swift run -c release GeometryHarness` before claiming Phase 1 still passes.
6. Zero network calls in the analysis path.

## Where knowledge lives
- `docs/reference/digest-*.md`: condensed chapters of the ArcLab textbook (formulas, thresholds,
  corrections). Consult before implementing statistics (Ch 5–6, 13), findings engine (Ch 15–16),
  pose (Ch 11–12), missing data (Ch 14), delivery/report (Ch 17–18).
- `docs/reference/sdk-and-licensing-research-2026-09-12.md`: verified Vision/AVFoundation API names,
  install base, XcodeGen vs Tuist, detector licences, rulebook dimensions.
- `docs/DECISIONS.md`: answers to the brief's open questions, with evidence.

## Toolchain
Xcode 26.6, iOS 26.5 SDK, Swift 6.3. iPhone 14 Pro paired (`xcrun devicectl list devices`).
`swift test` works. If only Command Line Tools are active, `GeometryChecks` still runs.
