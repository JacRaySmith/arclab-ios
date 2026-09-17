# Whole-body landmarks: feet, hands, 3-D lifting, body models (research, 2026-09-16)

Track A of `docs/PLAN-1.3-2026-09-16.md`. Question: what can ArcLab put on an iPhone 14 Pro, today, to get
**heel + big toe + little toe per foot** (and richer hands), what a monocular 3-D lifter or a parametric body
would actually buy, and how to prove "it tracks the whole real movement" without a mocap lab.

**Method.** The session's WebSearch budget was already spent, so everything below is a *primary* source read
directly: GitHub REST (`gh api`) for licences and repo state, `raw.githubusercontent.com` for READMEs, model
zoo tables, dataset terms and LICENSE files, the Hugging Face model API, and the coremltools converter source.
Two figures are marked **my estimate** (arithmetic I did here); everything I could not confirm is **UNVERIFIED**.
Not repeated here: `docs/research/detection-and-capture-tech-2026-09-13.md` §7 (Apple 3-D pose, ARKit-vs-Vicon
error, MediaPipe/pitchAI/OpenCap validation numbers, the 200 px/m framing estimate) and
`docs/research/arkit-body-tracking-spike-2026-09-15.md` (ARKit joints, no heels, camera exclusivity).

---

## 0. Recommendation in one paragraph

Ship the feet from an **RTMPose Halpe-26 model converted to Core ML** — Halpe-26 is the 17 COCO joints plus
head/neck/hip plus exactly the six points ArcLab wants (`left/right_big_toe`, `left/right_small_toe`,
`left/right_heel`), and RTMPose-m at 256x192 is 13.9 M params / 1.95 GFLOPs, an order of magnitude cheaper than
a 133-keypoint whole-body model. **But the licence chain is the blocker, not the compute**: Halpe comes from
AlphaPose (non-commercial research licence) and COCO-WholeBody's annotations are explicitly research/
non-commercial. So: use the Halpe-26 model **now, in the internal build, as the labelling and validation
engine**, and treat the shipping detector as either (a) a commercial licence bought from the annotation owners,
or (b) a small **foot-crop keypoint model trained on the user's own hand-labelled footage** — which is clean,
cheap at this scale, and is the fallback that does not depend on anyone's terms. MediaPipe BlazePose (Apache-2.0)
is the licence-clean stopgap but gives only heel + foot-index: enough for foot *pointing*, not for foot *roll*.
Hands stay on Vision. A learned 3-D lifter is not worth it (licences encumbered, trained on walking/sitting data,
no Core ML port exists); the same benefit comes from priors ArcLab can write itself. For a "recognisable you"
mesh the only commercially safe parametric bodies found are **ANNY (Apache-2.0, NAVER)** and **MHR (Apache-2.0,
Meta)** — the whole SMPL family, SKEL, SUPR, MANO and Sapiens are non-commercial.

---

## 1. Feet on device

### 1.1 What the triangle needs, in pixels

Foot triangle = heel, big toe, little toe. Using the prior doc's framing estimate (~200 px/m at 7 m, 1080p):
a 26 cm foot is ~52 px long and the big-toe-to-little-toe width (~9 cm) is ~**18 px** in the full frame
(**my estimate**). A top-down pose model resizes the *person* box to 256x192, i.e. a 1.9 m player (~380 px)
becomes ~256 px: scale 0.67, so in-model the foot is ~35 px long and ~12 px wide (**my estimate**). RTMPose's
SimCC head with `split_ratio = 2.0` bins the 192 px width into 384 bins, so *quantisation* is 0.5 px and is not
the limit — the limit is model/annotation error, typically 2-4 px on small extremities. Consequence, stated
plainly: **foot pointing direction is measurable at this framing; foot roll from the triangle will be noisy**
and should carry a wide uncertainty or be nil at long range. Closer filming (4-5 m) roughly doubles the margin.

### 1.2 Options

