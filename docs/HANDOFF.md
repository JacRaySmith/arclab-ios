# START HERE — state on 2026-09-24, written for the next agent

**Read in this order:** `CLAUDE.md` → this section → `docs/PIPELINE.md` (how to measure anything) →
`docs/EXPERIMENTS.md` (12 rows, every decision traceable to a p-value) → `docs/BENCH-RESULTS-2026-09-24.md`
and `docs/BENCH-RESULTS-azimuth-2026-09-24.md` (the tables) → `docs/BIG-CHANGES.md` (the ranked backlog).
The 2026-09-19 section below is still accurate for 1.4's features; this section supersedes it for measurement.

## The one thing that changed: there is now a measurement loop

Do not change analysis behaviour without running it. Three commands:

```
TrajectoryProbe session <clip> --rim <rim.json> --time-scale 4 --no-pose --spot <name> --dump-windows <dir>
ShotBench run <dir> --variant <name> --json out.json      # replays the cache, no video, seconds
ShotBench compare base.json cand.json                      # exact McNemar on flipped verdicts
```

The cache for the three 2026-09-13 clips is **not in the repo** (reproducible, and /private/tmp is purged
after a few days). Rebuild it with the first command; it takes about 2.5 minutes per clip. Variants are
declarative entries in `ShotBenchKit/Variants.swift` — adding an experiment is adding one entry.

**Read acceptance rate with its guards, never alone.** Every scorecard also carries median |g error|, fit
residual, within-block release-height and release-speed spread, and — since the corpus was labelled —
precision and recall. A variant that accepts more while worsening the others is a regression.

## What the corpus says (98 windows, all labelled by eye in `docs/footage-2026-09-13/window_labels.json`)

| | baseline | best kept (`autoFoundTrace`) |
|---|---|---|
| overall recall | 43.2 % | 56.8 % |
| threes | 4.8 % | 52.4 % |
| free throws | 39.3 % | 39.3 % |
| precision | 100 % | 100 % |

**Precision has been 100 % for every variant on every clip.** Not one accepted window was a non-shot. The
app's whole problem is recall — it throws real shots away — and nothing you do may cost that precision.

## Findings that should shape what you do next

1. **A hand-traced rim silently sets the calibration's "up".** `IMG_1766`'s trace was 15.02° from gravity;
   the auto-found trace was 0.538°. A tilt ε costs ≈ `L·sin ε` of release height — zero at the rim, 1.7 m at
   a three — so the rim reprojects perfectly and only distant shots are refused. Shipped in the app: gravity
   sampled during recording, `RimGravity.arbitrate` (3° margin, a stated convention), `RimTrustCard`, and
   `rim.calibrated` logging both candidates' angles.
2. **`IMG_1765` contains two shooting positions, not one** (13 shots near 241.3°, 15 near 293.7°). Its
   "within-block spread" was measuring a block that is not one block: 0.465 m pooled, **0.190 m** within a
   single position. Any per-clip grouping in the bench inherits this bug.
3. **Recall is a track-quality problem, not a geometry one.** The refused labelled shots have degenerate
   plane solves — ambiguity ratio 0.82–0.95, solve residual 0.21 m against 0.015 m for accepted, and implied
   ball size drifting 58 % along a single track. Forcing a correct azimuth rescues none of them.
   **This is the highest-value open lead.**
4. **Azimuth is not the lever.** Measured: 0.025 m of release height per degree, and within-block azimuth
   spread is 1.2–2.5°, so it explains 2–4 % of the variance. Pooling it made things worse (free-throw recall
   39.3 % → 14.3 %, p = 0.0078). Nothing shipped; the apparatus is kept.
5. **Logged, not acted on:** `solveByFixedGravity` reaches 0.2–2 % g-error at two azimuths 52° apart, which
   weakens "g is the check" in that path — a `CLAUDE.md` rule concern worth a decision. Also the plausibility
   band admits a 3.19 m release height.

## Work in flight, and its state

- **Court-anchored pose** (`CourtCalibration.swift`, defaulted off, merged): built but **not validated** —
  its agent stalled twice and the work was rescued. Read `docs/research/court-anchored-pose-2026-09-24.md`
  before touching it; it names the three things that were never done.
- **Multi-view 3-D** (`MultiViewFit.swift`, `MultiViewSync.swift`, merged, tested synthetically only):
  `docs/DESIGN-MULTIVIEW-2026-09-24.md` has the sweeps. Cameras want **45–90° bearing separation**; sync is
  recovered from the ball itself to 3–4 ms against an ~8 ms tolerance, so the two phones need no synchronised
  start. Awaiting footage.

## Blocked on the user

- **Footage:** the second-angle clips for multi-view; the 30–45° off-line clip; the close-up form clip; the
  footwork request in `docs/DESIGN-FOOTWORK-2026-09-15.md` §6; the behind clip with tape for spin.
- **The phone:** 1.4 (build 3) is installed and signed, but iOS needs the developer certificate trusted under
  Settings → General → VPN & Device Management. **Free-provisioning profiles last 7 days**, so a build
  installed on 2026-09-24 stops launching around 2026-10-01 and must be reinstalled.
- **Nothing on the phone has exercised the new rim logging yet**, so whether the user's own traces carry the
  tilt is still unanswered. It is answered the moment one session runs on 1.4 and the log is pulled.

## Traps this session hit, so you do not

- `build-app.sh` (in the scratchpad) once **did not run `xcodegen generate`**, so a newly added file was never
  compiled and the build still printed SUCCEEDED. It also built Debug. And its verdict line could be dropped
  by `sort -u | tail`, and it exited 0 on a signing failure. All fixed — but the lesson generalises: **a gate
  that cannot report its own failure is worse than no gate.** Check that a gate would catch its own absence.
- Worktree agents stall. Tell them to **commit early**; rescuing 1 548 uncommitted lines is luck, not process.
- Several agents forked before others merged and reported different test baselines. Always merge `main` into
  the worktree before judging a count. Current: **426 ShotGeometryTests + 27 FormEvalKitTests**, `GATE: PASS`.

---

# START HERE — state on 2026-09-19 (afternoon PT): 1.4 merged on main

**1.4 = 1.3.1 (morning, below) + four more Opus worktree agents merged by hand.** Entry points: You → Games, You → Your body
(jump test), Review → Sessions and Film review, Learn → Ball handling / Handling under pressure / Practice against games,
the new IQ tab. What landed:
- **Fixes:** the 3-D body went black during playback because `SCNView.rendersContinuously` was false while a Timer moved
  node transforms outside SceneKit's change tracking (`BodyPlayerView`, `FormModelView`); now driven by `isAnimating`,
  `body.player.frame` timings logged. Sessions: `SessionsListView` → `SavedSessionView` with an explicit delete and an
  impact dialog (which practice blocks become unscored, whether the plan loses its baseline, which files go or stay).
- **Practice→game:** curriculum modules `ballHandling` (5 drills, each ends in a measurable shot) and
  `handlingUnderPressure` (4); `NextBlock.GameLikeVariant` (random-spot B, decision-called C, fatigued A, contested C) offered
  as alternatives after a drill passes / retention holds, never scored against the plan's baseline; `GameLog` + practice-vs-
  game card with the 20-shot floor and the Wald detectable difference at the user's n; evidence in
  `docs/research/ball-handling-and-transfer-2026-09-19.md` (Kozar 1995 effect size UNVERIFIED).
- **Jump test** (`JumpTest.swift` + `App/Sources/Jump`): flight time from the lower ankle leaving/returning to its floor
  baseline at 240 fps (σ_h ≈ 7 mm on a 0.5 s flight), hip-rise cross-check scaled by stated height; rim ruler refused;
  **never run on a real jump yet** — first thing to check on the phone. Film review v1 (`App/Sources/Film`): manual
  possession tagging with rim-scanner shot candidates when the rim is marked; nothing auto-tagged;
  `docs/DESIGN-FILM-REVIEW-2026-09-19.md` says what auto-tagging would need.
- **IQ tab** (`App/Sources/IQ`): 24 first-person SceneKit scenarios with a freeze and decision-time capture, 59-question
  quiz, progress with n floors (10 plays per principle), no "IQ score". Verified in the Simulator only.

**Next:** 1. On the phone: one guided block (capture events, overlay), one 3-D playback, one jump test, one IQ session — pull
the log. 2. The 1.3.1 list below (three-point acceptance B1, body-pose cost B5). 3. Backlog in docs/BIG-CHANGES.md.

---

# START HERE — state on 2026-09-19 (morning PT), written for the next agent

**1.3.1 shipped today** (main, pushed; phone has it; bundle version now 1.3.1 (2) so `app.launch` identifies
the build). Read `docs/BIG-CHANGES.md` first — it is the ranked list of structural changes with log evidence
and gates (B1 three-point acceptance 33 % is the biggest measurement problem; B5 body pose is 12 s/shot).

What 1.3.1 changed (three Opus agents in worktrees, merged by hand, all gates re-run: 254 package tests,
GeometryHarness GATE PASS, app Release build):
- **Capture** (`CaptureView`, `CaptureController`, `GuidedCheckpoint.swift`, `TodayView`): the landscape overlay
  bug had four causes (safe-area vs full-screen geometry, sensor vs rotated aspect, refused
  `requestGeometryUpdate` never retried, rotation coordinator bound to a dead layer) — the overlay is now placed
  by `layerRectConverted(fromMetadataOutputRect:)`. The black screen on 09-18 left no crash report; the session
  had no runtime-error/interruption observers and a teardown use-after-free on the sample-buffer delegate. Both
  fixed and logged (`capture.*` events, `previousRunEndedCleanly` on `app.launch`). A guided session now
  checkpoints to disk after record / scan / each shot and Today offers "Resume the session you were in".
  Photos-imported clips are not checkpointed (temp copy).
- **Practice day as a sequence** (`NextBlock.swift` in ShotGeometry + `PracticeStore`, `PracticeNextCard`):
  after every scored block the app proposes the next one with the number, its n and the grade; day cap at 8
  blocks / 100 shots (stated as convention); 24 table tests. The user's 09-18 case (plan's baseline session
  deleted) is handled with a stated reason.
- **Plain-language drills** (`Curriculum.swift`, `FixLibrary.swift`, `DrillCard`, `DrillDirectory`, Learn/Plan/
  block-card views): Setup / Do this / What the app watches / Done when / Why (grade), precise version behind
  `detail`; `DrillCopyTests` fails on jargon so it cannot regress.

**Next, in order:** 1. Ask the user to run one guided block on 1.3.1 and pull the log: confirm `capture.configured`
/ `capture.running` appear, the overlay is right in both landscape orientations, and `previousRunEndedCleanly`
is true. 2. B1 in BIG-CHANGES (three-point acceptance) — needs the 30–45° off-line clip. 3. B5 (body pose only
over the frames the coachable measures use, deferred behind ball metrics). 4. The rest of the open items below.

Build/phone/log commands, honest limits and the 1.3 open items are unchanged below.

---

# START HERE — state on 2026-09-16 (evening PT), written for the next agent

**Read in this order:** CLAUDE.md (rules, never modified) → this section → docs/PLAN-1.3-2026-09-16.md and
docs/IMPROVEMENTS-2026-09-16.md (§10 roadmap: 1.2 UI done, 1.3 biometrics done, 1.4 coaching/biometrics next) →
docs/PHASE2-PREP.md (every measured change, newest at the bottom) → docs/research/ (graded evidence).

**Where things are**
- Code: private GitHub repo https://github.com/JacRaySmith/arclab-ios, branch `main`, tag `v1.3`; the 1.3 phone build is
  the release asset `ArcLab-1.3-iphoneos.zip`. Tree is clean and committed. Footage and build products are git-ignored.
- Phone: iPhone 14 Pro, ArcLab 1.3 installed (Release, Xcode 27.0, team KN6TTT6CJ7). devicectl id
  18543A40-891D-57BE-BBE9-7A8CD5DEDF28 (list shows the UDID 00008120-… now; the old id still works). The phone must be
  unlocked and plugged in for install/launch (error 4016 otherwise).
- Build/gate commands: ShotGeometry `swift test -Xswiftc -O --scratch-path <scratchpad>/sgbuild` (Xcode 27 fails to
  codesign a test bundle built inside the iCloud-synced Desktop tree; see README); ShotVideo `swift build -c release`;
  app `cd App && xcodegen generate && xcodebuild -project ArcLab.xcodeproj -scheme ArcLab -configuration Release
  -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath <one shared path> build`, then
  `xcrun devicectl device install app --device <id> <ArcLab.app>` and `process launch … com.arclab.app`. Phase-1 gate:
  `swift run -c release GeometryHarness`. Foot model ships compiled: Packages/ShotVideo/Sources/ShotVideo/Resources/
  ArcLabFootModel.mlmodelc (source in Packages/ShotVideo/Models; recompile with `xcrun coremlc compile`).
- The user's data: the app logs everything to Documents/ArcLab/logs/activity-<day>.jsonl (pull with devicectl copy from,
  domain appDataContainer com.arclab.app); sessions in Library/Application Support/ArcLab/sessions.json; BodyShot exports
  in Documents/ArcLab/body. Scratchpad copies are session-local and may be gone.

**This Mac has 8 GB RAM.** Agents each creating a derived-data folder took the scratchpad to 36 GB and the system killed
background jobs. Use one shared derived-data path, delete it after the gate, no polling watchers, at most 2–3 Opus agents.

**What 1.3 measured (honest limits to carry forward)**
- The "110 phone shots" are 37 unique free throws exported three times (FormEval deduplicates on the 2-D input).
- Coachable now (ICC ≥ 0.75 across repeated free throws): jump height 0.92, head horizontal travel 0.86. NOT coachable
  yet at 7 m: knee minimum (ICC −0.26) and elbow angle at release (SDC 42°). Do not surface those as coaching numbers.
- Hand plates are fitted only where both knuckles were seen; at the release instant the ball hides the hand on ~83 % of
  frames. The close-up form clip is the path for hands.
- Foot triangles: detection 100 % at set/dip/release on the 240 fps clip; foot angle at set repeats to ~2° (±1.2° per
  shot); the triangle's width prior is ~40 % too wide vs the toe-tip landmarks (deliberately not tuned); foot angle is
  measured against the camera→rim bearing (38° parallax here) — wire RimCalibration's rim position into
  FootTriangleOptions to make it a foot-to-rim angle. Halpe-26 licence is research-only (docs/DECISIONS.md).
- The fitted neck→nose length wanders 11.6 % frame to frame: the head is the least-constrained joint.

**Open items, in the order I would take them**
1. Phone benchmark of the foot model (read `body.feet` in the activity log after the user runs a session; FP32 may refuse
   the Neural Engine — FP16 was rejected on accuracy, so if it is slow, look at compute units or a smaller input).
2. Rim-bearing parallax fix for the foot angle (above). 3. Merge the two body-pose passes (~2 s/window at 240 fps) and
   fix the one-pixel tile-origin bug in CoreMLBallDetector — both need a re-baseline with FormEval, not bit parity.
4. 1.4 coaching: bandwidth per-shot cues on the coachable measures only; weekly review; drill picker; the footwork
   footage request in docs/DESIGN-FOOTWORK-2026-09-16.md §6 (still owed by the user), the 30–45° off-line clip, the
   close form clip, the behind clip with tape (spin). 5. Label the 20-frame sheet (scratchpad/labels, may be gone —
   regenerate with the FormEval label script) to turn the harness into ground truth.
6. Small UI leftovers: Review/Learn tabs keep old inline titles; Today card does not refresh on an edited session;
   verify the ring ellipse draws on the inline rim thumbnail on the phone.

**User preferences that matter:** never fabricate a number (nil with a reason), grade coaching claims A–D, put the
build on the phone at every clean point, do not ask permission for routine work, be token-efficient with Opus agents,
keep the GitHub repo private.

---

# Handoff — 2026-09-14 (pytrack self-correcting loop)

## App target (added 2026-09-14)
- `App/project.yml` (XcodeGen, per `docs/DECISIONS.md` §9.2) → `App/ArcLab.xcodeproj` (git-ignored; regenerate with
  `cd App && xcodegen generate`). Bundle id `com.arclab.app`, iOS 26.0, Swift 6 language mode, strict concurrency.
  Depends on the local packages `ShotGeometry` and `ShotVideo` (library product only; `TrajectoryProbe` stays macOS tooling).
- `App/Sources/`: `ArcLabApp` (entry), `ContentView` (Import clip → probe → "Find trajectories in first 10 s"),
  `AnalysisModel` (`@Observable`; decoding in detached tasks off the main actor, progress via the tracker callback),
  `ClipImporter` (`PhotosPicker` item → PhotoKit *original* video resource so slo-mo keeps its true frame rate;
  falls back to the `Transferable` file copy and says so). Unmeasurable values render as "not measured".
- Build/run commands: `App/README.md`. Signing: `DEVELOPMENT_TEAM` must be set before running on the phone.
- Verified on 2026-09-14: `xcodegen generate` OK; `ShotVideo` cross-compiles unchanged for `arm64-apple-ios26.0-simulator`
  (SwiftPM `--triple`), app sources typecheck against it in Swift 6 mode; `Packages/ShotVideo` `swift build -c release` (macOS) OK.
  The iOS 26.5 platform component was missing from Xcode 26.6 and was installed with `xcodebuild -downloadPlatform iOS`
  (8.5 GB); after that `xcodebuild -project App/ArcLab.xcodeproj -scheme ArcLab -destination 'generic/platform=iOS Simulator' build`
  → **BUILD SUCCEEDED**. Not yet run on a simulator or the phone; no clip has been imported through the app.

## Added 2026-09-14
- `tools/pytrack/` (Python, separate from the app): `track.py` (OpenCV ball + MediaPipe Pose joints), `grader.py`
  (pass/fail with error codes: frame drops, ball coverage/jumps/size/projected-parabola physics, pose coverage/teleports/swaps),
  `run_loop.py` (track → grade → tweak → escalate → human-intervention stop; every iteration logged under `runs/`).
  Environment: `.venv-legacy` (Python 3.12, mediapipe 0.10.14; mediapipe 1.0.1 aborts in Metal on this Mac).
