# Design memo — how to make ArcLab vastly better (2026-09-13)

Written after Phase 1, the Phase 2 tooling, and the three research reports. This is a proposal, not a decision. Anything here that changes the brief is marked **[changes brief]**.

## 1. Reframe the product in one sentence

Today the brief says: "measures shooting mechanics from video; the product is repeatability and self-comparison." That is a measurement product. Players do not buy measurements. They buy makes.

Proposed: **ArcLab is an n-of-1 shooting lab. It shows you where your shots cross the rim, tells you what your misses have in common, gives you one thing to try, and then tests honestly whether it worked.**

Four promises, each a screen, each with a falsifiable rule behind it:

| Promise | Screen | What makes it honest |
|---|---|---|
| Show me my shots | Rim map + arc bundle | Drawn from the fitted parabola on the player's own video, with the g-test dot |
| Tell me what my misses have in common | Finding card | Cohen's d ≥ 0.5, FDR-controlled, n ≥ 30 in the cell, evidence sentence with numbers |
| Give me one thing to try | Experiment card | One active intervention, external cue, constraint drill, fading plan |
| Tell me if it worked | Retest verdict | Pre-registered metric/n/target, scored against the frozen baseline, RTM sentence |

Everything else in the app exists to serve one of these four.

## 2. The ten design moves

### 2.1 The rim map is the home screen [changes brief: it makes lateral a first-class metric]

A top-down drawing of the rim, 45.7 cm across. One dot per shot where the ball's centre crossed the rim plane: front/back from the fitted parabola, left/right from the diameter-depth path at oblique views or from a frontal view. Green makes, grey misses. Set-level ellipses drawn over the dots.

Why: it is the golf dispersion plot. Every player reads it in two seconds. "All my misses are short" is a finding nobody needs a coaching licence to state, and depth is the metric with the only large-n published anchor (Daly-Grafstein & Bornn: makes peak ~11" past the front rim). Noah owners say the miss-direction breakdown is the thing they use. No phone app has it.

How: `ShotMetrics.depthPastFrontRim` and `rimCrossingOffset` already exist; `lateralDeviation` comes from the 45°-view diameter path validated in Phase 1 (median 1.7 cm at 1 px diameter noise). Side-only views draw a 1-D strip instead. Show the noise floor as a faint ring so a dot cloud tighter than the instrument is never over-read.

### 2.2 Score sessions in "makes lost per 100", not degrees

The textbook's geometric make-probability model (shrink the rim by the ball's cross-section at the entry angle, count the shot cloud that clears) turns any spread into a cost. Headline per cell: "Your front-to-back spread costs you about 9 makes per 100 from the wing. 7 of those 9 come from release speed."

