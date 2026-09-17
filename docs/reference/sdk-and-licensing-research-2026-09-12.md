# Research notes — iOS basketball shot-analysis app (Swift 6 / SwiftUI / iOS 26)

Date: 2026-09-12. No Xcode on this machine; Apple API facts were pulled from the JSON behind
developer.apple.com pages (`developer.apple.com/tutorials/data/documentation/<path>.json`) — the
cited human-readable URL is the same page. Anything I could not confirm is marked **UNVERIFIED**.

---

## 1. Vision framework — modern Swift API (iOS 18+) and iOS 26 changes

### (a) Trajectory detection
- Type: `final class DetectTrajectoriesRequest` — iOS 18.0 / macOS 15.0 / visionOS 2.0.
  Conforms to `ImageProcessingRequest`, `StatefulRequest`, `VisionRequest`, `Sendable`.
  https://developer.apple.com/documentation/vision/detecttrajectoriesrequest
- Init: `init(trajectoryLength: Int, _ revision: DetectTrajectoriesRequest.Revision? = nil, frameAnalysisSpacing: CMTime? = nil)`.
  Doc text: "`trajectoryLength` … must be at least 5"; "`frameAnalysisSpacing` … By default, Vision analyzes all frames."
  https://developer.apple.com/documentation/vision/detecttrajectoriesrequest/init(trajectorylength:_:frameanalysisspacing:)
- Config properties: `objectMinimumNormalizedRadius: Float`, `objectMaximumNormalizedRadius: Float`, `targetFrameTime: CMTime` (default indefinite = max accuracy; if set, Vision trades accuracy for time frame-to-frame), `let trajectoryLength: Int`.
  https://developer.apple.com/documentation/vision/detecttrajectoriesrequest/targetframetime
- Result: `struct TrajectoryObservation` with `detectedPoints: [NormalizedPoint]`, `projectedPoints`, `equationCoefficients`, `movingAverageRadius`; also `timeRange` via `VisionObservation`.
  https://developer.apple.com/documentation/vision/trajectoryobservation
- Only revision: `.revision1`. https://developer.apple.com/documentation/vision/detecttrajectoriesrequest/revision-swift.enum
- Legacy equivalent: `VNDetectTrajectoriesRequest` (iOS 14+, subclass of `VNStatefulRequest`). https://developer.apple.com/documentation/vision/vndetecttrajectoriesrequest

### (b) 2D body pose
- `struct DetectHumanBodyPoseRequest` (iOS 18) → `[HumanBodyPoseObservation]`. Config: `detectsHands`, `supportedJointNames`, `supportedJointsGroupNames`. Revision: `.revision2` only.
  https://developer.apple.com/documentation/vision/detecthumanbodyposerequest
- `struct HumanBodyPoseObservation` (conforms to `PoseProviding`): `allJoints(in:)`, `joint(for:)`, `availableJointNames`, `leftHand`/`rightHand` (`HumanHandPoseObservation`), `keypoints: MLMultiArray`.
  https://developer.apple.com/documentation/vision/humanbodyposeobservation
- Joint name type: `HumanBodyPoseObservation.JointName` (enum): leftAnkle, leftEar, leftElbow, leftEye, leftHip, leftKnee, leftShoulder, leftWrist, neck, nose, rightAnkle, rightEar, rightElbow, rightEye, rightHip, rightKnee, rightShoulder, rightWrist, root (19).
  https://developer.apple.com/documentation/vision/humanbodyposeobservation/jointname
- Each joint is `struct Joint` { `confidence`, `jointName`, `location` (normalized point), `distance(to:)` }.
  https://developer.apple.com/documentation/vision/joint
- `PoseProviding` protocol: https://developer.apple.com/documentation/vision/poseproviding
- Legacy: `VNDetectHumanBodyPoseRequest` / `VNHumanBodyPoseObservation.JointName`.
  https://developer.apple.com/documentation/vision/vnhumanbodyposeobservation/jointname

### (c) 3D body pose
- `final class DetectHumanBodyPose3DRequest` (iOS 18) — a **StatefulRequest**; `init(_ revision:, frameAnalysisSpacing:)`. "If the system allows it, the request uses AVDepthData information to improve the accuracy."
  https://developer.apple.com/documentation/vision/detecthumanbodypose3drequest
