# Phase 2 prep — tooling and synthetic baseline (2026-09-13, before Phase 0 footage)

## What exists

`Packages/ShotVideo` (AVFoundation + Vision, macOS 26 / iOS 26; depends on `ShotGeometry`, which stays pure):

| File | Content |
|---|---|
| `VideoReader.swift` | `AVAssetReaderOutput.Provider` frame loop with real per-frame PTS; `probe()` measures fps, jitter, gaps, transform. Gotchas learned: call `outputProvider(for:)` **before** `startReading()` and do not `add(output)` yourself; the provider's buffer cannot escape its closure, so the pixel buffer is re-wrapped with its original timing for Vision. |
| `TrajectoryTracker.swift` | One stateful `DetectTrajectoriesRequest` fed every frame; raw per-frame records kept; tracks reassembled from `timeRange.end` (see behaviour notes). Converts to `ShotGeometry.ImageSample`. |
| `SyntheticClip.swift` | Renders a `ShotSimulator` shot to a real video (textured background, rim ellipse, arm occluder, motion smear) plus a `.truth.json`. |
| `DetectorEvaluation.swift` | Scores any detector run against truth: recall below apex / final third (the brief's Phase 2 gate), centroid error, diameter bias, false positives; then runs `ShotAnalyzer` on the detector's own samples and compares θ, g, entry, h to truth. |
| `TrajectoryProbe` | CLI: `probe`, `track`, `frame`, `synth`, `eval`. |

```
cd Packages/ShotVideo && swift build -c release
.build/release/TrajectoryProbe probe  clip.mov                      # what the file really is (measured fps, jitter, gaps)
.build/release/TrajectoryProbe track  clip.mov --out run.json       # Vision trajectories → JSON
.build/release/TrajectoryProbe frame  clip.mov --time 1.5 --out f.png
.build/release/TrajectoryProbe synth  s.mov --fps 240 --view 30 --blur 0.5
.build/release/TrajectoryProbe eval   s.mov                         # gate numbers + pipeline comparison
```

## Vision `DetectTrajectoriesRequest` behaviour (observed, macOS 26.6, revision 1)

- `detectedPoints` is a sliding window of exactly `trajectoryLength` points; the same uuid persists for the whole flight; `timeRange.end` is the PTS of the newest point. Observations repeat on frames where no new point was added.
- `movingAverageRadius` is one value per observation, not per frame, and on a motion-smeared ball it over-reads the diameter by 8–10 px. **It cannot supply the per-frame ball size the azimuth solve wants.**

## Synthetic baseline (θ = 50°, FT distance, 30° view, camera 8 m / 1.3 m, ball 40–52 px, smear 0.5 frame)

| fps | Recall below apex (gate 90 %) | Recall final third (gate 75 %) | Centroid error mean / p90 px | Pipeline θ error | g error |
|---|---|---|---|---|---|
| 60 | 100 % | 100 % | 11.6 / 16.9 | −1.9° | 0.9 % |
| 120 | 97 % | 81 % | 5.9 / 8.6 | −1.5° | 1.0 % |
| 240 | 46 % | 29–33 % | 6.4 / 9.5 | −3.9° (−0.1° with length 5) | 0.5–0.6 % |

Reading it: at 240 fps Vision reports a new point on well under half the frames. The centroid error scales with the ball's per-frame displacement (≈ half a frame to one frame of lag), i.e. a **time-registration bias**, not random noise; g survives it, the back-extrapolated release does not. Both effects are on a clean synthetic ball, so real footage will be worse.

**Consequence:** Vision trajectory detection is the flight-window finder and a candidate generator; the per-frame detector (Create ML on crops, or WASB, see `docs/research/detection-and-capture-tech-2026-09-13.md`) is still required for Phase 2's ≤ 2 px target. The `eval` command is the gate harness for whichever detector comes next: give it a `TrajectoryRun`-shaped JSON and the same numbers come out.

## When the footage arrives

1. `probe` every clip; record measured fps and jitter in the session notes (slo-mo files may be 114–227 fps, not 240).
2. `track` a side-view FT clip; check the track count per shot and the flight time span against the audio call-outs.
3. Hand-label ~50 ball centres on two clips (the `frame` command exports PNGs) and run the scorer against those labels to measure Vision's real recall and the timing lag.
4. Decide the detector on those numbers, not on the synthetic ones.

## Real footage, evening of 2026-09-13 (first pass)

Clips in `footage/2026-09-13/` (git-ignored): `IMG_1764` elbow alternating sides, `IMG_1765` free throws, `IMG_1766` threes. Outdoor court, night, fan backboard, camera on the right wing ~8 m off the shot line, lens 1.2 m, 1× lens, tilted up slightly.

**Facts established**
- The exported files carry 30 fps timestamps but every frame is real: the ball's per-frame motion and a rim-free image-space gravity check give **120 fps** (time scale 4). The Camera.app slo-mo setting was 120, not 240. `probe` now reports edit-list stretch; here it was 1.0 because the export baked the slow-down in.
- **The apex leaves the top of the frame** for ~0.3 s real time on free throws. `FlightWindowFinder` now bridges gaps forward and backward when a joint fixed-g fit stays consistent.
- The first rim ellipse fit was pulled onto the backboard's red border (190 px instead of 115 px). Every scale failure traced to that. `docs/footage-2026-09-13/rim_1765.json` is the corrected fit (115 × 30 px, axis ratio 0.26, rim-plane normal within 8° of the image vertical, i.e. the pitch).
- Field of view: with the rim at ~9.3 m the 1080p120 slo-mo mode implies **hFOV ≈ 48°** (fx ≈ 2150), narrower than the 64° placeholder. Measure it properly in Phase 3.
- Vision trajectories: 8–19 px noise, duplicate tracks per flight, and the whole request aborts on busy frames ("too many moving objects") unless caught per frame. Usable only as a window finder.
- `BallDetector` (background difference on luma + Cr, seeded by Vision, extended backwards to the hands): ~4.5 px residual on clean flights; diameter under-reads on the dark side of the ball; drifts onto the shooter if not constrained to Vision's positions.
- The built-in shot-plane azimuth solve fails on this footage (missing apex, noisy diameters). `ShotPlaneSolver.solveByFixedGravity` (whole-track fixed-g scan, optional known release distance) gives a clean minimum on hand-picked shots but is not consistent enough across shots to pool per block (accepted shots' azimuths spread 120°).

**Results on hand-picked free throws** (time scale 4, hFOV 48°, known distance 4.4 m):

| file time | g_fit | error | release θ | h | v | entry | depth past front rim |
|---|---|---|---|---|---|---|---|
| 89 s | 9.17 | 6.5 % | 50.6° | 2.29 m | 7.11 m/s | 41.9° | 0.29 m |
| 313 s | 8.43 | 14 % | 41.5° | 2.82 m | 6.05 m/s | 37.6° | 0.22 m |
| 817 s | 9.67 | 1.5 % | 46.7° | 2.50 m | 7.48 m/s | 40.3° | 0.25 m |

Two of three inside the brief's 8 % Phase 3 gate, all physically plausible. The automated `session` pass over the whole clip (29 candidates, of which ~25 are shots) accepted g on ~6 and recovered a release on ~3: the batch is not yet trustworthy. Table in `docs/footage-2026-09-13/session_ft_batch.txt`.

**Review tooling**: `analyze … --review out.mov` and `session … --reviews dir` write a frame-per-frame overlay video (white ring = detection used, red = not used, dashed orange = fit prediction where nothing was detected, red double ring = release, orange ring = window end). Step with arrow keys in QuickTime Player. Three examples in `~/Desktop/arclab-review/`.

**What blocks the batch, in order**
1. Shot segmentation: candidates include rebounds and people; windows sometimes start mid-flight ("no-release"). Segment on the ball rising from the hands, not on Vision track ends.
2. Detector drift and diameter bias: a trained crop detector (Phase 2 plan) replaces the background-difference blob.
3. Azimuth: constrain per station from the routine (known distance) *and* pool across shots only after the per-shot solves agree within ~10°; otherwise report per-shot with σ.
4. Field of view: calibrate fx once per recording mode instead of inferring it from the rim.

## Release-instant ground truth (2026-09-14)

The shooter labelled the release frame on three review videos (`docs/footage-2026-09-13/release_labels.json`). Against them, the
pose-based release in `tools/pytrack/report.py` (ball ≥ 1 diameter from the nearer wrist, above it, rising) errs by −0.5, −4.5, −0.5
file frames (120 fps real: −4, −37, −4 ms); the ball-only release errs by −0.5, −12.5, +0.5. Mean bias −15 ms ≈ 0.8° of release
angle at 7 m/s. Pose-based release is the default; the ball-only rule fails whenever the tracker follows the held ball.

## Ball detector training (2026-09-14)

Create ML object detector, class `ball`, trained from the auto-labelled tiles exported by `tools/pytrack/export_labels.py`
(box centre in pixels, 512×512 JPEG). Script: `tools/createml/train_ball_detector.swift` (compiled with
`swiftc -O -framework CreateML`; uses `MLObjectDetector.DataSource.directoryWithImagesAndJsonAnnotation`,
transfer learning on `objectPrint(revision: 1)`, automatic validation split, `maxIterations 1500`).

**Data** (merged into `~/Desktop/arclab-labels-all`, hard links, split 85/15 on disk with seed 7 into `train/` and `test/`):

| source | ball tiles | negatives | total |
|---|---|---|---|
| `~/Desktop/arclab-labels` (free throws) | 277 | 77 | 354 |
| `~/Desktop/arclab-labels-elbow` (elbow) | 1,140 | 322 | 1,462 |
| train/ | 1,201 | 343 | 1,544 |
| test/ (held out, never seen in training or validation) | 216 | 56 | 272 |

**Command**
```
swiftc -O -framework CreateML -o tools/createml/train_ball tools/createml/train_ball_detector.swift
nohup tools/createml/train_ball ~/Desktop/arclab-labels-all --out ~/Desktop/BallDetector.mlmodel --iterations 1500 > tools/createml/train.log 2>&1 &
```

**Results**: in progress — `tail tools/createml/train.log`. The log ends with `training metrics`, `validation metrics`
and `held-out evaluation (272 tiles)` lines (mAP@IoU50 and mAP@variedIoU, per-class AP), then `wrote …/BallDetector.mlmodel`.
Held-out numbers are the ones to quote; the labels are auto-generated, so the mAP measures agreement with the
background-difference tracker, not with a human ground truth.

## Swift detector port (2026-09-14, agent-written, stopped by the user before completion)

`Packages/ShotVideo/Sources/ShotVideo/BallDetector.swift` now carries the Python tracker's rules (orange round candidates,
gravity-aware linking with top-edge re-entry, backward extension, projected-parabola template fill, `source`/`edge` flags).
With `analyze --classical --fixed-g-azimuth` (no distance constraint) on the three labelled free throws: g_fit 9.38 / 9.60 / 9.44
(all inside the 8 % gate); release recovered on one (48.1°, 2.31 m, 7.44 m/s at 817 s), late on one (89 s: window starts after the
release), absent on one (313 s). The Swift path still lacks the pose-based release that fixed this in Python; that is the next
port (MediaPipe → Vision `DetectHumanBodyPoseRequest` in ShotVideo).

## Swift pose stage (2026-09-14)

The pose-based release instant that made the Python pipeline accurate now exists in Swift, on Apple Vision.
Vision on macOS runs the same models as iOS, so these are the numbers the app will see.

**New in `Packages/ShotVideo`**

| File | Content |
|---|---|
| `PoseTracker.swift` | `JointSample` / `PoseFrame` / `PoseTracker.run(url:start:end:everyNthFrame:ballSeed:fps:)`. One `DetectHumanBodyPoseRequest` per frame decoded by `VideoReader.forEachFrame`; joints converted to top-left pixels with `toImageCoordinates(_:origin: .upperLeft)`; shoulders, elbows, wrists, hips, knees, ankles and the nose are kept, under the pytrack names (`l_wrist`, `r_elbow`, …) so the two pipelines can be diffed directly. Multi-person: the observation whose nearer wrist is closest to the ball seed, else the one with the largest joint bounding box. |
| `ReleaseFromPose.swift` | `ReleaseFromPose.estimate(detections:poses:ballDiameterPx:)` — `release_from_pose` from `tools/pytrack/report.py` verbatim: the first evidence-based ball sample that is ≥ 1.0 diameters from the nearer wrist (confidence ≥ 0.3), above it, and rising (v falls by > 2 px over the next three detections). Plus `PoseMetrics2D`: camera-side 2-D elbow and knee angles. |
| `TrajectoryProbe analyze --pose` | Runs the pose stage over the window (every frame), prints the estimated release in file time, and sets `windowOptions.releaseTimeOverride = pts / timeScale` **unless `--release-time` was given explicitly** (verified: an explicit `--release-time 204.20` still wins and the window note reports 204.200). `--pose-dump` prints, per detection, the nearer wrist, the distance in diameters, the above test and the rise over the next three detections. All existing flags behave as before; `analyze` without `--pose` is byte-identical to the previous release (817 s re-run: g 9.44, θ 48.1°, h 2.31 m, v 7.44 m/s, as recorded above). |

**Vision gotcha — and it matters on device.** `DetectHumanBodyPoseRequest` returns **zero** observations for a
`CVPixelBuffer`/`CMSampleBuffer` that carries the decoder's `CVCleanAperture` attachment — even the degenerate
full-frame one (1920×1080, offsets 0) that `AVAssetReader` attaches to every frame of these clips. The same frame
as a `CIImage` or `CGImage` detects the body normally, and so does the same buffer with that one attachment
removed; removing each attachment in turn showed `CVCleanAperture` is the only one that matters
(`AlphaChannelIsOpaque`, `CGColorSpace`, `CVFieldCount`, the chroma-location and Rec. 709 colour keys, `QTMovieTime`
are all harmless). `DetectTrajectoriesRequest` is unaffected, which is why the trajectory pass never showed it.
`PoseTracker` drops the attachment for the duration of the request and puts it back. Without this the stage
silently finds no body at all; with it, 210–222 of ~220 frames per window carry one.

**Release instant vs the shooter's labels** — `--classical --fixed-g-azimuth --pose`, `--time-scale 4 --hfov 48
--rim-diameter 0.4572` on `IMG_1765.mov`. 1 file frame = 33.3 ms file = 8.3 ms real.

| window (file s) | human label | Swift pose | error (file frames) | error (real) | Python/MediaPipe error |
|---|---|---|---|---|---|
| 88.5–95.5 | 90.150 | 90.633 | **+14.5** | +121 ms | −0.5 |
| 312.4–319.8 | 314.550 | 314.400 | −4.5 | −37 ms | −4.5 |
| 815.8–823.2 | 817.350 | 817.333 | −0.5 | −4 ms | −0.5 |

**The 89 s miss is the ball detector, not the pose.** Running the identical pose stage on the Python ball track
(`--track-json tools/pytrack/shots/ft/shot{05,11,24}.json --pose`) gives 90.133 / 314.367 / 817.333, i.e.
−0.5 / −5.5 / −0.5 file frames: **Vision body pose reproduces the MediaPipe-based rule to within one file frame on
all three shots.** `--pose-dump` over the 89 s window shows what goes wrong in the classical path: from file
90.03 to 90.13 the Swift detector's "ball" sits on the hands at (449, 432) while the Python track has the ball at
(452, 267); it then locks onto a static torso blob at (331, 528) for ten frames, and its first true ball sample is
at 90.633. The rule fires on the first honest sample it is handed. (Vision's wrist sits ~20 px from MediaPipe's
and reports confidence 0.7–0.85 where MediaPipe reports 0.99; neither difference moved the release.)

**Geometry with the pose release** (same three `--classical --fixed-g-azimuth --pose` runs)

| window | g_fit | verdict | rms | view | θ | h | v | L | entry | depth | pose: elbow rel / max, knee min |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 89 s | 8.83 (−10.0 %) | lowConfidence | 9.74 px | 30° oblique | 42.0° | 2.73 m | 6.38 m/s | 4.13 m | 36.7° | 0.28 m | 168° / 169°, 116° |
| 313 s | 9.36 (−4.6 %) | accept | 9.50 px | 15.9° side | 48.8° | 2.35 m | 6.99 m/s | 4.45 m | 39.6° | 0.24 m | 119° / 172°, 129° |
| 817 s | 9.44 (−3.8 %) | accept | 4.95 px | 39.0° oblique | 46.6° | 2.48 m | 7.23 m/s | 4.88 m | 39.6° | 0.27 m | 163° / 177°, 121° |

Python path, for orientation only — these were *not* tuned to: θ 48–51°, h 2.3 m, v 7.0 m/s at 89 s; θ 46°,
h 2.3 m, v 6.7 m/s at 313 s; θ 47°, h 2.5 m, v 7.4 m/s at 817 s.

- **313 s and 817 s**: within 1–3° of the Python release angle, within 0.2 m/s of its speed and 0.05–0.2 m of its
  height, both inside the brief's 8 % gravity gate. 313 s previously produced **no** release at all.
- **89 s**: the shot whose release is 121 ms late, and the metrics carry exactly that signature — higher
  (2.73 vs 2.3 m), shallower (42° vs ~50°) and slower (6.38 vs ~7.0 m/s) than the truth, with g_fit dropping from
  9.38 (4.3 %, accept) before the pose stage to 8.83 (10.0 %, lowConfidence) after it. Forcing a release instant
  onto a contaminated track makes the fit *worse*, not better. The detector has to be fixed first; the
  Create ML ball detector is the intended replacement.
- Before this stage the classical Swift path recovered a release on one of three windows. It now recovers one on
  all three, and two of the three are within half a file frame of the human label.

**Caveat on the 2-D angles**, which the probe prints with every pose line: only 313 s is classified `side` (16°);
89 s and 817 s are `oblique` (30°, 39°), so their elbow and knee numbers are camera-plane projections, not true
joint angles — the brief allows them for near-side views only. The 313 s elbow at release (119°, against a 172°
maximum a few frames later) says the rule fires a few frames before full extension there, which is the same
−4.5-frame bias the Python rule had on that shot.

**Next**, in order: (1) the ball detector through the release — it is now the only thing standing between this
stage and a correct 89 s; (2) restrict the azimuth solve to the flight range when the track carries held frames
(the `--track-json … --pose` run at 89 s fits g = 25.9 because every pre-release hand sample enters the azimuth
fit — `--flight-range` fixes that and the Python path always passes it).

## Three-point block status (2026-09-14, end of session)

Tracking now reaches the rim on threes (weak candidates accepted near an established parabola). Geometry with `--level-pitch 8.3`
(zero roll) is internally consistent on 12 shots (release 42–48°, h 2.3–2.9 m, v 6.9–7.4 m/s, entry 37–46°) but g_fit is 9–16 % low
on all of them: a uniform scale error of that clip's rim calibration (ring at the frame edge). Tried and rejected: same-camera
rim distance (made it worse: that ellipse already solves farther), known distance 7.0 m / none (no change), and a gravity-derived
time base (wrong sign: a lower recording rate raises g_fit, so the low g cannot be a frame-rate effect). Next: calibrate that
block from the backboard + rim jointly or from a lens calibration, then re-run `report.py shots/three`.
Sign rule worth remembering: g_fit = g_true · (fps_assumed / fps_true)². Low g_fit with a correct time base means the metric
scale is too small (rim placed too close).

## Core ML detector integration (2026-09-14)

The trained Create ML detector is now the **primary per-frame ball detector** inside `BallDetector`, with the
background-difference blobs kept as the per-frame fallback. Linker, top-edge re-entry, backward extension and
template fill are untouched and cannot tell which stage produced a candidate.

### What was built

| File | Change |
|---|---|
| `Packages/ShotVideo/Sources/ShotVideo/Resources/ArcLabBallModel.mlmodel` | the trained model, shipped as a package resource (`resources: [.process("Resources")]`). |
| `Packages/ShotVideo/Sources/ShotVideo/CoreMLBallDetector.swift` | `CoreMLBallDetector.detect(pixelBuffer:roi:minConfidence:)` → boxes in full-frame top-left pixels. Cuts 512-px square tiles at native resolution, runs the model, converts the normalized centre/size boxes, and suppresses duplicates from overlapping tiles. |
| `BallDetector` | `BallDetectorOptions.useCoreML` (**default `true`**), `coreMLMinConfidence` (0.30), `coreMLGapFrames`, `coreMLGlobalSearchEveryNthFrame`. New `BallDetector.runDetailed(…)` returns `(detections, BallDetectorStats)`; `run` still returns just the detections. |
| `TrajectoryProbe analyze` | `--classical` still means "run `BallDetector`"; **`--no-coreml`** forces the old path, `--coreml-confidence C` overrides the threshold. Prints `detector: coreml N frames, classical fallback M frames, mean inference X ms` plus the tile breakdown. |

**How a frame is searched.** The detector keeps a causal aiming track of its own last few boxes. With a live
prediction (or, failing that, the caller's coarse Vision seed) one 512-px tile is cut around it — one inference.
Three missed frames widen the region by one tile per side, capped at two. With nothing to aim at, the whole frame
is swept on a stride-448 grid (15 tiles at 1080p). The linker does its own, stricter, gating afterwards.

### Two facts that cost time, recorded so nobody repeats them

**Vision will not run this model.** `docs/reference/sdk-and-licensing-research-2026-09-12.md` §1(d) lists
`CoreMLRequest` / `CoreMLModelContainer` / `RecognizedObjectObservation` and flags the result type as unverified.
Measured on macOS 26.6: `CoreMLModelContainer(model:)` builds and reports `inputImageFeatureName == "image"`, but
`perform` throws `VisionError.invalidModel("The inputImageFeatureName does not point to a MLFeatureTypeImage
input.")` — and the legacy `VNCoreMLRequest` throws the same underlying error (Vision code 15). Tried and failed:
with and without a `featureProvider` for the model's two optional `Double` inputs, with `inputImageFeatureName`
assigned explicitly, on a plain 512×512 buffer with no region of interest, and on the full frame with one. The
model is a three-stage pipeline (`VisionFeaturePrint.Object` → neural network → non-maximum suppression) whose
image input carries a **flexible** size (299…×299…); Vision appears not to accept that combination.
`MLModel.prediction(from:)` on the same buffer works, so `CoreMLBallDetector` cuts its own tile and calls Core ML
directly. Nothing is lost — the pipeline already ends in an NMS layer, which is all `RecognizedObjectObservation`
would have added. The unverified note in §1(d) should now read "verified false for Create ML pipeline detectors
with a flexible-size image input".

**Resource naming and compilation.** SwiftPM does *not* run the Core ML compiler: `swift build` logs
`Copying ArcLabBallModel.mlmodel` and the raw file lands in `ShotVideo_ShotVideo.bundle`. An **Xcode** build does
compile it — and generates a Swift class named after the file, so a resource called `BallDetector.mlmodel` collides
with this package's own `BallDetector` type and breaks the app build. Hence `ArcLabBallModel`. The loader prefers
`ArcLabBallModel.mlmodelc` from the bundle (the app build's output, verified present in `ArcLab.app`) and otherwise
compiles the `.mlmodel` once into `Caches/ArcLab/` — so both the desktop probe and the phone work.

### Input scale: the source window matters, the model's input size does not

On the 272 held-out tiles (`~/Desktop/arclab-labels-all/test`, never seen in training or validation), the same
512×512 tile fed to Core ML at five input sizes:

| Core ML input | recall (tiles with a ball) | centre error vs the label, mean / median / p90 px | size error | false boxes / 37 negative tiles | ms/tile |
|---|---|---|---|---|---|
| 299 | 100 % (163/163) | 9.73 / 8.22 / 18.8 | −0.9 px | 43 | 6.7 |
| 384 | 100 % | 9.79 / 8.35 / 17.6 | −0.9 px | 40 | 7.2 |
| 512 | 100 % | 10.36 / 8.76 / 18.1 | −0.6 px | 48 | 7.1 |

Input resolution is irrelevant (the feature extractor resizes internally); what matters is that the **source window
is 512 px of 1080p**, the field of view the tiles were cut at. Signed bias is small (x −1.1, y +3.1 px), which also
confirms the box-centre convention and the tile→frame conversion. Note the labels were auto-generated by the
background-difference tracker, so this measures agreement with *that*, not with a human.

### Results — `--classical --fixed-g-azimuth --pose`, `--time-scale 4 --hfov 48 --rim-diameter 0.4572`

Coverage = detections inside the flight window ÷ (flight span × 120 fps + 1). 1 file frame = 33.3 ms file = 8.3 ms real.

**`IMG_1765.mov` free throws** (`--rim rim_1765.json`; human release labels 90.150 / 314.550 / 817.350 s):

| window | detector | release | err (file frames) | g_fit | θ | h | v | L | entry | apex | coverage | rms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 88.5–95.5 | classical | 90.633 | **+14.5** | 8.83 (10.0 %) | 42.0° | 2.73 m | 6.38 m/s | 4.13 m | 36.7° | 3.76 m | 52/96 = 54 % | 9.74 px |
| 88.5–95.5 | **Core ML** | 90.000 | **−4.5** | 8.86 (9.7 %) | **50.2°** | 2.15 m | **7.11 m/s** | 4.67 m | 39.3° | 3.83 m | 87/127 = 69 % | 11.12 px |
| 312.4–319.8 | classical | 314.400 | −4.5 | 9.36 (4.6 %) | 48.8° | 2.35 m | 6.99 m/s | 4.45 m | 39.6° | 3.82 m | 95/98 = 97 % | 9.50 px |
| 312.4–319.8 | **Core ML** | 314.400 | −4.5 | 8.81 (10.2 %) | 48.3° | 2.16 m | 6.93 m/s | 4.56 m | 35.8° | 3.68 m | 115/115 = 100 % | 10.46 px |
| 815.8–823.2 | classical | 817.333 | −0.5 | 9.44 (3.8 %) | 46.6° | 2.48 m | 7.23 m/s | 4.88 m | 39.6° | 3.94 m | 116/117 = 99 % | 4.95 px |
| 815.8–823.2 | **Core ML** | 817.333 | −0.5 | **9.73 (0.8 %)** | 45.1° | 2.64 m | 7.34 m/s | 5.11 m | 40.2° | 4.03 m | 120/120 = 100 % | 7.91 px |

Python path, for orientation only — **not** tuned to: 89 s θ 48–51°, h 2.3 m, v 7.0 m/s; 313 s θ 46°, h 2.3 m,
v 6.7 m/s; 817 s θ 47°, h 2.5 m, v 7.4 m/s.

**`IMG_1766.mov` three, 455.6–464.2** (`--rim rim_1766.json --level-pitch 6.3 --known-distance 6.3`; no human
release label). Reference: entry ≈ 44°, apex ≈ 4.4 m.

| detector | release | g_fit | θ | h | v | L | entry | apex | coverage | rms |
|---|---|---|---|---|---|---|---|---|---|---|
| classical | 458.067 | 8.72 (11.1 %) lowConfidence | 45.7° | 2.77 m | 7.27 m/s | 5.82 m | 42.9° | 4.32 m | 113/122 = 92 % | 10.29 px |
| **Core ML** | 458.033 | **9.05 (7.7 %) accept** | 46.2° | 2.81 m | 7.39 m/s | 5.90 m | **43.9°** | **4.39 m** | 133/133 = 100 % | 12.43 px |

### Reading it honestly

- **The 89 s release is fixed.** That shot was the open item at the end of the pose-stage section: the classical
  detector sat on the hands and then on a torso blob, so the pose rule fired 14.5 file frames (121 ms) late and the
  metrics carried exactly that signature. The Core ML detector finds the ball through the release, the pose rule now
  fires 4.5 frames *early* instead, and θ moves 42.0° → 50.2° and v 6.38 → 7.11 m/s, i.e. from well outside the
  Python reference to inside it. **All three free throws now sit within ±4.5 file frames of the human label.**
- **Coverage is up on every window** (54→69 %, 97→100 %, 99→100 %, 92→100 %), and the track starts 3–19 frames
  earlier and survives further past the rim. Template fill has almost nothing left to do (43 → 12 filled frames at
  817 s, 27 → 1 at IMG_1766).
- **g is not uniformly better: 817 s 3.8 % → 0.8 % and IMG_1766 11.1 % → 7.7 % (now inside the 8 % gate), but
  313 s 4.6 % → 10.2 %, out of it.** Two of four windows pass the gate either way; the change is not a clean win.
- **The centroid is noisier than the classical one.** Frame-by-frame over the 817 s window, on the 131 frames both
  produce: |Δ| mean 12.0 px, median 12.2, p90 19.2, with a −5.5 px vertical offset. Held-out-tile centre error is
  ~10 px mean against labels whose own tracker residual was ~4.5 px. So the model is markedly better at *finding*
  the ball (association, hands, occlusion, off-frame re-entry) and worse at *placing* it. That is the whole story of
  the table: release instants and coverage improve, per-sample rms rises (4.95 → 7.91 px at 817 s).
- **Boxes inflate near the rim.** Measured diameters run 47–106 px at 817 s against a true ~51 px ball, the large
  ones all in the last ~10 frames where the box swallows rim and net. Harmless for the fixed-g azimuth solve (which
  does not use diameters) but it rules the boxes out as a depth cue as they stand.
- The obvious next step, not taken here because the brief fixed the design: use the Core ML box to *choose* which
  background-difference blob is the ball and take the sub-pixel centroid from the blob. That would keep the model's
  association and the classical detector's 4.95 px placement.

### Speed

7.3–8.2 ms per 512-px tile on this M-series Mac (crop included; `computeUnits = .all`).

| window | tiles/frame | mean per frame | one-tile frames |
|---|---|---|---|
| 88.5–95.5 | 5.87 | 44.8 ms | 132 at 7.6 ms |
| 312.4–319.8 | 3.00 | 23.5 ms | 182 at 7.7 ms |
| 815.8–823.2 | 4.17 | 31.3 ms | 163 at 7.5 ms |
| IMG_1766 | 6.61 | 49.0 ms | 149 at 7.3 ms |

**Against the < 30 ms/frame phone budget:** the steady state — a ball being tracked, one aimed tile — is
**7.3–7.8 ms/frame**, comfortably inside it, and an A16 ANE should not be slower than this Mac. The mean is blown
out by the whole-frame sweep used when there is nothing to aim at: 15 tiles ≈ 110 ms, and 22–99 frames per window
need one (mostly before the ball is in the air). That sweep is the thing to fix before the phone —
`coreMLGlobalSearchEveryNthFrame` throttles it today (default 1, i.e. every frame, as specified), but the right
answer is to reacquire from motion (Vision trajectories or the background difference) and spend Core ML only on a
confirmed region. A whole window costs 7–14 s wall clock against 1.5–2.0 s for the classical path.

### Gates re-checked

- `cd Packages/ShotGeometry && swift test` → **14 tests, 0 failures** (unchanged).
- `cd App && xcodebuild -project ArcLab.xcodeproj -scheme ArcLab -destination 'generic/platform=iOS Simulator' build`
  → **BUILD SUCCEEDED**, with `ShotVideo_ShotVideo.bundle/ArcLabBallModel.mlmodelc` in the built `.app`.
- `analyze --classical --no-coreml` reproduces the previously recorded classical numbers exactly on all three free
  throws (8.83 / 9.36 / 9.44, θ 42.0° / 48.8° / 46.6°), so the old path is intact.

## Three-point scale error: root cause (2026-09-14)

**Cause: the focal length.** `--hfov 48` was never measured — it was back-derived from an *assumed*
9.3 m rim distance ("Real footage, evening of 2026-09-13", above), so the pipeline's only absolute
length scale rested on a pace-out. The 1080p120 mode's real field of view is **66.5° ± 2°**
(fx ≈ 1465 px, not 2156). Everything else on the suspect list — time base, drag, plane azimuth,
edge-clipped samples, rim tracing — moves g by a few percent at most.

### The measurement (independent of any shot)

Vanishing points on a 33-frame median of each clip (`cv2.createLineSegmentDetector` + RANSAC).
The light poles and fence posts give the vertical vanishing point; the court's ground lines give a
horizontal one that falls *inside* the frame, so it is well conditioned. The two directions are
orthogonal, so with square pixels and the principal point at the image centre, f² = −(v₁−c)·(v₂−c).

| clip | vertical VP | ground VP | fx (px) | hFOV |
|---|---|---|---|---|
| IMG_1764 elbow | (1314, −10892) | (931, 728) | 1470 | 66.3° |
| IMG_1765 free throws | (1191, −10141) | (1048, 733) | 1430 | 67.8° |
| IMG_1766 threes | (1837, −13064) | (965, 704) | 1494 | 65.4° |

Three clips, three pans, ±2 %. An iPhone 14 Pro 1× lens is 24 mm-equivalent, i.e. ~71° horizontal at
full sensor width; 66.5° is that minus the stabilisation crop. 48° would be a ~40 mm lens.

**Cross-check 1 — where the calibration puts the lens.** The rim ellipse's axis ratio fixes the
elevation of the line of sight almost independently of fx, so fx alone decides the distance and
therefore the implied camera height (3.048 m − rim height above camera):

| hFOV | IMG_1764 | IMG_1765 | IMG_1766 |
|---|---|---|---|
| 48° | 0.49 m | 0.50 m | 0.22 m |
| 66.5° | 1.11 m | 0.90 m | 1.05 m |

The field note for that evening says "lens 1.2 m". 48° puts the phone on the floor — that single
sanity check would have caught this on day one, and `RimCalibrationOptions.plausibleCameraHeight`
now emits it as a calibration warning.

**Cross-check 2 — the shooter's feet.** Intersect the ray through the median ankle landmark (in the
standing frames before the dip) with the floor plane 3.048 m below the rim centre, and measure the
horizontal distance to the rim. This uses no trajectory, no time base and no gravity; the elbow
station was tape-measured at 4.85 m and the three-point line is 6.75 m.

| block (expected) | 48° | 60° | 64° | 66.5° | 70° |
|---|---|---|---|---|---|
| elbow (4.85 m) | 14.30 | 4.89 | 4.77 | 4.72 | 4.68 |
| threes (6.75 m) | 16.07 | 7.04 | 6.89 | 6.83 | 6.76 |
| free throws (4.19 m) | 7.82 | 4.90 | 4.85 | 4.82 | 4.55 |

At 48° the geometry is not merely biased, it is absurd. The free-throw row also settles an old
puzzle: the shooter in IMG_1765 was **not on the line** — his ankle ray cannot reach 4.19 m at any
lens height (the minimum is 4.31 m), and the per-shot stations cluster at 4.7–4.9 m. That is where
the 4.4 m `--known-distance` used earlier came from.

### Why it hid, and why the threes were worst

Two effects, both quiet, both in the same direction:

1. The conic solve reads the rim's distance from its *angular* size, correcting the `cos²θ`
   perspective stretch of an off-axis circle. θ depends on fx, so too narrow an fx under-corrects
   the stretch and shrinks metres-per-pixel at the rim — a uniform scale error per block, worst for
   the block whose rim sits furthest off-axis (threes 836 px from the principal point, free throws
   685, elbow 488).
2. It also puts the rim too far away, so the shot plane looks too flat and the foreshortening along
   the flight is under-corrected — a deficit that **grows with the shot distance**.

`Packages/ShotGeometry/Tests/ShotGeometryTests/FocalLengthTests.swift` reproduces both from the
simulator at this camera pose (truth 66.5°, analysed at 48°):

| release distance | g_fit | release distance read back |
|---|---|---|
| 4.19 m | 9.36 (−4.6 %) | 4.12 m |
| 4.85 m | 9.24 (−5.8 %) | 4.73 m |
| 6.45 m | 8.89 (−9.4 %) | 6.14 m |

At 66.5° the same simulations return g = 9.79 and the exact release distances. That is the field
pattern — free throws inside the 8 % gate, elbow ~6 % low, threes 9–16 % low — from one wrong number.

### Rim tracing, measured (IMG_1766's trace is also bad)

Traced ellipses: IMG_1764 113.17 × 31.36 px, tilt −4.1°; IMG_1765 115.14 × 30.30 px, −3.4°;
IMG_1766 114.78 × 32.04 px, **+10.2°**. Fitting the only ellipse family the scene allows — the image
of a *horizontal* circle whose normal is the pole-derived vertical — to each trace gives an rms of
**0.62 px (1764), 1.73 px (1765), 6.19 px with a 12.1 px worst point (1766)**. IMG_1766's trace is
not the image of a horizontal circle: its own normal implies a −18° camera roll (the other clips
give −0.7° and −3.3°), because the right end of the trace runs along the red backboard bracket at
x = 1780–1817. `--level-pitch` papered over that; `analyze` now prints a warning when the override
disagrees with the traced ellipse's own normal by more than 8° (IMG_1766: 19.1°).

Sensitivity of `RimCalibrator.calibrate` at this pose (rim synthesised at 7.41 m, image centre
(1760, 300), hFOV 66.5°, 64 boundary points):

| perturbation | distance error | rim-normal error |
|---|---|---|
| ideal inner-edge trace | 0.0 % | 0.0° |
| traced the outer edge, told 0.4572 | −6.5 % | 0.0° |
| traced the tube centre-line, told 0.4572 | −3.4 % | 0.0° |
| 1 px isotropic noise (200 draws) | −0.4 % ± 0.8 % | — |
| 2 px isotropic noise (200 draws) | −1.8 % ± 1.5 % | — |
| left 30 % of the boundary missing | 0.0 % | 0.0° |
| right 30 % of the boundary missing | 0.0 % | 0.0° |
| right end dragged onto a bracket (+2, +5 px) | −2.8 % | 2.9° |
| right end dragged onto a bracket (+3, +9 px) | −6.0 % | 5.3° |

So: **keep the full conic solve** — taking the major axis alone would need exactly the `cos²θ`
off-axis correction the conic already applies, and a joint inner+outer fit buys nothing. What costs
is *which* edge and *local* contamination; arc coverage costs nothing as long as the points that
remain are accurate (the two coverage rows above are noiseless — with 1–2 px noise a short arc also
loses conditioning).

**Tracing rule** (this is what must not recur): trace the **inner** edge of the ring's tube — the
opening the ball passes through, 0.4572 m — put points only where the tube is unambiguous, never on
a bracket, backboard border or net loop, and leave gaps rather than guess. Then validate before use:
the trace must fit the image of a horizontal circle to ≲ 2 px, and the implied lens height must be
where the phone actually was.

Which edge the existing traces follow, measured on IMG_1765's left end (ring against dark sky):
the redness band's centre sits 59.7 px from the ellipse centre against a traced semi-major of
57.6 px, and the tube is 15.9 mm ≈ 4 px at 252 px/m — so the trace is within ~1 px of the **inner**
edge and 0.4572 is the right constant. (The outer 50 % crossing reads 66 px, which is bloom on the
dark side, not ring.) Sub-pixel circle fits to the ball's silhouette near the rim agree: 63.6–64.6 px
(IMG_1765) and 61.6 px (IMG_1764) against 60.0 / 59.0 px predicted by the inner-edge reading, where
an outer-edge reading (0.489) would predict 56.1 / 55.2 px.

### Results

`report.py shots/three --hfov 66.5 --level-pitch 6.3` (6.3° is the measured pitch from IMG_1766's
pole vanishing point, replacing the assumed 8.3°), rim diameter 0.4572, time scale 4:

| | hFOV 48 (before) | hFOV 66.5 (after) |
|---|---|---|
| windows passing the 8 % gravity gate | 1 of 27 (with impossible release values) | **10 of 27** |
| g_fit | 8.4–8.9 | **9.13 ± 0.10** |
| release angle | — | 46.57 ± 1.77° |
| release height | — | 2.63 ± 0.12 m |
| release speed | — | 7.61 ± 0.11 m/s |
| entry angle | — | 42.41 ± 2.32° |
| depth past front rim | — | 3.2 ± 14.0 cm |
| shot 8 | g 8.51, L 5.78 m | g 9.10, L 6.05 m |

Elbow block, same flags either side: **2 of 43 → 7 of 43** through the gate, g 9.18 ± 0.19.
(The 16 of 43 quoted in the pytrack README came from a run with `--known-distance`, which constrains
the azimuth; it is not comparable.)

### The 7 % that is left, unclosed on purpose

g on the threes is now 9.13 ± 0.10 over ten shots — the SD is 1 %, so the remainder is a single
systematic scale factor of −6.9 %, not noise. It is *not*:

- near-frame-edge samples: dropping every sample above the top 40 px of the frame moves shot 8 by
  0.7 % (9.06 → 9.12);
- drag (< 1 %, digest A-C2) or the time base (would need 124.4 fps, and duplicate-frame counts rule
  that out);
- the plane azimuth: the ten accepted threes solve to 0.3–10.3° from side-on, and their g values
  span only 9.02–9.32 across that range.

The release distance agrees with the same factor and so is evidence, not a second problem: the ten
accepted threes read L = 6.09 ± 0.08 m where a 6.75 m line implies ≈ 6.45 m at the ball — short by
5.6 %, against g short by 6.9 %. One scale, two symptoms.

It would close exactly if `--rim-diameter` were 0.489 (the ring's outer diameter, +7.0 %), and it is
tempting for that reason. **Do not do it**: both direct measurements above say the traces follow the
inner edge, and the ball-silhouette check rules the outer reading out at 13 %. Leaving g 7 % low and
labelled beats a number tuned to 9.81. Candidates still open, in order: the principal point (a ±30 px
error moves the vanishing-point fx by ∓4°), lens distortion at 800 px off-axis (uncorrected in the
pinhole model), and the ball-centroid bias of the tracker near the frame edges.

### What changed

- `Packages/ShotGeometry/Sources/ShotGeometry/Simulator.swift`: `CameraPlacement.iPhone14Pro1080p120()`,
  the measured 66.5°, with the method and the warning never to infer fx from an assumed rim distance.
  `iPhone1080p()` stays at 64° because Phase 1's gate numbers were produced with it.
- `Packages/ShotGeometry/Sources/ShotGeometry/RimCalibration.swift`:
  `RimCalibrationOptions.plausibleCameraHeight` (0.6–2.4 m) and a calibration warning when the
  solve puts the lens outside it. On the real clips at 48° it says "puts the lens 0.22 m above the floor".
- `Packages/ShotGeometry/Tests/ShotGeometryTests/FocalLengthTests.swift`: three tests — the correct
  fx recovers g and L at every shot distance; 48° reproduces the distance-dependent deficit and the
  short release distance; 48° implies an impossible lens height and trips the warning.
- `Packages/ShotVideo/Sources/TrajectoryProbe/Probe.swift`: `--level-pitch` now reports how far the
  override is from the traced ellipse's own normal and warns past 8°.
- `tools/pytrack/report.py`: default `--hfov` 48 → 66.5, with the provenance in a comment.
- Gates: `swift test` 17 tests, 0 failures; `swift run -c release GeometryHarness` → GATE: PASS
  (scenario I still marginal, identical to `docs/PHASE1-REPORT.md`).

---

## Body model (2026-09-14)

Beyond ball metrics: a per-shot **body model** — every joint, plus the directional cues (eyes/ears/nose
for the head, hand landmarks for the release) — so a shooter can be modelled, not just their ball.

### What was built

| File | Content |
|---|---|
| `Packages/ShotVideo/Sources/ShotVideo/BodyTracker.swift` | One decode pass over a window running **three** Vision requests per frame on a tracked crop: `DetectHumanBodyPose3DRequest` (17 joints, metres, model-space + camera-relative + image point), `DetectHumanBodyPoseRequest` (19 points incl. left/right eye, ear, nose, neck), `DetectHumanHandPoseRequest` (≤ 2 hands × 21 landmarks). Emits `ShotGeometry.BodyTimeline`. |
| `Packages/ShotGeometry/Sources/ShotGeometry/BodyKinematics.swift` | Foundation + simd only. True 3-D joint angles, shot phases, kinetic chain, stance, head, hands, and `BodySummaries` (mean/SD/n). Every number is a `BodyMeasure`: a value, or nil **with a reason**. |
| `Packages/ShotGeometry/Tests/.../BodyKinematicsTests.swift` | 36 tests: synthetic skeletons with known angles, yaw, lean and stagger; nil-with-reason contracts; the two degeneracy gates the real footage forced. |
| `Packages/ShotVideo/Sources/TrajectoryProbe/BodyCommand.swift` | `TrajectoryProbe body <clip> --start --end --release-time [--track-json --rim-u --pad --every --no-crop --check-3d --json]`. One line was added to `Probe.swift`'s dispatch (`case "body": …`) — the only edit to a file this work does not own. |

### Vision facts measured on macOS 26 (not read — measured on IMG_1765)

- **`Joint3D` has no per-joint confidence.** Only the observation carries one. `BodyJoint3D.confidence`
  is therefore `nil`; the observation confidence is on the frame. Inventing a per-joint number would be
  fabricating one.
- **The 3-D request needs a fixed input size.** It is a `StatefulRequest`: with a crop whose size changed
  frame to frame it returned a body on **1 of 12** frames; with the crop size locked for the pass, **29 of
  30**. `BodyTracker` locks the size after the first detection and only translates the box afterwards.
- **A tight crop loses the person; a fixed, moderately padded one is best.** Padding sweep (shooter ≈ 500 px
  tall in 1080p): pad 0.3 → 26/30 frames with a 3-D body, 0.6 → 29/30, 1.5 → 30/30 but the crop is then most
  of the frame. Default `cropPadFraction = 0.60`.
- **The crop is what makes the 3-D arm usable at all.** Same shot, same frame: elbow at release **108.5°
  cropped vs 26.8° full-frame** (2-D reads 139.3°), and the full-frame elbow never exceeds 119° across the
  whole shot — i.e. the arm never straightens, which is impossible.
- The `CVCleanAperture` strip from `PoseTracker` is still required for the full-frame passes.
- Cost on an M-series Mac with all three requests on the locked crop: **19–24 ms per frame**
  (42–53 frames/s), against ~35 ms/frame for two requests on the full frame — the crop pays for itself.
- `heightEstimationTechnique` is **`reference`** on every frame of this footage (no depth): `bodyHeight`
  is a 1.80 m population prior, so every "metre" is a prior-scaled length, not a measurement.

### Verification — the three labelled free throws (IMG_1765, scale 4, releases from `release_labels.json`)

| | shot05 (t 88.5–95.5) | shot11 (312.4–319.8) | shot24 (815.8–823.2) |
|---|---|---|---|
| 3-D body / analysed frames | 194 / 210 | 200 / 222 | 170 / 222 |
| 2-D body (of 19 pts ≥ 0.3 conf) | 210 / 210 (18.8) | 222 / 222 (18.6) | 221 / 222 (19.0) |
| hands (landmarks, hands/frame) | 147 (21.0, 1.61) | 169 (21.0, 1.59) | 121 (21.0, 1.07) |
| speed (all three requests) | 24 ms/frame (42 fps) | 22 ms/frame (45 fps) | 19 ms/frame (53 fps) |
| **elbow at release: 3-D vs 2-D** | 97.0° vs 139.3° (**−42.3**) | 154.9° vs 158.8° (**−3.9**) | 109.5° vs 163.3° (**−53.8**) |
| kinetic chain | hip→knee→elbow→wrist→shoulder (**not** P→D) | knee→hip→shoulder→elbow→wrist (**P→D**), lags 0/8/0/58 ms | knee→hip→wrist→shoulder→elbow (**not** P→D) |
| dip→release | 271 ms | 38 ms (wrong) | 238 ms |
| shoulder-line yaw / 2-D squareness | 5.7° / 0.309 | −4.5° / 0.218 | 1.2° / 0.221 |
| torso lean sagittal / frontal | 2.4° / −4.2° | 0.1° / 1.9° | 4.4° / 13.3° |
| head yaw / stability / faces rim | 95.1° / 26.2 px / yes | 99.0° / 4.3 px / yes | 69.3° / 9.5 px / yes |
| wrist snap at release | 110 °/s | 7414 °/s (nonsense) | nil (no hand within 50 ms) |

Per-frame noise (SD of consecutive differences ÷ √2, digest Ch 10 §10.5.1), over each whole window:

| signal | shot05 | shot11 | shot24 | compare with |
|---|---|---|---|---|
| 3-D elbow | 2.41° | 7.81° | 8.75° | Ch 12 2-D floor 1.4° bent / 2.3° straight |
| 3-D knee | 0.85° | 3.06° | 8.58° | `knee_min_deg` differences of interest ≈ 5–10° |
| 3-D shoulder elevation | 2.32° | 6.82° | 5.71° | — |
| 3-D shoulder-line yaw | 0.65° | 4.26° | 9.75° | Ch 12 squareness gate fires at 15° |
| 2-D nose u | 1.03 px | 1.14 px | 0.99 px | Ch 11 expects 2–5 px |
| 2-D shooting wrist v | 2.08 px | 2.45 px | 1.68 px | Ch 11 expects 2–5 px |

**Verdict at 9 m with a ≈ 500 px shooter.**

*Trustworthy.* The **2-D** stage: nose 1.0 px and wrist 1.7–2.5 px of per-frame noise, at or below Ch 11's
expected 2–5 px — head stability, head facing (nose offset 12–33 px against a 3 px floor, unanimous "faces
the rim" on all three), 2-D squareness (0.22–0.31, stable), and the existing 2-D elbow. Phase *timing* from
the wrist path is usable when the dip is inside the window (271 and 238 ms; shot11's 38 ms is a window
artefact, and the reason string says so).

*Noise.* The **3-D** stage's angles: 2.4–8.8° per frame on the elbow against a 2-D floor of 1.4–2.3°, and a
release elbow that disagrees with the 2-D value by −4°, −42°, −54° on three shots of the same shooter. A
Tier-B finding needs a deviation above 2 × the reliability SD (Ch 13 §13.6); at 8° per frame the 3-D elbow
cannot resolve anything the 2-D angle cannot. The kinetic-chain *order* recovered proximal-to-distal on 1 of
3 shots, and four of its lags were 0 or 8 ms — 8.33 ms is one file frame, i.e. the resolution floor, so those
orderings are coin flips. Head yaw reads 69–99°, outside the ±60° validity of its own model (the far ear is
occluded on this view) — report the facing *direction*, never the yaw angle.

*Refused outright* (nil with a reason, by design):

- **Foot direction**: `feetStaggerFromToes` is always nil — "no toe landmark in the Vision body model".
  Ankle joint angles likewise. Never estimated from the ankle.
- **Every metre.** `BodyKinematics` refuses `jumpHeight`, `hipDrift*`, `feetSeparation` and `feetStagger`
  when the mid-hip's 75th-percentile frame-to-frame speed exceeds 4 m/s. Measured: **8, 16 and 23 m/s** on
  the three shots (shot05's median was 3.6 m/s but its 75th percentile 7.6 and its maximum 177 — hence the
  percentile, not the median). Before the gate the model reported an 0.81 m free-throw "jump".
- **Hip-line yaw.** Vision holds the pelvis on a rigid segment: the 3-D hip vector is `(−0.3130, 0, 5e-6) m`
  on **every** frame (spread 3.5e-05 m over 200 frames). Refused with that reason. The shoulder line does
  move, so it is still measured.
- **Release fingertips.** No fingertip came within 1.0 ball radii of the ball centre on any shot; closest
  approach 1.8 / 1.4 / 2.0 radii. The hand landmarks and the ball centroid disagree by about one ball radius,
  so the metric is nil and says how close it got.

### Feet and face beyond Vision — MediaPipe Tasks Vision (the recommendation)

**Recommendation: do not add it now.** Keep the foot-direction metric nil with "no toe landmark in the
Vision body model". Revisit only if foot direction becomes a headline metric *and* the app can afford an
iOS-only dependency, because MediaPipe cannot run in the macOS probe where everything here is verified.

Verified by fetching the manifests and the file headers on 2026-09-14:

- **Official SPM support exists.** `https://github.com/google-ai-edge/mediapipe` has a root `Package.swift`
  (`swift-tools-version: 5.8`) declaring `MediaPipeTasksVision` from `.binaryTarget(url:checksum:)`
  xcframework zips, version 1.0.1 dated 2026-09-11. CocoaPods is no longer the only route.
- **iOS only** — `platforms: [.iOS(.v15)]`, and the CocoaPods spec agrees (`"platforms": {"ios": "15.0"}`).
  There is **no macOS slice**, so `TrajectoryProbe` could not run it and every number in the table above
  would have to be re-verified on device.
- **Size.** The binary targets are `MediaPipeTasksVision` 0.2 MiB, `MediaPipeTasksCommon` 12.8 MiB and
  `MediaPipeTaskGraphs` **1401 MiB** (Content-Length of the published zips). Model bundles are separate:
  `pose_landmarker_lite.task` 5.78 MB, `_full` 9.40 MB, `_heavy` 30.66 MB. The 1.4 GB is a resolve-time
  download of all-slice static archives, not the shipped app, but it lands in every clone and CI run.
- **Licence Apache-2.0** (CocoaPods spec `"license": {"type": "Apache"}`); the docs pages are CC-BY-4.0.
- **`-Xlinker -all_load` is mandatory** and is `.unsafeFlags`, so — in Google's own words in that manifest —
  "Downstream libraries wrapping MediaPipeTasks in a remote SPM package must reference this package by
  branch/revision or local path due to Apple's `.unsafeFlags` restriction." The newest released tag is
  `v1.0.0`; the 1.0.1 manifest is on `master` only.
- **Landmarks.** 33 points including `left/right heel` (29–30) and `left/right foot index` (31–32) — the toe
  we lack — plus inner/outer eyes, ears and both mouth corners; world landmarks in metres are produced
  alongside the normalised image ones.
- *Read, not verified:* community reports of "30 fps on an iPhone 12 at 640×480, CPU delegate" for the lite
  model and "20–25 fps" for the full model, and that running at 640×480 rather than full resolution costs
  ~40 % less time "with no meaningful accuracy loss".
- `paescebu/SwiftTasksVision` (MIT) is the older third-party SPM wrapper; it checks the xcframeworks into
  the repo and links `UIKit`, so it is also iOS-only and now redundant.

**If it is ever added, the exact steps are:**

1. Add to the *app* target (never to `ShotGeometry`, which must stay Foundation + simd, and not to
   `ShotVideo`, which must keep building for macOS):
   `.package(url: "https://github.com/google-ai-edge/mediapipe.git", revision: "<pinned sha on master>")`
   — a revision, not a version, because of the `.unsafeFlags` rule above. Product: `MediaPipeTasksVision`.
2. Download `pose_landmarker_full.task` (9.40 MB) from
   `https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/latest/`
   and add it as an app resource. Do **not** let the app fetch it at runtime (CLAUDE.md rule 6).
3. Wrap it behind a new `Packages/ShotVideoMediaPipe` iOS-only target exposing exactly the two things Vision
   lacks: `heel`/`footIndex` per side and the mouth corners. Feed them into `BodyFrame.points2D` under new
   canonical names (`leftHeel`, `leftFootIndex`, …) so `BodyKinematics` needs no change beyond reading them.
4. Replace `StanceMetrics.feetStaggerFromToes`'s fixed reason with the real computation, and keep the Vision
   reason for the path where MediaPipe is unavailable.
5. Re-run the three labelled windows on device and add a MediaPipe column to the noise table before any
   foot metric is reported to a user.

### The API the app should call

```swift
let timeline = try await BodyTracker.run(url: clip, start: startFile, end: endFile,
                                         options: opts,          // everyNthFrame, timeScale, crop, hands
                                         ballSeed: detections.map { ($0.pts, SIMD2($0.u, $0.v)) },
                                         fps: probe.measuredFrameRate)
let body = BodyKinematics.model(timeline: timeline,
                                releaseRealTime: shot.releaseRealTime,   // from the ball, never invented here
                                ballTrack: ballTrack, rimImageU: rim.centreU)
```

`BodyTracker` is the only Vision-facing piece; `BodyKinematics` is pure and testable on any Mac.
Read `body.warnings` first — the scale-provenance and tracking-gate messages decide whether any metre in
the payload may be shown at all.

## Three-point scale error: root cause (2026-09-14, evening)

Cause: the hand trace `rim_1766.json` was wrong, not the solver. Its right half lay on the backboard bracket (RimFinder's
6× overlay shows it), which centred the ellipse ~40 px too far right, inflated the axis ratio to 0.33 (true 0.25) and gave
the 16° roll that forced `--level-pitch`. Ruled out on the way, with numbers: time base, air drag, hFOV 40–56°, pitch,
azimuth, edge-clipped samples, ring/ball rulers (see memory notes and the agent sections above).
Fix: `footage/2026-09-13/rim_1766_found.json` (RimFinder inner-edge points, confidence 0.92, residual 0.95 px) and the same
for 1764/1765. Shot 8 alone: g 8.67 → 9.34, no pitch override needed. Block results are in SHOOTER-REPORT.md's evening
update (threes 11/27 accepted, elbow 18/43, free throws 11/31). Residual: elbow and threes g_fit 9.30–9.35 ± 0.2 → a ~5 %
focal-length error to settle from the recorder's logged `videoFieldOfView`.
Rule from this: never hand-trace the ring; use RimFinder and confirm both ends of the ring on the frame.

## Lens constant, measured on the phone (2026-09-14, night)

The app logs every back-wide-camera format at launch (`camera.formats`). iPhone 14 Pro: 1920×1080 @ 120 fps →
**videoFieldOfView 41.17°** (unbinned crop); 1920×1080 @ 240 fps and every ≤ 60 fps 1080p/4K format → **73.83°**
(binned/full); 1920×1440 → 71.29°; 1440×1080 → 68.78°. The shooter's own 42-shot session (PhotoKit original, real
timestamps, time scale 1, hand-marked rim residual 1.3 px) fitted gravity at **8.21 m/s² median, IQR 8.00–8.48**, tracks
clean (rms ≈ 4 px), with the assumed 48°: one scale factor, not noise. 9.81/8.21 = 1.19 → implied field of view 40.9°,
i.e. the 1080p120 format. The 2026-09-13 Camera.app slo-mo exports still measure ≈ 46–48° (elbow/threes g_fit 9.30–9.35
at 48° → 46°), which no raw format has: that footage carries Camera.app's stabilisation crop. Rule now in the app
(`LensSelection`): the first pass uses the stated field of view; if ≥ 5 clean shots fit gravity consistently off (IQR ≤
12 % of the median, error ≥ 5 %) and exactly one of the phone's formats (or the 48° stabilised-export value) lies within
3° of the implied field of view, the session is re-run with that lens and says so in its provenance; g_fit on the second
pass is the check. In-app recordings carry their format's field of view in the sidecar and never need this.
Speed on the phone with the 2026-09-14 speed work (Release): 250 s segment 275 s → **57 s** (scan 101 → 10 s, per window
27 → 6 s), same 3 of 6 accepted; the shooter's 42-shot session took 1890 s on the previous build.

## Body model, iteration 2 (2026-09-14)

Iteration 1 left the 3-D stage unusable: 2.4–8.8°/frame of elbow jitter, a release elbow disagreeing
with the 2-D value by up to 54°, and every metre refused. This pass measured *why*, rebuilt the 3-D
body from the part that is precise, and re-tested every refusal.

### The independent reference — MediaPipe, and what it settled

`tools/pytrack/body_reference.py` (run with `tools/pytrack/.venv-legacy/bin/python`, mediapipe 0.10.14
`mp.solutions.pose`, `model_complexity 2`, full frame, same `read_window` as `track.py`) writes both
`pose_landmarks` (33 points, converted to full-frame pixels) and `pose_world_landmarks` (metres,
hip-centred) per frame. Pose found on 212/212, 224/224, 204/224 frames of the three labelled windows.

**2-D agreement, Vision vs MediaPipe** (median |Δ| px per joint, shooter ≈ 500 px tall):

| joint | t89 | t313 | t817 | | joint | t89 | t313 | t817 |
|---|---|---|---|---|---|---|---|---|
| nose | 6.4 | 5.0 | 4.2 | | hip | **27.3** | **26.3** | **13.3** |
| shoulder | 9.6 | 5.9 | 5.4 | | knee | 8.0 | 9.6 | 7.2 |
| elbow | 4.1 | 4.0 | 6.7 | | ankle | 5.0 | 5.5 | 4.4 |
| wrist | 9.1 | 5.3 | 3.9 | | **all joints** | 9.7 | 8.1 | 5.4 |

(right side, the shooting side; the left side agrees to within a pixel or two where it is visible. A
mirrored match is 31–34 px, so the two models' left/right naming agrees — worth checking, it is the
classic way a joint table goes silently wrong.)

Two different model families land on the same pixels to 4–7 px everywhere **except the hip**, where they
differ by 13–26 px systematically. Rendered (`cmp_t89.png`): Vision puts the hip on the **belt line**,
MediaPipe at the **greater trochanter**. MediaPipe is anatomically right; this is why the fitted thigh
below comes out 0.52 m against Winter's 0.45 m for a 1.83 m subject. It is a definition difference, not
noise — but every hip-referenced angle inherits it.

**The finding that drove the rest.** Vision's own 3-D joints reproject **21–94 px** (median, per joint)
away from Vision's own 2-D joints on the same frame; RMS over a window is **55–72 px**. Rendered at the
t817 release, the 3-D shoulder/elbow/wrist image points land **off the body entirely**, pointing into the
background, while both 2-D skeletons trace the arm correctly. `DetectHumanBodyPose3DRequest` is not
seeing this person at this size; its angles were never going to be usable.

### One skeleton per shot (`BodySkeletonFit`, `BodyKinematics.swift`, Foundation + simd)

Bone lengths constant over the shot, joint positions in camera metres as the unknowns (with bone lengths
fixed each joint has two rotational degrees of freedom, so the unknowns *are* the angles), cost =
reprojection (px, Huber 12 px) + bone-length error + second-difference smoothness, the metre terms
converted to pixels through the body's own metres-per-pixel. Block coordinate descent: one
Levenberg-damped Gauss-Newton step per frame over 39 unknowns, forwards and backwards, 10 sweeps,
normal equations accumulated sparsely and solved by Cholesky. **50 ms for a 210-frame window.**

Weights chosen by sweep on t89, not by taste (reprojection RMS / elbow jitter):
4.0/1.0 → 24.5 px / 2.5°; 1.0/0.3 → 5.8 px / 3.8°; **0.3/0.6 → 1.8 px / 1.49°**; 0.2/0.1 → 0.4 px / 7.0°.
Defaults are 0.3/0.6: the reprojection lands on the 2-D input's own per-frame noise and the elbow jitter
is minimised. Bone lengths start at the 95th-percentile projected pixel length (a geometric floor — a
projection can only shorten a bone) and are refit to the median fitted length each sweep after the third.

**Before → after, the three labelled free throws** (`TrajectoryProbe body … --height 1.83 --hfov 48`):

| | t89 | t313 | t817 |
|---|---|---|---|
| reprojection RMS: Vision 3-D → fitted | 61.3 → **1.77** px | 72.1 → **2.41** px | 55.4 → **1.40** px |
| elbow jitter °/frame: Vision → fitted | 2.41 → **1.49** | 7.81 → **1.57** | 8.75 → **1.43** |
| — MediaPipe world / MediaPipe 2-D | 2.12 / 2.21 | 2.34 / 1.83 | 5.56 / 5.12 |
| knee jitter: Vision → fitted | 0.85 → **0.57** | 3.06 → **0.87** | 8.58 → **0.87** |
| shoulder-elevation jitter: Vision → fitted | 2.32 → **0.82** | 6.82 → **0.85** | 5.71 → **0.84** |
| mid-hip height jitter | 0.05 → **0.00** m | 0.07 → **0.00** m | 0.13 → **0.00** m |
| elbow at release: Vision → fitted | 97.0 → 135.8 | 154.9 → 151.4 | 109.5 → 166.6 |
| — MediaPipe world / 2-D, for comparison | 136.6 / 151.7 | 143.1 / 165.4 | 130.5 / 170.7 |
| fitted − MediaPipe world, median over shot | +24.3 (MAD 3.5) | +13.3 (MAD 13.1) | +26.6 (MAD 8.2) |

Reading it. The fitted elbow is the **least jittery signal of the four** and, unlike Vision's, it is
stable shot to shot (1.43–1.57 against 2.4–8.8). At t89's release it lands within **0.8°** of MediaPipe's
world elbow where Vision was 40° off. At t817 the fitted value (166.6°) disagrees with MediaPipe's world
elbow (130.5°) by 36° — and the frame settles it: the arm is visibly straight overhead, both 2-D models
read 165–171°, so the fitted value is right and MediaPipe's *world* landmarks are wrong there (that is
also the window where MediaPipe's own world-elbow jitter jumps to 5.6°/frame). Over the whole shot the
fitted angle sits systematically 13–27° **above** MediaPipe's world angle and below the 2-D projection;
the two 3-D estimates bracket the truth and their spread is the honest error bar on an absolute elbow
angle from one camera. The *jitter*, which is what a Tier-B finding needs (Ch 13 §13.6), is now 1.5°.

### Scale: two provenances, one of which fails its own check

`BodyScaleProvenance` is an explicit input; nothing derives a metre without it.

- **`.statedHeight(m)`** — the shooter's standing height against their 90th-percentile ankle-to-nose
  pixel span (Winter: nose 0.930 H, ankle joint 0.039 H → span 0.891 H). *Accepted.* At 1.83 m it gives
  0.00320 / 0.00323 / 0.00594 m/px and body depths of **6.91 / 6.96 / 12.80 m**.
- **`.rimRuler(0.4572 m, 113.4 px)`** — the corrected `rim_1765_found.json` ellipse. *Refused on all
  three windows*: it implies standing heights of 2.30 / 2.29 / 1.24 m, outside the 1.40–2.20 m gate. The
  shooter is not at the rim's depth on this oblique view (the ruler over-scales by 26 % on the two near
  windows). **The gate is the deliverable here** — the two provenances disagree by 26 %, and the
  disagreement is caught and refused rather than published.

**The clip is not one setup.** The shooter's ankle-to-nose span is 505/505 px on t89/t313 and **275 px**
on t817 — confirmed independently by MediaPipe (509/496/272). Camera or station moved between blocks; a
metre scale must be derived per window and must never be pooled across this session.

### Metres re-evaluated, and what is still refused

Vision's mid-hip moved at 8 / 26 / 47 m/s between frames (ceiling 4), so iteration 1 refused every metre.
The fitted mid-hip's frame-to-frame jitter is **0.00 m**; the gate now passes on all three shots.

| | t89 | t313 | t817 |
|---|---|---|---|
| jump height | nil → **0.255 m** | nil → **0.273 m** | nil → **0.313 m** |
| feet separation | nil → **0.17 m** | nil → **0.22 m** | nil → 0.06 m |
| hip drift lateral | nil → **−0.015 m** | nil → **0.130 m** | nil → **0.104 m** |
| hip drift depth (1σ) | −0.384 ± 0.002 m | 0.031 ± 0.003 m | −0.008 ± 0.003 m |

The 1σ is computed, not assumed: the fit's own information matrix at each frame, inverted for the
mid-hip block and scaled by the reprojection residual (`depthSigmaMetres`). It is conditional on the
neighbouring frames, so read it as "given the smoothing, this is what the pixels pin down".
`BodyCommand` refuses any depth-direction length below 2σ.

**Newly refused, with the reason.** The shoulder **line** never projects to more than 8 / 13 / 10 % of
the ankle-to-nose span in these windows; an adult's biacromial breadth is 27 % of that span when it faces
the camera. On this near-side view its depth is simply not observable, so `shoulderLineYaw`, `hipLineYaw`,
`torsoLeanSagittal` and `feetStagger` (which is measured against the facing direction derived from that
line) are now nil with that sentence. A free fit collapses the biacromial breadth to 0.124 m; pinning it
to Winter's 0.245 H was tried and **rejected** — the pixels left a 0.148 m spread around the pinned
0.448 m and it cost 0.5 px of reprojection, so `transverseBreadthFromHeight` defaults to false and the
projection gate does the refusing instead. Foot direction stays nil for the same reason as before.
`feetSeparation` at t817 (0.06 m) is reported but is at the edge: a 275-px shooter is ≈ 10 px per foot.

### Hands near the release

The hand request now gets its own **fixed 256 px crop** on the 2-D shooting wrist, biased 0.45 forearm
lengths past it, over release ± 0.4 s real, at every frame (`Options.handFocusRealTimeRange`).

| hands found, release ± 0.4 s | t89 | t313 | t817 |
|---|---|---|---|
| body crop (before) | 34/96 = **35 %** | 57/96 = **59 %** | 26/94 = **28 %** |
| 256 px wrist crop (after) | 64/96 = **67 %** | 69/96 = **72 %** | 20/94 = 21 % |

Crop-size sweep (release-window rate): 160 px → 0 %, 224 → 57/68 %, **256 → 70/78/22 %**, 320 → 69/78 %,
384 → 7 %, 512 → 6 %. The optimum is the same 256 px whether the shooter is 500 px or 275 px tall, so
"size the box from the forearm" was implemented, measured and rejected — Vision's hand request wants a
fixed **input** size, not a fixed subject fraction. It buys nothing on t817, where the shooter is half
the size and the hand is ~30 px: that window needs a longer lens or a nearer camera, not a better crop.

**Release fingertips still do not reach the ball.** Closest approach 1.7 / 1.4 / 1.7 ball radii against
the 1.0 gate, against 1.8 / 1.4 / 2.0 before. `lastFingertipsOnBall` stays nil with the distance in it.
The residual is about one ball radius on every shot, which points at the ball centroid or the hand
landmarks being biased, not at the detection rate.

### Timing at 120 fps real

One file frame = **8.33 ms** of real time; nothing at or below that is a measurement.

| | t89 | t313 | t817 |
|---|---|---|---|
| dip → release, Vision → fitted | 271 → 379 ms | 38 (window artefact) → 538 ms* | 238 → 379 ms |
| set point recovered | no → **yes** (22.150 s) | no → no* | no → no* |
| follow-through end | no → **yes** (22.592 s) | yes | yes |
| chain lags at or below the 8.33 ms floor | 2 of 4 → **0 of 4** | 3 of 4 → 1 of 4 | 2 of 4 → **0 of 4** |

\* the note "the dip is the first frame of the lookback" fires: the window starts after the real dip.
Smoothing has taken 7 of 12 chain lags off the quantisation floor and left 1: the orderings are now
readable rather than coin flips. They still read **hip → knee → shoulder → elbow → wrist** (t89) and
similar — *not* proximal-to-distal on any of the three. t313's earlier "proximal-to-distal: yes" was
built on lags of 0/8/0 ms and was noise.

### What to trust now, at 9–13 m with a 275–505 px shooter

*Trust.* The 2-D stage (unchanged: nose 1.0 px, wrist 1.7–2.5 px, and a second model agrees to 4–7 px).
The **fitted** 3-D angles — elbow, knee, shoulder elevation, hip — at 0.6–1.6°/frame, which is at or below
the Ch 12 2-D floor and finally under the 5–10° effect sizes the findings engine needs. Phase timing from
the fitted wrist path when the dip is inside the window. Image-plane metres (jump height, lateral drift,
feet separation) once a **stated height** has set the scale.

*Do not trust.* Any absolute elbow angle to better than ~25° — the fitted and MediaPipe-world estimates
bracket that wide. Anything transverse on a near-side view (yaw, facing, stagger, sagittal lean): refused.
The rim ruler as a body scale on an oblique clip: refused. Depth-direction lengths below 2σ: refused.
Vision's `DetectHumanBodyPose3DRequest` for anything at all at this subject size — it reprojects 55–72 px
from its own 2-D points, and the fit now replaces it wholesale.

*Next.* (1) Ask the shooter their height — it is the only input the metres need, and `--height` already
takes it. (2) Adopt MediaPipe's hip definition, or correct Vision's belt-line hip, before any
hip-referenced angle is reported. (3) Film closer or longer: t817's 275-px shooter is the one window
where every stage degraded. (4) The fingertip-to-ball residual of ~1 radius is the next thing to chase.

## 240 fps clips and the lens, from the shooter's phone (2026-09-15, early morning)

Three clips at a true 240 fps (one recorded in the app with the sidecar lens 73.83°, two Camera.app originals via
PhotoKit) plus the shot doctor in use (complaint typed: "My shot feels inconsistent and uncontrolled coming out of my
hand" → matched "inconsistent" → plan speedVariability, baseline release-speed SD 0.176 m/s, n 35).
- In-app 240 fps free throws: gravity median 9.97 (lens and time base right), but 16 of 28 accepted with release angle
  57.6 ± 13.5° and entry 46.5 ± 16.1° — the tracker's per-frame gates were tuned at 120 fps; several fits "miss the
  tracked ball by 52–98 px". Tracker agent assigned (frame-rate-aware gates, 240 fps evaluation on this recording).
- Camera.app 240 fps originals: gravity 10.2–10.5 with tight IQR → effective hFOV ≈ 51° (stabilisation crop; no raw
  format matches, so LensSelection stayed silent). LensSelection now falls back to a clip-calibrated lens (≥ 8 clean
  shots, tight IQR) with explicit provenance.
- Cost at 240 fps on the phone: ≈ 20 s per window (body stage 11 s, Core ML 3–4 s, pose 2.4–3.2 s).
- UX: all four saved sessions were labelled "Free throws" (including the threes clip and a duplicate save) because the
  save picker defaulted. Now: the spot must be chosen, duplicate saves are flagged, and a saved session can be moved to
  another spot from the Progress screen (long-press).

## Body model, iteration 3 (2026-09-15)

New data: the in-app 387 s recording at a true **240 fps** with the measured lens
(`videoFieldOfViewDegrees 73.83`, sidecar `03D7D2BF-….json`) — twice the frames of IMG_1765 and no
4× time-scale guesswork. Windows were found with `RimFinder` (rim at 545.5, 329.1 px, confidence
0.93, RMS 0.39 px) → `scan` (31 arrivals in 387 s) → `session` per arrival for the release instant.
Five of them: releases at file **31.928, 105.177, 199.123, 274.947, 341.795 s**, spans release − 1.5 s
to + 0.4 s, every 2nd frame (120 Hz), `--hfov 73.83 --height 1.83`.

The user's ask was "everything from wrists, elbows, shoulders, neck, hips, knees, ankles … and make
everything better and faster".

### 1. The joint set, completed — per joint, measured (medians over the five windows)

`BodyCoverage.perJoint` is new and pure: seen fraction, median detector confidence, per-frame image
noise (SD of consecutive differences ÷ √2, Ch 10 §10.5.1), how often the point sat within 6 px of a
frame border, and a **`symmetryInferred`** flag for a joint the detector never returned whose mirror
partner it did. It is on `BodyModel.coverage` and `BodySkeletonFitResult.jointCoverage`.

| joint | seen | conf | jitter px | clipped | MediaPipe agrees to (median \|Δ\|, t199) |
|---|---|---|---|---|---|
| nose | 100 % | 0.80 | 0.92 | 0 % | 3.9 px |
| left/right eye | 100 % | 0.83 / 0.81 | 0.92 / 0.93 | 0 % | 2.8 / 2.8 px |
| left/right ear | 100 % | 0.79 / 0.75 | 0.87 / 0.93 | 0 % | 7.8 / 6.4 px |
| **neck** | 100 % | 0.81 | **0.76** | 0 % | 3.1 px (vs MediaPipe's mid-shoulder — it has no neck) |
| left/right shoulder | 100 % | 0.81 / 0.80 | 0.82 / 0.80 | 0 % | 5.4 / 3.3 px |
| left/right elbow | 100 / 99 % | 0.84 / 0.88 | 1.00 / 1.13 | 0 % | 3.7 / 4.6 px |
| left/right wrist | 100 % | 0.82 / 0.87 | 1.44 / 1.67 | 0 % | 3.4 / 5.7 px |
| root | 100 % | 0.72 | 0.86 | 0 % | — |
| left/right hip | 100 % | 0.71 / 0.75 | 0.94 / 0.83 | 0 % | 7.8 / **10.9** px (the belt-line vs trochanter definition gap, was 13–27 px at 120 fps) |
| left/right knee | 100 % | 0.72 / 0.79 | 1.04 / 0.82 | 0 % | 3.5 / 3.6 px |
| **left/right ankle** | 100 % | 0.80 / 0.87 | **0.79 / 0.73** | **0 %** | 4.5 / **2.1** px |
| left/right hand (21 landmarks) | 46 / 49 % of the window, **100 % of release ± 0.4 s** | 1.00 | 6.60 / 6.59 | — | — |

Compare with iteration 2 on the 120 fps footage: 2-D nose 0.99–1.14 px and shooting wrist 1.68–2.45 px
there, against **0.92 px** and **1.67 px** here — the 240 fps frames are sharper (shorter exposure) and
the true lens removes the scale error. Every one of Vision's 19 2-D points is returned on essentially
every frame at this subject size, so nothing was `symmetryInferred` on this clip; the flag and the
mirror-bone path are exercised by unit tests that starve one side.

The independent check is `tools/pytrack/body_reference.py`, now with `--every N` (a 1.9 s window at
240 fps is 456 frames) and a `--compare <body --json>` mode that prints the table above's last column
itself. MediaPipe found a pose on **229/229** frames; the two model families agree to a median of
**4.4 px over all joints**, which is what makes the ankle and neck rows believable.

**Fitted-angle jitter**, °/frame at 120 Hz sampling, median over the five windows — both sides now
reported, because the far side is the one to read sceptically:

| | left | right (shooting) |
|---|---|---|
| elbow | 1.38 | 1.94 |
| knee | 0.74 | 1.33 |
| hip | 0.76 | 1.22 |
| shoulder elevation | 0.70 | 0.87 |
| shoulder abduction | 0.82 | 0.83 |

### 2. New measures: neck and trunk attitude, with their own precision

`PostureMetrics` (image plane, because that is the direction one camera measures; the transverse
component stays refused). Neck from Vision's own `neck` point on 100 % of frames, head centre from
the **mid-ear** on 100 %:

| | t31.9 | t105.2 | t199.1 | t274.9 | t341.8 |
|---|---|---|---|---|---|
| trunk to vertical at release | 5.28° | 5.22° | 3.85° | 5.70° | 4.28° |
| — its per-frame noise | ±0.21° | ±0.20° | ±0.20° | ±0.22° | ±0.23° |
| head to trunk at release | 19.68° | 20.79° | 21.03° | 17.06° | 20.42° |
| — its per-frame noise | ±1.09° | ±0.97° | ±1.08° | ±1.18° | ±1.17° |
| head to shoulder-line normal | 16.89° | 19.13° | 20.41° | 17.38° | 15.26° |
| — its per-frame noise | ±1.05° | ±1.00° | ±1.12° | ±1.26° | ±1.26° |

The trunk lean is the most precise angle in the whole body model — **0.2°/frame** — because it is a
long lever (mid-hip → neck, ≈ 260 px) between two of the steadiest points. Its shot-to-shot spread
(3.9–5.7°) is nine times its noise, so it resolves.

### 3. The phases were wrong, and why (found by the form agent's tempo)

The form agent measured set→dip **8 ± 0 ms** and release→follow-through **14 ± 2 ms** on this clip.
Both were artefacts of the definitions, and the wrist trace says so:

- The wrist rises from the waist, **holds still for 130–400 ms** at the set position, drives up, and
  the release *is* its highest point (it rises 0.000 to −0.009 m after the ball leaves, against a
  0.36–0.37 m rise into the release).
- **Set point.** The old rule was "the last quiet frame before the dip". The rate is zero at a turning
  point *by construction*, so the set point landed one frame before the dip on every shot. It is now
  the **last frame of the last run of stillness lasting at least `minimumSetPlateauSeconds` (0.08 s)** —
  the moment the hand leaves the set position.
- **Dip.** The old rule named whatever was lowest (or the last turning point) in the lookback. On this
  shooter that was a **0.004–0.015 m wobble inside the set plateau** against a 0.36–0.38 m rise, i.e.
  1–4 %. A dip now has to be a descent: `minimumDipDescentFraction` (5 % of the dip→release rise), and
  below it the model says *"this shot has no dip — the hand rises from the set position straight into
  the release"* instead of naming a wobble.
- **Follow-through.** Split in two. `followThroughPeak` is the wrist's highest point after release and
  is **refused on all five shots with the measured sentence**, because there is no rise. `followThroughEnd`
  is now measured against the shot's own rise (set → release) rather than a post-release rise that does
  not exist, which is what produced 14 ms.
- `setToReleaseMilliseconds` is new: the tempo number that survives when a shot has no dip.

**Corrected tempo, five free throws:**

| | t31.9 | t105.2 | t199.1 | t274.9 | t341.8 | mean ± SD |
|---|---|---|---|---|---|---|
| set plateau length | 133 ms | 367 ms | 375 ms | 217 ms | 400 ms | 298 ± 116 ms |
| **set → release** | 221 ms | 292 ms | 296 ms | 459 ms | 259 ms | **305 ± 90 ms** |
| dip → release | nil (2.7 %) | nil (4.0 %) | nil (1.0 %) | 342 ms | nil (3.4 %) | one shot of five |
| follow-through **peak** | nil | nil | nil | nil | nil | the release *is* the peak |
| **release → follow-through end** | 162 ms | 116 ms | 121 ms | 158 ms | 183 ms | **148 ± 29 ms** |

The old "dip → release 320 ± 43 ms" was really *set → release*: the wobble it called a dip sits at the
end of the set plateau. The corrected number, 305 ± 90 ms, is the same quantity honestly named.

### 4. Faster: 5.4 s → 2.9 s per window at 240 fps

Measured with `TrajectoryProbe body --every 2` (229 analysed frames of a 456-frame span), Release,
same Mac, best of two runs per window because the machine was shared:

| | t31.9 | t105.2 | t199.1 | t274.9 | t341.8 | median |
|---|---|---|---|---|---|---|
| before (iteration 2 settings) | 8.5 s | 5.3 s | 5.3 s | 7.6 s | 5.4 s | **5.4 s** |
| after (iteration 3 defaults) | 2.9 s | 2.8 s | 2.8 s | 2.9 s | 3.1 s | **2.9 s** |

Where it came from, and what was traded:

1. **Two croppers, not one — 10.3 s → 7.9 s on the same window minutes apart, the single biggest item.** `Cropper` caches one
   destination buffer *by size*, and the body crop and the 256 px hand crop are different sizes, so
   sharing one instance allocated a fresh `CVPixelBuffer` twice per frame. Nothing was traded; this
   was a bug. (The "before" row above already has the fix, so the true iteration-2 cost on this clip
   was 8.9–10.5 s.)
2. **The 3-D request on every 2nd analysed frame** (`everyNthFrame3D = 2`): 1.5 s → 0.7 s. The fit uses
   Vision's 3-D for one thing only, the front/back *sign* of each joint's depth, and the new
   `BodySkeletonOptions.depthSeedHoldSeconds` (0.10 s) holds that sign across the gap. Ablated with
   everything else fixed the fitted reprojection RMS, elbow, knee, hip and shoulder jitter were
   **identical to four significant figures**. `everyNthFrame3D = 3` was measured and rejected: the
   stateful request collapses to 4 bodies in 77 frames at that spacing (it recovers at 4 — 40/58).
3. **Hands on every 3rd frame outside the release window** (`everyNthFrameHandsOutsideFocus = 3`):
   1.77 s → 1.19 s, with the release-window hand rate unchanged at **100 %** on all five windows.
   Traded: hand coverage over the whole window falls from ~95 % to 46–49 %, which is only context.
4. **The three requests run concurrently** (`concurrentRequests = true`): a further ~0.7–1.5 s. The
   hand crop is then placed from the *previous* analysed frame's wrist (8 ms of hand travel against a
   256 px box); the outputs were byte-identical in the A/B.
5. Measured and **rejected**: rendering the body crop smaller (`cropRenderScale`). Vision resizes the
   input itself, so 0.7 left the 2-D request at 9.6 ms/frame against 9.0 at full size, and 0.5 pushed
   the fitted reprojection RMS from 1.38 to 1.69 px. The option stays, the default does not move.

Per-request cost at 240 fps on a quiet machine: 2-D body **9.0 ms/frame**, 3-D body **6.5**, hands
**7.6**, crop 0.2 s and decode 0.1 s for the window. The 2-D request is the long pole, so "run 2-D on
every frame because it is cheap" is not available — it is the most expensive of the three.

### 5. The other things that were tried, with their numbers

- **The neck in the fit.** `BodySkeletonFit` now solves for `neck` (bones `neckNose`,
  `neckShoulderLeft/Right`) and writes it back as `centerShoulder` *with* an image point, instead of
  the shoulders' midpoint. Cost: +0.02–0.04 px of reprojection RMS, no change to any jitter.
- **The symmetric-limb prior** (`symmetricLimbPrior`, default on): left and right bones of the same
  limb share one length, pooled over both sides' frames. On this clip, where Vision returns both sides
  confidently, it costs +0.10 px of reprojection and moves jitter by less than 0.2°/frame either way —
  it is neutral. It earns its place on the starved far side, which is what a true side-on view gives:
  the unit test deletes the left knee on 8 frames in 9 and the pooled thigh lands nearer Winter's
  0.245 H than the free one, which floors itself on a foreshortened projection.
- **Confidence-weighted observations** (default on): +0.18 px reprojection, jitter marginally better
  on 2 of 3 windows. Kept because 0.35 and 0.95 points should not pull equally.
- **Ankle clipping gate.** The feet sit at the bottom of the frame on a side view and a clipped ankle
  is reported *at* the border, which shortens the ankle-to-nose span and inflates the metres-per-pixel.
  Above `maximumAnkleClipFraction` (30 %) the height scale is now **refused** with that sentence (the
  stated height itself survives — it was stated). On this clip the ankles are clipped on **0 %** of
  frames, so nothing is refused; the gate is a contract, and a unit test pins it.
- **The ball-placed hand crop** (`handFocusUsesBall`, blend 0.5) and the **window-level shooting-hand
  vote**. The crop centre moves from the wrist-plus-forearm-bias toward the ball centre when the ball
  track has a sample. Release-window hand rate: unchanged (100 % either way, one window lost a single
  frame). Shooting-hand vote share: 83→84, 88→88, 83→86, 85→86, 88→91 %. Marginal, kept because the
  vote is what labels every frame and it never hurt.
- **`lastFingertipsOnBall` finally resolves.** With a real ball track — `TrajectoryProbe body
  --detect-ball --rim rim.json`, which seeds the detector from the fast rim scanner exactly as
  `session` does — the fingertips reach the ball on **all five** windows (index, little, middle, ring
  and thumb tips). Iterations 1 and 2 refused it on every shot: closest approach 1.4–2.0 ball radii
  against a 1.0 gate. 240 fps and the true 73.83° lens are what closed it.

### 6. What to trust now, at 240 fps with the real lens

*Trust.* All 19 2-D points at 100 % coverage and 0.73–1.67 px of noise, corroborated by a second model
family to 4.4 px. The fitted elbow, knee, hip and shoulder angles at 0.7–1.9 °/frame. The trunk lean at
0.2 °/frame. Set → release and release → follow-through end. The fingertip-on-ball set, when a ball
track is supplied.

*Do not trust.* Anything transverse on a near-side view — still refused. Any absolute elbow angle to
better than ~25°. The hip's *position* to better than ~10 px until Vision's belt-line hip is corrected
to the trochanter (iteration 2's item 2, still open).

## Body model, iteration 4: arms (2026-09-15)

The shooter looked at the 3-D form on the phone and said: **"the arms were short and did not follow
the body."** This pass measured that on **37 `BodyShot` files** the phone wrote from one of their own
sessions (schema v1, `fitted3D` per frame + the skeleton's bone lengths; 1920×1080, 158.2 fps, stated
height 1.700 m, hFOV **48° assumed**), found two separate causes, fixed one in the fit and named the
other as refused.

### 1. What the files say

**Bone lengths** (`skeleton.boneLengths` ÷ the stated 1.700 m, median over the 36 usable shots; one
shot is refused at 110 px of reprojection):

| bone | fitted | Winter | | bone | fitted | Winter |
|---|---|---|---|---|---|---|
| upper arm R | 0.191 H | 0.186 | | thigh R | 0.280 H | 0.245 |
| forearm R | 0.153 H | 0.146 | | shin R | 0.280 H | 0.246 |
| trunk R | 0.304 H | 0.288 | | **biacromial** | **0.052 H** | **0.259** |
| neck→nose | 0.147 H | — | | **biiliac** | **0.054 H** | 0.191 |

The *summary* arm is right to 3–5 %. The legs read 14 % long, which is iteration 2's open item — Vision
puts the hip on the belt line, not the trochanter. So "short arms" is not in this table at all.

**It is in `fitted3D`, the joint positions that are actually drawn.** Per-frame segment length ÷ that
shot's own median, medians over the 36 shots:

| segment | min/median | max/median | SD | | segment | min/median | max/median | SD |
|---|---|---|---|---|---|---|---|
| **upper arm R** | **0.822** | **1.138** | **9.9 %** | | thigh R | 0.875 | 1.059 | 5.0 % |
| **forearm R** | **0.816** | **1.096** | **6.3 %** | | shin R | 0.886 | 1.071 | 4.6 % |
| upper arm L | 0.785 | 1.138 | 9.0 % | | trunk R | 0.968 | 1.038 | 1.6 % |
| forearm L | 0.725 | 1.161 | 10.4 % | | **biacromial** | **0.406** | **1.388** | **22.7 %** |

"One skeleton per shot" was true of the summary and false of the skeleton: the drawn arm breathed by a
fifth of its length inside one shot, the legs by a twentieth, the trunk not at all.

**When is it short? Where the projection is short.** Medians over the 36 shots, by real time from the
release — fitted length ÷ its own median, beside the *projected* 2-D length ÷ its own longest:

| | set (−1.5…−0.6 s) | −0.6…−0.4 | −0.4…−0.25 | −0.25…−0.12 | −0.12…−0.03 | release ±30 ms | after |
|---|---|---|---|---|---|---|---|
| fitted upper arm | 0.945 | 1.082 | 1.084 | 1.074 | 1.024 | **0.959** | 0.981 |
| fitted forearm | 1.027 | 1.004 | 0.995 | 0.975 | 0.907 | **0.931** | 0.945 |
| projected upper arm | 0.780 | 0.930 | 0.954 | 0.944 | 0.876 | 0.817 | 0.837 |
| projected forearm | 0.890 | 0.799 | 0.805 | 0.801 | 0.780 | 0.859 | 0.822 |

The fitted arm tracks the projected arm. **That is the bug**: a bone that shortens along the view ray
costs nothing in pixels, and at `boneWeight` 0.3 the bone-length term was too weak to stop it, so the
arm was shortest exactly at the set and at the release — the two instants a shooter looks at.

**Depth-sign flips are not the cause.** The shooting elbow changes side of the shoulder along the
unobservable axis a median of **2** times per shot in `fitted3D` (0–6) against **6** in Vision's raw
3-D (1–14). A flip folds an arm; it does not shorten one.

**Nor is the form's own maths.** `ShotForm`'s body frame is a rotation plus one divisor, so it cannot
change a bone length (there is a test); the phase resampling is linear between frames 6.3 ms apart and
moves a bone by < 1 % once the bone is constant.

### 2. The other half: "did not follow the body"

The biacromial. The fit puts the shooter's two shoulders **0.052 H** apart where an adult's are 0.259 H,
and that distance swings **0.41–1.39** of itself within a shot. Both arms therefore hang from a point in
the middle of the chest that moves on its own, while the drawn torso is floored at an adult's width.

This is **refused, not fixed**. Every one of the 37 files already carries the sentence: the shoulder
line never projects to more than 5 % of the ankle-to-nose span on this near-side view, so its depth is
not observable. Iteration 2 measured and rejected pinning it; re-measured here on the same 36 shots,
`transverseBreadthFromHeight = true` gives the right *length* (0.245 H) but leaves a **15 %** per-frame
spread and costs **+0.4 px** of reprojection and **+0.17 °/frame** of elbow jitter. It stays off.

**A second, independent reason those shoulders collapsed: the lens.** These 37 files were fitted with an
**assumed 48°** horizontal field of view. On the 240 fps in-app clip with its measured 73.83° the same
code fits a biacromial of **0.167 H** with a 4.5 % per-frame spread, against 0.052 H and 22.7 % here.
A wrong focal length is a wrong depth scale, and the transverse breadth is the first thing to pay.

### 3. The fix, and the four things it moved

1. **Limb bones are held, not refit.** The eight limb bones (upper arm, forearm, thigh, shin) take
   `max(projection floor, Winter's fraction × the shooter's own fitted stature)` and keep it for the
   whole fit; `BodyBoneLength.source` says which of the two it was. `limbBoneWeight` 3.0 against
   `boneWeight` 0.3 for the rest.
2. **The floor is a 9-frame running median, taken once** (`projectionFloorMedianFrames` 5 → 9). A
   maximum is biased upward by everything under it. Two things sit under this one: the 2-D noise, and
   the fact that "a projection can only shorten a bone" is **false under perspective** — a bone nearer
   the camera than the depth its pixels were converted at projects *longer*. Measured on the
   swinging-arm synthetic with the noise switched off, the longest projected forearm is **1.037×**
   what the bone would project at the body's depth. The projected length is stationary at its peak, so
   a wider median costs nothing there and takes the bias out: recovered − true (upper arm / forearm)
   is +0.8 % / **+3.6 %** at 5 frames, **−0.1 % / +2.0 %** at 9, −0.8 % / +1.2 % at 15, −1.9 % / +0.9 %
   at 21. Re-expressing that floor at the bone's own fitted depth also now happens **once**, on the
   first refit, not every sweep: re-doing it each sweep is a ratchet (a longer bone pushes its proximal
   joint deeper, a deeper joint raises the floor) that grew the forearm from +2 % to +3.8 % at 25 sweeps.
3. **`smoothnessWeight` 0.6 → 0.3.** 0.6 was measured in iteration 2 *when every bone was soft* and
   smoothing was the only thing holding the elbow still. With the limbs rigid the smoothness term
   instead fights the depth swing a rigid arm must make, and the fit buys it back by moving joints in
   the image plane — which is reprojection error. Re-swept at limb weight 3, prior on, 25 sweeps
   (reprojection RMS px / shooting-elbow °/frame):

   | smoothness | 0.6 | 0.45 | **0.3** | 0.2 |
   |---|---|---|---|---|
   | 36 phone shots | 4.05 / 0.87 | 3.34 / 1.04 | **2.60 / 1.25** | 1.89 / 1.57 |
   | 4 × 240 fps windows | 2.74 / 0.63 | 2.29 / 0.64 | **1.83 / 0.76** | 1.32 / 0.87 |

   0.3 is where the reprojection lands back under the old defaults' on both clips while the elbow
   jitter stays inside the 1.4–1.9 °/frame this project has always reported. 0.2 is better on pixels
   and worse on jitter; it is fitting the 2-D noise (the input's own is 0.7–1.7 px).
4. **`sweeps` 10 → 25.** The stiffer problem was not converging. On the 240 fps windows at smoothness
   0.6, 10/25/40 sweeps give **3.96 / 2.75 / 2.56 px** and 0.83 / 0.63 / 0.61 °/frame — 25 takes nearly
   all of it. Cost: the fit goes from ≈ 0.15 s to ≈ 0.38 s per 223-frame window, +8 % of a 2.9 s window.

### 4. Before → after, on the phone's own shots

"Before (phone)" is what the shooter saw: the files the iteration-3 build wrote. "Before (refit)" is the
same 2-D input re-fitted with the old weights, which is the controlled comparison; it is already a
little better than the phone build because the limb bones are no longer refit to a per-frame median.

| | before (phone) | before (refit) | **after** | 240 fps: before | **after** |
|---|---|---|---|---|---|
| shooting upper arm | 0.192 H | 0.192 H | **0.191 H** | 0.161 H | **0.181 H** |
| — per-frame min/median | 0.822 | 0.883 | **0.992** | 0.860 | **0.985** |
| — per-frame max/median | 1.138 | 1.126 | **1.002** | 1.124 | **1.002** |
| — per-frame SD | 9.9 % | 6.8 % | **0.2 %** | 7.5 % | **0.3 %** |
| shooting forearm | 0.158 H | 0.155 H | **0.156 H** | 0.154 H | **0.157 H** |
| — per-frame SD | 6.3 % | 6.7 % | **0.1 %** | 9.7 % | **0.2 %** |
| reprojection RMS, median / worst | 2.95 / 4.09 px | 3.30 / 4.32 px | **2.60 / 3.32 px** | 1.47 / 1.57 px | **1.83 / 2.15 px** |
| shooting-elbow jitter °/frame | — | 0.83 | 1.25 | 0.87 | **0.76** |
| knee jitter °/frame | — | 0.81 | 1.01 | 0.80 | **0.53** |
| mid-hip step, stature/frame | — | 0.0026 | 0.0041 | 0.0017 | 0.0037 |

The gate was "no more than 0.5 px over iteration 3's 1.4–2.4 px". On the 240 fps clip the worst window
is **2.15 px** — inside iteration 3's own band. On the phone clip, where the assumed lens costs
everything a pixel or two, the fit is **better** than before on reprojection. The elbow jitter rises by
0.4 °/frame on the badly-lensed clip and falls by 0.11 on the well-lensed one; both sit under the
1.94 °/frame iteration 3 published for this joint.

**The pictures** (six phases, shot 9 of the session, before over after, the shooting arm in red and
labelled with upper arm + forearm in shooter heights):
`scratchpad/arms/arms_side.png`, `scratchpad/arms/arms_front.png`. The front strip is the one to read:
before, the arm runs 0.214 + 0.155 H at the set, 0.218 + 0.162 at −300 ms and **0.175 + 0.139** at the
release; after, it is 0.195 + 0.153 H at all six phases (0.194 + 0.153 at −100 ms).

### 5. What was already right, and what is still open

- **The drawn chain.** `SceneBody` and `FormModelView` both build a bone's geometry once and scale it
  along its own axis by the frame's actual joint distance, so a bone runs joint to joint on every
  frame; the shooting hand's 21 landmarks are anchored on the **fitted wrist** (`showFingers`), with a
  mitt pointed along the forearm when the hand is not detected. Nothing there needed changing — with
  the bones now constant, those capsules stopped having to stretch.
- **Measured and not taken: rigid torso bones.** With the limbs held, the torso is where the residual
  goes: the drawn trunk side's per-frame spread rises from 1.6 % to 3.0 % (phone) and 3.3 % to 4.2 %
  (240 fps). Raising `boneWeight` from 0.3 to 1.0 for the non-limb bones takes the trunk to 1.1 % / 0.6 %
  and the biacromial's per-frame swing from 18.1 % / 6.3 % to 5.9 % / 1.4 % — but costs 2.65 → 3.70 px
  (worst 5.97) on the phone clip and 1.86 → 2.40 px on the 240 fps one, and it buys a shoulder line that
  is steady and still five times too narrow. At 3.0 the torso is rigid (0.3 % / 0.2 %) and the phone
  clip's worst window reaches 7.64 px. `boneWeight` stays at iteration 2's 0.3; the number to fix first
  is the lens, not the weight.
- **Open: the block's mean form shortens bones.** `FormModel.build` averages positions, and the mean is
  not a body: measured over 12 of these shots, the mean skeleton's shooting upper arm runs
  **0.162–0.191 H** against the shots' own 0.191 H (85–100 %, median 95 %). It is drawn as the grey
  overlay in `FormModelView`, so a second, smaller short arm lives there. The fix (re-lengthening the
  mean skeleton along its own bone directions) changes what `compare(shot:)` measures against and wants
  its own pass.
- **Open: the hip definition** (iteration 2's item 2) — the 14 % long thigh and shin above are it.
- **Open: the lens on saved sessions.** 48° assumed on a clip that is nothing like 48° is the largest
  single error in these 37 files. `LensSelection`'s clip-calibrated fallback exists; these shots
  predate it.

**New tool.** `Packages/ShotGeometry/Sources/BodyRefit` (`swift run -c release BodyRefit <dir>
[--limb-bone-weight] [--limb-prior] [--smoothness-weight] [--sweeps] [--transverse-prior] [--out-dir]`)
re-runs `BodySkeletonFit` on exported `BodyShot` files. Every input the fit consumes is in the export,
so an option can be swept over 36 real shots in a few seconds without decoding a frame of video; every
number in this section came from it. **New tests** in `BodySkeletonFitTests`: an arm swinging through
foreshortening recovers a non-population length within 3 % from the pixels alone, keeps that length on
**every frame** within 3 %, takes the stature prior (labelled) when the view never lets it reach the
image plane, and pays no more than 0.5 px of reprojection for it.

## Mean form, rigid bones (2026-09-15)

Iteration 4's last open item: `FormModel.build` averaged **joint positions**, so the block's mean
skeleton's shooting upper arm ran 85–100 % (median 95 %) of the shooter's own. Two shots whose
forearms point in different directions average to a forearm shorter than either — the mean was not
a body, and it is drawn as the grey overlay in `FormModelView`.

### What changed

`FormModel.build` now re-integrates the mean skeleton instead of averaging it:

- **`FormSkeleton.root` + `FormSkeleton.tree(withNeck:)`** name the kinematic tree the mean is built
  along: the virtual root is the mid-hip (which is also the body frame's origin), and there is one
  edge per joint, parents first. Without a neck in the block the shoulders and the nose hang off the
  root instead.
- **The shooter's own length per bone**: per shot the median over its samples (the fit holds a bone
  constant within a shot since iteration 4), then the mean over the block. Exported as
  `FormModel.bones` (`FormBone`: `a`, `b`, `length`, `sd` across shots, `n`).
- **Per phase-time sample**, each bone takes the block's **mean direction** — the normalised
  resultant of the shots' unit vectors, the mean on the sphere — and that length, integrated from
  the mean mid-hip outward. A joint whose parent has no mean here has none either.
- **The ellipsoids are the shots' residuals against that mean**, so they include whatever the
  re-lengthening moved; the divisor is unchanged (n − 1), and `FormOptions.minimumSpread` rises
  1e-6 → 1e-3 because the 4-decimal position rounding now leaves a residual of that size between
  identical shots and their re-integrated mean (1e-3 is 1 mm in metres, 1.7 mm of a 1.7 m shooter, a
  hundredth of the fit's own depth σ).
- **Angles are still computed per shot and then averaged**, never read off the mean skeleton.
- Both comparisons are unchanged and stay consistent: `compare(shot:)` and `compare(_:with:)` both
  measure joint positions against the mean and divide by the same ellipsoids. What moved is the
  reference they measure against, which is now a body.

### Measured

**Test, `FormModelTests`** — the property, stated directly: six synthetic shots with **identical
bone lengths put in by hand** (hip 0.14, thigh/shin 0.45, trunk 0.50, half-shoulder 0.20, upper arm
0.30, forearm 0.27 m) and **randomised joint angles** (a seeded smooth sine per angle channel, so
each shot's angles are its own) give a mean whose every bone is exactly those lengths: the block's
bone table is right to 5e-4 m and every bone on **every** sample is within **0.05 %** — which is the
4-decimal position rounding, nothing else. The same test's control averages the positions of the
same six shots and gets an upper arm under 97 % of the figure's, so the randomisation bites.

The synthetic figure in `FormModelTests` also got **rigid legs** (the dip bends the knee forward on
two equal 0.45 m links instead of shrinking the thigh and shin), which is what a fitted skeleton has
done since iteration 4. `testIdenticalShotsGiveZeroSpreadAndTheSameMean` now asserts to 5e-4 rather
than 1e-6, and additionally that the residual sits under `minimumSpread` — the rounding, not a
spread.

`cd Packages/ShotGeometry && swift test`: **148 tests, 0 failures**. The app builds
(`xcodegen generate` + `xcodebuild -scheme ArcLab -destination 'generic/platform=iOS Simulator'`:
BUILD SUCCEEDED).

### Not measured — still open

This pass was stopped before the measurement on real shots. **Unmeasured, and to be done before this
is quoted as fixed:**

- The before/after on ≥ 20 of the 37 phone `BodyShot` files at one spot: mean-form bone length as a
  fraction of the shooter's fitted length **per phase** (the target is 100 ± 1 %, and the rigid mean
  should reach it by construction — but the emergent bones, the trunk side and the biacromial, are
  **not** tree edges and are not held, so their ratios are the ones worth reading), and how much the
  ellipsoids grew now that they carry the mean-form offset as well as the shot-to-shot spread.
- The front + side six-phase PNG strip from the exported `FormJSON`. Not rendered.
- `BodyRefit` has no mean-form mode, so there is no tool for the two bullets above yet; the intended
  shape is a `--mean-form` flag that builds a `ShotForm` per refitted shot (the phase times are in
  `BodyShotTiming`), builds the model, and prints the per-phase ratios against the fit's own bone
  table beside the same block averaged as positions.

---

## 3-D model 1.1 (2026-09-15)

Track A of `docs/PLAN-1.1-2026-09-15.md`, answering two sentences from the user: *"the head is messed
up… it should be drawn in such a way that the head is obvious"* and *"the tracking seems somewhat
flat and inaccurate."*

Measured on **107 of the 110 real phone `BodyShot` files** (three are refused by the harness's own
10 px reprojection gate) — free throws, threes and college threes, iPhone 14 Pro, all near-side
views. The tool is `swift run -c release BodyRefit <dir>`, which re-runs the same
`BodySkeletonFit.fit` the app runs; it grew a flatness block for this pass.

### What "flat" turned out to mean

The first job was to measure it rather than assume it, and the measurement moved the target.

1. **The sagittal excursion was never the problem.** On a near-side view the shot's sagittal plane
   *is* the image plane, so the elbow travelling forward from the set to the release is something the
   camera sees directly. The shooting elbow's image-plane travel is 0.104 H and the wrist's 0.194 H,
   both already there.
2. **The shooter had no left and right.** What the depth axis carries on a side view is the body's
   *thickness*, and that had collapsed: the fitted biacromial breadth came out **0.057 H against an
   adult's 0.245 H**, wandering **17.5 %** inside a single shot. The left and right shoulders sat
   0.039 H apart in depth, the hips 0.038 H, the ankles 0.038 H. Both arms hung off one point. That
   is the cardboard cut-out the user was looking at.
3. **The 2-D confirms it is unobservable, not merely unobserved.** The shoulder line projects to a
   median of 8.1 % of the shooter's own ankle-to-nose pixel span at its longest over a shot (2.8 %
   typically); an adult facing the camera would project 27.5 %. These clips are side-on to within a
   few degrees, so no amount of fitting recovers that breadth from these pixels.
4. **Vision's 3-D cannot lend it either.** Measured on the same 110 files, Vision's own
   `joints3D` put the two hips **0.0007 H** apart in depth and the two shoulders **0.0129 H** apart.
   Its 3-D body is itself near-planar on a side view. This killed the plan's first idea before it was
   written (see "what did not work").

### What changed

| | before (1.0) | after (1.1) |
|---|---|---|
| reprojection RMS, px (median / worst over shots) | 2.60 / 3.32 | **1.85 / 2.15** |
| shooting-elbow jitter, °/frame | 1.25 | 1.48 |
| knee jitter, °/frame | 1.02 | 1.35 |
| limb bone constancy, per-frame SD (upper arm / forearm / thigh / shin) | 0.1–0.2 % | **0.0–0.1 %** |
| worst drawn-segment SD, median over shots | 17.5 % | **2.3 %** |
| worst drawn-segment SD, 95th pct over shots | 22.4 % | **3.1 %** |
| biacromial, stature units (Winter 0.245) | 0.057 | **0.245**, declared a prior |
| shoulder L–R depth separation | 0.039 H | **0.239 H** |
| hip L–R depth separation | 0.038 H | **0.185 H** |
| ankle L–R depth separation (stance width) | 0.038 H | **0.133 H** |
| body depth extent (max − min joint depth) | 0.284 H | **0.341 H** |
| knee flexion range, ° | 67.2 | 74.7 |
| shooting-elbow opening, 3-D ° vs the image's own 48.5° | 34.4 | 35.8 |
| mid-hip depth 1σ, metres (the fit's own information matrix) | 0.0084 | **0.0050** |

Reprojection RMS is **29 % better** and bone constancy is **inside 0.1 %** on every limb bone, so the
gate the plan set ("RMS ≤ current, bone constancy ≤ 0.5 %") is met with room. The price is 0.23 °/frame
more elbow jitter, which keeps it inside the 1.4–1.9 °/frame band this project has reported since
iteration 2.

Three changes, in `BodySkeletonOptions`:

- **`torsoBreadthWhenUnobservable` (new, on).** *Only* on a view where
  `minimumBreadthProjectionFraction` has already **refused** the shoulder-line yaw — i.e. where the
  fit has proved the breadth unobservable — the torso is given a transverse axis built from two
  separate things: its **length** from Winter's population breadth of the shooter's own fitted stature
  (a prior, and `BodyBoneLength.source` says `population breadth (pinned)`), and its **direction**
  from the *measured* facing sign plus one anatomical fact (forward × left = up, so a shooter facing
  image-right has their left side away from the camera). Everything derived from the shoulder *line* —
  yaw, facing direction, sagittal lean, foot stagger — **stays refused**: this changes the skeleton's
  shape, not what may be read off it.
- **`BodyFacing.fromImage` (new).** The facing sign from two independent 2-D cues that must agree:
  the nose past the neck (median 15.8 px, 0.037 H) and the knee past the hip-to-ankle line (median
  27.0 px). They agreed on **110 of 110** phone shots. Disagreement is a refusal, not a vote; if
  neither clears the jitter floor the torso is left flat and a warning says so.
- **`depthSmoothnessScale` 1.0 → 0.3.** Iterations 1–4 smoothed all three axes equally, but in the
  image plane the smoothness competes with the reprojection term and in depth it competes with
  nothing, so an isotropic weight is several times stiffer in depth than anywhere the camera can see.
  Swept over the 107 shots with everything else at its final value (RMS px / elbow jitter °/frame /
  3-D elbow opening against the image's own 48.5°): 1.0 → 2.61 / 1.06 / 33.0; 0.5 → 2.10 / 1.31 / 36.1;
  **0.3 → 1.85 / 1.48 / 35.8**; 0.2 → 1.79 / 1.56 / 38.6; 0.1 → 1.73 / 1.64 / 38.3. Most of the
  reprojection is bought by 0.3 and the rest costs jitter; the opening is non-monotone across
  0.5 → 0.3, so the last 3° is inside this measurement's own noise and was not tuned to.

### What did not work, and was reverted

- **Vision's 3-D placement as a weak prior** (`visionDepthPriorWeight`, implemented, **default 0**).
  A weight of 0.3 took reprojection RMS from 2.52 to **3.86 px**, elbow jitter from 1.25 to
  **4.11 °/frame**, the worst bone SD from 2.4 % to **20.5 %**, and pulled the shoulder separation
  back down from 0.238 H to 0.136 H; a weight of 1.0 took RMS to **7.75 px**. Vision's 3-D body is
  near-planar on these views (§4 above) and inconsistent frame to frame, so a prior on its placement
  drags the fit toward a worse skeleton. The option is kept, documented and off, because the number
  that justifies "only the sign is used" is now written down.
- **Seeding the limbs' transverse depth as well as the torso's.** Seeding the elbows, wrists, knees
  and ankles at ±half a breadth put the guide wrist 0.31 H behind the pelvis and made the whole body
  0.50 H thick — 0.82 m for this shooter. Seeding only the four joints the pinned bones actually hold
  gives 0.34 H, at 1.85 px against 1.81. The thinner body is the true one; the limbs now follow their
  own bones off a shoulder or hip that is on the correct side of the body.
- **`projectionFloorMedianFrames` 9 → 15/21/31.** Worth 0.01–0.02 px of reprojection once the depth
  smoothing was fixed (1.85 → 1.84 → 1.83), and it shortens every limb bone by up to 1 %, against a
  default whose 9 was chosen on the swinging-arm synthetic. Left at 9.
- **Tempo-normalised smoothing** (scaling the second-difference weight by the frame interval, so the
  weight means an acceleration rather than a per-frame displacement) was *not* implemented: every
  file in this set is the same phone at the same analysed rate, so the data cannot discriminate it.
  It needs the 240 fps windows and is left for a pass that has them.

### The head

`Packages/ShotGeometry/Sources/ShotGeometry/HeadGeometry.swift` is new and pure (Foundation + simd).
The fit's only head joint is the **nose** (written out under the 3-D name `centerHead`), and
iterations 1–4 drew a sphere centred on it — a ball in front of the face, hanging past the neck,
which is what the user saw. `HeadGeometry.frame` places instead:

- a **skull ellipsoid** whose centre is 0.060 H behind the nose along the facing direction and 0.018 H
  above it, with semi-axes 0.042 / 0.065 / 0.0525 H (adult head breadth 0.084 H, height 0.130 H,
  depth 0.105 H) — so the mass of the head is behind the face, where a head's mass is;
- a **neck** drawn from the fitted neck joint to the skull's base, not to the nose;
- a **face side** — the measured nose, two eyes at ±0.018 H (interpupillary 0.036 H), and a chin line
  — placed from the *measured* facing direction: the horizontal part of neck → nose, the same cue
  `BodyKinematics.head` takes from the image, read off the fitted skeleton so the drawn face can
  never disagree with the drawn body, and locked to the shot's own median so one noisy frame cannot
  spin the head round.

When the nose sits within 0.012 H of the neck's vertical, or the shot carries no neck joint, the
facing direction is **refused**: the skull is bare — no eyes, no nose mark, no chin — and both
viewers' legends print the reason. Every proportion of the skull is a drawn proportion of the
shooter's stature, not a measurement of their head, and the body viewer's provenance card says so.

Both viewers use the same rig (`SceneHeadRig` in `App/Sources/SceneBody.swift`): solid on the body
volume (`BodyPlayerView`), translucent skull with solid face marks on the wireframe
(`FormModelView`), which is also where the mean form and an earlier session's mean form get a head.

### The picture

`docs/images/body-model-1.1-before-after.png` — shot 002 (free throw, 158 fps, side view), six phases
(load, dip, set, rise, release, follow) across, front and side down, **before** on the top half and
**after** on the bottom. Before: one flat plane of a body, both arms on the same line, a ball merged
into the shoulder for a head. After: a torso with a left and a right, the shooting arm in front of
the guide arm, and a skull on the neck with a face pointing at the rim. Rendered offscreen by
throwaway SwiftPM packages in the scratchpad (`t3a/rbefore`, `t3a/rafter`) around verbatim copies of
the pre- and post-1.1 `SceneBody.swift`; the "after" file is the same shot re-fitted through
`BodyRefit --write-shot`.

### Still open

- **The 3-D shooting arm still opens 12.7° less than the picture does** (35.8° against the image's
  own 48.5° from the set to the release). The fitted limb bones run 2–4 % longer than Winter's
  fractions (upper arm 0.190 H against 0.186, forearm 0.155 against 0.146, thigh 0.284 against 0.245),
  and a bone longer than the pixels support has to bend into depth at the moment the arm straightens.
  Whether the shooter's limbs really are long or the projection floor is biased up is not settled by
  this data; the swinging-arm synthetic is the place to settle it.
- **Stance width and the transverse axis are priors, not measurements**, on every clip this project
  has. A second camera, or one clip filmed at 30–45° off the shooting line, would measure them — and
  would also test the pinned breadth against a view that can see it. That is the filming request.
- **The depth uncertainty is still the depth uncertainty.** The fit's own information matrix puts the
  mid-hip's 1σ in depth at 0.0050 m after (0.0084 m before) — better, but it is the *pixels'*
  uncertainty, and it does not cover the pinned breadth, which is a prior and carries no σ at all.
  No depth-direction length may be read off the viewer as a measurement, and both viewers say so.
  (`BodyRefit` prints the depth σ but not the image-plane σ it should be compared against; the fit
  itself notes both, and adding the column to the harness is a five-line job for the next pass.)

---

## Solver and test-suite optimisation (2026-09-16)

Pure speed work on `Packages/ShotGeometry`. **No algorithm changed and no gate moved.** Every
optimisation below is the same arithmetic on the same values in the same order, so the results are
not "within tolerance" — they are bit-identical, and that is what was verified.

### Equivalence (the gate for this work)

| check | result |
|---|---|
| Real phone shots re-fitted (`BodyRefit`, 3 sessions) | **110** shots |
| max \|Δ\| per-joint 3-D position, before → after | **0.000e+00 m** (gate: 1 mm) |
| max \|Δ\| reprojection RMS | **0.000e+00 px** (gate: 0.1 px) |
| max \|Δ\| fitted bone length | **0.000e+00 m** |
| `swift run -c release GeometryHarness` output | **byte-identical** to the pre-change run; `GATE: PASS` |
| `swift run GeometryChecks` | 95 / 95 |
| `swift test` | 195 tests, 0 failures |

Phase timings are downstream of `joints3D`, which is bit-identical, so they are unchanged by
construction; `ShotPhaseDefinitionTests` and `FormModelTests` still pass.

The "before" `BodyRefit` was built from a copy of the pre-change `BodyKinematics.swift` (the only
file the skeleton fit depends on that this work touched, besides `Numerics`), and was checked to
reproduce the true original build's output byte-for-byte on session 74E9B9B8 before being used as
the baseline for the other two. The harness and `GeometryChecks` comparisons are against output
captured from the untouched project tree at the start of the work, not from a reconstruction.

### A. `BodySkeletonFit.fit` — 3.3–4.1× faster

Profiled with `sample` on `BodyRefit --profile` over 37 real 240 fps windows. Two things, not the
arithmetic, were the cost:

1. **`joints.firstIndex(of: bone.a)` in the inner loops** — a linear scan of a `[String]` comparing
   *strings*, run 38 times per frame per sweep in `solveFrame`, again in `cost`, again in
   `positionCovariance`, again in the per-sweep bone refit. Now `BodySkeletonFit.boneJointIndices`,
   resolved once (and `mirroredBoneIndexPairs` likewise).
2. **~200 heap allocations per frame per sweep.** `solveFrame`'s residual accumulator built a fresh
   `[Int]` and `[Double]` for *every scalar residual*; the Hessian, gradient, damped copy, Cholesky
   factor and two solve vectors were allocated per call; `choleskySolve` allocated three more per
   damping attempt. At 25 sweeps × ~150 frames that is ~800 000 allocations per shot. Now one
   `FrameNormalEquations` scratch object per fit, raw pointers, and unrolled 3×3/6×6 block updates.

Two smaller ones, both exact:

3. **Only the lower triangle of the information matrix is filled** — the factoriser never reads
   above the diagonal. Residuals normalise their two joints so the lower-indexed one comes first;
   the outer product is symmetric, so this is free.
4. **Envelope (profile) Cholesky.** Reprojection, smoothness and damping are block-diagonal in the
   joints; only a bone couples two joints, so the matrix's first non-zero per row is the skeleton's
   adjacency (`BodySkeletonFit.envelopeFirstColumn`). Cholesky provably introduces no fill-in to the
   left of it, so those columns are *exact* zeros and skipping them changes no bit of the factor.
5. `positionCovariance` factorises once and substitutes three right-hand sides instead of
   re-factorising the same matrix three times.

| | before | after |
|---|---|---|
| fit, mean per shot (37 shots, idle machine) | 0.098 s | **0.024 s** (4.1×) |
| fit, mean per shot (same, min of 5 under load) | 0.148 s | **0.045 s** (3.3×) |
| fit, total over 37 shots (idle) | 3.62 s | **0.91 s** |
| reprojection RMS, median / worst | 1.85 / 2.15 px | 1.85 / 2.15 px (identical) |
| max joint delta over 110 shots | — | 0 m |

### B. The Phase 1 gate path — harness 29.3 s → 8.4 s

`sample` on `GeometryHarness` put **`LinAlg.leastSquares`** and the malloc/retain traffic around it
at the top by a wide margin. It took `[[Double]]`: every row behind its own allocation with its own
reference count, so `R[i][j] *= s` paid a copy-on-write uniqueness check *per element* and the QR's
inner loops chased a pointer per row. The flight-window search fits a parabola starting at every
sample, ~1800 fits per `analyze`, so this ran constantly.

- `LinAlg.leastSquaresRowMajor` does the same Householder QR on a flat row-major buffer; the
  `[[Double]]` entry point is kept and forwards to it. `PolyFit.linear`/`.quadratic` and the
  release-ramp grid in `ReleaseDetection` now build the design matrix flat.
- `TrajectoryFitter.fit` gained an `ArraySlice` entry point, so the window search stops copying a
  sub-array per window, and folds five `map`s plus the finiteness check into one pass. The three
  RMS figures are accumulated directly instead of through `map`/`flatMap` (the old `flatMap`
  allocated a two-element array per inlier).

| | before | after |
|---|---|---|
| `swift run -c release GeometryHarness` | 29.3 s | **8.4 s** (3.5×), output byte-identical |

### C. The test suite

`swift test` builds `-Onone`, where every `for i in 0..<n` goes through a protocol-witness iterator
and every small array is a real allocation — sampling the debug `xctest` process showed
`Collection.formIndex(after:)`, `IndexingIterator.next()`, `swift_getAssociatedTypeWitness` and
malloc at the top, i.e. the *compiler*, not the code. The fix is to optimise the code under test:

```
swift test -Xswiftc -O
```

This changes the optimisation level, not the build **configuration**: `-assert-config` stays at
Debug, so `assert` and `precondition` are still live, `@testable` still works, and every
`XCTAssert` is the assertion it always was. No assertion was removed and no tolerance loosened.

| | test time | wall (cached build) |
|---|---|---|
| `swift test` (before this work) | 127.3 s | 132.3 s |
| `swift test` (after) | 41.6 s | 52.7 s |
| `swift test --parallel` (after) | — | 37.8 s |
| **`swift test -Xswiftc -O` (after)** | **1.1–3.6 s** | **8.5 s** |
| `swift test -Xswiftc -O --parallel` (after) | — | 9.6 s |

Per suite, `swift test` before → after: `BodySkeletonFitTests` 75.5 s → 5.8 s, `HeadAndTorsoTests`
11.0 s → 1.0 s (both §A), `GateTests` 32.3 s → 27.4 s, `FocalLengthTests` 6.9 s → 5.8 s (§B — the
unoptimised build eats most of §B's win; under `-Xswiftc -O` `GateTests` is 1.5 s).

`--parallel` does not help: SwiftPM forks one process per test **class**, `GateTests` is one class
and therefore the floor, and the optimised suite finishes in less time than the forks take. It is
not recommended, and the README says so. (The 37.8 s and 9.6 s rows above were measured while the
machine was carrying unrelated load; the other rows were not.)

**Monte-Carlo trial counts were left alone.** `GateTests.testGate30DegreeYawWithNoise` and
`testGateDroppedFrames` are not Monte Carlo — they are 5 *fixed* seeds each, and they do duplicate
a subset of `GeometryHarness` scenarios B and C, which draw 50 random shots apiece and are the gate's
authority (CLAUDE.md rule 5). Cutting the tests to 2–3 seeds was available and sanctioned, but it was
not needed: under `-Xswiftc -O` the whole `GateTests` class costs well under 2 s, so trading coverage
for time would buy nothing. The five seeds stay. Per-class fixture sharing was likewise not needed — `BodySkeletonFitTests` went
from 75.5 s to 0.5 s on the strength of §A alone.

### Tried and reverted

- **Quickselect instead of `sorted()` in `Stats.median`.** Exact (same elements, NaN falls back to
  the sort) and worth ~18 % of the release harness — but 2.6× *slower* under `-Onone`, because
  `sorted()` runs as optimised stdlib code while a hand-written loop in this package does not. A
  primitive used this widely should not get slower in the configuration the app's own debug builds
  use, so it went back to `sorted()`.
- **Reordering `BodySkeletonFit.joints` to shrink the Cholesky envelope** (the neck sits at index 13
  and makes its three rows full). Mathematically identical, but it changes accumulation order and so
  the last bits of every fitted position. Not worth giving up an exact equivalence proof for an
  estimated further ~1.3×.
- **A banded/block solve over time instead of Gauss-Seidel sweeps.** This would be a different
  algorithm with different answers; the brief's tuning (sweep counts, the once-only bone refit) is
  calibrated against the current one. Left for a pass that can re-run the tuning.

### Still open

- The factoriser's inner dot product is scalar. SIMD would reassociate the sum and is therefore not
  bit-exact; it is the obvious next step if an approximate-equivalence gate is ever acceptable.
- `FormModel.build` and `FootworkMetrics.compute` were checked and are not hot (37 `FormModelTests`
  total 1.0 s, 18 `FootworkMetricsTests` total 0.03 s, both unoptimised). `FormSkeleton.index(of:)`
  is the same string-scan pattern §A removed from the solver, if they ever become hot.
- `ShotPlaneSolver.objective` runs a full robust fit 220 times per azimuth solve and up to 6 solves
  per `analyze`. That count is the next real lever on the gate path, and it is an algorithm question
  (does the golden-section refinement need 40 iterations?), not a micro-optimisation.

## Pipeline optimisation (2026-09-16)

Making the video analysis pipeline faster without moving a number. The rule this pass worked under is the
one the phase gate states: on the 240 fps in-app clip and on the bench clip, the accepted set, every release
speed, angle and entry angle, and the body numbers must come out as they did before. **Every change kept
below is bit-identical** on both clips — same detections per window, same fitted g, same release instant,
same table, line for line — and the ones that were not are recorded under "Measured and rejected" with what
they cost.

### Where the time actually goes

The first thing this pass did was read the existing phone log rather than add to it. The
`analysis.shot.stage` "stages" row **already** carried `vision.pose`, `body.vision`, `body.fit` and `fit`;
the ball-stage table quoted in the brief was only the part of that row that comes from `BallDetector`.
Averaged over the 48 windows of the 46-shot run in `activity-2026-09-15.jsonl` (iPhone 14 Pro, 1080p120,
thermal `serious`, one lane, 442.9 s for the batch):

| stage | mean s | median s | what it is |
|---|---|---|---|
| `coreml` | 2.681 | 2.771 | the ball detector's 512 px tiles |
| `body.vision` | 2.344 | 2.726 | `BodyTracker`: 2-D + 3-D + hands over dip→follow-through |
| `vision.pose` | 2.122 | 1.993 | `PoseTracker`: the release instant from the wrist |
| `candidates` | 0.406 | 0.347 | per-frame blob search |
| `motion` | 0.368 | 0.366 | the probe that aims the Core ML tile |
| `planes` | 0.326 | 0.327 | half-resolution Y and Cr per frame |
| `template` | 0.211 | 0.124 | template match over gaps |
| `background` | 0.198 | 0.197 | per-pixel median background |
| `decode` | 0.155 | 0.144 | everything in the decode loop that is not the above |
| `body.fit` | 0.082 | 0.098 | `BodySkeletonFit` |
| `link` | 0.061 | 0.062 | the linker |
| `fit` | 0.055 | 0.058 | `ShotAnalyzer.analyze` |
| **sum** | **9.01** | | wall per window 9.23 mean, 9.43 median, 11.15 max |

Two things follow. **Three Vision/ANE passes are 79 % of the window** — and two of them are body-pose
passes over overlapping spans of the same clip, decoded twice. And **nothing outside the ANE is big enough
to matter on its own**: the whole CPU side is 1.9 s.

### What the log now says

Everything above was already logged; these are the parts of the bill that were not.

| new field / event | where | what it answers |
|---|---|---|
| `body.model` | stages row | `BodyKinematics.model` + the `BodyShot` payload build |
| `coreml.crop` | stages row | cutting the 512 px tiles out of the frame (now separate from inference) |
| `coreml.wait` | stages row | how much of `coreml` the decode loop actually had to wait for |
| `lanes`, `thermal`, `phase` | stages row | which batch shape produced this row |
| `rowSeconds` | `analysis.shot.done` | building the `BlockRow` on the main actor |
| `seconds` on `body.export` | existing event | the `BodyShot` JSON encode + atomic write (already off the main actor — checked, not assumed) |
| `scan.stages` | new event | `scan.decode` / `scan.detect` for the whole scan, with the frame count |
| `memoryLanes`, `budgetMB`, `deferBody` | `analysis.start` | which of the two limits set the lane count |
| `analysis.ball.end`, `analysis.body.start/end` | new events | the two phases of a batch, separately |

### Kept — every one of these is bit-identical on both clips

| change | file | default before → after | what it buys |
|---|---|---|---|
| Scan in concurrent lanes, each with its own reader and background, pre-rolled over the seam | `RimArrivalScanner` | `RimScanOptions.lanes` 1 (implicit) → **2** | the scan is decode-bound and one reader does not saturate the decoder |
| Per-pixel median background split over the cores by tile | `BallDetector.medianBackground` | serial → up to **4** workers | `background`, ~0.2 s/window on the phone |
| Per-frame candidate search split over the cores by frame, one `CandidateFinder` per worker | `BallDetector.track` | serial → up to **4** workers | `candidates`, ~0.4 s/window on the phone |
| Core ML inference moved off the decode loop: the tiles are cut while the buffer is in hand, the model runs on another thread, and the boxes are applied one frame later — before anything reads them | `BallDetector.decodeWindow`, `CoreMLBallDetector.cutTiles` / `detect(tiles:)` / `InflightInference` | serial → overlapped | the plane extraction and the motion probe of frame *k+1* now run *while* frame *k* is in the model |
| Multi-tile frames go through the model as one batch | `CoreMLBallDetector.detect(tiles:)`, `ModelBox.predictBatch` | one prediction per tile → batch from **2** tiles | a whole-frame sweep is 15 tiles; the model is per-image, so the boxes are the same |
| The reader skips the re-wrap for frames a stride does not analyse, and caches the format description | `VideoReader.forEachFrame(stride:)`, `RewrapBox` | every frame re-wrapped, a fresh `CMVideoFormatDescription` each time → only analysed frames, one description | `PoseTracker` and `BodyTracker` sample every 2nd/3rd frame |
| The body model is a second pass over the block, after every shot's ball numbers are on screen | `SessionModel.deferBodyStage`, `ShotAnalysisRunner.bodyOnly` | inside each window → after the batch | the shooter sees the numbers ~2.4 s/window sooner |
| `serious` no longer forces one lane; only `critical` does | `SessionModel.analyseAll` | serious → 1 → serious → whatever memory allows | see below |

### Before and after on the Mac

Every run below is `TrajectoryProbe` on this Mac, and the two arms are interleaved in one loop so they see
the same machine. `ARCLAB_SERIAL_PASSES=1` and `ARCLAB_NO_BATCH=1` reproduce the pre-2026-09-16 behaviour in
the same binary, which is what "before" means here. **Caveat on the absolute numbers:** `mediaanalysisd`
spent most of this session at 150–200 % CPU indexing the clips in the scratchpad, so the wall times are
inflated and noisy; the ratios below come from interleaved repeats, and the scan rows report every repeat.

**Scan** (`TrajectoryProbe scan`, five alternating repeats per clip, seconds):

| clip | one lane | two lanes | |
|---|---|---|---|
| bench clip, 250 s, 7 500 frames, 30 fps container | 4.39 4.19 4.08 4.32 4.52 (median **4.32**) | 2.94 2.97 3.05 3.04 3.40 (median **3.04**) | **−30 %** |
| 240 fps in-app clip, 0–130 s, 31 198 frames | 40.96 55.95 48.32 (min **40.96**) | 56.67 40.98 40.16 (min **40.16**) | **−2 %, i.e. nothing** |

That split is the finding, not noise in it: the bench clip's scan is **CPU-bound** (a 30 fps container, so
the decoder is idle most of the time and the detect loop is the cost) and lanes halve the detect work; the
240 fps clip's scan is **decoder-bound** and two readers just share one hardware decoder. The phone's
1080p120 footage decodes at 745 fps (69 121 frames in 92.8 s, `activity-2026-09-15.jsonl`), the same rate
this Mac gets on the 240 fps clip — so it is probably in the decoder-bound regime and the lanes will buy
little there. The new `scan.stages` event prints `scan.decode` and `scan.detect` for exactly this reason:
one phone run now says which regime it is in, instead of one number that cannot.

**Analysis** (`TrajectoryProbe session --scan-lanes 1` in both arms, so only the per-window changes show):

| clip | per-window median, before | after | |
|---|---|---|---|
| bench clip, 7 windows, 3 repeats | 10.03 9.78 9.42 s (median **9.78**) | 10.04 8.75 8.73 s (median **8.75**) | **−11 %** |
| 240 fps clip 0–130 s, 11 windows, 2 repeats | 7.52 8.75 s | 7.51 8.00 s | **−5 %** |

Per stage, from the last repeat of each (totals over all the windows of one run, seconds):

| stage | bench before | bench after | 240 before | 240 after | |
|---|---|---|---|---|---|
| `candidates` | 4.73 | **2.59** | 21.30 | **9.95** | −45 % / −53 % (split over 4 cores) |
| `background` | 2.71 | **0.89** | 3.34 | **1.03** | −67 % / −69 % (split over 4 cores) |
| `coreml` (the model's own seconds) | 31.07 | 32.53 | 12.09 | 13.39 | unchanged, as it must be |
| `coreml.wait` (what the loop waited) | 31.09 | **26.21** | 12.13 | **10.79** | −16 % / −11 % — the overlap |
| `coreml.crop` | 0.11 | 0.19 | 0.09 | 0.08 | cutting the tiles, now counted separately |
| `vision.pose` | 15.93 | 16.34 | 17.46 | 18.73 | untouched |
| `planes`, `motion`, `template`, `link`, `decode` | | | | | untouched |

`coreml` against `coreml.wait` is the overlap, measured: the model costs what it always did, and the decode
loop now waits for 16 % less of it because the next frame's planes and motion probe run during the
inference. On the phone the ratio should be better than on this Mac — a window's plane extraction, motion
probe and decode are 0.85 s against 2.68 s of inference, i.e. 4.3 ms of CPU per 13 ms of Neural Engine, so
in principle all of it hides.

**What this is worth on the phone.** Applying the measured per-stage ratios to the phone's own budget above:
`candidates` 0.41 → ~0.19, `background` 0.20 → ~0.06, and `coreml` 2.68 with 16–100 % of the CPU work
hidden → −0.4 to −0.85 s. That is a per-window **9.0 s → about 7.8–8.2 s** including the body stage, and —
with the body stage deferred — a wait for a shot's numbers of about **5.5 s** on a phone in a `serious`
thermal state, against 9.2 s before. The 5 s hot target is close but not met, and the thing standing
between here and it is the duplicate body-pose pass (below), which a parity gate cannot touch.


**Correctness.** Both clips, before against after, over the whole session output: the same 7 and 11 windows,
the same detection count per window, the same fitted g, release height, speed, angle, entry angle, depth,
inlier count, reprojection RMS and release instant — `diff` reports no difference at all, so the parity is
exact rather than within tolerance. Accepted: 4 of 7 on the bench clip, 8 of 11 on the 240 fps clip, both
unchanged.

### The lane count was never a thermal decision

`analysis.start` in `activity-2026-09-15.jsonl` reads `lanes 1, windowMB 335.9` on **every** run of the
1080p120 footage — thermal `fair` and thermal `serious` alike. A 2.8 s real window at 120 fps holds about
336 MB of half-resolution Y and Cr planes and the budget is 320 MB, so `max(1, 320/336)` had already
returned 1 before the thermal state was read. The "one window at a time because the phone is hot" note the
app printed was true but not causal, and it hid the real limit.

So the thermal rule now fires only at `critical`, and `analysis.start` records `memoryLanes` and `budgetMB`
alongside `lanes`. On this footage nothing changes — it is still one lane, for the stated reason — but the
phone bench can now see *which* limit bound, and a clip whose windows do fit two lanes keeps them when the
phone is merely hot. **Two lanes at `serious` is still unmeasured on the phone**: it cannot be measured
until a window fits the budget twice, which is a memory question (see "Still open").

### The deferred body stage

`ShotAnalysisRunner.run(runBody:)` already existed, and the body stage already took the release the
analyzer had used rather than feeding it — so moving it is pure scheduling. `SessionModel` now runs the
queue twice: every window's ball numbers first, then `ShotAnalysisRunner.bodyOnly` per measured shot, which
is the identical span, options and reasons the in-window stage used. The row is rebuilt and the `BodyShot`
written at the end of the second pass, and `SessionModel.bodyPhase` drives a "every shot is measured; form
model N of M…" line in the guided and practice views.

On the hot-phone budget above this takes the wait for a shot's numbers from 9.2 s a window to about
**6.5 s** (9.01 − `body.vision` 2.34 − `body.fit` 0.08 − the new `body.model`), with the form cards filling
in afterwards. Total batch time is unchanged by the move itself.

### Measured and rejected

- **A stride on the scan's pixel work** (`RimScanOptions.processHz`, kept as a knob, default off). The
  arrival rule does not need a per-frame measurement — a near-rim blob, one above it within three frames,
  and six high in the frame over the preceding 1.5 s — so a 120 fps clip need not be searched 120 times a
  second. It works and it is large: the bench clip's scan went 4.2 s to 2.7 s and 130 s of the 240 fps clip
  41 s to 34 s. It was rejected because **it moves the arrival frame**, by up to 4.5 file frames (37 ms of
  real time) on the bench clip, and the analysis window moves with it. The release instant is quantised to
  the pose stride (16.7 ms of real time at 120 fps), so a moved window lands on a different pose frame, and
  g·Δt then moves the release speed: two of the bench clip's four accepted shots moved by 0.11 and
  0.18 m/s, against a 0.05 m/s parity budget. The same run also flipped the 240 fps clip's accepted count
  from 8 to 9. **This is worth knowing for its own sake:** the release speed of a marginal shot is not
  stable to a 37 ms shift in where its window starts, which is a measurement-robustness finding, not an
  optimisation one.
- **Hardware-scaled decode for the scan** (`RimScanOptions.scaledDecode`, kept as a knob, default off).
  Asking `AVAssetReaderTrackOutput` for a half-size buffer moves the downscale from this process to
  VideoToolbox. It does not remove the work, it moves it: on 130 s of the 240 fps clip at one lane,
  27.2 s decode + 14.9 s detect (42.4 s wall) plain, against 35.1 s decode + 3.8 s detect (39.1 s wall)
  scaled; at two lanes the two are the same wall time (29.1 s against 30.4 s). It also changes the pixel
  values slightly — VideoToolbox's filter is not the box average the work grid is defined by — so the
  default keeps the candidates exactly what they were.
- **Three scan lanes.** 30.0 s against 31.5 s at two, on 130 s of the 240 fps clip. A third lane buys ~5 %
  and the phone is already producing `AVFoundationErrorDomain −11847 "Operation Interrupted"` under *one*
  reader (twice in `activity-2026-09-15.jsonl`). Two.
- **Merging the release-pose pass into the body pass.** `BodyTracker` already runs the same
  `DetectHumanBodyPoseRequest` that `PoseTracker` runs, over a span that contains most of the pose pass's,
  and it runs it on a *crop* — 20 ms an analysed frame with three requests against 29 ms with one on the
  full frame. One pass instead of two would take about 2.0 s a window off a 9.0 s budget, the largest
  single win available. It was **not** done, because the crop changes the 2-D wrist by a pixel or two and
  the release rule is a threshold on the ball-to-wrist distance: any change to the release instant moves
  the release speed by up to 0.16 m/s per pose frame, which the parity gate does not allow. It needs a pass
  that is allowed to re-baseline the numbers, and it should be the first thing that pass does.
- **Allowing the Core ML motion-skip at 120 fps** (`coreMLSkipWhenMotionAgrees` above
  `referenceFrameRate`). Already measured and rejected on 2026-09-15 — it moved two labelled free throws'
  releases by 2 file frames and their residuals from 5.5/5.7 px to 6.7/6.4 px — and re-checked here only to
  confirm it is the reason a 120 fps clip shows `0 skipped on motion` while the 240 fps clip skips ~450
  frames a window. This is why `coreml` is 2.7 s a window on the phone's 1080p120 footage and 0.5 s on the
  240 fps one.
- **Running the motion probe on the half-resolution planes the loop already builds** (instead of
  re-reading the full frame). It would save roughly 0.25 s a window. Not done: a box average of a box
  average is not the box average, so the aim point moves by up to one work pixel, the 512 px tile moves
  with it, and the model can then return a different box. Same reason as the scan stride.

### Still open

- **The two body-pose passes.** 4.5 s of a 9.0 s window is two `DetectHumanBodyPoseRequest` passes over
  overlapping spans of the same clip. One pass would serve both, and it is the only change left that is
  worth more than a few hundred milliseconds. It cannot be done under a bit-parity gate (above); it needs
  a pass that re-baselines the release instant and re-runs the acceptance numbers.
- **Two analysis lanes need a smaller window.** A lane is 336 MB of half-resolution Y and Cr planes because
  the whole window is kept so the three detector attempts can share one decode. Storing Cr at quarter
  resolution would make it 210 MB; keeping only the ~25 background frames and re-decoding for the candidate
  pass would make it ~30 MB at the cost of one extra decode (~0.2 s). Either would put two lanes inside the
  320 MB budget and make the thermal question measurable. Both change the candidate arithmetic or the decode
  count, so neither belongs in a parity pass.
- **Core ML compute units and input size.** `MLModelConfiguration.computeUnits` is `.all`. On a phone whose
  GPU is also driving the screen, `.cpuAndNeuralEngine` is worth an A/B that only the phone bench can run.
  The model's image input is flexible from 299 px; the tile is cut at the training size (512 px of native
  source) and that is the field of view the model expects, so a smaller *source* window is not available —
  but rendering the 512 px source into a 299 px input is, and is untested.
- **The tile origin is off by up to one pixel.** `CoreMLBallDetector` maps boxes back using the *requested*
  tile origin, while `crop` clamps that origin and rounds it down to an even pixel. The two differ by at
  most one pixel and the hybrid placement usually takes the blob's centroid anyway, so it rarely matters —
  but it is a bug, not a tolerance, and fixing it will move some boxes. Left for the same re-baselining pass.
- **`BodyTracker.everyNthFrame`** is 2 at ≥100 fps real. 3 would take about a third off `body.vision`; it
  changes the timeline's sampling, so it needs the reprojection-RMS and phase-timing comparison the body
  harness does, which is a re-baselining question rather than a parity one.

### Build note (2026-09-16)

Xcode updated itself from 26.6 to **27.0** part-way through this pass, and every developer tool now refuses
to run until someone accepts the new licence:

```
$ swift build -c release
You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' …
```

That needs a password, so it is the user's to run. Until it is, neither `swift build` nor `xcodebuild` works.
The measurements above were all taken with the release binary built before the update, which contains every
algorithmic change in this section; the handful of edits made after it (the probe's `--help` text, the
scan's thermal guard and progress fraction, `FormClipScanner`'s stride, and the app-side export and
progress-line changes) are syntax-checked with the Command Line Tools front end
(`/Library/Developer/CommandLineTools/usr/bin/swiftc -parse`, clean on every changed file) but have not been
type-checked. The app itself built clean (`BUILD SUCCEEDED`) on Xcode 26.6 with the deferred body stage, the
lane rule and the new log fields in place. **First thing after accepting the licence: `swift build -c release`
in `Packages/ShotVideo` and `xcodegen generate && xcodebuild … build` in `App`.**

---

## Form evaluation harness (2026-09-16)

Track D of `docs/PLAN-1.3-2026-09-16.md`. An honest, repeatable way to say how well the 3-D form
tracks the real movement — without a mocap lab — so every later biometrics change has a gate to
clear. Full baseline and the argument behind each number:
**`docs/research/form-eval-baseline-2026-09-16.md`**.

### What it is

- `Packages/ShotGeometry/Sources/FormEvalKit` — the statistics (ICC(2,1), percentile bootstrap,
  repeatability), the per-shot measurements, the label scoring, the report. Foundation + simd only.
- `Packages/ShotGeometry/Sources/FormEval` — the CLI over a directory of exported `BodyShot` files.
- `Packages/ShotGeometry/Tests/FormEvalKitTests` — 27 tests, every one against an answer worked out
  on paper (percentile type-7 values, the two-way ANOVA mean squares of a hand-computed 3×2 table,
  the closed form ICC(2,1) = 2·var(a)/(2·var(a) + c²) for a constant offset c, the SDC algebra) plus
  a synthetic projected skeleton for the reprojection and held-out paths.

### How to run it

```bash
cd Packages/ShotGeometry
swift build -c release
swift run -c release FormEval <dir of BodyShot .json> --json out.json --markdown out.md
```

It prints seven sections and two gate lines, writes the same as JSON, and **exits non-zero when a
gate fails**, so it drops into CI unchanged. Useful flags:

| flag | what it does |
|---|---|
| `--max-rms 10` | refuse a shot whose fit reprojects worse than 10 px RMS (1 of 38 today) |
| `--held-out all\|none\|<list>` | which joints to re-fit without (default: all 14) |
| `--no-retest` | skip the even/odd refits — halves the run, loses the repeatability table |
| `--no-dedupe` | count every file, including repeat exports of one session |
| `--labels <dir>` | score the fit against hand labels, with the double-label noise floor |
| `--limit N`, `--confidence C`, `--hfov D`, `--height M`, `--bootstrap N`, `--quiet` | as named |

646 fits over the 110 phone files take **32 s** on this Mac.

### What it measures, and what each number is worth

1. **Reprojection per joint, driven** — a consistency check. Median 0.52–1.76 px (0.005–0.017
   shoulder-widths); whole-skeleton RMS median 1.85 px.
2. **Held-out joints** — the number that is not a tautology. `blink` hides a joint on every 4th
   frame and scores those frames: shooting wrist **1.87 px** median / 4.38 px p90, far-side knee
   4.79 / 15.11. Every held-out error is 2.7–3.5× its driven counterpart. `absent` (the joint hidden
   on every frame) found that **this build's fit drops a joint it never observed** rather than
   carrying it on its bones — 10 of 14 joints produce no point at all; shoulders and hips survive
   only via the symmetry prior, 83–123 px out.
3. **Bone-length constancy and left–right symmetry** — both proposed gates pass at **0.02 %** against
   3 % and 4 %, and **the pass carries no information**: the fitted skeleton holds limb bones rigid
   (`limbBoneWeight = 3`) and Vision's 3-D request returns a *rigged* skeleton whose limb lengths are
   also constant (0.01–0.02 % SD). The harness gates only the nine single anatomical segments and
   prints spans that cross an articulation as `articulated`. One real finding survives: the fitted
   **`neckNose` span wanders 11.6 %** against Vision's 0.03 % — the head is the least constrained
   part of this skeleton.
4. **Phase-instant coverage** — all 14 body joints are present on **100 %** of shots at set, dip,
   release and follow. The gap is the *hand*: any hand at release **19 %**, the shooting hand
   **14 %**, the hand-plate corners 0 %. (This corrects "2 of 37 forms carry the right wrist at
   release" — that was the hand detector, not the body pose.) Also: **27 of 37 free throws have no
   dip**, so `dipDepth` is an n = 10 measure on this shooter.
5. **Repeatability** — shots as subjects, two refits of the same shot on disjoint halves of its
   frames as the repeated measurements. `jumpHeight` ICC(2,1) **0.92** and `headHorizontalRange`
   **0.86** are ready to coach on; `kneeMinimum` is **noise** (σ_meas 15.5° against a 9.1°
   shot-to-shot spread, ICC −0.26) and `elbowAtRelease` is nearly as bad (SDC 42°). Two of ten
   measures pass a 0.75 ICC line.
6. **Hand labels** — `--labels <dir>` scores the fit against human clicks and prints the
   double-label noise floor beside it. First sheet is cut and waiting: see below.

### The gate to hold new work to

`docs/research/form-eval-baseline-2026-09-16.md` §7 proposes the lines, with today's value beside
each. The two that bite: **held-out (blink) median ≤ 0.05 shoulder-widths for every fitted joint**
(worst today 0.047, one joint from failing) and **ICC(2,1) ≥ 0.75 for any measure shown to a user**
(2 of 10 today). Hands and feet add instant-locked angles — wrist snap, foot roll — which are the
fragile kind in §6; they must arrive with their own rows in the repeatability table or they should
not be shown.

### The 110 files are 37 shots

The phone directory holds three exports of one 37-shot free-throw session: two byte-identical, the
third the same 2-D input re-fitted by another build. The harness hashes each file's `points2D` and
drops 72 of 110. **"110 real phone shots" elsewhere in this document means 37 shots counted three
times** — the fits are real, the N is not. There is also no second condition in this data: one
shooter (1.70 m stated), one spot, one side-on framing, 48° assumed hFOV, 158 fps.

### The label sheet, and how to label it

`<scratchpad>/labels/` — **20 frames, 5 free throws, 4 frames each at −60/−20/+20/+60 ms around the
release**, cut from the 240 fps clip `03D7D2BF-2056-4AFE-948C-4D615953A49B.mov`, one JSON template
per frame for 12 joints (including `rightHeel` / `rightBigToe` / `rightLittleToe`, which this build
cannot fit and Track C will). `HOW-TO-LABEL.md` in that folder has the joint definitions and the
procedure; `labels/bodyshots/` holds a `BodyShot` per shot so the labels have something to score
against. `<scratchpad>/make_label_sheet.py` cuts more sheets (ffmpeg is **not** installed here, so it
drives `TrajectoryProbe frame`, which also reports each frame's true presentation time).

Two gaps found while building it, both worth closing:

- **A `BodyShot` does not record the clip it came from** (schema v1 `source` has kind/build/device/
  format and no file reference), so the clip has to be passed by hand. `source.clip` would fix it.
- **The app's session record stores each shot's window but not its release time**, so the 240 fps
  brackets are centred on `windowStart + 0.80 s` — the offset measured on the one session that
  records both (37 shots, 0.77–0.85 s, SD ≈ 40 ms). The labeller ticks which of the four frames is
  the true release, which turns the estimate into a measurement.

---

## Hands and release coverage (2026-09-16)

ArcLab 1.3, Track B. The hand becomes an **oriented plate** — wrist (back) · index MCP (front-inner)
· little MCP (front-outer) — attached at the fitted wrist, with the plate's *size* a declared
population prior and only its *orientation* fitted. And the coverage question the plan opened with:
only 2 of 37 free-throw forms carried the right wrist at the release instant. That turned out to have
nothing to do with hands.

### 1. Why 33 of 37 forms were empty at their own release instant

Measured first, guessed never. `HandProbe` (new, `Packages/ShotGeometry/Sources/HandProbe`) rebuilds
the whole chain from the exported records — `BodyShot` → timeline → `BodySkeletonFit` →
`HandTriangleFit` → `ShotForm` — and reads the sample at τ 0.75. On session `Free throws`
(clip `74E9B9B8`, 37 shots) the 1.2 code gave:

```
shooting wrist    2/37 (  5 %)
shooting elbow    2/37 (  5 %)
reasons
  ×33  the form has no sample at τ 0.75 (the release anchor is missing)
  ×2   no phase pair in this shot was found on both ends
```

The **elbow is missing exactly as often as the wrist**, which rules out every hand-side explanation
at once: it is not the 2-D confidence gate, not ball occlusion, not the hand crop, not
`everyNthFrame`. It is the **phase clock**. `ShotForm.realTime(forNormalised:anchors:)` walked the
four phase segments in order and returned the *first* segment containing τ; τ 0.75 is the upper end
of dip → release, so a shot whose dip was refused hit that segment, found one end nil, and gave up —
without ever reaching release → follow-through, whose lower end is the very anchor being asked for.
This shooter's free throw genuinely has no dip (the body model says so per shot: "the hand descended
only 0.013 into its lowest point against a 0.305 rise, 4.4 %, floor 5 %"), so 33 of 37 shots lost
their own measured release.

The fix is one rule: **an anchor's own τ needs no neighbour.** τ 0.75 *is* the release and the release
time is measured, so it resolves to that time; the stretches *between* two anchors still need both
ends and are otherwise absent, never interpolated across. `HandTriangleTests
.testReleaseInstantSurvivesAMissingDip` pins it, including that a release that was never dated stays
nil.

### 2. Coverage at τ 0.75, before and after

37 shots of `Free throws` (`74E9B9B8`), the same files, the same fit options.

| at τ 0.75 | 1.2 (before) | 1.3 (after) | what moved it |
|---|---|---|---|
| shooting wrist | **2/37 (5 %)** | **37/37 (100 %)** | the phase-clock fix |
| shooting elbow | 2/37 (5 %) | 37/37 (100 %) | the phase-clock fix |
| index MCP | 0/37 (0 %) | **4/37 (11 %)** | the point did not exist before; now lifted, and gated per sample rather than by window coverage |
| little MCP | 0/37 (0 %) | 4/37 (11 %) | the same |
| hand plate (≥ 2 points) | 0/37 | 5/37 (14 %) | — |
| hand plate oriented (3 points) | 0/37 | 4/37 (11 %) | — |
| skeleton reprojection RMS (median) | 1.85 px | 1.85 px | unchanged: the hand plate is fitted *after* the skeleton and never moves a body joint |
| hand-plate reprojection RMS (median) | — | 3.83 px | the constructed knuckles against the landmarks they were built from |

The other two phone sessions agree: `7EFFEC92` 37/37 · 37/37 · 4/37, `930D5CFC` 36/36 · 36/36 · 3/36.

Three smaller fixes are inside that table, each with its provenance stamped on the point
(`BodyPoint2D.provenance`, exported as `points2D[j].provenance`):

- **appendage points get their own confidence floor, 0.20.** Vision's hand-landmark confidences are
  nothing like its body-pose ones on a hand this small — measured over 1351 hand observations in this
  session, median 0.31 at the wrist, 0.50 at the index MCP, 0.50 at the little MCP — so the body's
  0.30 floor would discard half of every hand. Swept: 0.05 → 6/37 plates at the release, 0.10 / 0.20 /
  0.35 → 5/37, 0.70 → 0/37.
- **the wrist may come from the hand pose** when the body pose returned none on that frame ("wrist
  from hand pose"). Two detectors, one anatomical point, so it is a second observation and not an
  inference. It fired on 2 frames in 37 shots here — rare, because the body wrist is the *reliable*
  half of this problem (37/37 at the release).
- **a point may be carried across one sampled frame** and never two (271 points over 37 shots, 13 ms
  each at 79 samples/s). Switching it off costs nothing at the release (5/37 either way) and 1 point
  of whole-window plate coverage (18 % → 17 %), so it is kept for the drawing, not for the numbers.

Also fixed, and the reason the MCPs reach a form at all: `ShotForm` gated every joint on its
**window** coverage (`minimumSeenFraction` 0.20), which is the right question for a joint the fit
carries on bone lengths alone and the wrong one for an appendage point, which exists *only* on the
frames its landmark was seen on. Appendages are now gated per sample, by presence. Without that
change the index MCP scored 1/37 instead of 4/37 — the gate was throwing away the instants that had
actually been measured.

### 3. What is left is not fixable in software: the ball is in the way

Hand rate against time from the release, pooled over the 37 shots (1351 hand observations):

| Δt from release | −0.50 | −0.35 | −0.20 | −0.05 | **0.00** | +0.05 | +0.15 | +0.35 | +0.40 |
|---|---|---|---|---|---|---|---|---|---|
| frames with a hand | 3.6 % | 0 % | 0 % | 0 % | **16.8 %** | 56.8 % | 71.4 % | 83.8 % | 85.5 % |

Zero before the release, half to five-sixths after it, and the step is *at* the release to one
sampled frame. That is the shooting hand being wrapped around the ball: Vision's hand pose does not
return a hand it cannot see the palm and fingers of, and the release is by definition the instant the
ball leaves them. It is also an independent check that the release instant itself is right.

So the honest ceiling for a *shooting-hand* plate at the release instant on this footage is low, and
the record says which reason applies rather than filling it in:

> the right hand had no fitted plate within 20 ms of the release: the shooting hand is on the ball
> right up to that instant and Vision's hand pose does not see a hand wrapped around a ball

Everything the plate *is* for after that instant — the wrist snap, the follow-through, the guide
hand's departure — sits in the 50–85 % band and is measurable.

### 4. The plate itself

`Packages/ShotGeometry/Sources/ShotGeometry/HandTriangle.swift`. Each knuckle is placed where its own
view ray meets a sphere of the prior's radius about the fitted wrist, the pair is then made exactly
rigid, and the palm normal, the pointing direction and the roll are read off it. Three decisions were
measured rather than argued:

- **the depth branch is chosen for the pair, not one knuckle at a time.** Each ray meets the sphere
  twice — in front of the wrist's depth plane and behind it — and the only unused constraint is the
  triangle's third side. Chosen independently (least depth excursion each) the two collapse onto the
  same branch whenever the plate is near edge-on: on the 240 fps clip the breadth residual was −78 %
  that way and −46 % by the pair rule, with the same pixels; on the phone session, 4.35 px → 4.03 px
  of plate reprojection.
- **the apex stays on the *body* wrist.** The hand pose's own wrist landmark is 0.025 × stature from
  the body pose's (median over 1349 observations, 43 % of the prior's palm length), so moving the
  apex there is the obvious improvement — and the pixels refuse it: reprojection 4.35 → 5.67 px,
  breadth residual −18 % → −27 %, wrist-flexion range through the release 105° → 175°. The hand-pose
  wrist is the least confident of the 21 landmarks (p50 0.31), so it brings more noise than offset it
  removes. `HandTriangleOptions.apexFromHandPoseWrist` keeps the measurement reproducible; it is off.
- **a plate whose two knuckles land within 6 px of each other is refused outright** — corners and
  orientation — because the camera is then looking along the hand's own width and there is nothing to
  orient. 6 px is this project's own keypoint-noise floor (Vision vs MediaPipe agree to 4–7 px;
  `huberPixels` is 12 for the same reason). It matters most where you would least expect: on the
  240 fps clip the shooter is only 351 px tall and the two MCPs are **3.9 px apart** at the median
  (0.011 × stature against the prior's 0.049), so the gate takes the right hand's plate coverage from
  42.7 % to 15.4 % of frames and the plate reprojection from 6.14 px to 2.92 px. On the phone session
  the MCPs are 12 px apart (0.029 × stature) and coverage barely moves (18 % → 16 %).

The size prior is declared everywhere it is used — in `HandSizePrior.note`, in the exported
`hands.sizePrior` block, in the viewer's legend and on the review render: breadth across the
metacarpals 0.049 × stature (Pheasant, *Bodyspace* 2nd ed. Table 2: 87 mm / 1740 mm male,
76 mm / 1610 mm female; NASA RP-1024 vol. II: 90 mm / 1755 mm), palm length 0.058 × stature (hand
length 0.108 H, Drillis & Contini via Winter, × Pheasant's 0.54 palm fraction), taken as an isoceles
triangle about the wrist. `breadthResidual` is the file's own check on it: −20 % median on the phone
session, i.e. −2 to −4 px on a hand about 18 px across — inside the landmark noise.

### 5. What the plates say about these 37 free throws

Median over the shots that have a plate at the release; `n` is how many of the 37 those are, and the
small `n` is the ball-occlusion ceiling of §3, not a filter.

| measure | median | p10 … p90 | n |
|---|---|---|---|
| palm normal to vertical | +117° | +43 … +143 | 4 |
| hand pointing to vertical | +67° | +41 … +71 | 5 |
| roll | +64° | −147 … +91 | 4 |
| wrist flexion at release (+ = flexion) | +57° | −91 … +66 | 4 |
| wrist flexion change, release ± 80 ms | +42° | −165 … +81 | 6 |
| wrist flexion range, release ± 80 ms | 68° | 31 … 155 | 6 |
| palm normal to the rim bearing | nil | — | 0 |
| guide hand's contact plane | nil | — | 0 |

Read it as a coverage result, not a coaching result. Four shots is not a distribution: the p10–p90
spread on the flexion (−91° to +66°) is the spread of *four numbers measured at the edge of what the
detector can see*, and no finding should be built on it until a closer camera raises `n`. The two
nils are structural and each says so in the record: the palm-to-rim angle needs the rim's image
column, which `HandProbe` does not supply offline (the app does); the guide hand's contact plane
needs the **ball track**, which a `BodyShot` does not carry at all (schema §3) — it is computed only
in the pass that has both, i.e. `ShotAnalysisRunner` and `FormClipModel`.

On the 240 fps clip (`03D7D2BF`, release 31.928 file s, hFOV 73.83), where a plate does survive at
the release before the 6 px gate, the same measures read: palm to vertical 118°, palm to the rim
bearing 145°, wrist flexion at release +56°. After the gate that shot's release frame is refused,
which is the correct answer for a hand 17 px across.

### 6. Where it is drawn, and what the screen says

- `App/Sources/SceneBody.swift`: the body player draws the plate as a filled, double-sided triangle at
  the fitted wrist on every frame all three points were confident, translucent when a corner was
  carried across a sampled frame or clamped onto the prior, flat fingers when only two points were
  confident, a mitt when none. The provenance card prints the prior's own sentence and the per-side
  plate coverage.
- `App/Sources/FormScene.swift` / `FormModelView.swift`: the 3-D form viewer draws the same plate from
  the form's own joints (`FormSkeleton.appendagePoints`), with the plate's corners and edges at 0.45 ×
  the usual joint and bone radius — a shoulder-sized sphere at each corner swallows a plate 0.049
  statures across. The legend line names the prior. The 1.2 rig — presets, ghost, callouts, phase
  stops — is untouched.
- The **wrist joins the tap callouts**: `FormSkeleton.angleDefinitions` now carries `leftWrist` /
  `rightWrist` as elbow → wrist → the *midpoint* of the two knuckles (`AngleDefinition.b2`), which is
  the hand's own pointing axis; either knuckle alone sits half a breadth off it, 8–12° of a straight
  hand. It is the unsigned interior angle, so it reads like every other angle in that list; the signed
  flexion/extension lives in `hands.wristFlexionAtRelease`, which needs the palm normal for its sign.

`docs/images/hands-1.3.png` is the review render (side and front, at τ 0.75, shot 7 of the session),
drawn by the offscreen `HandRender` target against verbatim copies of the app's own scene sources.

### 7. Open

- **Coverage at the release instant is detector-limited, not code-limited.** Raising it needs either a
  hand model that tolerates occlusion or a camera close enough that the hand is more than ~20 px
  across. The form-clip path (filmed close) is where this feature will actually pay.
- **The 6 px separation gate is a floor, not a calibration.** It was set from the project's existing
  keypoint-noise figure and checked on two clips; it has not been swept.
- **`breadthResidual` is systematically negative** (−20 % phone, −46 % on the 240 clip above the
  gate). Some of that is foreshortening, which is honest; some may be that the prior's breadth is too
  wide for this shooter. A ruler in frame, or a stated hand breadth, would separate the two.
- **The guide hand's contact plane has never been exercised on real footage**, because no record
  carries a ball track. It runs in the app path; it needs one session analysed end to end to be
  reported.
- `BodyShot` still does not record the clip it came from (`source.clip`), so `HandProbe` has to be
  pointed at a directory by hand.

---

## Feet (2026-09-16) — 1.3 Track C

The shooter now has heel, big toe and little toe per foot. Vision has none of them, so this is a new
detector: **RTMPose-m Halpe-26 converted to Core ML** (`ArcLabFootModel.mlpackage`, 53 MB, FP32),
run on the whole-person crop `BodyTracker` already computes, SimCC-decoded in Swift. Licence and
conversion provenance are in `docs/DECISIONS.md` "Feet detector"; the short version is that it is an
**internal measurement engine**, off by default, and must not ship commercially as it stands.

### The model is the model

Two independent checks that the hand-written re-implementation of RTMPose is really the published
network, since the mm* stack will not install on this toolchain:

| check | result |
|---|---|
| parameter count against the mmpose model zoo | **13.926 M** vs 13.93 M |
| SimCC logits against mmpose's own mmdeploy ONNX (`end2end.onnx`), random input | max abs diff **4.9e-6**; **0.00 px** after decode |
| Core ML (FP32) vs PyTorch, 5 real frames of the 240 fps clip, all 26 keypoints | max **0.00 px** (gate was ≤ 1 px) |
| Core ML (FP16) vs PyTorch, same 5 frames | max **2.5 crop px = 3.6 full-frame px** — rejected, see DECISIONS |
| Mac benchmark, `computeUnits = .all`, 100 predictions | **6.15 ms/frame** FP32, 3.95 ms FP16 |
| end-to-end in `BodyTracker` (crop render + predict), 5 shots × ~228 frames | **11.6–12.6 ms/frame** |

`TrajectoryProbe feetbench <clip> --time <s> [--n 200] [--units all|cpu|cpuAndGPU|cpuAndNeuralEngine]`
isolates the model from the decode (a blank frame of the clip's real size; convolution cost does not
depend on the pixels) and is the command the phone should repeat. On this Mac, 100 predictions each,
an 800 × 1067 person box rendered down to 192 × 256 — the CIContext crop is inside every number,
as it is inside the tracker's:

| compute units | mean | best | worst | model load + compile |
|---|---|---|---|---|
| `.all` | **11.11 ms** | 8.05 | 19.15 | 0.41 s |
| `.cpuAndGPU` | 13.26 ms | 8.41 | 54.09 | 0.76 s |
| `.cpuAndNeuralEngine` | 26.36 ms | 18.69 | 54.25 | 0.51 s |
| `.cpuOnly` | 33.66 ms | 18.52 | 300.86 | 0.59 s |

`.cpuAndNeuralEngine` being *slower* than `.all` is the FP32 model refusing the ANE and falling back
to CPU — which is the measurement that makes the FP16 question real rather than theoretical.

The phone number is not here: the model was converted, verified and benchmarked on the Mac only.
**Open: the iPhone 14 Pro benchmark and the ANE/GPU residency split.** FP32 will not run on the ANE,
so if the phone says FP32 is too slow the trade is FP16 *plus* a stated 3.6 px quantisation term.

### Coverage on the 240 fps clip (5 accepted free throws, `03D7D2BF…mov`, ~228 analysed frames each)

Detection rate, confidence ≥ 0.35, pooled over the shots, within ±50 ms of each phase instant:

| instant | left heel | left big toe | left little toe | right heel | right big toe | right little toe | n frames |
|---|---|---|---|---|---|---|---|
| set | 100 % | 100 % | 100 % | 100 % | 100 % | 100 % | 46 |
| dip | 100 % | 100 % | 100 % | 100 % | 100 % | 100 % | 35 |
| release | 100 % | 100 % | 100 % | 100 % | 100 % | 100 % | 60 |

Whole-window: the detector returned at least one foot landmark on **97–100 %** of analysed frames
(222–229 of 224–229 per shot). Median SimCC confidence per point over the whole window: left heel
0.69, left big toe 0.81, left little toe 0.72, right heel 0.83, right big toe 0.72, right little toe
0.79. **This is the highest phase-instant coverage of anything ArcLab measures** — compare the
release-instant right wrist at 2 of 37 forms — because the feet are the least occluded part of a
shooter and the model sees them from the whole body.

### Toe-pair separation: the number that decides whether roll exists

`docs/research/whole-body-landmarks-2026-09-16.md` §1.1 predicted ~18 px of toe-pair separation at
this framing and warned that roll would be marginal. Measured, 1 126 frames per foot:

| foot | p10 | p25 | median | p75 | p90 | under the 4 px floor |
|---|---|---|---|---|---|---|
| left (near the camera) | 10.1 | 11.5 | **12.1** | 13.4 | 14.2 | **0 %** |
| right (far side) | 3.6 | 3.9 | **4.5** | 5.9 | 10.7 | **32 %** |

So the prediction was right in order of magnitude and pessimistic by ~30 %. The consequence is the
one the research called: **the near foot carries a roll on every frame; the far foot carries one on
about 68 %**, and the rest are refused with the pixel number in the reason rather than reported as
noise. Roll is refused, not estimated, under `FootTriangleOptions.minimumToePairPixels` (4 px).

### The foot angle — the metric that was nil on every shot until today

Shooting-side foot's yaw against the rim bearing at the set, four repeats of the same free throw
(the fifth has no set instant, so it is refused):

| shot (release, file s) | shooting foot | other foot | openness | ±1 px propagated σ | frame-to-frame spread | foot axis in image |
|---|---|---|---|---|---|---|
| 31.928 | −103.8° | −110.8° | 7.0° | ±1.1° | 0.6° | 35 px |
| 105.177 | −103.7° | −104.6° | 1.0° | ±1.2° | 0.8° | 34 px |
| 199.123 | −105.8° | −110.1° | 4.3° | ±1.2° | 0.7° | 34 px |
| 341.795 | −104.4° | −110.5° | 6.1° | ±1.3° | 0.9° | 35 px |
| 274.947 | refused — the body model found no set instant on this shot | | | | | |

**Spread across four repeats: 2.1°, against a per-shot error bar of ±1.2°.** That is a metric that
can carry a coaching claim: a 5° change in stance would be visible above it. Two caveats travel with
every row and are in the value's own provenance string:

- **Rim-bearing parallax 37.6–38.0°.** The angle is measured against the camera's bearing to the
  rim's image column, which equals the shooter→rim bearing only when the shooter stands on the
  camera→rim line. On this clip they do not, and 38° of that number is parallax. It is a constant of
  the setup, so *differences* between these four shots are unaffected; the absolute value is not a
  foot-to-rim angle yet. Closing it needs the rim's 3-D position, which `RimCalibration` already
  produces for the ball path — wiring that into `FootTriangleOptions` is the obvious next step.
- Two σs are published and they mean different things. The **propagated** one (±1.2°) is the whole
  triangle refitted with each landmark moved ±1 px; the **frame-to-frame** one (0.6–0.9°) is
  repeatability over the set window. Read the first.

### What the triangle's *shape* says, and it is not good news

| foot | rigid reprojection RMS | p90 | heel→big-toe residual | toe-span residual |
|---|---|---|---|---|
| left | 15.5–20.0 px | 18.4–24.1 px | +4 % … +11 % | **−40 % … −45 %** |
| right | 14.2–17.6 px | 17.9–21.2 px | +10 % … +12 % | **−33 % … −35 %** |

`reprojectionPixels` is deliberately **not** the reprojection of the placed vertices — those sit on
their own view rays by construction and would read 0.00 px on every frame, which is a tautology. It
is the *prior's own rigid triangle*, rotated onto the placed points about the fitted ankle and
projected back. On a synthetic foot built from the prior it is **< 1 px** (`FootKinematicsTests.
testRigidReprojectionIsNearZeroOnAPriorShapedFoot`), so 15–20 px on real footage is a statement about
the prior, not about the code: **the declared toe-span shape ratio is about 40 % too wide for where
the Halpe annotations actually put the big-toe and little-toe landmarks.** Winter's 0.055 H is foot
*breadth at the metatarsal heads*; the toe-tip landmarks are closer together than the ball of the
foot. The number is consistent across both feet and all five shots, which is what makes it a
calibration and not noise.

**Deliberately not fixed here.** Shrinking the ratio until the residual vanishes would be fitting a
"population prior" to one shooter's footage, which is the thing CLAUDE.md rule 1 exists to prevent.
The measured mismatch is published instead, and the honest reading of the whole track is: **the
foot's yaw is measurable and repeatable to ~1°; the triangle's shape is a declared prior that the
data says is wrong by ~40 % across the toes, so the roll and anything else that depends on the
across-axis should be read with that in mind.**

### The depth ambiguity, and why it had to be resolved by shape

Each vertex's view ray meets its prior sphere twice — once in front of the ankle's depth plane, once
behind — and a single camera cannot tell them apart. The hand triangle resolves this by taking the
smaller depth excursion. **For feet that is wrong often enough to matter** (a foot pointing away from
the camera has its toes genuinely deeper than its ankle), and the first implementation of it gave a
foot angle of −40°, −59°, −67° and −113° on four repeats of the *same* free throw — i.e. it was
choosing a different branch on different shots. `FootTriangleFit.chooseTriangle` now resolves all
three vertices together over the ≤ 8 combinations, scoring each by the rigid triangle's reprojection
**plus its own edge lengths against the prior**, in metres, with a continuity term. Scoring by
reprojection alone was tried and rejected: the rigid triangle is built from the heel and the *mid*-toe,
so splitting the two toes onto opposite branches leaves it unchanged, and that degenerate minimum won
on every frame and reported a **31 cm toe span**. With the edge term the branch is stable and the
four repeats agree to 2.1°.

### Heel-first / toe-first

`FootTriangleFit.strikes` reads the strike order from the heel's and the mid-toe's own **image rows**
at each touchdown, differenced, in stature units — not from fitted depth, for the reason
`FootworkMetrics`' header gives. It is unit-tested both ways. **It is not exercised on this footage:
all five shots are free throws and come back `stationary` with no touchdown before the lift.** It
needs an off-the-dribble or 1-2 clip to be validated on real frames.

### Where the numbers live

`Packages/ShotVideo/Sources/ShotVideo/FootPoseDetector.swift` (model + SimCC decode),
`Packages/ShotGeometry/Sources/ShotGeometry/FootKinematics.swift` (names, prior, triangle fit,
strikes, export record), `FootworkMetrics.footAngleToRim` / `otherFootAngleToRim` / `stanceOpenness`
/ `footStrikes`, `App/Sources/FootPlates.swift` (drawing).
Reproduce with:

```
TrajectoryProbe body <clip> --start s --end e --release-time r --time-scale 1 --every 2 \
    --hfov 73.83 --height 1.83 --hand-focus 0.4 --last-turning-dip --rim-u 545.5 --feet
```

**Packaging correction (2026-09-16, coordinator):** an Xcode app build of the package compiles a `.mlpackage` resource to
the products root and never copies it into `ShotVideo_ShotVideo.bundle`, so the first 1.3 phone build carried no foot
model (21 MB app). The model now ships compiled — `Sources/ShotVideo/Resources/ArcLabFootModel.mlmodelc`, made with
`xcrun coremlc compile Models/ArcLabFootModel.mlpackage` — and the editable source lives in `Packages/ShotVideo/Models/`.
The loader's first branch (a bundled `.mlmodelc`) is the one that runs on every platform now; app 74 MB. Mac feetbench on
the compiled model: 11.8 ms/frame (`all`), load + compile 0.97 s.
