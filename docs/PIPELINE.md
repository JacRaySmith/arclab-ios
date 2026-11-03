# The measurement pipeline

Until 2026-09-24, a change to shot analysis could only be judged by running `TrajectoryProbe
session` on a clip and reading the printed table by eye — slow (a full clip scan is minutes) and
not statistical (no p-value, no paired comparison, no regression check). This is the loop that
replaces that: **cache the corpus once → replay it in seconds under a named variant → compare two
runs with a paired statistical test.**

Three pieces:
- `TrajectoryProbe session --dump-windows <dir>` (`Packages/ShotVideo/Sources/TrajectoryProbe/Probe.swift`) —
  writes everything `ShotAnalyzer.analyze` needs for every shot window it scans, so later replay
  needs no video. Purely additive: every other `session` behaviour and default is unchanged.
- `ShotBenchKit` / `ShotBench` (`Packages/ShotGeometry/Sources/ShotBenchKit`, `.../ShotBench`) —
  a pure Foundation + simd + ShotGeometry library and CLI (no Vision, no AVFoundation, no network,
  no video) that replays a cache under a named *variant* and compares two replays.
- This file, and `docs/EXPERIMENTS.md`, the ledger of what was tried.

## The corpus (2026-09-13 filming night)

`footage/2026-09-13/` (gitignored — large video, not in the repo; lives on this Mac and wherever
else it was copied):

| clip | spot | sidecar |
|---|---|---|
| `IMG_1764.mov` | elbow, alternating sides | `rim_1764.json` |
| `IMG_1765.mov` | free throws | `rim_1765.json` |
| `IMG_1766.mov` | threes | `rim_1766.json` |

These are **120 fps slow-motion clips with a baked 30 fps timestamp track** (the file's own PTS
run at 30 fps; the content is 4× slower than real time), so every command below needs
`--time-scale 4` to turn file-time into real seconds. `docs/footage-2026-09-13/SHOOTER-REPORT.md`
has the fuller history of this corpus (calibration fixes, per-block numbers).

**This is one night, one court, one shooter.** A result from this corpus is evidence about *this
footage* — whether a change measurably helps or hurts what was filmed here — not yet evidence about
the app in general. Treat every `ShotBench compare` verdict accordingly.

## Building the cache

Dump a clip's windows into a cache directory (add `--spot` so `knownDistance` and the per-spot
tables in the scorecard have something to key on):

```
swift run -c release TrajectoryProbe session footage/2026-09-13/IMG_1765.mov \
  --rim footage/2026-09-13/rim_1765.json --time-scale 4 --spot freeThrow \
  --dump-windows ~/shotbench-cache

swift run -c release TrajectoryProbe session footage/2026-09-13/IMG_1766.mov \
  --rim footage/2026-09-13/rim_1766.json --time-scale 4 --spot three \
  --dump-windows ~/shotbench-cache

swift run -c release TrajectoryProbe session footage/2026-09-13/IMG_1764.mov \
  --rim footage/2026-09-13/rim_1764.json --time-scale 4 --spot elbow \
  --dump-windows ~/shotbench-cache
```

Spot labels are free text, but `SpotDistanceTable`
(`Packages/ShotGeometry/Sources/ShotBenchKit/Variants.swift`) recognises exactly `freeThrow`
(4.191 m), `three` (6.75 m) and `collegeThree` (6.32 m); `elbow` is deliberately absent (see
below). Dumping several clips into the same directory accumulates — `manifest.json` is merged, not
overwritten — so the three commands above build one cache.

A run over a whole clip takes minutes (the scan decodes the entire file once looking for rim
arrivals, then tracks the ball inside each window). To build or check a slice quickly, use the
existing `--start` / `--end` / `--limit` flags, e.g.:

```
swift run -c release TrajectoryProbe session footage/2026-09-13/IMG_1766.mov \
  --rim footage/2026-09-13/rim_1766.json --time-scale 4 --spot three --no-pose --limit 3 \
  --dump-windows /tmp/cache-slice
```

### The cache format

One JSON file per window plus a `manifest.json` index. Everything `ShotAnalyzer.analyze` needs, no
video:

```json
{
  "windowID": "IMG_1766@0023.7",
  "clip": "IMG_1766.mov",
  "spot": "three",
  "samples": [{"t": 7.308333333333334, "u": 281.00165972223675, "v": 514.9012497605513, "diameterPx": 131.72320508790568}, "…"],
  "rimBoundary": [[x, y], "…"],
  "rimDiameterUsed": 0.4572,
  "width": 1920, "height": 1080, "hfovDegrees": 64,
  "timeScale": 4, "measuredFPS": 30.000000000000004,
  "fileStart": 22.299999999999997, "fileEnd": 33.5,
  "releaseTimeOverride": null,
  "dumpedAt": "2026-09-24T14:49:03Z"
}
```

