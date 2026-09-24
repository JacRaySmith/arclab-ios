# Bench results — pooling the shot-plane azimuth (2026-09-24)

**The hypothesis: the camera and the shooter do not move inside a filming block, so the shot-plane
azimuth is one number per block rather than a free parameter per shot; solving it per shot lets
detection noise ride into release height, release speed and the fitted g, and that is why accepted
windows inside one block disagree about release height by 0.4 m.**

**Result: ruled out on this corpus, with numbers.** The per-shot azimuth inside a block already
agrees to a robust spread of 1.2° (elbow) and 2.5° (three); release height moves ~0.025 m per degree
of azimuth, so azimuth scatter can account for ~0.03–0.07 m of a 0.22–0.35 m within-block spread —
a few percent of the variance. Every pooling rule tried either left the corpus where it was or made
it worse, and on the windows accepted in *both* arms, pooling **widened** the within-block spread
(elbow 0.219 → 0.257 m, three 0.348 → 0.423 m). The free-throw clip's "shots disagree by 45°" is
not a noisy solve and not a bimodal solve of one geometry: it is **two genuinely different shooting
positions inside one clip**, so that block is not one block, and pooling a single azimuth over it
costs 8 of its 12 accepted shots (p = 0.008).

Everything here replays the same cached corpus as `docs/BENCH-RESULTS-2026-09-24.md` (98 windows,
`IMG_1764`/`IMG_1765`/`IMG_1766`, 2026-09-13 filming night) through `ShotBench`. **One night, one
court, one shooter, three clips** — these numbers are evidence about this footage.

**No shipped default moved.** This experiment touched only `Packages/ShotGeometry/Sources/ShotBenchKit`,
`Sources/ShotBench`, tests and docs. `ShotPlane.swift`, `Pipeline.swift`, `Probe.swift`, the app and
every gate threshold are untouched; the new variants are bench entries, not a change to what the app
does.

## 0. How recall and precision are scored here

The corpus is labelled by window (`docs/footage-2026-09-13/window_labels.json`: 88 `shot`,
6 `notShot`, 4 `unsure`). Recall = labelled shots accepted ÷ labelled shots; precision = accepted
windows that are labelled shots ÷ accepted windows that carry a `shot`/`notShot` label. **`unsure`
windows are excluded from both metrics entirely** — neither numerator nor denominator — rather than
folded into `notShot`. Scored by joining each scorecard's `windows[].accepted` to that file by
`windowID`. The reference variant's numbers reproduce the figures this task started from exactly
(overall 56.8 %, elbow 71.8 %, free throw 39.3 %, three 52.4 %, precision 100 % everywhere), which
is the cross-check that the join is right.

**Precision stayed at 100 % for every variant in this document, including the ones that fail.** Not
one accepted window across the whole experiment was a labelled non-shot. Nothing here trades
precision for recall, because nothing here gained recall at all.

## 1. Diagnosis: what the per-shot azimuth actually looks like

`ShotBench azimuth <cache> --variant autoFoundTrace` (new subcommand) solves each window's azimuth
on its own — `ShotPlaneSolver.solveByFixedGravity` over the whole track, under the auto-found rim
calibration — *before* any pooling decision, including for windows whose later analysis throws. Per
clip, over every window that produced a solve:

| clip | windows solved | robust centre | 1.4826·MAD of the kept core | dropped by the outlier rule | shape |
|---|---:|---:|---:|---:|---|
| `IMG_1764` elbow | 42 of 43 | 276.60° | **1.16°** | 13 | one mode + junk |
| `IMG_1765` free throw | 30 of 30 | 289.80° | **37.54°** | 0 | **two modes** |
| `IMG_1766` three | 25 of 25 | 275.08° | **2.53°** | 8 | one mode + junk |

- **Elbow**: 28 of the 42 solves lie inside 273.2°–278.6°, and those 28 are exactly the 28 accepted
  windows. The 13 the outlier rule drops are the windows whose solve is degenerate anyway (see §5).
