# Project Brief v2: iOS Basketball Shot Analysis App

> **Supersedes v1.** Changes: import-first ingestion with quality tiering, rim-ellipse calibration as primary, view class derived rather than declared, falsifiable rules engine, distance/shot-type bucketing, revised phase order.
>
> **How to use.** Paste Sections 0–9 into Claude Code as your first message. Work one phase at a time. Do not pass a gate until it passes.

---

## 0. Role and rules of engagement

You are building a native iOS app that measures basketball shooting mechanics from video, for serious high school and college players.

1. **Verify the environment first.** Xcode version, Swift version, whether a physical device is available. This app cannot be meaningfully tested in Simulator.
2. **Verify API surfaces against current documentation.** Vision moved to a modern Swift async/await API in iOS 18 alongside the legacy `VN*` classes. Do not assume symbol names from memory — check the SDK or docs and report what you find before using them.
3. **Never fabricate a number.** If a metric can't be computed reliably, return `nil` with a reason. A confidently wrong angle is worse than no angle. This is the most important rule in the project.
4. **Test harness before feature.** See Phase 1.
5. **Stop and ask** when a spec decision has real consequences. Do not silently choose.

---

## 1. User and thesis

**Primary user:** serious HS / AAU / college player. Shoots 200–500 reps per session, multiple sessions per week, often alone, in a shared gym with limited court time. Owns a recent iPhone. Motivated by slumps, recruiting, and consistency. Will tolerate a tripod if setup takes under 30 seconds. Will not tolerate being told their mechanics are wrong by an app that can't show its work.

**Thesis:** absolute accuracy is owned by expensive fixed hardware. **Repeatability and self-comparison are the product.** "Your release angle varies 6.2° across your last 200 reps, and the flat ones miss short" beats claiming an exact 47.3°. Design every decision around variance, trend, and the player's own make/miss data.

**Differentiator vs. free incumbents:** they count shots and report averages. We report *variance*, *what separates your makes from your misses*, *within-session fatigue*, and *change over months* — bucketed by shot type and distance so the comparisons are actually valid.

### Non-goals for v1
- Real-time feedback during the shot. All processing is post-capture.
- Game footage, contested shots, shots off movement beyond a simple 1-dribble pull-up.
- Any server, any account, any upload. Fully on-device.
- Automatic make/miss detection (v2 — see §5).

---

## 2. Hard constraints

| Constraint | Value |
|---|---|
| Platform | Native iOS, Swift 6, SwiftUI |
| Min target | iOS 26 (challenge this if install-base data suggests otherwise) |
| Network | **Zero network calls in the analysis path.** On-device is a product principle, not a v1 shortcut — the user base includes minors and body-pose data is plausibly biometric under laws like Illinois BIPA. |
| Persistence | SwiftData |
| Capture | AVFoundation, 1080p @120fps min, 240fps preferred. Log the format actually achieved. |
| Ball detection | **Create ML object detection.** Do NOT use Ultralytics YOLO — it's AGPL-3.0 and incompatible with a closed-source commercial app. Check dataset licences too. |
| Concurrency | Analysis off the main actor, with progress reporting and thermal-state awareness |

### Architectural rule

The geometry and statistics layer must be a **pure Swift package depending only on Foundation and simd** — no Vision, no AVFoundation, no UIKit. Everything in §4 and §6 lives there and is unit-testable without a device. This is what lets you iterate without a human in the loop on every change.

---

## 3. Ingestion: two paths, one pipeline

Both import and in-app capture feed the same analysis pipeline. They differ only in what quality you can guarantee.

### Quality tiering (applied at ingest, stored permanently)

| Tier | Criteria | Consequence |
|---|---|---|
| A | ≥60fps, camera stable, rim visible throughout | All metrics. Counts toward baselines. |
| B | 30fps, stable (or stabilizable), rim visible | Trajectory metrics only. Confidence-flagged. Counts toward baselines at reduced weight. No release-time, no fine pose metrics. |
| C | Handheld beyond rescue, rim absent, or shooter cropped | Rejected. Show a specific reason and a "how to film it" card. |

**Tier is a first-class field on every Shot.** Baselines and findings are computed from tier A and B only, with B down-weighted. Never let low-tier imports silently corrupt longitudinal statistics — that record *is* the product.

### Rim-anchored stabilization

If the rim is detected in every frame, register frames against the rim's detected position to remove camera motion. This promotes a meaningful fraction of handheld footage from C to B. Fails when the rim leaves frame; detect and degrade gracefully.

### Multi-person scenes

Gyms are shared. Do not assume one person in frame. At the release instant, select the pose skeleton whose wrist is nearest the ball. If ambiguous, show a frame and let the user tap the shooter once per session.