| Option | Keypoints that matter | Licence (code / weights / training data) | Size & cost | Fits ANE budget? | Confidence |
|---|---|---|---|---|---|
| **RTMPose Halpe-26** (mmpose `body8-halpe26`) | 26 incl. `big_toe`, `small_toe`, `heel` L/R (verified in `configs/_base_/datasets/halpe26.py`, ids 20-25) | Code Apache-2.0 (mmpose); **training data Halpe → AlphaPose "ACADEMIC OR NON-PROFIT ORGANIZATION NONCOMMERCIAL RESEARCH USE ONLY"** | m/256x192: 13.93 M, 1.95 GFLOPs; s: 5.70 M, 0.70 G; l/384x288: 28.24 M, 9.40 G | Yes with room (see 1.4) | High on the numbers, high on the licence text |
| **RTMPose-WholeBody / DWPose (distilled) 133 kp** | 133 incl. 6 foot + 21x2 hand | Code Apache-2.0 (mmpose, DWPose); **COCO-WholeBody annotations "ONLY for research and non-commercial use", owned by SenseTime, commercial contact given** | m/256x192: 2.22 GFLOPs, whole AP 60.6 (DWPose-distilled); l/384x288 10.07 G, AP 66.5 | Yes at 256x192 | High |
| **RTMW (cocktail14)** | 133, best whole-body AP | Apache-2.0 code; trained on 14 datasets incl. COCO-WholeBody/UBody → same encumbrance | RTMW-l 384x288: 17.7 GFLOPs, 70.1 AP; RTMW-m 256x192: 4.3 G, 58.2 AP | -l/384 is heavy; -m is fine | High |
| **Sapiens (Meta), 308 keypoints incl. feet** | 308 | **CC BY-NC 4.0** (LICENSE read directly) — not usable commercially | ViT 0.3B-2B; even 0.3B is far above the budget | No | High |
| **ViTPose / ViTPose+ (whole-body variants)** | 133 | Apache-2.0 code; whole-body weights trained on COCO-WholeBody → encumbered | ViT-B+ is ~86 M params, transformer | Marginal at best | Medium (weights' data provenance inferred from configs) |
| **YOLOv8-pose** | 17 COCO, **no feet** | AGPL-3.0 (Ultralytics) — also a copyleft problem for a closed app | small | n/a | High |
| **BlazePose GHUM / MediaPipe Pose Landmarker** | 33 incl. `left/right heel` (29,30) and `left/right foot index` (31,32) — **heel + one toe, no second toe → no triangle, no roll** | Apache-2.0 (mediapipe repo) | landmarker input 256x256, detector 224x224, float16; Google publishes no size/latency on the guide page | Yes | High on landmark list, medium on weights' licence (guide page does not state a model licence explicitly) |
| **Apple Vision** | 19 body joints, ankle is the lowest | Platform | free | yes | High |
| **ARKit body tracking** | has `*_toes_joint` but **one toe per foot and no heel**, plus it owns the camera (no 240 fps) | Platform | free | n/a | High (from the 2026-09-15 spike) |
| **Custom foot-crop keypoint model** on the shooter's own footage | exactly 3 per foot, at crop resolution | Owned outright — the only fully clean path | ~1-3 M params at 128x128 | Yes, trivially | Medium (needs the labelling effort below) |

**Licence reading, verbatim where it matters.** COCO-WholeBody's README §Terms of Use: "COCO-WholeBody dataset is
**ONLY** for research and non-commercial use. The annotations ... belong to SenseTime Research"; it names a
contact for commercial usage. AlphaPose's LICENSE headline: "ACADEMIC OR NON-PROFIT ORGANIZATION NONCOMMERCIAL
RESEARCH USE ONLY". Halpe's own repo carries no LICENSE file at all. The *model weights* published by mmpose sit
under the repo's Apache-2.0, and there is a real argument that weights are not the annotations — but a weight
file whose only reason to exist is those annotations is exactly the case that is unsettled. **This is a
"decide it explicitly and write it down" item, not a thing to ship by default** (confidence: high that the
restriction exists; low that anyone can tell you how a court would see the weights).

### 1.3 Conversion to Core ML: is it known to work?

- **coremltools has no ONNX front end.** Read directly from `coremltools/converters/_converters_entry.py`: the
  accepted inputs are TorchScript objects/`.pt`/`.pth` **or** a `torch.export` `ExportedProgram`; the README
  lists TensorFlow 1/2 and PyTorch only. So the rtmlib/mmdeploy ONNX files are *not* a conversion source —
  you convert from the `.pth` through mmpose's model class (trace or `torch.export`), or you round-trip
  ONNX→PyTorch, which is the fragile path. (Confidence: high.)
- **No published Core ML RTMPose exists.** Hugging Face search for `rtmpose` returns LiteRT, ExecuTorch, QNN,
  ONNX and Ambarella/AXERA ports — **no Core ML**. `Kinetix-ML/rtmlib-coreml` (Apache-2.0, last pushed
  2024-08-22) is a fork of rtmlib whose only Core ML artefact is a single `rtmo_demo_coreml.py`; it is not a
  converted whole-body model. So: budget for doing the conversion, not for downloading one.
- **What has to survive the conversion**: CSPNeXt backbone (plain convs — ANE-friendly), then RTMPose's SimCC
  head = a small self-attention/GAU block plus two large `Linear` layers producing 1-D coordinate
  classifications for x and y (`K x W*split` and `K x H*split`). Everything in that list has a Core ML op;
  the risks are (i) the GAU's einsum/reshape patterns falling back off the ANE, (ii) mmpose's `forward` not
  being traceable without the mm* stack installed, (iii) output layout. **Post-processing is genuinely easy**:
  argmax over each 1-D vector ÷ split ratio → (x, y) in crop pixels, and the max value is the confidence.
  No heatmap Gaussian decode, no NMS (top-down, one person). Do the argmax in Swift, not in the model.
- **Evidence the architecture maps to a mobile NPU**: Qualcomm's AI Hub publishes `RTMPose-Body2d` (256x192,
  17.9 M params, 68.5 MB float, 133 joints) at **1.1-3.7 ms on Snapdragon 8-series NPUs** (1.386 ms on 8 Gen 3,
  3.659 ms on 8 Gen 1), w8a16 similar. mmpose's own table gives ncnn FP16 on a Snapdragon 865 CPU/GPU:
  RTMPose-t 9.02 ms, -s 13.89 ms, -m 26.44 ms, -l 45.37 ms at 256x192.