- **Three**: 17 solves inside 269.5°–278.5°, which contain all 14 of the clip's accepted windows.
  Of the 8 the outlier rule drops, seven sit at 314°–332° and imply a ball
  0.03–0.14 m across at 0.5–2.5 m from the camera, and the eighth (127°) implies a 0.38 m ball —
  nonsense tracks, not a second shooting position.
- **Free throw**: two well-populated modes, **241.3°** (13 windows) and **293.7°** (15 windows), 52°
  apart, with junk filling the valley between them.

### The free-throw disagreement is two shooting positions, not a bimodal solve

This matters because the two diagnoses need opposite treatments. The evidence says the shooter (or
the ball) was genuinely in two different places, so the clip is not one block:

| | mode A (~241°) | mode B (~293°) |
|---|---|---|
| first detection, image u / v | 662–746 px / 467–617 px | 289–395 px / 394–452 px |
| largest detected ball diameter | 89–102 px | 126–148 px |
| depth of the first detection under its own plane | 8.8–9.2 m | 4.5–4.9 m |
| implied ball diameter `d_px·z/f_x` under its own plane | 0.274–0.284 m | 0.269–0.286 m |
| release distance from the rim centre | 3.7–4.4 m (median 4.16) | 3.5–5.1 m (median 4.72) |
| azimuth-solve residual / ambiguity ratio | 0.02 m / 0.25–0.31 | 0.01–0.02 m / 0.12–0.19 |

The decisive line is the implied ball diameter. It is computed from each window's *own* solved
plane and the detector's pixel diameters, and it does not know about gravity. Both modes give the
same ≈0.28 m — a size-7 ball (0.2413 m) plus the detector's uniform ~15 % box bias, the bias
`ShotPlaneSolver.objective` already absorbs with a free scale factor. If mode A were the *wrong
branch* of mode B's geometry, its depths would be wrong by the ratio of the two depths (≈1.9×) and
its implied diameter would come out near 0.45 m, not 0.28 m. It does not. The raw pixels agree: the
two modes' first detections are 300 px apart in the image and their balls differ in size by ~1.4×,
which is a different place on the court, not a different solution for the same place.

They also **alternate shot by shot in time** (B, A, B, A, B, B, B, A, B, A, B, A, B, A, A), rather
than occupying two stretches of the clip — consistent with a shot from the line and then a shot from
wherever the ball was chased down, repeatedly.

**The honest caveat**: the two modes' release *heights* disagree (mode A median 2.71 m, mode B
2.08 m) and one shooter does not have two release heights, so at least one mode carries a systematic
height error even though its geometry is self-consistent. The window labels record "shot" and
nothing about where the shooter stood, so nothing in the corpus says which mode is the free-throw
line. What is settled is the thing this experiment needed to settle: **that clip must not be pooled
to one azimuth**, on either reading.

## 2. Sensitivity: how much is a degree of azimuth worth?

`autoFoundAzimuthOffset5` is a deliberately wrong variant — the clip's robust pooled azimuth plus
exactly 5° — run only to measure the derivative on real windows. Paired against
`autoFoundPooledMedian` (the same pooled azimuth, unoffset) over the windows accepted in both arms:

| clip | n | median &#124;Δazimuth&#124; | median &#124;Δrelease height&#124; | ⇒ d(height)/d(azimuth) | median &#124;gErr&#124; |
|---|---:|---:|---:|---:|---|
| elbow | 27 | 5.00° | 0.103 m | 0.021 m/° | 0.028 → 0.057 |
| free throw | 4 | 4.95° | 0.114 m | 0.023 m/° | 0.014 → 0.047 |
| three | 8 | 5.00° | 0.157 m | 0.031 m/° | 0.012 → 0.054 |

Two things follow, and they are what rules the hypothesis out:

1. **Release height moves ≈0.025 m per degree.** The within-block azimuth spread is 1.16° (elbow)
   and 2.53° (three), so azimuth scatter contributes ≈0.03 m and ≈0.07 m to those blocks'
   release-height SDs, which are 0.219 m and 0.331 m. In variance terms that is 2–4 %. **An azimuth
   SD of ~13° would be needed to produce a 0.35 m height spread; the measured one is 1–3°.**