- `struct HumanBodyPose3DObservation`: `bodyHeight`, `cameraOriginMatrix`, `heightEstimationTechnique`, `joint(for:)`, `allJoints(in:)`, `cameraRelativePosition(for:)`, `pointInImage(for:)`, `parentJointName(for:)`.
  https://developer.apple.com/documentation/vision/humanbodypose3dobservation
- `HumanBodyPose3DObservation.JointName`: centerHead, centerShoulder, leftAnkle, leftElbow, leftHip, leftKnee, leftShoulder, leftWrist, rightAnkle, rightElbow, rightHip, rightKnee, rightShoulder, rightWrist, root, spine, topHead (17).
  https://developer.apple.com/documentation/vision/humanbodypose3dobservation/jointname

### (d) Core ML object detection through Vision
- `struct CoreMLRequest` (iOS 18): `init(model: CoreMLModelContainer, _ revision:)`; config `cropAndScaleAction: ImageCropAndScaleAction`, `modelContainer`.
  https://developer.apple.com/documentation/vision/coremlrequest
- `struct CoreMLModelContainer` — `init(model: MLModel, featureProvider:)`, `inputImageFeatureName`.
  https://developer.apple.com/documentation/vision/coremlmodelcontainer
- Result rules (doc): classifier → `ClassificationObservation`; image output → `PixelBufferObservation`; otherwise `CoreMLFeatureValueObservation`. "Vision forwards all confidence values from Core ML models as-is and doesn't normalize them to [0, 1]."
- `struct RecognizedObjectObservation` (iOS 18) exists: `labels: [ClassificationObservation]`, conforms to `BoundingBoxProviding`; "The confidence of the classifications sum up to 1.0. Multiply the classification confidence with the confidence of this observation."
  https://developer.apple.com/documentation/vision/recognizedobjectobservation
  **UNVERIFIED**: the CoreMLRequest page does not list `RecognizedObjectObservation` among its result types. In the legacy API, `VNCoreMLRequest` returns `VNRecognizedObjectObservation` for detector models that end in an NMS layer (e.g. Create ML output). Expect the same for `CoreMLRequest` (its results are `[any VisionObservation]` to be cast) but confirm in Xcode. Legacy page: https://developer.apple.com/documentation/vision/vnrecognizedobjectobservation

### (e) Performing on CVPixelBuffer / CMSampleBuffer (async)
`ImageProcessingRequest` (all requests above conform) provides:
```
func perform(on: CVPixelBuffer,  orientation: CGImagePropertyOrientation? = nil) async throws -> Self.Result
func perform(on: CMSampleBuffer, orientation: CGImagePropertyOrientation? = nil) async throws -> Self.Result
// also: URL, Data, CGImage, CIImage
```
https://developer.apple.com/documentation/vision/imageprocessingrequest
Multiple requests on one image: `ImageRequestHandler.perform(_:_:)` / `performAll(...)` (WWDC24 "Discover Swift enhancements in the Vision framework": "Vision will only introduce new features in Swift moving forward.")
https://developer.apple.com/videos/play/wwdc2024/10163/

### (f) Trajectory: stateful? frame requirements / limitations
- Yes — `DetectTrajectoriesRequest` conforms to `StatefulRequest` ("builds evidence of a condition over time"). Keep **one instance** and call `perform` on every frame. `StatefulRequest` exposes `frameAnalysisSpacing: CMTime` ("The request won't process buffers that fall within the frameAnalysisSpacing since the previously performed analysis. The analysis isn't done by wall time but by analysis of the time stamps of the sample buffers") and `minimumLatencyFrameCount: Int`.
  https://developer.apple.com/documentation/vision/statefulrequest
  https://developer.apple.com/documentation/vision/statefulrequest/frameanalysisspacing