`windowID` is stable across runs and code changes: `"<clip stem>@<file time, 0.1 s, zero-padded>"`,
built from the window's pre-padding *arrival* time so it does not move if the padding constants
around a rim arrival are retuned later. `fileStart`/`fileEnd` are the window's actual decoded span
(post-padding) — used to test "does this window cover time T" (e.g. matching a hand-labelled
release). `samples` are exactly what was fed to `ShotAnalyzer.analyze` live (edge-clipped
detections already excluded, same as the app). `rimDiameterUsed`, the intrinsics, `timeScale` and
`measuredFPS` are recomputed identically on replay: `ShotBenchKit` calls the *same*
`RimCalibrator.calibrate` on the cached boundary points, not a serialized calibration, so the
replayed calibration is byte-for-byte the live one, not an approximation of it.

## Replaying a variant

```
swift run -c release ShotBench run ~/shotbench-cache --variant baseline \
  --json baseline.json --markdown baseline.md
```

Variants ship in `Packages/ShotGeometry/Sources/ShotBenchKit/Variants.swift` as data — adding an
experiment is adding one `Variant` entry, not editing the runner:

- **`baseline`** — `azimuthByFixedGravity = true` per window, with the *session-pooled* azimuth
  applied per clip when ≥3 windows from that clip in this cache accept and agree within 25°
  (`BenchRunner.pooledAzimuthByClip` mirrors `Probe.swift`'s pass 1/pass 2 exactly). This is what
  `session` builds today for its per-shot analysis. One honest limitation: a live `session` run
  pools over every shot in one continuous capture; a cache can hold windows from several separate
  dump runs (e.g. two `--limit` slices), and this tool never assumes windows belong to the same
  capture just because they share a clip name — so pooling only ever sees the windows actually
  present in the cache directory you point it at. On a small or partial cache this can differ from
  what a full-clip live run would have pooled; the scorecard's `notes` say plainly whether pooling
  engaged for each clip.
- **`fixedGravityAzimuth`** — the same azimuth option in isolation, no session pooling, no known
  distance. On a corpus where pooling never engages (too few accepted shots, or they disagree by
  more than 25°) this is numerically identical to `baseline` — expected, not a bug: `baseline`
  already uses fixed-gravity azimuth, so this variant exists to stay a stable, pooling-free
  reference point if `baseline`'s default ever changes.
- **`knownDistance`** — sets `AnalysisOptions.knownReleaseDistance` from the cached `spot` label via
  `SpotDistanceTable` (free throw 4.191 m, three 6.75 m, college three 6.32 m). **Skips, never
  guesses**, a window with no spot label or a spot the table doesn't know — `elbow` most of all: the
  elbow is a lateral position on the floor, not a fixed distance from the rim, so there is no single
  number to put there.
- **`gravityUp`** — sets `RimCalibrationOptions.knownUp` per clip from `MeasuredVertical`, a table of
  each clip's camera roll/pitch measured from its own vertical vanishing point (independent of the
  rim trace). Session-pooled like `baseline`. Skips a clip with no recorded vertical. See
  `docs/BENCH-RESULTS-2026-09-24.md` for what this changes on the 2026-09-13 corpus.
- **`autoFoundTrace`** — recalibrates from the auto-found rim trace (`RimFinder`, 2026-09-14) instead
  of the cached hand trace, via a bundled `ShotBenchKit` resource (`Resources/rim_*_found.json`, so
  this needs no access to the gitignored footage directory at replay time). Session-pooled like
  `baseline`. Skips a clip with no bundled auto-found trace.

- **`ballSizeCue002` / `ballSizeCue02` / `ballSizeCue20`** (2026-09-27) — `autoFoundTrace`'s calibration
  with pooling **off**, plus an absolute ball-size prior in the fixed-gravity azimuth objective
  (`AnalysisOptions.ballSizeCue`; the weight is metres of plane-fit residual per 100 % size error).
  Read against **`autoFoundNoPool`**, not `autoFoundTrace` — a pooled azimuth is substituted via
  `fixedAzimuth` and would bypass the solve the cue lives in. **Measured and reverted**: 0.002 and 0.02
  are byte-identical to the control, 0.20 loses one window and makes rmsPx significantly worse
  (p = 0.0422). Kept only so the negative result stays reproducible; `AnalysisOptions.ballSizeCue`
  defaults to nil.

