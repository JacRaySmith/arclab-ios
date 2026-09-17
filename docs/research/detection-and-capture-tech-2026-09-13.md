# Detection and capture technology research — ArcLab iOS

Date: 2026-09-13. Companion to `docs/reference/sdk-and-licensing-research-2026-09-12.md` (API names, licences of
RT-DETR/RF-DETR/YOLOX, Roboflow dataset licences, AVAssetReader/Provider API — not repeated here).

Method: ~45 web searches plus direct fetches. Where possible I read primary sources rather than summaries:
Apple's Action & Vision sample was downloaded and grepped (values below are from the Swift source, not the video);
Apple doc pages were read through the `developer.apple.com/tutorials/data/documentation/*.json` endpoint; licences
were read through the GitHub REST API (`/repos/{owner}/{repo}` and `/license`) or the raw `LICENSE` file; the WASB
paper was text-extracted from the arXiv PDF. Anything I could not confirm is marked **UNVERIFIED**. "My estimate"
marks back-of-envelope numbers I computed, not published figures.

Frequently used estimate (my estimate, used in several sections): iPhone main camera, 1080p landscape, horizontal
FOV ≈ 69° → at 7 m the frame spans ≈ 9.6 m → **≈ 200 px/m**. A 24 cm ball ≈ 48 px; a 1.9 m player ≈ 380 px;
a forearm (~27 cm) ≈ 54 px. Ball at 7 m/s at 240 fps moves ≈ 2.9 cm ≈ **6 px per frame**; at 30 fps ≈ 47 px per frame.

---

## 1. Apple's Action & Vision app (WWDC20 session 10099 + sample code)

Sources: session https://developer.apple.com/videos/play/wwdc2020/10099/ ; sample page
https://developer.apple.com/documentation/vision/building-a-feature-rich-app-for-sports-analysis ; sample zip
https://docs-assets.developer.apple.com/published/84b9ca3f588f/BuildingAFeatureRichAppForSportsAnalysis.zip
(files quoted: `Common.swift`, `GameViewController.swift`, `SetupViewController.swift`, `CameraViewController.swift`,
`Views/TrajectoryView.swift`).

### Exact parameter values (from the source)
| Item | Value | Where |
|---|---|---|
| `VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: GameConstants.trajectoryLength)` | `trajectoryLength = 15` | `GameViewController.swift:48`, `Common.swift:119` |
| Confidence gate on observations | `trajectoryDetectionMinConfidence: VNConfidence = 0.9` | `GameViewController.swift:45` |
| `objectMinimumNormalizedRadius` / `objectMaximumNormalizedRadius` | **not set** (defaults) | grep of all sources: no occurrence |
| `request.regionOfInterest` on the trajectory request | **not set**; the ROI is applied in app space (`TrajectoryView.roi`) | `GameViewController.swift:185-216`, `TrajectoryView.swift:120` |
| App-space ROI | `throwRegion` = 400 pt wide, starts 50 pt right of the player box, height = player box height − 50; `targetRegion` = board box ± 50 pt; ROI slides with the bag and snaps to the target region | `resetTrajectoryRegions()`, `updateTrajectoryRegions()` |
| Throw complete | > `noObservationFrameLimit = 20` consecutive frames with no observation inside the ROI | `Common.swift:121`, `TrajectoryView.isThrowComplete` |
| Trajectory stitching | a new observation is accepted if its start is within `maxDistanceWithCurrentTrajectory = 250` pt of the current path end, and the path moves left→right (`isTrajectoryMovingForward`) | `TrajectoryView.swift:31-37,116-121` |
| Pose buffer | `maxPoseObservations = 45`, `maxTrajectoryInFlightPoseObservations = 10` | `Common.swift:120,123` |
| Board size | `boardLength = 1.22` m (4 ft) | `Common.swift:118` |
| Capture | `sessionPreset = .hd1920x1080`, `AVCaptureVideoDataOutput` 420f, `alwaysDiscardsLateVideoFrames = true`, `preferredVideoStabilizationMode = .standard`; **no frame-rate set** (device default, i.e. 30 fps) | `CameraViewController.swift:64-91` |
| Scene stability | `VNTranslationalImageRegistrationRequest(targetedCMSampleBuffer:)` against the previous frame via `VNSequenceRequestHandler`; keep `sceneStabilityRequiredHistoryLength = 15` shifts; stable iff `|Σx| + |Σy| < 10` (points) | `SetupViewController.swift:44-46,193-209,237-238` |

### How release speed and angle were computed
- **Speed**: length of the straight line from the first to the last detected point of the *first* accepted trajectory
  (view points) divided by `timeRange.duration`; converted with `pointToMeterMultiplier = 1.22 / boardLengthInPoints`,
  where the board length is the longest edge of the board contour (`VNDetectContoursRequest` with `regionOfInterest =
  board bounding box` from a Create ML detector, `polygonApproximation(epsilon: 0.01)`), then ×2.24 for mph.
  (`GameViewController.swift:249-262`, `SetupViewController.swift:277-295`). This is a chord speed, not an
  instantaneous release speed.
- **Release angle**: the forearm (elbow→wrist from `VNDetectHumanBodyPoseRequest`) angle from horizontal at the pose
  frame `count − (trajectoryLength + maxTrajectoryInFlightPoseObservations)` = 25 pose frames before the current one —
  i.e. the release frame is *assumed* to be 25 frames before the first trajectory result, which encodes the request's
  latency (15 points) plus a fudge of 10 (`Common.swift:91-102`). It is not derived from the ball track.