### 1.4 Expected speed on an iPhone 14 Pro (A16, 16-core ANE)

No published Core ML/ANE number for any RTMPose model exists (**UNVERIFIED** — this is the gap the benchmark
below closes). Bracketing it: the Snapdragon 8 Gen 1/8 Gen 3 NPUs run the 133-kp 256x192 model in 1.4-3.7 ms,
and the A16's ANE is in that class; ArcLab's own measured Vision costs on an M-series Mac are 9-12 ms/frame for
2-D body, 6.5-19 ms for 3-D body and ~3 ms for the hand request on a 256 px crop (`docs/PHASE2-PREP.md`,
`docs/HANDOFF.md`). **My estimate: RTMPose-m Halpe-26 at 256x192 should land at 3-8 ms/frame on the ANE, and
RTMPose-s under 3 ms** — comfortably inside a 30 ms/frame budget, and small enough to sit alongside the existing
three requests. Treat this as a hypothesis with a cheap test: convert RTMPose-s and -m, run 200 frames on the
phone with `computeUnits = .all`, log ms/frame and the ANE/GPU split, and only then choose the size.
Fallback if the GAU head will not stay on the ANE: RTMPose-t/s, or 192x256 → 128x160 input.

### 1.5 Integration shape for ShotVideo

`BodyTracker.run` already does exactly the right thing structurally: one decode pass, a `Cropper` per crop size
(the body crop and the 256 px hand crop each own one — sharing one cost 10.3 s vs 5.9 s per window), Vision
requests on the crop, results mapped back to full-frame pixels via `toImageCoordinates(...) + origin`. And
`CoreMLBallDetector.swift` already carries the Core ML loading pattern (`MLModelConfiguration.computeUnits =
.all`, a bundled `.mlmodelc` with a cache fallback). A foot request is the two joined together:

1. **Third cropper, seeded from the previous analysed frame's 2-D knees/ankles** — the same `lastPoints2D`
   trick the hand crop uses, which at 240 fps is 8 ms of travel.
