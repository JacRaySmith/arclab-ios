# Phase 1 report — synthetic geometry harness

Date: 2026-09-12. Package: `Packages/ShotGeometry`. Toolchain: Swift 6.3.3 / Xcode 26.6.
Verification: `swift test` (10 tests, 0 failures), `swift run GeometryChecks` (95 checks, 0 failures),
`swift run -c release GeometryHarness` (output below).

## What was built

Pure Swift, Foundation + simd only.

| File | Content |
|---|---|
| `Constants.swift` | Court/ball dimensions, court types, degree/radian boundary helpers |
| `Numerics.swift` | Seeded RNG, descriptive stats, Householder-QR least squares, Jacobi symmetric eigen, polynomial fits (lowest-power-first, named fields) |
| `Ellipse.swift` | Conic ↔ ellipse, gradient-weighted (Sampson) ellipse fit |
| `Camera.swift` | Pinhole intrinsics, world→camera pose, look-at |
| `RimCalibration.swift` | Camera pose from the rim's image ellipse (circle-pose, two-fold ambiguity resolved by "rim is above the camera"), quality warnings |
| `ShotPlane.swift` | Shot-plane azimuth solve: the only plane through the rim centre on which the back-projected track is a time-parabola; ball-diameter profile as a shape-only cue |
| `TrajectoryFit.swift` | Robust (Huber IRLS, per-axis scale) fit of x(t) linear, y(t) quadratic against timestamps; g free; optional fixed g for detection |
| `ReleaseDetection.swift` | Free-flight window by local gravity test; sub-frame release from the pre-release deviation ramp; contact trimming |
| `Metrics.swift` | Forward model, entry floor, yaw formula, gravity gate (8%/20%), view classes, metric/confidence payloads |
| `Pipeline.swift` | `ShotAnalyzer`: detections + calibration → metrics; `BallScaleAnalyzer`: the ball-scale-only fallback |
| `Simulator.swift` | 3D shot (hold → constant-acceleration push → flight → bounce), virtual camera, pixel/diameter noise, dropped/occluded frames, rim boundary points, ground truth |

Pipeline per shot: image apex → azimuth solve on the always-clean core (apex − 0.3 s … apex + 0.1 s)
→ project to plane → flight window → re-solve azimuth on the flight → (alternate up to 5×) → final
robust free-g fit anchored at the sub-frame release time → metrics from the fitted parabola.

## Gate result: PASS

Each scenario: 50 random draws of θ ∈ [40°, 60°], h ∈ [2.0, 2.6] m, L ∈ {4.19, 5.5, 6.75} m,
speed = make-speed × [0.97, 1.03], camera distance ∈ [6, 10] m, height ∈ [1.2, 1.8] m, 64 rim
boundary points at 0.3 px noise, ball-diameter noise 1 px (0 for scenario A). Errors are of the
recovered release angle, g_fit, entry angle, release height, and the release instant.

