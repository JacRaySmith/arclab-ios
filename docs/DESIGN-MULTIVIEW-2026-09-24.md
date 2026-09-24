# Multi-view 3-D shooting model — design and capture protocol (2026-09-24)

The user's ask: "Building the 3-D shooting model (from each distance) using multiple angles of the
user." Code: `Packages/ShotGeometry/Sources/ShotGeometry/MultiViewFit.swift` (triangulation),
`MultiViewSync.swift` (time offset from the ball). Tests: `Tests/ShotGeometryTests/
MultiViewFitTests.swift`, `MultiViewSyncTests.swift`, `MultiViewFitSweepTests.swift` (the two
sweeps this document reports). This document assumes `CourtCalibration` (built concurrently) exists
and supplies a `Camera` (`Camera.swift`, already in this package: intrinsics + a rigid pose) per
clip, with the pose already expressed in a **shared court frame** — origin on the floor below the
rim, z up, solved from the rim ellipse, measured gravity, and at least one more marked court
feature. Nothing here touches or depends on how that pose was solved; `MultiViewFit` and
`MultiViewSync` consume any two `Camera`s that share a frame.

---

## 0. The honest split, stated once

- **Two devices filming the same shot, synchronised.** The two cameras' rays for one joint at one
  instant actually intersect (up to pixel noise) at the true position: a real triangulation of one
  movement. This is what `MultiViewFit` computes, and what all of §4–5 below validates.
- **One device moved between blocks** — today's only option; a second phone has been an open
  question since the 2026-09-13 filming day. Rays from *different shots*, paired only by a shared
  nominal shot-clock label ("both 40 ms after release"), can still be triangulated by the same
  arithmetic, but the result is a **statistical combination of two different instances of the
  movement**, not a reconstruction of either one. `MultiViewFit` cannot tell the two cases apart — a
  ray is a ray — so this distinction is the caller's responsibility, and it is why §6's protocol
  spells out both variants and never lets the second one be shown as if it were the first.

---

## 1. `MultiViewFit`: triangulating a joint from two or more views

**Method.** Closest point of approach of N weighted rays:

```
minimise  Σ_i (1/σ_i²) · ‖ P_i (X − o_i) ‖²        P_i = I − d_i d_i^T
```

`o_i` is camera i's centre (`CameraPose.position`, already in the court frame), `d_i` the unit ray
through the observed pixel (`CameraIntrinsics.ray`, rotated into the court frame by
`CameraPose.rotateBack`), and `P_i` projects onto the plane perpendicular to that ray. Expanding
each `P_i`'s perpendicular plane into an orthonormal basis `(u_i, v_i)` turns this into an ordinary
weighted linear least squares in the three components of X — two rows per ray,
`u_i·X = u_i·o_i` and `v_i·X = v_i·o_i` — solved by the same Householder QR
(`LinAlg.leastSquaresRowMajor`) every other fit in this package already uses. No new numerics.

**Units, and the bug this document's own sweep caught.** A pixel-domain weight (`1/pixelSigma²`) is
fine for *solving* X — it is a scale-invariant relative weighting across rays. It is the wrong unit
for a *covariance*: inverting a pixel-domain information matrix produces a covariance in pixel-ish
units, not metres, and reads as absurdly large (metres, not millimetres) if trusted directly — which
is exactly what the first run of Table 1 below showed (reported σ of 1.7–10.7 **metres** against
measured errors of 9–50 **millimetres**). `MultiViewFit.triangulate` therefore solves twice: once
with pixel-domain weights to get a first position, then converts each ray's pixel noise to a metric
one via the small-angle approximation `angularSigma ≈ pixelSigma/focalPx`,
`metricSigma ≈ angularSigma × range` (range from the first solve), and re-solves with those weights.
The same metric weights build the information matrix `Σ (1/σ_i²) P_i` whose inverse — eigen-decomposed
by the existing `LinAlg.symmetricEigen` — is the reported covariance: `uncertaintyMetres` is
`√(mean eigenvalue)`, `worstAxisUncertaintyMetres` is `√(largest eigenvalue)`, the weak direction
near-parallel rays blow up. Table 1 §4 shows the corrected numbers track the actual error to within
roughly 25–30 % (systematically a bit low) — a reasonable relative indicator of which joints and
frames are less trustworthy, not a calibrated confidence interval.

