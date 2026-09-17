# Form evaluation: the baseline before hands and feet (Track D, 2026-09-16)

Track D of `docs/PLAN-1.3-2026-09-16.md`, answering the question
`docs/research/whole-body-landmarks-2026-09-16.md` §5 poses: **how do we say how well the 3-D form
tracks the whole real movement, honestly, without a mocap lab?** — and then actually saying it, on
the footage that exists today, so every later biometrics change has a number to beat.

The harness is `Packages/ShotGeometry/Sources/FormEval` (CLI) over `Sources/FormEvalKit` (the
statistics and the per-shot measurements, unit-tested). Reproduce every table below with:

```
swift run -c release FormEval <dir of BodyShot .json> --json out.json --markdown out.md
swift run -c release FormEval <dir> --max-rms 10        # the same, minus fits that failed outright
```

---

## 0. Three things to read before the tables

**1. There are 37 shots here, not 110.** The phone directory holds 110 `BodyShot` files, and
`docs/PHASE2-PREP.md` has been quoting "110 real phone shots" since 1.1. They are **three exports of
one 37-shot free-throw session**: `74E9B9B8…` and `930D5CFC…` are byte-identical (930D is missing
one file), and `7EFFEC92…` carries the *same* `points2D` and the *same* Vision `joints3D` from a
different build's re-fit. The harness hashes each file's 2-D input and drops the repeats — 72 of
110 — because counting them would treble every N without adding one new observation. One file in
`7EFFEC92` survives the hash (shot 30, whose release time differs by 17 ms), which is why the
headline count is 38 rather than 37; with `--max-rms 10` it is 37.

So: **one session, one shooter (1.70 m stated), one spot (free throws), one framing (side-on, 48°
assumed hFOV, 158 fps)**. Nothing below is a distance or view-class comparison, because there is no
second condition in this data. Section 5's warning from the research doc — "state the distance and
view class for every row" — is satisfied by stating once that every row is the same row.

**2. The bone gates the research proposed are not falsifiable on this pipeline.** §5.2 suggested
bone-length SD ≤ 3 % and left–right ≤ 4 %. Both pass, at 0.02 %, and the pass means nothing:
*both* 3-D sources hold segment lengths fixed by construction. The fitted skeleton does it with
`BodySkeletonOptions.limbBoneWeight = 3`, and Vision's `DetectHumanBodyPose3DRequest` returns a
**rigged** skeleton whose limb lengths are also constant (measured: 0.01–0.02 % SD over 5 700
frames). The only spans that move are the ones that cross an articulation — the biacromial
(clavicles rotate), the trunk edges and diagonals (the spine flexes), the head and neck spans (the
neck rotates) — and those *should* move on a perfectly tracked body. The harness therefore gates
only the nine single anatomical segments and prints the rest as `articulated`; it reports the gate
as passing and says in the same line why that is not evidence. **The gate that does have teeth is
the held-out reprojection in §2**, and §7 proposes numbers for it.

**3. Reprojection of a joint the fit was driven by is a consistency check, not an accuracy one.**
That is §1, kept because a regression in it is still a regression. The honest number is §2.

---

## 1. Reprojection, per joint — driven (consistency)

