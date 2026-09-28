# Platform and detector research, 2026-09-27

What the 2026 Apple platforms and the ball-tracking literature actually offer ArcLab's two ceilings —
**recall** (57–65 % of real shots accepted; precision 100 %) and **battery** (Vision body pose, median
12.0 s a shot). Supersedes the date-stamped parts of
`docs/reference/sdk-and-licensing-research-2026-09-12.md`; that file's API names and licence work stand.

Every claim is marked **VERIFIED** (an authoritative page or paper PDF was read) or **UNVERIFIED**
(secondhand, inferred, or arithmetic). Where a number is my own arithmetic on ArcLab's geometry it
says so.

**The headline: nothing Apple shipped in iOS 26 or 27 addresses either ceiling.** Vision's pose,
tracking and trajectory surface has not advanced since iOS 18 — no new revisions, and no WWDC session
on any of it in either 2025 or 2026. Both ceilings are ours to fix.

---

## 1. The diameter estimator is the single highest-value line in the repo

`Packages/ShotVideo/Sources/ShotVideo/CoreMLBallDetector.swift:125`

```swift
diameterPx: 0.5 * (b.w + b.h) * side,
```

The ball's diameter is the **arithmetic mean of a bounding box's width and height**, and `w`/`h` are
then discarded. Two independent problems:

- **Depth error is diameter error, one for one.** `z = f·D/d`, so `dz/z = −dd/d` exactly, unattenuated.
  The 58 % implied-diameter drift recorded in `BIG-CHANGES.md` B11 *is* a depth sweep of roughly
  4.4 m → 7.0 m along a single arc. (Arithmetic, from ArcLab's own geometry.)
- **Motion blur grows the box along the motion axis only**, so the mean is contaminated by half the
  streak and the contamination scales with instantaneous speed — largest just after release and
  approaching the rim, near zero at apex. That is a drift of the right shape in the right place.
  Estimated at **+12 % at 120 fps and +6 % at 240 fps** for a 7 m/s ball at 7 m (arithmetic).

Measured against the corpus on 2026-09-27 (`docs/EXPERIMENTS.md`), blur explains ~1.7 % of the
variance observationally — a lower bound, since that regression's speed term is correlated with the
real depth trend. **`SyntheticClip.swift` already has `exposureFraction`**, so rendering one arc at
1.0 and at 0.0 and measuring the drift is a controlled experiment that needs no new code.

Cheap fixes, both one line in the pure-geometry layer: use **`min(w, h)`** (the across-motion axis is
unsmeared), or subtract a streak term predicted from the parabola's own velocity.

### What the literature says the ceiling is

**Van Zandycke & De Vleeschouwer, "Ball 3D Localization From A Single Calibrated Image", CVPRW 2022**
([arXiv:2204.00003](https://arxiv.org/abs/2204.00003), VERIFIED — PDF read). A small CNN on a 64×64
patch regresses ball diameter in pixels. On identical detections:

| estimator | diameter MAE | 3-D MAE |
|---|---|---|
| Hough circle transform on the heatmap | 4.9 ± 0.8 px | 6.3 ± 1.0 m |
| **learned CNN diameter regression** | **1.6 ± 0.1 px** | **2.3 ± 0.2 m** |

Trained on 14–37 px balls, re-validated at 7–19 px. **ArcLab's ball is ~48–64 px, above their whole
training range**, so 1.6 px MAE (≈3.3 %, ≈23 cm at 7 m) is a conservative bound. Human annotator error
is itself ≈2 px. **Do not build a Hough-circle post-pass — it is measured 3× worse.**

Their own stated gap is exactly B11's idea: they use a constant-size/ballistic constraint only as an
*offline annotation denoiser*, and say temporal regularisation "goes beyond the scope of our paper".
Code is CC BY-NC-ND 4.0 (unusable); the idea is unencumbered.

**The standard objection does not apply to us.** Two 2025 papers dismiss size-based depth
([arXiv:2506.05763](https://arxiv.org/html/2506.05763), [arXiv:2506.07981](https://arxiv.org/abs/2506.07981),
both VERIFIED) — but both concern **7–10 px** balls. Ours is 5–7× better conditioned. The technique is
not wrong for us; the estimator is.

**A second, better depth channel.** Caio, Van Zandycke & De Vleeschouwer, MMSports 2023
([arXiv:2309.03640](https://arxiv.org/abs/2309.03640), VERIFIED): regress the pixel distance from the
ball to its vertical projection on the ground plane and invert the projection matrix. **MAPE 1.25 m vs
2.88 m** for diameter regression — 2.3× better, and independent of apparent size. We already recover a
metric plane from the rim ellipse, so this channel is available. **Disagreement between two channels
that fail differently is a far stronger trust metric than diameter drift alone** — which is what B11
actually wanted. Risk: both channels share the rim calibration, and 2026-09-24 showed the rim trace's
implied vertical can be wrong for a whole clip.

**BlurBall**, Gossard et al., **CVPRW 2026** ([arXiv:2509.18387](https://arxiv.org/abs/2509.18387),
**MIT**, weights for BlurBall/WASB/TrackNetV2+V3/BallSeg/DeepBall/MonoTrack in one repo, VERIFIED).
The ground-truth heatmap covers the whole blur streak. Changing **only the labelling convention** from
"front edge of the streak" to "centre of the streak", identical images and models:

| detector | F1 front → centre |
|---|---|
| DeepBall | 39.36 → **57.14** |
| TrackNetV3 | 93.74 → 95.93 |
| WASB | 95.58 → 96.00 |

Blur-aware trajectory fitting cut trajectory error **84.4 → 53.0 px**. Direct published evidence that
modelling the streak instead of letting it corrupt the box fixes downstream geometry.

**Licences worth knowing** (all read from the actual LICENSE, VERIFIED): **WASB** MIT (1.5 M params,
82.6 F1 on broadcast basketball where BallSeg scores 16.8); **TrackNetV3** MIT *and its licence text
explicitly covers the checkpoints*; **RF-DETR** Apache-2.0 for N/S/M/L weights, with a Core AI export
landed 2026-09-24 and published on-device latency. **Blocked:** all Ultralytics YOLO (AGPL), YOLO-NAS
(non-commercial), DEIMv2 (non-commercial), and anything pretrained on Objects365 (academic-only, which
transitively taints D-FINE's `*_obj365` and all LW-DETR weights).

**TrackNetV3's recall lever is the relevant one.** Its trajectory rectification traded **1.85 points of
precision for 4.77 points of recall** on a detector at 99.64/94.56. ArcLab is at **100/57**.
⚠️ But precision 100 % is the reason this app can say it never fabricates a number. Any repair that
invents a detection to close a gap is a fabricated measurement. If taken, repaired samples must be
flagged on `ImageSample` and the bench must report precision on repaired vs original separately.

---

## 2. Vision has not moved, and the body-pose bill is ours to cut

**Every request ArcLab uses is unchanged since iOS 18** — `DetectTrajectoriesRequest`,
`DetectHumanBodyPoseRequest` (revision2 only), `DetectHumanBodyPose3DRequest`, `TrackObjectRequest`
(revision2 only), `TrackOpticalFlowRequest`, `CoreMLRequest`. VERIFIED from the DocC JSON endpoints.
The legacy `VN*` API is **not** deprecated (exactly one symbol across the whole surface is). Apple's
sports-analysis sample is still iOS 14 / `VN*`. WWDC25 and WWDC26 had one Vision session each, both
about document reading and segmentation; **zero** tracking, trajectory, pose or detection content.

New and possibly relevant: **`GenerateIterativeSegmentationRequest`** (iOS 27) can be seeded with a
bounding box — a SAM-style mask from a detector box. No latency published; viability at 120–240 fps
**UNVERIFIED**. **`VTFrameProcessor`** (VideoToolbox, came to iOS in 26) takes an arbitrary
`interpolationPhase` array, so a frame can be synthesised at exactly the timestamp a ball position is
wanted; no latency published.

⚠️ **Hand pose changed model in iOS 26 and the docs never said so.** WWDC25 session 272, verbatim:
*"the joints are not in the same location as the previous model… we encourage you to retrain."* The
`Revision` enum still lists only `revision1`. ArcLab ships no hand metric, but `HandTriangle` consumes
hand-pose points and any threshold tuned before iOS 26 is suspect.

### Four measured levers on the 12 s pass (B5)

From ArcLab's own instrumentation: 2-D body alone **12 ms/frame**; adding the 3-D request → **31
ms/frame**; adding hands on a 256 px crop → **34 ms/frame**. So **the 3-D request is 19 ms/frame — over
half the stage — and the skeleton fit uses it only for the *sign* of each joint's depth.** Separately,
giving the body and hand crops their own `Cropper` took one window 10.3 s → 5.9 s, which the code's own
comment calls the single largest cost in the stage. **The stage is as much buffer-copy-bound as
inference-bound.**

- **A. `detectsHands` defaults to `true` and nothing reads the result — benched here, result honest but
  weak.** VERIFIED from the doc, and verified in this tree: the request is constructed bare in three
  places (`BodyTracker.swift:205`, `PoseTracker.swift:67`, `FormClipScanner.swift:263`), `detectsHands`
  is never set anywhere, and nothing reads the body observation's hand sub-observations — the wrist
  points used downstream come from the separate `DetectHumanHandPoseRequest`.

  **Measured 2026-09-27** on 60 frames of `IMG_1765.mov` at t = 240 s (where Vision finds a body in
  20/20 frames), 9 paired passes, macOS, `swiftc -O`:

  | | median ms/frame | observations |
  |---|---|---|
  | `detectsHands = true` (today) | 14.28 | 31 |
  | `detectsHands = false` | 11.78 | **31** |

  **Faster in 7 of 9 paired passes; sign test p = 0.18 — not significant.** Median *paired* delta
  −1.12 ms/frame (−7.8 %); the −17.5 % implied by comparing the two medians is an artefact of taking
  them from different passes, and should not be quoted. The machine was running six research agents
  throughout, and pass-to-pass variance (11.97–16.74 ms/frame on the *same* setting) swamps the effect.

  **The solid part is the other column: the observation count is identical in every pass, so nothing is
  lost by turning it off.** That makes this a free change whose saving is unmeasured rather than a
  trade-off. Re-measure on a quiet machine and on device before claiming a number.

  **A measurement worth recording, once it is framed correctly.** Run on **full 1920×1080 frames**,
  Vision finds a body in only **13 of 336 frames (4 %) inside real shot windows** of `IMG_1765.mov`
  (14 windows taken from the bench cache, 24 frames each; 11/24 at one window, 2/24 at another, 0/24 at
  the other twelve). At ~8 m the shooter is a small fraction of frame height and full-frame body pose
  mostly does not see them.

  ⚠️ **This is not what the app does, and must not be quoted as an app coverage figure.** `BodyTracker`
  crops around the shooter and runs pose on the crop (`BodyTracker.swift:213`, two `Cropper`s), which is
  exactly why it gets usable coverage — `docs/research/form-eval-baseline-2026-09-16.md` reports ICC 0.92
  for jump height over 37 free throws. What the number does establish is that **the crop is load-bearing,
  not an optimisation**: remove it and body coverage collapses to a few per cent. Anything that changes
  how the crop is placed or sized (including lever D's `regionOfInterest` idea) is a change to a
  first-order dependency, and needs the FormEval re-baseline B5 already specifies.
- **B. Perform the requests through one handler.** `BodyTracker.swift:348-350` issues three independent
  `perform(on:)` calls, each building its own handler. WWDC24 10163, verbatim: *"for optimal performance
  Vision recommends performing requests together."* Note honestly: the `ImageRequestHandler` reference
  page does not itself claim shared work is saved, so this rests on the session transcript. Bench it.
- **C. Call the 3-D request less.** `frameAnalysisSpacing` skips buffers but Apple **never promises a
  compute saving** — the saving comes only from not calling `perform`, which matches ArcLab's
  measurement that the spacing knob changed nothing. Since the output is used only for a sign, and a
  limb's depth sign changes at most twice in a shot, `everyNthFrame3D` of 4–6 with sign-holding is pure
  arithmetic. **This is the only one of the four that can change a number** — gate it on B5's stated
  gate (ICC for jump height and head travel unchanged within SDC), because the recorded knee angles
  without 3-D (175.6/173.3/171.1°) versus with (158.2/143.3/156.0°) show how badly naive dropping fails.
- **D. `regionOfInterest`** is a member of `ImageProcessingRequest` (iOS 18+). ArcLab crops by rendering
  into a `CVPixelBuffer`; ROI may avoid the render. **UNVERIFIED** that Vision's ROI path is cheaper.

A/B should be bit-identical. If they are not, that is itself the finding.

---

## 3. Capture: real guarantees arrived in iOS 26, and one silent hazard

**`AVCaptureDeviceInput.activeLockedVideoFrameDuration` (iOS 26.0+)**, verbatim: *"Setting this
property **guarantees** the intra-frame duration delivered by the device input is precisely the frame
duration you request."* VERIFIED. Before this it was a request, not a guarantee. **ArcLab's minimum
target is iOS 26, so this is adoptable unconditionally.** It auto-resets to `kCMTimeInvalid` on any
`activeFormat` change, and is incompatible with auto frame rate and spatial capture.

Apple's guidance on the same page: **set exposure to half the frame duration or less.** At 240 fps that
is ≤ 1/480 s — which halves the motion-blur streak feeding §1.

🔴 **`AVCaptureDevice.isAutoVideoFrameRateEnabled` (iOS 18+) decreases the frame rate in low light**,
throws if you set frame duration while it is on, and resets to `false` on every `activeFormat` change.
VERIFIED. **A dim gym is exactly the trigger condition.** Set it false explicitly and re-assert after
every format change.

Also turn off and assert, for the analysis path (all VERIFIED): video stabilisation (a time-varying
warp and crop destroys constant intrinsics), `isCinematicVideoCaptureEnabled` (iOS 26 — bakes synthetic
blur in and forces continuous autofocus), iOS 27's low-light video noise reduction (temporal NR smears
a fast ball) and continuous-autofocus tracking, and iOS 26 smart framing. **Reactions** are off by
default for non-VoIP apps, but a gym is full of the triggering gestures and confetti composited into
analysis frames would be catastrophic — add a CI check that Info.plist carries neither
`NSCameraReactionEffectsEnabled` nor the VoIP background mode, and log `device.reactionEffectsEnabled`
at capture start.

**Per-frame gravity can be recorded, and should be.** iPhone `.mov` files carry **no** gravity or
attitude track (VERIFIED as absent from the QuickTime key list), but `AVCaptureMetadataInput(formatDescription:clock:)`
— passing `session.synchronizationClock` — writes `CMDeviceMotion.gravity` as timed metadata.
⚠️ `AVAssetWriterInputMetadataAdaptor` is **deprecated in iOS 27**; use `AVAssetWriter.inputMetadataReceiver(for:)`
(iOS 26+). This would replace `MeasuredVertical` — a hand-built per-clip table of camera vertical — with
a measured quantity per frame, and the rim trace's implied vertical was the root cause of the
three-point collapse. Do **not** use `RotationCoordinator` for this: its angles are quantised to 0/90/180/270°.

**Frame rates, VERIFIED per model.** 1080p240 is universal from iPhone 14 Pro through 18 Pro, including
non-Pro models — a safe floor. **4K240 does not exist on any iPhone**; the ceiling is 4K120 (16/17/18
Pro, Duo). ⚠️ Apple's tech specs describe Camera.app, not what `AVCaptureDevice.formats` vends to a
third-party app, and Apple publishes no per-device format enumeration — enumerate at runtime, never
hardcode a device table.

**Dropped frames are fully diagnosable** via `captureOutput(_:didDrop:from:)` and
`kCMSampleBufferAttachmentKey_DroppedFrameReason` (`_FrameWasLate`, `_OutOfBuffers`, `_Discontinuity`).
At 240 fps a `_Discontinuity` mid-flight silently corrupts a parabola fit. Log every drop with its PTS
and gap-flag the affected track.

**Prefer `AVCameraCalibrationData` to ARKit for intrinsics**: it carries a distortion lookup table,
`pixelSize`, and reference dimensions; `ARCamera.intrinsics` has no distortion model at all.
⚠️ **Unconfirmed and load-bearing:** whether a 1080p240 *video* format vends calibration data, or only
the photo/depth paths. Test on device.

---

## 4. Ruled out, with the reason

- **LiDAR / depth at 7 m.** Apple publishes no range figure anywhere. *Scientific Reports* 11:22221
  (VERIFIED): *"The maximum range is up to 5 m"*, with point density falling from 7,225 pts/m² at 25 cm
  to 150 pts/m² at 2.5 m. An independent bench sweep found reliable operation only to ~4 m and
  non-repeatable readings beyond. At 7 m we are 40 % past the stated maximum. **The rim-ellipse-from-a-known-0.4572 m
  approach is correct and depth is not an alternative.**
- **ARKit body tracking.** ARKit owns an `AVCaptureSession` and iOS grants exclusive camera access, so
  120/240 fps AVFoundation capture and ARKit body tracking **cannot run on the same pass** (VERIFIED,
  Apple forums). Confirms `docs/research/arkit-body-tracking-spike-2026-09-15.md`'s conclusion.
  ⚠️ **Correction to that doc:** it cites FB15128723 for the iOS 26 `ARBodyAnchor` failure; that thread
  got no Apple response. The one that did is forums/thread/803714 → **FB20684856**, and the reporter
  confirmed in February 2026 that **it was fixed in iOS 26.3**. Broken on 26.0–26.2 only, not an iOS 27 fix.
  What ARKit *would* still give a tripod is `WorldAlignment.gravity` — camera roll and pitch relative to
  true vertical without estimating a vanishing point — but it needs a separate pre-recording pass, and
  there is an active world-tracking drift regression on LiDAR devices (FB23200349, iOS 26.4+, Apple:
  *"no recommended workaround so far"*).
- **Apple Foundation Models.** **It does not run on this project's device.** Apple's support page
  (updated 2026-09-14, VERIFIED) lists iPhone 16+, 15 Pro/Pro Max, iPhone Air, iPad mini (A17 Pro) —
  **iPhone 14 Pro is not eligible**, so `SystemLanguageModel.default.availability` returns
  `.unavailable(.deviceNotEligible)` on the paired phone. It addresses neither ceiling, would need a
  full template fallback anyway, and App Review 1.4.1 requires disclosed methodology for accuracy claims
  on health measurements. ⚠️ Unresolved doc conflict: the context-window article says 4096 tokens, WWDC26
  session 241 prints 8192 — read `model.contextSize` at runtime, hardcode neither.
- **Hough circle transform** for the diameter — measured 3× worse than a learned regressor. The clearest
  "don't" in this research.
- **RoomPlan**, **`ARGeoTrackingConfiguration`** (outdoor + network), **Private Cloud Compute** (network,
  excluded by product principle).

**Core AI** (iOS 27+) is genuinely new — a full inference framework, with `coreai-torch` export and an
RF-DETR path with published iPhone latency (**RF-DETR-Nano fp16, A15 iPhone 13: 30.5 ms/frame** ≈ 33 fps).
Core ML is **not** deprecated and Vision's `CoreMLRequest` still takes an `MLModel`; there is no
`CoreAIRequest`. ⚠️ `coremltools` has **no iOS 27 deployment target** on `main` (VERIFIED by reading
`_deployment_compatibility.py`). And Core AI is iOS 27-only, with **no published iOS 27 adoption figure**
— Apple's page still reports iOS 26 at 86 % as of 2026-06-07. Raising the minimum target today costs
most of the install base.

---

## Corrections this research makes to existing docs

1. **`arkit-body-tracking-spike-2026-09-15.md`** cites the wrong Feedback ID (see §4). The bug was fixed
   in **iOS 26.3**.
2. **`sdk-and-licensing-research-2026-09-12.md` §5(c)**: SportsMOT is CC BY-NC 4.0 *and has no ball
   annotations at all* — players only. Its Roboflow licence strings were read from mirrored exports
   because Roboflow Universe 403s programmatic fetches; **open each in a browser before training**.
3. The same doc's open question about `CoreMLRequest` returning `RecognizedObjectObservation` can be
   closed: the documentation still lists only three result types and does not include it.
4. **`CoreMLBallDetector` cuts 512 px tiles from the native frame**, so the common "letterboxing destroys
   small objects" explanation does **not** apply here. Worth recording because it removes a
   plausible-sounding cause and points squarely at the box→diameter conversion.