2. **The gravity gate costs ≈0.0074 of g-error per degree** (median |gErr| 0.019 → 0.056 for 5°), so
   an azimuth would have to be ~11° out before it alone broke the 8 % gravity gate. Nothing inside a
   block's core is anywhere near that.

A third, slightly surprising, observation: the deliberate 5° error did **not** widen the within-block
spread (elbow 0.231 → 0.167 m, three 0.468 → 0.357 m over the common windows). On this corpus an
azimuth error acts as a largely common-mode shift of a block's release heights, not as the source of
the shot-to-shot scatter — which is the same conclusion from the other direction.

## 3. The variants

All six sit on `autoFoundTrace`'s calibration (the rim fix is already established) and differ from it
in exactly one thing: the pooling rule. Defined in `Packages/ShotGeometry/Sources/ShotBenchKit/Variants.swift`,
estimators in `CircularStats.swift`.

- **`autoFoundNoPool`** — control: no pooling at all, every window keeps its own solve.
- **`autoFoundPooledMedian`** — robust circular **median** over **all** windows' per-shot solves
  (accepted or not). Outlier rule, stated in code: `c₀` = circular median; `MAD` = median circular
  distance to `c₀`; drop everything farther than `max(3 · 1.4826 · MAD, 4°)` from `c₀`; the centre is
  the circular median of the survivors. The floor stops a pathologically tight core from rejecting
  its own members.
- **`autoFoundPooledMedianAccepted`** — the same estimator over the accepted windows only, to
  separate "median + MAD instead of mean + 25° spread" from "all windows instead of accepted ones".
- **`autoFoundPooledGated`** — the same, but a clip is pooled only when the surviving azimuths'
  robust spread (1.4826·MAD) is ≤ 10°: agreement measured robustly, replacing "≥3 accepted shots and
  no accepted shot more than 25° from the mean".
- **`autoFoundPooledIterated`** — pool, then re-solve every window's azimuth over only the flight
  window the pooled azimuth implies (held-ball and in-net samples excluded, via
  `AnalysisOptions.azimuthTimeRange`), re-pool, repeat; ≤4 rounds, stop when the centre moves < 0.25°.
- **`autoFoundPooledClustered`** / **`autoFoundPooledClusteredTight`** — the candidate the diagnosis
  asked for: cluster the clip's azimuths by circular gap (15° / 10°), pool *within* each cluster of
  ≥4 windows, and let a window outside every qualifying cluster keep its own solve.

## 4. The table

Reference = `autoFoundTrace` (legacy pooling: accepted-only circular mean, ≥3 windows, ≤25° max
deviation). `b/c` and `p` are the exact McNemar test on verdict flips against that reference
(`b` = reference accepted and candidate rejected, `c` = the reverse). `hSD`/`vSD` are the
within-block release-height / release-speed SDs over accepted windows.

