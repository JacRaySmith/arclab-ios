# Why three-point shots are refused — one turn of the loop (2026-09-24)

**Answer in one line:** on `footage/2026-09-13/IMG_1766` it is not the ball, the azimuth or the focal
length — the hand-traced rim's own plane normal is **15° from vertical**, which reads the release
height `L·sin 15°` too low, and that error grows with shot distance. Constraining the rim solve to a
measured gravity direction takes the threes clip from **1/25 to 11/25** accepted with the free-throw
control flat (**12/30 → 11/30**). A clean trace does slightly better still (12/25) and keeps `g`
honest (1.0 % vs 4.6 % median error), so the solver change is a **safety net, not the cure**.

Everything below was produced with `--no-pose`, `--time-scale 4`, the probe's default `--hfov 64`,
rim diameter 0.4572 m, and the app's acceptance rule as `TrajectoryProbe session` applies it
(gravity within 8 %, release height 1.6–3.3 m, speed 4.5–11 m/s, depth −0.6…1.0 m, reprojection
residual ≤ 25 px).

## 1. Baseline, measured here

| clip | block | windows | accepted | rate |
|---|---|---|---|---|
| `IMG_1766.mov` + `rim_1766.json` | threes | 25 | **1** | 4 % |
| `IMG_1765.mov` + `rim_1765.json` | free throws | 30 | **12** | 40 % |

Same direction as the phone logs (33 % vs 76 %), further apart because `--no-pose` removes the
wrist-based release instant. Commands:

```
TrajectoryProbe session footage/2026-09-13/IMG_176{5,6}.mov \
  --rim footage/2026-09-13/rim_176{5,6}.json --time-scale 4 --no-pose --out base_176{5,6}.json
```

### What the refusals actually say

Refusal reasons over the refused windows (one window can trip several):

| reason | IMG_1766 (24 refused) | IMG_1765 (18 refused) |
|---|---|---|
| release height outside 1.6–3.3 m | **16** | 3 |
| `g_fit` beyond 8 % | 11 | 8 |
| reprojection residual > 25 px | 6 | 5 |
| depth outside −0.6…1.0 m | 5 | 1 |
| no release recovered | 5 | 11 |
| release speed outside 4.5–11 m/s | 3 | 3 |
| analysis threw | 1 | 3 |

Median release height over *all* windows: **1.11 m on the threes, 2.63 m on the free throws.**

### The signature: systematic, not scattered

Nine of the 25 three-point windows solve to a fitted release distance of 5.9–7.0 m — the real
three-point releases (the 6.75 m line puts the ball at ≈ 6.45 m). Their reported release heights:

| window | 18 | 17 | 9 | 8 | 4 | 10 | 11 | 13 | 19 |
|---|---|---|---|---|---|---|---|---|---|
| L (m) | 5.92 | 6.11 | 6.29 | 6.31 | 6.40 | 6.57 | 6.58 | 6.59 | 6.99 |
| release h (m) | 1.54 | 1.35 | 1.11 | 0.93 | 0.81 | 0.48 | 0.42 | 0.52 | 0.58 |
| `g_fit` | 9.86 | 10.23 | 10.35 | 10.19 | 10.53 | 10.30 | 10.22 | 10.40 | 10.72 |

A human releases a three between about 2.3 and 2.9 m. Every one of the nine is **low, by the same
sign**, median −1.8 m, and the spread *within* the group (SD 0.39 m) is a fifth of the offset. Their
solved azimuths agree to a few degrees. A detection problem scatters; this is a calibration problem.

## 2. Root cause, with three independent numbers

`RimCalibrator` on each trace at `--hfov 64`:

| trace | camera pitch | camera roll | rim distance | implied lens height |
|---|---|---|---|---|
| `rim_1766.json` (hand) | 1.8° | **−18.0°** | 7.70 m | 0.74 m |
| `rim_1765.json` (hand) | 5.4° | −3.0° | 7.21 m | 1.03 m |

A tripod does not roll 18°. Two independent sources say it did not:

1. **The vertical vanishing point** of the light poles and fence posts on IMG_1766, measured in the
   2026-09-14 investigation and recorded in `docs/PHASE2-PREP.md`: (1837, −13064). Through the same
   intrinsics that is `up = (0.0639, −0.9917, 0.1120)` — **pitch 6.43°, roll −3.69°**. (It reproduces
   that document's independently quoted 6.3° pitch, so the arithmetic here is right.)
2. **An automatically found trace of the same rim**, `rim_1766_found.json` (already in the footage
   folder, made 2026-09-14): **pitch 6.9°, roll −3.4°** — 0.6° from the pole-derived vertical.

So the hand trace's own normal is **15.0° off**, and `docs/PHASE2-PREP.md` already recorded why: its
right end runs along the red backboard bracket at x = 1780–1817. The same document measured that no
horizontal circle fits that trace better than 6.2 px, against 1.7 px for IMG_1765.

**Why 15° is fatal at range and invisible up close.** The reported release height is the release
point's rise above the rim centre *measured along the calibration's `up`*, so an error ε in that
direction costs ≈ `L·sin ε`: 1.08 m at a free throw, **1.67 m at a three**, and nothing at all at the
rim — which is why the rim still reprojects perfectly and nothing in the old output complained.
`Packages/ShotGeometry/Tests/ShotGeometryTests/RimGravityTests.swift` pins that scaling.
IMG_1765's trace is 2–3° from gravity, worth ≈ 0.1 m, which is why free throws never showed it.

## 3. Candidates, ranked before testing

1. **Gravity-constrained rim normal.** Evidence above. Predicts release heights on IMG_1766 rise
   ~1.6 m into the believable band, acceptance rises, free throws barely move. Could be wrong if the
   pole-derived vertical is itself wrong — checked against the auto-found trace, 0.6°.
2. **Known shooting distance** (`AnalysisOptions.knownReleaseDistance`). Predicts the azimuth stops
   wandering. Could be wrong because it constrains the azimuth and cannot touch a tilted `up` — and
   it makes the reported distance an input rather than a measurement.
3. **Rim edge convention**, 0.4572 vs 0.489 (a 7 % scale change, the size of the g tolerance).
   Already ruled out by two direct measurements on 2026-09-14; re-tested here for completeness.
4. **Focal length**: the probe defaults to 64°, the measured values are 65.4° (IMG_1766) and 67.8°
   (IMG_1765). A few per cent of scale.
5. **Azimuth time range.** `Pipeline.swift`'s re-solve loop is `for _ in 0..<5 where !azimuthFixed`,
   and `azimuthByFixedGravity` sets `azimuthFixed = true` — so in the session path the azimuth is
   solved **once**, over the whole 2.4 s window including the held ball and the ball in the net, and
   never refined on the detected flight. Not tested this turn; see §7.

## 4. The change

`RimCalibrationOptions.knownUp` — a measured up direction in the camera frame. **Default `nil`, so
nothing that ships today changes** (verified: `TrajectoryProbe session` on IMG_1766 still prints
`accepted 1 of 25` after the change). When set:

- the rim plane's normal is taken from it, and only the rim's *position* is solved from the conic;
- the centre comes from a closed form (`poseWithKnownNormal`, derivation in the source) used as the
  starting point for `fitHorizontalCircle`: a 3-parameter Nelder–Mead fit of the horizontal circle to
  the traced ellipse, bounded to 0.4–2.5× the seed range;
- two warnings are added — how far the trace's own normal is from gravity, and the best residual any
  horizontal circle achieves against the trace. On IMG_1766 they read *15.0°* and *6.4 px*.

On the phone `knownUp` is CoreMotion's gravity vector negated. On archive footage it is the vertical
vanishing point of poles or posts.

No acceptance threshold was touched.

## 5. Before and after, per clip

Identical detections on both sides: the ball track was dumped once per clip and replayed through
`ShotAnalyzer` with the session's two-pass azimuth pooling and acceptance rule. The replay reproduces
`TrajectoryProbe session` **row for row** on both clips (1/25 and 12/30, same `g`, `h`, `v`, `L`).

**IMG_1766 — threes, 25 windows**

| run | accepted | med \|g err\| (accepted) | med residual (accepted) | release h, m | release v, m/s |
|---|---|---|---|---|---|
| baseline: hand trace, free solve | 1/25 (4 %) | 0.3 % (n=1) | 9.8 px | 2.30 (n=1) | 5.97 (n=1) |
| **+ `knownUp` from the pole VP** | **11/25 (44 %)** | 4.6 % | 8.3 px | 2.02 ± 0.34 | 9.08 ± 0.92 |
| auto-found trace, free solve (no code change) | 12/25 (48 %) | **1.0 %** | 7.2 px | 2.17 ± 0.42 | 8.62 ± 1.24 |
| auto-found trace + `knownUp` | 12/25 (48 %) | 1.2 % | 7.2 px | 2.18 ± 0.42 | 8.63 ± 1.25 |

**IMG_1765 — free throws, 30 windows (the control)**

| run | accepted | med \|g err\| (accepted) | med residual (accepted) | release h, m | release v, m/s |
|---|---|---|---|---|---|
| baseline: hand trace, free solve | 12/30 (40 %) | 1.5 % | 6.5 px | 2.59 ± 0.43 | 6.92 ± 0.71 |
| **+ `knownUp` from the pole VP** | 11/30 (37 %) | 1.3 % | 6.0 px | 2.66 ± 0.49 | 6.86 ± 0.65 |
| auto-found trace, free solve | 12/30 (40 %) | 1.8 % | 6.0 px | 2.67 ± 0.47 | 6.83 ± 0.70 |
| auto-found trace + `knownUp` | 11/30 (37 %) | 1.4 % | 6.0 px | 2.66 ± 0.49 | 6.86 ± 0.66 |

(`h` and `v` are median ± SD over the accepted windows of that run.)

A second consistency check the baseline fails and the fix passes: the camera and the station do not
move within a block, so the per-shot azimuths should agree. Baseline IMG_1766 pools 1 accepted shot
(pooling needs 3) and falls back to per-shot solves; with `knownUp` it pools **14 shots agreeing to
5.5°**, view angle 6.2° from side-on.

### Candidates that failed, with their evidence

| candidate | IMG_1766 | IMG_1765 | verdict |
|---|---|---|---|
| `--known-distance 6.45` on the tilted calibration | **0/25** | (4.4 m) 11/30 | worse than baseline — rejected |
| `--known-distance` *with* `knownUp` | 11/25, median h 1.86 m | 10/30 | adds nothing, costs height — rejected |
| rim outer edge 0.489 | 1/25 free, 1/25 with `knownUp` (median \|g err\| over all windows 34 %) | 11/30 | rejected, confirms 0.4572 |
| `--hfov` 65.4 / 66.5 instead of 64 | 1/25 free, 11/25 with `knownUp` at every value | 12/30, 11/30 | not the lever (still use the measured value) |

## 6. Is it distinguishable from chance?

Per-window verdict flips, paired on identical detections:

- **IMG_1766:** 11 refuse→accept (windows 4, 7, 8, 9, 10, 11, 13, 14, 16, 17, 18) and 1
  accept→refuse (window 20). McNemar exact, 12 discordant pairs with 11 in one direction:
  **two-sided p = 0.006**.
- **IMG_1765:** 1 accept→refuse (window 25), 0 the other way. **p = 1.0** — the control is flat, as
  a change that fixes threes without breaking free throws should be.

That p-value says the flips on IMG_1766 are not a coin toss *given these 25 windows*. It says nothing
about generalisation, and the honest caveat is bigger than the statistic: **the whole three-point gain
comes from one bad hand trace, on one clip, from one night, one court, one shooter.** The mechanism is
general — any trace that wanders onto a bracket tilts the normal — but the size of the win on another
session depends entirely on how bad that session's trace is. To be sure this is the cause of the
33 % acceptance on the 09-17 and 09-19 sessions, their own rim traces have to be checked against
gravity the same way; if those traces are clean, this is not their problem and the search continues.

## 7. Honest limits

- **The fix is second best.** A clean trace beats it on the same clip: 12/25 at 1.0 % median `g`
  error versus 11/25 at 4.6 %. `knownUp` can only fix the *normal*; the contaminated ellipse still
  sets the size and position, and the constrained fit compensates by pushing the rim from 7.70 m to
  8.73 m. That is where the residual +4.6 % `g` comes from. The change's real value may be the two
  warnings: the failure is now loud instead of silent.
- **The control loses a window** (12 → 11) and the constraint moves IMG_1765's implied lens height
  from 1.08 m to 0.79 m, *away* from the field note "lens 1.2 m". Either the pole-derived vertical
  for that clip is a couple of degrees off or the note is. On the phone the question does not arise —
  CoreMotion gives gravity directly — but **no phone-captured session has been tested**.
- **`--no-pose` throughout.** The release instant comes from the ball alone and lands early, so
  release speeds read high (8.6–9.1 m/s where the 2026-09-14 pose-based runs got 7.61 ± 0.11 m/s) and
  heights read low. It biases both sides of every comparison identically, so the before/after is
  sound, but no absolute release number here should be quoted at a shooter.
- **The Nelder–Mead range bound is a guard, not a result.** Without it a contaminated trace can drive
  the constrained fit to a degenerate minimum with the rim almost at the lens; a synthetic case did
  exactly that (0.23 m). The bound is loose (0.4–2.5× the seed) because the ellipse's angular size
  fixes the range far better than that.
- **`g` stays the check.** Nothing here feeds gravity into the final fit; `TrajectoryFitOptions.fixedG`
  is still used only by window detection and the azimuth scan.

## 8. Gates

- `swift test -Xswiftc -O` in `Packages/ShotGeometry`: **312 tests, 0 failures** (308 before + the 4
  added here) and **27 tests, 0 failures** in FormEvalKitTests. (The 43 figure in the task brief is a
  sub-suite count, not the FormEvalKit total.)
- `swift run -c release GeometryHarness` → **GATE: PASS**, scenario I still marginal and identical to
  `docs/PHASE1-REPORT.md`. The harness never sets `knownUp`, so it runs the unchanged code path.
- `TrajectoryProbe session … --no-pose` on IMG_1766 after the change: **`accepted 1 of 25`** — byte
  for byte the baseline, confirming no shipped default moved.

## 9. Next, ranked

1. **Fix the traces, and stop new bad ones at capture.** Validate every rim trace against CoreMotion
   gravity when it is made and refuse past ~5° disagreement. Worth more than any solver change
   (12/25 at 1.0 % `g` versus 11/25 at 4.6 %). Re-run the desktop sessions with `rim_176x_found.json`.
2. **Wire `knownUp` to CoreMotion in the capture path** and re-run a phone session. The data to test
   that does not exist yet.
3. **Check the 09-17 / 09-19 three-point sessions' own rim traces against gravity** before assuming
   they share this cause.
4. **Put the pose stage back and re-measure.** With a clean trace the three-point `g` error is already
   1.0 %, so the largest remaining error in what the user reads is the ball-only release instant.
5. **Refine the fixed-gravity azimuth on the detected flight window** (§3, candidate 5). Untested:
   `azimuthByFixedGravity` short-circuits `Pipeline.swift`'s re-solve loop, so held-ball and in-net
   samples sit in the azimuth solve for the whole session path.

## 10. Tooling this needed, and did not have

`Packages/ShotVideo/Sources/TrajectoryProbe/Probe.swift` is owned elsewhere right now, so the sweep
ran from a throwaway package in the scratch directory. Two flags would have made that unnecessary and
are worth adding:

- `session --gravity x,y,z` (or `--up-vp u,v`) → `RimCalibrationOptions.knownUp`.
- `session --dump-detections file.json`, and a `fit` sub-command that replays a dump. The detection
  pass costs ~2.5 min per clip; a geometry sweep over a dump costs under a second, which is the
  difference between four experiments and forty.