2. **Two candidate geometries, and they should be measured against each other, not assumed**:
   - *(a) whole-person crop, native format.* Run the Halpe-26 model exactly as trained (person box → 256x192).
     Zero domain shift, one extra pass, feet at ~12 px toe-width in-model (§1.1). This is the honest default
     for an off-the-shelf model: **a top-down model fed a below-knee crop is out of distribution and will
     produce confident nonsense** — feet are located partly from where the body is.
   - *(b) below-knee crop at high magnification* — only for a **model trained that way** (the custom option).
     A 128x128 crop around the two ankles gives ~4x the effective foot resolution, which is what roll needs.
3. **Provenance, per CLAUDE.md**: each foot point carries source (`rtmpose.halpe26` / `custom.footcrop` /
   `vision.ankle`) and the SimCC max as confidence; below the gate the point is *absent with a reason*
   (`footLandmarkUnavailableReason: "detectorConfidence 0.21 < 0.5"`), never interpolated.
4. **Feed BodyKinematics** a rigid foot-triangle prior (heel→big-toe ~19 cm, heel→little-toe ~17 cm, toe-width
   ~9 cm, scaled by the fitted stature) so the three 2-D points lift to a plane with one unknown roll angle.

**Recommended path:** RTMPose Halpe-26 (m at 256x192, whole-person crop) converted via `torch.export` →
coremltools, used immediately for internal measurement and to generate weak labels; a **custom foot-crop
model on the user's own labelled frames** as the shipping path and the licence-clean fallback; MediaPipe
BlazePose (heel + foot index, Apache-2.0) as the degraded stopgap if neither lands — pointing only, roll nil.

---

## 2. Hands

**Nothing on device beats Vision's hand pose for this job today, and the current gap is not the model.**

- Vision already gives 21 2-D landmarks/hand and `BodyTracker` already runs it on a 256 px wrist-anchored crop
  for ~3 ms/frame. The triangle the plan wants (wrist, index MCP, little MCP) is available *now*.
- **COCO-WholeBody hands** (inside RTMPose-WholeBody/DWPose/RTMW) would add: the hand points in the *same* pass,
  the *same* person and the *same* coordinate frame as the body — no separate hand detector to fail, no crop to
  place, and left/right assignment that cannot disagree with the body. That consistency is the real argument,
  not accuracy. It comes with the non-commercial annotation licence of §1.2.
- Dedicated hand models: `RTMPose-m hand` (COCO-WholeBody-Hand, 2.58 GFLOPs, PCK@0.2 81.5) — same licence
  chain. **HaMeR** is MIT-licensed *code* but depends on the MANO hand model (non-commercial). **WiLoR** is
  **CC BY-NC-ND 4.0** — no commercial use and no derivatives. MediaPipe Hand Landmarker is Apache-2.0 and 21
  points, i.e. no better than Vision but portable.
- **Motion blur and ball occlusion are exposure and pipeline problems.** At 240 fps the shutter is short enough
  that blur is modest; what kills the release frame is (i) the ball covering the hand, (ii) confidence gating,
  (iii) crop placement one frame stale. The 1.3 plan's own finding — only 2 of 37 free-throw forms carry the
  right wrist at the release instant — should be diagnosed in the pipeline (log why each frame dropped: no hand
  observation / below gate / crop miss / chirality flip) before anyone changes detector. A different model
  will not fix a crop that is in the wrong place.

---

## 3. Monocular 3-D lifting, and the honest alternative

| Lifter | Code licence | Training-data encumbrance | Size | Core ML port? |
|---|---|---|---|---|
| VideoPose3D (Meta) | **CC BY-NC 4.0** (LICENSE read) | Human3.6M (academic-only) | small TCN | none found |
| MotionBERT | Apache-2.0 | checkpoints are H36M(-SH) trained; 17 joints, ≤243 frames | DSTformer, ~1-2 M-class | none found |
| MotionAGFormer | Apache-2.0 | H36M / MPI-INF-3DHP checkpoints | XS 2.2 M / 1.0 GMACs (27 f) … L 19 M / 78.3 GMACs (243 f) | none found |
| PoseFormerV2 | MIT | H36M | small | none found |

Three things follow.

1. **Licence is again about the data, not the code.** Human3.6M's terms are academic-use; MPI-INF-3DHP likewise.
   A shipped lifter trained on them carries the same unsettled question as §1.2 (confidence: high that the
   dataset terms are academic; medium that this transfers to weights).
