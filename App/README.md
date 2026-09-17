# ArcLab iOS app target

The app is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`docs/DECISIONS.md` §9.2). `ArcLab.xcodeproj` is git-ignored; edit `project.yml`, never the project.

## What it does today

The home screen has one product path and one toggle. **Analyze a session video** (`GuidedSessionView`)
is the path a shooter takes: record in the app (`CaptureView`, true frame rate and lens in a sidecar, so
nothing is asked) or pick a video, mark the rim once, and the app does the rest by itself —
treats a ≈30 fps file with no edit list as a 4× slo-mo export (the filming guide says slo-mo; the gravity
check catches a wrong factor), scans the whole clip, analyses every shot as it is found, and ends on the
session screen with the block numbers, the coaching card and Save. **Step-by-step tools** shows the
numbered flow below for the same measurements one step at a time.

Import a clip, mark the rim, find **every** shot in it, analyse them, and read the block — with the
single-shot flow still there for one window at a time:

1. **Clip.** Import from Photos → decode every frame and measure what the file really is
   (`VideoReader.probe()`: size, measured frame rate, edit-list stretch, jitter, notes). Slo-mo clips
   come in through PhotoKit's *original* video resource so the true frame rate survives; if the library
   cannot be read the picker's file copy is used and the UI says so.
2. **Timing and lens.** A **slow-motion factor** (file time ÷ factor = real time) and the lens's
   horizontal field of view. When the file carries an edit list the factor is taken from it. The
   2026-09-13 clips are 120 fps exported with 30 fps timestamps: the stretch reads `1.00×`, the file
   cannot say it is slow, so a switch offers the factor **4** whenever the measured rate is ≈30 fps,
   and the number stays editable. hFOV defaults to **48°** (1080p120 slo-mo on the paired iPhone).
   Get the factor wrong and `g_fit` comes back ≈4× or ¼ of 9.81 — which is what the gravity check is for.
3. **Rim** (`RimMarkingView`). One decoded frame at a scrubbed time, tap ≥ 6 points around the inside
   of the ring (loupe + 1 px nudges for the last point), then **Calibrate** runs
   `RimCalibrator.calibrate`. It shows camera→rim distance, rim height above the camera, axis ratio,
   ellipse residual, pose ambiguity, pitch/roll and every `RimCalibration.warnings` entry, and draws the
   fitted ellipse back over the frame so the fit can be checked against the ring.
4. **Session** (`SessionView`). **Find and analyze every shot.** One fast pass over the clip
   (`SessionScanner`) finds the shot windows, then each one goes through the same analyzer. See
   "Session mode" below.
5. **One shot** (`ShotPickerView`). Scrub to just before a shot, set the window (default 7 s of *file*
   time), **Analyze**. Off the main actor, with progress, it runs exactly what `TrajectoryProbe analyze
   --classical --pose --fixed-g-azimuth` runs: Vision `DetectTrajectoriesRequest` over the window → best
   ball-sized sample per frame → those positions seed `BallDetector` → Vision body pose for the release
   instant → `ShotAnalyzer.analyze` with `AnalysisOptions.azimuthByFixedGravity = true`. Failures print
   the pipeline's own message verbatim.
6. **Result** (`ResultsView`). The release frame with the detections (small dots), the fitted parabola
   reprojected through the solved shot plane (orange) and the rim points (green); then `g_fit` with its
   accept / low-confidence / reject verdict and the `GravityGate.explain` line, release angle, height,
   speed and distance, entry angle, apex, depth past the front rim, the analyzer's warnings, and a
   **rim map**: the ring to scale (45.7 cm) with the ball's crossing on the front/back axis and the
   dashed swish zone, radius (rim − ball)/2. Left/right says "not measured from this camera angle" on
   side views rather than drawing a number nobody measured. No target bands. A **body** card shows the
   camera-side elbow at release, the elbow at its most extended near release, the deepest knee bend and
   dip → release, always under the analyzer's view-class warning: a 2-D image-plane angle equals the
   true joint angle only when the limb lies in the image plane, so these are relative only.

Anything that cannot be computed reads **"not measured"** with the analyzer's own reason
(`releaseUnavailableReason`, `entryAngleUnavailableReason`). All work is on-device; there are no network calls.

The original diagnostic screen is still there under **Tools → Probe & Vision tracks**: the full probe
table plus every Vision trajectory in the first 10 s, each with a "Use as the shot window" button.

