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
`IMG_1765` holds two). *Status:* not started; this is the highest-value open measurement lead.

**B12. The bench groups by clip, but a clip is not a block.** `IMG_1765` contains two shooting positions, so
its within-block spread (0.465 m) was averaging two stations; within one it is 0.190 m. *Change:* group the
spread statistics by recovered standing position, which needs the shooter's feet in the window cache
(`--dump-windows` does not write pose landmarks today). *Status:* not started; it silently distorts any
spread-based verdict until done.

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