2. **The domain is wrong.** These models are trained overwhelmingly on H36M-style indoor walking, sitting,
   phoning and gesturing. A jump shot — arms fully overhead, occluded wrist, feet leaving the ground, a side-on
   camera — is out of distribution in exactly the phases ArcLab measures. A lifter will happily return a
   smooth, plausible, *wrong* elbow depth, which is the single failure mode CLAUDE.md forbids.
3. **What a lifter actually provides, ArcLab can provide itself.** The useful content of a temporal lifter is
   three priors: constant bone lengths, temporal smoothness (limited joint acceleration), and left/right
   symmetry of segment lengths. ArcLab's own skeleton fit can impose all three directly as constraints with
   stated units and residuals — no licence, no black box, and the residual is reportable. **Recommendation: do
   not add a learned lifter. Add the priors to the fit and report the depth ambiguity honestly** (a side-on
   single camera cannot resolve rotation about the camera axis of a limb pointing at the camera; that is
   geometry, not a model deficiency).

**Two-view capture is the honest way to get depth.** What the app would need, in order of difficulty:
(1) a second device — a second iPhone, or an iPad; (2) **time sync**: iOS has no cross-device capture-clock API,
so sync must come from a shared event in both videos — the ball's release frame, a clap, or a screen flash —
giving sub-frame alignment only if both run high frame rates (at 240 fps one frame is 4.2 ms); (3) **extrinsics**,
and here ArcLab is unusually lucky: **both cameras already see the rim, and the rim is already a metric
calibration target** (`RimCalibration`), so the two views can be registered through the shared rim circle and
backboard rectangle with no checkerboard and no user calibration dance; (4) transfer/pairing UX (AirDrop of the
second clip, or MultipeerConnectivity). Expected gain, from the numbers in the prior doc: multi-camera
Pose2Sim reaches 3-4° joint-angle error vs 12-18° for good single-camera systems. A ~1.5-2 m baseline at 90°
to the shooting plane would convert the worst axis (depth) into a measured one. Effort: **L** and it changes the
product (two phones), so it belongs behind a "advanced capture" flag, not in the default path. Note the
tempting shortcut does not work: the iPhone 14 Pro's own multi-camera stereo baseline is ~1-2 cm, which at 7 m
gives depth uncertainty of metres (**my estimate**) — useless here.

---

## 4. Mesh / parametric body, for a "recognisable you"

| Model | Licence | Commercial? | Notes |
|---|---|---|---|
| SMPL / SMPL-X / SMPL-H / MANO | MPI "non-commercial scientific research purposes" | **No** | Confirmed indirectly and repeatedly: SKEL and SUPR ship the identical MPI text, and ANNY's README flags its SMPL-X-topology assets as "non-commercial use only" |
| SKEL (biomechanical skeleton inside SMPL) | MPI non-commercial (LICENSE.txt read) | **No** | Anatomical joints — attractive for coaching, unusable commercially |
| SUPR | MPI non-commercial (LICENSE read) | **No** | |
| GHUM/GHUML (Google) | model not publicly released; BlazePose's *landmarks* are Apache-2.0 via mediapipe | n/a | You get landmarks, not the mesh |
| Sapiens (Meta) | **CC BY-NC 4.0** | **No** | Also far too large for the ANE |
| **ANNY (NAVER Labs, 2025)** | **Apache-2.0** (LICENSE read) | **Yes** | Differentiable PyTorch body mesh, one topology across ages, *interpretable* high-level `phenotype` shape params in [0,1] plus a skeletal rig; caveat read in the README: the default install "may download non-commercial only assets when needed" (the SMPL-X topology) — pin the Apache-licensed assets only |
| **MHR — Momentum Human Rig (Meta, `facebookresearch/MHR`)** | **Apache-2.0** | **Yes** | Anatomically-inspired parametric full-body model: 45 identity params, 204 pose params, 72 expression; ships a **TorchScript `mhr_model.pt`**, which is directly convertible by coremltools. Companion `facebookincubator/momentum` (MIT) has the IK/solver machinery |
| Home-grown low-parameter body | yours | Yes | Capsules/lofted segments driven by the fitted bone lengths — what ArcLab draws today |

