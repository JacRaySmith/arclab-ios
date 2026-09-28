# Big changes — the structural moves, ranked by what the logs say

Written 2026-09-19. `docs/IMPROVEMENTS-2026-09-16.md` is the 55-item backlog of things to polish. This file is
the short list of changes that alter how the app works, with the evidence for each and the gate it must pass.
Add to it only when a change moves a measurement, a data model, a capture mode, or the shape of a day; keep
polish in the backlog. Status is updated in place; nothing is removed, it is marked done with the build.

## 0. What the phone logs said on 2026-09-17 and 2026-09-19

Pulled from `Documents/ArcLab/logs/activity-<day>.jsonl` (times UTC).

| session (spot) | shots found | accepted | rate |
|---|---|---|---|
| 09-17 free throws | 29 | 22 | 76 % |
| 09-17 Three | 36 | 12 | 33 % |
| 09-17 College three | 17 | 2 | 12 % |
| 09-19 Three | 36 | 12 | 33 % |
| 09-19 free throws (practice block: baseline) | 7 | 5 | 71 % |

Rejection reasons across both days (a shot can carry one):

| reason | count |
|---|---|
| shot-plane solve not believable: release height outside the band | 36 |
| g_fit off by more than the tolerance (scale, timing, or window contamination) | 30 |
| solve not believable: released too far from / behind the rim (put-back or tip) | 16 |
| release speed outside the band | 4 |
| fitted arc misses the tracked ball | 4 |

Cost: Vision body pose is the whole analysis bill. `body.vision` median 12.0 s per shot on 09-19 (n = 33,
10.4–15.2 s); 1,190 s over the 110 body passes on 09-17. The foot model is 5–6 ms per shot; the ball detector
and the plane fit are ~2 s each per shot.

Behaviour: the app process restarted twice within seconds of the guided record screen on the evening of
09-18 (04:53:37 Z and 04:54:03 Z) with no crash report on the phone and nothing logged in between; the user
saw a black screen and lost the in-progress session (`SessionModel` is memory-only). The same evening the
practice day was built with one block; after it was done the user bounced Today → Practice → Guided five
times in one minute looking for what to do next, then recorded on their own.

## 1. The changes, in the order to take them

**B1. Three-point shots are two-thirds rejected. This is the biggest measurement problem in the app.**
Free throws accept at ~75 %; threes at 33 %, college threes at 12 %. The reasons are not "no ball": the
plane solve lands on an impossible release height or the fitted g is off. That is the open three-point
scale question (release distance / azimuth ambiguity from a single 45° camera at 7 m; see the 09-14
investigation and `docs/PHASE2-PREP.md`). *Change:* constrain the solve with what the app already knows —
the chosen spot's distance (`AnalysisOptions.knownReleaseDistance`) and the rim-calibrated plane — and
report the solve as "distance-assumed" rather than free when the free solve is outside the band; add the
30–45° off-line clip the user still owes as the second view. *Gate:* a FormEval/GeometryHarness re-baseline
with before/after acceptance on the two 09-17/09-19 three sessions (36 + 36 shots), no metric gaining a
number it previously refused, `g` stays the check. *Status:* **root cause found and largely fixed 2026-09-24** — it was the rim trace's implied vertical, not the scale (see `docs/research/three-point-acceptance-2026-09-24.md`). Threes went 1/25 → 12/25 accepted on the corpus, recall 4.8 % → 52.4 %. Remaining refusals are track quality, not geometry. The off-line clip is still wanted.

**B2. A persisted, crash-proof session state machine.** Record → scan → analyse → save must survive a process
death at any step, with the clip kept on disk until the session is saved or discarded, a checkpoint after each
step, and a resume card on launch. Also: log camera runtime errors and interruptions, and whether the previous
run ended cleanly, so the next black screen is diagnosable. *Gate:* kill the app at each of the four steps and
resume with no lost shot; `analysis.resume` follows every `app.launch` with `previousRunEndedCleanly: false`.
*Status:* shipped in 1.3.1 (2026-09-19); phone verification pending.