### Shot taxonomy

Every shot is tagged with **type** (form shooting / catch-and-shoot / off-dribble / free throw) and **distance bucket** (derived from calibration, bucketed at roughly 1m intervals, plus named zones: FT, mid, corner 3, wing 3, top 3). All statistics in §6 run *within* a (type, bucket) cell. Mixing free throws and threes makes every metric bimodal and every comparison meaningless.

---

## 4. Geometry and physics

**This section is the heart of the app. Wrong here and nothing else matters.**

### 4.1 Known dimensions

```
Rim inner diameter           0.4572 m  (18 in)
Rim height (top of ring)     3.048 m   (10 ft)
Rim center to backboard face 0.381 m   (6 in gap + 9 in radius)
Backboard (rectangular)      1.829 × 1.067 m  (72 × 42 in)
Backboard inner rectangle    0.610 × 0.457 m  (24 × 18 in)
FT line to backboard face    4.572 m   (15 ft)
Ball diameter, size 7        ≈ 0.2385 m
Ball diameter, size 6        ≈ 0.2304 m
Three-point line   NBA 7.24 m / NCAA-M 6.75 m / NCAA-W & HS 6.32 m / HS 6.02 m
```
Confirm the 3-pt distances against current rulebooks; they have changed and vary by level. Make court type a user setting.

### 4.2 Calibration — rim ellipse primary

A circle of known diameter projects to an ellipse. Fit the rim's ellipse and recover camera pose up to a two-fold ambiguity, resolved by knowing the rim is horizontal. The rim is orange, high-contrast, always present, and never transparent.

**Fallbacks, in order:**
1. **Rim ellipse.** Primary. Degrades when the minor/major axis ratio drops below ~0.15 (camera too low) — detect this and warn the user to raise the camera.
2. **Backboard rectangle.** Secondary and cross-check. Note: glass backboards are low-contrast (use the painted inner rectangle instead), and **fan-shaped backboards are not 72×42 and break the rectangle assumption entirely.** Ask for backboard type at setup.
3. **Ball scale only.** Known ball diameter from detected pixel diameter. Mark all angle metrics low-confidence.

When 1 and 2 are both available, cross-check them and log the disagreement. Persistent disagreement means a bug.

### 4.3 Derived view class

Do not ask the user to declare "side mode" or "frontal mode." **Derive the camera's azimuth from calibration and gate metrics on what that view can support:**

- Azimuth within ~25° of the shot plane → arc, release angle, entry angle, elbow angle valid
- Azimuth within ~25° of head-on → left/right deviation, elbow flare, shoulder-hip alignment valid
- In between → report only what survives (see the open question in §9)

Show the user which metrics this camera position can and cannot produce, before they shoot.

### 4.4 Shot plane

Define the shot plane as the vertical plane containing the release point and the rim center. Project all ball detections into it before fitting.

When only ball-scale calibration is available and the yaw offset `φ` is estimated, apply:
```
tan(θ_true) = tan(θ_measured) · cos(φ)
```
Include a unit test showing the magnitude: a true 50° release from 30° off-axis measures ≈54.0°. Surface this as a warning when confidence is low.

### 4.5 Release instant

The ball becomes a free body the moment it leaves the hand. Find the release frame by fitting the gravity-only model to clean mid-arc frames and walking backwards until the residual jumps. Cross-check against wrist-to-ball separation from pose. **Do not** use a pixel-level "ball no longer touches hand" test; it fails constantly under occlusion.

### 4.6 Trajectory fit — against time, and back-extrapolated

Fit against timestamps, not horizontal displacement:
```
x(t) = x₀ + vx₀·t
y(t) = y₀ + vy₀·t − ½·g·t²
```
Solve for `x₀, y₀, vx₀, vy₀, g` by robust least squares (RANSAC or Huber loss) over the **clean mid-arc** frames, then **back-extrapolate to the release instant.** The first few post-release frames are the noisiest data in the clip — the ball is occluded by hand, arm, and often head — so never derive release angle directly from them.

### 4.7 The gravity constraint — check or solver, never both

Fitted `g` should land near 9.81 m/s².

```
|g_fit − 9.81| / 9.81 ≤ 0.08   → accept
0.08 < error ≤ 0.20            → accept, low confidence
error > 0.20                   → reject, tell the user why
```

- **With rim or backboard calibration:** use this as an independent QC gate. It catches scale errors, bad ellipse fits, and frame-timestamp bugs.
- **With ball-scale calibration only:** invert it — solve for the scale that makes `g` come out to 9.81. This also corrects for the user picking the wrong ball size. But then you no longer have an independent check, so flag it.

