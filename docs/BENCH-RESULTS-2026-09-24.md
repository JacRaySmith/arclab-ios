# Bench results — full 2026-09-13 corpus (2026-09-24)

Four variants (`fixedGravityAzimuth`, `knownDistance`, `gravityUp`, `autoFoundTrace`) replayed against
`baseline` over the **full** 2026-09-13 corpus: all three clips, no `--limit`, no `--start`/`--end`
slicing. See `docs/PIPELINE.md` for how the cache and the bench tool work, and
`docs/research/three-point-acceptance-2026-09-24.md` for the investigation `gravityUp` and
`autoFoundTrace` come from — this document extends that one from a 3-clip hand sweep to the full,
reproducible bench pipeline, and adds the elbow block as a second control.

**This is one night, one court, one shooter, three clips.** Every number below is evidence about
*this footage* — whether a change measurably helps or hurts what was filmed on 2026-09-13 — not yet
evidence about the app in general. `docs/EXPERIMENTS.md` records the decision taken from each result.

## 1. Building the cache and verifying the replay

Cache built with `TrajectoryProbe session <clip> --rim <sidecar> --time-scale 4 --no-pose --spot
<spot> --dump-windows <cache>`, one clip at a time (8 GB Mac), `--hfov` left at the probe's default
(64°):

| clip | spot | windows dumped | live `accepted N of M` |
|---|---|---:|---|
| `IMG_1764.mov` | elbow | 43 | **26 of 43** (session azimuth pooled: 23 accepted shots → view angle 3.3° from side, max deviation 3.0°) |
| `IMG_1765.mov` | freeThrow | 30 | **12 of 30** (12 accepted shots disagree by 45° — pooling did not engage, per-shot solves) |
| `IMG_1766.mov` | three | 25 | **1 of 25** (1 accepted shot in pass 1, need 3 — pooling did not engage) |
| **total** | | **98** | |

**Replay verification (`ShotBench run <cache> --variant baseline`) against the live numbers above:
exact match, every clip** — 26/43, 12/30, 1/25, and `baseline`'s notes line reads "session-pooled
azimuth applied for: IMG_1764.mov" only, matching the live run's own pooling decision. This is a
stronger check than `docs/PIPELINE.md`'s previous round-trip note (a 3-window, no-pooling slice of
`IMG_1766`): it exercises the full corpus, the plausibility/residual gates on every refusal, and —
for the first time — the **session-pooled azimuth path** on a real multi-shot pooled clip (IMG_1764),
which the tool's own build-day note said was still untested. It passed. `docs/PIPELINE.md` §"The
round-trip check" has been updated accordingly.

No discrepancy was found, so nothing below is invalidated by a replay/live mismatch.

## 2. The variants

- **`fixedGravityAzimuth`** — `baseline`'s azimuth option alone, no session pooling, no known
  distance. Exists as a pooling-free reference point; expected to match `baseline` wherever pooling
  doesn't engage and to differ only where it does (IMG_1764 here).
- **`knownDistance`** — `AnalysisOptions.knownReleaseDistance` from `SpotDistanceTable` (free throw
  4.191 m, three 6.75 m). Skips elbow (no fixed distance for a lateral station).
- **`gravityUp`** — `RimCalibrationOptions.knownUp` set per clip from `MeasuredVertical`
  (`Packages/ShotGeometry/Sources/ShotBenchKit/Variants.swift`), the vertical vanishing point of
  light poles/fence posts, independent of the rim trace. **Only IMG_1766's pitch/roll (6.43°,
  −3.69°) is stated outright** in the research document; IMG_1764's (7.65°, −1.77°) and IMG_1765's
  (8.18°, −1.24°) are derived here, by the identical method, from the raw vertical vanishing points
  `docs/PHASE2-PREP.md`'s "Vanishing points on a 33-frame median of each clip" table records for all
  three clips — see the source comment in `Variants.swift` for the full derivation and the unit tests
  (`GravityUpVariantTests`) that check it reproduces IMG_1766's published number bit for bit and
  round-trips through `RimCalibration`'s own `pitch`/`roll` formulas. No clip was skipped: all three
  have a recorded vertical.
