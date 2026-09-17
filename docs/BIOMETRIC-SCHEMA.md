# Biometric data schema v2 (2026-09-16)

The contract every body-tracking stage writes to and every consumer (coaching rules, the 3-D form viewer, a future
skeletal or mesh model) reads from. Rules: **a value is either measured or absent with a reason**; nothing is filled
in by symmetry or by a prior without being flagged as such; every quantity carries its units and its frame of
reference; the schema is versioned and additive (new fields never change old meanings).

**v2 (1.3, hands) is additive.** Everything v1 wrote is still there, spelled the same way. v2 adds
the hand plates — `BodyFrame.handTriangles`, `BodyShot.hands`, the appendage 2-D points, and an
optional `provenance` string on any 2-D point. The reader accepts **both** versions
(`BodyShotSchema.readableVersions = [1, 2]`); a v1 file decodes with every new key nil, and
`BodyShotExportTests.testVersionOneStillDecodes` holds that to a test so the shots already on the
phone are never stranded.

## 1. Joint set

Names are the union of what Vision 2-D (19 points), Vision 3-D (17 joints) and MediaPipe (33 landmarks) can provide,
so a landmark never has to be renamed when the source changes. Left/right are the **shooter's** left/right.

| group | joints | 2-D source | 3-D source | notes |
|---|---|---|---|---|
| head | nose, leftEye, rightEye, leftEar, rightEar, topHead, centerHead | Vision 2-D | Vision 3-D (top/centre) | head yaw/pitch from eyes/ears/nose (validity ±60°) |
| neck / spine | neck, centerShoulder, spine, root (mid-hip) | Vision 2-D neck | Vision 3-D | trunk lean from root→centerShoulder |
| shoulders | leftShoulder, rightShoulder | both | both | shoulder-line yaw only when both are seen |
| arms | leftElbow, rightElbow, leftWrist, rightWrist | both | both | fitted angles come from the skeleton fit, not raw 3-D |
| hands | 21 landmarks × 2 (wrist, thumb 4, index 4, middle 4, ring 4, little 4) | Vision hand | — | shooting vs guide hand decided by the ball track |
| hand plate (v2) | leftIndexMCP, rightIndexMCP, leftLittleMCP, rightLittleMCP, leftHandWrist, rightHandWrist | Vision hand, lifted into the body name space by `HandPoints.lift` | `HandTriangleFit` (orientation fitted, **size a prior**) | the plate's two front corners plus the hand detector's own wrist; `…HandWrist` is kept beside `…Wrist` so two detectors never overwrite one another |
| hips | leftHip, rightHip | both | both | Vision holds the pelvis rigid: hip-line yaw is unobservable |
| legs | leftKnee, rightKnee, leftAnkle, rightAnkle | both | both | feet are often at the frame bottom: clipping gate |
| feet | leftHeel, rightHeel, leftFootIndex (toe), rightFootIndex | MediaPipe only | MediaPipe world | **absent from Vision**: foot direction is nil with reason "no toe landmark" |

## 2. Per-frame record (`BodyFrame`)

```
t_file      s   file timestamp            t_real  s   real time (t_file ÷ timeScale)
points2D    { joint: {u, v, confidence} } image pixels, top-left origin, full frame (never the crop)
joints3D    { joint: {x, y, z, confidence?} } metres, camera frame (x right, y down, z forward) — raw Vision 3-D
fitted3D    { joint: {x, y, z, sigma?} }  metres or unit-height (see scale), body frame (§4) — skeleton fit output
hands       { left|right: [21 × {u, v, confidence}] } image pixels; `role`: shooting | guide | unknown
seen        { joint: true|false }          observed in this frame vs interpolated/inferred
crop        {x, y, w, h}                   the crop the requests ran on (fixed size within a shot)

handTriangles (v2, optional)   [ {side, role, wrist, indexMCP?, littleMCP?, palmNormal?, pointing?,
                                  roll: BodyMeasure, pointsUsed: 2|3, wristProvenance,
                                  interpolated: [landmark], clamped: [landmark],
                                  reprojectionPixels, breadthResidual} ]
```

`points2D[joint].provenance` (v2, optional) says how a point came to be there when it is not simply what the detector
that owns the name returned. Three values are written today, all by `HandPoints.lift`:
`"Vision hand pose, <landmark>; sided by …"`, `"wrist from hand pose (…)"` (the hand detector's wrist standing in for a
body-pose wrist the body detector did not return — a second observation, not an inference), and
`"interpolated across one sampled frame (… ms …); not an observation"`. Absent means "the detector returned it".