**B3. The practice day is a sequence, not one block.** After every scored block the app proposes the next
one with the reason (which number, its n, the rule's grade) and what the extra data will let it tell; a day
cap with tomorrow's first block when reached; never an empty Today. *Gate:* the plan's measure computed
identically before and after; every proposal carries n and grade; blocks under the floor say "not enough
shots to tell". *Status:* shipped in 1.3.1; game-like variants added in 1.4.

**B4. A plain-language layer with a lint.** Every drill and gate the user reads follows Setup / Do this / What
the app watches / Done when / Why (grade); the precise statistical version sits behind a tap; a unit test
fails on jargon so it cannot regress. *Gate:* the copy lint passes over every curriculum string; the block card
is readable at 5 m. *Status:* shipped in 1.3.1; the lint covers the 1.4 modules too.

**B5. Body pose costs 12 s per shot for two coachable numbers.** Only jump height (ICC 0.92) and head
horizontal travel (0.86) are coachable at 7 m; the pass runs over every window regardless. *Change:* run
body pose only over the frames the coachable measures use (set → release plus the landing), merge the two
pose passes (HANDOFF item 3), and defer body pose behind the ball metrics so the shot card appears in ~4 s
and the body numbers fill in while the shooter takes the next block. *Gate:* a FormEval re-baseline of the
37 unique free throws; ICC for jump height and head travel unchanged within their SDC; `body.vision` median
under 4 s. *Status:* not started.

**B6. The close-up form clip as a first-class capture mode.** At 7 m the ball hides the hand on ~83 % of
release frames and elbow angle at release has an SDC of 42°. Hands, elbow and guide-hand measures need the
close clip (`FormClipView` exists; capture from the guided flow does not). *Change:* a "Form clip" block type in
the practice day (5 shots, phone 2–3 m away, 45°), scored only on the measures the clip can carry. *Gate:*
hand plates fitted on ≥ 80 % of release frames in the close clip; every measure that stays uncoachable stays
nil with its reason. *Status:* not started; needs the close form clip the user owes.

**B7. Foot angle against the rim, not the camera.** Foot angle is currently measured against the camera→rim
bearing (38° parallax on the reference clip). Wire `RimCalibration`'s rim position into `FootTriangleOptions`.
*Gate:* foot angle at set still repeats to ~2° across the 240 fps clip. *Status:* not started (HANDOFF item 2).

**B8. Detector re-baseline bundle.** Fix the one-pixel tile-origin bug in `CoreMLBallDetector`, motion-gate
the Core ML frames, and choose the decode scale per pass, all in one re-baseline so the gate numbers move
once. *Gate:* `docs/PHASE<N>-REPORT.md` with before/after on the phone shots. *Status:* not started.

**B9. The build must identify itself.** The app still reports `version 0.1.0 build 1` in every `app.launch`
while the docs and GitHub tag say 1.3, so the log cannot tell which build a behaviour came from. *Change:*
`MARKETING_VERSION` / build number set from the release tag at every phone install. *Status:* done 2026-09-19 (1.3.1 (2)).

**B10. Film auto-tagging** — see `docs/DESIGN-FILM-REVIEW-2026-09-19.md`; v1 (1.4) is manual tags plus rim-scanner shot candidates. *Gate:* a measured candidate recall on real game film before any auto-tag claim. *Status:* design only.


**B11. Track quality is now the recall ceiling.** Measured 2026-09-24 over the labelled corpus: the real shots
still refused have degenerate plane solves — ambiguity ratio 0.82–0.95, solve residual 0.21 m against 0.015 m
for accepted windows, and the ball diameter implied by their own track drifting **58 % along a single track**.
Forcing a correct shot-plane azimuth rescues none of them, so this is detection, not geometry. *Change:* make
the detector's diameter self-consistent along a track (the size cannot really change 58 % in flight), and treat
a track whose implied size drifts as untrustworthy rather than fitting it. *Gate:* recall on the labelled
98-window corpus, precision held at 100 %, within-block release-height spread per **position** (not per clip —
`IMG_1765` holds two).
*Status:* **premise corrected 2026-09-27, and this is no longer the top lead.** Two measurements, both in
`docs/EXPERIMENTS.md`:
- The drift is real and it does separate good tracks from bad — implied-diameter spread 0.496 on refused
  real shots against 0.241 on accepted ones (AUC 0.82). And the plane's implied ball diameter is otherwise a
  *precise* quantity: over accepted windows it is 1.157 / 1.176 / 1.181 × the true 0.2385 m on the three
  clips — three camera placements agreeing to within 2 %, within-clip IQR 1.5–2.3 %. The detector's box bias
  is stable, not noisy.
- But **the azimuth is never the gate.** Of the 31 labelled-real shots `autoFoundNoPool` refuses, the refusal
  is the gravity gate 19 times, a failed trajectory fit 7 times, the plausibility gate 5 times, and the
  azimuth solve **zero** times. Feeding the solve an absolute ball-size prior
  (`AnalysisOptions.ballSizeCue`, swept at three weights) rescued **no** window and made the fit residual
  significantly worse — reverted. The ambiguity ratio this item rests on is a *symptom* of a bad track, not
  the mechanism that rejects it.

**B14 below replaces this as the top lead.** Motion blur is also ruled out as the cause of the drift (sign
test p = 0.125; it explains 1.7 % of the variance against a 30–57 % drift). What remains untested:
`BallDetector.hybrid` mixes a Core ML box with a threshold-dependent blob candidate along one track and
records neither which was used nor the box's `w`/`h`, so the drift's real cause is undiagnosable from the
cache today. Recording provenance and `w`/`h` in `--dump-windows` is the cheap next step if anyone returns.

**B12. The bench groups by clip, but a clip is not a block.** `IMG_1765` contains two shooting positions, so
its within-block spread (0.465 m) was averaging two stations; within one it is 0.190 m. *Change:* group the
spread statistics by recovered standing position, which needs the shooter's feet in the window cache
(`--dump-windows` does not write pose landmarks today). *Status:* not started; it silently distorts any
spread-based verdict until done.

**B13. The plan asked for the same block over and over, and the day was too long to finish.** The
shooter's report after using 1.4: the plan "takes too long, takes up too much battery, and kept giving me
the same thing to do". The engine's own table explains the third part — `measureFlat`, `measureUnavailable`
and `notEnoughShots` re-issued themselves with the same spot, the same count and the same sentences until
the 8-block / 100-shot cap stopped them, and `NextBlock.State` had no idea what it had already asked for.
*Change (shipped 2026-09-25):* `State.proposalsToday` plus `NextBlock.escalate` — the second time a
stalling row comes up it asks for something genuinely different (drop the cue; move the phone; size the
block by the share of shots that counted), and the third time it ends the day and says so. Day cap
5 blocks / 60 shots, down from 8 / 100 — still a stated convention. The Shoot tab became the shooter's
three choices (plan · single session · form clip), and the body pass can be skipped from the screen that
shows it running, since every number the block is scored on is already in by then. *Gate:* 434 + 27 tests
with 0 failures, eight of them new on the repeat rule; GeometryHarness `GATE: PASS` byte-identical to
PHASE1-REPORT; Release build clean. **No measurement changed** — no `AnalysisOptions`, no `EXPERIMENTS.md`
row. *Status:* shipped as **1.4.1 (4)**, on the phone and launching (log says so); unverified in a real
session. The cap and the 30-shot block ceiling are
conventions and want the shooter's opinion after a real day. The battery ceiling is untouched: it is B5's
12 s a shot, which is structural by §3(a) and was left alone on purpose.

**B14. The shots that are refused are short arcs of badly-tracked ball, and the fit's own span floor
lets them through.** Measured 2026-09-27 (`docs/EXPERIMENTS.md`, and the two new test files below).

*The evidence, in order.* Of the 31 labelled-real shots `autoFoundNoPool` refuses, the refusal is the
gravity gate 19 times, a failed trajectory fit 7, the plausibility gate 5, and the azimuth solve **0** —
so the azimuth is never the gate (which is what retired B11). The 19 gravity failures are not a scale
or frame-rate bug: `g_fit / 9.81` runs from **−2.04 to +16.04**. Comparing the raw cached tracks:

| | accepted real shots | gravity-refused real shots |
|---|---|---|
| median samples in the window | **122** | **34** |
| median time span | **1.08 s** | **0.32 s** |
| median p90 image speed | 2 551 px/s | **6 131 px/s** |

A quarter of the arc, over a third of the time, moving 2.4× faster in the image.

*Why that is fatal.* Curvature is the only thing carrying `g`, and a parabola's sagitta over a span T
is `g·T²/8` — the signal falls as `T²` while the noise does not. Swept on synthetic arcs
(`TrackSpanAndGravityTests`), the share of draws passing the 8 % gravity gate at 120 fps:

| span | noise 0.007 m (≈1.5 px at 7 m) | 0.015 m | 0.030 m |
|---|---|---|---|
| 0.15 s (**the current `minimumSpan`**) | **34 %** | 14 % | 7 % |
| 0.25 s | 87 % | 51 % | 29 % |
| 0.32 s (**the refused windows' span**) | 98 % | 83 % | **52 %** |
| 0.50 s | 100 % | 100 % | 93 % |
| 1.00 s (**the accepted windows' span**) | 100 % | 100 % | 100 % |

Two things follow, and the second is the one that was not obvious:
1. `TrajectoryFitOptions.minimumSpan = 0.15 s` admits arcs where **a perfectly tracked ball passes
   the gravity gate only 34 % of the time.** At that span the gate is measuring the span, not the shot.
2. Span alone does **not** explain the refusals — a *clean* 0.32 s arc passes 98 % of the time. It is
   span **and** detection noise together. So there are two independent levers, and either moves them.

*Change, in the order the evidence supports:*
- **Refuse honestly instead of fabricating.** A window too short for `g` to be determined should be
  refused with "the arc is too short to measure gravity (0.32 s; needs ≈0.5 s at this track quality)",
  not fitted and then rejected for a `g` of −20 m/s². Reporting −20 m/s² is a fabricated number
  (CLAUDE.md rule 1) and it sends every reader — including B11 — hunting the wrong cause. This is the
  cheapest change here and it costs no recall, because those windows are refused either way.
- **Then lengthen the tracks.** The refused windows move 2.4× faster in the image, which is where the
  detector loses the ball. Extending a track through fast motion is worth more than any geometry
  change: at 1.0 s even 0.030 m noise passes the gate 100 % of the time.
- **Do not** raise `minimumSpan` on its own without the refusal message — that converts a wrong number
  into a silent disappearance, which is worse.

*What was ruled out on the way, so nobody re-runs it:* the azimuth solve (never the gate), an absolute
ball-size prior (rescued 0 windows, made the residual worse, reverted), motion blur as the cause of the
implied-diameter drift (sign test p = 0.125), and a wrong focal length (re-run at the measured 66.3/67.8/65.4°;
**0 of 98 windows changed verdict**). The flight-window segmentation itself is now tested
(`FlightWindowFinderTests`, 9 tests) and is correct on clean, noisy, 30 fps, flight-only, post-rebound
and held-ball-before tracks — so it is not the fault either.

*Gate:* recall on the labelled 98-window corpus with precision held at 100 %, and the refusal histogram
of labelled-real shots showing "arc too short" where it is true instead of a scattered `g`.
*Status:* not started. **This is the highest-value open measurement lead**, and the first step is cheap:
no new footage, no new model, no device.

## 2. Footage the user owes (blocks B1, B6 and the footwork work)

- The 30–45° off-line clip (B1's second view).
- The close-up form clip, 2–3 m, 45° (B6).
- The footwork request in `docs/DESIGN-FOOTWORK-2026-09-15.md` §6.
- The behind clip with tape on the ball (spin).

## 3. What counts as big

A change belongs here if it (a) changes what a metric means or how often it is available, (b) changes a
persisted data model, (c) adds or removes a capture mode, or (d) changes what a day of practice looks like.
Everything else is backlog. Each entry needs the evidence line, the change in one paragraph, and a gate that
can fail.