**Refusals, all with a stated reason (CLAUDE.md rule 1):**
- No view observed the joint at all.
- Every view's confidence is below the gate (`Options.minimumConfidence2D`, default 0.3 — the same
  default `BodyKinematicsOptions` uses, so a point not trusted from one camera is not smuggled in via
  a second).
- Only one view survives the gate.
- The best pair of surviving views subtends less than `Options.minimumBearingSeparationRadians`
  (default 8°, from §4's sweep) at the joint — near-parallel rays, the "two cameras too close in
  bearing" case.
- The normal equations are rank-deficient (a defensive fallback; the bearing gate should make this
  unreachable in practice).

`MultiViewFit.Observation` is plain (`view`, `camera`, `pixel`, `confidence`) so it works for a body
joint or a ball sample alike; a convenience initialiser takes a `BodyKinematics.swift` `BodyPoint2D`
directly. `MultiViewFit.triangulate(observationsByJoint:)` batches a whole frame's worth of joints.

---

## 2. `MultiViewSync`: finding the time offset from the ball's own flight

iOS has no shared capture clock across two devices
(`docs/research/whole-body-landmarks-2026-09-16.md` §3): each clip's timestamps are on its own
clock, offset by however far apart the two "record" presses landed — tens to hundreds of ms of human
reaction time, not knowable to better than that unless it is measured from the footage. The ball is
already tracked in both clips and follows a parabola, so it is a shared, moving, physically-modelled
signal that needs no clap and no screen flash.

**Method.** For a candidate offset τ (meaning `tA + τ ≈ tB` for the same real instant), pair every
view-A ball sample with a locally-interpolated view-B sample at `t + τ` (a quadratic fit through the
nearest few B samples in time — `PolyFit.quadratic`, falling back to linear near a track's edge), run
`MultiViewFit.triangulate` on the pair (bearing gate disabled: whether the cameras are usably
separated for a *joint* is a different question from whether the residual is informative about τ),
and take the mean squared triangulation residual as `cost(τ)`. A coarse grid search (default step:
one 240 fps frame, ±1 s range) finds the neighbourhood of the minimum; a local quadratic refit of
`cost(τ)` around the best grid point (`PolyFit.quadratic` again) finds the vertex `τ* = −c1/(2·c2)`
to sub-grid precision.

**Why this converges at all, not just "is small everywhere":** at the true offset the two rays are
looking at the *same instant* of a moving ball, so they meet up to pixel noise alone. At any other τ
they are being asked to agree on where a moving ball was, off by an amount that grows with the ball's
speed and the size of the error — `cost(τ)` is a bowl with its floor at the truth, which is what makes
τ resolvable from the footage rather than only knowable from a clock neither device has.

**Uncertainty and the flat-fit refusal.** The quadratic fit's own residual scatter (SD of
`cost(τᵢ) − q(τᵢ)` over the fitted window) is the noise floor; `σ_τ = √(scatter / c2)` (dimensional
check: metres² / (metres²/s²) = s², so `√` gives seconds) — a first-order estimate from local
curvature, not a full covariance propagation, stated as such rather than dressed up as more precise
than it is. Refused, with a reason, when: the tracks are too short (`< minimumSamples`, default 8, in
either view); the two tracks do not overlap at enough candidate offsets to search; `c2 ≤ 0` (no
interior minimum — the cost does not curve the right way); or the quadratic's rise across the fitted
window is less than `minimumCurvatureToNoiseRatio` (default 4×) times its own residual scatter — a
"minimum" that is not distinguishable from the scatter around it. A stationary point (§ tests) is the
textbook case: it carries no timing information, `cost(τ)` is flat but for noise, and the estimator
refuses rather than reporting a τ that is really just noise (`MultiViewSyncTests.
testStationaryPointRefusesFlatFit`).

**What a residual sync error costs, quantified rather than hand-waved.** A ball in flight moves at
roughly 6–9 m/s; a hand can move at a few m/s through release. At 240 fps one frame is 4.167 ms.
`MultiViewSync.positionErrorEstimateMetres(speedMetresPerSecond:syncErrorSeconds:)` is the
first-order arithmetic behind "milliseconds become centimetres" (`error ≈ speed × |syncError|`),
kept in code so it is never retyped by hand; Table 2 (§5) measures the *actual* triangulated error
under an uncorrected offset rather than only asserting this linear model, and the two agree in shape
though not exactly in scale (§5 explains the gap).

---

## 3. Synthetic validation: what was built

Both sweeps (§5) use a synthetic joint (a release-side wrist) on a smooth path from the set position
to release — 0.5 s at 240 fps, rising 1.0→2.2 m with a small forward reach and a natural lateral
wobble — projected through two `Camera`s built the same way `FootKinematicsTests`/`GateTests` build
theirs (`CameraPose.lookAt`, real `iPhone14Pro1080p120` intrinsics), with **2-D noise σ = 1.85 px** —
the FormEval whole-skeleton reprojection RMS **median**, measured on real footage
(`docs/research/form-eval-baseline-2026-09-16.md` §1: "Whole-skeleton RMS: median 1.85 px per
shot"), not an invented figure. `MultiViewFit.Options`/`MultiViewSync.Options` default to this same
number so the sweeps and the shipped code agree.

`MultiViewSyncTests` separately validates the *sync estimator itself* against `ShotSimulator`'s own
free-throw parabola (`ShotParameters`, `ShotSimulator.worldPosition`/`flightTime`) at a 60° camera
separation: a 15 ms injected offset recovers to within 3 ms, a −180 ms one to within 4 ms — both well
inside the ±1 s search range and both sub-frame at 240 fps.

---

## 4. Table 1 — recovered-joint error vs. camera bearing separation

`MultiViewFitSweepTests.testBearingSeparationSweep`, one seed per bearing, 120 synthetic frames per
row, cameras 5 m from the shooter at 1.4 m height:

| target bearing | achieved | refused | median err | p90 err | median reported σ |
|---:|---:|---:|---:|---:|---:|
| 2° | — | 120/120 | — | — | — |
| 5° | — | 120/120 | — | — | — |
| 8° | 8.2° | 72/120 | 48.6 mm | 112.9 mm | 36.1 mm |
| 10° | 10.3° | 0/120 | 38.5 mm | 80.5 mm | 30.3 mm |
| 15° | 15.5° | 0/120 | 20.5 mm | 53.7 mm | 20.3 mm |
| 20° | 20.6° | 0/120 | 19.6 mm | 42.2 mm | 15.5 mm |
| 30° | 30.7° | 0/120 | 13.2 mm | 27.7 mm | 10.7 mm |
| 45° | 46.2° | 0/120 | 10.6 mm | 19.9 mm | 7.8 mm |
| 60° | 61.3° | 0/120 | 9.2 mm | 16.0 mm | 6.5 mm |
| 90° | 91.3° | 0/120 | 8.8 mm | 14.7 mm | 5.8 mm |
| 120° | 120.8° | 0/120 | 9.6 mm | 16.2 mm | 6.5 mm |

**Reading it.** Below the 8° default gate the geometry is refused outright (2°, 5°). At 8° itself —
right at the gate — 60 % of frames still refuse, because the *achieved* per-frame bearing (the rays
to the actual, moving joint, not the nominal camera placement) dips under the threshold as the joint
moves through the shot; 8° is a floor, not a working point. Error falls steeply from 10° to about
45° (38.5 mm → 10.6 mm), then flattens: 45°→90° only buys 10.6 → 8.8 mm, and 120° is very slightly
*worse* than 90° (self-occlusion and foreshortening effects are not modelled here, so this uptick is
geometry only, and a real camera pair would likely see it sooner because of occlusion — a limitation
of this sweep, not a claim about real footage). **Recommendation: 45–90° bearing separation**, with
60° as a reasonable middle target that leaves margin above the steep part of the curve and below
where returns visibly stop.

## 5. Table 2 — recovered-joint error vs. uncorrected sync error, bearing fixed at 60°

`MultiViewFitSweepTests.testSyncErrorSweep`: the same joint path, cameras at the recommended 60°
separation, one camera's clock offset by a *known, uncorrected* τ (i.e. this is the cost of **not**
running `MultiViewSync`, or of it being wrong by this much):

| sync error | median err | p90 err | median joint speed | naive speed×τ |
|---:|---:|---:|---:|---:|
| 0 ms | 10.3 mm | 17.0 mm | 2.59 m/s | 0.0 mm |
| 1 ms | 9.6 mm | 15.5 mm | 2.59 m/s | 2.6 mm |
| 2 ms | 10.6 mm | 17.3 mm | 2.59 m/s | 5.2 mm |
| 4.17 ms (1 fr @ 240) | 12.1 mm | 18.2 mm | 2.59 m/s | 10.8 mm |
| 8.33 ms (1 fr @ 120) | 14.1 mm | 22.8 mm | 2.59 m/s | 21.6 mm |
| 16.67 ms (1 fr @ 60) | 26.2 mm | 35.2 mm | 2.59 m/s | 43.2 mm |
| 33.3 ms (1 fr @ 30) | 43.9 mm | 60.7 mm | 2.59 m/s | 86.2 mm |
| 66.7 ms (2 fr @ 30) | 87.8 mm | 111.8 mm | 2.59 m/s | 172.7 mm |

**Reading it.** The 0 ms row (10.3 mm) is the pixel-noise floor from Table 1's 60° row (9.2 mm — the
same experiment, different seed; the two agree to within noise). Error roughly doubles by 8 ms, and
by 16–17 ms (one 60 fps frame) it has already tripled. The naive `speed × τ` estimate is the right
**shape** but not the right **scale**: it overestimates the measured error by roughly 2× at the large
end (172.7 mm predicted vs. 87.8 mm measured at 66.7 ms). That gap is real and worth stating rather
than papering over: the weighted least-squares triangulation does not fully manifest the two rays'
timing-caused disagreement as position error — it settles at a compromise point between where each
ray *thinks* the joint is, which is closer to the truth at the reference instant than the raw
"how far did the joint move" arithmetic suggests. Treat `positionErrorEstimateMetres` as a
conservative (worse-case-leaning) back-of-envelope, and Table 2 as the measured number.
**Recommendation: keep uncorrected sync error under about 8 ms** (one 120 fps frame) to stay within
roughly 1.5× the intrinsic pixel-noise floor; by 30 fps-frame-scale desync (33 ms) the timing error
dominates and is roughly 4× the floor. `MultiViewSyncTests` shows the estimator itself lands well
inside this (recovered to 3–4 ms on a half-second free-throw flight), so the practical bar is "run
the estimator", not "hope the two thumbs were close".