| variant | clip | n | acc | recall | precision | median &#124;gErr&#124; | median rmsPx | hSD (m) | vSD (m/s) | b/c | p |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| **autoFoundTrace** (ref) | overall | 98 | 52 | 56.8 % | 100 % | 0.019 | 5.54 | 0.385 | 0.952 | — | — |
| | elbow | 43 | 28 | 71.8 % | 100 % | 0.027 | 5.14 | 0.257 | 0.393 | — | — |
| | free throw | 30 | 12 | 39.3 % | 100 % | 0.015 | 5.93 | 0.465 | 0.701 | — | — |
| | three | 25 | 12 | 52.4 % | 100 % | 0.010 | 7.18 | 0.423 | 1.240 | — | — |
| **autoFoundNoPool** | overall | 98 | 54 | **59.1 %** | 100 % | 0.017 | 5.51 | **0.373** | 0.941 | 0/2 | 0.50 |
| | elbow | 43 | 28 | 71.8 % | 100 % | 0.026 | 5.23 | **0.219** | **0.342** | 0/0 | — |
| | free throw | 30 | 12 | 39.3 % | 100 % | 0.015 | 5.93 | 0.465 | 0.701 | 0/0 | — |
| | three | 25 | 14 | **61.9 %** | 100 % | 0.009 | 6.27 | **0.331** | **0.933** | 0/2 | 0.50 |
| autoFoundPooledMedian | overall | 98 | 44 | 48.9 % | 100 % | 0.019 | 5.53 | 0.386 | 0.976 | 8/0 | **0.0078** |
| | elbow | 43 | 28 | 71.8 % | 100 % | 0.028 | 5.12 | 0.258 | 0.393 | 0/0 | — |
| | free throw | 30 | 4 | **14.3 %** | 100 % | 0.014 | 9.68 | 0.156 | 0.202 | 8/0 | **0.0078** |
| | three | 25 | 12 | 52.4 % | 100 % | 0.012 | 6.75 | 0.413 | 1.211 | 0/0 | — |
| autoFoundPooledMedianAccepted | overall | 98 | 40 | 44.3 % | 100 % | 0.020 | 5.35 | 0.367 | 1.013 | 12/0 | **0.0005** |
| | free throw | 30 | 0 | **0.0 %** | — | — | — | — | — | 12/0 | **0.0005** |
| autoFoundPooledGated | overall | 98 | 52 | 56.8 % | 100 % | 0.019 | 5.52 | 0.382 | 0.932 | 0/0 | — |
| | elbow | 43 | 28 | 71.8 % | 100 % | 0.028 | 5.12 | 0.258 | 0.393 | 0/0 | — |
| | free throw | 30 | 12 | 39.3 % | 100 % | 0.015 | 5.93 | 0.465 | 0.701 | 0/0 | — |
| | three | 25 | 12 | 52.4 % | 100 % | 0.012 | 6.75 | 0.413 | 1.211 | 0/0 | — |
| autoFoundPooledIterated | overall | 98 | 44 | 48.9 % | 100 % | 0.022 | 5.41 | 0.374 | 0.981 | 8/0 | **0.0078** |
| | free throw | 30 | 4 | 14.3 % | 100 % | 0.014 | 9.69 | 0.155 | 0.202 | 8/0 | **0.0078** |
| autoFoundPooledClustered (15°) | overall | 98 | 44 | 48.9 % | 100 % | 0.020 | 5.53 | 0.383 | 0.977 | 8/0 | **0.0078** |
| | free throw | 30 | 4 | 14.3 % | 100 % | 0.016 | 9.38 | 0.150 | 0.192 | 8/0 | **0.0078** |
| autoFoundPooledClusteredTight (10°) | overall | 98 | 51 | 55.7 % | 100 % | 0.021 | 5.53 | 0.378 | 0.910 | 2/1 | 1.00 |
| | elbow | 43 | 28 | 71.8 % | 100 % | 0.028 | 5.12 | 0.258 | 0.393 | 0/0 | — |
| | free throw | 30 | 11 | 35.7 % | 100 % | 0.029 | 6.06 | 0.436 | 0.497 | 2/1 | 1.00 |
| | three | 25 | 12 | 52.4 % | 100 % | 0.012 | 6.75 | 0.413 | 1.211 | 0/0 | — |
| *autoFoundAzimuthOffset5* (probe, deliberately wrong) | overall | 98 | 40 | 44.3 % | 100 % | 0.056 | 5.46 | 0.358 | 0.776 | 12/0 | **0.0005** |

`ShotBench compare`'s own verdict lines: `autoFoundNoPool` **NO DIFFERENCE** (McNemar p = 0.50, no
paired-delta metric moved); `autoFoundPooledGated` **REGRESSED** (its only firing regression is the
elbow height SD, 0.257 → 0.258 m) though its rmsPx improves significantly (sign test p = 0.0015) and
its gError worsens significantly (p = 0.033); `autoFoundPooledMedian`, `…Clustered`, `…Iterated`
**REGRESSED**; `autoFoundPooledClusteredTight` **REGRESSED** on two individual windows.

### Paired, on the windows accepted in *both* arms — the number that decides it

Verdict flips can hide a quality change, so this is the like-for-like comparison: same windows, only
the azimuth differs.