## Session mode

`SessionView`, reached from step 4. An analysed session can be **saved** at the bottom of that screen with
the spot it was shot from (free throws, elbow, mid-range, three, other) and an optional note; only each
shot's numbers, verdict and reason are stored (`SessionStore`, one JSON file in the app's Application
Support folder, never the clip, never off the device). The home screen's **Progress** section and
`HistoryView` pool every saved session **per spot**: that is the only place the brief's 30-accepted-shot
floor is ever reached, so the one "what to work on" finding lives there, together with the per-session
lines (accepted n, speed and entry mean ± SD, inferred makes/misses) and the one cross-session comparison
the app makes, the change in release-speed spread. Spots are never pooled together.

**Scan** (`SessionScanner`, cancellable, with progress). One decode of the clip, no Vision. `RimArrivalScanner`
keeps a running background (a sigma-delta estimator, one grey level a frame) on a **quarter-resolution crop of
the rows the rule actually reads** — the upper 40 % of the frame plus the rim's own neighbourhood — and reports
the round, orange, moving blobs against it. Every blob goes into a frame-indexed slot, and then the rule from
`tools/pytrack/session.py` `find_arrivals` decides where the shots are:

> a **ball-sized candidate within 2.5 diameters of the rim centre**, **moving down** (a candidate near
> it and above it in the previous three frames), **preceded within 1.5 s of real time** by at least six
> ball-sized candidates in the upper 40 % of the frame. At most **one arrival per 3 s of real time**.

The rim centre is the calibrated ellipse's centre in pixels and the ball's size comes from the same
ellipse (`2 · semiMajor · ball / rimDiameter` — 60 px on the 2026-09-13 clips). On `footage/2026-09-13/IMG_1765.mov` this
finds the same 30 arrivals the old whole-clip `DetectTrajectoriesRequest` scanner found — 28 of them within a
tenth of a second, two of them 0.6 s of real time later — in **19–27 s instead of 150 s** (`docs/HANDOFF.md`,
"Speed, 2026-09-14"). The old scanner is still there as `SessionScanOptions.mode = .vision`, for comparison.
Each arrival becomes the
window `[arrival − (1.3 + 0.35) s real, arrival + 0.4 s real]` in file time — 8.2 s at a 4× factor. The
scan measures nothing; it only says where to point the analyzer.

**Analyse.** Each window runs through `ShotAnalysisRunner`, the same code the single-shot flow uses, with
per-shot progress and a stop button. The window is **decoded once**: one pass produces the half-resolution Y and
Cr planes, the Core ML boxes and the background model, and every later stage — the two fallback detector
parameter sets included — works from that, so a retry never touches the file again. Inside a session the Vision
trajectory pass over the window is skipped entirely (the scan already says where the ball is and seeds the
detector's tile); the single-shot flow still runs it, because there is no scan behind it. Body pose runs only
over the part of the window that can carry a release — from its start to half a second of real time past the
ball's first detection — and a looser detector is only tried again when the first attempt did not **see** enough
of the ball, never when a well-covered track simply fitted the wrong gravity. Windows run one or two at a time,
decided by a memory budget (one decoded 1080p window at a 4× factor holds about 255 MB of planes) and dropped to
one whenever `ProcessInfo.thermalState` is serious or critical. Status per shot is
**queued / analyzing / accept / low confidence / reject / failed**, and a failure shows the analyzer's own
sentence. Tapping a shot opens the ordinary results screen for it.

**Block summary.** Counts (windows found, measured, accepted, failed), then mean ± SD and n for release
angle, height and speed, entry angle, depth past the front rim and `g_fit`, plus the pose angles. A shot
is **accepted** — the rule is `report.py`'s — only when its fitted gravity is within 8 % of 9.81 **and**
its release height is 1.6–3.3 m, its speed 4.5–11 m/s, its release point ≥ 2 m from the rim (put-backs and tips
from under the basket are not shots from a spot), its crossing −0.6…1.0 m and the fitted arc's
reprojection residual is ≤ 25 px (a 162 px fit once passed on gravity alone): gravity alone does not
prove the shot-plane solve worked. Geometry statistics use accepted shots only; the pose angles use every
shot that produced one, because they do not depend on the plane. Nothing is a target.

**Rim map** (`SessionRimMapView`): the ring to scale with one dot per accepted shot, coloured by the
inferred outcome. Make/miss is inferred from the ball's own behaviour at the rim (`report.py`'s
`infer_outcome`, ported) and **unknown** stays unknown. Side views measure front/back only, so those dots
sit on the centre line and the picture says so.

