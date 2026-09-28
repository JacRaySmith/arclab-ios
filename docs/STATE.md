# STATE — what is true right now

**Overwrite this file in place. Never append a new section to it.**
`docs/HANDOFF.md` is what happens when "current state" gets appended five times instead of edited
once: it is 149 KB, its five `START HERE` sections have to be diffed against each other to learn the
state, and two of them still assert a day cap and a foot-angle repeatability that later sections
contradict. HANDOFF is now the **archive of past states plus the topic deep-dives** — read it for
history and for the measurement write-ups it alone carries, not for what is true today.

Last updated **2026-09-27**.

---

## What ships

**1.4.1 (4)**, installed on the paired iPhone 14 Pro on 2026-09-25 and launching (its own log reports
`version 1.4.1 / build 4`, `previousRunEndedCleanly: true`, screen `today`, 14 saved sessions).
Free provisioning was refreshed at install, so **this build stops launching around 2026-10-02** and
must be reinstalled.

**Nothing has been shot on it.** The Shoot tab's three choices, the escalation rule and the
skip-the-body-models button all still want one guided block and one plan day on a real court.

Five tabs: Shoot · Review · Learn · IQ · You. `App/README.md` describes what each screen does.

## Gates, as of this file's date

| gate | state |
|---|---|
| `swift test` | **461 ShotGeometryTests + 27 FormEvalKitTests, 0 failures** (was 434 + 27 on 2026-09-25; +27 this pass — `ShotAcceptanceTests`, `BallSizeCueTests`, `FlightWindowFinderTests`, `TrackSpanAndGravityTests`) |
| `GeometryHarness` | **GATE: PASS**, byte-identical to `docs/PHASE1-REPORT.md` — row I (3 px noise) still marginally FAILs exactly as recorded there, which is how you know the fit has not moved |
| App Release build | last verified 2026-09-25 (simulator, clean derived-data path, after `xcodegen generate`) |

**`swift test` cannot codesign its test bundle inside this folder** — it is file-provider-synced, so
`com.apple.FinderInfo` returns to the build product mid-build and `xattr -c` does not hold. Build
outside the tree: `swift test --scratch-path <dir under /tmp>`, `-derivedDataPath` for `xcodebuild`.
A gate that cannot run must never be read as a gate that passed.

## The measurement loop, in three commands

```
TrajectoryProbe session <clip> --rim <rim.json> --time-scale 4 --no-pose --spot <name> --dump-windows <dir>
ShotBench run <dir> --variant <name> --json out.json      # replays the cache, no video, seconds
ShotBench compare base.json cand.json                      # exact McNemar on flipped verdicts
```

The cache for the three 2026-09-13 clips is **not in the repo** (reproducible, and `/private/tmp` is
purged). Rebuilding all three takes about 20 minutes on this Mac — `IMG_1764` is a 22-minute file and
the scan decodes it once. A correct rebuild reproduces **26/43, 12/30, 1/25 — 98 windows**; if it does
not, stop and find out why before trusting anything downstream.

`ShotBench run` now takes `--acceptance shipping|legacy` and **defaults to `shipping`**, the rule the
phone applies. Every number in `docs/EXPERIMENTS.md` dated 2026-09-24 was scored with `legacy` and
reproduces with that flag; see `docs/PIPELINE.md`.

## Where the numbers stand on the 2026-09-13 corpus

98 windows, all hand-labelled (88 `shot`, 6 `notShot`, 4 `unsure`). Under the shipping acceptance rule:

| variant | accepted | recall | precision |
|---|---|---|---|
| `baseline` | 44 / 98 | 48.9 % | 100 % |
| `autoFoundTrace` | 57 / 98 | 62.5 % | 100 % |
| `autoFoundNoPool` | 59 / 98 | 64.8 % | 100 % |

**Precision has been 100 % for every variant ever run.** Not one accepted window was a non-shot. The
whole problem is recall, and nothing may cost that precision.

## The open lead

**`BIG-CHANGES.md` B14.** The shots still refused are short arcs of badly-tracked ball: the accepted
windows carry a median 122 samples over 1.08 s, the gravity-refused ones 34 samples over 0.32 s moving
2.4× faster in the image. At the fit's current `minimumSpan` of 0.15 s a *perfectly tracked* ball
passes the 8 % gravity gate only 34 % of the time. First change is honesty — refuse an arc too short
to determine `g` as such, instead of reporting a `g` of −20 m/s². Then lengthen the tracks.

B11 (detector diameter self-consistency) **was the top lead and is not any more**: the azimuth solve
is never the gate on this corpus, an absolute ball-size prior rescued zero windows, and motion blur
does not explain the diameter drift. All three are measured rows in `docs/EXPERIMENTS.md`.

## Blocked on the user

- **Footage owed:** the 30–45° off-line clip (B1's second view); the close-up form clip, 2–3 m at 45°
  (B6); the footwork request in `docs/DESIGN-FOOTWORK-2026-09-15.md` §6; the behind clip with tape on
  the ball (spin); the second-angle clips for multi-view (`docs/DESIGN-MULTIVIEW-2026-09-24.md` wants
  45–90° of bearing separation; sync is recovered from the ball itself, so no synchronised start).
- **The phone:** reinstall before ~2026-10-02. iOS needs the developer certificate trusted under
  Settings → General → VPN & Device Management.
- **A real session on 1.4.1** — the rim-tilt logging, the three-choice Shoot tab, the plan's
  escalation rule and the skip button are all unexercised by an actual day of shooting.
- **A decision:** 4 of the 17 free throws the app counts as measured on this corpus have **no release
  height, speed or angle** — the release instant was never in frame. They are accepted because the app
  does not refuse a shot for a metric it honestly could not compute, but "17 counted" is then not the
  same claim as "17 produced the numbers the block is scored on" (12 have both release and arc). The
  plan engine already uses the per-measure n, so this is a reporting question, not a maths one.

## Work in flight, unvalidated

- **Court-anchored pose** (`CourtCalibration.swift`, defaulted off, merged) — built but never
  validated; read `docs/research/court-anchored-pose-2026-09-24.md` first, it names what was not done.
- **Multi-view 3-D** (`MultiViewFit.swift`, `MultiViewSync.swift`, merged) — synthetic sweeps only,
  awaiting footage. No product path calls either.
- **`BallSizeCue`** (`AnalysisOptions.ballSizeCue`, defaulted off) — measured and reverted; kept only
  so the negative result stays reproducible.

## Traps

- **A gate that cannot report its own failure is worse than no gate.** `build-app.sh` once skipped
  `xcodegen generate`, so a newly added file was never compiled and the build still printed SUCCEEDED.
  Check that a gate would catch its own absence.
- **Worktree agents stall.** Tell them to commit early; rescuing 1 548 uncommitted lines is luck.
- **Merge `main` into a worktree before quoting a test count** — several agents have reported
  different baselines from forks taken at different times.
- **The repo is ~6.4 GB**, 5.3 GB of it the irreplaceable `footage/2026-09-13/` corpus. `.build`
  directories and the `tools/pytrack/.venv` were cleared on 2026-09-27; `tools/pytrack/requirements-legacy.txt`
  records how to rebuild the working environment (mediapipe **0.10.14** — 1.0.1 aborts in Metal here).