| clip | n | hSD per-shot → pooled | vSD per-shot → pooled | median &#124;Δheight&#124; | median &#124;Δazimuth&#124; |
|---|---:|---|---|---:|---:|
| elbow | 28 | 0.219 → **0.257 m** (worse) | 0.342 → 0.393 | 0.011 m | 0.70° |
| free throw | 12 | 0.465 → 0.465 (pooling never engaged either way) | 0.701 → 0.701 | 0.000 m | 0.00° |
| three | 12 | 0.348 → **0.423 m** (worse) | 0.970 → 1.240 | 0.050 m | 1.87° |

**Pooling the azimuth widens the within-block spread on both clips where it engages**, by 0.04 m and
0.08 m. The hypothesis predicted the opposite sign. It also moves each window's azimuth by well
under 2° and its release height by 1–5 cm, which is the same conclusion as §2 stated as a
measurement rather than as a derivative.

### Where the free-throw clip's 0.465 m actually comes from

Splitting the 12 accepted free-throw windows by which azimuth mode they belong to (under
`autoFoundNoPool`, i.e. each window's own solve):

| group | n | median release height | height SD | median release speed | speed SD |
|---|---:|---:|---:|---:|---:|
| mode A (~241°) | 6 | 2.714 m | **0.190 m** | 6.655 m/s | 0.293 |
| mode B (~293°) | 6 | 2.084 m | 0.507 m | 7.444 m/s | 0.973 |
| both, as the scorecard reports it | 12 | — | **0.465 m** | — | 0.701 |

Mode A alone is 0.19 m; the two modes' medians differ by 0.63 m. **Most of that clip's reported
0.465 m spread is the two shooting positions being averaged together, not shot-to-shot measurement
noise** — which means the scorecard's "within-block spread" for `IMG_1765` has been measuring a
block that is not a block. (Mode B's own 0.507 m is dominated by one window, `IMG_1765@0899.7`, whose
release height comes out at 3.19 m; without it mode B is 0.23 m. That window is accepted by every
gate — a separate, real problem, see §6.)

The three-point clip is the counter-example that settles the hypothesis: under
`autoFoundPooledGated` **every accepted three-point window uses the identical azimuth** and the
release-height SD is still 0.413 m. A single fixed azimuth does not tighten that block.

## 5. Why the 38 refused shots are refused — it is not the azimuth

Labelled shots under the reference variant, grouped by outcome, with the quality of their *own*
azimuth solve:

| outcome | n | median solve residual | median ambiguity ratio | median implied ball diameter | median diameter spread along the track |
|---|---:|---:|---:|---:|---:|
| accepted | 50 | 0.015 m | 0.16 | 0.278 m | 0.23 |
| gravity gate (>8 %) | 18 | **0.208 m** | **0.82** | 0.262 m | **0.58** |
| trajectory fit failed | 10 | **0.174 m** | **0.95** | 0.234 m | **0.59** |
| plausibility gate | 6 | 0.021 m | 0.60 | 0.295 m | 0.31 |
| no observed release | 4 | 0.016 m | 0.18 | 0.280 m | 0.31 |

The 28 windows in the two big refusal buckets do not have a *slightly wrong* azimuth — their azimuth
objective has no distinct minimum at all (an ambiguity ratio of 0.82–0.95 means the second-best
minimum is within 5–18 % of the best) and their tracks do not look like a ball in free flight (the
implied ball diameter varies by ~58 % along the track, against 23 % for accepted windows). Forcing a
correct block azimuth on them does not rescue them: under `autoFoundPooledGated` the three-point clip
is pooled at its core azimuth and its recall stays at 52.4 %, rescuing none of them.

**The recall problem on this corpus is a track-quality problem, not an azimuth-estimation problem.**
That is the most useful thing this experiment found, and it points the next piece of work at the
tracker (and at what a window contains), not at the plane solver.

## 6. Findings worth recording, that are not this experiment's to act on

Stated as findings with numbers, deliberately **not** acted on here — no gate was weakened, no
threshold changed, no shipped default moved:

1. **`IMG_1765` is two blocks, not one.** Any statistic that assumes "one clip = one shooting
   position" is wrong for that clip — including the within-block spread the scorecard reports for it
   and the session-pooled azimuth the live `session` command would apply if three of its shots ever
   agreed. The corpus needs a per-window *position* label, or the clip needs splitting, before its
   spread number means anything.
2. **The fixed-gravity azimuth solve weakens "g is the check".** `solveByFixedGravity` picks the
   azimuth whose parabola fits with g held at 9.81, and the final fit then reports g as an
   independent check. On the free-throw clip both modes reach g-errors of 0.2–2 % while disagreeing
   about the plane by 52°, so a small final g-error is not on its own evidence that the plane is
   right. The ball's apparent diameter *is* independent of gravity (§1) and separates good tracks
   from junk cleanly here (0.27–0.29 m implied for every accepted window; 0.03–0.14 m for the junk) —
   a candidate confidence signal, untested as a gate.
3. **One accepted window reports a 3.19 m release height** (`IMG_1765@0899.7`), inside the 1.6–3.3 m
   plausibility band, and a 3.13 m one at `IMG_1765@0540.7`. The band is wide enough to admit
   releases no human makes. This is evidence the band is loose, **not** a licence to change it —
   that is a separate decision with its own evidence, per this task's rules.
4. **Legacy pooling is, if anything, slightly harmful here.** `autoFoundNoPool` accepts 2 more
   windows than `autoFoundTrace` (p = 0.50, not significant) and has a tighter spread on both pooled
   clips. The live `session` command's pass-1/pass-2 pooling is not earning its complexity on this
   corpus. Not significant on 98 windows — worth re-testing on the next session's footage before
   anyone removes it.

## 7. Decision

**Keep: nothing shipped. Reverted as a hypothesis, kept as tooling.** No variant beat
`autoFoundTrace` on recall, and the two that moved the corpus significantly moved it the wrong way.
`autoFoundNoPool` is directionally the best of the set (+2 windows, tighter spread everywhere) but
p = 0.50 on 2 discordant windows — not distinguishable from chance at this corpus size, and turning
off the live pooling on that basis would be exactly the kind of claim this pipeline exists to
prevent.

What is kept is the measurement apparatus, because it is what makes the negative result auditable
and reusable: the `ShotBench azimuth` diagnosis subcommand, `CircularStats` + `AzimuthPooling`
(circular mean/median/MAD/clustering, tested at the wrap point), the pooling strategies as
`Variant.pooling`, and `azimuthUsedDegrees` / `viewAngleDegrees` / `pooling` on the scorecard.

## 8. Gates

- `swift test -Xswiftc -O` in `Packages/ShotGeometry`: **379 tests, 0 failures** in ShotGeometryTests
  (356 before this pass + 23 new in `CircularStatsTests`) and **27 tests, 0 failures** in
  FormEvalKitTests. The new tests cover the circular median at the wrap point specifically (the naive
  answer for {350°, 355°, 5°, 10°} is 177.5°, the antipode of the truth), its even-n midpoint
  convention, its independence from input order, the MAD outlier rule including the floor and both
  gates, and gap clustering including a cluster that straddles 0°.
- `swift run -c release GeometryHarness` → **GATE: PASS**, unchanged (nothing in `ShotGeometry` moved).

## 9. Honest limits

- **One night, one court, one shooter, three clips**, and two of the three clips carry a systematic
  problem of their own (`IMG_1765` mixes two positions; `IMG_1766`'s rim sits at the frame edge).
  "Azimuth pooling does not help" is established *for this footage*.
- **The free-throw two-position finding rests on geometry, not on a label.** Nobody recorded where
  the shooter stood; the label file says "shot". The pixel evidence (300 px apart, 1.4× ball size)
  is strong, but the two modes' release heights cannot both be right, so at least one mode's absolute
  numbers are wrong and this experiment did not determine which.
- **`--no-pose` throughout**, as in `docs/BENCH-RESULTS-2026-09-24.md`: release heights read low and
  speeds high. This biases every arm identically, so the comparisons hold, but no absolute release
  number here should be quoted at a shooter.
- **The sensitivity numbers in §2 are a local derivative** measured at +5°, on the windows that
  survived a 5° error. They should not be extrapolated to tens of degrees.
- **The clustering gap is a tuned constant.** 15° does not separate the free-throw modes (the junk
  windows bridge the valley); 10° does. Both are in the ledger rather than one being quietly chosen,
  but a constant picked by looking at this corpus is not a constant validated on it.
