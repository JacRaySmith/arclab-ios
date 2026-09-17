# Decisions and open-question answers

Dated 2026-09-12 unless noted. Evidence for the numbers is in `PHASE1-REPORT.md` and
`reference/sdk-and-licensing-research-2026-09-12.md`.

## Brief §9.1 — Can one 45° camera give full 3D from the ball's pixel diameter?

**Partly. Tested in the Phase 1 simulator (`GeometryHarness`, "Open question 1").** With a 45°
view at 8 m, 240 fps, 1.5 px centroid noise and a per-frame diameter noise of 1 px (a realistic
detector box), a per-frame depth-from-diameter 3D fit locates the ball's rim crossing to a median
1.7 cm laterally (p90 4.9 cm) and 3.8 cm in depth. At 2 px diameter noise: 3.0 cm / 7.4 cm / 6.2 cm.

- Good enough for **left/right deviation classes** (left / centre / right of a 45.7 cm rim) and for
  a coarse lateral number from a single oblique camera.
- Not good enough to replace the shot-plane solve for arc metrics: the plane method recovers
  release angle to 0.2° mean / 0.6° max at 30° yaw, and its depth at the rim to ~1 cm.
- Design consequence: the diameter profile is used as a *shape-only* cue inside the azimuth solve
  (free scale factor, so ball size and detector bias cancel). Absolute depth from diameter stays
  a fallback, flagged low-confidence.

## Brief §9.2 — XcodeGen vs Tuist

**XcodeGen** (MIT, 2.46.0, Jul 2026). Lighter for a single developer with one app target and one
local package; a `project.yml` diff is readable and `.pbxproj` never enters git. Tuist is
heavier and its cadence is aimed at large multi-module workspaces. Install: `brew install xcodegen`.
Confirm with the user before Phase 3 creates the project.

## Brief §9.3 — iOS 26 minimum

**Yes, iOS 26.0.** Apple's June 2026 measurement: iOS 26 on 86% of iPhones ≤ 4 years old and 79% of
all iPhones; TelemetryDeck Sept 2026: 86.6% iOS 26, 7.9% iOS 18. For a launch in early 2027 the
loss is a few percent of reachable devices, and iOS 26 brings `AVAssetReaderOutput.Provider`
(the non-deprecated frame reader) and the current Vision API surface.

## Brief §9.4 — Ball detection options

Options, with licences (verified in the research file):

| Option | Licence | Notes |
|---|---|---|
| Create ML object detector (transfer learning) | Output model is the developer's; Xcode SLA has no clause restricting Create ML output | Base backbone is unpublished but OS-provided. Needs Phase 0 footage labelled. |
| RT-DETR / RF-DETR / YOLOX / DETR fine-tune → Core ML | Apache-2.0 | Viable; more engineering than Create ML; RF-DETR small variants are Core-ML-convertible. |
| Ultralytics YOLO v8/11 | **AGPL-3.0** — excluded | Confirmed incompatible with a closed-source app. |
| YOLO-NAS | Weights non-commercial — excluded | |
| Vision `DetectTrajectoriesRequest` | Built in | Zero-model baseline to evaluate first (needs a stationary camera). |

Datasets: several Roboflow basketball sets are CC BY 4.0 / MIT (re-check each page in a browser
before use); SportsMOT is CC BY-NC 4.0 — not usable. Decision deferred to Phase 2; Vision
trajectory detection is evaluated first, Create ML second.

## Calibration: which rim edge?

The ring is a torus. Detected boundary points trace either the inner edge (0.4572 m) or the outer
edge (≈ 0.489 m with a 15.9 mm tube). Using the wrong one is a 7% scale error, which the g-test
flags (g scales linearly with scale). `RimCalibrationOptions.rimDiameter` must be set to the edge the
detector actually traces; Phase 3 decides after looking at real detections.

## Constants

Rim inner diameter 0.4572 m, rim height 3.048 m, free-throw line to rim centre 4.191 m,
g = 9.81 m/s². Size-7 ball 0.2385 m per the brief (rulebook range 0.2385–0.2426 m, so the ball is
never the primary ruler). Three-point radius by court type in `CourtType` — corners differ and are
not modelled yet.

## Release-instant detection (departure from the textbook)

The textbook's walk-back against a single anchor parabola (Ch 10.3) fails whenever the projected
track bends slowly — which any small shot-plane azimuth error produces. Replaced by a **local
gravity test**: a 0.3 s window slid along the track and fitted with g fixed; hand push (≈30 m/s²)
misfits by ~10 cm, a held ball by ~3 cm, free flight by the noise. Release is then refined below the
frame by fitting the pre-release deviation ramp ½·Δa·(t_r − t)² with a linear trend term. Measured
bias ≈ −1 frame at 240 fps (vs −5 frames for the textbook median rule at 120 fps).