**The `seen` floor differs by detector.** A body point counts as seen at confidence ≥ 0.30; an **appendage** point at
≥ 0.20 (`BodyShotOptions.minimumHandLandmarkConfidence`). Measured over 1351 hand observations in the 37-shot
free-throw session, Vision's hand-landmark confidences run at a median of 0.31 at the wrist and 0.50 at the MCPs
against 0.9+ for a shoulder, so one floor for both would throw away half of every hand.

`handTriangles[].pointsUsed` is the honesty gate: **3** = wrist and both knuckles were confident, so the plate has an
orientation, a palm normal and a roll; **2** = wrist and one knuckle, which fixes a direction and *not* a roll —
`roll` and `palmNormal` are then absent with that reason. Below 2 there is no entry at all.

## 3. Per-shot record (`BodyShot`, one per analysed window)

```
version                 2  (1 still reads)
source                  { app | cli, build, device, format {w, h, fps, hfovDegrees, provenance: sidecar | assumed | gravity-calibrated} }
timing                  { releaseRealTime, set, dip, followThroughPeak (s, real); quantisationFloor = 1/fps }
frames                  [BodyFrame]         every processed frame (the app samples every Nth at high frame rates; N recorded)
skeleton                { boneLengths (m or unit), scaleProvenance: statedHeight | unitHeight, symmetricPrior: bool }
angles                  { elbow L/R, knee L/R, shoulderElevation L/R, hip L/R, ankle L/R, wristFlexion (shooting), trunkLean, neckFlexion, headYaw, headPitch : [ {t_real, radians, sigma?} ] }
events                  { kineticChain: [ {joint, peakVelocityTime, peakVelocity} ] ordered; lagsMs with floor }
summary                 { jumpHeight, dipDepth, stanceWidth, stanceStagger, hipDrift, headStability, handRateAtRelease : BodyMeasure }
seenFractions           { joint: 0…1 }
symmetryInferred        [ joint ]           joints the viewer must draw as inferred, never solid
warnings                [ String ]          e.g. "shooter pixel height 275 px: metres excluded from pooling"

hands (v2, optional)    { sizePrior { isPopulationPrior: true, breadthFractionOfStature, palmLengthFractionOfStature,
                                      breadth, palmLength, wristToMCP, stature, statureProvenance, note },
                          shootingSide, plateFraction {side: 0…1}, orientedFraction {side: 0…1},
                          palmToRimBearingAtRelease, palmToVerticalAtRelease, pointingToVerticalAtRelease,
                          rollAtRelease, wristFlexionAtRelease, wristFlexionChangeThroughRelease,
                          wristFlexionRangeThroughRelease, wristFlexionFramesThroughRelease,
                          guideContactPlaneToShotPlane, guideContactPlaneToVertical, guideLastContactRealTime,
                          notes }
```

`BodyMeasure` = `{ value, unit, sigma?, provenance } | { unavailableReason }`.

### 3.1 The hand plate's size is a prior, and says so

`hands.sizePrior.isPopulationPrior` is always `true`. A single camera cannot measure a hand 20 px across, so the
plate's **size** is borrowed and only its **orientation** is fitted:

- hand breadth across the metacarpals **0.049 × stature** (range 0.048–0.050): Pheasant, *Bodyspace: Anthropometry,
  Ergonomics and the Design of Work*, 2nd ed., Table 2 — male 87 mm / 1740 mm (0.0500 H), female 76 mm / 1610 mm
  (0.0472 H); NASA RP-1024, *Anthropometric Source Book* vol. II (1978), USAF male 90 mm / 1755 mm (0.0513 H).
- palm length (wrist crease → the MCP row) **0.058 × stature**: hand length 0.108 H (Drillis & Contini, reproduced in
  Winter) × the 0.54 palm fraction of Pheasant Table 2.
- the triangle is taken as **isoceles** about the wrist — the index MCP is really a few millimetres further out, which
  is under 4 % of the palm length and far inside what two view rays through a 40 px hand separate.

Anything derived from the plate inherits that provenance. `breadthResidual` (‖index − little‖ ÷ the prior's breadth
− 1) is the file's own check on it: a median of −18 % over the 37-shot phone session, ≈ −2 to −4 px on a hand that is
about 18 px across, i.e. inside the landmark noise.

### 3.2 What the plate measures