The **azimuth-pooling experiments** (2026-09-24, `docs/BENCH-RESULTS-azimuth-2026-09-24.md`) all sit
on `autoFoundTrace`'s calibration and differ from it only in `Variant.pooling`, so they are read
against `autoFoundTrace`, not against `baseline`: **`autoFoundNoPool`** (no pooling at all — the
control), **`autoFoundPooledMedian`** / **`autoFoundPooledMedianAccepted`** (robust circular median
over all / accepted windows, MAD outlier rule), **`autoFoundPooledGated`** (pooled only when the
surviving azimuths' robust spread 1.4826·MAD ≤ 10°), **`autoFoundPooledIterated`** (re-solve each
window over the flight window the pooled azimuth implies, then re-pool), **`autoFoundPooledClustered`**
/ **`autoFoundPooledClusteredTight`** (cluster the clip's azimuths by circular gap and pool within
each cluster), and **`autoFoundAzimuthOffset5`** — a deliberately wrong sensitivity probe, never a
candidate, which offsets the pooled azimuth by 5° so the bench can measure d(release height)/d(azimuth).
The estimators are in `ShotBenchKit/CircularStats.swift` (circular mean/median/MAD/clustering, unit
tested at the wrap point); the pooling rules are `AzimuthPoolingStrategy` in `Variants.swift`, and a
scorecard now carries a `pooling` section saying, per clip, whether pooling engaged and the numbers
behind that decision.

## Diagnosing the azimuth, before any pooling decision

```
ShotBench azimuth <cache-dir> --variant autoFoundTrace --json azimuth.json
```

Solves every window's azimuth on its own (`ShotPlaneSolver.solveByFixedGravity` over the whole
track) under that variant's calibration and dumps it per window — including for windows whose later
analysis throws, which a scorecard cannot show. Each row carries the solve's residual, ambiguity
ratio and σ, the window's own accept/refuse verdict, its release height/distance, and two
gravity-independent numbers: the ball diameter the window's own plane implies (`d_px · z / f_x`,
median along the track) and how much that varies along the track. A ball does not change size, so
those two separate "this plane is right" from "this fit happens to reproduce g" — the fixed-gravity
solve chooses the plane that makes g come out at 9.81, so a small g-error is not by itself evidence
that the plane is right. It prints the robust per-clip pool (centre, 1.4826·MAD, max deviation,
outliers dropped) and whether it would engage.

`gravityUp` and `autoFoundTrace` are the first two variants that need more than `AnalysisOptions`: a
`Variant` can also supply a `CalibrationOverride` (a replacement rim boundary, a `knownUp`, or both) —
`BenchRunner.calibration(for:override:)` applies it before `RimCalibrator.calibrate` runs, and
`pooledAzimuthByClip` takes the same override so pass 1 (pooling) and pass 2 (the final per-window
analysis) always see the same calibration. See `CalibrationOverride` in `Variants.swift`.

Every scorecard reports, overall and **per spot**: windows analysed, accepted count and rate, a
histogram of refusal reasons (coarse categories — gravity gate, plausibility gate, residual gate,
azimuth/window/fit failures — the exact per-window reason string is also kept on every window row),
and a quality summary computed over the *accepted* windows only:

- median and p90 of `|gError|`, median `rmsPx`;
- **within-block spread** — the SD of release height and of release speed among accepted windows of
  the same clip *and* spot (one shooter, one station: this should be small). Refused below n = 5,
  with that reason, rather than reported from too few shots to mean anything.
- release-time error in ms, for any window whose analysed span covers a label in
  `~/Desktop/arclab-review/release_labels.json` (three hand-labelled `IMG_1765` free-throw
  releases). If that file is missing or does not match the expected shape, the scorecard says so
  (`labelScoring.status`) and carries on — this is not a hard failure.

**Acceptance rate alone is never the verdict.** A variant that accepts more shots by loosening
physics is a regression; read acceptance beside gError/rmsPx/spread every time.

## Comparing two runs

```
swift run -c release ShotBench compare baseline.json candidate.json --markdown compare.md
```

