# The shot doctor — finding what is wrong with a shot, and what to do about it

Date: 2026-09-14. Code: `Packages/ShotGeometry/Sources/ShotGeometry/{ShotDoctor,Symptoms,FixLibrary}.swift`,
tests `Tests/ShotGeometryTests/ShotDoctorTests.swift`. Pure Foundation; no Vision, no AVFoundation,
no network. Evidence base: `docs/research/healthy-shot-model-2026-09-14.md`,
`docs/reference/digest-ch05-06-variance.md`, `docs/reference/digest-ch15-16-engine.md`,
`docs/DESIGN-MEMO-2026-09-13.md`.

The ask was: find issues with a shot *much* better than the app does now, then fix them, and let the
shooter say what is wrong in their own words ("my shot keeps being short", "when I get further from
the basket I can't get enough power", "the rotation on my shot is diagonal").

## 1. The brainstorm, distilled to five things

**1. A miss is an arithmetic statement, not an adjective.** The app already computes the rim crossing
and the release. That is enough to say, for a *single* miss: it landed 23 cm past your makes' band,
your release speed was 0.63 m/s over your makes and at this spot a m/s is worth 166 cm of depth, your
angle was +3.1° which at your operating point is worth almost nothing, and 72 cm of the error is not
explained by any of the three. The Jacobian (`ReleaseSensitivity`) is what makes three
incommensurable channels — rad, m/s, m — comparable: convert all of them to centimetres of depth.
Nothing else in the category does this per shot.

**2. The reference must be the shooter's own makes, and say so when it is not.** Published depth
optima are NBA threes. With ≥ 8 makes at a spot, the reference is the shooter's own make centroid;
below that, it is the published 25–28 cm band and every sentence says which one it used.

**3. "Versatility" is a testable claim, and tonight it fails.** The one defensible definition in the
literature is *spread stability*: skilled shooters' release-velocity SD was the **same** at free-throw
and 3-point range. So the engine compares the near spot's speed SD against the far spot's, and against
the smallest ratio those shot counts can distinguish. That is a real diagnosis that no arc-number app
produces.

**4. The complaint is the entry point, not the dashboard.** A shooter does not open an app wanting a
number; they open it because something feels wrong. So: a taxonomy of 14 complaints, a deterministic
on-device keyword matcher (no ML, no network), an ordered list of mechanical hypotheses behind each,
and for every hypothesis one evidence test run against *this shooter's* data — which can come back
supported, not supported, below its shot floor, or "this needs a camera position you have not filmed".

**5. A fix is only a fix if it can be scored.** Every hypothesis carries a cue, a drill, the measure
that should move, a magnitude honest about detectability, a pass check the app computes from the next
session, and a retention rule for the session after that. One fix at a time.

## 2. Data flow

```
SavedSession/BlockRow  ──►  [ShotRecord]  ──►  ShotDoctor.diagnose(records:) ──►  Diagnosis
  (App/Sources)             (package)                                              ├─ perSpot: [SpotDiagnosis]
                                                                                   │    ├─ MakeCentroid (ownMakes | publishedBand)
                                                                                   │    ├─ OperatingPoint (J at the cell mean)
                                                                                   │    ├─ [MissDecomposition]  ← one per miss
                                                                                   │    ├─ DepthVarianceAttribution (Ch 5 delta method)
                                                                                   │    └─ honesty: [String]
                                                                                   └─ distance: DistanceDependence
                                                                                        ├─ [SpotProfile] (n per spot)
                                                                                        ├─ [DistanceTrend] (slope, ratio, n)
                                                                                        └─ Versatility (verdict + grade A source)

complaint text ──► SymptomLibrary.match ──► SymptomEngine.answer(complaint:diagnosis:records:)
                                                        ──► ComplaintAnswer { ranked: [HypothesisEvaluation], plan: FixPackage? }

next session ──► ShotDoctor.diagnose ──► FixLibrary.check(passCheck:baseline:followUp:spot:)
session after ──►                        FixLibrary.retention(passCheck:baseline:followUp:retention:spot:)
```

`ShotRecord` is the only thing the App has to build. Its `spot` raw values match `ShotSpot`, so
`DoctorSpot(rawValue: session.spot.rawValue)` bridges. Radians in, metres in, seconds in; the package
converts to degrees only inside the sentences it hands back.

## 3. Issue finding, per shot

For each inferred miss at a spot:

| Step | What it does |
|---|---|
| Classify depth | `short` / `long` / `onLine` against the reference band (own makes' SD, or the published 25–28 cm) |
| Classify lateral | `left` / `right` / `onLine`, or a stated reason: a side view cannot see it |
| Primary direction | whichever error is larger **in units of its own tolerance** (lateral tolerance defaults to the exact ring geometry: 11 cm of room for the ball's centre) |
| Channel contributions | `(v − v_ref)·∂depth/∂v`, `(θ − θ_ref)·∂depth/∂θ`, `(h − h_ref)·∂depth/∂h`, all in cm |
| Residual | `depthError − Σ contributions`, always stated, never hidden |
| Sentence | one line with every number and the reference it used |

Per spot: the delta-method attribution (`DepthVarianceAttribution`) over every accepted shot, giving
the dominant channel and its share, with `n`, with the ±10–15-point caveat at session n, and with an
explicit note when the predicted spread and the observed spread disagree by more than 30 % (the
channels compensate, or the depth measure is smoothed — the engine says both are possible rather than
picking one). A share above 100 % is possible and correct when the covariance term is negative; the
engine explains that instead of clamping it.

Floors: make centroid ≥ 8 makes; attribution ≥ 20 shots; spot enters the distance comparison at ≥ 5.

## 4. Distance dependence

Profiles per spot (n, measured mean release distance or the spot's nominal, and mean ± SD for speed,
angle, height, entry, crossing depth, lateral, dip→release), then trends from the nearest to the
farthest spot with a slope per metre and, for spreads, a ratio.

The versatility verdict is `spreadWidens` / `spreadStable` / `spreadNarrows` / `undecided`, decided by
comparing the far/near release-speed SD ratio against `DoctorStats.detectableSDRatio(n:) = exp(1.96/√n)`
— which reproduces `DESIGN-MEMO` §3.5's table (1.36× at 30, 1.28× at 50, 1.20× at 100, 1.14× at 200)
to within 0.04 and is conservative below 50.

## 5. Complaint intake

14 symptoms: short, long, left, right, flat, too high, inconsistent, no power from distance, diagonal
rotation, back rim, front rim, rushed, all-arm, tired late. Each carries player-voice synonyms; the
matcher lowercases, strips punctuation, and scores whole-word phrase hits weighted by phrase length,
so "further from the basket" beats a stray "short". Ties break on declaration order, so the same
sentence always gives the same answer. No match returns a stated reason and the picker — the engine
never guesses.

Each symptom lists mechanical hypotheses in prior-plausibility order. Each hypothesis carries its
grade, its source, and one `EvidenceTest`: the measure, the direction, the threshold (absolute, a
detectable-SD ratio, a multiple of the session SD, or `descriptiveOnly` where the literature gives no
direction), the shot floor, and the clip it needs. Ranking: supported first (grade A before B before
C, then prior order, then effect size), then below-floor, then needs-another-clip, then no-data, then
descriptive, then ruled out. Nothing is hidden — a shooter is told what was tested and failed.

## 6. Fix packages

One per hypothesis (19 of them), each with: an external-focus cue in one sentence; a drill with reps,
sets, spots, a constraint and a blocked/random schedule; the measure that should move; an expected
magnitude phrased against the detectability floor rather than a promise; a `PassCheck` the app runs on
the next session; a retention rule for the session after.

The honesty rules travel with every plan (`FixLibrary.honestyRules`): one fix at a time, nothing below
its floor, "associated with" never "because", **the cue wording itself is unproven** (the
bias-corrected meta-analysis of external focus gives g = 0.01 with Bayes factors favouring the null),
and the score of a fix is what survives to the next session. Where a cue is big enough to be
detectable in a session or two — back-of-the-ring vs front-of-the-ring is a 5–10 cm mean shift — the
package suggests the randomized cue trial (`DESIGN-MEMO` C1) instead of a prescription.

## 7. The three clips the app should orchestrate

| Clip | Camera | Unlocks | Status |
|---|---|---|---|
| **Side** | Tripod perpendicular to the shot plane | Arc, release angle/speed/height, entry, crossing depth, dip→release, sagittal joints | shipped |
| **Behind the shooter** | On the line to the basket, rim in frame | Left/right at the rim, spin axis, frontal forearm flare, shoulder squareness | **needed** — six of the 19 hypotheses are untestable without it, including every left/right and rotation complaint |
| **Close form** | Close, waist-up, highest fps | Joint angles, sequencing order, knee-drive rate, head stability | **needed** — the preparatory-phase findings live here |

The engine already returns `ClipRequirement.whatToFilm` on any hypothesis it cannot test, so the app
can turn an untestable hypothesis into a one-tap "film this next" card. That is the honest version of
a feature request: the shooter is told exactly what question the extra clip would answer.

## 8. Ball spin as a new measurement

`ShotRecord.spinAxisTiltDegrees` and `backspinRevolutionsPerSecond` exist and are consumed by the
`spinAxisTilt` hypothesis, which currently returns "put one strip of tape around the ball's seam and
film one set from behind you". Feasibility is settled (`DESIGN-MEMO` §3.7): backspin of 1–3 rev/s is
3–9° per frame at 120 fps, a stripe on a 45 px ball fits to 2–3° per frame, and a 0.2 rev/s sidespin
component shows as ≈ 20° of axis tilt. No new hardware. This is the single largest new *measurement*
the app can add, and it is the only way to answer "the rotation on my shot is diagonal" with a number.

## 9. UI screens

1. **Ask about your shot** — a text field plus the 14 symptom rows. Free text runs the matcher; no
   match shows the picker with the stated reason.
2. **Diagnosis** — the symptom restated, then the ranked hypotheses as cards: grade letter, one-line
   mechanism, the evidence line with its numbers and n, and the verdict chip (supported / ruled out /
   needs more shots / needs another clip). The untestable ones carry a "film this" button.
3. **Plan** — exactly one fix: cue, drill, what should move, what would count as a change, and the
   honesty rules. Everything else sits in a visible queue.
4. **Next-session check** — the pass check computed against the new session, with the target shown
   as baseline ÷ detectable ratio, and "not enough shots to tell" as a first-class, non-failing result.
5. **Progress** — retention: practised vs learned, per fix, over a rolling three-session window; plus
   the per-spot profile table and the versatility verdict with its trend.

A sixth surface, per shot, belongs on the existing shot list: the miss sentence.

## 10. The API the App layer calls

```swift
// 1. Bridge. One record per shot; nil anything not measured.
let records: [ShotRecord] = savedSessions.flatMap { session in
    session.shots.enumerated().map { i, s in
        ShotRecord(id: s.id, sessionID: session.id.uuidString, sessionDate: session.date, sequence: i,
                   spot: DoctorSpot(rawValue: session.spot.rawValue) ?? .other,
                   outcome: ShotOutcomeLabel(rawValue: s.outcome) ?? .unknown,
                   accepted: s.verdict == "accept",
                   releaseSpeed: s.releaseSpeed,
                   releaseAngle: s.releaseAngleDegrees.map(Angle.radians),
                   releaseHeight: s.releaseHeight,
                   releaseDistance: s.releaseDistance,
                   entryAngle: s.entryAngleDegrees.map(Angle.radians),
                   depthPastFrontRim: s.depthPastFrontRim,
                   lateralDeviation: s.lateralDeviation,
                   dipToRelease: s.dipToReleaseSeconds,
                   viewClass: ViewClass(rawValue: s.viewClass),
                   kneeExtensionPeakDegreesPerSecond: s.kneeExtensionPeakDegreesPerSecond,
                   proximalToDistal: s.proximalToDistal,
                   elbowAtReleaseDegrees: s.elbowAtReleaseDegrees,
                   headStabilityNormalised: s.headStabilityNormalised,
                   shoulderLineYawDegrees: s.shoulderLineYawDegrees)
    }
}

// 2. Diagnose. Pure, synchronous, no I/O.
let diagnosis = ShotDoctor.diagnose(records: records)
diagnosis.perSpot                       // headline, missDecompositions[].sentence, dominantCause, honesty[]
diagnosis.distance.statements           // the distance-dependence paragraph, one string per line
diagnosis.distance.versatility          // verdict, ratio, detectable floor, grade, source

// 3. Answer a complaint (free text or a picked symptom).
let answer = SymptomEngine.answer(complaint: text, diagnosis: diagnosis, records: records, spot: nil)
let answer2 = SymptomEngine.answer(symptom: .noPowerFromDistance, diagnosis: diagnosis, records: records)
answer.unmatchedReason                  // non-nil ⇒ show the picker, do not guess
answer.ranked                           // [HypothesisEvaluation]: verdict, evidenceLine, filmThis?, rank
answer.plan                             // FixPackage? — nil when nothing is supported
answer.honesty                          // FixLibrary.honestyRules, always shown

// 4. Score it next time.
let next = ShotDoctor.diagnose(records: nextSessionRecords)
let check = FixLibrary.check(plan.passCheck, baseline: diagnosis, followUp: next, spot: .three)
check.passed                            // Bool? — nil means "cannot tell yet", never a silent fail
let ret = FixLibrary.retention(plan.passCheck, baseline: diagnosis,
                               followUp: next, retention: sessionAfter, spot: .three)
ret.held                                // Bool? — "practised, not learned" is an explicit outcome

// 5. Browse the content without any data.
SymptomLibrary.all; HypothesisLibrary.all; FixLibrary.package(for:); FixLibrary.honestyRules
```

Floors worth surfacing in the UI: `ShotDoctor.ownMakesFloor` (8), `.attributionFloor` (20),
`.spotFloor` (5), and `DoctorStats.detectableSDRatio(n:)` for the "with this many shots we can see
changes of X % or more" line the memo asks for.

## 11. What the engine says about the two sessions filmed tonight

Free throws n = 35 (9 makes, 25 misses, 1 outcome unseen), threes n = 29 (10 makes, 15 misses, 4 unseen):

- **Depth spread is a speed problem at both spots.** Release speed carries 93 % of the predicted
  front-to-back variance at the line and ~100 % at three-point range. Angle carries ~1 %: at a 49.9°
  release the shooter is sitting almost exactly on their own depth-turnover angle (51.1° at the line),
  where ∂depth/∂θ ≈ 0.
- **The shot does not hold its spread with distance.** Release-speed SD 0.18 → 0.63 m/s, a 3.5×
  widening against a 1.44× detectability floor. At the three's operating point a m/s is worth 166 cm of
  depth, so 0.63 m/s of SD is ±105 cm — several ring widths. This is the finding.
- Angle SD 1.8 → 4.6°, height 2.13 → 2.34 m, dip→release 0.78 → 0.58 s (−26 %, 2.5 near-spot SDs).
- Entry 38.2° at the line is a genuine grade-A geometric finding: below 40° the ball has under 3 cm of
  margin. Entry *rises* to 40.7° at the three, so this is not a range-strength story — it is a
  free-throw arc story.
- Crossing depth 32 and 33 cm past the front rim, both past the published 25–28 cm make band.
- For "when I get further from the basket I can't get enough power": ranked `rangeStrengthLimit` (A,
  supported) → `flatArcGeometry` (A, supported, at the line) → `rushedPreparation` (B, supported) →
  `armDominantDrive` (needs a close form clip) → `releaseHeightDrift` (reported, never scored). One
  plan comes back: the distance ladder, 5 × 16, with the far-spot speed SD as the pass check.

## 12. Not built, deliberately

- **Lateral and spin are untestable from tonight's clips.** Six hypotheses return a camera position
  instead of a number. That is the honest state, and it is also the product roadmap.
- **No reliability SD.** Trend rules use the session's own SD as a yardstick and say so; the Ch 13
  error budget is what should replace it.
- **The soft make model is not fitted.** `SoftMakeModel.isFitted` is still false, so no cost-in-makes
  ranking is attempted; hypotheses rank by grade and prior, not by makes lost per 100. That is the
  next thing to build once ≥ 100 tagged shots exist.
- **`releaseDistance` is load-bearing.** Without it there is no Jacobian, so no centimetres and no
  attribution — the engine says exactly that rather than substituting a nominal distance.