### Transcript statements that matter (session 10099)
- "It requires a stable scene. Hence, the prerequisite that we actually have the phone stabilized on a tripod."
- "You have to feed in SampleBuffers with time stamps, because we're using the time stamps in our analysis."
- "If your ball, for instance, bounces or leaves the frame, we get a new trajectory anytime this happens. And you
  have to combine those… by looking… at the last point of a previous trajectory if it matches up with the first point
  of a new trajectory."
- "By setting the minimumObjectSize, I can filter out the noise of the very small parts… maximumObjectSize to filter
  out objects that are much larger."
- "Objects have to travel on some kind of a parabola. Now, a straight line is a parabola."
- Latency: results appear only once five (here 15) points are accumulated; the app renders asynchronously and releases
  buffers before drawing.
- Stationary objects and the throwing hand are not handled explicitly — the design relies on frame differencing (static
  things produce no signal), on the ROI starting 50 pt right of the player's bounding box, and on "business logic"
  ("we knew that the bean bags would only travel from the player throwing at the board").

Apple's article "Identifying Trajectories in Video" adds: "The algorithm looks at the frame differentials in the video
to detect any objects traveling along a parabolic path"; sizes "aren't pixel accurate, but instead provide general
guidelines… Setting a size that's slightly smaller than your target minimum, and slightly larger than your maximum may
produce better results"; the example uses `trajectoryLength: 15`.
https://developer.apple.com/documentation/vision/identifying-trajectories-in-video

**Recommendation for ArcLab:** copy the structural ideas (single stateful request fed `CMSampleBuffer`s, confidence ≥ 0.9,
app-side ROI that excludes the shooter's body box, stitching by end/start proximity, "no observation for N frames"
end-of-flight) but none of the numeric constants — they are for a 30 fps bean-bag toss. Do not use their release-angle
method (forearm from horizontal, fixed 25-frame offset); ours comes from the fitted ball track (BRIEF §4.5).

---

## 2. Real-world behaviour of DetectTrajectoriesRequest / VNDetectTrajectoriesRequest