- Status: loop passes on all three hand-picked free-throw windows. `session.py` runs it over whole clips; `report.py`
  produces the block report. Free throws: 6 of 31 windows pass the 8 % gravity gate → release 46.6 ± 3.6°, h 2.43 ± 0.26 m,
  v 7.23 ± 0.11 m/s, entry 38.4 ± 3.4°, depth 17.7 ± 4.7 cm. Elbow and three-point blocks in progress (`tools/pytrack/shots/`).
- Swift additions today: `AnalysisOptions.azimuthTimeRange`, `FlightWindowOptions.releaseTimeOverride`, `analyze --track-json/--flight-range/--release-time`.
- Next real step: train a ball detector from the passing tracks (thousands of auto-labelled frames) to replace the background-difference blobs.
- Findings that transfer to the Swift pipeline: seed flights by "leaves the body box", not by "rises"; key re-entry off the
  top-edge exit; a projected parabola (shared perspective denominator) is the right image-space model for oblique views;
  Hough circles are unusable at night (lights); template matching at the parabola prediction recovers release-adjacent frames.

# Handoff — 2026-09-13 (Phase 2 prep; Phase 0 filming today)

## Added 2026-09-13
- `docs/PHASE0-FILMING-PROTOCOL.md` v1: what to film today and what to measure.
- `Packages/ShotVideo` + `docs/PHASE2-PREP.md`: frame reader (true PTS), Vision trajectory probe, synthetic clip
  renderer, detector scorer, end-to-end synthetic baseline. Vision at 240 fps: ~40 % frame recall, ½–1 frame timing lag.
- `docs/research/`: coaching evidence (rules with provenance), competitive landscape + presentation patterns,
  detection/capture tech (licences, slo-mo import gotchas, flicker, pose accuracy). Agent-written; URLs cited, UNVERIFIED marked.
- Fixed inverted advice in `RimCalibration` messages: a thin rim ellipse means the camera is near rim height → lower it / move closer.
- `docs/DESIGN-MEMO-2026-09-13.md` (3 parts): product reframe, ten design moves, further innovations, simulation numbers
  (speed dominates depth near 50°; halving speed SD ≈ +13 makes/100; cue trials need multi-session sets), data model, rules v1.
- `ShotGeometry/MakeModel.swift`: clean-pass geometry, `SoftMakeModel` (placeholder until fitted from tags), `ReleaseSensitivity`
  (turnover angle), `DepthVarianceAttribution`. Tests reproduce the textbook worked shooter. `swift test` 14/14.
- Evening: first real footage analysed (see `docs/PHASE2-PREP.md` "Real footage"). Clips are 120 fps slo-mo with baked 30 fps
  timestamps (time scale 4). Hand-picked free throws fit with g within 1.5–14 %; the automated batch is not yet reliable
  (segmentation, detector drift, azimuth consistency). Review videos: `~/Desktop/arclab-review/`. Rim fit: `docs/footage-2026-09-13/rim_1765.json`.
- Pipeline changes today: gap bridging in `FlightWindowFinder` (both directions), `ShotPlaneSolver.solveByFixedGravity`,
  `AnalysisOptions.knownReleaseDistance / azimuthByFixedGravity / fixedAzimuth`, `MakeModel.swift`; ShotVideo gained
  `BallDetector`, `Overlay`, `OverlayVideo`, and the `analyze` / `session` commands.
- Detector trained (Create ML, transfer learning, 1,544 auto-labelled tiles): held-out mAP@IoU50 0.88 (272 tiles); model
  `~/Desktop/BallDetector.mlmodel` (6.7 MB); trainer `tools/createml/train_ball_detector.swift`; integration into ShotVideo in progress.
- Swift pose stage (`PoseTracker`, `ReleaseFromPose`, `analyze --pose`): reproduces the pytrack release rule within one file frame
  when given the same ball track; found that Vision body pose returns nothing for buffers carrying the decoder's CVCleanAperture
  attachment (PoseTracker strips it). Remaining error is the classical ball detector on the release side.
- Three-point block: rim ellipse normal for IMG_1766 had a spurious 16° roll; `analyze --level-pitch` (zero roll, given pitch)
  restores plausible geometry; tracker now accepts weak candidates near an established parabola so the descent is tracked to the rim.
- Still uncommitted. Still awaiting: XcodeGen confirmation, court type, ball size, backboard type, second phone availability.

# Handoff — 2026-09-12 (end of Phase 1)

## Completed
- Repo `projects/arclab-ios` created (git initialised, everything staged, **nothing committed**).
- `Packages/ShotGeometry`: pure Swift (Foundation + simd) geometry/physics layer — rim-ellipse
  calibration, shot-plane azimuth solve, robust time-parabola fit with free g, local-gravity release
  detection with sub-frame refinement, metrics + confidence payload, ball-scale fallback, simulator.
- Verification: `swift test` 10/10, `swift run GeometryChecks` 95/95,
  `swift run -c release GeometryHarness` → **Phase 1 gate PASS** (table in `docs/PHASE1-REPORT.md`).
- Docs: `docs/BRIEF.md` (the spec), `docs/DECISIONS.md`, `docs/PHASE1-REPORT.md`,
  `docs/reference/` (textbook digests + SDK/licence research), `CLAUDE.md`, `README.md`.
- Toolchain: Xcode 26.6 installed and licensed, iOS 26.5 SDK, iPhone 14 Pro paired. XcodeGen not installed.

## Decisions made
- iOS 26.0 minimum (86% install base).
- XcodeGen over Tuist — **awaiting user confirmation**.
- Ultralytics YOLO and YOLO-NAS excluded (AGPL / non-commercial). Evaluate Vision
  `DetectTrajectoriesRequest` first, Create ML second; Apache-2.0 detectors (RT-DETR, RF-DETR, YOLOX) as fallback.
- Open question 1: single 45° camera gives left/right at the rim to ~2–5 cm (classes only), not arc.
  Diameter profile is used as a shape-only cue in the azimuth solve.
- Textbook median walk-back replaced by the local gravity test (see `docs/DECISIONS.md`).
- Unobserved release → `release = nil` with a reason (never extrapolated).
- Rim edge (inner 0.4572 m vs outer ≈0.489 m) is a Phase 3 decision; wrong choice = 7% scale error caught by the g-test.

## Known limits
- 3 px centroid noise breaks the 2°/2% targets → Phase 2 detector must deliver ≤ 2 px.
- At 30 fps, ~2% of draws exceed the 2% g line (precision floor, product gate is 8%).
- Backboard calibration, frontal-view lateral deviation, VFR/timestamp-jitter gate rows: not built.

## Exact next steps
1. **User (Phase 0):** film ~200 reps at 240 fps (side / 45° / head-on × FT / mid / three) on a
   tripod, plus ~50 handheld 30 fps; hand-label makes/misses. Nothing in Phase 2+ is verifiable without it.
2. **User:** confirm XcodeGen + iOS 26 minimum; decide whether to commit the staged work.
3. **Phase 2 (needs footage):** build a frame reader (`AVAssetReaderOutput.Provider`, real PTS, not
   `nominalFrameRate`); run Vision `DetectTrajectoriesRequest` on Phase 0 clips as the zero-model
   baseline; measure recall below apex (≥90%) and in the final third (≥75%), head-vs-ball false positives.
   If insufficient, label and train a Create ML detector. Report centroid noise in px — it sets the pipeline's sensitivity.
4. **Phase 3:** `brew install xcodegen`, create the app target depending on `ShotGeometry`, file
   import, rim detection → `RimCalibrator`, `ShotAnalyzer` on real tracks. Gate: g_fit within 8% on 240 fps footage.

---

# App analysis flow (added 2026-09-14, later)

The app scaffold is now a working single-shot analysis flow: **import → mark the rim → analyse one
window → arc + numbers + rim map**. Brief §8's cold-start requirement ("a traced arc overlaid on the
player's own video with release and entry angles labelled") is what the results screen draws; the rim
map is the design memo's §2.1 object, drawn descriptively (no target bands).