- **Verdict flips**, tested with an exact McNemar test: `b` = windows the baseline accepted and the
  candidate rejected, `c` = the reverse. The two-sided p is `min(1, 2·P(X ≥ max(b,c)))` for
  `X ~ Binomial(b+c, 0.5)`, computed exactly (`BenchStats.binomialCoefficient` builds `C(n,k)` by the
  multiplicative recurrence, never the huge intermediate factorials). `b + c == 0` prints "no window
  changed verdict" and no p. Otherwise it prints b, c, the net, the p, and the number of discordant
  windows that would need to land on one side, *at the current corpus size*, to reach significance
  at α = 0.05.
- **Paired deltas** on gError, rmsPx, the within-block spreads, and release-time error where
  labelled — median `candidate − baseline`, n, and a sign-test p, over windows where the measure
  exists (finite) in *both* arms. A metric that is `.infinity` in both arms (a fit whose g came out
  non-finite/non-positive — `GravityGate.verdict`) yields a `.nan` delta and is correctly dropped
  from n rather than miscounted as "unchanged".
- **A regression section that fires regardless of acceptance**: any window accepted in both runs
  whose `|gError|` worsened by more than 0.02 (absolute) or whose `rmsPx` worsened by more than 2 px,
  and any within-block spread that widened at all. Stated in the output every time: *a candidate
  that raises acceptance while worsening gravity error, fit residual, or within-block spread is a
  regression, not an improvement.*
- Windows present in one scorecard and not the other are always listed (never silently dropped),
  with a reason — skipped by that variant, or genuinely absent from that run's cache.
- Exit code is always 0 (`compare` is a measurement, not a gate); the one-line verdict is IMPROVED /
  NO DIFFERENCE / REGRESSED / MIXED, printed with its reason. **A p above 0.05 means the change is
  not distinguishable from chance on this corpus** — that is a real, useful result, not a failure to
  find one.

## Adding a variant

Add one `Variant` to `Variants.swift`: a `name`, a `summary` (shown in every scorecard), and
`makeOptions: (CachedWindow, VariantContext) -> VariantResult`, returning `.options(AnalysisOptions)`
or `.skip("reason")`. If the experiment needs a different `RimCalibration` (a `knownUp`, or a
different rim boundary entirely) rather than just different `AnalysisOptions`, also supply
`calibrationOverride: (CachedWindow) -> CalibrationOverride` — see `gravityUp`/`autoFoundTrace` for
examples. Append the variant to `Variant.all`. That is the whole integration — `ShotBench run` and
the aggregation/statistics do not change.

## The round-trip check (why this pipeline can be trusted)

Verified 2026-09-24 on a 3-window slice of `IMG_1766.mov` (`--spot three --no-pose --limit 3`): the
live `session --dump-windows` table and a `ShotBench run --variant baseline` replay of the resulting
cache agree **exactly**, window by window — same accept/reject verdict, same thrown-error text for
the window that failed to fit, same `gError` (including the deliberate `.infinity` on two windows),
same `rmsPx`, release height/speed/angle, entry angle, depth, and sample count. Session-pooling did
not engage on this slice (0 of 3 windows accepted in pass 1, same live and replayed), so this first
check exercised only the per-shot fixed-gravity path.

**Extended 2026-09-24 to the full corpus (all three clips, 98 windows, no slicing).** The live
`accepted N of M` line for each clip and a `ShotBench run --variant baseline` replay of the resulting
cache agree exactly on every clip: `IMG_1764` 26/43, `IMG_1765` 12/30, `IMG_1766` 1/25. This closes
the gap the note above used to flag: `IMG_1764` is a real multi-shot capture where the live
`session` command's pass-1 pooling *does* engage (23 accepted shots → view angle 3.3° from side, max
deviation 3.0°), and the replay's `pooledAzimuthByClip` reproduces that decision exactly (the
scorecard's `notes` read "session-pooled azimuth applied for: IMG_1764.mov", nothing else) — so the
pooled path, not just the per-shot path, is now verified against a live run, not only against unit
tests of the pooling logic in isolation. See `docs/BENCH-RESULTS-2026-09-24.md` §1 for the full table.

## Results

`docs/BENCH-RESULTS-2026-09-24.md` has the first real comparisons run through this pipeline:
`gravityUp` and `autoFoundTrace` (both from `docs/research/three-point-acceptance-2026-09-24.md`)
against `baseline`, `fixedGravityAzimuth`, and `knownDistance`, over the full 2026-09-13 corpus, per
clip and overall. `docs/EXPERIMENTS.md` has the one-line-per-variant ledger.
`docs/BENCH-RESULTS-azimuth-2026-09-24.md` has the azimuth-pooling experiment: the per-clip azimuth
diagnosis (one clip of that corpus turns out to hold two shooting positions, not one), the six
pooling variants, and the measurement that rules the "azimuth noise causes the 0.4 m release-height
spread" hypothesis out.

