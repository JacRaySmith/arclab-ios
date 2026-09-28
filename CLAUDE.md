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

## Read these, in this order
A new agent following the old version of this section reached the textbook digests and never found
the measurement loop, the backlog, or the state of the build. The order is:

1. **this file**
2. **`docs/STATE.md`** — what ships, the current gate numbers, where the corpus stands, the one open
   lead, and what is blocked on you. One page, overwritten in place, never appended to.
   `docs/HANDOFF.md` is now the archive of past states and the topic deep-dives; read it for history
   and for the measurement tables it alone carries, not for what is true today.
3. **`docs/PIPELINE.md`** — how to measure anything, and what the current corpus can and cannot say.
   Then **`docs/EXPERIMENTS.md`**, the ledger: one row per comparison acted on, each traceable to a
   p-value. Never change analysis behaviour without adding a row.
4. **`docs/BIG-CHANGES.md`** — the ranked structural backlog (B1–B14) with the evidence for each.
   `docs/IMPROVEMENTS-2026-09-16.md` is the longer polish list underneath it.

`App/README.md` is the best prose description of what the app actually does today — consult it
before re-deriving a screen's behaviour from the source.

**Constants are the code, not the prose.** `ShotGeometry/Constants.swift` is the single source:
size-7 ball **0.2385 m**, rim inner **0.4572 m**, rim height **3.048 m**, free-throw line to rim
centre **4.191 m**. `docs/BRIEF.md` and `docs/DECISIONS.md` agree with it.
`docs/reference/digest-constants-and-corrections.md` says "use exactly these" and then gives the
textbook's **0.2426 m** ball — that digest is the textbook's record, not this project's; where they
differ, the code wins and `DECISIONS.md` says why.

## Where knowledge lives
- `docs/reference/digest-*.md`: condensed chapters of the ArcLab textbook (formulas, thresholds,
  corrections). Consult before implementing statistics (Ch 5–6, 13), findings engine (Ch 15–16),
  pose (Ch 11–12), missing data (Ch 14), delivery/report (Ch 17–18).
- `docs/reference/sdk-and-licensing-research-2026-09-12.md`: verified Vision/AVFoundation API names,
  install base, XcodeGen vs Tuist, detector licences, rulebook dimensions.
- `docs/DECISIONS.md`: answers to the brief's open questions, with evidence.

## Toolchain
Xcode 27.0 (27A266a), iOS 27.0 SDK, Swift 6.4 — verified 2026-09-25. `project.yml` still declares
`xcodeVersion: "26.6"`; XcodeGen accepts it. iPhone 14 Pro paired (`xcrun devicectl list devices`).
If only Command Line Tools are active, `GeometryChecks` still runs.

**`swift test` inside the repo fails to codesign**: *"resource fork, Finder information, or similar
detritus not allowed"* on the test bundle. This folder is file-provider-synced, so `com.apple.FinderInfo`
lands back on the build product during the build and `xattr -c` does not hold. Build outside the tree —
`swift test --scratch-path <dir under /tmp>`, and `-derivedDataPath` likewise for `xcodebuild`. A gate
that cannot run is a gate that cannot fail, so do not read a skipped `swift test` as a pass.