- Apple's article "Identifying Trajectories in Video" (written for VN API, same algorithm):
  - "requires a stable scene, meaning the camera is mounted on a tripod, and the camera and background remain stationary. … Any camera movement introduces noise and motion blur, which reduces the accuracy of the detection."
  - "A single object may produce multiple trajectories. For example, a bouncing ball forms a new trajectory with each bounce."
  - "The minimum number [trajectory length] is 5"; results are only delivered "until the result has at least one trajectory with a high confidence score and a trajectory length matching the requested length."
  - "requires using CMSampleBuffer objects that contain timestamps so it can correctly calculate the trajectory observation's time range." → feed `CMSampleBuffer` (or pixel buffers with proper timing — the CMSampleBuffer overload is the safe path).
  - Resolution guidance: "For small objects, like a tennis or cricket ball, you may need 1080p… soccer ball, may require only VGA."
  - No explicit frame-rate requirement is documented; `frameAnalysisSpacing` is the throttle. **UNVERIFIED**: behaviour at 240 fps (Apple gives no max/min fps).
  https://developer.apple.com/documentation/vision/identifying-trajectories-in-video

### iOS 26 Vision changes (WWDC25 "Read documents using the Vision framework")
- New `struct RecognizeDocumentsRequest` → `DocumentObservation` (iOS 26). https://developer.apple.com/documentation/vision/recognizedocumentsrequest
- New `struct DetectLensSmudgeRequest` → `SmudgeObservation` (iOS 26; "requires a device with A14 Bionic and later"). https://developer.apple.com/documentation/vision/detectlenssmudgerequest
- Hand-pose model replaced with a smaller/faster model ("Still detects 21 joints… New joint locations require retraining existing ML hand pose and hand action classifiers"). https://developer.apple.com/videos/play/wwdc2025/272/
  Note: `DetectHumanHandPoseRequest.Revision` doc still lists only `revision1` (forum report of the mismatch, unanswered): https://developer.apple.com/forums/thread/803595
- Nothing new for trajectory, body pose or CoreMLRequest in iOS 26 (their doc pages show iOS 18.0 introduction and no 26.0 additions).

---

## 2. AVFoundation — high-frame-rate capture and imported video

### Selecting a 240 fps format
- Formats are enumerated per device at runtime: `AVCaptureDevice.formats: [AVCaptureDevice.Format]`; each format has `videoSupportedFrameRateRanges: [AVFrameRateRange]` and `formatDescription` (for dimensions). Apple does not publish a static table of which formats do 1080p240 — you must filter at runtime (dimensions == 1920x1080 && `range.maxFrameRate >= 240`).
  https://developer.apple.com/documentation/avfoundation/avcapturedevice/formats
  https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/videosupportedframerateranges
  https://developer.apple.com/documentation/avfoundation/avframeraterange/maxframerate (`var maxFrameRate: Float64`)
  `AVFrameRateRange.minFrameDuration` "is the reciprocal of maxFrameRate": https://developer.apple.com/documentation/avfoundation/avframeraterange/minframeduration
- Apply it: `lockForConfiguration()`, set `activeFormat`, then `activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration` (= CMTime(1, 240)); wrap in `session.beginConfiguration()/commitConfiguration()`. Setting `activeFormat` flips the session preset to `.inputPriority`. Setting a duration not in the active format's ranges throws `invalidArgumentException`.
  https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeformat
  https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideominframeduration
- Caveat (Apple): "If you configure a session to use an active format intended for high resolution still photography, and you apply zoom, orientation, or format changes to an AVCaptureVideoDataOutput, the system may not meet the target framerate." (same activeFormat page). Also `isVideoBinned` formats exist. https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/isvideobinned

### Frame timestamps
- `CMSampleBuffer.presentationTimeStamp: CMTime` (Swift property, iOS 13+). Legacy C: `CMSampleBufferGetPresentationTimeStamp`.
  https://developer.apple.com/documentation/coremedia/cmsamplebuffer/presentationtimestamp
- Stateful Vision requests key off these timestamps (see §1f).