## Gates that can silently pass (2026-09-24)

A measurement loop is only as good as its gates, and one of ours was not measuring anything.

The shared `build-app.sh` used by agents did **not** run `xcodegen generate` before building.
`App/ArcLab.xcodeproj` is git-ignored and generated from `App/project.yml`, so any source file
added since the last generate was never compiled: the build could print `** BUILD SUCCEEDED **`
while the new code did not exist in the target at all. It also built `Debug`, which is not what
ships and has been measured on device at roughly a hundred times slower per analysis window.

Fixed: the script regenerates the project first and treats a `xcodegen` failure as fatal, refusing
to build a stale project rather than reporting a pass. It builds `Release` by default.

Signing is now separate from the gate. As of 2026-09-24 Xcode reports "No Accounts", so a signed
build fails and nothing can be installed on the phone until an Apple ID is signed in again. The
correctness gate therefore builds unsigned (`CODE_SIGNING_ALLOWED=NO`); pass `--sign` when the
build is meant for the device.

**The lesson for this pipeline:** a gate that cannot fail is worse than no gate, because it is
believed. When a result depends on a gate, check that the gate would have caught its own absence.

## The acceptance rule the bench scores with (2026-09-27)

`ShotBench run` takes `--acceptance shipping|legacy`, and **defaults to `shipping`** — the rule the
phone applies (`ShotGeometry/ShotAcceptance.swift`). It did not used to. Until 2026-09-27 the rule
existed in three retyped copies (the app, `Probe.swift`, `ShotBenchKit/Acceptance.swift`) and the
bench's had drifted from the app's in two ways: no `minimumReleaseDistance`, and a window whose
`release` or `depthPastFrontRim` was nil was refused outright rather than having that check skipped.

On this corpus the difference is **5 windows** — 39 accepted under the old rule, 44 under the app's,
all five free throws, precision 100 % either way. So:

- **Every acceptance and recall number in rows dated 2026-09-24 was produced by the legacy rule.**
  They are reproducible with `--acceptance legacy`, and every *paired* comparison between two
  variants is unaffected, because both arms always used the same rule.
- Every scorecard now records its rule in `Scorecard.acceptance`, and `compare` refuses two cards
  scored by different rules rather than reporting the rule change as a variant effect.

A caveat the change surfaces rather than creates: 4 of those 5 windows have **no observed release**,
so they carry no release height, speed or angle. They are accepted because the app does not refuse a
window for a metric it honestly could not compute — but it means "17 of 30 counted" is not the same
claim as "17 of 30 produced the numbers the block is scored on". Worth a decision.

## The corpus is not 4× slow everywhere (2026-09-29)

Every clip of the 2026-09-13 corpus was described above as "4× slower than real time" throughout. It is not.
An iPhone slo-mo clip exported from Photos is a constant 30 fps file whose **content** runs at 1/4 speed
inside the slow section and at full speed outside it — the exporter keeps every captured frame in the slow
section and every 4th elsewhere — and these three files have normal-speed stretches at **both ends**:

| clip | normal-speed windows (arrival file time) | ball image speed there | in the slow section |
|---|---|---|---|
| `IMG_1765` | 5.4, 17.7, 32.0, 44.3 s and 1109.2, 1122.2 s | 30–48 px/frame | 8–14 px/frame |
| `IMG_1766` | 23.7 s and 1506.1, 1519.4, 1534.9, 1547.9 s | 48–52 px/frame | 8–13 px/frame |
| `IMG_1764` | 13.9, 26.8, 44.4, 58.0 s and 1279.8, 1297.3, 1313.0 s | 35–42 px/frame | 9–11 px/frame |

Read as 4× slow, a shot there crosses the court in 0.25 s and fits **g = 90–140 m/s²** (a 4× time-scale
error, squared, less what the plane solve absorbs). That is where most of the "19 gravity-gate refusals with
g_fit/9.81 from −2 to +16" of the 2026-09-27 rows came from — a property of the export, not of the tracker
or the fit. `TrajectoryProbe speed <clip>` measures the mean frame-to-frame luma difference along a file;
on this footage it shows the ends elevated but the ball's own per-frame displacement is the clean tell.