Log `g_fit` on every shot and expose it in a debug view. It is your single best signal for pipeline health.

### 4.8 Metrics from the fit

- **Release angle** = `atan2(vy₀, vx₀)` at the back-extrapolated release instant
- **Release height** = `y₀`
- **Entry angle** = `atan(vy(t_rim) / vx)` at the rim's horizontal distance — **from the fitted parabola, never from raw near-rim detections**, which are small, blurred, and worst-case noisy
- **Apex height** = `y` at `t = vy₀/g`
- **Depth at rim** = crossing position relative to rim center (front / center / back)

Do not report entry angle if the arc wasn't tracked past apex.

---

## 5. Metrics

### Tier 1 — trajectory
Release angle, entry angle, release height, apex height, release time (tier A only), depth at rim, left/right deviation (frontal views only), outcome, and a confidence payload: `g_fit`, RMS residual, detection count, calibration path, quality tier.

### Tier 2 — body pose
Elbow angle at set point and at release, knee flexion depth, dip-bottom-to-release timing, shoulder-hip alignment, elbow flare, landing drift, vertical jump.

**2D elbow angle suffers the same perspective error as the ball** — it's only correct when the arm lies roughly in the image plane. Compute it only in side-class views and flag it otherwise. Evaluate 2D vs. 3D Vision body pose empirically in Phase 5; do not commit now. 3D pose is monocular-inferred and unproven at 6–8 m.

**Do not ship wrist-flexion or finger-position metrics.** Vision's hand keypoints are unreliable at shooting distance. If you believe otherwise, prove it with data first.

### Make/miss
**v1 ships manual tagging.** A swipeable strip of auto-clipped shots, ball auto-playing, one tap each. It takes a player 30 seconds per 100 shots and gives you clean ground truth. Build automatic detection in v2, validated against the tagged data you'll have accumulated.

---

## 6. Findings engine

Build as a data-driven rules engine. Rules live in JSON, not Swift.

### The core principle

**Domain knowledge defines the hypothesis space. The player's own data adjudicates.** A rule proposes that some metric might matter. The engine only surfaces the finding if that metric actually separates *this player's* makes from their misses, or shows genuine instability, at a real effect size within the relevant (type, distance) cell. Never assert a universal ideal — good shooters have idiosyncratic mechanics, and telling a 38% shooter to fix their elbow is actively harmful.

### Statistical requirements (non-negotiable)

- **Effect size floor:** Cohen's d ≥ 0.5. Significance alone is not sufficient.
- **Multiple-comparison control:** Benjamini-Hochberg FDR across all metrics tested. Without this you manufacture roughly one false finding per session by chance.
- **Minimum n:** no finding below 30 shots in the cell. Show "collecting baseline" and mean it.
- **Within-cell only:** never compare across shot types or distance buckets.
- **Tier filtering:** tier A and B only, B down-weighted.
- **Max 3 findings shown,** ranked by `effect_size × confidence`. Nobody can work on eight things.

### Finding classes (in order of how much authority they require)

1. **Variance** — "your release angle SD is 3.8° on catch-and-shoot threes." Requires no coaching authority at all.
2. **Make/miss separation** — "misses averaged 43.1° entry vs 47.8° on makes (n=128)." Requires none either.
3. **Within-session drift** — "release angle drops ~3° after rep 60." Log shot index and test for trend. This is one of the most useful things the app can say and it's nearly free.
4. **Trend over time** — session-to-session movement in mean and SD.
5. **Prescription** — drills. *Separate, clearly-labelled layer. Ships after 1–4 are solid.*

### Rule schema

```
id, metric, condition_type (variance | outcome_separation | drift |
trend | absolute_threshold), thresholds, min_n, required_view_class,
required_tier, applies_to_shot_types[], finding_copy_key, drill_ids[],
provenance ("published" | "heuristic"), provenance_note
```

The `provenance` field is mandatory. It lets you see at a glance how much of the engine rests on sourced numbers (entry angle ~43–47°, etc.) versus judgement calls. Emit a debug report summarising the split.

### Evidence requirement

Every finding must cite its own evidence in the UI. Not "your elbow is flaring." Instead: "On your 41 misses from the wing, elbow flare averaged 14.2° vs 6.1° on your 67 makes (last 3 sessions, n=108)." And never claim causation — the copy is "associated with," not "why."

---

## 7. Data model (SwiftData)

