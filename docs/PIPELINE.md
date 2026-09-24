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

## What the corpus cannot yet tell us: the missing denominator

Acceptance rate is *accepted windows ÷ windows found*, and nothing in the corpus says how many of
those windows are real shots by this shooter. A refused window may be a good shot the geometry got
wrong, or a rebound, a warm-up, another player, or nothing at all — and those are opposite
outcomes. Until the corpus is labelled with the real shots, acceptance rate can only be compared
between variants on the same windows (which is what the paired McNemar test does, and why it is the
right test), never read as an absolute score of how well the app works.

A supporting signal that something is off: on the free-throw clip the accepted windows' release
height has a standard deviation of 0.43 m. One shooter at one spot does not vary their release
height by 43 cm, so either the accepted set contains windows that are not this shooter's free
throws, or the measurement is much noisier than the acceptance gate implies. Both are worth
knowing and they are distinguishable only with labels.