`session --gravity-time-scale` handles it per window without a hand-drawn boundary: a window whose fit is
**refused** at the declared scale is read again as ×1 content — the declared-scale track with its timestamps
re-read, and a fresh track under ×1 gates (the tracker's gates were tuned at 120 fps and shrink to 1–3 frames
at 30 fps, so the re-timed track is usually the better reading) — and the ×1 reading is kept only when
gravity then comes out within 15 % *and* the fit residual is smaller than the declared one's. Two discrete
hypotheses (the export's two speeds), gravity choosing between them, and the 8 % gate still applied
afterwards. The dump records the chosen `timeScale` per window and a note saying what both fits gave. The app's own recordings
carry a true frame rate and are not affected; an imported slo-mo clip is (`AnalysisModel.sloMoStretch`
reads one stretch per file), so the same check belongs in the import path.

## Tracker variants on one decode (2026-09-29)

`session --track-variants a,b,c --dump-windows <dir>` tracks every named parameter set
(`TrajectoryProbe/TrackingVariants.swift`) on the **same decoded window** — planes, Core ML boxes and the
background are paid for once, and `WindowFrames` memoises the per-frame candidate passes by finder
thresholds and diameter — and dumps each to `<dir>/<variant>/` (plus `<variant>-gts` with the gravity
time-scale check). Each cache also carries `<windowID>.diag.json`: every detection the tracker returned
with its stage and placement (`forward.refined`, `back.weak`, `extend.blob`, …), the scanner seeds, and the
tracker's own counters, so a track can be drawn with its sources told apart. `ShotBench` ignores the diag
files (the manifest does not list them). Score each cache with `ShotBench run <dir>/<variant> --variant
autoFoundNoPool` and compare any two as usual.

## The intrinsics this cache was built with (2026-09-27)

The cache carries `"hfovDegrees": 64`, the probe's default. `docs/PHASE2-PREP.md` measured this
footage from vanishing points at **66.5° ± 2°** (66.3 / 67.8 / 65.4 per clip) and showed 48° to be
absurd, but nothing re-ran the corpus at the measured value.

It was re-run on 2026-09-27, with `hfovDegrees` rewritten per clip: under `autoFoundTrace`,
**not one window of the 98 changes verdict** (b = 0, c = 0; 57 accepted either way; per-spot
28/17/12 identical; recall 62.5 %, precision 100 %). Paired, the measured value is very slightly
*better* — gError median Δ −0.0023 (p = 0.0275), rmsPx median Δ −0.014 px (p = 0.0001).

The reason is the rim: the calibration reads the scene's scale from the rim's own angular size, so a
uniform focal-length error largely cancels, and `g` — fitted, never assumed — absorbs what is left.
**No result in this file or in `EXPERIMENTS.md` needs re-running.** Prefer the measured value when
the cache is next rebuilt.

## What the corpus could not tell us, and now can

This section used to say that acceptance rate had no denominator — that a refused window might be a
real shot the geometry got wrong or a rebound, and the two are opposite outcomes, so acceptance
could only ever be compared between variants.

**That was answered on 2026-09-24**, the same day it was written, by hand-labelling all 98 windows
(`docs/footage-2026-09-13/window_labels.json`; 88 `shot`, 6 `notShot`, 4 `unsure`). Precision is
**100 %** for every variant tried — not one accepted window was a non-shot — so the failure mode is
entirely recall, and the scorecard now reports precision and recall directly
(`PrecisionRecall.swift`). Read `docs/BENCH-RESULTS-2026-09-24.md` §8.

The section's supporting worry — that the free-throw clip's 0.43 m release-height spread meant the
accepted set was contaminated — was answered at the same time and **refuted**: restricting to the
labelled shots *widens* the SD (0.430 → 0.447 m). It is a measurement-quality problem, not a
contamination problem. `IMG_1765` also turns out to hold two shooting positions, not one
(`docs/BENCH-RESULTS-azimuth-2026-09-24.md`), which is a second reason any per-clip grouping is
suspect.

**What is still open, and is now the sharpest question in the project:** of the 31 labelled-real
shots that `autoFoundNoPool` still refuses, the refusal is the **gravity gate 19 times, a failed
trajectory fit 7 times, the plausibility gate 5 times — and the azimuth solve zero times.** The
19 gravity failures are not a scale or frame-rate error: `g_fit / 9.81` runs from −2.04 to +16.04,
four of them negative. A fit whose g lands there is not being fed one free flight, which makes
`FlightWindowFinder` / `ReleaseDetection` — the only core geometry with no test file — the lead,
rather than the detector's ball diameter (`BIG-CHANGES.md` B11).