**Strip charts** (`ShotStripChartView`): release speed and release angle in shot order, filled for the
accepted shots and hollow for the ones the block rule left out, with the block's own mean and a ±1 SD
band as the only reference lines.

**Coaching card** (`SessionCoaching.swift`), at the bottom of the screen:
- *What this session says* — at most three sentences chosen by rules, ranked release-speed consistency →
  what the inferred misses have in common front to back → entry angle against the published mid-40s band
  → rhythm and arm extension (side views only). Every sentence carries ± and n and says "associated
  with", never "because".
- *What to work on* — exactly one item, and only at **30 or more accepted shots** (brief §6). Below that
  it says "Collecting baseline: N of 30 accepted shots" and what arrives at 30. At 30 the rules are the
  Ch 15 `flat_arc` threshold, release-speed spread scored in centimetres of depth, and within-session
  drift — and "nothing fired" is a permitted answer.
- *How to film next time* — one or two lines, each from something this clip actually did: the ball's top
  edge reaching the frame top → a metre of sky above the arc; outcomes mostly unknown → say "make" or
  "miss" after each shot; a rim axis ratio below 0.2 → lower the tripod.

### What it does on the 2026-09-13 footage
On the first 200 s of `IMG_1765.mov` the scan takes **26 s** (6270 frames, 4 chunks) and finds **8
arrivals**, at 12.1, 24.3, 38.5, 50.5, 93.7, 107.3, 153.3 and 166.1 s. The Python scanner finds 8 in the
same range, at 1.5, 15.4, 28.5, 50.5, 93.6, 108.2, 153.1 and 168.3 s: four agree within a second, one
within 2.2 s, and three do not match. Of the 8 windows, 7 are measured and **1 is accepted**
(g_fit 9.81, release 43.5° at 2.68 m and 7.26 m/s, entry 38.6°, depth 15.7 cm). That accept rate is the
ball tracking, not the scanner — the same windows with the pose stage off give the same one accept, and
the earlier Swift batch over this clip got none before 232 s. `docs/HANDOFF.md` has the full numbers and
the limits.

## Build
```sh
brew install xcodegen                     # once
cd App && xcodegen generate               # after every project.yml change
# Simulator (needs the iOS platform: Xcode > Settings > Components, or `xcodebuild -downloadPlatform iOS`)
xcodebuild -project App/ArcLab.xcodeproj -scheme ArcLab \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```