### Is 1080p240 available on iPhone 15/16/17 rear cameras? Yes (Apple tech specs)
- iPhone 15: "Slo-mo video support for 1080p at 120 fps or 240 fps". https://support.apple.com/en-us/111831
- iPhone 16: "Slo-mo video support for 1080p at 120 fps or 240 fps". https://support.apple.com/en-us/121029
- iPhone 17: "Slo-mo video support for 1080p at 120 fps or 240 fps" (4K max 60 fps). https://www.apple.com/iphone-17/specs/
- iPhone 17 Pro: "Slo-mo video support for 1080p up to 240 fps and 4K Dolby Vision up to 120 fps (Fusion Main)"; also 4K at 120 fps standard recording. https://support.apple.com/en-us/125090
- Which physical lens/`AVCaptureDevice.DeviceType` exposes the 240 fps format and whether third-party apps get the exact same format list as Camera.app: **UNVERIFIED** (must check `formats` on-device).

### Thermal state
- `ProcessInfo.processInfo.thermalState` → `.nominal/.fair/.serious/.critical`. `.serious`: "Reduce the target framerate from 60 FPS to 30 FPS… Reduce CPU and GPU usage". `.critical`: "If possible, stop using peripherals such as the camera". Observe `ProcessInfo.thermalStateDidChangeNotification`.
  https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property
  https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/serious
  https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/critical