**What "a recognisable you" actually needs** (in the order it pays off): correct **segment proportions** from
the person's own fit (stature, shoulder width, arm and leg lengths) — this is most of the recognition;
**consistent limb thickness** so the silhouette is a body and not a stick; **head orientation and gaze/facing**
(already improved in 1.2, and the reason the user noticed); **hand and foot plates with the right pointing and
roll** — which is precisely what 1.3 adds and what makes a shot read as *this* person's shot; **ground contact
and a shadow**, because a body that floats never looks real; and only then surface detail. Skin texture, face
identity and a scanned mesh are the *last* 5 % and the biggest cost. Recommendation: keep the home-grown body
for 1.3, and if a mesh is wanted later, prototype **MHR** (TorchScript → Core ML, Apache-2.0) with its
identity params fitted to the measured segment lengths, not to pixels.

---

## 5. Proving "it tracks the whole real movement" without a mocap lab

Five measurements, all computable from footage ArcLab already has (110 phone shots + the 240 fps clip), each
reported per joint and per phase instant:

1. **Reprojection error per joint.** Project the fitted 3-D skeleton back into the image and measure the
   distance to the detected 2-D point, in **px and in shoulder-widths** (scale-free, comparable across
   distances). Report median and 90th percentile per joint. This is the only number that directly answers
   "does the 3-D model agree with what the camera saw". Beware the tautology: joints the fit was driven by will
   look good, so report **held-out** joints too (fit without the foot points, then reproject them).
2. **Left/right bone symmetry and bone-length constancy.** For every frame, |left - right| segment length and
   the SD of each segment length over the shot. A body whose femur changes length by 8 % through the motion is
   not tracking the movement, and no ground truth is needed to say so. Publish a pass line (**suggested: SD
   ≤ 3 % of segment length, L-R difference ≤ 4 %** — set from the data, then frozen).
3. **Phase-instant coverage.** The percentage of shots for which each required joint exists at each phase
   instant (set, dip, lift, release, landing). This is the metric that already exposed "2 of 37 forms carry the
   right wrist at release". Coverage *is* the honesty metric — it turns "we cannot see it" into a number.
4. **Test-retest on repeated free throws.** Within one session, N ≥ 20 free throws (the closest thing to a
   repeated identical movement): report the within-athlete SD and an ICC per metric (foot angle, wrist snap,
   elbow angle at release). A metric whose test-retest SD exceeds the between-athlete or between-condition
   difference it is meant to show is not ready to be coached on. This is the ArcLab-native version of accuracy:
   it measures *repeatability*, which is what the variance thesis needs anyway.
5. **A small hand-labelled set from the user's own footage.** Sizing it: **~150-200 frames total** — 5 phase
   instants x 6-8 shots x 4-5 camera/distance conditions — labelled for **12 joints per frame**: wrist, index
   MCP, little MCP (shooting hand), elbow, shoulder, hip, knee, ankle, heel, big toe, little toe, and the nose
   (as a head-orientation check). That is ~2 000 clicks, roughly 2-3 hours with a decent labelling harness, and
   it is also the seed training set for the custom foot model. **Label 20 of those frames twice, days apart**,
   to establish the intra-rater noise floor — no model should be judged below it, and reporting "the human
   labeller repeats to 2.4 px" is what makes the rest of the numbers credible.

Support these with what already exists: the synthetic clip generator (known ground truth for the fit's
mathematics) and the existing reprojection plumbing. Publish all of it as a `docs/PHASE<N>-REPORT.md` table,
and state the distance and view class for every row — a single number averaged over 7 m and 4 m footage hides
exactly the effect §1.1 predicts.

---

## 6. Ranked recommendations for this build