## Screens (all in `App/Sources`, SwiftUI, Swift 6 strict concurrency)
- `ContentView` — home, five numbered steps: Clip · Timing and lens · Rim · Shot · Result, plus
  **Tools → Probe & Vision tracks** (the previous probe/track screen, kept reachable; each listed track
  has a "Use as the shot window" button that sets the window from the track's time span).
- `RimMarkingView` — one decoded frame at a scrubbed file time, tap ≥ 6 points inside the ring, a 6×
  loupe with 1 px nudges for the last point, **Calibrate** → `RimCalibrator.calibrate(boundaryPoints:
  intrinsics:options:)`. Shows camera→rim, rim height above camera, axis ratio, ellipse residual, pose
  ambiguity, pitch/roll and every `RimCalibration.warnings` entry, and draws the fitted ellipse back on
  the frame. Points are stored in decoded-image pixels — the same coordinates Vision reports.
- `ShotPickerView` — scrub, window start + length (default 7 s of *file* time, with the real-time
  equivalent shown), **Analyze** off the main actor with a progress line per stage.
- `ResultsView` — release frame + overlay (white detections, white rings on the flight window, red
  double ring at release, orange reprojected parabola, green rim points and reprojected rim centre),
  then `g_fit` with verdict and the `GravityGate.explain` line, release angle/height/speed/distance,
  entry angle, apex, depth past front rim, a "how well it was seen" block (view class and angle, RMS px,
  inliers, flight span, samples after apex, azimuth σ, release observed, calibration path), the warnings
  list, and a provenance block ("where the numbers came from": which detector, how many samples, the
  time scale, the real frame rate).
- `RimMapView` — ring to scale (45.72 cm inside), front rim at the bottom, dashed swish zone of radius
  (rim − ball)/2 = 10.9 cm, the ball drawn to scale at the crossing from `depthPastFrontRim`. Left/right
  is **not** drawn: side views get a dashed front/back-only strip and the text "not measured from this
  camera angle"; oblique and frontal get their own reason (`lateralDeviation` is still nil in the pipeline).

## Pipeline wiring (`ShotAnalysisRunner`, off the main actor)
`TrajectoryTracker.run` over the window → best ball-sized sample per frame index (diameter 10–140 px,
highest confidence wins) → those positions as `seed` for `BallDetector.run(url:start:end:seed:fps:
options:)` with `expectedDiameterPx = 1.6 × median seed radius` → `ImageSample(t: pts / timeScale, …)` →
`ShotAnalyzer.analyze(track:calibration:intrinsics:options:)` with `azimuthByFixedGravity = true`.
Exactly `TrajectoryProbe analyze --classical --fixed-g-azimuth`. If the classical detector returns < 12
detections the Vision samples are used instead **and the result says so**; if Vision finds no ball-sized
track the run stops with that sentence rather than analysing nothing. Analyzer errors are shown verbatim.

## Slow-motion factor (the 2026-09-13 trap, now surfaced in the UI)
`VideoProbeResult.sloMoStretch` is `1.00×` for those clips: they are 120 fps exported with 30 fps
timestamps, so nothing in the file says it plays 4× slow. The app therefore asks: a "This clip is slow
motion" switch that sets the factor to the edit-list stretch when there is one and otherwise to **4**
when the measured rate is 28–32 fps, with the number editable, and the footer explaining that a wrong
factor shows up as `g_fit` ≈ 4× or ¼ of 9.81. hFOV is editable and defaults to **48°** (1080p120 slo-mo
on this phone). Changing either invalidates the current result, so numbers can never outlive their inputs.

## Verified on 2026-09-14
- `cd App && xcodegen generate`; `xcodebuild -project App/ArcLab.xcodeproj -scheme ArcLab -destination
  'generic/platform=iOS Simulator' build` → **BUILD SUCCEEDED**, clean build, no warnings from `App/Sources`.
- Built for `platform=iOS Simulator,name=iPhone 17 Pro`, installed and launched on the booted simulator;
  home screen renders (`/Users/smyth/Desktop/arclab-review/app_home.png`).
- `IMG_1765.mov` was added to the simulator's Photos library (`xcrun simctl addmedia`, several minutes for 1.6 GB; a 23 MB clip takes ~1 min).
- The runner was compiled verbatim into a small macOS harness and run on `freethrow_t313.mov` with
  `footage/2026-09-13/rim_1765.json`, factor 4, hFOV 48: rim 9.36 m, axis ratio 0.263;
  **g_fit 9.47 (+3.5 %, accept)**, rms 12.8 px, 70/72 inliers, view 15° (side), entry **40.0°**,
  depth **23.8 cm**, release `nil` with "release instant not in the footage (track starts in flight)";
  76 classical detections from 112 Vision seeds; 191 parabola points reproject in front of the camera;
  release frame at 1.733 s file time. That exercises every call the app makes and the overlay math, in 11 s.

## Not verified
- No screen past the home screen has been *seen* running: driving the simulator's UI needs accessibility
  permission for AppleScript, which this session does not have, and `simctl` cannot tap. The rim,
  shot-picker and results screens are verified by compilation and by the pipeline harness above, not visually.
- Nothing has run on the paired iPhone (`DEVELOPMENT_TEAM` is still unset).
- Analysis speed on device is unmeasured. Note that `TrajectoryTracker.run` calls `VideoReader.probe()`,
  which decodes the **whole file** before the windowed pass — on a 2-minute 1.6 GB clip that dominates the
  wait, and the UI can only say "decoding the clip once to measure its true frame rate…" while it happens.
  Caching the probe per clip (it is already computed at import) is the obvious next fix and needs a
  `ShotVideo` change.
- `lateralDeviation` is still nil everywhere, so the rim map is one-dimensional for now, by design.

---

# App session mode (added 2026-09-14, later still)

"Analyse one shot" became "analyse a session": one pass over the clip finds every shot, each window
goes through the same analyzer, and the block is summarised, mapped and coached. Nothing is persisted
— no SwiftData yet, so the session lives only while the app is open. The single-shot flow is untouched
and still works (`ContentView` steps 5 and 6).

## What was added (all in `App/Sources`)
- `SessionScanner.swift` — the whole-clip pass. `TrajectoryTracker.run` over chunks of 60 s of file
  time (it holds one stateful Vision request, so one instance per chunk) with a 3 s overlap so a
  flight across a boundary is still seen whole, every Vision sample dropped into a frame-indexed slot,
  then `tools/pytrack/session.py` `find_arrivals` ported frame for frame: a ball-sized candidate within
  **2.5 diameters** of the rim centre, **moving down** (something near it and above it in the previous
  three frames), **preceded within 1.5 s real** by ≥ 6 ball-sized candidates in the upper 40 % of the
  frame, **one arrival per 3 s real**. Window = `[arrival − (1.3 + 0.35) s real, arrival + 0.4 s real]`
  in file time (8.2 s at a 4× factor). Progress is reported as a fraction plus a message and
  `Task.checkCancellation()` makes the scan stoppable. The rim centre is the fitted ellipse's centre
  (which on `rim_1765.json` is 0.0 px from the mean of the marked points) and the ball size is derived
  from the rim ellipse: `2·semiMajor · (0.2385 / rimDiameterUsed)` = **60 px** on that clip.
- `ShotAnalysisRunner.swift` — gained the **pose stage**. `PoseTracker.run` over the window on
  **every 2nd frame** (halves the cost of the slowest stage; the release rule only fires on a detection
  that has a pose frame within 0.75 of the median detection gap, so on an odd frame it waits for the
  next even one — ≤ 1 file frame, ≈ 8 ms of real time at 120 fps, against the ±37 ms the rule was
  measured to). `ReleaseFromPose.estimate` → `AnalysisOptions.windowOptions.releaseTimeOverride`
  (real seconds), `PoseMetrics2D.angles` for elbow at release / elbow most extended near release /
  knee minimum, plus **dip → release** computed here from the camera-side wrist (the lowest wrist in
  the 1.2 s real before release, the same rule as `report.py pose_metrics`) because `PoseMetrics2D`
  does not compute it. Everything lands in `ShotPoseResult`, carried on `ShotRunResult`, and the
  analyzer's view-class sentence is attached after the fit: 2-D angles are only meaningful in a
  near-side view and never travel without that warning.
- `BlockSummary.swift` — `RimOutcome.infer` (report.py's `infer_outcome`, ported: tracked below the
  ring inside its width → make, tracked leaving → miss, vanished at the rim → the last four points
  decide and the label is marked `inferred-weak`, anything else **unknown**), `ShotAcceptance`
  (report.py's `accepted`: gravity within 8 % **and** release height 1.6–3.3 m, speed 4.5–11 m/s,
  depth −0.6…1.0 m — the plausibility half exists because the 2026-09-13 three-point block produced
  gravity-passing shots with a 1.3 m release height), `Stats`/`BlockStat` (mean, sample SD, n),
  `BlockRow` and `BlockSummary`.
- `SessionCoaching.swift` — the coaching card. Three parts, each rule-driven: **what this session
  says** (≤ 3 sentences, ranked speed → miss-depth pattern → entry angle → pose, every one with ± and
  n, "associated with" never "because"), **what to work on** (exactly one item and only at
  n ≥ 30 accepted shots per brief §6; below that a literal "Collecting baseline: N of 30" with what
  arrives at 30; at ≥ 30 the rules are flat-arc `mean_lt 40` from the Ch 15 digest, release-speed
  spread scored in centimetres of depth, and within-session drift, and "nothing fired" is a permitted
  answer), and **how to film next time** (ball's top edge reached the frame top → a metre of sky;
  outcomes mostly unknown → say make/miss; rim axis ratio < 0.2 → lower the tripod).
- `SessionModel.swift` / `SessionView.swift` / `SessionRimMapView.swift` / `ShotStripChartView.swift` —
  in-memory state and the screen: scan controls with progress and cancel, the block summary (counts,
  then mean ± SD and n for release angle/height/speed, entry angle, depth, g_fit, and the pose angles
  in a disclosure group), a rim map with one dot per **accepted** shot coloured by inferred outcome
  (side views put every dot on the centre line and say "front/back only"), strip charts of release
  speed and angle in shot order (filled = accepted, hollow = excluded; the only reference line is the
  block's own mean with a ±1 SD band), the shot list with status
  (queued / analyzing / accept / low confidence / reject / failed + the analyzer's own reason) and the
  geometry **and** pose numbers per row, and the coaching card last.
- `ShotResultContext.swift` — `ResultsView` now takes a context instead of the model, so the session
  list and the single-shot flow open the same screen; `SingleShotResultsView` keeps the old entry
  point. `ResultsView` gained a pose card and a session verdict/outcome card.

## Verified on 2026-09-14
- `cd App && xcodegen generate && xcodebuild -project ArcLab.xcodeproj -scheme ArcLab -destination
  'generic/platform=iOS Simulator' build` → **BUILD SUCCEEDED**. (It failed for about an hour on
  `filename "BallDetector.swift" used twice` — Xcode's Core ML codegen for the new
  `Sources/ShotVideo/Resources/BallDetector.mlmodel` generating a second `BallDetector.swift`. That was
  another agent's in-flight change and they fixed it; `COREML_CODEGEN_LANGUAGE=None` on the command
  line was the interim check and is not needed now.)
- `SessionScanner` + `ShotAnalysisRunner` + `BlockSummary` + `SessionCoaching` compiled **verbatim**
  (symlinked) into a macOS harness and run on `footage/2026-09-13/IMG_1765.mov` with
  `rim_1765.json`, factor 4, hFOV 48, restricted to the first **200 s** of file time.
  - Scan: 6270 frames in 4 chunks in **26 s**, → **8 arrivals** at file times
    **12.1 24.3 38.5 50.5 93.7 107.3 153.3 166.1**.
    The Python scanner finds 8 in that range at **1.5 15.4 28.5 50.5 93.6 108.2 153.1 168.3**: four
    agree within 1 s (50.5, 93.7, 107.3, 153.3), one within 2.2 s (166.1), and three do not match
    (mine 12.1/24.3/38.5 against Python's 1.5/15.4/28.5). The count is the same but the *set* is not.
    Two causes, both real: Vision's trajectory detector gives ~1 candidate per frame per live track
    where the Python scanner's background-difference finder gives many, so an arrival can be missed
    (the first shot at 1.5 s is inside the ~10 frames Vision needs to form a trajectory at all); and
    the "one arrival per 3 s real" lock-out is 12 s of file time here, so one early extra firing
    shifts everything after it. Vision is also not run-to-run deterministic on this clip — an earlier
    run of the same command found 7 arrivals, missing 107.3.
    The Vision-based arrivals match the earlier Swift batch in
    `docs/footage-2026-09-13/session_ft_batch.txt` (11.2, 37.7, 49.7, 92.5, 150.0, 165.1) far more
    closely than they match pytrack's, which is what one would expect from the same candidate source.
  - Analysis: 7 of the 8 windows were measured, 1 failed with the analyzer's own sentence
    ("flight window: no sustained free-flight segment found"), and **1 was accepted** — shot 7 at
    153.3 s: **g_fit 9.81**, release 43.5° at 2.68 m and 7.26 m/s, entry **38.6°**, depth **15.7 cm**.
    Those land on top of the free-throw block's published means in `SHOOTER-REPORT.md`
    (entry 38.4 ± 3.4°, depth 17.7 ± 4.7 cm). Total 182 s for the scan plus all 8 windows
    (≈ 19 s per window including the pose pass).
  - Pose ran on all 7 measured windows: elbow at release 153 ± 19°, elbow most extended near release
    171 ± 5°, knee minimum 116 ± 13°, dip → release **0.61 ± 0.34 s** (n 7), against the report's
    0.68–0.77 s and 156–161°. Every one carries the view-class warning, and the spread is exactly the
    "relative only" noise the report warns about.
  - Block summary at n = 1 reads "1 counted", every geometry statistic says "(n 1, one shot has no
    spread)", the coaching card shows one sentence (entry angle vs the published mid-40s band),
    "Collecting baseline: 1 of 30 accepted shots", and one filming line ("a metre of sky above the
    arc — on 3 of 7 measured shots the ball's top edge reached the top of the frame").

## Honest limits of the session mode
- **The accept rate on this footage is 1 in 8, and that is the detector, not the scanner.** Running
  the same 8 windows with the pose stage switched off changes nothing (still 1 accept), and the
  earlier Swift batch over this clip (`session_ft_batch.txt`) got **no** accept at all before 232 s.
  The 6-of-31 free-throw accept rate in `SHOOTER-REPORT.md` came from `track.py` + `run_loop.py`'s
  five-iteration self-correcting tracker, not from Vision + the classical detector the app runs. Until
  the app's ball tracking matches pytrack's, a session will show mostly rejects with their reasons —
  which is the honest outcome, but it is not yet a useful session.
- The scanner's arrival set is not the Python scanner's arrival set (above). Neither is ground truth;
  neither has been checked against the video frame by frame.
- `lateralDeviation` is still nil, so the session rim map is one-dimensional, by design.
- Nothing is persisted, so a session dies with the app. SwiftData is the next step.
- Nothing has been *seen* running: the simulator UI still cannot be driven from this session, so every
  session screen is verified by compilation and by the macOS harness, not visually.
- The scan re-probes the clip once per chunk (`TrajectoryTracker.run` calls `quickProbe`), which is
  cheap but wasteful; caching the probe from import needs a `ShotVideo` change.

# Swift tracking parity, 2026-09-14

The Swift ball tracking in `Packages/ShotVideo` now clears the same gate the Python tracker clears on
`footage/2026-09-13/IMG_1765.mov`, and clears it on more windows. **12 of 30** windows are accepted over the
whole 1137 s clip (8 % gravity gate **and** release height 1.6–3.3 m, speed 4.5–11 m/s, depth −0.6…1.0 m),
against **6 of 31** for `tools/pytrack` and **5 of 29** for the same Swift harness with the tracking changes
switched off. All three human-labelled free throws now pass the gravity gate, and their release instants sit
within **±3.5 file frames** of the shooter's own labels.

Nothing in `Packages/ShotGeometry`, `tools/pytrack` or `docs/PHASE2-PREP.md` was touched.
`swift run -c release GeometryHarness` still prints **GATE: PASS**.

## What changed

### `Packages/ShotVideo/Sources/ShotVideo/BallDetector.swift`
- **Hybrid placement (`BallDetectorOptions.coreMLHybridCentroid`, default on).** The Core ML box no longer
  supplies the position. It *selects* which background-difference blob is the ball — the strict blobs first,
  then a relaxed second look — and the blob's weighted sub-pixel centroid is the position. This is the step
  `docs/PHASE2-PREP.md` named as the obvious next one: the model is markedly better at *finding* the ball and
  ~10–12 px worse at *placing* it. On the three labelled windows 80–117 of the tracked frames are now placed
  this way; only 5–11 fall back to a box centre.
- **Inflated boxes are dropped (`coreMLMaxBoxDiameterFactor`, 1.8).** A box wider than 1.8 running ball
  diameters has swallowed the rim and the net; with no moving orange blob inside it, its centre is the rim's,
  not the ball's, so it produces no sample at all. 3 such boxes are dropped in the 817 s window.
- **The ball size is re-derived from the selected blobs.** The boxes read large, so after the first hybrid
  pass the expected diameter is taken from the median of the blobs the boxes selected, and if it moved by
  more than 15 % the blobs are found again at the new size.
- **Blobs no box claimed are kept** (`keepUnmatchedBlobs`), so the fallback to the classical detector is now
  per candidate instead of per frame.
- **Predicted weak candidates on the dark descent** (`predictedWeakCandidates`, `track.py`'s rule ported):
  with ≥ 10 linked points, a blob from the relaxed finder (0.6× the difference threshold, half the minimum
  area, circularity 0.3, 3 less orange margin) within **0.8 D** of the parabola prediction and 0.4–1.6 D
  across is accepted. It is still image evidence — no position is ever extrapolated. It fires 14–27 times per
  window on the pure background-difference path, which is where the descent used to go dark.
- **Backward extension into the hands** now uses pytrack's **1.5 D** gate (was 1.0 D) and refuses Core ML
  box candidates: at the hands the box swallows ball and hand together, and believing it moved the pose
  release rule 4 frames early on the 313 s free throw.
- **The track is cut where free flight ends** (`trimAfterBounce`, `bounceRiseDiameters` 0.25). After the apex
  the ball's image *v* only grows; the first frame that climbs back by more than a quarter of a ball, well
  past the apex and ≥ 1.5 D below it, is a bounce off the rim, the net or the floor. Without this the 313 s
  track ran 48 frames past the rim and the analyzer's window detector took the rebound for the shot.
- `BallDetectorStats` gained `hybridRefinedFrames` / `hybridBoxOnlyFrames` / `blobOnlyFrames` /
  `weakDescentFrames` / `suppressedInflatedBoxes`, counted over the chosen track, and `analyze` prints them
  as a `placement:` line.

### Edge-clipped samples never reach the fit
A blob cut by the frame edge has its centroid pulled inward, so an arc whose apex leaves the top of the frame
reads flatter than it is and g fits low. `Probe.swift` already dropped these for pytrack tracks; the Swift
path now does the same — in `analyze --classical` (`--keep-edge` puts them back), in `session`, and in
`ShotAnalysisRunner`. They stay in `ballDetections` because the pose stage still wants them. For the same
reason the **ball diameter the release rule scales by is now the median of the unclipped detections only**:
a clipped blob under-reads the ball, and on the 313 s window that alone moved the estimated release from
−6.5 to −2.5 file frames.

### `App/Sources/ShotAnalysisRunner.swift` — a cut-down `run_loop.py`
The detector now runs up to three times per window, and only when the shot does not come out measurable
(`ShotAcceptance.evaluate`): **(1)** Core ML box + blob centroid, **(2)** background difference only,
**(3)** background difference with loosened thresholds (`run_loop.py`'s LEVEL1 moves for
`BALL_COVERAGE_LOW`/`BALL_NO_FLIGHT`: 0.8× difference threshold, circularity −0.1, area bounds widened,
+4 gap frames, template score −0.1). A retry re-runs **only** the detector — the Vision trajectory pass and
the body-pose pass happen once and are reused, so `runPoseStage` was split into `capturePoses` (the Vision
work) and `poseResult` (pure). The attempt the block rule accepts wins; among equals the one whose fitted
gravity is closest to 9.81, because g is the check. A retry costs 2 s (pure background difference) to ~10 s
(loosened hybrid) per window on this Mac, and an accepted window never pays for one. Every retry is recorded
in the shot's notes.

### `TrajectoryProbe session` now mirrors the app
It had neither of the two things the app's session flow has, which is why it accepted nothing under the block
rule: it ran **no pose stage** (so most windows had no release and failed plausibility on a `nil`), and it
pooled the per-shot azimuths with a plain median of an angle that wraps (15 "accepted" shots spread over
227°…298° produced a session azimuth that put rms at 14–284 px). Now it runs `PoseTracker` + `ReleaseFromPose`
per window on every 2nd frame exactly as `ShotAnalysisRunner` does, pools the azimuth as a **circular mean
over shots that pass the full acceptance rule**, and uses it only when ≥ 3 such shots agree within 25°
(on this clip 12 agree only within 39°, so the per-shot solve stands). It prints `ACCEPT` per row and an
`accepted N of M` line. New flags: `--no-pose`, `--legacy-tracking` (everything above switched off, for
before/after), and on `analyze`: `--keep-edge`, `--no-hybrid`, `--no-weak`.

## Numbers

### The three labelled free throws
`analyze IMG_1765.mov --rim rim_1765.json --start S --end E --time-scale 4 --hfov 48 --rim-diameter 0.4572
--fixed-g-azimuth --classical --pose`. Release error is in **file** frames (30 fps file, 1 frame = 8.3 ms
real) against `docs/footage-2026-09-13/release_labels.json`.

| window (file s) | | g_fit | rms px | release | err (frames) | θ | h | v | entry | depth |
|---|---|---|---|---|---|---|---|---|---|---|
| 88.5–95.5 | before | 8.86 (9.7 %) low | 11.12 | 90.000 | −4.5 | 50.2° | 2.15 m | 7.11 m/s | 39.3° | 0.29 m |
| | **after** | **9.46 (3.6 %) accept** | **9.52** | 90.033 | **−3.5** | 51.2° | 2.11 m | 7.38 m/s | 40.3° | 0.28 m |
| 312.4–319.8 | before | 8.81 (10.2 %) low | 10.46 | 314.400 | −4.5 | 48.3° | 2.16 m | 6.93 m/s | 35.8° | — |
| | **after** | **9.45 (3.7 %) accept** | **5.42** | 314.467 | **−2.5** | 49.2° | 2.15 m | 7.15 m/s | 36.9° | 0.11 m |
| 815.8–823.2 | before | 9.73 (0.8 %) accept | 7.91 | 817.333 | −0.5 | 45.1° | 2.64 m | 7.34 m/s | 40.2° | — |
| | **after** | 9.42 (4.0 %) accept | **5.65** | 817.367 | **+0.5** | 45.5° | 2.55 m | 7.22 m/s | 39.3° | 0.29 m |

Two of three windows went from failing the 8 % gate to passing it; the third was already inside it and moved
from 0.8 % to 4.0 %, which is the one number that got worse. Per-sample rms fell on all three
(11.12 → 9.52, 10.46 → **5.42**, 7.91 → **5.65** px) — pytrack's range on this footage is 3–5 px, so 313 s
and 817 s are now inside it and 89 s is not.

`--no-coreml` still works and on the 817 s window is still the most precise single path: g 9.42 (4.0 %),
**rms 4.43 px**, release +0.5 frames, in **1.5 s** against 10 s for the hybrid, with 27 frames recovered by
the weak-descent rule. It is not the default because it puts the 89 s release **+14.5 frames** late — the
classical detector sits on the hands there, which is the failure the Core ML box exists to fix.

### The whole clip
`session IMG_1765.mov --rim rim_1765.json --time-scale 4 --hfov 48 --rim-diameter 0.4572`.

| run | windows | accepted | note |
|---|---|---|---|
| before (old detector, old `session` command) | 30 | **0** | 8 passed gravity alone; 7 of those had no release at all |
| `--legacy-tracking` (new command, old detector) | 29 | **5** | isolates the session-command fix |
| **after** | 30 | **12** | isolates the tracking change: 5 → 12 |
| `tools/pytrack` (`SHOOTER-REPORT.md`) | 31 | 6 | reference |

The 12 accepted shots: release **45.8 ± 3.7°** at **2.32 ± 0.35 m** and **7.26 ± 0.19 m/s**, entry
**36.1 ± 2.8°**, depth past the front rim **0.22 ± 0.19 m**, g error **5.0 ± 1.4 %**, median fit rms 6.5 px.
pytrack's six: 46.6 ± 3.6°, 2.43 ± 0.26 m, 7.23 ± 0.11 m/s, 38.4 ± 3.4°, 0.177 ± 0.047 m. The two blocks
agree on every number to within their own spread, on twice as many shots.

## What still fails, and why
- **The 89 s window is still the worst of the three** (rms 9.52 px, g 3.6 %). It has the most box-only
  placements (11 of 98) and 22 edge-clipped frames: the shooter is closest to the camera there, the ball
  leaves the top of the frame early, and the background-difference blob merges with the shooter's shirt
  through the release.
- **Dropping the edge-clipped samples opens a hole** where the ball is above the frame (43 frames on the
  313 s window, 0.36 s of real time). That hole is only survivable because the track is now cut at the
  bounce; with the old, untrimmed track the same drop made the analyzer's window detector take the rebound
  for the shot and g fell to 7.14 (27 % — reject). The two changes only work together.
- **One accepted row is accepted on a very bad fit**: shot 28 at 1078.5 s has rms 161.9 px and still satisfies
  gravity + plausibility. The block rule has no residual term, which the `report.py` rule it was ported from
  also lacks. A `rmsPx` ceiling is the obvious addition and was not made here because it changes the rule.
- **The `session` command's windowing is not the app's.** It takes Vision tracks that end near the rim; the
  app uses `SessionScanner` (the `find_arrivals` port). Several of the 30 "shots" are not shots (a ball
  rolling, a rebound), which is where most of the 18 rejects come from, not from the tracking.
- **Vision's trajectory pass is not deterministic**: the same clip gave 417 and 418 tracks on two runs, hence
  30 windows against 29. Counts in this section are therefore ±1 window.
- **The retry loop has never run on a phone**, and nothing here was seen in the simulator UI — the app builds
  (`xcodegen generate && xcodebuild … -destination 'generic/platform=iOS Simulator' build` → BUILD SUCCEEDED)
  and the same code paths were measured through `TrajectoryProbe`, which is not the same as watching it work.

## Automatic rim finder (2026-09-14)

`Packages/ShotVideo/Sources/ShotVideo/RimFinder.swift` proposes the rim ellipse from **one** frame so
setup becomes confirm-or-nudge instead of tap-64-points. No Vision, no Core ML, no network: an
orange-chroma plane over the top 60 % of the frame, thinning that deletes solid paint (backboard
border, bracket) and leaves arcs, RANSAC with the rim priors, then three refit passes that read each
normal's paint profile and take its **half-maximum midpoint** — the tube centre-line — rather than
walking in to the last orange pixel. The inner circle the calibrator wants is then the centre-line
scaled by `0.4572 / (0.4572 + 0.0159) = 0.96639`.

### What was wrong in the handed-over file, and what changed
- **The luma gate gated on R, not luma.** Documented as a luma gate; implemented as `(r - minLuma)`.
  Harmless in this footage (R never clips) but wrong in the direction that matters: a sunlit ring
  clips its red channel to 255 while the pixel is still strongly orange, so the upper gate would eat
  the band's *core* and bias the half-maximum midpoint the whole measurement rests on. Now
  `0.299R + 0.587G + 0.114B`, with `minLuma` dropped 50 → 34 because the shaded side of the ring sits
  at luma ≈ 55. Measured band widths fell from 9.3–12.1 px to a uniform 9.0–10.4 px, matching the
  file's own "~9–10 px" claim, and IMG_1764 @ 60 s dropped from rms 1.75 px to 0.77 px.
- **A magic constant contradicted its comment.** `peakMin = minChromaScore * 0.58` sat *below* the
  mask threshold under a comment saying a real band peaks well above it. It is now the documented
  option `minBandPeakScore` (default 14) with the real reason written down: the crossings are read
  off a profile, so the shaded side of the ring still contributes where no single pixel clears the mask.
- **`rawInwardEdgePoints` fabricated points.** Unmeasured angles were filled in by evaluating the
  fitted ellipse, so a caller could not tell a measurement from an extrapolation — a CLAUDE.md rule 1
  violation. It now contains only angles where a band was actually measured and is shorter than 64
  when the ring is partly hidden. `boundaryPoints` is still exactly 64, by construction.
- **`medianBandWidthPx` averaged rejected bands**, including profiles that cleared the peak test and
  were then thrown out as too wide, so a stray blob could set the number the blur warning is read
  from. Now only accepted bands count, and the warning fires at `0.85 × maxBandWidthPx` (the old
  `> 14 px` test had become unreachable, since bands wider than 13 px are rejected).
- **The best-scoring ellipse could veto a valid one.** Coverage/gap failures on `solutions[0]`
  returned `.notFound` without looking at `solutions[1]`; the search now walks the list, and the
  runner-up used for the confidence margin is the best *other* ellipse rather than `solutions[1]`.
- `RimFindResult` gained a public memberwise init so an app target can wrap a user-dragged ellipse in
  the same type and feed one downstream path.

### Measured, 8 ball-free frames, 1920×1080, M-series Mac
Differences are **found tube centre-line minus the hand trace's fitted ellipse** — the honest
comparison, because a careful hand trace marks the painted tube's centre-line (0.4731 m), not the
inner edge. Runtime is the whole `findWithDiagnosis` call including the chroma plane.

| frame | Δcx | Δcy | Δmajor | Δminor | Δangle | inlier | conf | rms px | band px | ms |
|---|---|---|---|---|---|---|---|---|---|---|
| 1764 @ 60 s | −3.7 | +0.4 | −1.7 | −0.4 | +0.2° | 0.93 | 0.78 | 0.77 | 9.0 | 30 |
| 1764 @ 200 s | −3.0 | +0.2 | −1.5 | −0.3 | +0.1° | 0.97 | 0.89 | 0.87 | 9.0 | 30 |
| 1765 @ 60 s | −3.9 | +1.8 | +2.5 | +0.5 | −2.2° | 0.88 | 0.67 | 1.10 | 9.6 | 33 |
| 1765 @ 200 s | −3.8 | +1.8 | +0.2 | +0.4 | −2.0° | 0.90 | 0.64 | 1.34 | 9.9 | 27 |
| 1765 @ 400 s | −3.8 | +1.5 | +1.1 | +0.6 | −1.7° | 0.92 | 0.74 | 1.26 | 9.3 | 25 |
| 1766 @ 100 s | **−38.9** | −4.5 | −0.8 | −2.2 | −14.0° | 1.00 | 0.92 | 0.95 | 9.0 | 41 |
| 1766 @ 300 s | **−32.1** | −4.6 | −2.7 | −2.6 | −13.5° | 0.78 | **0.38** | 2.39 | 10.4 | 24 |
| 1766 @ 600 s | **−41.5** | −4.2 | −1.7 | −2.0 | −14.0° | 0.96 | 0.85 | 1.16 | 9.5 | 29 |

**The IMG_1766 row is the hand trace being wrong, not the finder.** `rim_1766.json` (and both its
variants, which share a centre to 0.1 px) puts the ring at cx ≈ 1761 with a +10° tilt; the finder says
cx ≈ 1721 at −3.9°, stable to 3 px across 16 frames spread over the clip. The overlay
(`out/rim_IMG_1766_t100.png`, 6× zoom) settles it by eye: the trace's right half lies on the dark-red
**bracket and backboard border**, past the end of the orange tube. This is the failure the file's own
header warns about. Re-trace IMG_1766 before using it as ground truth for anything.

On 1764/1765 the residual Δcx ≈ −3.5 px with Δcy < 2 px and Δmajor ≈ ±2 px is also mostly the traces
over-running the ring's right tip into the bracket — the two left tips agree to about a pixel.

Renders (6× zoom of the ring, green = proposed inner edge, red = measured tube centre-line, blue =
hand trace), in
`/private/tmp/claude-501/-Users-smyth-Desktop-projects-arclab-ios/f779438c-c98c-43e5-9075-769f12c1d9ac/scratchpad/out/`:
`rim_IMG_1764_t60.png`, `rim_IMG_1764_t200.png`, `rim_IMG_1765_t60.png`, `rim_IMG_1765_t200.png`,
`rim_IMG_1765_t400.png`, `rim_IMG_1766_t100.png`, `rim_IMG_1766_t300.png`, `rim_IMG_1766_t600.png`
(scratch — regenerate with the throwaway package next to them if they are gone).

### False positives and stability
Swept 16 times per clip (48 frames, most with a ball, a shooter and a rebound somewhere in shot):
**47 found, 0 false positives.** Centre spread 1719.6–1722.7 / 1572.3–1574.5 / 1367.6–1369.5 px in x
and under 1.1 px in y; semi-major 51–59 px. The one miss is an honest `.notFound` ("no wide, flat arc
that could be a ring"). Crops containing only the bracket and the backboard's red border return
`.notFound`; so does the bottom half of a frame, and so does random noise. A crop that clips the
ring's right tip *does* return a small ellipse — correct behaviour for an input where the rim really
is half out of frame, and it never wins against the whole ring in a full frame. The result is
bit-identical run to run (seeded RNG), and the `CVPixelBuffer` overload matches the `CGImage` one to
0.00 px.

### How the app should call it
One frame, before the shooter starts — the ball must be out of the ring, which every ball-free frame
above was:

1. Grab one frame from the preview or the recorded clip and call
   `RimFinder.findWithDiagnosis(in: frame)` on a background task. It is 25–45 ms at 1080p and
   single-shot, so there is no reason to run it per frame or to hold a camera buffer for it. Take
   `.notFound(reason:)` straight to the UI — the reasons are written to be shown to a user.
2. Draw `result.boundaryPoints` (64 points, already the inner edge) as the draggable ellipse handles
   and `result.ellipse` as the outline. **Never commit the proposal silently.** The user confirms, or
   drags the ellipse/its handles, and the edited points go to `RimCalibrator.calibrate` exactly as a
   hand trace would — the finder's output is the same shape as the manual path, not a parallel one.
3. Show `result.warnings` verbatim under the ellipse. They are already plain-language and each one
   names *where* to look, which is the only thing that makes a nudge cheap.
4. If `result.confidence < 0.6`, open the confirm step **zoomed on the major-axis tip the warning
   names** (the bracket end) with the ellipse already editable, and word the prompt as a question —
   "Does the ring end here?" — not as a result. Do not show the number. Below 0.6 the proposal is a
   starting point, and IMG_1766 @ 300 s (conf 0.38, a soft frame where the fit stops ~2.7 px short on
   the right) is exactly the case that must not slip through as a measurement.
5. If confidence is high (≥ 0.85 on five of the eight frames here) still require an explicit tap to
   accept, and offer "trace it myself" at every step. A wrong rim is a silent 5 % distance error in
   every metric downstream; a confirm tap is cheaper than a wrong session.
6. Worth doing and not done: run the finder on two or three ball-free frames and only auto-propose
   when they agree to a pixel or two. The sweep above shows they do agree, which is the cheapest
   available check that the proposal is not a one-frame accident.

### Still untested
Only the 2026-09-13 clips, only 1080p, only that basket, only on a Mac — never on the phone, never
indoors, never on a ring whose paint has faded, and never against a re-traced IMG_1766. The 60 %
`searchTopFraction` and the orange-chroma assumption are both unproven outside this footage.

---

## Healthy shot model and coaching rules (2026-09-14)

**New research doc:** `docs/research/healthy-shot-model-2026-09-14.md`. It extends
`coaching-evidence-2026-09-13.md` with the joint-kinematics, sequencing, versatility and
practice-method literature, and assembles a 22-row "healthy, versatile shot" profile where every row
is a *measured range with a grade* (A = peer-reviewed on skilled shooters or exact geometry; B =
peer-reviewed but small/recreational/indirect; C = coaching consensus; D = opinion or in-house
hypothesis). §7 of that doc is the mapping table: profile row → grade → is it in `BlockRow` today →
what the app says → what unlocks the rest.

**What the research changes, in one line each.**
- Release-speed SD stays the headline (grade A, Slegers 2021, r = −0.96), and the skilled band is
  0.05–0.13 m/s, *the same at free-throw and 3-point distance*. That last clause is the definition of
  "versatile" the app can defend: **spread that does not widen when the distance or condition changes.**
- Depth makes peak 25–28 cm past the front rim (grade A); the ring centre is 22.9 cm, so "swish it"
  is wrong.
- The proficient/non-proficient difference in the joint literature lives in the **preparatory phase**
  (knee peak 212.9 vs 269.4 °/s — proficient move *slower*), not at release (grade B).
- Elbow, set point, one- vs two-motion, squareness and stance width are **C/D lore or contradictory**.
  Excellent vs good professionals showed *no* kinematic differences at all (grade A null, Cabarkapa 2022).
- The two cue-delivery beliefs a shooting app would naturally adopt — external focus and faded
  feedback — both have grade-**A null** meta-analyses against them (McKay 2022/2024).

**`App/Sources/SessionCoaching.swift` (the only file changed).**
- `EvidenceGrade` (A/B/C/D) now travels with every `CoachingCard.Line` and every profile row, and is
  folded into the `provenance` string so existing views show it without edits.
- New "what this session says" lines: **depth-variance attribution** (the Ch 5 delta method through
  the rim-crossing Jacobian, at n ≥ 20 — "this much of your front-to-back spread is release speed,
  this much is angle, this much is height"); **release angle against this block's own depth-turnover
  angle** (grade A, geometry, and distance-free so it beats any population angle); **dip-to-release ×
  release-speed correlation** at n ≥ 15, reported with its r and n and labelled **grade D, untested**.
  The speed and entry lines now quote the skilled band and the 10–11 in depth peak.
- Lines are ordered **by grade, then author order** (`sort` is not stable in Swift, so the order is
  carried explicitly). Still capped at three.
- `workOn` is now a candidate queue sorted by **evidence grade first, then departure size within the
  grade** (the second key is a tie-break only and is never printed). Six rules: flat arc (A),
  release-speed spread (A), left-right spread (A, new), drift (A), angle-dominant depth spread (B, new),
  rhythm correlation (D, new). The n ≥ 30 gate and "collecting baseline" are unchanged.
- New **`ShotProfile`**: 15 rows of (metric, yours ± SD n, profile range, grade, one-sentence reading,
  source), attached to the card as `CoachingCard.profile`. Below n = 30 it is tagged
  `"preview, n < 30"` and says so in `note`. Rows that cannot be measured carry
  `unavailableReason`, never a blank.
- New filming advice: shoot a block from the 45° position, because left-right spread is a grade-A
  metric a side view cannot deliver.

**Numbers verified against the package, not asserted.** `ReleaseSensitivity` at the three blocks'
means gives ∂depth/∂v = 1.46–1.57 m per m/s, i.e. **14.6–15.7 cm per 0.1 m/s** — an independent
confirmation of the `depthCmPerTenthOfAMetrePerSecond = 15` anchor. Depth-turnover angles come out
48.1–50.5°, consistent with the digest's 50.72° reference case.

**Known limitation, stated in the copy.** `SessionCoach.releaseToRimCentreMetres` reconstructs the
shot distance by inverting `Physics.forward` on each accepted shot's own fit, because `BlockRow` does
not carry it. On the 2026-09-13 footage that gives 4.80 / 4.33 / 5.75 m for free throws / elbow /
threes — the right ordering, the wrong magnitudes, because of the hFOV scale error the shooter report
already flags. Every line that uses it says the sign of the gap is more trustworthy than its size.

**TODOs left in the file, naming the `BlockRow` fields that would unlock the held-back rows**
(`BlockSummary.swift` was not touched): `releaseDistance` (from `ShotMetrics.release?.distance`, kills
the reconstruction above), `headStabilityPx` (`HeadMetrics.stabilityPx`), `shoulderLineYawDegrees`
(`StanceMetrics.shoulderLineYaw`), `proximalToDistal` (`KineticChain.proximalToDistal`),
`kneeExtensionPeakDegreesPerSecond` (`KineticChainEvent.peakRateDegreesPerSecond`),
`forearmFromVerticalDegrees` for the frontal-view elbow-flare metric.

**Must not be shown until tracking improves:** any metre from the body model (stance width, jump
height — the unreliable class), 3-D shoulder-line yaw and 3-D joint angles (the noisy class),
kinetic-chain lags in milliseconds (no published reference range at all), and head stability across
sessions (pixels do not travel between camera positions). Sequencing **order** and head-stability
**within-session SD** are safe as patterns once they reach `BlockRow`; their numbers are not.

**Not done:** no view renders `CoachingCard.profile` yet — `SessionView.coachingSection` and
`HistoryView.coachingSection` each need one section, which is an App-view change outside this task's
scope. `Packages/` and the tools were not touched, so Phase 1 is unaffected.
# Speed, 2026-09-14

The user's words were "it analyzes the shots extremely slowly". On the phone a full session was unusable: the
whole-clip scan alone ran past four minutes on a 250 s segment with the phone in a *serious* thermal state.
Nothing below changes what is measured — it changes how many times the same frames are decoded and how many
Core ML tiles are cut. **Every default here is a measured number**: where a cheaper setting changed any of the
three labelled free throws, the cheaper setting was rejected and the reason is recorded in the code.

`swift run -c release GeometryHarness` still prints **GATE: PASS**. `Packages/ShotGeometry` untouched.

## What changed

### `Packages/ShotVideo/Sources/ShotVideo/StageTimings.swift` (new)
A thread-safe per-stage wall-clock ledger — `decode`, `planes`, `coreml`, `motion`, `background`, `candidates`,
`link`, `template`, `vision.trajectory`, `vision.pose`, `fit` — threaded through the detector, the scanner and
the analyzer. `TrajectoryProbe session` prints it per window and as a total; `SessionModel` writes it into the
activity log under `analysis.shot / stages`. Nothing below was changed without this printing first.

### `RimArrivalScanner.swift` (new) — the scan without Vision
`DetectTrajectoriesRequest` over a whole clip costs ~5 ms a frame, and the arrival rule it fed never wanted
trajectories: it wants ball-sized moving blobs near the rim and in the upper 40 % of the frame. The new scanner
decodes the clip once and, on a **quarter-resolution crop of exactly those rows** (480×108 of 1920×1080 on this
footage), keeps a per-pixel sigma-delta background — one grey level a frame, which converges to the running
median — and reports round, orange, moving blobs against it. Size comes from a loose local re-threshold with no
orange gate, the way `BallDetector` measures it: without that the strict mask reads the *lit* part of the ball
and under-reads the diameter by half, and the arrival rule gates on diameter (this alone took the segment from
8 arrivals to 9). All arithmetic is vDSP.

### `ArrivalRule.swift` (new)
`find_arrivals` moved out of `App/Sources/SessionScanner.swift` into `ShotVideo` unchanged, so the desktop probe
can run the *same* rule over the old scanner's candidates and the new one's. `SessionScanner.arrivals` is now a
shim. `SessionScanOptions.mode` selects `.fast` (default) or `.vision` (the old scanner, kept for comparison),
and `TrajectoryProbe scan <clip> --rim … [--vision]` prints both lists and the differences.

### `BallDetector.swift` — one decode per window
`runDetailed` split into `decodeWindow` (→ `WindowFrames`: the half-resolution Y and Cr planes, the per-frame
Core ML boxes, and the background model, memoised) and `track` (pure CPU, no file access). A detector retry is
now arithmetic on frames that are already in memory. `runDetailed(url:…)` still exists and composes the two.

Accelerate throughout, because a debug build was ~100× slower than release on this code and the phone's app
scheme was running debug: `halfLuma`/`halfCr` are vDSP box averages (`vDSP_vfltu8` → `vDSP_vadd` → `vsmul` →
`vDSP_vfixru8`, which truncates exactly like the integer division it replaces — the planes are bit-identical);
`CandidateFinder`'s difference image and orange gate are `vsub`/`vabs`/`vsma`; the background median is tiled so
25 planes of one tile fit in L2 and uses an insertion sort on a raw pointer instead of `Array.sort()` per pixel;
the duplicate-frame signature samples every 4th pixel of each cell instead of all 400.

Core ML economy, each setting checked against the three labelled free throws:
- the whole-frame sweep runs every **2nd** frame when nothing predicts the ball (bit-identical tracks; every 3rd
  changed the 89 s window, every 8th moved its release to −8.5 file frames — rejected);
- a stale prediction widens the search by **one** tile stride, not two (bit-identical; zero changed the 89 s
  window's g from 3.1 % to 6.3 % — rejected);
- sweeps stop 45 frames after the last box once the ball has been locked on at least once, and are capped at
  **24 per window**, because a window the model never locks on to is both the most expensive (15 tiles a frame)
  and the least likely to be worth anything;
- `MotionProbe.swift` (new): a sixteenth-area background difference that re-aims the tile at a ball the tracker
  has **already had**, so re-acquisition costs one tile instead of nine. It is deliberately *not* allowed to aim
  before the first lock: measured, it aims at the ball still in the shooter's hands, the model returns a box
  there, the backward extension believes it, and the 313 s free throw's release moves from −2.5 to −15.5 file
  frames. `coreMLEveryNthFrame` (run the model on every n-th tracked frame) is exposed and left at 1 for the
  same reason — 2 is a third cheaper but changes the track near the hands.

### `VideoReader.forEachPixelBuffer`
`forEachFrame` re-wraps every frame in a fresh `CMSampleBuffer` with a fresh format description, because Vision's
stateful requests are async and need timing. A synchronous pixel consumer needs none of that. The scanner and the
window decode use the new path.

### `App/Sources/ShotAnalysisRunner.swift`
- The **Vision trajectory pass inside the window is gone** from the session path (`useVisionSeed`, default off):
  it was a whole extra decode plus ~5 ms a frame, and the scan already knows where the ball is. The scanner's
  candidates seed the detector and the rim ellipse gives the expected ball size. The single-shot flow still runs
  it (`AnalysisModel` passes `useVisionSeed: true`) because there is no scan behind it and it is also that
  flow's fallback when the detector finds too little.
- `fps` and the frame size come from the scan instead of a per-window probe.
- **Body pose only where a release can be**: from the window's start to half a second of real time past the
  ball's first detection, instead of the whole window. The dip lookback is already clipped by the window, so
  nothing measurable is lost; the note on the shot says what range ran.
- **Retries only for a coverage failure.** A window that produced ≥ 20 unclipped detections and ≥ 15 inliers and
  still fitted the wrong gravity is a geometry failure; looser detector thresholds cannot mend geometry. On the
  phone three windows had been paying 12–14 s each for a loosened pass that rescued none. The shot's notes say
  when a retry was skipped and why.

### `App/Sources/SessionModel.swift`
Windows are analysed in a `TaskGroup`, one or two at a time. The limit is computed, never assumed: one decoded
1080p window at a 4× factor holds ~255 MB of planes against a 320 MB budget, so on this footage the phone runs
**one**; a shorter window or a smaller frame gets two. `ProcessInfo.thermalState` of *serious* or *critical*
forces one lane whatever the arithmetic says, and `analysisNote` says which and why. The lane count, the window
size in MB, the thermal state and the per-stage timings all go into the activity log.

## Numbers

All on this Mac, `-c release`, `TrajectoryProbe session footage/2026-09-13/IMG_1765.mov --rim
docs/footage-2026-09-13/rim_1765.json --time-scale 4 --hfov 48 --rim-diameter 0.4572`. "Before" is the code as
it stood this morning; both were run on the same machine, minutes apart.

### End to end

| | before | after |
|---|---|---|
| **250 s segment** (7,500 frames), `--start 0 --end 250 --limit 6` | **99 s** | **38 s** |
| ├ scan | 34 s — Vision, 220 fps | **4 s** — fast scanner, 1,780 fps |
| └ per window | 10.8 s mean (6 windows) | **5.6 s median**, 5.6 s mean, 8.4 s max |
| windows accepted on the segment | 1 of 6 | **2 of 6** |
| **whole clip** (1,137 s, 34,132 frames, 30 windows) | ~475 s (scan 150 s measured + 30 × 10.8 s) | **227 s** |
| ├ scan | **150 s** — Vision, 240 fps (35,842 frames) | **19 s** — fast scanner, 1,800 fps |
| └ per window | — | **6.85 s median**, 6.84 s mean, 11.2 s max |
| windows accepted on the whole clip | **12 of 30** | **13 of 30** |

The per-window target in the task was ≤ 3 s median and it is not met: 6.85 s. The reason is in the stage table
below — Core ML inference is 4.2 s of it, and **every** further cut to it that was tried changed one of the
three labelled free throws (each rejected setting, and what it did, is recorded in `BallDetectorOptions`). The
two levers left are `coreMLGlobalSearchEveryNthFrame` (3 instead of 2 costs the 89 s window a frame of release,
−3.5 → −4.5, and buys ~15 %) and `coreMLEveryNthFrame` (2 buys ~35 % and moves the same window further), and
both should be decided against a bigger labelled set than three shots, on the phone, not here.

### Per window, by stage (seconds, whole clip, 30 windows)

| stage | total | per window | what it is |
|---|---|---|---|
| `coreml` | 126.4 | 4.21 | the trained detector's 512-px tiles |
| `vision.pose` | 20.7 | 0.69 | `DetectHumanBodyPoseRequest`, every 2nd frame, release range only |
| `motion` | 14.4 | 0.48 | the sixteenth-area background difference that re-aims the tile |
| `candidates` | 14.0 | 0.47 | the background-difference blob finder, every frame |
| `planes` | 11.2 | 0.37 | half-resolution Y and Cr for every frame |
| `background` | 6.5 | 0.22 | the per-pixel median background (built **once** per window) |
| `template` | 3.4 | 0.11 | NCC fill near release |
| `decode` | 2.4 | 0.08 | waiting on the video decoder (it runs ahead of us) |
| `link` | 1.0 | 0.03 | the tracker |
| `fit` | < 0.05 | — | the plane solve and the parabola |

Gone from this table entirely: the per-window **Vision trajectory pass** (3.2 s a window on the phone), the
second and third **decodes** of the same window (the ball detector's and the pose pass's), and the decode a
retry used to pay for again. The phone's own before-numbers, from the coordinator's Release-build bench run on
the 250 s segment: scan 101 s, Vision trajectory 3.2 s a window, ball detector 8.6–15.6 s, pose 2.7–3.3 s,
retries +2 s and +12–14 s, 163 s for 6 windows.

### Arrivals: the fast scanner against the Vision scanner

`TrajectoryProbe scan … --vision` runs both and applies the same `find_arrivals` rule to each.

| range | Vision scanner | fast scanner | agreement |
|---|---|---|---|
| 0–250 s | 9 arrivals, 39.7 s | 9 arrivals, 4.2 s | all 9, worst gap 0.16 s of file time (5 frames) |
| whole clip | 30 arrivals, 149.5 s | 30 arrivals, 43.5 s (19–27 s once vDSP landed) | 28 of 30 within 0.1 s; **166.07 → 168.53** and **833.67 → 836.13**, i.e. the same two shots seen 2.4 s of file time (0.6 s real) later |
| lost | — | **none** | |
| gained | — | **none** | |

The two late ones are the arrival *frame* moving, not a different shot; the window is 8.2 s of file time, so a
2.4 s shift still contains the flight, and both windows are analysed either way.

### The three labelled free throws

`analyze --start S --end E --time-scale 4 --hfov 48 --rim-diameter 0.4572 --fixed-g-azimuth --classical --pose`,
against `docs/footage-2026-09-13/release_labels.json`. Release error in **file** frames (1 frame = 8.3 ms real).

| window (file s) | before: release / err / g / rms | after: release / err / g / rms |
|---|---|---|
| 88.5–95.5 | 90.033 / **−3.5** / 9.46 (3.6 %) / 9.52 px | 90.033 / **−3.5** / 9.51 (3.1 %) / 7.60 px |
| 312.4–319.8 | 314.467 / **−2.5** / 9.45 (3.7 %) / 5.42 px | 314.467 / **−2.5** / 9.44 (3.8 %) / 5.47 px |
| 815.8–823.2 | 817.367 / **+0.5** / 9.42 (4.0 %) / 5.65 px | 817.367 / **+0.5** / 9.42 (4.0 %) / 5.68 px |

Releases are identical to the frame on all three, and the tracks differ by at most one detection. Through the
**session** path (different, wider windows, scanner seeds instead of Vision seeds, narrowed pose) the same three
shots come out at 90.000 (−4.5), 314.467 (−2.5) and 817.467 (+3.5) file frames, all inside ±5, and all three are
accepted by the block rule (g 2.5 %, 1.4 %, 5.8 %).

## What is left

- **Core ML is now the whole cost of a window.** The honest next step is not another throttle but a cheaper
  inference: the model's image input is flexible (299…) and the tile is handed to it at 512, so feeding a
  downscaled tile, or sweeping a 2× downscaled frame (4 tiles instead of 15), is worth measuring — against more
  than three labelled shots.
- **Two windows at a time is memory-bound, not compute-bound.** One decoded 1080p window at a 4× factor is
  ~255 MB of planes. Quarter-resolution Cr, or planes cropped to the band the ball can occupy, would let two
  lanes run inside 320 MB. The `TaskGroup` and the budget are in place; only the arithmetic says one today.
- The fast scanner reads only the upper 40 % of the frame, so it cannot seed the detector where the ball is low
  (the hands, the dribble). That is why the session path still sweeps more than `analyze` does. A second,
  coarser, whole-frame pass in the same decode would fix it, and it is the cheapest remaining win.

## Body model in the app (2026-09-14)

The per-shot body model now runs inside `ShotAnalysisRunner`, and the parts of it that iteration 2
(`docs/PHASE2-PREP.md`, "Body model, iteration 2") measured as trustworthy are shown on the shot card,
summarised on the session screen, and used by the graded coaching rules. Nothing that iteration refused
is shown: the refusals arrive as `BodyMeasure` values that are nil **with the model's own sentence**.

### Where it runs

`ShotAnalysisRunner.bodyStage`, once per window, after the detector attempt that was kept and after the
release estimate — so the body model is handed the release the analyzer already used and can never move
a ball number. A failure returns `(nil, reason)` and costs the body card only.

- **Span**: release − 1.5 s to release + 0.4 s of *real* time, i.e. the dip to the follow-through
  (`bodyLookbackRealSeconds` / `bodyTailRealSeconds`). It starts before the analysis window does, because
  the dip is usually earlier than the scanner's window opens.
- **Rate**: every 2nd frame at or above 100 fps real, every frame below (`bodyEveryNthFrameThresholdFPS`).
  At 120 fps real that is 60 Hz, and it puts a **16.7 ms floor** under every kinetic-chain lag; the floor
  is printed with the lags rather than hidden.
- **Decode**: a second, bounded one. The ball pass keeps half-resolution Y and Cr planes, which is not what
  Vision's three requests need, and the body span starts up to 1.5 s of real time before the ball window,
  so there was nothing to reuse.
- **Then**: `BodySkeletonFit.fit` (0.03 s) → `BodyKinematics.model` on the fitted timeline, with
  `transverseYawUnavailableReason` passed through from the fit. Timed as `body.vision` and `body.fit`
  through the runner's `StageTimings`, so the activity log carries both.

### Speed, measured on the Mac CLI (`TrajectoryProbe body`, Release, same span and rate the app uses)

| | t89 | t313 | t817 |
|---|---|---|---|
| frames analysed | 115 | 115 | 115 |
| Vision pass, two runs | 4.9 / 4.4 s | 5.2 / 5.0 s | 4.0 / 3.7 s |
| skeleton fit | 0.03 s | 0.03 s | 0.03 s |

**Median ≈ 4.5 s per window, against a ~3 s budget — it is over, and here is the whole bill.** Decomposed
on t89 at the same span: 2-D body alone **12 ms/frame** (1.3 s), + `DetectHumanBodyPose3DRequest`
**31 ms/frame** (3.6 s), + the hands on their 256 px release crop **34 ms/frame** (3.9 s). So the 3-D
request is 19 ms/frame — half the stage.

Dropping it gets the stage to **2.5–2.9 s**, inside the budget, and was **rejected on measurement**: the
fit uses Vision's 3-D only for the *sign* of each joint's depth (its placement is not used at all), and
without it the legs collapse into the image plane — the knee at release reads 175.6 / 173.3 / 171.1° on
the three shots instead of 158.2 / 143.3 / 156.0°, and t89's elbow moves from 136.2° to 128.9°, away from
MediaPipe's independent 136.6°. Two other levers were measured and bought nothing:
`frameAnalysisSpacing3D` at 0.1 and 0.2 s changed neither the coverage (94/115 either way) nor the time,
and trimming the lookback to 1.0 s (85 frames instead of 115) measured 3.1–3.9 s — the cost is per frame,
not fixed. For scale, the same Mac runs the existing ball stage at **6.8 s mean / 7.7 s median per window**
(`TrajectoryProbe session --limit 6`), where the phone does ~6 s.

### One change to `BodyKinematics`, and why the integration needed it

`BodyKinematicsOptions.dipIsLastTurningPoint` (default **false**; every existing test still asserts the old
behaviour, 62 tests green). The old rule takes the **lowest** frame in the lookback. That is right for a
window that opens at the dip and wrong for a 1.5 s one: over a free-throw routine the lowest hand is the
shooter still holding the ball, so the dip landed on the first frame and `dipToRelease` came back as the
length of the window — **1500 / 1500 / 1454 ms** on the three labelled shots. The new rule takes the last
frame before release at which the hand stops descending, from the same smoothed rate the set point uses:
**421 ms / no turning point / 354 ms**. Where there is no turning point inside the span the model says so
in `phases.notes`, and `ShotBodyResult` then **refuses** the number rather than publishing the window's
length. (`TrajectoryProbe body --last-turning-dip` switches it on; the app always does.)

### The three labelled free throws, as the app now measures them

`--every 2 --hfov 48 --height 1.83 --hand-focus 0.4 --last-turning-dip`, spans 84.15–91.75, 308.55–316.15,
811.35–818.95 file s of `footage/2026-09-13/IMG_1765.mov`.

| | t89 | t313 | t817 |
|---|---|---|---|
| reprojection RMS, fitted vs Vision's 3-D | 3.31 vs 61.06 px | 3.00 vs 55.98 px | 1.24 vs 37.36 px |
| elbow at release (fitted) | 136.2° | 147.3° | 162.7° |
| — the 2-D elbow, for comparison | 139.3° | 158.8° | 163.3° |
| elbow jitter at 60 Hz sampling | 2.39° | 2.17° | 1.74° |
| knee minimum, dip → release (fitted) | 108.5° | 99.3° | 103.1° |
| elbow extension peak | 786 °/s | 776 °/s | 589 °/s |
| knee extension peak | 307 °/s | 223 °/s | 224 °/s |
| dip → release | 421 ms | **refused** (no turning point in the span) | 354 ms |
| chain order | hip→knee→shoulder→elbow→wrist | shoulder→hip→knee→elbow→wrist | hip→knee→elbow→shoulder (no wrist) |
| proximal-to-distal | no | no | no |
| jump height | 0.301 m | 0.219 m | 0.309 m |
| dip depth (hips) | 27.3 px = 0.054 H = 0.088 m | 37.7 px = 0.074 H = 0.122 m | 17.0 px = 0.062 H = 0.102 m |
| head stability | 27.9 px = 0.055 H | 19.6 px = 0.039 H | 13.9 px = 0.051 H |
| hands found, release ± 0.4 s | 62 % | 79 % | 19 % |
| shooter pixel height (ankle→nose, p90) | 508 px | 507 px | 275 px |
| shoulder-line yaw | refused (line projects to 10 % of the span, an adult's is 27 %) | refused (9 %) | refused (11 %) |

The dip depth is the **hips'** lowest point before release and how far they fell to reach it (lowest at
0.80–0.87 s before release on all three), not the hands': on this shooter's free throw the hand rises
through the whole span with only a hesitation in it. The elbow jitter is higher than iteration 2's
1.43–1.57° because the app samples every 2nd frame — the difference is the sampling interval, not the fit.

### Shooter height, and the metres

`ShooterProfile` (UserDefaults, `shooter.heightCm`, optional, 120–230 cm) with `ShooterHeightRow` in the
guided flow's video step and in the session screen's Body group. **The rim ruler is never used as a body
scale** — iteration 2 measured it implying standing heights of 2.30 / 2.29 / 1.24 m on these windows. With
no stated height every metre is nil with the reason "shooter height not given", and the gate is explicit in
`ShotBodyResult.make`: without it `BodySkeletonFit` still needs *a* working scale for its numerics (a
1.80 m prior, which changes no angle), and a metre derived from that prior would be a population number
wearing a measurement's clothes.

**Metres are never pooled across setups.** `BlockSummary.metrePool` keeps only the shots whose shooter
pixel height is within 10 % of the block's median and says in `metrePoolingNote` how many were dropped and
why. On this clip t817 (275 px) would be dropped against t89/t313 (508/507 px): the camera or the station
moved mid-clip, which MediaPipe confirmed independently in iteration 2.

### What the app shows and coaches with

- `BlockRow` / `SavedShot` (all optional, so old `sessions.json` files still decode): `releaseDistance`
  (the last `TODO(BlockRow)` — the coaching card no longer re-derives the distance from θ, v, h and depth),
  `fittedElbowAtReleaseDegrees` + `fittedElbowJitterDegrees`, `elbowExtensionPeakDegreesPerSecond`,
  `kneeExtensionPeakDegreesPerSecond`, `fittedKneeMinimumDegrees`, `jumpHeightMetres`, `dipDepthMetres`,
  `dipDepthNormalised`, `bodyDipToReleaseMilliseconds`, `chainOrder` + `chainLagsMilliseconds` +
  `chainFrameFloorMilliseconds` + `proximalToDistal`, `headStabilityPx` + `headStabilityNormalised`,
  `handRateAtRelease`, `shoulderLineYawDegrees`, `shooterPixelHeight`, `bodyUnavailableReason`.
- `ResultsView`'s Body card: the fitted elbow, knee, hip and shoulder at **set, dip, release and
  follow-through** as a table, the chain order with its lags and the frame floor, dip→release, the peaks,
  jump height, dip depth, head steadiness, squareness and the hand rate — each with its value or the
  model's own reason, then the coverage, the scale sentence, the reprojection and the warnings.
- `SessionView`'s Body group: mean ± SD n of the same, the proximal-to-distal count, the metre-pooling
  note, and the 2-D camera-side angles kept underneath.
- `SessionCoaching`: all five `TODO(BlockRow)` placeholders are gone. Head stability and the chain order
  are real rows; squareness carries the *measured* refusal sentence; preparation speed compares the fitted
  knee-extension peak with Cabarkapa et al. 2023's two group means (212.9 vs 269.4 °/s) as a **B-grade**
  card line and profile row; the elbow row is now the fitted value with its jitter and the ±25° bracket
  said out loud; and `rhythmVersusSpeed` (the grade-D dip→release vs release-speed rule) prefers the body
  model's dip→release, which recovers the dip on windows where the raw 2-D wrist does not.

### What is left

- **The stage is 1.5 s per window over budget and the 3-D request is the whole of it.** The fit needs only
  the *sign* of each joint's depth. A cheaper source of that sign — a one-frame 3-D call whose ordering is
  carried forward by the smoothness term, or ordering inferred from limb foreshortening — would buy back
  ~2 s per window without the accuracy loss that simply switching it off costs.
- **t313 has no dip inside 1.5 s of real time.** Its hand rises monotonically through the span, so the
  number is refused. Whether the real dip is at 1.7 s or whether this shooter simply has no hand dip is not
  settled; a 2.5 s lookback on one window would answer it, at about 2 s more of Vision.
- **t817's 19 % hand rate is a filming problem, not a crop problem** (iteration 2 swept the crop size and
  256 px was already the optimum at both subject sizes). It is the 275 px shooter: film closer, or longer.
- The per-shot body card shows numbers only. An overlay of the fitted skeleton on the release frame is the
  obvious next thing, and `BodySkeletonFitResult.timeline` already carries everything it needs.

## Ball spin (2026-09-14)

The ask: a shooter says *"the rotation on my shot is diagonal"* and wants the app to measure it.
`Packages/ShotVideo/Sources/ShotVideo/SpinTracker.swift` measures spin **rate** (rev/s) and **spin-axis
direction** from the ball's own surface texture — seams, logo, panel lines — over consecutive frames.
`TrajectoryProbe spin` drives it (`SpinCommand.swift`, one line added to `Probe.swift`'s dispatch).
Nothing else was touched.

### Method

A ball in flight is a rigid sphere, so every surface point moves with `v = ω × p`. Under the weak
perspective a ball a few metres away satisfies, a surface point at normalised disc coordinates
`(x, y)` — x right, y down, in units of the apparent radius, `z = √(1 − x² − y²)` — has image velocity,
in the same radius units with ω in rad/frame:

```
fx = −ω_y·z − ω_z·y
fy =  ω_z·x + ω_x·z
```

Three unknowns, linear, two equations per matched surface patch. `ω_z` is a plain in-plane rotation of
the disc; `ω_x` and `ω_y` push texture *across* the disc, strongest at the centre and vanishing at the
limb. So enough correspondences inside the disc fix the whole 3-D angular velocity — rate *and* axis —
from one camera, with no depth and no ball model beyond "sphere". The pipeline:

1. **Resample.** Ball-centred Catmull-Rom crops at native scale and upsampled so the radius is ~112 px.
   A validity mask marks patch pixels that fell outside the frame, so blocks near the edge are dropped
   rather than matched against replicated pixels.
2. **Remove the lighting.** Subtract a box-blurred copy (blur radius ≈ R/4) to kill the shading gradient,
   then subtract the **per-pixel temporal median** of the centre-aligned stack. That median is precisely
   the part of the ball's appearance that does not rotate: the shading and the **specular highlight**.
   Left in, the highlight drags every match toward zero displacement and produces a confident-looking
   spin of ≈ 0 — the single most dangerous failure mode here. `staticStructureFraction` reports the split.
3. **Match.** Zero-mean NCC block matching on a grid inside 0.8 R, coarse-to-fine (4× decimated search,
   then a ±6 px refinement, then a parabolic sub-pixel peak). A block whose second correlation peak
   rivals the best is ambiguous and is thrown away; the ambiguity test runs on the *wide* coarse search
   only, because inside the narrow refinement window the surface is one broad lobe by construction.
4. **Fit.** Tukey-biweight IRLS on the three unknowns, with the normal matrix's condition number by
   Jacobi. `refineTranslation` (two extra unknowns for ball-centre error) is **off** by default: on a
   disc a uniform shift is nearly degenerate with ω_x, ω_y — z only runs 1 → 0.6 over the usable disc —
   and turning it on raises the condition number from ~2 to ~220 and measurably *worsens* the axis.
5. **Warp and refine.** A block matched rigidly across a rotating sphere reads systematically short: the
   texture inside it is compressed as it swings toward the limb, and the best rigid alignment of a
   compressed target sits inside the true displacement. One pass that warps the next frame back by the
   estimated rotation and re-matches removes most of it — rate bias **−10 % → −3 %** on the synthetic.
6. **Report against the flight.** With flight direction `t` and camera up `u`, the pure-backspin axis is
   `ê_b = t × u` (horizontal, perpendicular to the flight plane), `ê_t = t` is rifle spin and
   `ê_v = ê_b × ê_t` is side spin. Outputs are `tiltFromBackspinDegrees` (0° = pure backspin — the number
   the shooter means by "diagonal"), signed `sideTiltDegrees` and `rifleTiltDegrees`, and
   `backspinFraction`. For a side-on camera the backspin component *is* the in-plane image rotation ω_z,
   the best-conditioned of the three; the side and rifle components come from the across-disc flow and
   are the weaker ones. Without a 3-D flight direction the image track is used and assumed parallel to
   the image plane, and a warning says so.

Refusals (CLAUDE.md rule 1 — nil with a reason, never a fabricated number): texture SNR below
`minDynamicSNR`; fewer than `minPairsFitted` **or** under 60 % of frame pairs fitting; rate scatter above
35 % of the rate across pairs (a ball's spin barely changes in flight, so a rate that is not repeatable
is not a measurement); zero angular velocity; no flight direction. Zero network calls.

### Numbers — synthetic (`TrajectoryProbe spin any --self-test`, 24 frames)

A textured sphere with a known ω, rendered with Lambertian shading, a camera-fixed specular highlight,
box motion blur, Gaussian noise and 0.4 px of centring error in the track handed to the estimator.

| case | truth | rate measured | axis error | tilt measured |
|---|---|---|---|---|
| 60 px ball, 120 fps, pure backspin | 2.50 rev/s, 0° | 2.43 (−2.9 %) | 0.7° | 0.7° |
| 60 px, 120 fps, diagonal 30° | 2.50, 30° | 2.42 (−3.2 %) | 2.0° | 31.9° |
| 60 px, 120 fps, diagonal 55° | 3.00, 55° | 2.96 (−1.3 %) | 0.8° | 55.7° |
| 60 px, 240 fps, diagonal 30° | 2.50, 30° | 2.32 (−7.3 %) | 0.7° | 30.0° |
| 90 px, 240 fps, diagonal 30° | 2.50, 30° | 2.40 (−4.0 %) | 2.3° | 29.1° |
| 60 px, 120 fps, 360° shutter blur | 2.50, 30° | 2.45 (−2.2 %) | 1.4° | 31.3° |
| 60 px, texture contrast × 0.06 | 2.50, 30° | **refused** (7/23 pairs fitted) | — | — |

So the method is sound at 60 px and 120 fps: rate to within ~5 % and axis to within ~2°, and it refuses
when the texture is taken away. The residual few-per-cent low bias is foreshortening that one warp pass
does not fully remove; a second pass is available (`refinePasses`).

### What it measured on footage/2026-09-13/IMG_1765.mov — nothing, and that is the honest answer

**Spin is not measurable on this clip.** All three labelled free throws refuse, 24 frames from release:

| shot | window | ball | pairs fitted | verdict |
|---|---|---|---|---|
| shot05 | 90.33 s file | 78 px across | 1 / 23 | refused |
| shot11 | 314.83 s file | 80 px across | 7 / 23 | refused |
| shot24 | 817.53 s file | 48 px across | 5 / 23 | refused |
| shot11, ball still in the hands | 311.50 s file | 134 px across | 5 / 9 | refused |

The cause is visible before any algorithm runs. Crop the ball, upsample 6–8× and look: the ball is a dim
(mean luma ≈ 70/255), low-contrast, motion-blurred sphere under a single hard floodlight. **There are no
seams in the image at all** — not at 78 px in flight, and not at 134 px held in the shooter's hands
before release, which is the largest and sharpest the ball ever is in this clip. The only strong
structure is the specular highlight arc at the upper left, and it stays put frame after frame because it
belongs to the lamp, not the ball. `TrajectoryProbe spin … --strip out.png` renders the evidence: the top
row is the crops, the bottom row is what the matcher sees — crescent-shaped limb residuals from
centring jitter around a blank grey disc.

Two cautions about the diagnostics for whoever picks this up:

- **`dynamicTextureSNR` reads 34–50 on this footage, and it is lying.** It is measured on the inner
  0.55 R specifically to keep the limb out (measured to 0.8 R it read 35–50 on a ball whose interior is
  blank), but the pytrack centres jitter by a pixel or more, so the silhouette still slides inside the
  crop and registers as "moving structure". The SNR gate is **not** what refused these shots — the
  cross-pair consistency gates did. The SNR number should be trusted only once the ball centre is good
  to a fraction of a pixel.
- Frame-to-frame luma differencing over 314–316 s shows ~11 % of frames in this 4×-slowed file are exact
  duplicates of their predecessor. The rest are genuinely distinct, so the clip really is 120 fps of
  distinct content, but a spin pass should skip the duplicated pairs rather than fit zero rotation to them.

### Limits, and what a better clip would buy

- **Texture is the binding constraint, not resolution and not frame rate.** 2–3 rev/s at 120 fps is
  6–9° per frame, which is a 6–12 px arc on a 78 px ball — easily enough motion to measure. There is
  simply nothing on the ball to measure it *with* at this exposure.
- **A 240 fps clip from behind the shooter would add three things.** (a) Half the rotation per frame —
  3–4.5° — which halves the texture displacement and makes the correspondence easier, at the cost of a
  shorter exposure and so a dimmer ball, which is only a win in good light. (b) From behind, pure
  backspin turns the axis *along the view direction*, so the spin becomes a plain in-plane rotation of
  the disc: that is the ω_z channel, the best-conditioned one, and side-spin tilt then shows up as the
  well-separated across-disc flow instead of the other way round. This is the single biggest geometric
  improvement available and it costs only a camera position. (c) Closer framing for a 150–200 px ball,
  where the seams are several pixels wide.
- **Filming requirement, in one line:** daylight or a bright gym, a shutter no slower than ~1/500 s, the
  camera behind or in front of the shooter rather than side-on, and a ball whose seams contrast with its
  panels. Without the first two, no method recovers spin from this hardware.
- The estimator also wants a better ball centre than the current detector gives. Centring error does not
  cancel — with translation unknowns disabled it converts directly into rate error.

### API

```swift
SpinTracker.measure(frames: [SpinGrayImage], track: [SpinSample],
                    options: SpinOptions = SpinOptions()) -> SpinResult?
```

`frames[i]` is the image `track[i]` was measured in (a crop is fine — `SpinGrayImage` carries its origin,
and `SpinGrayImage.luma(from:cropX:…)` builds one from a `CVPixelBuffer`'s luma plane). `SpinSample.timeSeconds`
is **real** seconds: divide file seconds by the slow-motion factor first. The return is nil only when the
input cannot support any statement at all (fewer than three usable samples); every other refusal comes back
as a `SpinResult` whose `rateRevPerSecond` / `axisCamera` are nil next to `rateUnavailableReason` /
`axisUnavailableReason`, alongside the diagnostics that justify it: `dynamicTextureSNR`,
`staticStructureFraction`, `pairsAttempted` / `pairsFitted`, `medianInliers`, `medianResidualPx`,
`rateScatterRevPerSecond`, `confidence`, `warnings` and the `perPair` fits. `SpinTracker.patchStrip`
exposes the intermediate patches so a caller can render the strip and *look* at what the matcher is being
asked to track, and `SpinTracker.renderSyntheticBall` is the known-ω sphere the self-test validates against.

```
TrajectoryProbe spin <clip.mov> --track-json <pytrack shot.json> --from <file s>
                   [--count 24] [--time-scale 4] [--strip out.png] [--json out.json]
TrajectoryProbe spin any --self-test
```

## Shot doctor screens (2026-09-14)

`App/Sources/{ShotDoctorModel,AskView,DiagnosisView,PlanView}.swift`, with a Start row ("Ask about
your shot") and a Progress row ("Diagnosis and plan") in `ContentView`, a link in `HistoryView`, and
`ActivePlan` persistence in `SessionStore`. Builds clean for `generic/platform=iOS Simulator`.

The App layer computes nothing. `ShotDoctorModel.records(from:)` is the whole bridge — saved shots
to `[ShotRecord]`, degrees to radians, `DoctorSpot(rawValue:)` off `ShotSpot` — and every sentence,
threshold and floor on screen comes back from the package. Where the engine returns nil the screen
prints the engine's own reason; nowhere does the UI substitute a number, a default or a target.

`ActivePlan` (`App/Sources/SessionStore.swift`, its own `active-plan.json`) records which fix, which
spot, which session the baseline came from, that session's value for the fix's `PassMeasure` and its
accepted-shot n, then the follow-up and retention session ids once those sessions exist. The pass
check and the retention rule are `FixLibrary.check` / `.retention` verbatim; `Bool?` nil is rendered
"cannot tell yet" and is never styled as a failure.

### What is left

- **The plan's baseline value is read with `FixLibrary.check(…, followUp: baseline)`** and only its
  `baselineValue` is used. A public `FixLibrary.value(_:_:spot:scope:)` would make that honest
  rather than merely correct.
- **Six hypotheses still return a camera position instead of a number.** `filmThis` is shown as a
  line of text; it is not yet a one-tap "film this next" that sets the capture screen up for the
  behind-the-shooter or close-form clip.
- **The per-shot miss sentence is not on the shot list yet** (`DESIGN-SHOT-DOCTOR` §9's sixth
  surface). `ResultsView`/`BlockSummary` is where it belongs, and `MissDecomposition.sentence`
  already carries it.
- **Retention uses the next two saved sessions at the spot, whatever their dates.** The design's
  rolling three-session window is not implemented; two sessions saved on the same day would be read
  as a follow-up and a retention.

## 3-D form model (2026-09-15)

A shot's fitted skeleton (`BodySkeletonFit`) is a *shot*. `Packages/ShotGeometry/Sources/ShotGeometry/FormModel.swift`
turns it into a **form**: the same joints in the shooter's own frame, on a phase-normalised clock, so two
shots of different tempo lie on top of each other — and then averages many of them into the mean form of a
block, with the spread around it. Foundation + simd only, 36 tests
(`Tests/ShotGeometryTests/FormModelTests.swift`), whole package 129 green.

### What a form is

| | |
|---|---|
| **Frame** | origin the **mid-hip at the set point**, **x** toward the rim along the shot plane, **z** up, **y** = z × x. Moving a whole shot moves nothing in its form (there is a test): it compares shapes, not where the shooter stood. |
| **Forward axis** | `FormFacing`: `.rimDirection` when the caller has the shot plane, `.rimImageColumn(rimU:)` when only the rim's image column is known (x is then the camera's horizontal, signed toward the rim — honest on a near-side view, and the note says so), `.cameraAxes` when nothing is known. |
| **Unit** | metres **only** with a stated standing height. Without one every length is divided by the shooter's own fitted ankle-to-nose span and the unit is `shooterHeights`, with `unitNote` saying it. No metre is ever derived from the 1.80 m prior the fit uses for its numerics. |
| **Clock** | set 0, dip 0.35, release 0.75, follow-through 1, 41 samples so every phase lands exactly on a sample index. **The fractions are a convention, not a measurement** — the real durations travel beside them (`FormPhaseDurations` per shot, `FormTempo` per block, milliseconds with their spread), and every sample also carries `dt`, its real seconds from release. |
| **A missing phase** | is never interpolated across. The segment gets **no samples** and a `FormGap` with the reason. |
| **The far side** | a joint the tracker saw on < 20 % of frames is **not** taken from the fit (with no pixels of its own it is held up only by bone lengths and smoothing). It is mirrored across the shooter's own mid-line and flagged `inferredBySymmetry` — the viewer draws it dashed — or, with no mirror to borrow from, refused outright in `refusedJoints` with the reason. |

`FormModel.build` averages accepted shots into per-phase-time mean joint positions, per-axis 1σ
(the variability ellipsoid), mean ± SD of all nine joint angles over normalised time, the tempo, and
per-joint seen fractions. Angles are computed **per shot and then averaged**, never off the mean skeleton
— averaging positions shortens bones. Two comparisons: `model.compare(shot:)` (per joint, per phase, the
deviation in the block's own SDs) and `FormModel.compare(a, with: b)` (block against block in the pooled
SD, for progress). Everything is `BodyMeasure`-style value-or-reason; where a spread cannot exist the
sentence says why — including *"the body frame's origin is the mid-hip at the set point, so the hips have
no spread there by construction"*.

**Export.** `FormJSON` — compact (no pretty printing, positions rounded to 4 dp on the way in), versioned,
and a form from a version this build does not know is refused rather than guessed at.

### In the app

- `ShotBodyResult.form` / `.formUnavailableReason`, built in `ShotBodyResult.make` from the same fitted
  skeleton and the **same vetted phase times** as every other body number — a dip this result refuses
  (the edge-note one) is refused to the form too, so the normalised axis can never be anchored on a
  number the body card would not print. `ShotAnalysisRunner` passes the rim's image column and nothing else.
- `SavedShot.form` — kept for **accepted** shots only (that is the population a block mean may be built
  from, and one form is ≈ 15 kB). Optional, so every older `sessions.json` still decodes.
  `SavedSession.formModel` and `SessionStore.sessionsWithForms(spot:excluding:)` are what the Progress
  screen needs to build `FormModel`s across sessions per spot.
- `App/Sources/FormModelView.swift` — SceneKit. Joints as spheres, bones as capsules, **dashed and thin**
  for symmetry-inferred ones, 1σ ellipsoids on a toggle, a set → dip → release → follow-through scrubber
  labelled with the real seconds from release, play/pause **at the block's real tempo** (the clock is
  stepped in real seconds and mapped back to normalised time, so a slow dip plays slowly), the block's
  mean form overlaid on the selected shot, and a "compare with an earlier session" picker.
  Reached from the session screen (the block's mean form) and from a shot's results (that shot against the
  block). Screen visits and comparisons go to `ActivityLog` as `screen name=form` and `form.compare`.

### Measured: five accepted free throws of the 240 fps in-app recording

`03D7D2BF…mov`, true 240 fps, hFOV 73.83° from the sidecar, `rim_240.json`. The session pass accepted
**18 of 26** windows with g_fit 9.75–10.01 (0.5–2.1 % error), which is the best gravity this project has
measured; five of them were run through `TrajectoryProbe body --form-json` (span release − 1.5 s →
release + 0.4 s, every 2nd frame = 120 Hz, `--last-turning-dip`) and pooled with `TrajectoryProbe form`.

- **Every joint was seen.** 99.7–100 % of frames for all 14, on all five shots: nothing was inferred by
  symmetry on this footage, because a 73.83° lens at this distance keeps the far side in view. The dashed
  path is exercised by the tests, not by this clip.
- **Tempo**: set → dip **8 ± 0 ms**, dip → release **320 ± 43 ms**, release → follow-through **14 ± 2 ms**
  (n 4), whole shot **358 ± 25 ms** (n 4). The 8 ms is **two sampled frames at 240 fps — the quantisation
  floor**: on this shooter's free throw the set point and the last turning point of the hand are the same
  instant, so the first 35 % of the normalised axis spans one frame pair, and the last 25 % about 14 ms.
  The axis is still the right thing to compare two shots on, but read the dip → release stretch: it is
  where 90 % of the real time is.
- **Variability (1σ, shooter heights, RMS over the three axes)**: hips 0.002–0.005 (the frame's origin is
  the mid-hip at the set point, so this is near zero there by construction), neck 0.005–0.009, shoulders
  0.007–0.013, right (shooting) elbow 0.022–0.029, left elbow 0.014–0.048, wrists 0.023–0.075, knees
  0.018–0.062, ankles 0.019–0.076. **The torso repeats, the ends of the limbs do not** — and the ankles'
  spread is as large as the wrists', which on a free throw is a stance that is not being set the same way
  twice (or the feet at the bottom of the frame; the fit's own edge-coverage note is the place to check).
- **Angles, set/dip → release** (mean ± SD across the five shots): shooting elbow **80.2 ± 13.2° →
  157.7 ± 10.3°**, shooting shoulder elevation **121.0 ± 1.1° → 148.3 ± 3.0°** (the most repeatable thing
  in the block), shooting knee 122.6 ± 21.8° → 152.8 ± 14.0°, trunk lean from vertical 8.5 ± 1.0° → 6.1 ± 2.7°.
- Shot 1 against the block: worst deviation **1.39 SD** (the nose at the set point); nothing over 2 SD.
- One form is **15 kB** of JSON; a block of five is 41 samples × 14 joints of mean and 1σ.

Rendered from the model's own JSON (the same file the viewer reads):
`scratchpad/form_model_ft240.png` — four phases, mean skeleton in grey with 1σ ellipses, shot 1 in orange.

**Open.** (1) No standing height was given, so this block is in **shooter heights**; `--height` (and
`ShooterProfile`) switches the whole thing to metres with no other change. (2) The set → dip and
release → follow-through segments are at the timing floor on this footage — the phase detector, not the
form model, is what to look at next. (3) The Progress screen still has no link to a cross-session
`FormModel`; everything it needs is stored.

## Coordinator changes, cycle 1 (2026-09-15)

- **Saved sessions**: the spot must be chosen on save (no default), a duplicate save of the same clip is flagged, and a
  saved session can be edited (spot, note) or deleted from Progress (`EditSessionView`; long-press also moves it).
  `ShotSpot`/`DoctorSpot` gained `collegeThree` (6.75 m). The shooter's four sessions were relabelled on the phone
  by pushing `sessions.json` over USB (backup in the scratchpad).
- **Lens**: `LensSelection` falls back to a clip-calibrated field of view when ≥ 8 clean shots agree on one scale factor
  and no phone format is within 3° (Camera.app's 240 fps export measures ≈ 51°); provenance states it.
- **Analysis wait**: `SessionModel.estimatedSecondsRemaining` (median window time × remaining) and `lastMeasured`;
  `GuidedSessionView` shows "about N min left" and a last-shot line (verdict, speed, angle, cm vs the make band).
- **Home**: a last-session glance card (accepted, release m/s ± SD, cm past the front rim, inferred makes, active plan).
- **Docs**: `docs/BIOMETRIC-SCHEMA.md` v1 (the contract for the future 3-D skeletal/mesh model),
  `docs/DESIGN-PRACTICE-MODE-2026-09-15.md`, `docs/DESIGN-LIVE-FEEDBACK-2026-09-15.md`.
- **Phone**: Release build with all of the above + practice mode + the 3-D form viewer installed 2026-09-15 ~07:00 UTC;
  benchmark on it: 250 s segment 85 s (probe+scan 41 s, 6–8 s per window at 120 fps including the body stage).

## BodyShot export (2026-09-15)

- **Schema in code**: `Packages/ShotGeometry/Sources/ShotGeometry/BodyShotExport.swift` — `BodyShot` and its parts
  (`BodyShotFrame`, `BodyShotSkeleton`, `BodyShotTiming`, `BodyShotEvents`, `BodyShotSummary`, `BodyShotMeasure`),
  `version` 1, custom decoder that refuses any other version, `encoded()`/`decode()` (sorted keys, compact), and
  `BodyShot.make(rawTimeline:fit:model:…)` which builds the record from the tracker's raw timeline, the skeleton fit
  and the kinematic model. Absent joints are absent keys; a metre appears only with a stated height (else unit
  height = the fitted standing height, `scaleProvenance = unitHeight`); raw Vision joints are re-expressed in the
  schema's camera frame (x right, y down, z forward); fitted joints are in the body frame (origin mid-hip at the set,
  x toward the rim's image column when known, z up). Deviations from the doc, all additive: `hands` is an array with
  a `chirality` field (Vision does not always report a side); per-joint σ is omitted (the fit only publishes the
  mid-hip's median depth/lateral σ, carried on `skeleton`); `trunkLean`/`neckFlexion`/`headYaw`/`headPitch` tracks
  are `unavailableReason` (the model reports them as summaries) with the summaries in `notes`;
  `timing.quantisationFloor` is `everyNthFrame / fps`, the honest floor when frames are decimated.
  Tests: `Tests/ShotGeometryTests/BodyShotExportTests.swift` (round-trip, absent joint stays absent, no metres
  without a height, version refusal, 200 frames with two hands = 1.07 MB ≤ 2 MB).
- **App**: `ShotBodyResult.bodyShot` (new optional field, built in `ShotBodyResult.make` from the same fit/model/
  vetted phases); `ShotAnalysisRunner.bodyStage` passes the raw timeline and the frame format into `make` (only
  change there). `App/Sources/BodyShotWriter.swift` writes `Documents/ArcLab/body/<clip name>/<shotID>.json`
  atomically on a utility queue for accepted shots (hook in `SessionModel`'s success branch), fills `source` with
  device/build/lens provenance (`SessionModel.hfovProvenance`: sidecar for in-app recordings, assumed otherwise,
  gravity-calibrated after a lens repass), logs `body.export` {path, bytes, frames}, keeps the newest 500
  (`list()`, `delete(olderThan:)`, `totalBytes()`). The session directory is the clip's name because a session has
  no UUID until it is saved; a later move to `<sessionID>` is a rename.
- **CLI**: `TrajectoryProbe bodyexport <clip> --start --end --release-time [--hfov --height --every --out]` runs the
  same stage on the Mac and writes the same JSON (`BodyExportCommand.swift`; one dispatch line in `Probe.swift`).

## Form-clip mode, validated (2026-09-15)

Ground truth for the body-only scanner (`FormClipScanner`) is the rim-based session on the 387 s in-app
240 fps free-throw recording (`03D7D2BF-….mov`, hFOV 73.83, `RimFinder` → `scan` → `session`:
`scratchpad/fc_truth_session.txt`, releases in `truth_all.txt`). Frames were exported at every disputed
event and looked at. **What is on the clip:** 31 rim arrivals = 23 free throws from the line (22 the ball
model accepts + t169.9, whose flight failed gravity because the ball hit something), 5 quick tips from
under the rim (ball-side release angles 75–96°, flights 0.2–0.8 m; t68.3 was thrown with the *left*
hand), and 3 that are not shots at all (t6.7 nobody in frame, t313.0 a dribble, t381.7 walking to the
camera). The clip also holds catches, holds at the chest, walks with the ball and a pick-up off the floor.

**Before** (the pattern the phone ran: a wrist rise of ≥ 0.55 torso spans, one per 3 s): 36 windows on
the desktop, 40 on the phone — the 23 free throws, the 5 tips, the catch, and 8 non-shots; set 130–170 ms
before the apex; "left hand" from the elbow-confidence camera-side vote (8892 confident left elbows
against 8702 right on a right-handed shooter filmed from his right).

**After**, on the same 30 Hz sample series (`--use-series`, pure, no Vision):

| gate (all in the shooter's own torso spans, 30 Hz) | measured on the clip |
|---|---|
| high point ≥ 0.35 above the shoulder line | free throws 0.80–0.98; dribbles/holds/walks −0.66…+0.07 (18 refused) |
| extension held ≥ 0.3 s above half the apex height | free throws > 1 s; catch 200 ms, tips 100–200 ms (6 refused) |
| set = last ≥ 80 ms run with \|rate\| ≤ 8 % of the drive's peak (iteration 3's rule), drive set→apex ≤ 1.0 span | the overhead catch at t70.5 held 100 ms at the waist then reached 1.6 spans (refused); every free throw drives 0.35–0.5 |
| set shots only (`requireSetPlateau`, **now on by default**, toggle on the screen) | 23/23 free throws have a 333–600 ms plateau; the tips have none |

Result: **23 of 23 free throws found, 0 false positives, 28 refusals each carrying its reason** (listed
on the screen). The 5 tips are refused, by design: a form clip pools the set shot's body model, and
"set shots only" off reports them with *no set position* on the card. Shooting side: **right**, by the
extended-wrist rule on 22 of 22 shots that showed both wrists; the camera-side elbow count is printed
but no longer decides anything, and with no vote the side is *unknown*, not guessed.

**Release instant**, `--body --every 2` (120 Hz body pass), against the ball-flight release, in file
frames of 4.17 ms: wrist apex n 23, mean −0.58, SD 1.31, **worst 3.04 frames (12.7 ms)** — every shot
inside the ±25 ms target. The hand-seeded ball track's "left the hand" frame was within 3 frames on 15
of 20 and 5–18 frames off on five, each of those 17–79 ms from the apex; the ball-to-apex gate is now
**15 ms** (was 100), after which every one of the 23 releases is within **±3 frames** (ball ×12, worst
2.1 frames; apex ×11, worst 3.0). `wristApexSigma` is the measured worst case, 13 ms (was 26).
Peak wrist velocity sits 17 ± 2.4 frames early and stays a fallback of last resort.

**Set timing.** The 30 Hz scanner dates the set 184 ± 14 ms before the release with a 433 ± 68 ms plateau
(n 23); the 120 Hz body model on the same five shots iteration 3 reported says 221–459 ms and 133–400 ms.
The scanner's set is a candidate only — `FormClipModel.measure` passes the release, and `BodyKinematics`
re-reads the set at full rate — so the card's number is the model's.

**Simulated close-up** (`--crop 3.0 --crop-windows 5`, the frame re-encoded around the shooter): the body
needs 456–464 rows, so the achievable zoom on a 1080-row frame is **2.33–2.37×** (the requested 3× is a
cap). Full frame vs crop, five windows, every 2nd frame: seen 99.3–100 % vs 100 % on all eight joints;
2-D jitter median 0.78–0.85 px vs 0.82–0.91 px (0.25–0.29 % of the shooter's height either way); 3-D body
68–103 vs 71–94 of 229 frames; hands at release 99–100 % vs 100 % (three windows re-run after the
crop-clock fix below). A re-encoded crop adds no pixels, so this is the expected null result: the crop
changes nothing the body model reads, and the gain a *real* 3–4 m clip gives (≈ 3× the pixels on every
limb) is not measurable from this footage. `CropExport` re-zeroes the clock at the window's first frame;
the CLI's crop row now moves the apex onto that clock (the first run reported 0/0 hands for that offset).

**App.** `FormClipModel.setShotsOnly` (default on) → `FormClipScanOptions.requireSetPlateau`; refused
high points are listed under the scan with their reasons; the scan footer states the rule and what the
scan needs (whole body, shoulders, hips and wrists, ≥ ~60 px of torso). Saves go through
`SessionStore.saveFormClip` with `formClip: true`; `sessions(at:)`, `pooled(at:)`, the doctor's records,
the progress charts and the 30-shot floor all read `sessions(at:)` and so never see a form clip; every
ball field on a form-clip `SavedShot` is nil with *form clip: no rim in frame* and `gFit` is NaN. Builds:
`swift build -c release` (ShotVideo) and `xcodebuild … ArcLab … iOS Simulator` both clean.

**Not validated:** the 433 s Photos free-throw clip the phone scanned (73 windows against 48 arrivals) is
not on the Mac; the same rules apply to it but its numbers are not measured here.

## Tracking at 240 fps (2026-09-15)

The shooter's first true-240 fps in-app recording — `03D7D2BF-2056-4AFE-948C-4D615953A49B.mov`, 386 s,
1920×1080, **239.978 fps measured**, `videoFieldOfView` **73.83°** from the sidecar, free throws from the
side, `timeScale` **1** — came back from the phone with the clock right and the block wrong: 28 windows,
16 accepted, gravity median 9.97 m/s², but release **57.6 ± 13.5°**, entry 46.5 ± 16.1°, speed
6.95 ± 0.70 m/s, residual 5.3 ± 8.1 px, and rejections whose reason was "the fitted arc misses the tracked
ball by 52–98 px". The same shooter at 120 fps gives 49.9 ± 1.8° and 6 ± 1 px.

Two separate things were wrong, and only one of them was the tracker.

### 1. Every gate in the tracker is now a real quantity, converted once from the capture rate

`BallDetectorOptions` no longer holds a per-frame number anywhere. A gate is a **speed** (ball diameters per
real second), a **duration** (real seconds), a **rate** (Hz), or a dimensionless factor, and one small type,
`FrameRates`, turns all of them into file frames from the clip's **capture rate** = `file fps × timeScale`:

| option (real units) | at 120 fps | at 240 fps | what it gates |
|---|---|---|---|
| `maxLinkDiametersPerSecond` 240 | 2.0 D/frame | 1.0 D/frame | how far the linker may jump |
| `extendBackDiametersPerSecond` 180 | 1.5 D/frame | 0.75 D/frame | backward extension into the hands |
| `gateGrowthPerSecond` 18 | 0.15/frame | 0.075/frame | how the gate opens while frames are missed |
| `maxGapSeconds` 0.05 | 6 frames | 12 frames | when the track ends |
| `maxOffframeSeconds` 1.0 | 120 | 240 | survival above the top of the frame |
| `historySeconds` / `minimumHistorySeconds` | 10 / 6 | 20 / 12 | the parabolic predictor's window |
| `extendBackSeconds` 1/3 | 40 | 80 | how far back into the hands |
| `bodyExclusionDelaySeconds` 4/120 | 4 | 8 | when the shooter's box starts excluding blobs |
| `templateReachSeconds` / `NeighbourSeconds` | 25 / 4 | 50 / 8 | the NCC fill near release |
| `bounceMinimumTrackSeconds` / `bouncePastApexSeconds` | 12 / 6 | 24 / 12 | the bounce cut |
| `freeFlightBreakSeconds` 3/120 | 3 | 6 | the free-flight cut |
| `coreMLInferenceRateHz` 120 | every frame | every 2nd | the model on a tracked frame |
| `coreMLGlobalSweepRateHz` 60 | every 2nd | every 4th | the whole-frame sweep |
| `coreMLGapSeconds` / `…SecondsAfterLock` / `…StaleWidenPerSeconds` | 8 / 45 / 3 | 16 / 90 / 6 | the tile's aim |
| `maxSeedsTried` 40 | 40 | 80 | a compute budget that has to cover the same real time |

`timeScale` is the file's slow-motion factor; `nil` means "the caller did not say" and the gates fall back to
the 120 fps numbers, so no existing caller's track moved by the option being added. `TrajectoryProbe session`
and `ShotAnalysisRunner` both set it. `--legacy-rates` switches it off, which is the before/after below.

**Measured, and this is the honest result: at 240 fps the frame-rate conversion buys speed, not accuracy.**
Whole clip, same binary, minutes apart:

| | `--legacy-rates` (per-frame values as tuned at 120 fps) | frame-rate aware |
|---|---|---|
| accepted | 23 of 31 | 23 of 31 |
| release, the free throws | 50.95 ± 1.60° | 50.90 ± 1.56° |
| fit residual | median 1.45 px | median 1.40 px |
| per-window | median 9.90 s | **median 4.33 s** |

and on the first 160 s (13 windows) run back to back with nothing else on the machine:

| | frame-rate aware | `--legacy-rates` |
|---|---|---|
| per-window median | **5.78 s** | 7.93 s |
| Core ML, total / per window | **10.63 s / 0.82 s** | 54.84 s / 4.22 s |
| accepted | 10 of 13 | 10 of 13 |

So the loose gates were costing **5.2× the inference** and roughly twice the window time; they were not what
put 13.5° of spread on the phone's block. **The probe does not reproduce that spread at all** — not before
the change and not after. What does explain it is below.

### 2. The block rule cannot tell a free throw from a ball thrown up at the rim from underneath

The fast scanner finds **31 arrivals** in this clip. They are not 31 free throws: **22 free throws**, **six
balls thrown up into the ring from directly under the basket**, one shot from close range, one window at the
start with almost no ball, and one at the end with the shooter walking past the camera and no ball at all.

`ShotAcceptance.evaluate` asks for gravity within 8 %, release height 1.6–3.3 m, speed 4.5–11 m/s, depth
past the front rim −0.6…1.0 m and residual ≤ 25 px. A ball tossed up from under the rim satisfies every one
of them. One does: shot 30 at 372.8 s, release **85.0°**, entry 78.4°, 5.12 m/s, released **0.25 m** from the
rim centre, gravity 9.82 (**0.1 %** — the measurement is right, it is just not a shot from a spot). Its
overlay shows the shooter standing under the basket and the arc running into the ring, where the ball
rattles; that rattle is the whole of its 24.3 px residual.

| over the accepted rows | release | entry | speed | residual |
|---|---|---|---|---|
| all 23 | 52.38 ± 7.27° | 40.69 ± 8.54° | 7.12 ± 0.44 m/s | median 1.40 px |
| the 22 free throws (released > 2 m from the rim) | **50.90 ± 1.56°** | **38.98 ± 2.39°** | **7.22 ± 0.07 m/s** | **median 1.40 px, max 3.7 px** |

One contaminating row moves the block from 1.6° of spread to 7.3°. The phone accepted 16 rows: twelve free
throws at ~50° plus four of these throws at ~85° would read **58.8 ± 15.2°** — against the phone's reported
**57.6 ± 13.5°**, and the same arithmetic on entry gives 48 ± 17° against its 46.5 ± 16.1°. That is not proof,
but it is the only explanation on offer that fits all three of the phone's numbers, and the tracker on this
Mac fits none of them.

**The fix is a minimum release distance in `ShotAcceptance` (and the probe's `plausible` mirror).** Every
free throw in this clip is released 4.15–4.28 m from the rim; every one of these throws is under 0.8 m; the
nearest spot in any plan is the free-throw line at 4.2 m. It was **not** made here: `BlockSummary.swift` is
not part of this task, and it changes what the app calls a shot, which is a product decision. Until it is
made, a 240 fps block that contains put-backs will read 6–8° high with three to five times the spread.

### Core ML: run the model only where a cheap motion candidate is ambiguous or absent

Both gates live in `BallDetector.decodeWindow` and both were checked against the three labelled 120 fps free
throws before being kept.

- `coreMLSkipWhenMotionAgrees` (on, **above `referenceFrameRate` only**). The box is only ever asked *which*
  moving blob is the ball — the hybrid placement takes the blob's own centroid. Once the ball is locked on,
  if `MotionProbe` (the sixteenth-area background difference that already runs every frame to aim the tile)
  puts a single ball-sized moving blob within 0.75 D of the linker's own prediction, that question is already
  answered for free. Confining it to rates above 120 fps means it can never take away an inference the
  detector was tuned with. Allowing it at 120 fps was measured and **rejected**: the 313 s free throw's
  release moved −2.5 → −4.5 file frames, the 817 s one +0.5 → +2.5, and their residuals 5.47/5.68 → 6.68/6.43 px.
- `coreMLSweepOnlyWhenMoving` (on, all rates). A whole-frame sweep is 15 tiles at 1080p and the first second
  of a window is a shooter standing at the line; when nothing ball-sized is moving anywhere the sweep is
  skipped. A *gate*, not an aim — when something moves the sweep still covers the whole frame and the model
  still decides — and a skipped sweep does not spend the `coreMLMaxGlobalSweeps` budget. (Aiming the sweep
  before the first lock was measured on 2026-09-14 and rejected: box on the ball still in the hands, release
  −2.5 → −15.5 file frames.)

On a 240 fps free-throw window the model now runs on ~11–89 frames of the ~670 a window holds, with 430–490
skipped because the probe agreed and most of the rest skipped as still-frame sweeps: **0.78–0.82 s per
window**, against 4.22 s with the gates at their 120 fps values. Core ML is no longer the dominant stage at
240 fps — the per-frame background-difference candidates, the motion probe and Vision's pose are.

### The body-pose pass is throttled by real time, not by file frames

`ShotAnalysisRunner.poseSampleRateHz` = **80 pose frames per real second**: every 2nd frame at 120 fps (what
the labelled free throws were measured with) and **every 3rd at 240**. `TrajectoryProbe session --pose-hz H`
overrides it. First 160 s of the 240 fps clip, 13 windows, 10 accepted, same 10 either way:

| pose rate | step at 240 fps | `vision.pose` total | per-window median | max release Δ vs every frame | release angle |
|---|---|---|---|---|---|
| 240 Hz | every frame | 35.36 s | 6.93 s | — | 50.59 ± 1.52° |
| **80 Hz (default)** | **every 3rd** | **14.96 s** | **5.95 s** | **9 ms = 2.2 frames at 240** | 50.35 ± 1.44° |
| 60 Hz | every 4th | 10.65 s | 4.86 s | 13 ms = 3.1 frames | 50.24 ± 1.55° |

Every 3rd frame costs **0.24° of release angle and 9 ms of release instant** for 2.4× less Vision — well
inside the ±37 ms the pose rule itself is known to (`docs/footage-2026-09-13/SHOOTER-REPORT.md`). Every 4th
also holds (0.35°, 13 ms) and was **not** taken: it buys another 18 % of a stage that is no longer the
bottleneck while doubling the quantisation floor that every timing number in `BodyShot` has to declare.

### What the overlays show

`--overlays` renders the window: white rings are the samples that reach the fit, blue → red is time, the
orange curve is the fitted parabola reprojected.

- **341.0 s (accepted, 52.8°, g 9.96, 1.6 px)** — what a good one looks like now: one unbroken chain from the
  hand to the ring, the flight window covering the whole arc, the parabola sitting on the samples, the track
  cut at the rim with no rattle in it, and nothing edge-clipped (at this framing the apex stays in frame).
- **372.8 s (accepted, 85.0°)** — the put-back above. The tracking is right; the flight window runs on into
  the rattle. `trimAfterFreeFlight` cannot cut it because the ball never falls `freeFlightMinimumDropDiameters`
  (1.5 D) below its apex — it *stops* at the apex. That guard stays: removing it costs three 120 fps windows
  half their inliers each and takes the 120 fps clip from 13 accepted to 11.
- **169.0 s (rejected, g 3.24, 53.9 px)** — a short high shot from a few feet away. The tracking is perfect:
  every detection sits on the ball through a clean arc. The **plane solve** fails — the arc is short and near,
  so the fixed-g azimuth is badly conditioned, and it fails the same way with the per-shot solve as with the
  session azimuth. That is `ShotGeometry`, not the tracker.
- **380.6 s (rejected, g −8.90, 94.5 px)** — the last window, no ball: the shooter walks toward the camera and
  the detector puts 200 px "balls" on his shirt, because the loose local re-threshold that measures the
  diameter merges with it. Correctly rejected; a sanity cap on the measured diameter against the expected one
  would kill it earlier, and was not added because nothing accepted depends on it.

None of the four is a linking failure. On the free throws the linker runs the whole flight — **197–225
samples in the fit** out of the ~670 frames a window holds.

### The 240 fps clip, end to end

`session 03D7D2BF….mov --rim rim_240.json --time-scale 1 --hfov 73.83`. The rim came from `RimFinder` on a
ball-free frame at t = 10 s: 64 boundary points, confidence 0.93, ellipse rms **0.39 px**, written by a
throwaway SwiftPM tool in the scratchpad because there is still no `TrajectoryProbe rim` command.

| stage | total (31 windows) | per window |
|---|---|---|
| whole-clip scan | 103 s (92,820 frames, 900 fps) — **53 s of it is the HEVC decoder** | — |
| `vision.pose` | 35.6 s | 1.15 s |
| `motion` | 25.5 s | 0.82 s |
| `coreml` | 24.1 s | **0.78 s** |
| `candidates` | 22.7 s | 0.73 s |
| `planes` | 19.9 s | 0.64 s |
| `template` | 7.7 s | 0.25 s |
| `background` / `link` / `decode` | 4.1 / 3.4 / 2.9 s | 0.13 / 0.11 / 0.09 s |
| **per window** | | **median 4.33 s, mean 4.79 s, max 15.58 s** |

The whole 386 s clip is ~250 s of analysis on this Mac. Both the 240 fps and the 120 fps runs were repeated
end to end and came out **row-for-row identical**, so none of these are lucky draws.

### Regression: the 120 fps clip did not move

`session footage/2026-09-13/IMG_1765.mov --rim footage/2026-09-13/rim_1765_found.json --time-scale 4
--hfov 48` — 30 fps file at 4×, so every gate resolves to exactly the per-frame number it was tuned at.

| | |
|---|---|
| accepted | **13 of 30** |
| release / entry, accepted rows | 44.90 ± 3.54° / 37.32 ± 2.71° |
| fit residual | median 6.40 px, max 11.7 px |
| release vs `docs/footage-2026-09-13/release_labels.json`, in **file** frames | **−4.5, −2.5, +2.5** — all three inside ±5, all three accepted |

### Changed here

- `Packages/ShotVideo/Sources/ShotVideo/BallDetector.swift` — `FrameRates`, every option restated in real
  units, `coreMLSkipWhenMotionAgrees`, `coreMLSweepOnlyWhenMoving`, `trimAfterFreeFlight`. Every rejected
  setting and the number that rejected it is in the option's own doc comment.
- `Packages/ShotVideo/Sources/TrajectoryProbe/Probe.swift` — `session` passes `timeScale` to the detector,
  and gained `--legacy-rates`, `--pose-hz H`, `--no-motion-skip`, `--no-still-sweep-gate`,
  `--no-free-flight-trim`, `--free-flight-drop`, `--free-flight-residual`.
- `App/Sources/ShotAnalysisRunner.swift` — `base.timeScale = timeScale` on every detector attempt, and
  `poseSampleRateHz` (80 Hz real) instead of a fixed every-2nd-frame.
- `Packages/ShotGeometry` untouched. `swift build -c release` (both packages) and
  `swift run -c release GeometryHarness` → **GATE: PASS**. `xcodegen generate && xcodebuild … -destination
  'generic/platform=iOS Simulator' build` → **BUILD SUCCEEDED**.

### What is left

- **The minimum release distance in `ShotAcceptance`** (above). It is the one change that would have fixed
  the number the user actually complained about, and it is one line plus a reason string.
- **The whole-clip scan is now the biggest single cost at 240 fps** — 103 s, 53 s of it decode. The arrival
  rule does not need every frame of a 240 fps clip; stepping 2 frames would halve it and still satisfy
  `descentLookbackFrames`. Cheapest remaining win.
- **`ArrivalRuleOptions.descentLookbackFrames` (3) and `minimumHighCandidates` (6) are still file-frame
  counts.** Both survive the rate change — the drop over 3 frames at 240 fps is ~11 px against a 2 px floor,
  and more frames only make the "high in the frame" test easier — but they are the two gates in the arrival
  rule not stated in real units.
- **A close-range shot's plane solve still fails** (169 s: g 3.24 on a visually perfect track).
- **None of this ran on the phone.** Every number here is the Mac's, through `TrajectoryProbe session`, which
  runs the same detector, the same pose rule and the same acceptance rule as the app's session flow.

## 2026-09-15 afternoon — clean point, build on the phone

Phone build (Release, installed ~14:20 PT) = this tree exactly: frame-rate-aware tracker, `ShotAcceptance.minimumReleaseDistance` 2 m,
validated form-clip mode, arms fix (rigid limb bones), rigid-bone mean form (`FormModel.build`, see PHASE2-PREP "Mean form, rigid
bones"), 3-D body player link, AR body-capture experiment. `swift test` 148 / 0 failures; app BUILD SUCCEEDED.
Open: before/after measurement of the mean form on ≥ 20 phone shots (needs a `BodyRefit --mean-form` mode), six-phase PNG,
live feedback during recording (docs/DESIGN-LIVE-FEEDBACK-2026-09-15.md). User data today: 46-shot free-throw session, 37 accepted,
443 s on a thermally "serious" phone (~9.6 s/shot with body stage) — the next speed target.

## 2026-09-15 evening — ArcLab 1.1 on the phone

Release build installed ~18:00 PT = tree. Plan: docs/PLAN-1.1-2026-09-15.md. Landed: 3-D model 1.1 (HeadGeometry, torso
breadth pinned when unobservable, depth smoothing 0.3, skull+face rig in SceneBody/FormModelView; RMS 2.60 → 1.85 px on 107
phone shots; PHASE2-PREP "3-D model 1.1"), Curriculum (8 modules, LearnView, PlanView link; research/shooting-curriculum),
FootworkMetrics + FootworkCardView + FootworkProbe (DESIGN-FOOTWORK), passthrough clip probe (93 s → ~3 s), clip
fingerprint + "analysed before" notice. Tests 195 / 0 failures.
Open: shooting arm opens 35.8° in 3-D vs 48.5° in the image (limb bones 2–4 % long); stance width/transverse axis are priors
on every existing clip (need a 30–45° off-line clip); tempo-normalised smoothing needs 240 fps windows; gather/travel norms
are grade D pending the user's own pull-ups; no drill picker yet (drill inferred from step pattern).

## 2026-09-16 — optimisation build on the phone

Release build installed ~00:05 PT 2026-09-16 (Xcode 27.0; the machine self-updated mid-cycle — licence accepted by the
user). Tests 195 / 0 failures in 2.6 s with `swift test -Xswiftc -O --scratch-path <outside Desktop>` (README explains the
Xcode 27 codesign/iCloud-Desktop trap). All kept changes are bit-identical on the gate clips and on 110 phone shots
(PHASE2-PREP "Solver and test-suite optimisation" + "Pipeline optimisation").
On-phone bench (same 250 s clip, 6 windows, thermal nominal): total 85.5 s → 58.6 s; probe 20 → 0.8 s; scan 41 → 10.4 s
(decode 16.7 s of CPU, detect 3.8 s); ball phase 6.3 s/window with `coreml.wait` 0.8–3.0 s the floor; deferred body phase
1.5 s/shot on this clip (4–4.7 s/shot on 240 fps windows in the user's session earlier tonight).
Next levers (need a re-baseline, not bit-parity): merge the two body-pose passes (~2 s/window at 240 fps), fewer Core ML
frames per window (motion-gated seeding + blob tracking), smaller decoded window (224 MB → 2 lanes under the 320 MB
budget), CoreMLBallDetector one-pixel tile-origin bug (fix with the re-baseline).

## 2026-09-16 — ArcLab 1.2 (UI) built

Chosen from docs/IMPROVEMENTS-2026-09-16.md (908 lines; §2 per-screen specs, §3 reliability, §4 copy guide, §10 roadmap).
Shipped: 4-tab shell (Shoot · Review · Learn · You; TodayView card = the plan's measure on the last session via
FixLibrary.check, one primary button; AdvancedToolsView holds the old step-by-step home; YouView profile + camera formats
+ activity-log tail; `-tab` launch arg for screenshots); guided flow with spot-before-rim, inline RimPreviewCard
(Looks right / Adjust), live ShotFeedView with the bandwidth rule (tick inside own mean ± 1 SD at ≥ 10 saved accepted
shots), auto-save + Undo, pause/resume on −11847 with per-shot checkpoints, probe retry, local notification on completion
(Live Activity skipped: needs a widget target); SessionView rim-map hero + SessionSummaryTiles + one coaching sentence,
everything else in disclosures; form-clip fingerprint; verdict chips; 3-D form: release-pose open, six-stop clock (load
and rise derived, provenance printed), camera presets, ghost of own best reps (FormModel.bestReps, ≥ 5 make-band shots
else block mean), tap-a-joint callout, 88 % scrims. Raw identifiers removed from every view. Tests 201 / 0.
Open: ellipse overlay on the inline rim thumbnail unverified on device; HistoryView/LearnView own inline titles (tabs
read "Progress"/"Learn"); Today card refresh on an *edited* session needs a store change counter; only 2/37 FT forms
carry the right wrist at release (tracking coverage → 1.4).

## 2026-09-16 midday — 1.3 paused mid-work (user request)

Three agents (hands + release coverage, feet via Halpe-26 Core ML, evaluation harness) were stopped by the user's request
after repeated watchdog stalls. Tree holds untracked half-done files (HandTriangle.swift, FootKinematics.swift, FormEval*,
HandProbe, FootPoseDetector/model in ShotVideo, Package.swift targets) and may not compile as a whole. Phone stays on 1.2.
Resume: build/test first, then resume or re-brief per docs/PLAN-1.3-2026-09-16.md.

## 2026-09-16 afternoon — ArcLab 1.3 (3-D form: hands, feet, evaluation) on the phone

Plan docs/PLAN-1.3-2026-09-16.md; research docs/research/whole-body-landmarks-2026-09-16.md. Shipped (tests all green,
app + ShotVideo builds, Release installed): hand plates (HandTriangle.swift, wrist·index MCP·little MCP, declared 0.049 H
breadth prior, BodyShot schema v2), the phase-clock fix that returned the release instant to shots with no dip (wrist and
elbow at τ 0.75: 2/37 → 37/37), foot triangles (RTMPose-m Halpe-26 → ArcLabFootModel.mlpackage FP32 53 MB, 0.00 px vs
PyTorch; FootPoseDetector on the person crop; FootKinematics rigid triangle with Drillis–Contini prior; foot angle at set
repeatable to ~1°, toe-span residual −40 % = the prior's shape, deliberately not tuned; roll only when toes ≥ 4 px apart),
FootworkMetrics foot angle/openness/strikes real, FootPlates in the scene, You › Advanced toggle "Track the feet"
(UserDefaults feet.enabled, default on, timing logged as body.feet), export footTriangles (v2.1 additive), FormEval +
FormEvalKit harness (docs/research/form-eval-baseline-2026-09-16.md; 110 files = 37 unique shots; jumpHeight ICC 0.92,
headHorizontalRange 0.86; kneeMinimum and elbowAtRelease are noise at this distance — do not coach on them yet), a 20-frame
label sheet in scratchpad/labels/sheet-2026-09-16 with HOW-TO-LABEL.md. DECISIONS.md: Halpe-26 licence is non-commercial
research → internal measurement/labelling only.
Open: phone benchmark of the foot model (FP32 may refuse the ANE; read body.feet in the log after a session); foot angle
is measured against the camera→rim bearing (parallax 38° on this footage) — wire RimCalibration's rim position into
FootTriangleOptions; heel/toe-first strikes unexercised on real footage (needs a 1-2 or pull-up clip); neckNose wanders
11.6 %; hand plate coverage at release is detector-limited (17 % of frames at t = 0) — the close form clip is the path.