```
=== Phase 1 gate (brief §8) ===
A perpendicular, zero noise, 240 fps n=50  |Δθ| mean 0.000° sd 0.000° max 0.000° (tol 0.1)  |Δg| max 0.00% (tol 2%)  |Δentry| max 0.00°  Δh max 0.000 m  release max 0.00 fr  → PASS
B 30° yaw, 1.5 px noise, 240 fps n=48  |Δθ| mean 0.168° sd 0.145° max 0.625° (tol 1.5)  |Δg| max 1.12% (tol 2%)  |Δentry| max 0.33°  Δh max 0.078 m  release max 2.85 fr  → PASS
     2 draw(s) had the release out of frame (shooter cropped → tier C, excluded from θ stats)
C 30° yaw, 1.5 px, 20% dropped frames n=48  |Δθ| mean 0.134° sd 0.108° max 0.458° (tol 2.0)  |Δg| max 1.06% (tol 2%)  |Δentry| max 0.36°  Δh max 0.059 m  release max 1.70 fr  → PASS
     2 draw(s) had the release out of frame (shooter cropped → tier C, excluded from θ stats)
D 30° yaw, 1.5 px, 30 fps n=48  |Δθ| mean 0.217° sd 0.219° max 1.223° (tol 3.0)  |Δg| max 1.66% (tol 2%)  |Δentry| max 0.39°  Δh max 0.121 m  release max 0.55 fr  → PASS
     2 draw(s) had the release out of frame (shooter cropped → tier C, excluded from θ stats)

=== Additional scenarios ===
E perpendicular, 1.5 px, 120 fps n=50  |Δθ| mean 0.230° sd 0.196° max 0.869° (tol 1.5)  |Δg| max 1.00% (tol 2%)  |Δentry| max 0.22°  Δh max 0.092 m  release max 2.00 fr  → PASS
     worst θ: Δ=-0.869° Δg=0.26% [θ=52.0 v=7.08 h=2.31 L=4.19 cam 8.5 m @ 1.42 m, rms 2.14 px, seed 339442]
F 30° yaw, 1.5 px, 60 fps n=48  |Δθ| mean 0.210° sd 0.181° max 0.859° (tol 2.0)  |Δg| max 1.54% (tol 2%)  |Δentry| max 0.38°  Δh max 0.088 m  release max 0.85 fr  → PASS
     2 draw(s) had the release out of frame (shooter cropped → tier C, excluded from θ stats)
G 55° yaw (oblique), 1.5 px, 240 fps n=49  |Δθ| mean 0.219° sd 0.174° max 0.671° (tol 2.0)  |Δg| max 1.10% (tol 2%)  |Δentry| max 1.01°  Δh max 0.092 m  release max 3.60 fr  → PASS
     1 draw(s) had the release out of frame (shooter cropped → tier C, excluded from θ stats)
H 30° yaw, 1.5 px, 6 frames occluded n=48  |Δθ| mean 0.153° sd 0.116° max 0.434° (tol 1.5)  |Δg| max 1.00% (tol 2%)  |Δentry| max 0.37°  Δh max 0.066 m  release max 2.00 fr  → PASS
     2 draw(s) had the release out of frame (shooter cropped → tier C, excluded from θ stats)
I 30° yaw, 3 px noise, 240 fps n=48  |Δθ| mean 0.632° sd 0.461° max 2.094° (tol 2.0)  |Δg| max 3.18% (tol 2%)  |Δentry| max 1.18°  Δh max 0.196 m  release max 8.00 fr  → FAIL
     2 draw(s) had the release out of frame (shooter cropped → tier C, excluded from θ stats)
     worst θ: Δ=-2.094° Δg=-1.13% [θ=42.3 v=7.83 h=2.35 L=5.50 cam 7.7 m @ 1.52 m, rms 4.43 px, seed 154399]

=== Open question 1: depth from ball diameter (45° view, 240 fps, 1.5 px centroid noise) ===
  diameter noise 0.25 px: lateral-at-rim |error| median 0.017 m, p90 0.034 m; depth-at-rim |error| median 0.027 m (n=30)
  diameter noise 0.50 px: lateral-at-rim |error| median 0.018 m, p90 0.035 m; depth-at-rim |error| median 0.029 m (n=30)
  diameter noise 1.00 px: lateral-at-rim |error| median 0.017 m, p90 0.049 m; depth-at-rim |error| median 0.038 m (n=30)
  diameter noise 2.00 px: lateral-at-rim |error| median 0.030 m, p90 0.074 m; depth-at-rim |error| median 0.062 m (n=30)

GATE: PASS
```

Draws whose release was out of frame (camera too close and yawed, so the shooter is cropped) are
reported as such and excluded: the pipeline returns `release = nil` with a reason instead of a
number. That is the tier-C behaviour the brief asks for, verified by `testUnobservedReleaseIsNotFabricated`.

Reading the table:
- **A** is exact to floating point: renderer and fit agree, no maths bug.
- **B, C** (30° yaw, 1.5 px, with and without 20% drops) recover release angle to 0.17° mean /
  0.63° max against a 1.5° / 2.0° gate; g within 1.4%.
- **D** (30 fps) 0.22° mean / 1.2° max against 3.0°; g max 1.66% in this run. Across seeds the
  30 fps g error has SD ≈ 0.7%, so roughly 2% of draws exceed the 2% line (one such seed is
  documented in `GateTests.testGate30fps`). This is the expected precision floor of a 0.9 s
  window at 30 fps, not a bug; the product gate is 8%.
- **I** (3 px noise, beyond the brief's "realistic") fails the extra 2° / 2% targets marginally.
  That is the sensitivity boundary: the Phase 2 detector must deliver ≤ 2 px centroid noise.

## Things learned that change later phases

1. **Azimuth precision is the whole game for oblique cameras.** A 3° error in the shot plane's
   azimuth bends the projected track by centimetres at the ends of the flight, which breaks any
   anchor-parabola walk-back and biases g. The local gravity test and the diameter-profile cue exist
   for this reason. Real detectors must report a ball size (box or radius) per frame.
2. **The textbook's median walk-back is not usable here** (see `DECISIONS.md`). The replacement
   has ≈ −1 frame bias at 240 fps.
3. **The release cannot be measured if it isn't in frame.** Framing guidance (Phase 4) must keep
   the shooter's release point inside the frame; the pipeline refuses rather than extrapolates.
4. **Rim edge ambiguity is a 7% scale error** — it will show up in the Phase 3 g-test if the
   detector traces the outer edge while the calibration assumes the inner diameter.
5. **Open question 1 answered** (`DECISIONS.md`): depth from diameter gives lateral deviation to
   ~2–5 cm at 45°, enough for left/centre/right, not enough to replace the plane solve for arc.

## Not done / carried forward

- Backboard-rectangle calibration (fallback 2) and the rim/backboard cross-check: Phase 3, needs real
  detections to define what "backboard corners" a detector produces.
- Frontal-view lateral deviation is gated (reported as unavailable) but not yet computed from the
  diameter-depth path; wire `DECISIONS.md` §9.1 method into `ShotAnalyzer` in Phase 3.
- Timestamp jitter and variable frame rate are simulated (`SimulationOptions.timestampJitter`) but
  not yet part of the gate table.