```
Player     — id, name, ball size, court type, handedness, created

Session    — id, player, date, location label, source (capture | import),
             achieved format (fps, resolution, stabilization flags),
             calibration method, calibration quality, derived view class,
             backboard type

Shot       — id, session, index_in_session, timestamp,
             shot_type, distance_m, distance_bucket, zone_label,
             outcome (make | miss | untagged),
             trajectory metrics, pose metrics,
             quality_tier, confidence {g_fit, rms, n_detections,
             calibration_path, view_class},
             clip reference (optional)

Baseline   — player, metric, shot_type, distance_bucket,
             mean, sd, n, window (rolling 200 shots), last_computed

Finding    — player, date range, rule_id, effect_size, p_adj, n,
             cell (type + bucket), evidence payload, drills_shown,
             user_marked_working_on
```

**Storage discipline:** 240fps 1080p is roughly 1 GB per five minutes, and this user shoots for an hour. Process incrementally during the session and discard raw footage as you go. Retain metrics plus optionally a trimmed, downscaled 2-second clip per shot. Default to metrics-only. Warn before a session if free space is low.

---

## 8. Phases and gates

**Note the ordering: import before capture.** Import is a file picker; capture is 240fps AVFoundation config, thermal management, and live framing checks. Building import first unblocks the entire analysis pipeline against real footage without writing any capture UI.

### Phase 0 — Test footage (human task, do this first)
Go to a gym with a tripod. Shoot ~200 reps at 240fps from three camera positions (side, 45°, head-on) and three distances (FT, mid, three). Shoot another 50 handheld at 30fps to exercise the import path. Hand-label makes and misses. **Nothing downstream is verifiable without this.**

### Phase 1 — Synthetic geometry harness
Pure Swift package, no UI, no camera. Trajectory simulator (given release point, angle, velocity, virtual camera pose → 2D image points with configurable noise, dropped frames, frame rate) plus the full pipeline from §4, plus tests asserting recovery of known inputs.

**Gate:** perpendicular camera, zero noise → release angle within 0.1°. 30° yaw with realistic pixel noise → within 1.5°. 20% dropped frames → within 2.0°. 30fps simulation → within 3.0°. `g_fit` within 2% throughout. Show me the output before proceeding.

### Phase 2 — Ball detection
Create ML object detector, exported to Core ML. Evaluate Vision's built-in trajectory detection as a zero-model baseline first — it may suffice. Handle the head-vs-ball false positive explicitly.

**Gate:** on the Phase 0 footage, recall ≥90% on the arc below apex and ≥75% in the final third approaching the rim (the ball is small and blurred up there — separate targets are realistic, a single 90% number is not). Zero non-ball detections surviving RANSAC.

### Phase 3 — Import path, calibration, analysis
File picker, quality tiering, rim-anchored stabilization, rim-ellipse calibration with manual fallback, full analysis, results view with the arc traced over the video.

**Gate:** real 240fps footage → `g_fit` within 8% of 9.81. Real 30fps handheld → correctly tiered B or C, and B results within 3° of the 240fps result on the same shot filmed simultaneously. **If you can't hit this, calibration is wrong. Do not move on.** This gate is the whole de-risking of the project.

### Phase 4 — Capture path
120/240fps capture, framing guide, live rim-drift stability check (the rim is fixed; its detected drift *is* your camera-motion metric — no new machinery needed), thermal warnings.

### Phase 5 — Pose metrics
**Gate:** elbow angle at release, on 20 real frames, agrees with manual protractor measurement within 5°. Evaluate 2D and 3D pose, pick by this gate.

### Phase 6 — Tagging, persistence, history, trends
Swift Charts. Show SD as a band, not just a mean line — variance is the thesis.

### Phase 7 — Findings engine
**Gate:** fed synthetic shot histories with a deliberately injected pattern, it finds the pattern. Fed random-noise histories, it produces **zero** findings. The second half matters more than the first.

### Phase 8 — Prescription layer, onboarding, TestFlight

### Cold-start requirement
The first session must deliver something satisfying at n=1, before any baseline exists. A traced arc overlaid on the player's own video with release and entry angles labelled does this. A "collecting baseline" spinner does not.

---

## 9. Open questions — answer or test before building

1. **Can one 45° camera give full 3D?** Ball pixel diameter yields depth; depth plus image position yields a 3D trajectory from a single view, which would collapse the side/frontal split and give arc *and* left-right deviation from one setup. Precision depends on how many pixels the ball spans at range. **Test this in the Phase 1 simulator before designing around it** — do not assume either way.
2. XcodeGen/Tuist vs. Xcode-managed project? Recommend the former for AI-assisted editing (`.pbxproj` merge conflicts are miserable), confirm with me.
3. iOS 26 minimum — confirm against current install base.
4. Ball detection: Create ML from scratch on Phase 0 footage, or fine-tune a permissively licensed pretrained detector? Report options with licences.