| field | definition | refused when |
|---|---|---|
| `palmToVerticalAtRelease` | angle between the palm normal and camera-up | fewer than 3 confident points at the release |
| `palmToRimBearingAtRelease` | palm normal against the rim's **bearing** (the camera's horizontal toward the rim's image column — a bearing, never a depth) | no rim column, or no plate |
| `pointingToVerticalAtRelease` | wrist → mid-MCP against camera-up | no plate |
| `rollAtRelease` | rotation of the palm normal about the pointing axis from the upward reference; + by the right-hand rule | 2 points, or the hand points within ~9° of the reference axis |
| `wristFlexionAtRelease` | fitted forearm (elbow → wrist) against the plate's pointing direction; **+ = flexion** (toward the palm), − = extension, 0 = in line | no palm normal to give the sign, or no fitted elbow |
| `wristFlexionChangeThroughRelease` | last − first flexion inside release ± 80 ms | fewer than two frames in that span carry both |
| `guideContactPlaneToShotPlane` | the **guide** palm's normal at the last frame a guide knuckle was within one ball radius of the ball centre, against the shot plane's normal (on a side view, the camera's own view ray): 90° = the guide palm lay in the shot plane | no ball track in the record, no guide plate, or no contact frame |

The guide-hand contact plane is the one measure that **cannot** be recomputed from a `BodyShot` alone: the record
carries no ball samples (§3), so it is written only by the pass that has both the plates and the ball track (the app's
`ShotAnalysisRunner`, and `FormClipModel`). Offline, it comes back with exactly that reason.

## 4. Frames of reference

- **Image**: pixels, full-frame, top-left origin. Always what the tracker saw.
- **Camera**: metres, x right, y down, z forward, origin at the lens (Vision 3-D convention).
- **Body**: origin at the mid-hip at the set point; x toward the rim along the shot plane; z up; y completes the right-handed
  frame (toward the camera on a right-wing side view). Scale: metres when the shooter's stated height is known, else
  unit height (root-to-top-of-head = 1) and `scaleProvenance = unitHeight`.
- **Hand plate** (v2): the wrist · index MCP · little MCP triangle, attached at the **fitted** wrist. Positions in the
  body frame and in `skeleton.unit`; `palmNormal` and `pointing` are unit vectors in the same frame, rotated but never
  scaled, so they carry no length unit. `palmNormal` points **out of the palm** (the side the ball sits on).
- **Phase time**: set = 0, dip = 0.35, release = 0.75, follow-through peak = 1.0 (fixed fractions, `FormPhase
  .normalisedTime`); real durations kept in `timing`. **An anchor's own τ needs no neighbour**: τ 0.75 *is* the
  release and resolves to the measured release time even when the dip was never found. (Before 2026-09-16 it did not,
  and 33 of 37 free throws therefore carried nothing at all at their own release instant — see PHASE2-PREP, "Hands and
  release coverage".) The stretches *between* two anchors still need both ends and are otherwise absent, never
  interpolated across.

## 5. Session and shooter layers

- `SavedShot` (App) carries the trustworthy scalars (fitted elbow/knee at release, extension peaks, dip→release, jump,
  head stability, hand rate) and the compact `ShotForm` (body-frame joints on the phase axis) for accepted shots.
- `FormModel` (per spot, per session or pooled): per-phase mean joint positions, per-joint variability ellipsoids, mean ±
  SD angle curves, tempo, seen fractions. Metres are pooled only across shots whose shooter pixel height agrees within
  10 % (the station moves).
- `ShooterProfile`: height (m, stated), handedness (inferred from the ball track, confirmable), and later wingspan.

## 6. Files on the phone

```
Documents/ArcLab/body/<sessionID>/<shotID>.json     BodyShot (full frames) for accepted shots — the mesh model's input
Library/Application Support/ArcLab/sessions.json    SavedSession[] (scalars + ShotForm)
Documents/ArcLab/logs/activity-<day>.jsonl          every event with timings
```

## 7. What the future 3-D skeletal / mesh model needs and where it comes from

| need | status |
|---|---|
| stable joint names, both sides, seen flags | this schema |
| constant bone lengths per shooter | skeleton fit (BodySkeletonFit) |
| metres | stated height (rim ruler refused on oblique views) |
| far-side joints | flagged inferred; a second camera (behind) or the form clip removes the ambiguity |
| feet / toes | MediaPipe only; decision pending a close form clip |
| hand shape at release | Vision hands on the release ±0.4 s crop; ~70 % of frames at 9 m, expected ≫ at 3–4 m |
| head direction | 2-D eyes/ears/nose, ±60° validity |
