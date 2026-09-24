# Court-anchored camera pose — state on 2026-09-24

**Status: built and merged, defaulted off, NOT validated.** The agent that wrote this stalled twice
before finishing, and its uncommitted work was rescued, committed and merged by the session that
supervised it. Read this before trusting anything in `CourtCalibration.swift`.

## The idea

A traced rim ellipse plus a measured vertical fixes five of the six camera pose parameters: the rim
centre in the camera frame, and the camera's tilt relative to gravity. It cannot fix the sixth — the
**bearing**, meaning where around the hoop the camera stands — because a circle is symmetric about
its own axis. That missing degree of freedom is why `ShotPlaneSolver` solves a shot-plane azimuth per
shot from weak cues, and why `AnalysisOptions.knownReleaseDistance` exists as an escape hatch.

Any second court feature at a known position relative to the rim fixes the bearing. The dimensions
are already in `Constants.swift` (rim 3.048 m, free-throw line 4.191 m from the rim centre, backboard
1.829 × 1.067 m, lane and three-point figures in `CourtType`).

## What was built

- `Packages/ShotGeometry/Sources/ShotGeometry/CourtCalibration.swift` (843 lines) and
  `CourtAnchor.swift` — the pose solve and the anchor type.
- `AnalysisOptions.courtAnchor` (**default nil**) and an `allowedAzimuths` parameter on the plane
  solver (**default nil**), so no shipped behaviour moved.
- `CourtCalibrationTests.swift`, `CourtCorpusTests.swift` — green.
- A `courtAnchored` variant in `ShotBenchKit/Variants.swift`.

## What was NOT done, and matters

1. **No recovered-versus-known validation.** The strongest available evidence was never produced:
   does the solved pose put the rim 3.048 m above the floor, the free-throw line 4.191 m from the rim
   centre, and the camera near the ≈1.2 m lens height the field note in `docs/PHASE2-PREP.md`
   records? Until that table exists, a bench gain could be overfitting and should be read that way.
2. **The corpus court marks are a single hand-marked stance per clip**, not per-shot and not per
   position, because the window cache carries no pose landmarks.
3. No write-up of the pose formulation by its author; this file is the supervising session's
   reconstruction from the code and the measured result.

## The measured result

`ShotBench run` over the 98-window labelled corpus, `courtAnchored` against `autoFoundTrace`:

| clip | autoFoundTrace | courtAnchored |
|---|---|---|
| IMG_1764 elbow | 28 / 43 | 28 / 43 |
| IMG_1765 free throw | 12 / 30 | **6 / 30** |
| IMG_1766 three | 12 / 25 | **14 / 25** |
| overall recall | 56.8 % | 53.4 % |
| precision | 100 % | 100 % |

**The free-throw loss is explained, not mysterious.** `IMG_1765` contains two distinct shooting
positions (13 shots near 241.3°, 15 near 293.7°; see `docs/BENCH-RESULTS-azimuth-2026-09-24.md`). A
single marked stance pins the bearing window to one cluster, so the other cluster's shots are
refused. That the number halves is what that hypothesis predicts, so this run **corroborates the
two-position finding independently** rather than contradicting the court idea.

The three-point clip, where the single stance is correct, gained two windows.

## What to do next with it

1. Mark **both** free-throw stations, re-run, and judge the idea on a corpus whose marks are right.
2. Produce the recovered-versus-known table (item 1 above). That is better evidence than any bench
   number because the pose is not fitted to those quantities.
3. Better than marking at all: derive the stance per shot from the shooter's feet. That needs pose
   landmarks in the window cache, which `--dump-windows` does not currently write.
4. Remember the measured sensitivity before expecting much: release height moves ≈0.025 m per degree
   of azimuth, and within-block azimuth spread is 1.2–2.5°, so the azimuth accounts for only 2–4 % of
   the release-height variance. The refused shots are a **track-quality** problem (degenerate solves,
   implied ball size drifting 58 % along a track), not an azimuth problem.