### Reading an imported video at full rate with real per-frame timestamps
- `AVAssetReader(asset:)` + `AVAssetReaderTrackOutput(track:outputSettings:)` (use `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`/`VideoRange` for H.264/HEVC — Apple's stated optimal formats), `startReading()`, then loop `copyNextSampleBuffer()`; each returned `CMSampleBuffer` carries its own `presentationTimeStamp`, which is the actual per-frame time (decoded samples come back "in presentation order").
  https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput
  https://developer.apple.com/documentation/avfoundation/avassetreaderoutput/copynextsamplebuffer()
- **iOS 26 change**: `copyNextSampleBuffer()` is marked deprecated as of iOS/macOS 27.0 in the docs; the replacement is `AVAssetReaderOutput.Provider<Payload>` with `func next() async throws -> Payload?` (iOS 26.0+). Since you target iOS 26, use the Provider API.
  https://developer.apple.com/documentation/avfoundation/avassetreaderoutput/provider
  https://developer.apple.com/documentation/avfoundation/avassetreaderoutput/provider/next()
- Set `alwaysCopiesSampleData = false` if you don't mutate buffers (Apple note on AVAssetReaderOutput page). https://developer.apple.com/documentation/avfoundation/avassetreaderoutput
- Do **not** trust `AVAssetTrack.nominalFrameRate`/`minFrameDuration` for VFR or Slo-mo: (a) both are deprecated as of iOS 16 in favour of async `load(...)`; (b) a developer report shows `load(.nominalFrameRate)` returning ~30 for a 239.68 fps Slo-mo clip and duration 8x longer (the file has a slow-motion edit list/time mapping), unanswered by Apple.
  https://developer.apple.com/documentation/avfoundation/avassettrack/nominalframerate
  https://developer.apple.com/forums/thread/731460
  Practical rule: derive fps from consecutive `presentationTimeStamp` deltas of the decoded samples; treat deltas as variable. Reading with `outputSettings: nil` "preserves the timing and format of the source frames" but returns compressed samples in decode order (Apple copyNextSampleBuffer doc).

---

## 3. iOS install base (as of 2026-09) and deployment-target recommendation

- Apple official (App Store transactions, **June 7, 2026**): iOS 26 on **86%** of iPhones introduced in the last four years and **79%** of all iPhones; iPadOS 26: 79% / 68%.
  https://developer.apple.com/support/app-store/
  Press breakdown of the same data: ~14% iOS 18, ~7% earlier (all iPhones). https://www.macrumors.com/2026/06/09/ios-26-adoption-stats-wwdc/
  Year-earlier comparison: iOS 18 was 88% / 82% on June 5, 2025. https://appleinsider.com/articles/26/06/10/fewer-iphone-users-are-updating-to-ios-26-than-they-did-with-ios-18
  Feb 12, 2026 snapshot: iOS 26 74% (last-4-years) / 66% (all). https://9to5mac.com/2026/02/13/apple-announces-ios-26-usage-numbers-heres-how-they-compare/
- Third-party (TelemetryDeck, updated 2026-09-01, skews to small indie apps, US/EU): iOS 26 86.57%, iOS 18 7.87%, iOS 27 (beta) 3.29%.
  https://telemetrydeck.com/survey/apple/iOS/majorSystemVersions/
- StatCounter/Mixpanel: not consulted (**UNVERIFIED**).
- iOS 27 ships ~Sept 2026 (typical cadence; not verified). By early 2027 the installed base will look like today's minus one version: iOS 27 majority, iOS 26 large minority, iOS 18 single digits.

**Recommendation: minimum deployment target iOS 26.0.** Rationale: Vision's Swift API is iOS 18+, but `AVAssetReaderOutput.Provider`, `DetectLensSmudgeRequest` and the newest hand-pose model are iOS 26+; iOS 26 already covers ~79–87% of iPhones today and will be >90% by launch; the capture feature also needs recent hardware anyway. Going to iOS 18 buys ≈7–14% of devices at the cost of dual code paths for AVAssetReader. If the product must support iOS 18, keep the Vision code on the iOS 18 API (it is unchanged) and gate only the reader.

---

## 4. XcodeGen vs Tuist (2026)

| | XcodeGen | Tuist |
|---|---|---|
| Latest release | 2.46.0 (2026-07-16) — Swift package `traits` support, XcodeProj 9.14.0. https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0 | CLI 4.208.0 (2026-09-11); very frequent releases. https://github.com/tuist/tuist/releases/tag/4.208.0 |
| Repo activity | pushed 2026-07-16, not archived, MIT (GitHub API) | pushed 2026-09-12, not archived; licence MIT for most of repo, `server/` separate, `kura/` AGPL-3.0. https://github.com/tuist/tuist/blob/main/LICENSE.md |
| Config | YAML/JSON `project.yml` | Swift `Project.swift` manifests |
| Install | single binary (brew/mint) | `mise` recommended; generation works locally, no account required for `tuist generate`. https://tuist.dev/en/docs/guides/quick-start/install-tuist |
| Xcode 26 | Works; one open issue about `supportedDestinations`+`deploymentTarget` defaulting to 26 under Xcode 26 (opened 2025-08-15). https://github.com/yonaskolb/XcodeGen/issues/1577 | Tuist/XcodeProj added Xcode 26 items (e.g. `dstSubfolder`). https://github.com/tuist/xcodeproj/blob/main/CHANGELOG.md ; Bitrise stacks preinstall Tuist 4.50+ with Xcode 26. https://bitrise.io/blog/post/xcode-26-is-coming-with-major-stack-updates |
| Swift 6 | Explicit "Swift 6"/"Xcode 26" statements: **UNVERIFIED** for both projects (release notes don't say; both are actively released against current Xcode). | same |

**Recommendation: XcodeGen.** For one developer, one app target, one local Swift package, a 30-line `project.yml` is lighter than a Swift manifest + mise + Tuist's cache/insights surface. XcodeGen's slower cadence (community-maintained; https://xcodegen.com/is-xcodegen-still-actively-maintained/) is acceptable because the generated project format is stable. Pick Tuist only if you want modular caching/`tuist test` selective testing later.

---

## 5. Ball detection

### (a) Create ML object detection
- API: `MLObjectDetector` with `ModelParameters.algorithm` = `.darknetYolo` (full network; "Use this algorithm when your training dataset has a significant number of examples") or `.transferLearning(.objectPrint(revision: 1))`.
  https://developer.apple.com/documentation/createml/mlobjectdetector/modelparameters-swift.struct/modelalgorithmtype
  https://developer.apple.com/documentation/createml/mlobjectdetector/modelparameters-swift.struct/modelalgorithmtype/transferlearning(_:)
- Base model: Apple describes it only as "a general purpose model built into the operating system"; the feature extractor enum case is `objectPrint(revision:)` ("A feature extractor you use with a transfer-learning algorithm for object detectors"). The exact architecture is not published (**UNVERIFIED**). Transfer-learning models are small because the backbone lives in the OS (hence they need iOS 14+ at runtime — Apple's Tech Talk "Improve Object Detection models in Create ML", https://developer.apple.com/videos/play/tech-talks/10155/ ; the iOS 14 requirement and "~80 images per class" guidance are quoted second-hand at https://blog.roboflow.com/createml/).
  https://developer.apple.com/documentation/createml/mlobjectdetector/modelparameters-swift.struct/featureextractortype/objectprint(revision:)
- Data format: images + JSON annotations (`imagefilename`, `annotation[{coordinates{x,y,width,height}, label}]`), pixel or normalized units, default top-left origin / center anchor.
  https://developer.apple.com/documentation/createml/building-an-object-detector-data-source
- Licence to ship: the Xcode and Apple SDKs Agreement (https://www.apple.com/legal/sla/docs/xcode.pdf) contains no clause mentioning Create ML, machine learning or trained models (grep of the 16-page PDF: zero hits); the model you train is your own output and is shipped like any other app asset under the Apple Developer Program License Agreement. No restriction on closed-source commercial distribution found. (Not legal advice; **UNVERIFIED** beyond absence of any such clause.)
- Create ML `MLObjectDetector` runs on macOS only (doc: macOS 10.15+) — needs a Mac with Xcode. https://developer.apple.com/documentation/createml/mlobjectdetector

### (b) Permissively licensed pretrained detectors (GitHub API licence field, checked 2026-09-12)
| Model / repo | Licence | Notes |
|---|---|---|
| RT-DETR — lyuwenyu/RT-DETR | Apache-2.0 | active (pushed 2026-09-07). https://github.com/lyuwenyu/RT-DETR |
| RF-DETR — roboflow/rf-detr | Apache-2.0 | v1.10.1 (2026-09-07); DINOv2 backbone. https://github.com/roboflow/rf-detr |
| YOLOX — Megvii-BaseDetection/YOLOX | Apache-2.0 | last push 2025-06; still widely used, has official CoreML/ONNX export. https://github.com/Megvii-BaseDetection/YOLOX |
| DETR — facebookresearch/detr | Apache-2.0 | repo archived (2024). https://github.com/facebookresearch/detr |
| MobileNet-SSD — tensorflow/models (research/object_detection) | Apache-2.0 (LICENSE file header "Copyright 2022 Google LLC… Apache") | https://github.com/tensorflow/models/blob/master/LICENSE ; Caffe port chuanqi305/MobileNet-SSD is MIT https://github.com/chuanqi305/MobileNet-SSD |
| PaddleDetection (PP-YOLOE, RT-DETR paddle) | Apache-2.0 | https://github.com/PaddlePaddle/PaddleDetection |
| **YOLO-NAS** — Deci-AI/super-gradients | Code Apache-2.0, but **pretrained weights are under a proprietary non-commercial licence**: "may not use the Software for any commercial use, including in connection with any models used in a production environment". Avoid. https://github.com/Deci-AI/super-gradients/blob/master/LICENSE.YOLONAS.md |
| **Ultralytics YOLOv8 / YOLO11 / YOLO26** | **AGPL-3.0** (GitHub API licence = AGPL-3.0; Ultralytics: "All Ultralytics YOLO trained models fall under the AGPL-3.0 License by default"; Enterprise licence required for closed-source apps). https://github.com/ultralytics/ultralytics , https://www.ultralytics.com/license |
Conversion to Core ML: Apple coremltools (BSD-3) — https://github.com/apple/coremltools . Model weights' licences are separate from code licences — check each checkpoint (e.g. RT-DETR/RF-DETR COCO/Objects365 weights are released by the same repos under Apache-2.0; **UNVERIFIED** per-file).

### (c) Public basketball datasets
- Roboflow Universe (pages return HTTP 403 to non-browser fetch; licences below are as shown in Roboflow's search listings, **verify in browser**):
  - "Basketball Players" (roboflow-universe-projects) — 1,196 imgs, classes incl. Ball/Player/Hoop — CC BY 4.0. https://universe.roboflow.com/roboflow-universe-projects/basketball-players-fy4c2
  - "Basketball detection" (computer-vision-d5fjh) — 4.9k imgs, person/ball/hoop — CC BY 4.0. https://universe.roboflow.com/computer-vision-d5fjh/basketball-detection-dn6fg
  - "basketball-players-detection" (kyles-workspace) — 3.8k imgs, Ball/Player/Ref — CC BY 4.0. https://universe.roboflow.com/kyles-workspace/basketball-players-detection-flths
  - "Basket Ball Tracking" (zeeshan-public-projects) — 1,978 imgs, ball/person — MIT. https://universe.roboflow.com/zeeshan-public-projects/basket-ball-tracking-xkyu5
  - "NBA Ball" — 2,000 ball imgs — MIT. https://universe.roboflow.com/basketball-llmyu/nba-ball
  - "Basketball Ball Segments From Shooting Videos" (ktu-magister) — 1,000 imgs. licence not shown. https://universe.roboflow.com/ktu-magister/basketball-ball-segments-from-shooting-videos
  - Browse: https://universe.roboflow.com/browse/sports/basketball
- SportsMOT (ICCV 2023; 240 clips, basketball/football/volleyball from NBA/NCAA/Olympics YouTube): **CC BY-NC 4.0** and redistribution needs written permission — not usable for a commercial model. https://github.com/MCG-NJU/SportsMOT
- Other candidates (not checked): DeepSportradar basketball datasets, SoccerNet-style sets — **UNVERIFIED**.

---

## 6. Official court/equipment dimensions (2025-26 / 2026 rulebooks)

| Item | NBA (2025-26 Official Playing Rules, Rule 1) | FIBA (Official Basketball Rules 2026 + Equipment 2026) | NCAA Men (2025-26 Rules Book) | NCAA Women (2025-26/26-27 Rules Book) | NFHS (Rule 1) |
|---|---|---|---|---|---|
| 3-pt arc | 23'9" from centre of basket; parallel lines 3' from sidelines (→ 22' in corners) | 6.75 m radius; parallel lines 0.90 m from sideline inner edge; basket centre 1.575 m from endline | 22' 1¾" (outside edge); 21' 7⅞" in corners | same as men: 22' 1¾"; 21' 7⅞" corners | 19' 9" radius, 2" line, semicircle (no corner straight-line rule) |
| FT line → backboard face | 15' from plane of face | 5.80 m from endline inner edge; backboard face 1.20 m from endline → 4.60 m | 15' from plane of face | 15' | 15' |
| Rim height | 10' | 3,050 mm (±6 mm) top edge | 10' | 10' | 10' |
| Rim inside diameter | 18" | 450–459 mm | 18" | 18" | 18" (NFHS text via secondary source) |
| Ring → backboard | 6" nearest inside edge | 151 mm (±2) | 6" | 6" | 6" |
| Backboard | 6' × 3½' | 1,800 (+30) × 1,050 (+20) mm | 6'×3½' or 6'×4' (3½' recommended) | (same rule text expected; UNVERIFIED) | rectangular or fan (dims not verified) |
| Ball | "officially approved NBA ball", 7½–8½ psi; circumference not in rulebook (**UNVERIFIED**; commonly 29.5") | Size 7: 750–770 mm circumference, 580–620 g; Size 6: 715–730 mm, 510–550 g; men size 7, women size 6 | 29½–30", 20–22 oz | 28½–29", 18–20 oz | Boys 29½–30", 20–22 oz; Girls 28½–29", 18–20 oz |

Sources:
- NBA: https://official.nba.com/rule-no-1-court-dimensions-equipment/ (PDF: https://cdn.nba.com/manage/2026/01/Official-2025-26-NBA-Playing-Rules.pdf — Rule 1 §I(d), §II(a),(d),(e),(f))
- FIBA rules 2026 v1.1 (Art. 2.5.3, 2.5.4): https://assets.fiba.basketball/image/upload/documents-corporate-fiba-official-rules-2026-v1-1.pdf
- FIBA Basketball Equipment 2026 v1.0 (§1.1.3, 1.1.8, 1.2.1, 1.2.4, 1.2.5, Table 1): https://assets.fiba.basketball/image/upload/documents-corporate-fiba-official-rules-2026-equipment-v1-0.pdf
- NCAA Men 2025-26 Rules Book (Rule 1 §6 Art.5, §7 Art.1, §11 Art.2, §14 Art.1, §15 Art.2, §16 Art.8-9): https://www.naia.org/wp-content/uploads/2026/05/2025-26_Men-s_Basketball_Rules_Book-BR26.pdf ; official listing https://ncaapublications.com/products/2025-26-mens-basketball-rules-book
- NCAA Men's & Women's court diagram 2025-26 (22'1¾", 21'7⅜"… note diagram prints 21'7⅜" while rule text says 21'7⅞" — use rule text): https://ncaaorg.s3.amazonaws.com/championships/sports/basketball/rules/common/PRXBB_CourtDiagram.pdf
- NCAA Women 2025-27 Rules Book (Rule 1 §7 Art.1, §14 Art.1, §16 Art.8-9): https://www.nysgboa.com/wp-content/uploads/2025/09/Womens-Basketball-Rules-2025-2027.pdf ; official listing https://ncaapublications.com/products/2025-26-and-2026-27-ncaa-womens-basketball-rules-book
- NFHS Rule 1 (§4 Art.1, §6, §11 Art.1, §12 Art.1) — transcribed by an officials' chapter (secondary; NFHS rulebook itself is paywalled): https://abilenebasketballrefs.com/nfhs-rules-book/nfhs-rules-book-rule-1-court-and-equipment/ ; NFHS rules hub https://nfhs.org/sports/basketball/rules
- Derived: ball diameter = circumference/π → size 7 ≈ 23.9–24.5 cm (FIBA 750–770 mm) / 29.5–30" → 23.9–24.3 cm; size 6 ≈ 22.8–23.2 cm (FIBA) / 28.5–29" → 23.0–23.4 cm.

---

## 7. `swift test` on macOS with Command Line Tools only (Swift 6.3.2 / CLT 26.5) — tested on this machine

Environment: `xcode-select -p` = /Library/Developer/CommandLineTools; `swift --version` = Apple Swift 6.3.2 (swiftlang-6.3.2.1.108), SDK MacOSX26.5.

Empirical results (pure-Swift package, `swift-tools-version: 6.0`):
1. `swift test` with an **XCTest** target → `error: no such module 'XCTest'`. No `XCTest.framework` exists anywhere under /Library/Developer/CommandLineTools (find returned nothing). **XCTest does not work CLT-only.** (Matches long-standing reports: https://forums.swift.org/t/error-xctest-not-available/62353 , https://github.com/exercism/swift/issues/358)
2. `swift test` with a **Swift Testing** target, no flags → `error: no such module 'Testing'`, even though CLT ships `/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework` and `/Library/Developer/CommandLineTools/Library/Developer/usr/lib/lib_TestingInterop.dylib`. SwiftPM in CLT doesn't add those search paths (Apple's Stuart Montgomery: "The version of SwiftPM in CommandLineTools does not yet have this change… which configures the necessary search paths to locate Testing.framework" — https://forums.swift.org/t/error-no-such-module-testing/74784).
3. **Works** — Swift Testing only, with explicit paths **and** `platforms: [.macOS(.v14)]` in Package.swift (without a platforms entry the `@Test` macro expansion fails with "'isolation()' is only available in macOS 10.15 or newer"):
   ```
   FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
   LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
   swift test --disable-xctest \
     -Xswiftc -F -Xswiftc $FW \
     -Xlinker -F -Xlinker $FW -Xlinker -rpath -Xlinker $FW \
     -Xlinker -L -Xlinker $LIB -Xlinker -rpath -Xlinker $LIB
   ```
   Output: "Testing Library Version: 1902 … ✔ Test run with 1 test in 0 suites passed".
   Any XCTest file in the test target still breaks the build, so keep the package Swift-Testing-only (or `#if canImport(XCTest)`).

Gotchas:
- Related open SwiftPM issue on CLT-only builds involving swift-testing/`CompilerPluginSupport` (2024, still open): https://github.com/swiftlang/swift-package-manager/issues/7306
- Swift Testing overview (Swift 6.0 / Xcode 16+): https://developer.apple.com/documentation/testing
- Cleaner alternatives: install a Swift.org toolchain (`swiftly`), or install Xcode and `xcode-select -s /Applications/Xcode.app`; both give `swift test` with XCTest + Swift Testing without flags (forum thread above).
- iOS-only code (UIKit/SwiftUI-on-iOS, AVFoundation capture) cannot be tested by `swift test` on macOS at all — keep pure logic (trajectory maths, court geometry, shot classification) in the local package with `#if canImport(...)` guards, and run iOS tests in Xcode/CI.