37 shots, 5 600–5 740 frames per joint, 2-D confidence gate 0.3 (the fit's own).
"SW" = shoulder-widths: Winter's population biacromial breadth (0.245 H) carried into this shot's
pixels by the observed ankle-to-nose span (0.891 H), median **100.6 px** here. It is a prior-scaled
ruler, not a measured shoulder — the *fitted* biacromial cannot be one, because a side-on view
cannot see the shoulder line's length and the fit reads it at ~0.06 H.

| joint | median px | p90 px | median SW |
|---|---:|---:|---:|
| rightWrist | 0.52 | 1.32 | 0.005 |
| rightElbow | 0.59 | 1.46 | 0.006 |
| rightAnkle | 0.84 | 2.21 | 0.008 |
| rightShoulder | 0.93 | 1.79 | 0.009 |
| rightHip | 0.95 | 1.84 | 0.009 |
| leftWrist | 0.95 | 3.54 | 0.009 |
| leftElbow | 1.07 | 3.66 | 0.010 |
| leftAnkle | 1.09 | 2.54 | 0.011 |
| leftShoulder | 1.21 | 2.63 | 0.012 |
| leftHip | 1.21 | 2.77 | 0.012 |
| rightKnee | 1.32 | 3.46 | 0.013 |
| nose | 1.44 | 3.07 | 0.014 |
| neck | 1.49 | 2.78 | 0.015 |
| leftKnee | 1.76 | 5.10 | 0.017 |

Whole-skeleton RMS: median **1.85 px** per shot, and 1 shot of 38 at **74.9 px** (session
`74E9B9B8` shot 23 — its *median* is 1.61 px, so it is a handful of catastrophic frames, not a bad
shot throughout). The near side (right, the shooting side) reprojects about twice as tightly as the
far side, which is what a single camera should do.

## 2. Held-out joints — the number that is not a tautology

Two designs, because the first one revealed something about the fit rather than about the footage.

**`blink`** — the joint's 2-D is hidden on every 4th frame and the fit is scored **on exactly those
frames**. This is the failure the footage actually produces: the detector loses a joint for a few
frames and the model has to carry it.

**`absent`** — the joint's 2-D is removed from every frame. **This build's fit does not place a
joint it never observed**: it drops it, unless the mirror side can stand in (shoulders and hips,
via the symmetry prior). 10 of 14 joints produce no point at all. That is a finding for Track B and
Track C, not a gap in the harness, and it is reported as the `no point` column.

| joint | blink median px | blink p90 px | blink median SW | driven median px | absent |
|---|---:|---:|---:|---:|---|
| rightElbow | 1.75 | 4.30 | 0.017 | 0.59 | no point |
| rightWrist | 1.87 | 4.38 | 0.018 | 0.52 | no point |
| rightShoulder | 2.61 | 4.94 | 0.025 | 0.93 | 122.69 px (mirrored) |
| rightHip | 2.72 | 5.25 | 0.026 | 0.95 | 101.55 px (mirrored) |
| rightAnkle | 2.96 | 7.47 | 0.029 | 0.84 | no point |
| leftWrist | 2.99 | 11.34 | 0.029 | 0.95 | no point |
| leftShoulder | 3.19 | 7.71 | 0.031 | 1.21 | 104.50 px (mirrored) |
| leftElbow | 3.24 | 11.56 | 0.032 | 1.07 | no point |
| leftHip | 3.24 | 7.49 | 0.031 | 1.21 | 83.45 px (mirrored) |
| leftAnkle | 3.54 | 7.88 | 0.035 | 1.09 | no point |
| neck | 4.09 | 7.64 | 0.040 | 1.49 | no point |
| rightKnee | 4.13 | 11.59 | 0.040 | 1.32 | no point |
| nose | 4.21 | 8.92 | 0.041 | 1.44 | no point |
| leftKnee | 4.79 | 15.11 | 0.047 | 1.76 | no point |

Read it this way: **hide the shooting wrist for a frame and the model puts it back within 1.9 px
(0.018 shoulder-widths) at the median, 4.4 px at the p90.** Hide a far-side knee and the p90 is
15 px. Every held-out number is 2.7–3.5× the driven one, which is the honest cost of prediction and
the proof that §1 was measuring agreement rather than accuracy.

The mirrored `absent` numbers (83–123 px) are not a model error so much as a statement about the
symmetry prior: a shoulder reconstructed entirely from the other shoulder lands most of a
shoulder-width away. Anything drawn from a symmetry-inferred joint must stay dashed.

## 3. Bone-length constancy (SD, % of the bone's own median)

| bone | fit median | fit p90 | Vision median | Vision p90 | gate |
|---|---:|---:|---:|---:|:--|
| upperArmLeft / Right | 0.12 / 0.05 | 0.17 / 0.10 | 0.01 | 0.01 | pass |
| forearmLeft / Right | 0.11 / 0.07 | 0.15 / 0.09 | 0.02 | 0.02 | pass |
| thighLeft / Right | 0.07 / 0.05 | 0.10 / 0.06 | 0.01 | 0.01 | pass |
| shinLeft / Right | 0.06 / 0.08 | 0.07 / 0.10 | 0.01 | 0.01 | pass |
| biiliac | 2.89 | 3.73 | 0.01 | 0.01 | pass |
| biacromial | 2.42 | 2.96 | 4.44 | 7.91 | articulated |
| trunkLeft / Right | 1.52 / 1.60 | 2.00 / 1.94 | 4.72 / 5.49 | 6.15 / 7.23 | articulated |
| trunkDiagonalLR / RL | 1.63 / 1.09 | 2.03 / 1.47 | 3.05 / 4.58 | 4.25 / 5.94 | articulated |
| headLeft / Right | 5.96 / 5.83 | 6.63 / 6.35 | 10.35 / 9.60 | 13.50 / 13.38 | articulated |
| neckNose | 11.63 | 12.72 | 0.03 | 0.04 | articulated |
| neckShoulderLeft / Right | 3.24 / 2.37 | 4.18 / 2.69 | 0.02 | 0.03 | articulated |

**Verdict: PASS at 0.02 % against a 3 % line, and the pass carries no information** (see §0.2).

One row *is* informative and it is not flattering: **`neckNose` wanders 11.6 % in the fitted
skeleton against 0.03 % in Vision's.** The fit is nearly 400× worse than its own input at holding
the neck-to-nose distance constant. `headLeft`/`headRight` show the same shape (5.9 % fitted vs
Vision's 10 %, but Vision's is genuine neck rotation while the fit's is on top of it). The head is
the least well constrained part of this skeleton — worth knowing, given 1.3 started from "I like
the head improvement".

## 4. Left–right asymmetry (|L−R| ÷ mean, %)

| pair | fit median | fit p90 | Vision median | Vision p90 | gate |
|---|---:|---:|---:|---:|:--|
| upperArm | 0.04 | 0.05 | 0.01 | 0.02 | pass |
| forearm | 0.03 | 0.05 | 0.02 | 0.02 | pass |
| thigh | 0.04 | 0.05 | 0.01 | 0.01 | pass |
| shin | 0.04 | 0.05 | 0.01 | 0.01 | pass |
| trunk | 1.80 | 3.37 | 5.73 | 6.92 | articulated |
| head | 1.40 | 1.73 | 7.16 | 10.36 | articulated |

**PASS at 0.02 % against a 4 % line** — and, again, 0 by construction: the fit pooled the mirrored
limb lengths on all 38 shots (`symmetricBones`), and Vision's rig is symmetric to begin with.

## 5. Phase-instant coverage

Shots that have the instant at all: **set 37 · dip 10 · release 37 · follow 35**. The dip is the
striking one: **27 of 37 free throws have no dip at all** — the body model refuses it with "the hand
rises from the set position straight into the release". That is a real property of this shooter's
free throw, not a detector failure, but it means `dipDepth` is a measure with n = 10.

Of the joints, at every one of the four instants:

| point | set | dip | release | follow |
|---|---:|---:|---:|---:|
| all 14 body joints | 100 % | 100 % | 100 % | 100 % |
| `leftIndexMCP` / `rightIndexMCP` | 0 % | 0 % | 0 % | 0 % |
| `leftLittleMCP` / `rightLittleMCP` | 0 % | 0 % | 0 % | 0 % |
| `leftHandWrist` / `rightHandWrist` | 0 % | 0 % | 0 % | 0 % |
| any hand at all | 0 % | 0 % | **19 %** | **43 %** |
| the shooting hand | 0 % | 0 % | **14 %** | **20 %** |

This corrects a claim that has been circulating: "only 2 of 37 free-throw forms carry the right
wrist at the release instant" is about the **hand detector**, not the body pose. The body-pose
`rightWrist` is present on **100 %** of shots at every instant. What is missing is the *hand*: the
shooting hand exists at release on 5 of 37 shots (14 %) and the hand-plate corners on none, because
the hand crop only runs in a ±0.4 s window and Vision loses the hand behind the ball. The four
`…MCP` rows are 0 % because Track B's points do not exist in these v1 exports yet; the rows are
here so the next run shows the change without another edit.

## 6. Repeatability of the form measures

Subjects are shots. The two repeated measurements are **refits of the same shot on disjoint halves
of its frames** (even-indexed and odd-indexed) — the same physical movement, analysed twice, which
is the only true test–retest available when there is one athlete. ICC(2,1) is two-way random,
absolute agreement, single measurement; the interval is a 2 000-sample percentile bootstrap over
shots. σ_meas is the SD of one analysis, recovered from the paired differences
(σ = √(Σd²/2n)); **SDC = 1.96·√2·σ_meas** is the change below which two analyses of one movement
cannot be told apart. *Reliability* = max(0, 1 − σ²_meas/σ²_between): the share of the shot-to-shot
spread that is not measurement noise.

`--max-rms 10`, n = 37 (the 74.9 px shot excluded; it alone moved `headHorizontalRange`'s
between-shot SD from 0.014 to 0.556 stature, which is what a single bad fit does to a mean).

| measure | unit | n | mean | between-shot SD | CV % | σ_meas | SDC | reliability | ICC(2,1) [95 %] |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| jumpHeight | stature | 37 | 0.120 | 0.016 | 13.0 | 0.004 | 0.012 | **0.92** | **0.918** [0.829, 0.947] |
| headHorizontalRange | stature | 37 | 0.026 | 0.014 | 55.7 | 0.005 | 0.014 | **0.87** | **0.863** [0.028, 0.950] |
| shoulderElevationAtRelease | deg | 37 | 117.8 | 6.61 | 5.6 | 3.67 | 10.2 | 0.69 | 0.519 [0.142, 0.671] |
| releaseHeight | stature | 37 | 1.037 | 0.029 | 2.8 | 0.018 | 0.051 | 0.60 | 0.547 [0.313, 0.702] |
| elbowOpening | deg | 37 | 39.0 | 18.4 | 47.3 | 12.5 | 34.7 | 0.54 | 0.189 [−0.166, 0.469] |
| elbowMinimum | deg | 37 | 76.4 | 7.43 | 9.7 | 5.78 | 16.0 | 0.40 | 0.212 [−0.155, 0.503] |
| elbowAtRelease | deg | 37 | 115.3 | 19.6 | 17.0 | 15.3 | 42.3 | 0.39 | 0.010 [−0.349, 0.368] |
| trunkLeanAtRelease | deg | 37 | 6.61 | 2.34 | 35.4 | 1.98 | 5.50 | 0.28 | 0.101 [−0.204, 0.360] |
| kneeMinimum | deg | 37 | 112.8 | 9.10 | 8.1 | 15.5 | 43.1 | **0.00** | **−0.261** [−0.528, −0.020] |
| dipDepth | stature | 10 | 0.000 | 0.000 | 316 | 0.000 | 0.001 | 0.00 | −0.043 [−0.154, 0.000] |

**This is the most important table in the document, and most of it is bad news.**

- **Two measures are ready to coach on.** `jumpHeight` (ICC 0.92, SDC 0.012 stature ≈ 2 cm on this
  shooter) and `headHorizontalRange` (ICC 0.86, SDC 0.014 stature ≈ 2.4 cm). Both are vertical or
  horizontal *displacements* of well-observed joints, which is exactly what a single side-on camera
  measures well.
- **`kneeMinimum` is noise.** σ_meas 15.5° against a shot-to-shot spread of 9.1°: the measurement
  error is *larger than the thing being measured*, ICC is negative, reliability is 0. Any coaching
  cue about knee bend from this pipeline today is reading its own noise. The near-side knee also has
  the worst reprojection in §1 (leftKnee p90 5.1 px) and the worst blink error in §2 (p90 15 px).
  Same joint, three independent ways of saying it.
- **`elbowAtRelease` is nearly as bad.** σ_meas 15.3°, SDC 42° — two analyses of one shot can differ
  by 42° and that is within noise. `elbowMinimum` (σ 5.8°) is three times better than the angle at
  the release instant, which says the problem is *when* the release is, not the arm: a 4 ms timing
  error at 158 fps lands on a different frame of a 900 °/s extension.
- **`dipDepth` has n = 10 and a mean of 0.000 stature.** It is not measurable on this shooter's free
  throw, because there is no dip (§5). It is reported so the number cannot be quoted by accident.

A practical reading for 1.3: the depth-direction and instant-locked angles are the fragile ones; the
displacement measures are solid. Hands and feet will add instant-locked angles (wrist snap, foot
roll), so they must arrive with their own rows in this table or they should not be shown to a user.

## 7. What the gates should be after this

The research's two bone gates are kept (they cost nothing and a real regression would break them),
but they are not the gate. Proposed, from the numbers above, to be frozen once Track B and C land:

| gate | proposed line | today | why this line |
|---|---|---|---|
| held-out (blink) reprojection, shooting-side wrist/elbow | p90 ≤ 0.02 SW | 0.017 / 0.017 median, 4.3–4.4 px p90 | the joints the form measures hang off; today's p90 is ~0.042 SW so the line is **median**, not p90, until it improves |
| held-out (blink) reprojection, any fitted joint | median ≤ 0.05 SW | worst 0.047 (leftKnee) | one joint away from failing; it is the honest ceiling |
| whole-skeleton reprojection RMS | median ≤ 2.5 px, ≤ 5 % of shots over 10 px | 1.85 px, 1/38 = 2.6 % | where the 1.1 iteration left it |
| repeatability of any measure shown to a user | ICC(2,1) ≥ 0.75 **and** SDC smaller than the coaching cue's effect | 2 of 10 pass | the rule that stops noise being coached |
| phase-instant coverage of a joint a measure needs | ≥ 90 % of shots | body 100 %, hand 14 % | the hand is the 1.3 gap, quantified |
| bone-length SD (9 rigid segments) | ≤ 3 % | 0.02 % | kept, tautological, cheap |
| left–right difference (4 limb pairs) | ≤ 4 % | 0.02 % | kept, tautological, cheap |

## 8. The hand-label path

The only ground truth ArcLab can afford is a human clicking on joints. `scratchpad/labels/` holds
the first sheet: **20 frames, 5 free throws, 4 frames each at −60/−20/+20/+60 ms around the
release**, cut from the 240 fps clip `03D7D2BF-2056-4AFE-948C-4D615953A49B.mov`, with a JSON
template per frame for the 12 joints of §5.5 (including `rightHeel`, `rightBigToe`,
`rightLittleToe`, which this build cannot fit and Track C will). `scratchpad/labels/bodyshots/`
holds a `BodyShot` export per shot so `FormEval --labels` has something to score against — produced
with `TrajectoryProbe bodyexport`, 7 s per window. `scratchpad/labels/HOW-TO-LABEL.md` is the
instruction sheet. `scratchpad/make_label_sheet.py` cuts more.

The scoring path is verified end to end on synthetic labels: an injected 3 px offset reads back as
a 4.0 px median error (3 px plus the fit's own ~1 px), and an injected 4 px disagreement between two
labellers reads back as a 4.00 px noise floor.

Two honest gaps:

- **A `BodyShot` does not record the clip it came from.** Schema v1 `source` carries kind, build,
  device and format and no file reference, so the clip must be passed to the label script by hand.
  Adding `source.clip` would close it.
- **The release instant of the 240 fps session is estimated, not measured.** The app's session record
  stores each shot's analysis window but not its release time, so the brackets are centred on
  `windowStart + 0.80 s` — the offset measured on the one session that records both (37 shots,
  0.77–0.85 s, SD ≈ 40 ms). The ±60 ms bracket is deliberately wider than that. The labeller is
  asked to tick which of the four frames is the true release, which turns the estimate into a label.

## 9. Open

- **No second condition.** Every number is one shooter, one spot, one framing, one lens assumption
  (48° hFOV marked `assumed` in the export). The distance effect §1.1 of the research doc predicts
  cannot be seen until a second session at a different distance is exported.
- **`--max-rms` is off by default**, so the headline tables include the 74.9 px shot. Both runs are
  in the scratchpad (`formeval/baseline.json`, `formeval/baseline-clean.json`).
- **The even/odd retest halves the frame rate**, and the fit's smoothness term counts frames rather
  than seconds, so each half is smoothed differently from the full-rate fit. σ_meas is therefore an
  **over**-estimate of the shipped analysis's noise, and SDC is conservative. Weighting smoothness by
  dt would remove the confound.
- **No human labels exist yet.** Until the sheet comes back, §8's numbers are plumbing tests, and the
  harness says so rather than scoring anything.
