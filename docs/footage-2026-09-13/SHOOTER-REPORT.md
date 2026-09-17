# Shooter report — session of 2026-09-13 (first automated pass, 2026-09-14)

Camera: right wing, ~8 m off the shot line, 1× lens, 1080p at 120 fps slo-mo. Outdoor court, night, fan backboard.
Everything below is measured; nothing is a target. Statistics use only shots whose fitted gravity is within 8 % of 9.81
(the pipeline's own honesty check). Outcomes are inferred from the ball's behaviour at the rim and marked as such.

## What was measured

| Block | Windows found | Tracking passes | Gravity gate passes | Release angle | Release height | Release speed | Entry angle | Depth past front rim |
|---|---|---|---|---|---|---|---|---|
| Free throws | 31 | 12 | 6 | 46.6 ± 3.6° | 2.43 ± 0.26 m | 7.23 ± 0.11 m/s | 38.4 ± 3.4° | 17.7 ± 4.7 cm |
| Elbow, alternating sides | 43 | 23 | 16 | 49.0 ± 3.1° | 2.47 ± 0.26 m | 6.66 ± 0.30 m/s | 41.8 ± 3.0° | 28.6 ± 14.0 cm |
| Threes | 27 | 12 | 1 | (n=1: 46.9°) | (2.44 m) | (7.46 m/s) | (40.2°) | (−21 cm) |

Rim centre is 22.9 cm past the front rim. Published make rates for NBA threes peak around 11 in (28 cm) depth and mid-40s entry.

The three-point block is internally consistent but not yet validated: with the tracker fixed and a zero-roll camera assumed, 12 threes give release 42–48°, height 2.3–2.9 m, speed 6.9–7.4 m/s, entry 37–46°, ball −27 to +23 cm from the front rim, but every one of them fits gravity 9–16 % low. That is a uniform scale error in that clip's calibration (the ring sits at the frame edge; a rim-distance, lens or ring-edge error of ~12 %), not a frame-rate effect (a lower recording rate would push g up, not down). Per the brief those shots are held back, not reported. (Earlier paragraph kept for the record:) The three-point block is not yet measurable as a block. The tracking is now good (12 of 27 windows pass the tracking grader, ball followed from the hands to the rim), but the rim calibration for that clip is unreliable: the camera was re-aimed so the ring sits at the far right edge of the frame, its ellipse normal came out with a 16° roll the tripod never had, and with either that normal or an assumed zero-roll pitch only one shot passes both the gravity gate and the physical-plausibility gate. The fix is a better calibration for that block (backboard plus rim, or a lens calibration), not more tracking work. One valid three: release 46.9° at 2.44 m, 7.46 m/s, entry 40.2°.

## What it says so far (previews, not findings: the engine needs 30 tagged shots per cell)

- **Release speed is very consistent** at the line (SD 0.11 m/s ≈ 1.5 %). That is the variable that costs makes fastest, so this is a strength.
- **Entry angle at the line averages 38°**, a few degrees below where makes cluster; from the elbow it is 42°. Same release angle, different distance: nothing to change yet, just something to watch as n grows.
- **From the elbow, misses were mostly long**: 5 of 8 inferred misses crossed more than 7 cm past the rim centre; the depth spread there (SD 14 cm) is three times the free-throw spread. If that holds at n ≥ 30, the finding would read "elbow misses are associated with the ball travelling long", and the rim map would show it directly.
- **Pose**: elbow at full extension near release ~156–161° (both blocks), knee minimum ~115–133°, dip-to-release 0.68–0.77 s, jump 0.10–0.12 m. Elbow angles at the release frame itself are noisy (SD 30–50°) with this pose model at 8 m, so treat all pose numbers as relative only.

## Release-frame accuracy (your labels)

Three shots labelled by hand: the release detector is within 4 ms on two and 37 ms early on one. Mean bias −15 ms ≈ 0.8° of release angle.

## What would make the next session better

1. A metre of sky above the arc (tilt up or step back): the apex left the frame on every free throw.
2. Say "make" / "miss" after each shot: the audio becomes the outcome label and unlocks the make/miss statistics.
3. Same 120 fps setting is fine; 240 is not needed for these metrics.

## Update 2026-09-14 (evening): all three blocks measurable

The three-point block's "uniform scale error" was the hand-traced rim: its right half sat on the backboard bracket, so the
ellipse was centred ~40 px too far right with a spurious roll and a fatter axis ratio (0.33 vs 0.25). Re-fitting every
block with the automatic rim finder's inner-edge points (`footage/2026-09-13/rim_176N_found.json`, RimFinder in
Packages/ShotVideo) and the same tracker:

| block | accepted / windows | release angle | release height | release speed | entry angle | depth past front rim | g_fit |
|---|---|---|---|---|---|---|---|
| free throws | 11 / 31 (was 6) | 46.7 ± 4.2° | 2.40 ± 0.39 m | 7.31 ± 0.37 m/s | 37.8 ± 3.3° (n 10) | 19 ± 12 cm | 9.76 ± 0.40 |
| elbow | 18 / 43 (was 16) | 50.0 ± 2.4° | 2.25 ± 0.24 m | 7.00 ± 0.30 m/s | 39.9 ± 3.0° (n 17) | 27 ± 15 cm | 9.35 ± 0.18 |
| threes | 11 / 27 (was 0) | 47.9 ± 2.2° | 2.47 ± 0.16 m | 7.65 ± 0.61 m/s | 42.0 ± 2.8° | 16 ± 15 cm | 9.30 ± 0.12 |

Acceptance is the 8 % gravity gate plus the plausibility gate (height 1.6–3.3 m, speed 4.5–11 m/s, depth −0.6…1.0 m).
Outcomes are still inferred from the ball at the rim (threes: 5 make, 5 miss, 1 unknown; elbow 3/8/7; free throws 1/5/5).

What the numbers say, with the same honesty rules as above (associations, n < 30 per cell, no targets):
- Release speed spread is the number that matters most for depth: 0.30 m/s SD at the elbow and 0.37 m/s at the line map to
  roughly ±45–55 cm of depth at the rim; the threes' 0.61 m/s includes two long-and-short outliers.
- Entry angles sit at 38–42°, the low side of the published mid-40s band, on every spot; the threes are the highest.
- Release angle rises with distance the way it should not: 46.7° (line) → 50.0° (elbow) → 47.9° (three) with the elbow the
  steepest and the slowest — those are the shots that fell short most often (8 inferred misses of 11 with an outcome).

Still open: elbow and three g_fit sit 5 % low with a tight spread, which is now a lens-focal-length question (hFOV 48° was
inferred from an assumed rim distance, never measured); the in-app recorder logs the true field of view of every format.

## First in-app session on the phone (2026-09-14, 23:11 UTC, iPhone 14 Pro, Release build)

433 s PhotoKit original (real 120 fps timestamps), rim found automatically (confidence 0.83, residual 1.1 px, camera→rim
9.74 m), fast scan 48 windows in ~130 s, analysis 414 s (8.7 s per shot: Core ML tiles 4.3 s, body pose 2.1 s). **35 of
46 measured windows accepted** (g_fit 9.38 ± 0.11 → lens ≈ 46° vs the assumed 48°; 10 rejects were contaminated windows
with g far off). Accepted block: release 7.17 ± 0.18 m/s, 49.9 ± 1.8°, height 2.13 ± 0.07 m; entry 38.2 ± 3.0°; depth
32 ± 17 cm past the front rim; inferred 9 make / 25 miss / 1 unknown (misses long); dip→release 0.78 ± 0.08 s; fit rms
6.2 ± 1.2 px. The same clip on the previous build (hand-marked rim, 48°): 2 of 42 accepted in 31 min, g_fit 8.21.

Second in-app session the same night (506 s clip, rim found automatically at 0.88, camera→rim 10.67 m, 39 windows,
35 measured, **29 accepted**, 319 s): g_fit 9.67 ± 0.15 (lens within 1.5 %), release 8.09 ± 0.63 m/s at 48.3 ± 4.6°
from 2.34 ± 0.13 m, entry 40.7 ± 2.7°, depth 33 ± 21 cm long, inferred 10 make / 15 miss / 4 unknown, dip→release
0.58 ± 0.11 s. The faster, wider-spread release says a longer spot than the first clip (the spot label is the shooter's
to give when saving). Neither session was saved in the app at the time of writing.