## Run
```sh
open App/ArcLab.xcodeproj                 # pick a simulator or the paired iPhone 14 Pro, ⌘R
# or, from the command line:
xcrun simctl boot 'iPhone 17 Pro'
xcodebuild -project App/ArcLab.xcodeproj -scheme ArcLab \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcrun simctl install booted <path to ArcLab.app from the build log>
xcrun simctl launch booted com.arclab.app
# the Simulator's Photos library starts empty; a 1.6 GB clip takes several minutes to add:
xcrun simctl addmedia booted footage/2026-09-13/IMG_1765.mov
```
Running on the device needs `DEVELOPMENT_TEAM` set (in `project.yml` under `targets.ArcLab.settings.base`,
or once in Xcode's Signing & Capabilities).

## Layout
- `Sources/ArcLabApp.swift` — entry point.
- `Sources/ContentView.swift` — home: Start (guided path, filming guide), Progress, and the numbered
  steps behind the "Step-by-step tools" toggle.
- `Sources/GuidedSessionView.swift` — the guided path: video → rim → automatic scan and analysis → results,
  driving the same `AnalysisModel`/`SessionModel` as the numbered steps.
- `Sources/AnalysisModel.swift` — `@Observable` state for the whole flow (clip, probe, time scale, hFOV,
  rim points, calibration, window, analysis); every decode or fit runs in a detached task off the main actor.
- `Sources/ShotAnalysisRunner.swift` — clip + window + calibration → `ShotAnalysis` + `ShotPoseResult`,
  off the main actor. Falls back to the Vision samples when the classical detector returns fewer than 12,
  and says so. The pose pass runs on every 2nd frame, which costs at most one file frame of release
  quantisation (≈ 8 ms of real time at 120 fps) and halves the cost of the slowest stage.
- `Sources/SessionScanner.swift` — the whole-clip arrival scan, chunked, cancellable, with progress.
- `Sources/BlockSummary.swift` — the acceptance rule, the mean/SD statistics, and make/miss inferred
  from the ball at the rim.
- `Sources/SessionCoaching.swift` — the three-part coaching card and the rules behind each part.
- `Sources/SessionModel.swift` — the live session's state while the app is open.
- `Sources/SessionStore.swift` — saved sessions (`SavedSession`/`SavedShot`, Codable) in one JSON file,
  the `ShotSpot` cell, and the per-spot pooling that feeds the Progress screen.
- `Sources/HistoryView.swift` — Progress: pooled block per spot, the finding at ≥ 30 accepted shots,
  session-by-session lines, delete by swipe.
- `Sources/FilmingGuideView.swift` — the Phase 0 filming protocol as an in-app checklist, each step with
  the reason the analysis needs it.
- `Sources/RimMarkingView.swift`, `ShotPickerView.swift`, `SessionView.swift`, `ResultsView.swift`,
  `RimMapView.swift`, `SessionRimMapView.swift`, `ShotStripChartView.swift` — the flow.
- `Sources/ShotResultContext.swift` — one analysed shot, detached from where it came from, so the
  session list and the single-shot flow open the same `ResultsView`.
- `Sources/FormModelView.swift` — the 3-D form: a rotatable SceneKit skeleton on a set → dip → release →
  follow-through scrubber, played back at the block's real tempo, with the block's mean form and its 1σ
  ellipsoids on top and an earlier session for progress. Joints the tracker never saw are drawn **dashed**
  (mirrored from the other side, `ShotForm.inferredBySymmetry`) and no number is read off them. Reached
  from the session screen (the block's mean form) and from a shot's results (that shot against the block).
- `Sources/ShotOverlay.swift` — detections, reprojected parabola and rim points, in image pixels.
- `Sources/FrameLoader.swift` — one decoded frame → `UIImage`, in the *decoded* orientation, so a tap on
  the picture and a detection in the analyzer mean the same (u, v).
- `Sources/ImageFit.swift` — pixel ↔ view mapping for the `.fit` rectangle, plus the loupe.
- `Sources/ProbeTrackView.swift` — the probe table and Vision track list.
- `Sources/ClipImporter.swift` — `PhotosPicker` item → temp file (PhotoKit original first, `Transferable` copy second).
- Dependencies: local packages `../Packages/ShotGeometry` and `../Packages/ShotVideo` (library product only;
  `TrajectoryProbe` is macOS tooling and is not linked).

## In-app capture

`CaptureView` records the clip inside ArcLab instead of in Camera.app, so the shooter never picks a
slo-mo setting, a lens, a zoom or a focus mode — and, more importantly, **the analysis is never told the
time base or the field of view by hand**. Both of those are typed in today (step 2 above), and both are
guesses: get the slow-motion factor wrong and `g_fit` comes back at 4× or ¼ of 9.81.

- `Sources/CaptureController.swift` — `CaptureEngine` (the `AVCaptureSession`, on its own serial queue,
  `@unchecked Sendable` with the invariant spelled out in the file) and `CaptureController`
  (`@MainActor @Observable`, the UI state). Nothing but `Sendable` value types crosses between them:
  no `AVCapture…` object and no `Error`, only a `CaptureEvent`.
- `Sources/CaptureView.swift` — the landscape recording screen, the framing overlay and the preview layer.
- `Sources/RecordedClip.swift` — one recording and its sidecar.

**What the camera is set to, and why each one matters.**
- Back **wide (1×)** camera only, via `AVCaptureDevice.DiscoverySession([.builtInWideAngleCamera])`.
  Never `.builtInDualWideCamera`/`.builtInTripleCamera`: a virtual device switches to the ultra-wide or
  the telephoto by itself, and the lens geometry is part of the calibration. `videoZoomFactor = 1.0`.
- 1920×1080 at the highest frame rate ≥ 120 (240 preferred), pinned with
  `activeVideoMin/MaxFrameDuration`, `sessionPreset = .inputPriority` so the session cannot override it.
- `isAutoVideoFrameRateEnabled = false` and low-light boost off: both trade frame rate for exposure in a
  dim gym, silently.
- `preferredVideoStabilizationMode = .off`. Stabilisation shifts and warps the image frame by frame; the
  whole geometry assumes a camera that does not move, and the protocol's answer to shake is a tripod.
- HEVC when `availableVideoCodecTypes` offers it, else h264. Audio on — the protocol asks the shooter to
  say "make" or "miss" after each shot, and that track is the ground-truth log
  (`NSMicrophoneUsageDescription` is in `project.yml`).
- Focus, exposure and white balance are set on a tapped point (or the centre after 2 s if nobody taps),
  allowed to settle, then `.locked`. The screen says which locks actually took.
- Rotation comes from `AVCaptureDevice.RotationCoordinator`, so both the preview and the written file are
  horizon-level; the screen asks the window scene for landscape while it is up.

**On an iPhone 14 Pro this is expected to select 1920×1080 at 240 fps** (the format Camera.app's
1080p slo-mo uses) **with a `videoFieldOfView` near 48°** — HFR formats are cropped, which is why that is
narrower than the ~64° of ordinary 1080p. *Expected from the format list, not verified on the device:*
the code reads the number off the chosen `AVCaptureDevice.Format` and writes it down, so whatever the
hardware really offers is what ends up in the sidecar.

**`RecordedClip`** is written to `Documents/ArcLab/Recordings/<uuid>.mov` with a `<uuid>.json` sidecar
holding the same struct: recorded date, requested frame rate, `videoFieldOfViewDegrees`, resolution,
codec, device model (`iPhone15,2`, not "iPhone"), the focus/exposure lock states and any warnings. After
the recording stops the file is **re-read** — `AVAssetTrack.nominalFrameRate` *and* a counted
frames ÷ duration — and both go in the sidecar. A file that claims 240 fps and holds 190 gets a warning
saying so, which is the thermal governor and the one failure the filming protocol cannot otherwise catch.
`measuredNominalFrameRate` is `nil` when the file could not be re-read; nothing falls back to the
requested rate silently. `RecordedClip.load(url:)` reads the sidecar from either the `.mov` or the
`.json`, `loadAll()` lists the folder, `delete()` removes both files, and
`slowMotionFactorAgainst30fps` is the number the import flow makes the shooter type — here it is a fact.

**The screen.** Live preview at `.resizeAspect` (never `.resizeAspectFill`: the shooter must see exactly
the frame that will be written, or the guides are lying), with the protocol's framing drawn on it — a
green "feet on this line" near the bottom edge, a dashed orange "rim inside this band" across the top
third, and the "keep about a metre of sky above the highest arc" reminder — plus a readout of
resolution / fps / hFOV / lock state, elapsed time, and a record-stop button on the trailing edge where
it does not cover the feet line. Camera denied shows the reason and an **Open Settings** button; the
Simulator (no camera) shows a plain "record on the iPhone" message.

**Rim-in-frame indicator.** A coarse orange check in the top third, at ≤ 5 Hz, reading the chroma plane
of the native 4:2:0 buffer directly (no colour conversion, no CIFilter, no GPU) and **skipped entirely
while recording**, so it can never cost the 240 fps file a frame. It is a framing aid, not a measurement:
a wooden floor, a ball rack or a sunset also read as orange.

**Limits.**
- The format choice, the 240 fps and the ~48° hFOV are what the code asks for and reads back; they have
  not been run on the paired iPhone yet. The Simulator cannot test any of it.
- The second `AVCaptureVideoDataOutput` (the rim indicator) is added only when `canAddOutput` allows it.
  Its effect on sustained 240 fps recording is untested on device; if frames are dropped, removing that
  output is a two-line change.
- No storage check and no maximum duration: ~1 GB per 5 minutes at 1080p240, and a full disk ends the
  recording with the analyzer's own error, not a friendly one.
- Nothing is deleted automatically. Recordings accumulate in Documents until `RecordedClip.delete()`.

## Shot doctor screens (2026-09-14)

Three screens over `Packages/ShotGeometry`'s `ShotDoctor` / `SymptomEngine` / `FixLibrary`
(`docs/DESIGN-SHOT-DOCTOR-2026-09-14.md`). No new measurement and no new statistics: the App layer
bridges, displays, and persists one choice.

**`ShotDoctorModel`** (`@MainActor @Observable`) is the only bridge. `records(from:)` turns
`SavedSession`/`SavedShot` into `[ShotRecord]` — degrees back to radians at the boundary,
`DoctorSpot(rawValue: session.spot.rawValue)`, `accepted` from the saved verdict, everything not
measured left nil. The pooled diagnosis and the per-session ones are cached against a store
signature (`session id # shot count`), so `ShotDoctor.diagnose` runs once per change rather than once
per redraw. With no saved session there is no diagnosis at all and every screen shows the same
sentence — save a session first, with its spot.

**Ask** (`AskView`, from Start). Free text runs `SymptomLibrary.match` through
`SymptomEngine.answer`; the screen says which phrases it matched and offers the 14-row picker, and
an unmatched complaint shows the engine's stated reason plus the picker rather than a guess. Then
the ranked hypotheses: plain name, evidence-grade capsule in `ShotProfileView`'s style
(`DoctorGradeBadge`), the verdict chip — supported / not supported / not enough shots yet / cannot be
measured from this camera position — the engine's own evidence line with its numbers and n, and
`filmThis` as a "film this next" line. `answer.plan` is the single link onward.

**Diagnosis** (`DiagnosisView`, from Progress and from home). Per spot: the depth-variance
attribution with its four shares and the measured depth beside the predicted one, the operating
point's cm-per-0.1 m/s, the distance table (one row per spot with n, means ± SD) with the
versatility verdict, its ratio against the detectable floor and its grade, the entry-angle geometric
finding, and the most recent session's misses one by one with the engine's arithmetic sentence.
Nothing here decides its own floor: where the engine returns nil the screen prints its reason.

**Plan** (`PlanView`). One `FixPackage` as cue, drill (sets × reps, spots, constraint, schedule),
the measure that should move, the expected magnitude, and how the app checks it. "Start this plan"
writes an `ActivePlan` — hypothesis, symptom, spot, baseline session id and date, the pass measure's
own baseline value read out of that session's diagnosis (nil with a reason when the session does not
carry it), and the accepted-shot n. Later sessions at that spot fill in `FixLibrary.check` and
`FixLibrary.retention`; `passed` and `held` are `Bool?` and nil renders as "cannot tell yet", never
as a failure. One plan at a time: starting another asks first.

**Storage.** `ActivePlan` lives in its own `active-plan.json` beside `sessions.json`, so a session
file written by an older build still decodes untouched. Screen visits and plan choices go to
`ActivityLog` as `screen`, `doctor.ask`, `doctor.plan.started`, `doctor.plan.cleared`.

## Practice mode (2026-09-15)

`docs/DESIGN-PRACTICE-MODE-2026-09-15.md`. A session is a list of **blocks**, and a block is a spot,
a number of shots, and a role in the active plan. The home row is "Practice: today's plan".

**Today's plan** (`PracticeHomeView`). `PracticeStore.ensureToday(doctor:)` builds it once per day
from `ShotDoctorModel.planProgress`. With a plan: the drill blocks come out of the fix package's own
`Drill` — its `spots` mapped to `ShotSpot` × its `reps`, one block per spot, capped at five, with the
package's constraint and schedule quoted; where the package names no spots, `min(sets, 2)` blocks at
the plan's spot. Then an un-cued retention block of 10 at the plan's spot. Without a plan (or with a
plan whose baseline session was deleted) it is one baseline block: ten free throws, un-cued. Every
block's spot is explicit before a shot is taken; nothing is defaulted to "wherever the last clip was".

**A block** (`PracticeBlockView`). Instruction and the package's one external-focus cue, then Record
(`CaptureView` in a full-screen cover) → `AnalysisModel.useRecordedClip` → `findRimAutomatically` →
`SessionModel.startScan`/`analyseAll`, including the guided flow's lens second pass
(`LensSelection.propose` → `reanalyse`). The same models as the guided flow, so the measurements are
identical. While it runs: shots found / measured / counted, the current shot's stage, the time-left
estimate, and the feedback line ("Shot 7: counted — 7.21 m/s at 49°, 4 cm long of the make band",
`PracticeFeedback.line`). When the analysis ends the block **saves itself** through
`SessionStore.save` at its own spot with the note `practice block: <role>` — no save button to
forget — and is scored.

**The block card.** The plan's own pass measure read back out of `FixLibrary.check` against the
block's saved session (the self-check read-out `ShotDoctorModel.startPlan` uses), in plain words with
its unit and its n; then `FixLibrary.check` for a drill block and `FixLibrary.retention` for the
retention block, both with `passed`/`held` as `Bool?` — "cannot tell yet" and "n more shots at this
spot before the check can run" are outcomes, never fails. Then the next block's cue. A block whose
recording produced no measured shot is not saved at all; it carries the reason and can be re-recorded.

**Summary** (`PracticeSummaryView`). Every block with its numbers, what moved in the plan (baseline /
follow-up / retention, each with its date and n or its unavailable reason, plus the check and
retention sentences), and the way into Progress.

**Storage.** `practice.json` beside `sessions.json`: `PracticeSession { id, date, planID,
planHypothesis, blocks: [PracticeBlock] }`, each block carrying its spot, intended shots, role,
recording file, saved session id, measure (value, unit, n, or a reason) and `PracticeCheck`. Nothing
in `SessionStore` or the package changed. Log events: `practice.session.built`,
`practice.block.start`, `practice.block.saved`, `practice.check`, and `screen`.

**Copy rules held throughout:** external-focus cues only, "associated with" never "because", no
universal target (the comparison is always the shooter's own earlier block), every number with its n,
and `FixLibrary.honestyRules` shown on the plan screen.

**Latency, honestly.** The card appears one to three minutes after the block, not shot by shot: the
per-shot pipeline is still 6–20 s a shot on the phone. The screen says so and tells the shooter to
record the next block while the last one finishes.

**Spoken results.** `ShotSpeaker` (on-device `AVSpeechSynthesizer`) says each measured shot as it lands: speed to one decimal, then whole cm vs the make band ("4 long" / "in the band"), or just "not measured" for a shot that was not accepted — never an angle, never a target; a newer shot replaces the one waiting, so at most one is ever queued.
The speaker icon in the practice block and guided screens mutes it (persisted per screen in UserDefaults, default on for practice, off for guided); every line is logged as a `speak` event. Speech ducks other audio; keeping it going with the screen locked also needs the `audio` background mode in `project.yml`, which is not set.

**Progress charts.** `ProgressChartsView` (Swift Charts, in `HistoryView` after the pooled block) draws one chart per metric for the picked spot, sessions on x in date order, session mean on y with a ±1 SD band and n on every point; release-speed SD is the headline with the Slegers 2021 skilled band shaded, entry angle carries the 32°/40° geometry lines, depth the 25–28 cm published make-rate band — references, never targets. Each chart hides itself with one line below two sessions carrying the measure.
A "compare spots" toggle overlays the other spots on the spread chart only; tapping a point shows that session's date, clip, n and value; every chart carries a caption in the app's own units (0.1 m/s of speed SD ≈ 15 cm depth spread) and an accessibility label. Logged as a `screen` event named `progress.charts`.

## Form-clip mode, validated (2026-09-15)

The close-up with no rim. `FormClipView` → `FormClipModel` → `FormClipScanner` (ShotVideo). Measured
against the rim-based session on the 240 fps in-app recording (details in `docs/HANDOFF.md`, same heading):

- **Finding shots.** A shot is a wrist pattern sampled at 30 Hz: a rise of more than half a torso length
  to a high point above the shoulder line, held above half that height for 0.3 s, driven by at most one
  torso length from a set held still for at least 80 ms (iteration 3's rule); one per 3 s. On the clip:
  23 of 23 free throws found, 0 false positives; the 5 quick tips from under the rim, the catch, the
  dribbles, holds and walks are refused and listed on the screen with the reason. "Set shots only" is a
  toggle, on by default. The shooting hand is voted from the shots (the wrist extended further from the
  body at the top), 22 of 22 right on this clip; the camera side is never used.
- **Release instant.** The wrist's highest point from the 120 Hz body pass is within 3 frames (12.7 ms) of
  the ball-flight release on all 23 shots; a ball-left-the-hand frame is used only when it agrees with it
  to 15 ms. Every card says which was used and its spread (±8 ms ball, ±13 ms wrist).
- **What it cannot measure**, stated on the clip footer, the release card and the form section: release
  speed and angle, entry angle, depth, make or miss. Saved sessions carry `formClip: true` and never join a
  shot session's pool or the 30-shot floor.
- **Close-up simulation** (`TrajectoryProbe formclip … --crop 3`): cropping the 9 m clip 2.3× around the
  shooter leaves seen-fraction, jitter and hands-at-release unchanged (100 %, ~0.85 px, 100 %) — a crop
  adds no pixels, so the real gain of filming at 3–4 m is not measurable from this footage.