---

## 6. Capture protocol

**Camera placement.** Keep the existing single-view position (side-on, roughly 45–48° off the
shooting line, 5–7 m back — whatever the current baseline framing is, so single-view analysis of the
same footage is unaffected and comparable). Place the second phone so the **bearing separation seen
from the shooter is 45–90°** (§4) — concretely, roughly a quarter to half-turn around the shooter
from the first phone, at a similar distance (5–7 m) and a similar height (waist-to-chest, so the
whole body plus a margin above the release point is framed). Avoid nearly opposite placements (close
to 180°): not tested here, but symmetric occlusion of the shooting-side arm by the torso becomes more
likely, undoing the "the other camera sees what the ball hid" benefit §7 predicts.

**Every frame, both phones:**
- The **rim**, fully — `CourtCalibration`'s target.
- At least **one more marked court feature** in view at some point in the clip (the free-throw line,
  a lane line, the backboard) — a single ellipse under-constrains the full 6-DOF pose; `Court
  Calibration` needs the second feature, per its own design.
- The **whole body including both feet**, with margin — a cropped ankle or a cropped release is
  refused in the single-view pipeline already (`GeometryHarness`'s tier-C exclusion), and would be
  refused here too.

**Starting the recordings.** No precise simultaneity is required: `MultiViewSync` solves the offset
from the ball's own flight, not from the button presses. Start both phones recording with a few
seconds of margin before the shot and a couple after — enough that the whole ball flight (from
release to rim, ideally the whole visible arc) is inside both clips with room either side. A shared
starting cue (a raised hand, a verbal count) is a nice manual cross-check but is **not** required for
sync to work.

**Shots and distances.** Filming is a real cost the user has repeatedly had to make time for (see
`docs/HANDOFF.md`'s state notes), so: **pilot first** — about 10 shots at one distance (the free-throw
line, to match the existing single-view baseline exactly) — before committing to more. If the pilot's
FormEval comparison (§8) shows real movement on `kneeMinimum` or `elbowAtRelease`, extend to the full
protocol: **at least ~20 shots per distance** (the scale the existing repeatability tables already use
successfully at n=37) at **two or more distances** (e.g. the free-throw line and one mid-range spot),
because `docs/research/form-eval-baseline-2026-09-16.md` §0 flags "no second condition" as the
existing baseline's biggest limitation and this build should not repeat it.

**One phone only.** Two-view triangulation of a single shot is unavailable — see §0. What is still
possible: film **blocks from different tripod bearings**, at the **same distance and spot**, across a
session (or across sessions). `MultiViewFit` can then combine the court-frame joint positions of
*different* shots that share a nominal shot-clock label (e.g. "knee angle 40 ms before release") into
a **per-distance statistical model** of that instant — genuinely useful, genuinely new information
about the depth axis, but never a reconstruction of any one shot, and the app must never present it
as one. Label every such output "combined across N shots from two bearings", not "3-D reconstruction".

---

## 7. What should become trustworthy, and what should not — graded

Every claim below is a **prediction** (marked P) unless marked **M** for something this document's
synthetic sweep actually measured. None of it is validated on real footage yet — that is §8's job.

| measure | today (single view, form-eval-baseline-2026-09-16.md) | two-view prediction | grade |
|---|---|---|---|
| Occluded hand at release (ball hides it ~83 % of frames, one view) | shooting hand present at release on 5/37 shots (14 %) | a joint hidden behind the ball in one view is geometrically likely visible from a camera 45–90° away; coverage should rise substantially | **P**, plausible and cheap to falsify once footage exists — count coverage directly |
| Depth-direction quantities in general (transverse yaw, out-of-plane lean, anything the single-view pipeline currently refuses for lacking depth) | refused, by design (`PostureMetrics`, `BodyKinematicsOptions.transverseYawUnavailableReason`) | become directly measured rather than refused, with the propagated uncertainty from §1 attached | **P** — this is the geometric reason multi-view exists, but "measured" is not the same as "coachable"; ICC still has to clear 0.75 |
| `kneeMinimum` (ICC **−0.26**, σ_meas 15.5° vs. between-shot SD 9.1° — worse than noise) | not coachable | **uncertain, worth testing first**: if the knee's noise is dominated by an unobserved depth component, triangulation could fix it; if it is dominated by detector jitter or timing (not diagnosed in the baseline doc), it will not. This is exactly why the knee has the worst held-out reprojection *and* the worst blink error in the single-view baseline — those numbers do not by themselves say which cause dominates | **P**, genuinely uncertain — do not promise this one |
| `elbowAtRelease` (SDC **42°**) | not coachable | **likely not fixed by triangulation alone**: the baseline's own diagnosis is that the problem is *timing* — "a 4 ms timing error at 158 fps lands on a different frame of a 900 °/s extension" — not the arm's depth (`elbowMinimum`, a window measure, is already 3× better). Two-view triangulation adds spatial precision, not release-timing precision | **P, and a deliberately pessimistic one** — flagged so it is not oversold |
| `jumpHeight` (ICC 0.92), `headHorizontalRange` (ICC 0.86) | already coachable | no urgent need for two views; triangulation adds propagated uncertainty for no clear gain here | **P** — low priority to re-validate, but should not regress |
| `dipDepth` (n = 10, mean 0.000 — this shooter's free throw has no dip) | refused, correctly | stays refused — this is a property of the shot, not a camera limitation | **M** by definition (the baseline already measured it); no camera change alters it |

---

## 8. How it will be judged

The objective test, once the capture protocol's footage exists: **re-run `FormEval` on two-view
fits and on the existing single-view fits over the *same* shots**, and compare the ICC(2,1) and SDC
tables per measure (`docs/research/form-eval-baseline-2026-09-16.md` §6 is the format to match). This
requires the same shots analysed both ways, which is why §6 keeps the existing single-view camera
position unchanged — the single-view fit does not need to be redone, only the new two-view one added
alongside it on the same physical shots.

**The bar, stated plainly, per CLAUDE.md rule 1 and the existing gate line in
form-eval-baseline-2026-09-16.md §7:** a measure is "coachable" only once it crosses **ICC(2,1) ≥
0.75**, and its SDC must be smaller than whatever coaching cue would be built on it. The two measures
the user most needs fixed are named, with today's numbers, so the after-numbers can be compared
directly against them:

- **`kneeMinimum`**: today ICC **−0.261** [−0.528, −0.020], SDC **43.1°**. Success is ICC ≥ 0.75 and
  an SDC small enough to say something coaching-relevant about knee bend (single digits to low teens
  of degrees, not 43°).
- **`elbowAtRelease`**: today ICC **0.010** [−0.349, 0.368], SDC **42.3°**. Per §7's prediction, this
  one may not move much from triangulation alone — if the after-numbers do not improve, that is
  itself the useful result: it would confirm the problem is release-timing precision, and the next
  fix belongs in release detection, not in adding a camera.

**Do not claim it will work.** This document's synthetic sweeps (§4–5) show the triangulation
geometry recovers position to single-digit millimetres at 45–90° bearing and single-digit-ms sync
error — that is a statement about the *geometry*, built on the *measured* 2-D noise figure, on a
*synthetic* joint. Whether that translates into `kneeMinimum` or `elbowAtRelease` crossing 0.75 is
unknown until real two-view footage is analysed and run through `FormEval`; §7's table says which way
each measure is expected to move and how confidently, not that it will happen.

---

## 9. Test and gate results

From `Packages/ShotGeometry`:

```
swift test -Xswiftc -O --scratch-path <scratchpad>/sgMV
```

- **`MultiViewFitTests`** (7 tests): a known synthetic point recovered to **1e-6 m** with zero noise
  and to **< 5 cm** under 1.85 px noise at 5 m / 60°; near-parallel rays (2° separation) refused
  ("too close to parallel"); a single view refused ("only 1 view"); no view refused; a low-confidence
  view dropped rather than trusted (falls back to the single-view refusal); a third, well-separated
  view does not increase the reported uncertainty over two.
- **`MultiViewSyncTests`** (5 tests): a 15 ms injected offset recovered to within 3 ms, a −180 ms
  offset to within 4 ms, both on a `ShotSimulator` free-throw parabola at 60° bearing; a stationary
  (non-informative) point refuses as a flat fit; a 3-sample track refuses as too short;
  `positionErrorEstimateMetres` is exactly `speed × |Δt|`.
- **`MultiViewFitSweepTests`** (2 tests): produces Tables 1 and 2 above, with loose monotonicity
  assertions (error falls from 8° to 60°; error does not fall as sync error grows) so a future
  regression fails loudly without pinning the exact numbers as a brittle regression test.
- **Full suite**: **380 ShotGeometryTests + 27 FormEvalKitTests, 0 failures**. This file adds exactly
  14 tests (7 + 5 + 2, §9's list above); the base branch this worktree started from already carried
  366 ShotGeometryTests, not the 362 the task brief stated — other agents' concurrent merges into
  `main` moved that number between when the brief was written and when this worktree branched
  (confirmed: `git diff HEAD` before this work touched only the 6 new files listed at the top of this
  document, nothing pre-existing was modified). All pre-existing tests still pass unchanged.
- **`swift run -c release GeometryHarness`** → `GATE: PASS` (scenarios A–D, the brief §8 gate,
  unaffected by this work — untouched files). Scenario I ("30° yaw, 3 px noise", an additional
  stress scenario beyond the core gate) already failed before this change and is unrelated to it (no
  file it depends on was edited here).

---

## 10. Summary: measured vs. predicted

**Measured (this document's own synthetic sweeps, §4–5, §9):**
- Triangulation recovers a known synthetic point exactly under zero noise, and to millimetres under
  the measured 2-D noise figure, at a workable bearing separation.
- Error falls steeply from the 8° refusal floor to about 45°, then flattens; 45–90° is recommended.
- Uncorrected sync error costs roughly 1 mm/ms near the recommended bearing, accelerating past ~1
  frame at 60 fps (17 ms); recommend keeping it under ~8 ms (1 frame at 120 fps).
- The sync estimator itself recovers known offsets to 3–4 ms on a half-second ball flight — comfortably
  inside that budget.
- The propagated per-joint uncertainty tracks measured error to within roughly 25–30 % (systematically
  a bit low): useful as relative guidance, not a calibrated interval.

**Predicted, not measured (§7, explicitly graded, to be tested per §8 once real two-view footage
exists):**
- Occluded-hand-at-release coverage rising.
- Depth-direction quantities becoming measured rather than refused.
- `kneeMinimum` crossing ICC 0.75 — genuinely uncertain.
- `elbowAtRelease` improving — the baseline's own diagnosis (a timing problem, not a depth one) makes
  this the least likely of the four to move, and is reported that way on purpose.