## Feet detector: Halpe-26 internally, not in a shipped build (2026-09-16)

**Decision.** ArcLab measures the feet with **RTMPose-m Halpe-26**, converted to Core ML and bundled
as `Packages/ShotVideo/Models/ArcLabFootModel.mlpackage` (source) and shipped compiled as
`Sources/ShotVideo/Resources/ArcLabFootModel.mlmodelc`. It is used for
**internal measurement and for labelling** — it is the only thing that gives heel, big toe and little
toe per foot, and Vision gives none of them. It is **off by default** (`BodyTracker.Options.detectFeet
= false`, `TrajectoryProbe body --feet` turns it on) and **must not ship in a commercial build** until
one of the following is true:

1. a commercial licence is bought from the annotation owners (COCO-WholeBody's README names a
   SenseTime contact; AlphaPose/Halpe would need its own), or
2. it is replaced by a **custom foot-crop keypoint model trained on the user's own labelled frames**
   — the licence-clean path recommended by `docs/research/whole-body-landmarks-2026-09-16.md` §6 #7,
   for which this model is the weak labeller, or
3. it is replaced by MediaPipe BlazePose (Apache-2.0), which gives heel + one foot index per foot:
   enough for the foot's *pointing direction*, not enough for a triangle or a roll.

**Why the restriction exists.** The mmpose *code* and the published *weights* sit under Apache-2.0,
but the weights exist only because of annotations that do not: AlphaPose's LICENSE headline is
"ACADEMIC OR NON-PROFIT ORGANIZATION NONCOMMERCIAL RESEARCH USE ONLY", Halpe's own repo carries no
LICENSE at all, and COCO-WholeBody's terms say "ONLY for research and non-commercial use". Whether a
weight file inherits its training data's terms is genuinely unsettled; the point of writing it down
is that shipping it would be a decision taken deliberately, not one taken by default.

**Source and provenance of the artefact.**
- Checkpoint: `rtmpose-m_simcc-body7_pt-body7-halpe26_700e-256x192-4d3e73dd_20230605.pth`
  (download.openmmlab.com, 55.9 MB), 26 keypoints, ids 20–25 are `left/right_big_toe`,
  `left/right_small_toe`, `left/right_heel`.
- Conversion: **no ONNX front end exists in coremltools**, so the path is PyTorch → `torch.jit.trace`
  → coremltools. mmcv/mmdet/mmpose do not install on this toolchain, so the architecture was
  **re-implemented minimally** from the checkpoint's own `meta['cfg']`
  (`<scratchpad>/feet/rtmpose_min.py`, ~250 lines: CSPNeXt-P5 d0.67/w0.75 + RTMCC/SimCC head) and
  loaded strict. Two independent checks that the re-implementation is the real model: it has
  **13.926 M parameters** against the model zoo's 13.93 M, and it agrees with mmpose's **own published
  mmdeploy ONNX** to **4.9e-6** max absolute difference on the SimCC logits (0.00 px after decode).
- Precision: **FLOAT32**, 53 MB. FLOAT16 (27 MB) was built and measured and **rejected for now**: it
  moves keypoints by up to **2.5 crop px (3.6 full-frame px)** against PyTorch, because the SimCC
  argmax flips between near-equal bins. Mixed precision (FP32 matmuls, FP16 convolutions) made no
  difference, so the error is in the convolution stack, not the head. FP32 reproduces PyTorch to
  **0.00 px on all 26 keypoints over 5 frames** of the 240 fps clip. Cost: 6.15 ms/frame against
  3.95 ms on this Mac with `.all`, and FP32 will not run on the ANE — so if the phone benchmark says
  FP32 is too slow there, the trade to make is FP16 **plus a stated 3.6 px quantisation term**, not a
  silent swap.
- Packaging (superseded 2026-09-16: the model ships compiled as an `.mlmodelc` folder because an Xcode app build never copies a `.mlpackage` into the resource bundle): `.mlpackage` had to be `.copy`d, not `.process`ed, in `Package.swift` — `.process`
  descends into the package and asks `coremlc` to compile the inner `model.mlmodel`, which the
  SwiftPM build sandbox denies read access to `weights/weight.bin`. `FootPoseDetector` compiles the
  copied package once into the caches directory, exactly as `CoreMLBallDetector` does for the ball.
- Class name: `ArcLabFootModel`, chosen so the Swift class an Xcode build generates from the file
  name cannot collide with `ArcLabBallModel` or with any type in `ShotVideo`.