What is documented and what developers report:
- **Per-frame radius is not available.** `TrajectoryObservation.movingAverageRadius` is declared
  `let movingAverageRadius: CGFloat` — one number per observation, not per point
  (https://developer.apple.com/documentation/vision/trajectoryobservation/movingaverageradius). It was added in
  iOS 15 (API diff: http://codeworkshop.net/objc-diff/sdkdiffs/ios/15.0/Vision.html). The observation gives
  `detectedPoints` (centroids) and `projectedPoints` (on the fitted parabola) only. **This alone means the Vision
  trajectory detector cannot satisfy the Phase 1 requirement that the detector report a ball size per frame.**
- **`objectMaximumNormalizedRadius` setter reported ignored** (stays 1.0) while `objectMinimumNormalizedRadius` and
  `regionOfInterest` took effect — unanswered forum thread, iOS 14 era
  (https://developer.apple.com/forums/thread/670447). The MIZUNO sample repo repeats the same observation ("setting
  has not been reflected for unknown reasons") and uses `trajectoryLength: 10` for a golf ball
  (https://github.com/MIZUNO-CORPORATION/IdentifyingBallTrajectoriesinVideo, MIT). Whether this is fixed in the
  iOS 18 `DetectTrajectoriesRequest` API: **UNVERIFIED** — test on device.
- **Full-frame ROI produced no results; a windowed ROI worked**, and raising the camera (chest→eye level) helped for
  a rolling ball (https://developer.apple.com/forums/thread/658466).
- **Stable camera is mandatory** ("Any camera movement introduces noise and motion blur, which reduces the accuracy",
  https://developer.apple.com/documentation/vision/identifying-trajectories-in-video). Handheld 30 fps imports are
  therefore out of scope for this detector unless frames are first registered (see §6).
- **Shadows produce a second parabola**; multiple concurrent trajectories are distinguished by `uuid` (WWDC20 session;
  also https://cloud.tencent.com/developer/article/2277724). Expect the shooter's hands/arms to spawn short spurious
  trajectories — `trajectoryLength` and the ROI are the only knobs.
- **Latency** = at least `trajectoryLength` frames; `targetFrameTime` lets the request trade accuracy for time
  ("If processing takes longer than the targeted time… it attempts to decrease the overall time by reducing the
  accuracy"; default indefinite = max accuracy) (https://developer.apple.com/documentation/vision/detecttrajectoriesrequest/targetframetime).
  For offline import, leave it indefinite.
- **Small objects**: Apple says it follows objects "only a few pixels in size" and recommends 1080p for tennis/cricket
  balls (same article). Our ball is ≈ 48 px at 7 m (my estimate) — comfortably large for the detector.
- **120/240 fps behaviour**: I found **no** developer report, blog, or GitHub project that ran this request on 120 or
  240 fps footage — **UNVERIFIED**. Reasoning to test against: the algorithm differences consecutive frames; at 240 fps
  the ball moves ≈ 6 px/frame (my estimate), so the differential blob is the ball itself (good), but the parabola over
  15 points spans only 62 ms and is nearly straight, so early results will have weak curvature. Mitigation:
  `frameAnalysisSpacing` (documented as a throttle) to analyse every 4th–8th frame for *detection*, then use our own
  detector on all frames.
- **Occlusion**: a trajectory that "goes offscreen and comes back" starts a new trajectory (same article); occlusion
  by the shooter's body near release should behave the same. No quantitative report found.
- No basketball/tennis/cricket/table-tennis GitHub project using the request beyond the MIZUNO sample was found (searches
  returned Python/YOLO projects only).

**Recommendation for ArcLab:** use `DetectTrajectoriesRequest` only as the *zero-model baseline* the brief asks for and
as a cheap **flight-window finder** (time range + coarse parabola) on tripod footage; do not plan on it as the
production detector — it returns no per-point size, cannot be tuned below `trajectoryLength = 5`, has an unresolved
max-radius bug report, and has no documented high-frame-rate behaviour. Record its recall on the Phase 0 footage
(§"Phase 2 evaluation plan") so the decision is data-driven.

---

## 3. Permissively licensed small-ball detectors that can be converted to Core ML

Licence strings below are exactly as returned by the GitHub API `license.spdx_id` / `license.name` on 2026-09-13, or
quoted from the LICENSE file.

| Model / repo | Licence | Input / architecture | Reported accuracy on small balls | Core ML feasibility | iPhone speed |
|---|---|---|---|---|---|
| **WASB** — https://github.com/nttcom/WASB-SBDT (BMVC 2023, https://arxiv.org/abs/2311.05237) | `MIT` (GitHub API). Weights are Google-Drive links from `MODEL_ZOO.md`; no separate weight licence stated → assume repo licence, **UNVERIFIED** | HRNet-small variant with the stem strides removed, 3 stacked RGB frames → 3 heatmaps at input resolution; images resized to **288×512**; 1.5 M params (paper §5.1, Table 3) | Paper Table 2 (τ = 4 px): Basketball dataset F1 **80.6** / Acc 71.3 / AP 71.5 at 30.2 FPS (Step=3) and F1 82.6 / Acc 73.4 / AP 77.1 at 22.3 FPS (Step=1); Tennis F1 94.0–95.6; Badminton 91.6–93.1. Basketball set: 1920×1080 broadcast clips from Yan et al. ECCV 2020, 275,328 manually annotated images, mean ball displacement 33.7 ± 21.8 px/frame, fast camera motion. Paper limitation: "our validation is limited to standard frame resolutions (e.g., HD, FHD) and frame rates (e.g., 25–30 FPS)" | Plain conv HRNet + heatmap decoding → coremltools-convertible in principle; **UNVERIFIED** (not attempted) | Not reported; paper FPS are on V100 |
| **TrackNetV3** — https://github.com/qaz812345/TrackNetV3 | LICENSE file is MIT text and explicitly covers "this software, pretrained model checkpoints, and associated documentation" (GitHub API shows `Other`; raw file read) | Two modules (TrackNet + InpaintNet); resolution not stated in README | 97.51 % accuracy on the Shuttlecock Trajectory Dataset; 25.11 FPS (hardware not stated in README) | TrackNet part is U-Net-style conv → convertible; the inpainting/rectification module is a second model | Not reported |
| **TrackNet / TrackNetV2** (NCTU GitLab: https://gitlab.nol.cs.nycu.edu.tw/open-source/TrackNet , https://gitlab.nol.cs.nycu.edu.tw/open-source/TrackNetv2) | **No LICENSE file** in either repo tree (checked via GitLab API: TrackNetV2 tree = `3_in_1_out`, `3_in_3_out`, `README.md`); GitLab licence field `None` → treat as all-rights-reserved until the authors say otherwise. Community ports: https://github.com/Chang-Chia-Chi/TrackNet-Badminton-Tracking-tensorflow2 `MIT`; https://github.com/ChgygLin/TrackNetV2-pytorch `None` | TrackNet input 640×360 (README); V2 uses 3-in/3-out at 512×288 per the WASB paper | WASB re-implementation of TrackNetV2: Badminton Acc 85.6 (paper Table 2 discussion) | Convertible (U-Net) | Not reported |
| **MonoTrack** — https://github.com/jhwang7628/monotrack | "ADOBE RESEARCH LICENSE … may be exercised for noncommercial research purposes … only" (raw LICENSE) | modified TrackNet + MMPose | (WASB Table 2: Basketball F1 80.8) | — | **Do not use** |
| **BallSeg / DeepSportradar** — https://github.com/gabriel-vanzandycke/deepsport | `LICENSE.md` = "Attribution-NonCommercial-NoDerivatives 4.0 International (CC BY-NC-ND 4.0)"; WASB notes BallSeg's "official implementation has not been publicly available" | ICNet-based, two frames | — | — | **Do not use** (datasets on Kaggle: licence **UNVERIFIED**) |
| **BlurBall** — https://github.com/cogsys-tuebingen/blurball (https://arxiv.org/abs/2509.18387) | `MIT` (GitHub API) | HRNet-based multi-frame detector that also predicts **blur orientation and extent**; 64 k annotated table-tennis frames; weights via NextCloud | Not in README | Convertible in principle (**UNVERIFIED**) | Not reported |
| **Roboflow-trained models** | Datasets: see prior doc (CC BY 4.0 / MIT listings). Roboflow states you own trained weights and that models trained with "Roboflow Train" are commercial-OK; RF-DETR is Apache-2.0 (https://roboflow.com/licensing , https://blog.roboflow.com/rf-detr-is-free-to-use-commercially/) | RF-DETR Nano/Small/Medium (https://blog.roboflow.com/rf-detr-nano-small-medium/): Nano 48.0 AP COCO at 2.3 ms (T4) | No basketball-specific numbers | Roboflow's iOS post gives **no measured iPhone latency** for RF-DETR; "60+ FPS on Neural Engine" is a claim about YOLO11, not measured (https://blog.roboflow.com/best-ios-object-detection-models/) | **UNVERIFIED** |
| **Create ML `MLObjectDetector`** | your own model (prior doc §5a) | Transfer learning: "does well with as few as 80 training examples per class", model half the size, requires iOS 14 (tech talk https://developer.apple.com/videos/play/tech-talks/10155/ as quoted by search results; transcript not fetchable). Practitioner report: trained on 416×416 images with a 13×13 grid; `gridSize` is a `ModelParameters` property (https://developer.apple.com/documentation/createml/mlobjectdetector/modelparameters-swift.struct/gridsize , https://evilmartians.com/chronicles/object-detection-with-create-ml-training-and-demo-app) | **No published result on ~40 px objects — UNVERIFIED.** At 416 px input a 48 px ball in a 1920 px frame becomes ≈ 10 px (my estimate), which is below what YOLOv2-style grids localise well | Native | Native |

Notes:
- The WASB benchmark (same codebase, same metric) is the only apples-to-apples comparison of these detectors on a
  basketball set; WASB and MonoTrack lead, TrackNetV2 and BallSeg trail (paper Table 2). WASB's Basketball numbers are
  on broadcast footage with fast pans, which is harder than our tripod case.
- All of these are **heatmap** detectors: they give a centroid, not a bounding box. Ball diameter must come from a
  second step (e.g. local blob/edge fit around the peak, or a regression head) — BlurBall's blur-extent head is a
  hint that the same architecture can regress size. Ultralytics is excluded (AGPL, prior doc).

**Recommendation for ArcLab:** run two candidates on the Phase 0 footage: (a) Create ML transfer-learning detector
trained on **cropped tiles** (e.g. 640×640 crops centred on the predicted ball position, so the ball is ≥ 40 px in
model input) — box gives diameter directly; (b) WASB (MIT) converted with coremltools at 288×512 with a local
edge-fit for diameter. Keep MonoTrack and BallSeg out of the codebase. Prefer training data you film yourself
(Phase 0) over broadcast datasets: the domain (static camera, gym, one ball) is different.

---

## 4. Rim / hoop detection and ellipse fitting

Findings:
- **No open-source project that fits a rim ellipse from phone video was found.** Basketball repos detect the hoop as a
  YOLO/Faster-R-CNN box and decide make/miss from ball-vs-box position: chonyy/AI-basketball-analysis (Faster R-CNN,
  COCO; LICENSE is the OpenPose "NONCOMMERCIAL RESEARCH USE ONLY" agreement — https://github.com/chonyy/AI-basketball-analysis),
  BasketVision (YOLOv8 → AGPL chain; draws a "green ellipse" — whether it is fitted or drawn from the box is
  **UNVERIFIED**, https://github.com/hetuvpatel/BasketVision), nvan21/Basketball-Shot-Detection (segmentation +
  parabola fit, https://github.com/nvan21/Basketball-Shot-Detection). The Stanford CS231A report calibrates from court
  lines, not the rim (https://cvgl.stanford.edu/teaching/cs231a_winter1415/prev/projects/basketball.pdf).
  HomeCourt (Nex Team) "recognizes the rim" with a deep model but publishes no method
  (https://www.cnbc.com/2019/04/17/how-artificial-intelligence-is-making-better-basketball-shooters-with-just-your-iphone.html).
- **Datasets with a hoop/rim class** (Roboflow Universe listings, licence as shown in listings — pages return 403 to
  fetch, verify in a browser): "Basketball and rim" 6.3 k images CC BY 4.0
  (https://universe.roboflow.com/basketball-hoop-tsdku/basketball-and-rim); "basketballl hoop" CC BY 4.0
  (https://universe.roboflow.com/basketballai3/basketballl-hoop); "Basketball Courts Class" 337 images with
  Backboard/Net/Rim classes CC BY 4.0 (https://universe.roboflow.com/shotanalyzer-workspsace/basketball-courts-class).
- **Colour**: a commonly published OpenCV orange range is H 10–25, S 100–255, V 20–255 on OpenCV's 0–180 hue scale
  (https://www.geeksforgeeks.org/computer-vision/choosing-the-correct-upper-and-lower-hsv-boundaries-for-color-detection-with-cv-inrange-opencv/).
  Nothing basketball-specific with validated thresholds was found; the ball is the same orange, so colour alone cannot
  separate rim from ball — use *stationarity over time* (the rim never moves; median over N frames) and shape.
- **Geometry**: pose of a circle from one ellipse with known intrinsics (two-fold ambiguity, resolved by our
  "rim is horizontal" prior): "Pose estimation of a single circle using default intrinsic calibration"
  https://arxiv.org/abs/1804.04922 ; homography from one ellipse correspondence plus minimal extra information
  (https://www.researchgate.net/publication/265212988_Homography_estimation_using_one_ellipse_correspondence_and_minimal_additional_information).
  RANSAC ellipse fitting on edge points is standard (https://link.springer.com/content/pdf/10.1007/978-3-642-17534-3_65.pdf).
- **Net and backboard**: the net hangs from the rim's lower edge and is white; the backboard edge is a straight line
  behind the ring; both contaminate an edge map. Nobody publishes a recipe; the practical fix is to fit only the
  **upper arc** of the orange ring (which is the visible outer edge, un-occluded by net), and to reject straight-line
  segments before fitting. **Breakaway-rim shapes**: no source found — **UNVERIFIED**; the ring itself is still a
  45–46 cm circle (prior doc §6), the spring housing sits behind it toward the backboard and will show as an orange
  blob attached to the back of the ellipse — mask the rear 20 % of the ring width.
- Related monocular basketball 3D-reconstruction paper (calibration + 2D detection → 3D ballistic shot):
  https://ieeexplore.ieee.org/document/10312079/ (abstract only; method details **UNVERIFIED**).

**Recommendation for ArcLab:** two-stage rim detector, all on-device: (1) coarse box from a Create ML "hoop" class
(train on Phase 0 frames + a CC BY 4.0 set) or a user tap; (2) inside the box, orange mask → contour
(`DetectContoursRequest`, iOS 18: https://developer.apple.com/documentation/vision/detectcontoursrequest , or CoreImage
edges) → RANSAC ellipse on the top arc → temporal median of ellipse parameters over ≥ 30 frames (rim is static);
report minor/major ratio and refuse below 0.15 (BRIEF §4.2). Remember the calibration uses the *inner* 45 cm
diameter while the edge you fit is the *outer* edge (Phase 1 report caveat 4) — model the tube radius.

---

## 5. iPhone slo-mo files and Camera.app behaviour

### How a Camera.app 240 fps clip is stored and how to read it
- The `.mov` written by Camera.app is a plain full-rate file: Premiere imports it and "plays at normal speed" unless the
  user re-interprets the footage ("footage shot at 240fps and played at that same recorded speed is going to be just a
  very high frame rate but at normal speed" — https://community.adobe.com/t5/premiere-pro-discussions/iphone-6-6-plus-slow-motion-240fps-cinematic-camera-mov-clips-do-not-play-in-slow-motion-in-premiere/m-p/7338281).
  The slow-motion section is a Photos-side adjustment.
- From PhotoKit, `PHImageManager.requestAVAsset` returns an **`AVComposition`**, not an `AVURLAsset`, for slo-mo
  videos (https://buffer.com/resources/slow-motion-video-ios/ ; https://blog.kulman.sk/converting-slow-motion-video-to-url-asset/).
  A developer who loaded a 239.68 fps clip got `nominalFrameRate` ≈ 30 and a duration 8× the original — the
  composition's time-mapped playback, not the file (https://developer.apple.com/forums/thread/731460, unanswered).
- `PHVideoRequestOptions.version = .original` preserves 240 fps; `.current` after a Photos trim comes back at 30 fps;
  an Apple engineer pointed to `AVMetadataKey.quickTimeMetadataKeyFullFrameRatePlaybackIntent` (iOS 18+, "indicate
  whether the movie intends to play at the full frame rate (1) or at a slow motion rate (0)") for movies *you* record
  (https://developer.apple.com/forums/thread/775350 ,
  https://developer.apple.com/documentation/avfoundation/avmetadatakey/quicktimemetadatakeyfullframerateplaybackintent).
- Apple Media Engineering's recommended way to get a file URL for a library slo-mo video is
  `PHImageManager.requestExportSession(forVideo:options:exportPreset:resultHandler:)`
  (https://developer.apple.com/forums/thread/756332) — but an export with a preset may re-encode/resample; for analysis
  use `.original` and read the resulting `AVURLAsset` directly (per-frame PTS from `AVAssetReaderOutput`, prior doc §2).
  Reading the original resource via `PHAssetResource`/`PHAssetResourceManager` is an alternative; an iOS 18 crash in
  `writeData(for:toFile:options:)` was reported (https://developer.apple.com/forums/thread/774559) — **test**.
- **Frame-rate bugs in Camera.app**: users on iPhone 12–16 report 240 fps slo-mo actually recorded at ~114–227 fps
  or ~185 fps with jitter, codec-independent, temporarily fixed by a restart, "a very well documented bug… starting with
  iPhone 12" (https://discussions.apple.com/thread/254658403 ,
  https://forums.macrumors.com/threads/240-fps-slomotion-only-records-at-around-180-fps.2364332/ ,
  https://discussions.apple.com/thread/255919244). Implication: never assume 1/240 s spacing — use PTS deltas and let
  the fitter's dropped-frame handling (Phase 1 gate) absorb gaps; report the measured effective fps in the tier record.

### Camera.app settings (Apple iPhone User Guide, iOS 26 page:
https://support.apple.com/guide/iphone/change-video-recording-settings-iphc1827d32f/ios)
- "Slo-mo is set to record at 1080 HD at 240 fps from the back camera and 1080 HD at 120 fps from the front camera.
  To change the back camera to 120 fps, go to Settings > Camera > Record Slo-mo."
- "Auto FPS… automatically reducing the frame rate to 24 fps… apply Auto FPS to only 30-fps video, to both 30- and
  60-fps video, or turn it off" / older models: "Turn on Auto Low Light FPS." — the text scopes it to 30/60 fps video;
  no statement about Slo-mo. Community advice is to disable it when chasing frame-rate issues
  (https://discussions.apple.com/thread/254658403).
- "the Lock Camera setting prevents switching between cameras while recording video. Lock Camera is off by default."
- "You can lock the white balance when recording videos… Settings > Camera > Record Video, then turn on Lock White
  Balance." Whether Lock Camera / Lock White Balance apply in **Slo-mo mode** is not stated by Apple — **UNVERIFIED**
  (third-party guides say Pro controls only appear in Video mode, e.g. https://geekchamp.com/how-to-lock-white-balance-in-iphone-camera-on-ios-17/).
- "Enhanced Stabilization… zooms in slightly… while recording in Video mode or Cinematic mode" (not listed for Slo-mo).
- AE/AF Lock by long-press works in the Camera app and is the community fix for exposure/focus hunting in slo-mo
  (https://discussions.apple.com/thread/251750653).

### Third-party apps
- **Filmic Pro** App Store listing: "High speed frame rates of 60/120/240fps", manual ISO/shutter/focus; subscription
  (https://apps.apple.com/us/app/filmic-pro-video-camera/id436577167).
- **Blackmagic Camera** iOS tech specs list frame rates up to "100 fps, 120 fps" — **no 240** — with shutter 1/24–1/8000
  or angle, ISO, WB 2500–10000 K, manual focus (https://www.blackmagicdesign.com/products/blackmagiccamera/techspecs);
  users report a 60 fps cap on iPhone 15 Pro in some configurations (https://forum.blackmagicdesign.com/viewtopic.php?f=2&t=213897).
- **ProCamera**: no verifiable 240 fps statement found — **UNVERIFIED**.
- For our own capture path the 240 fps format is selected from `AVCaptureDevice.formats` (prior doc §2); a stale
  forum thread reports frame rate "gradually reduced" when filters were applied at 240 fps
  (https://developer.apple.com/forums/thread/60388) — keep the 240 fps path free of per-frame GPU work.

### Flicker and rolling shutter at 240 fps
- Mains lighting flickers at 100/120 Hz (2× mains) and PWM LEDs at their own rate; at 120/240 fps each frame samples a
  different phase, and with a rolling shutter the brightness varies *within* a frame as horizontal bands
  (https://forums.macrumors.com/threads/240fps-slow-motion-video-doesnt-work-right-under-florescent-lights.1783976/ ,
  https://www.geekinstructor.com/fix-flickering-iphone-slow-motion-videos/ ,
  https://divoom.com/blogs/setup-ideas/stop-led-display-flickering-on-camera). The usual fix — shutter = 1/60 or 1/120 s
  — is impossible at 240 fps (frame period is 1/240 s), so **flicker cannot be cancelled at 240 fps under 120 Hz light**;
  it can at 120 fps with a 1/120 s shutter (only in apps with manual shutter). Camera.app exposes no shutter control.
- Rolling shutter: CineD measured the iPhone 15 Pro at 4.7–5.3 ms (4K 25p, various lenses, "300Hz strobe" method)
  (https://www.cined.com/iphone-15-pro-lab-test-rolling-shutter-dynamic-range-and-exposure-latitude/). No 1080p240
  measurement exists (**UNVERIFIED**); readout must be ≤ 4.17 ms at 240 fps. For a ball moving ≈ 6 px/frame the
  top-to-bottom skew over a 48 px ball is ≈ 0.1 px (my estimate) — negligible; at 30 fps handheld it is not
  necessarily negligible (47 px/frame) but the readout time is the same, so skew ≈ 47 × (readout/frame period) — small
  if readout ≈ 5 ms of a 33 ms frame (≈ 7 px, my estimate) — the parabola fit sees it as a constant lateral bias.

**Recommendation for ArcLab:** import path: request `.original`, read the `AVURLAsset` frames with real PTS, compute
median and p95 PTS delta, store effective fps, and tier on it (≥ 200 fps effective → A). Capture path: use our own
AVFoundation session, never Camera.app, so we can set the format, lock exposure/focus/WB explicitly, and disable video
stabilization. Add a **flicker detector** (per-frame mean luminance oscillating at ~100/120 Hz) and a **rolling-band
detector** (row-mean luminance gradient) in the framing check; if flicker is strong, suggest 120 fps and normalise
per-row luminance before detection. Log the measured frame rate on every recording — do not trust the requested one.

---

## 6. Rim-anchored stabilization on-device

Vision offers (all iOS 18, Swift API; legacy `VN*` equivalents exist):
- `TrackTranslationalImageRegistrationRequest` (StatefulRequest + TargetedRequest) → `ImageTranslationAlignmentObservation`
  (https://developer.apple.com/documentation/vision/tracktranslationalimageregistrationrequest); the legacy form is what
  Action & Vision uses for its 10-point stability test (§1).
- `TrackHomographicImageRegistrationRequest` → `ImageHomographicAlignmentObservation.warpTransform`
  (https://developer.apple.com/documentation/vision/trackhomographicimageregistrationrequest ,
  https://developer.apple.com/documentation/vision/imagehomographicalignmentobservation).
- `TrackObjectRequest` (StatefulRequest, `init(detectedObject:_:frameAnalysisSpacing:)`) → `DetectedObjectObservation`
  (https://developer.apple.com/documentation/vision/trackobjectrequest). Legacy note: `trackingLevel` "has no effect on
  general purpose object tracker (VNTrackObjectRequest) revision 2" (Apple doc as quoted by search results;
  https://developer.apple.com/documentation/vision/vntrackingrequest/trackinglevel).
- `TrackOpticalFlowRequest` / `VNGenerateOpticalFlowRequest`: "very resource intensive, so perform only one request at a
  time"; revision 2 is ML-based (https://developer.apple.com/documentation/vision/trackopticalflowrequest ,
  https://developer.apple.com/documentation/vision/vngenerateopticalflowrequest).
- `DetectContoursRequest` for feature edges (https://developer.apple.com/documentation/vision/detectcontoursrequest).

Accuracy reports for handheld sports video: **none found** (searches returned patents, OpenCV tutorials and a 2018
forum thread on homographic registration difficulties, https://developer.apple.com/forums/thread/93548). The only
numeric datapoint is Apple's own "< 10 points summed over 15 frames = stable" heuristic (§1). **UNVERIFIED** beyond that.

Reasoning that matters more than the API choice: whole-frame registration is dominated by the largest textured region
(floor, crowd, the moving shooter), not by the rim; a global homography that is correct for the far wall is wrong for
the rim plane by parallax when the phone translates. Our geometry needs the *rim* to be fixed, and we already detect it
per frame (§4), so the rim ellipse (5 parameters) plus the backboard's straight edges give a per-frame similarity or
homography of the rim plane directly, with no image warping at all — apply it to ball centroids in `ShotGeometry`.

**Recommendation for ArcLab:** (1) Phase 3 import: per-frame rim ellipse + backboard-edge fit → per-frame transform
applied to detections; declare "stabilizable" only if the rim ellipse is found in ≥ 95 % of frames and its parameters
move smoothly. (2) Phase 4 capture: run `TrackTranslationalImageRegistrationRequest` on a down-scaled frame every
~100 ms as the live "camera moving" indicator, and rim-centre drift as the metric shown to the user (BRIEF Phase 4).
(3) Do not build on optical flow or `TrackObjectRequest` for this; the rim is a better feature than anything generic.

---

## 7. Monocular 3D body pose at 6–8 m

Apple:
- `DetectHumanBodyPose3DRequest`: 17 joints, "returns one skeleton for the most prominent person", lifts 2D to 3D; body
  height is "a more accurate measured height or a reference height of 1.8 meters" depending on depth metadata
  (`heightEstimation`); LiDAR depth improves scale (WWDC23 111241 transcript:
  https://developer.apple.com/videos/play/wwdc2023/111241/). Apple publishes **no accuracy or distance guidance**.
- Independent evaluation of Apple's *Vision* 3D pose: **none found** (**UNVERIFIED**). Nearest evidence: ARKit body
  tracking vs Vicon over eight body-weight exercises: weighted MAE **18.80° ± 12.12°** (range 3.75° to 47.06° per
  joint/exercise), Spearman 0.76; knee never reached full extension (min 22.77° vs 0°)
  (Reimer et al. 2021, https://www.researchgate.net/publication/351446785_Mobile_Motion_Tracking_for_Disease_Prevention_and_Rehabilitation_Using_Apple_ARKit).
  A Freiburg clinical study with an iPhone 12 Pro (ARKit + LiDAR) vs Captury found wrist-position differences with
  standard deviations up to ≈ 0.13–0.16 m, worst on the depth axis, and cites ≈ 120 ms tracking latency
  (https://arxiv.org/abs/2311.09716). These are ARKit numbers, not Vision's, and at short range.

Alternatives (licences from GitHub API 2026-09-13):
| Model | Licence | Notes |
|---|---|---|
| MediaPipe BlazePose GHUM — https://github.com/google-ai-edge/mediapipe | `Apache-2.0` | 33 landmarks + 3D; GHUM paper: MPJPE-PA 78 mm, MPJPE 121 mm (https://arxiv.org/abs/2206.11678). TFLite; Core ML port would be a conversion project (**UNVERIFIED**) |
| RTMPose — https://github.com/open-mmlab/mmpose (projects/rtmpose) | `Apache-2.0` | 2D top-down, 256×192 / 384×288 inputs; a dependency-free fork with Core ML demo scripts exists (https://github.com/Kinetix-ML/rtmlib-coreml; no iPhone timings published) |
| ViTPose — https://github.com/ViTAE-Transformer/ViTPose | `Apache-2.0` | 2D, transformer; no Core ML port found |
| MotionBERT — https://github.com/Walter0807/MotionBERT | `Apache-2.0` | 2D→3D lifter over a keypoint sequence; could sit on top of any 2D model; not converted to Core ML anywhere I found |

Validation numbers for phone-based markerless elbow angles in sport (all single-view or few-view, all far below our
5° gate):
- MediaPipe upper-limb vs optoelectronic reference: elbow flexion RMSE **14.0° (right) / 12.76° (left)**, ICC > 0.91;
  error worst when the two segment vectors are nearly colinear (max extension)
  (https://www.mdpi.com/2076-3417/16/3/1202).
- pitchAI (single smartphone, baseball pitching, 38 elite pitchers) vs marker-based: throwing arm r² 0.88 ± 0.03,
  **RMSE 12.3 ± 4.2°** (https://sportrxiv.org/index.php/server/preprint/view/101).
- OpenCap (2+ iPhones, 60 Hz typical): lower-limb grand mean 3.85° MAE / 4.34° RMSE; cricket bowling upper limb
  **RMSE 17.61 ± 7.72°** with only 56 % of trials usable; overhead-squat upper body RMSE 36.7 ± 35.79°
  (scoping review https://pmc.ncbi.nlm.nih.gov/articles/PMC13468529/ ; https://pubmed.ncbi.nlm.nih.gov/38905926/).
- Pose2Sim multi-camera: 3–4° mean joint-angle error in walking/running/cycling — shows what multi-view buys
  (https://www.ncbi.nlm.nih.gov/pmc/articles/PMC9002957/).
- Distance: no study quantifies keypoint error vs subject pixel height at 6–8 m (**UNVERIFIED**). My estimate: at
  7 m the forearm is ≈ 54 px; a 3–4 px keypoint error at each end gives ≈ 3–4° per keypoint on the elbow angle before
  any lifting error.

**Recommendation for ArcLab:** for Phase 5 use **2D** pose (`DetectHumanBodyPoseRequest`, 19 joints, multi-person —
needed for BRIEF §3 "select the skeleton whose wrist is nearest the ball") in the side-view azimuth class only, on the
240 fps stream with a short temporal median around the release frame; compute elbow angle in the image plane and
correct for the calibrated azimuth. Treat 3D (Apple or MotionBERT) as an experiment against the same 20-frame
protractor gate, not the default. Expect the 5° gate to be marginal; if it fails, report elbow angle as a
within-athlete *relative* metric with a stated ±10° absolute uncertainty rather than dropping it — that keeps the
variance thesis (BRIEF §6) intact. Any Core ML port of MediaPipe/RTMPose is a week of work with no published iPhone
accuracy to justify it yet.

---

## Top 10 pitfalls to avoid when the Phase 0 footage arrives

1. **Reading slo-mo through PhotoKit `.current`** — you get a 30 fps `AVComposition`, not the 240 fps file. Request
   `.original` and verify PTS deltas ≈ 4.17 ms (§5).
2. **Assuming 240 fps** — Camera.app on iPhone 12+ sometimes records 114–227 fps with jitter. Measure every clip's
   effective fps and dropped-frame pattern before judging the detector or the fitter (§5).
3. **Trusting `DetectTrajectoriesRequest` for size** — `movingAverageRadius` is one value per observation; there is no
   per-frame diameter, which Phase 1 requires (§2).
4. **Full-frame ROI on the trajectory request** — reported to produce nothing; window it and exclude the shooter's body
   box (§1, §2).
5. **Downscaling 1080p to a 416 px detector input** — the ball becomes ≈ 10 px; train and infer on crops/tiles (§3).
6. **Fitting the rim ellipse to all orange edges** — net, backboard edge, breakaway housing and the ball itself are in
   the mask; fit the top arc, reject lines, median over time, and mind inner vs outer diameter (§4).
7. **Global-frame stabilization** — registration follows the floor/crowd, not the rim plane; use the rim ellipse as the
   anchor and transform detections, not pixels (§6).
8. **Gym light flicker at 240 fps** — 120 Hz banding cannot be shuttered out at 240 fps; detect it, normalise luminance
   per row, and offer 120 fps (§5).
9. **Video stabilization / lens switching on the capture path** — EIS warps geometry and Camera.app may switch cameras;
   in our session set stabilization off and pin the device/format; in Camera.app footage expect it (§1, §5).
10. **Expecting 5° elbow angles from a single phone at 7 m** — published single-view upper-limb RMSE is 12–18°; design
    Phase 5 so the gate can fail without killing the product (§7).

## Phase 2 evaluation plan (what to run first, what numbers to record)

Prep (one afternoon): ingest every Phase 0 clip with `.original`; record per clip: resolution, median/p95 PTS delta,
number of PTS gaps > 1.5× median, camera position (side/45°/head-on), distance bucket, lighting notes, flicker
amplitude (peak-to-peak of per-frame mean luminance / mean), rolling-band amplitude. Hand-label ball centroid + diameter
on every 8th frame of 40 clips spread across positions/distances (≈ 3,000 boxes) — this is the ground truth for
everything below; also label the rim ellipse once per clip.

Run in this order, all on the same labelled frames, and record the same table for each detector:
1. **Zero-model baseline**: `DetectTrajectoriesRequest`, `trajectoryLength` ∈ {5, 8, 15}, `frameAnalysisSpacing`
   ∈ {0, 1/60, 1/30 s}, ROI = frame minus shooter box, min radius = 0.6 × expected. Record: recall of labelled
   frames below apex / final third (BRIEF Phase 2 targets 90 % / 75 %), centroid error (median, p90, px) vs labels,
   number of spurious trajectories per shot, first-result latency (frames after true release), whether
   `objectMaximumNormalizedRadius` takes effect, time per frame.
2. **Create ML transfer-learning detector on 640×640 tiles** (train on ~2,000 labelled crops + 20 % hard negatives:
   heads, orange shirts, rim). Record: recall below apex / final third, precision, centroid error, **diameter error
   (median, p90, px)** — must be ≤ 2 px centroid and ≈ 1 px diameter per the Phase 1 sensitivity — ms/frame on the
   iPhone 14 Pro, and the head-vs-ball false-positive rate before and after the RANSAC parabola gate (must be 0 after).
3. **WASB (MIT) converted to Core ML** at 288×512 on 3-frame stacks with local edge-fit diameter. Same table.
4. **Rim**: per-clip rim ellipse via §4 pipeline vs hand-labelled ellipse: centre error (px), axis errors, minor/major
   ratio, percentage of frames found, parameter jitter over time (px), and the implied camera pose vs the known tripod
   position.
5. **End-to-end sanity on 10 tripod 240 fps clips**: feed each detector's track to `ShotGeometry`; record `g_fit`
   (BRIEF Phase 3 target within 8 %), release angle, and the release-frame index vs a hand-picked release frame.
   Detector choice is whichever meets the recall targets *and* gives `g_fit` within 8 % on the most clips; ties go to
   the smaller model.

Numbers to write into `docs/PHASE2-REPORT.md`: the tables above per camera position and distance bucket, the effective
fps histogram of the Phase 0 set, and the flicker/band statistics — these decide the capture-path defaults in Phase 4.