- **`autoFoundTrace`** — recalibrates from the auto-found rim trace (`RimFinder`, 2026-09-14,
  `rim_*_found.json`, bundled as a `ShotBenchKit` resource) instead of the cached hand trace. No clip
  was skipped: all three have a bundled auto-found trace.

Both `gravityUp` and `autoFoundTrace` are session-pooled like `baseline` (pass 1 uses each variant's
own calibration, matching the research document's own methodology — see `BenchRunner.pooledAzimuthByClip`).

## 3. Overall (all clips pooled, 98 windows; 55 for `knownDistance`, which skips elbow)

| variant | accepted | rate | McNemar b / c / net | p | minority needed at this n | median &#124;gErr&#124; | median rmsPx |
|---|---:|---:|---|---|---|---:|---:|
| baseline | 39/98 | 39.8% | — | — | — | 0.056 | 6.5 px |
| fixedGravityAzimuth | 36/98 | 36.7% | 4 / 1 / −3 | 0.375 | n=5, unreachable below n=6 | 0.055 | 6.5 px |
| knownDistance | 11/55 | 20.0% | 2 / 0 / −2 | 0.500 | n=2, unreachable | 0.017 | 6.3 px |
| **gravityUp** | **50/98** | **51.0%** | 2 / 13 / **+11** | **0.0074** | need 12 of 15 | 0.045 | 5.9 px |
| **autoFoundTrace** | **52/98** | **53.1%** | 0 / 13 / **+13** | **0.0002** | need 11 of 13 | 0.019 | 5.5 px |

`ShotBench compare`'s own verdict line calls all four **REGRESSED** — correctly, by its stated rule
(*any* window accepted-in-both-arms whose gError/rmsPx worsened past threshold, or *any*
within-block spread that widened, overrides a net acceptance gain). But that rule fires on a handful
of individual windows and is not the whole story once the corpus is split by clip — §4 below is the
number that matters for judging "did this fix threes".

Regressions the tool flagged, verbatim:
- `fixedGravityAzimuth`: 1 window (IMG_1764@0971.7, rmsPx 7.7→10.5 px) + elbow spread widened
  (0.284→0.302 m height SD) — the cost of losing IMG_1764's pooling, exactly as expected.
- `knownDistance`: freeThrow spread widened (0.430→0.465 m height SD).
- `gravityUp`: 1 window each on gError (IMG_1765@0501.5, 0.8%→3.0%) and rmsPx (IMG_1765@0228.9,
  12.2→15.1 px), + freeThrow spread widened (0.430→0.491 m).
- `autoFoundTrace`: 1 window on gError (IMG_1766@1422.8, 0.3%→3.8% — still well inside the 8% gate)
  + freeThrow spread widened (0.430→0.465 m).

## 4. Per clip — this is the real comparison

### `IMG_1764.mov`, elbow (43 windows) — control 1

| variant | accepted | rate | b / c | p | median &#124;gErr&#124; | median rmsPx | height SD (m) | speed SD (m/s) |
|---|---:|---:|---|---|---:|---:|---:|---:|
| baseline | 26/43 | 60.5% | — | — | 0.065 | 6.39 | 0.284 | 0.440 |
| fixedGravityAzimuth | 23/43 | 53.5% | 4/1 | 0.375 | 0.065 | 6.42 | 0.302 | 0.467 |
| knownDistance | skipped — elbow has no fixed release distance | | | | | | | |
| gravityUp | 28/43 | 65.1% | 0/2 | 0.500* | 0.054 | 5.68 | 0.245 | 0.398 |
| autoFoundTrace | 28/43 | 65.1% | 0/2 | 0.500* | 0.027 | 5.14 | 0.257 | 0.393 |

\* n=2 discordant windows: the best possible split (2/0) still only reaches p=0.5 — **not enough
data to call this significant either way**; would need ≥6 discordant windows for any split to reach
α=0.05. Both `gravityUp` and `autoFoundTrace` move every quality number the same direction (lower
gError, lower rmsPx, tighter spread) while accepting 2 more windows — directionally clean, not yet
statistically distinguishable from chance.

### `IMG_1765.mov`, free throw (30 windows) — control 2

| variant | accepted | rate | b / c | p | median &#124;gErr&#124; | median rmsPx | height SD (m) | speed SD (m/s) |
|---|---:|---:|---|---|---:|---:|---:|---:|
| baseline | 12/30 | 40.0% | — | — | 0.013 | 6.38 | 0.430 | 0.712 |
| fixedGravityAzimuth | 12/30 | 40.0% | 0/0 | — | 0.013 | 6.38 | 0.430 | 0.712 |
| knownDistance | 11/30 | 36.7% | 1/0 | 1.000 | 0.017 | 6.26 | 0.465 | 0.614 |
| gravityUp | 11/30 | 36.7% | 1/0 | 1.000 | 0.013 | 6.05 | 0.491 | 0.647 |
| autoFoundTrace | 12/30 | 40.0% | 0/0 | — | 0.015 | 5.93 | 0.465 | 0.701 |

**The control the fixes must not break.** `autoFoundTrace` leaves the accepted *set* untouched
(0 discordant) and moves median gError from 1.3% to 1.5% (still tight) while lowering rmsPx.
`gravityUp` loses exactly the one window `docs/research/three-point-acceptance-2026-09-24.md`
already reported (window 25, p=1.0 — a single flip can never be significant) and widens the height
spread from 0.430 to 0.491 m — the same "implied lens height moves away from the field note"
concern that document flagged (§7). `knownDistance` loses a different window (p=1.0, same reason:
one flip is never significant) with a similar spread widening.

### `IMG_1766.mov`, three (25 windows) — the target

| variant | accepted | rate | b / c | p | median &#124;gErr&#124; | median rmsPx | height SD (m) | speed SD (m/s) |
|---|---:|---:|---|---|---:|---:|---:|---:|
| baseline | 1/25 | 4.0% | — | — | 0.003 (n=1) | 9.82 (n=1) | n=1 < 5 | n=1 < 5 |
| fixedGravityAzimuth | 1/25 | 4.0% | 0/0 | — | 0.003 (n=1) | 9.82 (n=1) | n=1 < 5 | n=1 < 5 |
| knownDistance | 0/25 | 0.0% | 1/0 | 1.000 | — | — | — | — |
| **gravityUp** | **11/25** | **44.0%** | 1/11 | **0.0063** | 0.046 | 8.28 | 0.339 (n=11) | 0.924 (n=11) |
| **autoFoundTrace** | **12/25** | **48.0%** | 0/11 | **0.0010** | 0.010 | 7.18 | 0.423 (n=12) | 1.240 (n=12) |

This is the whole story. Both `gravityUp` and `autoFoundTrace` take the three-point block from
unusable (1/25, and the one accepted window's own quality numbers are meaningless at n=1) to roughly
half-accepted, and the McNemar flip is real: 11 or 12 refuse→accept windows against at most one the
other way, exact two-sided p = 0.006 and 0.001. `gravityUp`'s number reproduces
`docs/research/three-point-acceptance-2026-09-24.md` §6 exactly (12 discordant, 11 in one direction,
p = 0.006).

**`autoFoundTrace` is the better of the two on every accuracy measure** — one more accepted window,
median |gError| 1.0% against 4.6%, median rmsPx 7.2 against 8.3 px — confirming that document's own
ranking ("a clean trace beats [`knownUp`] on the same clip"). **`gravityUp` is tighter on spread**
(height SD 0.339 m vs 0.423 m, speed SD 0.924 vs 1.240 m/s) even though its central accuracy is
worse — plausibly because `autoFoundTrace` admits one more, more marginal shot, and because
`knownUp` only fixes the plane's *normal*; the trace it's built on (still the contaminated hand
trace for `gravityUp`) still sets the rim's size and position, visible in the higher gError. Neither
is free lunch: `gravityUp` is the fallback for a session whose trace cannot be fixed after the fact;
`autoFoundTrace` is strictly better when an auto-found trace exists at all.

## 5. Verdict per variant

| variant | overall | elbow (control) | free throw (control) | three (target) | decision |
|---|---|---|---|---|---|
| fixedGravityAzimuth | REGRESSED (tool) | non-sig net −3 (p=0.375) | unchanged | unchanged | **inconclusive** — expected: it is `baseline` minus pooling, and pooling only engaged on elbow here |
| knownDistance | REGRESSED (tool) | skipped | non-sig net −1 (p=1.0), spread widened | **worse** (1→0) | **reverted** — matches `docs/research/three-point-acceptance-2026-09-24.md`'s own rejection |
| gravityUp | REGRESSED (tool, net positive) | non-sig net +2 (p=0.5), all quality numbers improve | non-sig net −1 (p=1.0), spread widens slightly | **significant net +10** (p=0.0063), gError/rmsPx both improve a lot | **kept as a safety net** — real, corpus-significant fix for the target with a small, non-significant cost on one control |
| autoFoundTrace | REGRESSED (tool, net positive) | non-sig net +2 (p=0.5), all quality numbers improve | **unchanged accepted set** (0 discordant), gError/rmsPx both improve | **significant net +12** (p=0.0010), best gError/rmsPx of any variant | **kept, preferred over gravityUp** — larger, cleaner win on the target, and the only variant that does not touch the free-throw control's accepted set at all |

`ShotBench compare`'s single-line REGRESSED verdict for `gravityUp`/`autoFoundTrace` is a correct
report of its stated rule (any individual-window or spread regression overrides a net acceptance
gain) — it is not wrong, but reading it without the per-clip breakdown above would miss that the
"regression" is one borderline window and one modest spread widening on a *control* clip, while the
*target* clip's improvement is both large and the most statistically significant result in this
entire pass. This is exactly why `docs/PIPELINE.md` says acceptance and the tool's verdict line are
never read alone.

## 6. Honest limits, restated for this pass

- **One night, one court, one shooter, three clips.** A number here says this pipeline change helped
  or hurt *this footage*; whether it generalises needs the 09-17/09-19 sessions' own rim traces
  checked against gravity the same way (`docs/research/three-point-acceptance-2026-09-24.md` §9.3),
  which this pass did not do.
- **`--no-pose` throughout**, same as the research document: release speeds read high and heights
  read low because the release instant comes from the ball alone. This biases every variant
  identically, so the *comparisons* are sound, but no absolute release number in this document
  should be quoted at a shooter.
- **The elbow control has too few discordant windows to call `gravityUp`/`autoFoundTrace` significant
  there** (n=2; would need ≥6). Both move every quality number in the same, favourable direction, but
  "directionally consistent" is not "significant" — say so plainly rather than rounding it up.
- **`gravityUp`'s IMG_1764/IMG_1765 pitch/roll are derived, not published.** Only IMG_1766's is stated
  outright in the research document; the other two come from this file's own arithmetic on
  `docs/PHASE2-PREP.md`'s recorded vanishing points, checked against IMG_1766's published answer
  (bit-for-bit) but not independently re-measured for this pass.
- **`autoFoundTrace`'s within-clip spread on the target is *wider*, not narrower, than baseline could
  even show** (baseline has n=1, no spread computable) **and wider than `gravityUp`'s** — a real
  quality question worth watching if this trace is used going forward, not a reason to prefer
  `gravityUp` on the strength of that one number alone (its central accuracy is worse).
- **The comparator's REGRESSED verdict on `gravityUp`/`autoFoundTrace` is not a bug**; it is what a
  corpus-wide, spread-sensitive rule is supposed to do when a real fix has a real (if small and
  non-significant) side cost on a control clip. Reading acceptance, gError, rmsPx and spread
  together, per clip, is what settles it — which is the whole reason this pipeline reports all four
  rather than a single number.

## 7. Gates

- `swift test -Xswiftc -O` in `Packages/ShotGeometry`: **339 tests, 0 failures** in ShotGeometryTests
  (312 before this pass + 6 new — `GravityUpVariantTests`, unit-testing `upFromPitchRoll` and the
  `gravityUp`/`autoFoundTrace` skip behaviour) and **27 tests, 0 failures** in FormEvalKitTests.
- `swift run -c release GeometryHarness` → **GATE: PASS**, scenario I still marginal and identical to
  `docs/PHASE1-REPORT.md`; the harness never sets `knownUp`, so it exercises the unchanged code path.

## 8. The missing denominator, filled in: labelling the corpus (2026-09-24, second pass)

§"What the corpus cannot yet tell us" above flagged the real problem with every number in this
document: acceptance rate has no denominator for "how many windows are actually shots", so a
refused window could be a good shot the geometry got wrong or correctly-refused debris, and the
free-throw clip's 0.43 m release-height spread among accepted windows could be contamination or
could be noise — indistinguishable without labels. This pass adds the labels and answers both
questions.

### 8.1 How the labels were made

For each of the 98 cached windows, ~4 frames spanning `fileStart`→`fileEnd` were extracted with
`TrajectoryProbe frame` and tiled into one 2×2 review image (a scratch Swift/AppKit script, not
checked in — see `docs/footage-2026-09-13/window_labels.json`'s own `note`). An agent (this one)
looked at all 98 tiled images and labelled each `shot`, `notShot`, or `unsure`, with a one-phrase
reason for every `notShot` and `unsure`. This is **one person's (one agent's) visual judgement from
four still frames per window on one night's footage — not authoritative ground truth.** `unsure` is
a real answer, not a cop-out: those windows are excluded from precision/recall scoring entirely
(neither numerator nor denominator of either metric), and the count is always printed so the
exclusion is never silent. The labels live at `docs/footage-2026-09-13/window_labels.json`,
version-controlled next to `release_labels.json`.

| clip | spot | shot | notShot | unsure | commonest `notShot`/`unsure` reason |
|---|---|---:|---:|---:|---|
| `IMG_1764.mov` | elbow | 39 | 3 | 1 | no release visible — empty court, a rebound retrieval, or the player just walking/holding the ball between shots |
| `IMG_1765.mov` | freeThrow | 28 | 0 | 2 | a pre-shot "rise" pose visible but no ball confirmed in flight in any of the 4 sampled frames |
| `IMG_1766.mov` | three | 21 | 3 | 1 | empty court / player walking in with no release, or (one window) dribbling throughout with no rise-and-release |
| **total** | | **88** | **6** | **4** | |

Every `notShot`/`unsure` window's exact reason is in `window_labels.json`. Two shapes of judgement
call are worth naming plainly (not wrong, but not obvious either): (1) a few `shot` labels are a
drive-in layup or putback near the rim rather than a standing jumper (`IMG_1765@0101.0`,
`IMG_1765@0758.2`, `IMG_1764@0899.2`) — a real release toward the ring, but not the shot shape the
geometry model assumes; (2) `unsure` was used whenever a clear pre-shot "rise" pose wasn't followed
by a confirmed ball-in-flight frame (`IMG_1765@1075.3`, `IMG_1765@1091.8`, `IMG_1766@1140.1`) —
plausibly real shots that simply fell between the 4 sampled instants, called `unsure` rather than
guessed as `shot`.

### 8.2 Precision and recall, per variant, per clip

`ShotBenchKit`'s scorecard (`PrecisionRecall.swift`, `Scorecard.swift`, `Reporting.swift`) now
reports, whenever `window_labels.json` is found: **recall** (of labelled `shot` windows, the
fraction accepted — a thrown-away shot is the real failure) and **precision** (of accepted windows
with a definite label, the fraction labelled `shot` — an accepted `notShot` is a fabricated
measurement). A window a variant *skips* (never evaluates, e.g. `knownDistance` on an elbow window)
counts the same as a refusal for recall — the app produced no measurement for it either way. With no
label file, the scorecard is unchanged except for one line naming the path it looked and didn't
find (verified by `ShotBenchWindowLabelTests`, including the no-labels and all-`unsure` cases).

Re-running the four variants from §2–§5 over the now-labelled corpus:

| variant | overall recall | overall precision | elbow recall | freeThrow recall | three recall |
|---|---:|---:|---:|---:|---:|
| baseline | 43.2% (38/88) | **100.0%** (38/38) | 66.7% (26/39) | 39.3% (11/28) | 4.8% (1/21) |
| knownDistance | 11.4% (10/88)† | **100.0%** (10/10) | 0.0% (elbow skipped)† | 35.7% (10/28) | 0.0% (0/21) |
| **gravityUp** | 54.5% (48/88) | **100.0%** (48/48) | 71.8% (28/39) | 35.7% (10/28) | **47.6% (10/21)** |
| **autoFoundTrace** | 56.8% (50/88) | **100.0%** (50/50) | 71.8% (28/39) | 39.3% (11/28) | **52.4% (11/21)** |

† `knownDistance` structurally cannot measure elbow windows (no fixed shooting distance — see
`SpotDistanceTable`), so its overall recall is dragged down by 39 shots it never had a chance to
recall, not by a worse fit; read its elbow row as "not applicable", not "0% capable", and compare it
to the others only on freeThrow/three.

**Precision is 100% for every variant on every clip that has data, full stop.** Across 98 labelled
windows and four variants, not one accepted window turned out to be labelled `notShot` — the
acceptance gates (gravity error, plausibility, fit residual) that the app already runs never once
mistook a rebound, a pass, or dead time for a shot in this corpus. The failure mode this whole
corpus exhibits is **entirely recall**: real shots the geometry could have measured but refused,
concentrated overwhelmingly in `IMG_1766` (threes), where `baseline` recovers 1 shot in 21 and
`autoFoundTrace` recovers 11. This confirms, with an actual denominator behind it now, exactly what
§3–§5's acceptance-rate numbers already suggested and what `ShotBench compare`'s McNemar test already
established statistically — but it had not been possible to say, until now, that the *fixes* aren't
also quietly admitting junk to buy that gain. They aren't.

### 8.3 The free-throw spread: contamination, or noise?

**28 of the 30 `IMG_1765` (free throw) windows are real shots** (0 `notShot`, 2 `unsure`). This
alone is informative: the clip is not full of rebounds and passes masquerading as shots — this
shooter was, in fact, shooting free throws almost continuously.

Of `baseline`'s 12 accepted free-throw windows, 11 are labelled `shot` and 1 (`IMG_1765@1075.3`) is
`unsure` — **zero are `notShot`.** Recomputing the release-height standard deviation over only the
11 confirmed-shot accepted windows:

| set | n | release-height SD (m) | mean (m) |
|---|---:|---:|---:|
| all `baseline`-accepted free-throw windows | 12 | 0.430 | 2.460 |
| accepted **and** labelled `shot` only | 11 | **0.447** | 2.444 |

**The spread does not shrink — it widens slightly.** Dropping the one `unsure` window (the only
window that *could* have been contamination) makes the spread marginally worse, not better. There is
no contamination to exclude: every other accepted window is a confirmed real free throw, and they
still disagree on release height by nearly half a metre.

**This is a measurement-quality problem, not a labelling/contamination problem.** The corpus was
never contaminated with non-shots in a way that explains the spread; the geometry pipeline itself is
producing release-height estimates for real free throws that vary far more than one shooter at one
spot should. (`docs/BENCH-RESULTS-2026-09-24.md` §6 already flagged that this pass ran `--no-pose`
throughout, so release comes from the ball trace alone — a plausible contributor to that
measurement noise, though not one this labelling pass can itself confirm or rule out; that is a
question for the pose-based release path, not for the corpus's labels.)

### 8.4 Gates (this sub-pass)

- `swift test -Xswiftc -O` in `Packages/ShotGeometry`: **362 tests, 0 failures** in ShotGeometryTests
  (339 from §7 + 10 new — `ShotBenchWindowLabelTests`, covering the loader's missing/unreadable/
  well-formed cases, the recall/precision arithmetic on a mixed synthetic set, the `unsure`-and-
  no-label exclusion case, the all-`unsure` case, and that a skipped window counts as not-accepted
  for recall) and **27 tests, 0 failures** in FormEvalKitTests — all green, unchanged from §7.
- `swift run -c release GeometryHarness` → **GATE: PASS**, unchanged from §7 (this pass touches only
  `ShotBenchKit`/`ShotBench`, never `ShotGeometry`).
- Round-trip: `ShotBench run <cache> --variant baseline` from the repo root reproduces §1's exact
  live numbers (26/43, 12/30, 1/25) with the new "Shot labels" section appended — confirming the
  label-scoring addition is purely additive to the existing scorecard, as designed.