| # | Item | Effort | Risk | Why now |
|---|---|---|---|---|
| 1 | **Diagnose the release-frame hand coverage (2/37)** with per-frame drop reasons (no observation / below gate / crop miss / chirality), then fix the crop or gate | **S** | Low | Hands are already measurable; this is the cheapest gain in the whole plan and it must precede any hand-model shopping |
| 2 | **Hand triangles from Vision** (wrist, index MCP, little MCP) into the fit, export and drawing, with the rigid hand-size prior declared | **S-M** | Low | Track B; no new dependency, no licence question |
| 3 | **Convert RTMPose-s and -m Halpe-26 to Core ML** (`torch.export` → coremltools) and benchmark ms/frame + ANE residency on the phone over 200 frames | **M** | Medium (GAU head may not stay on the ANE) | Decides §1.4's open number; everything about feet depends on it. Internal build only |
| 4 | **Foot triangle into BodyKinematics + FootworkMetrics** (rigid foot prior, real foot angle vs rim bearing, heel/toe contact order) behind a provenance flag, validated by reprojection on the 110 shots | **M** | Medium | The actual 1.3 deliverable for feet; makes two currently-nil metrics real |
| 5 | **Hand-label 150-200 frames** (12 joints) from the user's footage; double-label 20 | **M** | Low | Serves evaluation (§5.5) *and* is the training set for #7; do it once, use it twice |
| 6 | **Evaluation harness**: reprojection per joint (px + shoulder-widths, held-out), bone symmetry/constancy, phase-instant coverage, free-throw test-retest | **M** | Low | This is what lets the build claim "tracks the whole real movement" without overclaiming |
| 7 | **Custom foot-crop keypoint model** trained on #5's labels (weak labels from #3 where confident), 128x128, ~1-3 M params | **M-L** | Medium (small dataset; mitigate with heavy augmentation and by restricting to this user's framing) | The licence-clean shipping path, and higher foot resolution than any person-crop model |
| 8 | **Bone-length + smoothness + symmetry priors in the skeleton fit**, with residuals reported | **S-M** | Low | Buys most of what a learned 3-D lifter would, with none of the licence or domain risk |
| 9 | **Written licence decision** in `docs/DECISIONS.md`: what may ship, what is internal-only, whether to contact SenseTime/AlphaPose for commercial terms | **S** | Low | The blocker in §1 is legal, not technical; leaving it implicit is the real risk |
| 10 | **Defer**: learned 3-D lifter (§3), Sapiens/SMPL/SKEL/SUPR anything (§4), two-phone stereo capture (§3), mesh rendering via MHR/ANNY (§4) | — | — | Each is either non-commercial, out of domain, or a product change rather than a tracking improvement. MHR is the one to prototype first if a mesh is ever wanted |

---

## Sources

Read directly, 2026-09-16: mmpose RTMPose model zoo and `configs/_base_/datasets/halpe26.py`
(github.com/open-mmlab/mmpose, Apache-2.0); COCO-WholeBody README Terms of Use (github.com/jin-s13/COCO-WholeBody);
AlphaPose LICENSE (github.com/MVIG-SJTU/AlphaPose); Halpe-FullBody README (github.com/Fang-Haoshu/Halpe-FullBody);
DWPose (github.com/IDEA-Research/DWPose, Apache-2.0); rtmlib and Kinetix-ML/rtmlib-coreml (Apache-2.0);
qualcomm/RTMPose-Body2d model card (huggingface.co); Hugging Face model search for `rtmpose` / `coreml pose`;
apple/coremltools `converters/_converters_entry.py` and README (BSD-3-Clause); MediaPipe Pose Landmarker guide
(developers.google.com/edge/mediapipe/solutions/vision/pose_landmarker) and github.com/google-ai-edge/mediapipe
(Apache-2.0); facebookresearch/sapiens LICENSE (CC BY-NC 4.0); facebookresearch/VideoPose3D LICENSE (CC BY-NC 4.0);
Walter0807/MotionBERT (Apache-2.0); TaatiTeam/MotionAGFormer (Apache-2.0); QitaoZhao/PoseFormerV2 (MIT);
geopavlakos/hamer (MIT); rolpotamias/WiLoR license.txt (CC BY-NC-ND 4.0); MarilynKeller/SKEL LICENSE.txt and
ahmedosman/SUPR LICENSE (MPI non-commercial); naver/anny LICENSE + README (Apache-2.0);
facebookresearch/MHR README (Apache-2.0); facebookincubator/momentum (MIT).
In-repo: `Packages/ShotVideo/Sources/ShotVideo/BodyTracker.swift`, `CoreMLBallDetector.swift`,
`docs/PHASE2-PREP.md`, `docs/HANDOFF.md`.
