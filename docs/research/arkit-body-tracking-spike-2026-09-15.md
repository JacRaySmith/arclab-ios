# ARKit body-tracking spike (2026-09-15)

**Question.** Can `ARBodyTrackingConfiguration` on the iPhone 14 Pro (iOS 26.6.2) give a *metric* 3-D skeleton
of a shooting motion with no rim and no stated height? **Status: built, not yet measured on the phone.** Nothing
below claims a detection rate, a joint count or a scale; the screen exists to measure them.

## What is known (Apple documentation, not measured here)

- Rear camera only; A12 or later; ARKit owns the camera, so it **cannot run together with the 240 fps AVCapture
  session** (`CaptureView`). A form clip from ARKit is a separate take at the ARKit format's rate (60 fps formats
  are offered; the screen picks the highest-fps, then widest, `supportedVideoFormats` entry and logs the choice).
- `ARSkeleton3D` has `ARSkeletonDefinition.defaultBody3D.jointCount` joints (documentation says 91; the screen
  reads the count from the SDK and shows "n / total tracked"). Only a subset is *tracked* (`isJointTracked`);
  the rest are rig positions. `jointModelTransforms` are relative to the `ARBodyAnchor`.
- Scale: `automaticSkeletonScaleEstimationEnabled` is **off by default** (scale stays 1.0); the spike turns it on
  and reads `ARBodyAnchor.estimatedScaleFactor`. Metric hypothesis, from Apple's BodyDetection sample (the
  character is scaled by the factor): **metres = model translation × estimatedScaleFactor, then the anchor
  transform**. The "× scale" toggle on the screen draws the skeleton both ways; the one that sits on the person
  is the right one.
- Bone lengths are the rig's lengths × one uniform scale (ARKit estimates joint *rotations* and a body scale, not
  per-bone lengths). The export marks every bone `prior: true` for that reason.
- No per-joint uncertainty is published; no 2-D points; no heels.
- **iOS 26 report (FB15128723):** Apple developer forums report `ARBodyAnchor` never appearing on iOS 26.x.
  Unverified for 26.6.2 — the screen logs `arbody.body.first` (seconds to the first anchor) or, if none ever
  comes, the readout stays at "First body: none after N s" and `arbody.end` carries `firstBodySeenAfter: null`.

## What the screen does

Home → "Step-by-step tools" → **AR body capture (experiment)** (`App/Sources/ARFormCaptureView.swift`,
`ARFormCaptureController.swift`). Landscape. Checks `isSupported` (says so if false; the Simulator degrades to a
message). Camera view with the projected skeleton (filled dot = tracked joint, hollow = rig-only; orange bone =
both ends tracked). Readout: format, body detected yes/no (+ `isTracked`), tracked joints / total, scale factor,
body-anchor updates/s, frames/s, seconds to the first body. Record writes every `ARFrame` (detected or not):

- `Documents/ArcLab/arbody/<date>.json` — raw log: joint names, parent indices, intrinsics, video fps, and per
  frame `t`, `hasBody`, `isTracked`, `scale`, `anchorTransform` (16 floats), `joints` {ARKit name → model
  transform, tracked joints only}.
- `Documents/ArcLab/arbody/<date>.bodyshot.json` — BodyShot v1 (`docs/BIOMETRIC-SCHEMA.md`), verified by
  `BodyShot.decode` before it is written. `fitted3D` in the body frame (origin = hips in the first detected
  frame; z = world up; x = shooter facing from the shoulder line because there is no rim; y = z × x), metres by
  the hypothesis above, `seen` from `isJointTracked`, `skeleton.scaleProvenance = "arkit.estimatedScaleFactor"`,
  `scaleNote` with mean/min/max/spread of the factor. Phases, angles, events, summary: unavailable with reasons.
  `timing.releaseRealTime` is a non-optional Double in the schema, so it holds **−1 plus a warning** (schema gap
  to fix: it should be a `BodyShotMeasure`).
- ActivityLog `arbody.recorded`: frames, detectedFraction, meanTrackedJoints, scale/scaleMin/scaleMax/
  scaleSpreadPercent, seconds, fps, firstBodySeenAfter, both paths and byte counts (or the error).
  Also `arbody.start` (support, format list), `arbody.body.first`, `arbody.body.lost`, `arbody.end`.

## Joint mapping (ARKit `defaultBody3D` name → schema §1)

| ARKit | fitted3D key | seen key | note |
|---|---|---|---|
| hips_joint | root | root | body-frame origin |
| spine_7_joint | spine | spine | topmost spine joint; spine_4 would be nearer Vision's mid-spine — revisit with data |
| neck_1_joint | centerShoulder | neck | `SceneBodyJoints.seenKey` convention |
| head_joint | centerHead | nose | |
| left/right_eye_joint | leftEye / rightEye | same | |
| left/right_**arm**_joint | leftShoulder / rightShoulder | same | ARKit has `*_shoulder_1_joint` (clavicle root, next to spine_7) **and** `*_arm_joint` (humeral head). The brief said shoulder_1; the humeral head is the schema's shoulder, so `*_arm_joint` is used. The export's `notes` prints \|neck_1→left_arm\| and \|left_arm→left_forearm\| so the choice can be checked (expect ~0.15–0.2 m and ~0.3 m). |
| left/right_forearm_joint | leftElbow / rightElbow | same | |
| left/right_hand_joint | leftWrist / rightWrist | same | finger joints stay in the raw log |
| left/right_upLeg_joint | leftHip / rightHip | same | |
| left/right_leg_joint | leftKnee / rightKnee | same | |
| left/right_foot_joint | leftAnkle / rightAnkle | same | |
| left/right_toes_joint | leftFootIndex / rightFootIndex | same | **first source with toes**; `*_toesEnd_joint` (tip) is the alternative; no heel |

Any name missing from the device's rig is listed in the BodyShot `warnings` rather than silently dropped.

## How to test on the phone

1. Install a Release build on the iPhone 14 Pro; open Home → Step-by-step tools → AR body capture (experiment).
2. Stand the phone 3–4 m from the shooter, side-on (the form-clip station), full body in frame, good light.
3. Wait for "Body: yes" — note the seconds in "First body" (or that it never comes; give it 30 s and a walk
   across the frame). Toggle "× scale" and see which skeleton sits on the person.
4. Record, shoot 3 shots, stop. Repeat once with the shooter facing the camera.
5. Pull `Documents/ArcLab/arbody/` and `Documents/ArcLab/logs/activity-<day>.jsonl`
   (`xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier com.arclab.app ...`),
   and read the `arbody.*` lines.

## Decision rule

Adopt ARKit for the form clip if, over the recorded shots: body detected in **≥ 90 % of frames**, **≥ 20 tracked
joints** on average, and **estimatedScaleFactor stable within ±5 %** (`scaleSpreadPercent ≤ 10` across a take,
and consistent between takes). Also required: the scaled skeleton visibly fits the shooter (the metric
hypothesis), and a plausible shoulder-choice check in the export notes. If no `ARBodyAnchor` appears on iOS
26.6.2, record that as the FB15128723 outcome and stop here — the Vision + stated-height path stays.
