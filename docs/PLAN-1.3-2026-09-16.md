# ArcLab 1.3 — the 3-D form tracks the whole real movement (plan, 2026-09-16)

User's brief: "next build will improve upon the 3-D form. Once this is tracking your whole real movements then we can
use it as a learning tool. I like the head improvement; now get the hands and feet by getting one point at the back
(wrist, heel) and then another two at the front left and front right of those appendages. Make more research for
improvements and add whichever you recommend."

## What "hands and feet" means here

Each appendage becomes an oriented **triangle**, so the model can show where it points and how it is rolled:

- **Hand:** wrist (back) · index-finger knuckle (front, thumb side) · little-finger knuckle (front, outer side). From
  those three: the palm normal (where the palm faces), the pointing direction (wrist → mid-knuckle), and the roll.
  At release this is the wrist snap and the guide-hand's contact plane.
- **Foot:** heel (back) · big toe (front, inner) · little toe (front, outer). From those: the foot's pointing
  direction relative to the rim bearing (foot angle — nil on every view today), the foot's roll, and heel/toe contact
  order (FootworkMetrics currently uses the ankle only).

Sources on device: Vision's hand pose gives 21 2-D landmarks per hand (wrist, MCPs, tips) — the hand triangle is
already measurable. Vision has **no** foot landmarks (ankle only); the feet need another detector (Track A decides).

## Tracks

**A — research (short):** on-device options for feet (and richer hands): COCO-WholeBody family (RTMPose/DWPose
wholebody: 133 keypoints incl. heel, big toe, small toe per foot and 21 hand points; Apache-2.0; ONNX → Core ML),
BlazePose GHUM (heel + foot index only), ARKit body tracking (toes joint, phone as camera only), a custom foot-crop
keypoint model. Also: monocular 3-D lifting improvements, parametric body/mesh options with usable licences, and how to
evaluate "tracks the whole real movement" (per-joint image reprojection, left/right consistency, phase-instant coverage).
Deliverable: docs/research/whole-body-landmarks-2026-09-16.md with a recommendation and effort per option.

**B — hands + coverage (implement):** hand triangles from the existing Vision hand pose, lifted into the skeleton fit
with a rigid hand-size prior (population hand breadth ∝ stature, declared as a prior), exported (BodyShot schema v2
additive fields), drawn in SceneBody/FormModelView as oriented hand plates, and measured (palm facing at release, wrist
flexion/extension through the release, guide-hand contact plane). Plus the coverage gap: only 2 of 37 free-throw forms
carry the right wrist at the release instant — find why (confidence gate? ball occlusion? hand crop?) and fix it with a
stated provenance, never an invented point.

**C — feet (implement, after A):** integrate the recommended foot detector into ShotVideo's BodyTracker as a second
request on a foot crop, feed heel/big-toe/little-toe into BodyKinematics as new 2-D points and 3-D fitted joints
(rigid foot triangle prior), export, draw as foot plates, and make FootworkMetrics' foot angle and heel/toe contacts
real. Validate on the 110 phone shots and the 240 fps clip; report coverage and reprojection.

**D — research-recommended improvements:** whatever A recommends beyond hands/feet that fits this build (e.g. a
temporal 3-D lifter as a prior, a mesh preview, evaluation harness), implemented by C or a fourth agent.

## Rules
CLAUDE.md stands: no fabricated points — a landmark the detector did not see is absent, drawn absent, and exported
absent with the reason; ShotGeometry stays Foundation + simd; every metric carries unit, provenance, unavailable reason;
tests + `swift test` green; measurements of ball metrics unchanged.