Why: a degree is meaningless to a 16-year-old; a make is not. It also ranks findings on one scale (the textbook's Tier A ranking) and it works at n = 10 with a wide interval, which solves cold start honestly.

How: `Physics.forward` plus the Ch 5 delta-method attribution give the cost and the split. Bootstrap the interval. Show the interval.

### 2.3 Release speed consistency leads; release angle follows

The coaching research found release-velocity SD predicts three-point performance at r ≈ −0.96 in the one study using the same measurement class as ArcLab, while angle SD was weak. The brief's headline example is angle variance. Reorder: speed SD → depth spread → entry angle → angle SD.

Speed is scale-dependent, so it is honest only with rim calibration (tier A/B). That is fine: depth spread in inches is the same information in the player's units and the rim map already shows it.

The coachable proxy for speed consistency is **rhythm**: dip-bottom-to-release timing, measurable at 120 fps from the ball alone (no pose). Test per player whether timing SD associates with speed SD. If it does, rhythm drills are justified by that player's own data, which is the only justification the thesis allows.

### 2.4 Routines, not free-form sessions

A routine is a scripted set of stations: "5 spots × 10 shots, then 20 free throws." The app announces the station, so shot type and distance are known without tagging, cross-checked against the calibration-derived distance. Every routine produces the same cells, so history is comparable by construction.

Why: cells are the statistical unit and free-form sessions fragment them; the tagging strip is the main friction; and routines are what serious players already do. A routine is also the natural unit for the distance-ladder protocol the textbook uses to discriminate a strength limit from a mechanical one.

Later: routines shareable as files; coach-authored routines.

### 2.5 Voice is the ground truth channel

The player is alone in a gym with a phone on a tripod. Today's protocol has them saying the shot number and "make/miss" out loud. On-device speech recognition turns that into tags with no strip to swipe. "Start", "stop", "skip that one" run the capture. Optional post-shot audio callout of the depth class only ("short", "long", "good"), since a single-shot angle is inside the noise but a depth class is not.

**[changes brief]** The brief says all processing is post-capture. A 1 s flight analysed within ~2 s is still post-capture per shot; keep the rule that numbers are reported per set, and let the callout say only the class.

### 2.6 Preflight that predicts the tier before the first shot

Ten seconds after the tripod is set: rim found, ellipse ratio, camera-to-rim distance from the rim's pixel size, ball pixel size predicted for that distance, shooter-in-frame box, flicker banding check, phone level, thermal state. Verdict: "Tier A: all metrics" or "Move back 1.5 m for threes" or "Lower the tripod 30 cm."

Why: setup failure and false counts are the dominant complaint category for every competitor. The rim's pixel diameter gives the distance for free; nobody else uses the rim as a ruler.

### 2.7 Experiments are the gamified object, not shots

An Experiment card: hypothesis in plain words, the drill with its external cue, the metric, n, target, and earliest counting session, all fixed before the player looks. Sessions tick along a progress bar. The verdict compares against the frozen six-session baseline and prints the regression-to-the-mean sentence when the firing session was in the worst third. One active experiment at a time, enforced in the data model.

Why: streaks and badges reward volume; experiments reward learning. This is the honest version of what Noah sells as "17% better" with no design behind it.

### 2.8 Trust is a feature: show the instrument

Every number carries ±. Every session has a capture-quality block: g-test pass rate, discarded frames, what could not be measured and why. Every shot has a green/amber/red gravity dot. The player can mark a shot "bad detection"; it is excluded, logged, and becomes a labelled example. A two-phone "measure my setup's noise" mode reports the reliability SD once and shows all later findings relative to it.

Why: the brief's user "will not tolerate being told their mechanics are wrong by an app that can't show its work." Competitors hide their method; the 2025–26 "AI coach" apps ship unexplained scores. Showing the instrument is the positioning.

### 2.9 Store crop tracks, not video [changes brief]

The brief defaults to metrics-only storage. Instead keep, per shot, a 64×64 crop around the ball for every frame plus one rim crop, at ~1 MB per shot. This allows re-detection and re-fitting when the pipeline improves (stamp `pipeline_version`), gives the detector its training set, and contains no face or body, which keeps the privacy story intact for minors.

### 2.10 Pool across distances with the player's own distance model (v2, validate first)

Strict per-cell statistics are correct but starve n. Release angle and speed vary with distance predictably per player. Fit each player's own metric-vs-distance curve and analyse residuals from it, so free throws and mid-range shots inform the same variance estimate. Keep strict cells as the default until this is validated on the tagged corpus.

## 3. The screens

1. **Home**: last session's rim map, the one active finding or experiment, band chart of the leading metric per cell.
2. **Session**: shot strip with g dots, per-set table (mean ± SD, n), rim map, arc bundle drawn on one frame, capture-quality block.
3. **Shot**: video with the five overlay elements (detections, fitted parabola, skeleton when available, phase markers, per-frame validity).
4. **Trends**: SD bands over sessions per cell; "watching, 2 of 3 sessions" slump indicator.
5. **Experiments**: active card, history with verdicts, efficacy table once n > 1.
6. **Setup**: preflight verdict, routine picker, noise-floor calibration.

Copy rules: "associated with", never "because"; every value with ± and n; no adjective judges a shot; no target band on a descriptive metric.

## 4. Engineering changes to the plan

- **Detector as two stages**: Vision trajectory finds the flight window (today's synthetic result: it drops ~60 % of frames at 240 fps and lags ½–1 frame, so it cannot be the detector). Then a small Core ML model on crops around the parabola-predicted position gives a box, and a circle fit on the orange mask inside the box gives a sub-pixel centre and diameter. Physics-guided search keeps the model tiny and fast.
- **120 fps default, 240 opt-in**: no 120 Hz flicker banding, half the heat and storage, Phase 1 shows 0.2° mean release-angle error at 120. 240 buys release timing only.
- **Rim once per session**: hoop detector → orange mask → ellipse RANSAC → one confirmation tap; then track drift as the tripod-moved alarm and stabilization anchor. Transform detections, not pixels.
- **Metrics-lost-per-100 and attribution in `ShotGeometry`** now; they are pure functions and can be gated with synthetic shot clouds like Phase 7.
- **Rules file**: start with five, not eighteen: `speed_variance`, `depth_bias`, `entry_angle_low` (Tier A, computed floor), `drift_within_session`, `lateral_consistency` (frontal/45°). Add rules only when a fixture fires and a null fixture stays silent.
- **Pose**: published phone-based elbow error is 12–18°. Ship elbow as a within-player relative metric or not at all; the 5° gate is the test, not the promise.

## 5. Cut or defer

- Universal ideal-form statements of any kind.
- Automatic make/miss from video in v1 (voice gets the ground truth cheaper and produces the corpus for v2).
- Wrist and finger metrics, per the brief.
- Any cloud, account, or upload.

## 6. What the Phase 0 footage should settle first

1. Real Vision recall and timing lag against 50 hand-labelled ball centres.
2. Rim ellipse ratio actually achieved at 7–9 m and 1.0–1.3 m lens height.
3. Whether the deliberately varied block (flat/high/short/long) shows up as a clean injected pattern in the rim map and the engine.
4. Whether dip-to-release timing SD tracks release-speed SD for this shooter.
5. Two-phone or 240/30 fps agreement on release angle and depth.

---

# Part 2 — further innovations (same day, second pass)

Ranked inside each group. Tags: **evidence** (published support exists), **geometry** (follows from physics we already compute), **speculative** (worth a per-player experiment, not a promise). Effort is relative to the current package.

## A. New things a phone can measure that nobody else does

### A1. Expected makes from the trajectory (xFG) — geometry, medium effort
From each shot's rim-plane crossing (depth, lateral, entry angle) compute the probability it goes in using the geometric make model, then refine with the player's own tagged outcomes. Sum over the session: "you shot 42 %, your trajectories were worth 47 %." Separates process from luck. On a bad-luck day the process score stays honest; on a lucky day it warns. Football's xG did this for a whole sport. Also gives a per-shot "how close was that miss" that makes the rim map richer.

### A2. Backspin rate and spin-axis tilt — evidence, high effort
Slegers & Love 2022: spin-axis SD correlated r ≈ 0.80 with accuracy. At 240 fps a 2 rev/s ball rotates ~3° per frame; seams and logo are trackable on a 45 px ball only marginally. The cheap trick: one strip of tape around the ball. With a stripe, spin rate and axis per shot are easy, and detection gets easier too. Sidespin is the physical signature of a thumb push from the guide hand, which is otherwise invisible. Ship as an optional "stripe mode".

### A3. Rhythm and pre-shot routine timing — evidence, low effort
Catch-to-release time, dip-bottom-to-release, and the consistency of both, all from the ball track. Pre-performance routine consistency is a known correlate of free-throw performance. Free at 120 fps; needs no pose.

### A4. Warm-up and fatigue signatures — evidence, low effort
Shots-to-baseline at the start of a session ("you reach your normal arc after about 25 shots") and the drift point near the end ("arc drops after rep ~60"). Both are trend tests already specified. Both become prescriptions: warm-up length before games, block length in practice, and whether the drift point moves later over months (shooting endurance as a trait).

### A5. Audio make/miss and contact classification — low effort, v1.5
Swish, rim, backboard, and floor have distinct sounds. A Create ML sound classifier on the clip's audio gives outcome and contact type per shot without any view dependence. Fused with the rim-crossing geometry it becomes a confident automatic outcome, and it labels "clean swish" vs "rim make" for free. This beats visual make detection on cost and privacy.

### A6. Wrist IMU fusion via Apple Watch — geometry, medium effort
Many players already wear a watch. The wrist accelerometer marks the release instant to the millisecond regardless of occlusion, cross-checking the video release, and gives a per-shot "snap" consistency number. Standalone, the watch counts shots and measures rhythm on days with no tripod, so the data streak survives. A watch-only "count and rhythm" mode widens who can use the app at all.

### A7. Stereo pair mode from two phones — geometry, high effort
The two-phone reliability test already needs two phones side by side. Put them at two positions instead, calibrate both from the rim, sync on a clap, and every shot is a true 3D trajectory with lateral and depth from any pair of views. Teammates' phones become a lab.

### A8. Court and rim context — low effort
Detect double rims from ellipse thickness, outdoor conditions from residual patterns (wind shows up as a non-parabolic residual and a bad g-fit), and tag them. Outdoor double-rim sessions are compared only with each other.

## B. New feedback channels

### B1. Guess-then-reveal — evidence, low effort
After each set, before the rim map appears, the player taps where they think the misses went and how wide the spread was. Then the reveal. Error-estimation ability is a marker of expertise and training it improves learning. A "calibration score" tracks whether the player's feel matches the measurement. It also makes the reveal a moment instead of a table.

### B2. Haptic depth class on the wrist — low effort
One tap short, two taps long, a buzz for good. Private, immediate, no numbers, no phone in hand. Per-set numbers stay in the app so the honesty rule holds.

### B3. Sonified arc — speculative, low effort
A tone after each shot whose pitch encodes entry angle. Players learn to hear their arc the way musicians hear pitch. Augmented auditory feedback has some motor-learning support; test per player with B-style experiments.

### B4. Ghost of your own best — geometry, medium effort
Overlay the mean trajectory of the player's own best sets as a translucent band on replay and, later, on the live viewfinder. Every shot is judged against the player's own best, never against a pro. The band narrowing over months is the progress picture.

### B5. Arc bundle on one frame — geometry, low effort
All arcs of a session drawn on a single frame, makes and misses coloured. The most obvious single picture of spread that exists. Two lines of drawing code once the fits exist.

## C. Practice science built in

### C1. Within-player randomized cue trials — evidence, low effort
The pre/post retest is vulnerable to regression to the mean. Alternating sets with random assignment are not: sets 1–8 get cue A or cue B at random ("aim at the back of the rim" vs "normal"), the set is the unit, the comparison is A vs B on depth spread and xFG. Order effects and RTM cancel by design. This turns the contested motor-learning literature into a per-player answer in one session. It is the single strongest scientific idea in this memo and the cheapest to build: the app already announces sets.

### C2. Retention tests, not just practice performance — evidence, low effort
Learning is what survives to the next session, not what happened at the end of the last one. The first counted set after warm-up is the retention test for the previous session's change. Show "practiced" vs "learned" side by side. Almost nobody does this and it is the honest score for any drill.

### C3. Adaptive routines — speculative, medium effort
Between sets the app can adjust the next station or cue based on the rim map: if the last set was short, the next set's cue is the back rim. That is bandwidth feedback with the set as the bandwidth unit. Evidence is contested, which is exactly why C1 exists to test it per player.

### C4. Blocked vs random scheduling with a rationale — evidence, low effort
Blocked practice while a change is new, random once it holds. The app schedules it and can measure the retention difference with C2.

### C5. Distance ladder as a first-class protocol — evidence, low effort
Five shots at four distances discriminates a strength limit from a mechanical one. The textbook's cause discriminator, built as a routine.

### C6. Post-session check-in as data — low effort
Three taps: tired, sore, focused, each 1–5. Correlate with drift and spread. The "ask_user" discriminators the rules file already wants, humanised.

## D. Motivation and identity

### D1. Verifiable shooting résumé — medium effort
A signed session card: 200 shots, make %, xFG, depth spread, camera tier, g-test pass rate, with a hash of the metrics and a 20-second overlay reel. Recruiting is a named motivation in the brief; a tamper-evident card from an app that shows its work is something a coach can trust more than a highlight tape.

### D2. Consistency streaks instead of make streaks — low effort
Reward the band narrowing and the experiment completed, not the make count. Volume rewards produce volume; consistency rewards produce consistency.

### D3. Monthly lab report — low effort
The textbook's six-section report as a PDF for parents and coaches. Every value with ± and n. Shareable by AirDrop, never uploaded.

### D4. Coach mode — medium effort
One phone, several players by tap-to-select at the rim, per-player histories, a team consistency board, routines authored by the coach and shared as files.

## E. Ecosystem and hardware, all optional

- Shooting-machine companion: the machine gives volume, the phone gives quality; place it on the tripod beside the Gun or Dr. Dish.
- Youth mode: 8.5 ft rims and size 5/6 balls as settings, with the entry floor recomputed from the ball size.
- Stripe kit or lab ball for spin (A2).
- Two-phone stereo (A7).
- Watch as remote, haptic channel, and wrist IMU (A6, B2).

## F. Risks and the hedge for each

| Risk | Hedge |
|---|---|
| Measurement noise swamps the signal for many players, the app shows nothing, they leave | The rim map, arc bundle, and xFG are always available and satisfying at n = 10; findings are the bonus, not the product |
| Setup friction kills adoption | Preflight predicts the tier; routines remove tagging; watch-only mode keeps the streak alive on tripod-less days |
| Findings do not lead to improvement | C1 randomized cue trials give per-player answers in one session; C2 retention tests score what actually stuck |
| A competitor copies the surface | The moat is the honest science, the tagged corpus, the crop-track corpus, and the efficacy table, none of which can be copied from screenshots |
| Pose accuracy never reaches the gate | Elbow ships as a relative metric or not at all; the ball-only metrics carry the product |
| 240 fps heat and flicker | 120 fps default |

## G. If only five things could be built after Phase 3

1. Rim map with xFG (A1, 2.1).
2. Randomized within-player cue trials (C1).
3. Guess-then-reveal (B1).
4. Retention test as the first counted set (C2).
5. Audio make/miss classifier (A5).

Each is low-to-medium effort, each rests on either physics or published evidence, and together they make the app the only shooting tool that can say what worked for this player and prove it.

---

# Part 3 — the numbers, and what they force (third pass, same day)

Simulations run 2026-09-13 with a parabola model, size-7 ball, 18-inch rim, free-throw line (4.19 m to rim centre, release height 2.1 m). Script: scratchpad `makemodel.py` / `trials.py`; the Swift equivalents are now in `ShotGeometry/MakeModel.swift` with tests reproducing the key values.

## 3.1 Speed is the whole game near the optimum

Sensitivity of depth at the rim to each release variable, free throw:

| Release angle | Entry angle | Depth per 1° of angle | Depth per 0.1 m/s of speed |
|---|---|---|---|
| 44° | 27° | +7.2 cm | +16.5 cm |
| 48° | 33° | +3.0 cm | +15.6 cm |
| 50.7° | 38° | 0.0 cm | +15.1 cm |
| 52° | 40° | −0.5 cm | +14.9 cm |
| 55° | 44° | −3.0 cm | +14.3 cm |

At the turnover angle (about 51° from the line) the depth does not depend on release angle at all. A 0.1 m/s speed error, which is 1.4 % of the release speed, moves the ball 15 cm. **A free throw is a speed-control task to about 1 %.** The textbook's worked shooter (77 % of depth variance from speed) is the general case, not a special one.

Design consequence: the "release angle" that every competitor headlines is the least important number for a shooter near 50°. For a flat shooter (44°) angle does matter, which is why the rule is "release angle minus the player's own turnover angle", not a universal target. `ReleaseSensitivity.depthTurnoverAngle` computes it per player from their mean speed and height.

## 3.2 Consistency in makes, not centimetres

Under a forgiving make surface (placeholder shape; see 3.3), free throws aimed at the centre:

| Depth SD at the rim | Speed SD | Angle SD | Makes per 100 |
|---|---|---|---|
| 9 cm | 0.05 m/s | 1.5° | 63 |
| 13 cm | 0.08 | 2.0° | 52 |
| 17 cm | 0.10 | 2.5° | 46 |
| 22 cm | 0.13 | 3.0° | 38 |
| 29 cm | 0.17 | 4.0° | 30 |

Which variance to cut, from a base of 43 makes per 100 (angle SD 2.5°, speed SD 0.10, height SD 3 cm, lateral SD 5 cm):

| Halve this SD | Makes gained per 100 |
|---|---|
| Speed | +13 |
| Lateral | +5 |
| Angle | +2 |
| Height | +1 |

Aim bias matters less than spread: shifting the mean depth by ±8 cm costs 2–3 makes; the spread costs 10–20. The message to a player is one sentence: *tighten your speed and your left-right, and stop worrying about your arc unless you are flat.*

## 3.3 The geometric make model is a lower bound, not xFG

The exact "clean pass" criterion (the ball's swept ellipse fits inside the ring) gives 12 % clean passes at a 17 cm depth SD where a forgiving surface gives 46 %. Real makes mostly touch the ring. Therefore:

- `MakeGeometry.cleanPass` is Tier A and can be shown as "swish probability", never as make probability.
- xFG needs `SoftMakeModel` fitted from the player's tagged outcomes: a logistic or Gaussian surface in (along, lateral) with the geometric model as the shape prior and a published population curve as the starting parameters. Until it is fitted from ≥ 100 tagged shots, the UI labels it "population prior, not yet your data". `SoftMakeModel.isFitted` exists for this reason.
- The voice tags are therefore not a convenience. They are the training set for the headline number.

## 3.4 Randomized cue trials need more sets than intuition says

Sets of 10, per-shot depth SD 15 cm, instrument noise 2 cm, two-sided test at 5 %:

| True effect | 6 sets per arm | 8 per arm | 12 per arm |
|---|---|---|---|
| Mean depth shifts 5 cm | 42 % power | 51 % | 67 % |
| Mean depth shifts 8 cm | 77 % | 87 % | 96 % |
| Depth SD 15 → 12 cm (20 % tighter) | 38 % | — | 52 % at 10, 70 % at 15 |
| Depth SD 15 → 10 cm (33 % tighter) | 81 % | — | 94 % at 10 |

A single session of 120 shots (6 sets per arm) detects only large effects. Consequences:

1. **Trials span sessions.** Randomize within each session, accumulate sets across two to four sessions, and report the running interval. The trial card shows "12 of 24 sets done; current estimate −3 ± 6 cm; undecided."
2. **The verdict vocabulary has three states:** A better, B better, undecided. Undecided is the common outcome and must be presented as normal, never as failure.
3. **Outcome choice matters.** For consistency cues use the set SD (log-scale test); for aim cues use the set mean. For most cues, xFG per set is the single outcome that captures both, once the soft model is fitted.
4. **Pick cues expected to be big.** Aiming at the back of the rim versus the front is a 5–10 cm mean shift and is detectable. "Be smooth" is not a trial.

## 3.5 How many shots to see a consistency change at all

Detectable ratio of two depth SDs at 95 %: 1.36× with 30 shots per side, 1.28× at 50, 1.20× at 100, 1.14× at 200. The brief's rolling 200-shot window is right; below 100 the app cannot honestly claim a consistency change smaller than 20 %. Show the detectable-change floor on the trend screen ("with this many shots we can see changes of 18 % or more").

## 3.6 Regression to the mean and the retention test

Worst-of-six sessions followed by no change at all shows a +1.75 reliability-SD "improvement" against the bad session and +0.00 against the six-session baseline. The textbook guard reproduces exactly; keep it.

Retention tests: a set-of-10 mean depth has a standard error of 4.7 cm, so one last-set/first-set pair can only see a 13 cm change. Pool three session pairs to see 7.6 cm, or use two sets at each end. The retention card therefore reads over a rolling three-session window.

## 3.7 Spin from a taped stripe is feasible

Backspin of 1–3 rev/s is 1.5–4.5° per frame at 240 fps and 3–9° at 120 fps. A stripe on a 45 px ball can be fitted to ~2–3° per frame; over a 200-frame flight the rate is known to better than 1 %, and a 0.2 rev/s sidespin component shows as a ~20° axis tilt. No new hardware; one piece of tape. Ship as an optional mode after the ball detector exists.

## 3.8 What this changes in the build order

1. `MakeModel.swift` is in the package now: clean-pass geometry, the soft surface with a fitted flag, release sensitivities, the turnover angle, and the delta-method depth attribution. Tests reproduce the textbook's worked shooter (14.9 cm depth SD, 77 % from speed).
2. The findings engine's first rule is not "entry angle low". It is **`speed_variance_cost`**: makes lost per 100 attributable to speed SD, computed from the attribution and the fitted make surface, with the interval from the shot count. Second: **`lateral_variance_cost`** on 45°/frontal views. Third: **`flat_arc`** as the player's release angle below their own turnover angle by more than the reliability SD, which is the only form in which an arc rule is Tier A.
3. The rim map gets a "swish zone" outline (clean-pass region for the player's mean entry angle) and, once fitted, a make-probability heat shading.
4. Trials are multi-session objects in the data model with a running estimate and an undecided state.
5. Voice tagging moves from nice-to-have to required for xFG.

## 3.9 The first ten minutes, scripted

1. Open the app, pick "Free throws, 20 shots". Preflight on the tripod: rim found, "Tier A, 7.4 m, lower the phone 20 cm for a rounder rim" if needed.
2. Shoot. Say the number and make or miss. The app says nothing.
3. Walk to the phone. First screen: the arc bundle of 20 shots on one frame, then the rim map with the swish zone. The sentence under it: "Your shots landed in a 14 cm front-to-back band. 71 % of that spread comes from release speed. Angle barely matters at your 50° arc." The g-test dots are green.
4. Guess-then-reveal was skipped on the first session; it starts on the second.
5. No finding, no drill, no score. A line says: "After about 100 tagged shots this becomes your expected-make rate. After 3 sessions we start looking for what separates your makes from your misses."

That is satisfying at n = 20, entirely honest, and it makes the tagging feel like building something rather than paying a tax.

## 3.10 Data model additions (over the brief's §7)

```
Routine      — id, name, stations[] (shot_type, zone_label, distance_m, shots), version, author (self | file)
Station run  — session, routine, station index, set index, cue_id?, trial_arm?
Set          — session, index, station run, n, mean/SD per metric, xFG, feedback_shown (bool), guess (rim-map tap, optional)
Tag source   — per Shot: voice | manual | audio_classifier | inferred, with confidence
Crop track   — per Shot: 64×64 ball crops per frame + rim crop, pipeline_version   (replaces optional clip)
Trial        — player, cell, cue_a, cue_b, outcome_metric, sets_per_session, started, sets_done, running_estimate, ci, verdict ∈ {a, b, undecided}
Experiment   — one active per player (unique index): finding_id, drill_id, retest {metric, n, target, earliest_session}, baseline_frozen, status
Retention    — per session pair: last two sets prev session vs first two sets this session, per cell, pooled over 3 pairs
MakeSurface  — per player × cell: parameters, n_tagged, is_fitted, fitted_at, pipeline_version
Sensitivity  — per player × cell: turnover angle, ∂depth/∂v, attribution shares, n, computed_at
```

## 3.11 Rules v1 (five entries, provenance stated)

```json
[
 {"id":"speed_variance_cost","metric":"release_speed","condition_type":"variance","min_n":100,
  "threshold":{"makes_lost_per_100_from_speed_gte":6},"required_tier":"A","required_view_class":"any",
  "provenance":"published","provenance_note":"Slegers 2021 r=-0.96 speed SD vs 3P%; delta-method attribution (Ch 5); cost via fitted make surface"},
 {"id":"lateral_variance_cost","metric":"lateral_at_rim","condition_type":"variance","min_n":100,
  "threshold":{"makes_lost_per_100_from_lateral_gte":4},"required_tier":"A","required_view_class":"oblique_or_frontal",
  "provenance":"published","provenance_note":"Daly-Grafstein & Bornn: lateral variance, not mean offset, separates contested/uncontested; Slegers & Love 2022"},
 {"id":"flat_arc_vs_own_turnover","metric":"release_angle","condition_type":"absolute_threshold","min_n":30,
  "threshold":{"mean_below_turnover_by_reliability_sd_gte":2},"required_tier":"A","required_view_class":"side_or_oblique",
  "provenance":"published","provenance_note":"geometry: below the turnover angle depth sensitivity to angle grows ~3 cm/deg per 3°; Slegers 2022 individual optimum 4.3±2.1° above min-speed angle"},
 {"id":"depth_bias","metric":"depth_past_front_rim","condition_type":"outcome_separation","min_n":30,
  "threshold":{"cohens_d_gte":0.5,"fdr_q":0.10},"required_tier":"B","required_view_class":"any",
  "provenance":"published","provenance_note":"Daly-Grafstein & Bornn makes peak ~11 in; Noah 45/11 (vendor); direction adjudicated by the player's own tags"},
 {"id":"drift_within_session","metric":"release_speed","condition_type":"drift","min_n":60,
  "threshold":{"total_change_over_session_reliability_sd_gte":2,"robust_slope":"theil_sen"},"required_tier":"A","required_view_class":"any",
  "provenance":"published","provenance_note":"Bourdas 2024 entry angle −3 to −4 % after fatigue; Slawinski 2018 found none in elite U18, so drift is measured, never assumed"}
]
```

Every rule fires a sentence with numbers and n, in "associated with" language, and cites its provenance in the detail view.

## 3.12 Audio outcome classifier — data plan

- Classes: swish, rim-in, rim-out, backboard-in, backboard-out, airball, no-shot.
- Windows: 1.2 s of audio starting 0.2 s before the trajectory's rim-crossing time (known from the fit), so the classifier never has to find the shot.
- Labels: the player's own voice tags give make/miss; rim contact class is inferred from geometry (clean-pass margin) for the first pass and hand-checked on 200 clips.
- Model: Create ML sound classifier on 200–500 labelled windows per class; expected to separate swish from rim easily and rim-in from rim-out only with the geometry fused in.
- Fusion: outcome = argmax over classes of P(audio) × P(geometry). Disagreements go to the tagging strip; agreements skip it.
- Validation: agreement with voice tags ≥ 97 % before the strip is hidden by default.
