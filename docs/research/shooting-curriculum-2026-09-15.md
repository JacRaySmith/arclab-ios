# The shooting curriculum — what an NBA shooting coach teaches, in order, with grades

Date: 2026-09-15. Track B of `docs/PLAN-1.1-2026-09-15.md`. User's words: *"This should train you like an
NBA shooting coach would teach you."*

This is the **teaching** document. `FixLibrary` answers "your numbers say X, so do Y"; this answers
"teach me to shoot". Eight modules in the order a coach works through them, each with what the coach
watches, the one cue they say, the drill with its reps and its constraint, what **done** looks like in
ArcLab's own measurements, and the common faults with the fingerprint each leaves in the numbers.

Companion documents, **not repeated here**:
- `docs/research/healthy-shot-model-2026-09-14.md` — the measurable ranges, the joint kinematics, the
  versatility definition, the practice-method table, and the A–D grading scheme used below.
- `docs/research/coaching-evidence-2026-09-13.md` — the rule-by-rule evidence review and the folklore
  table ("claims that are folklore / not supported — do not ship").
- `docs/DESIGN-SHOT-DOCTOR-2026-09-14.md`, `docs/DESIGN-PRACTICE-MODE-2026-09-15.md` — the screens.

Shipped as `Packages/ShotGeometry/Sources/ShotGeometry/Curriculum.swift` (+ `CurriculumTests.swift`)
and the **Learn** screen (`App/Sources/LearnView.swift`).

---

## 0. The three honest positions this document takes

**1. The order is grade C.** No study has compared teaching orders for basketball shooting. The
sequence below — base → footwork → dip and rhythm → guide hand → release and follow-through → range →
off the dribble → game speed — is what shooting coaches converge on, with a defensible mechanical
rationale (each module's measurement is only readable once the one before it repeats). It is shipped
labelled as consensus, not as a finding.

**2. The cue is the weakest link, and the app says so.** The bias-corrected meta-analysis of
external-focus cues finds **g = 0.01** on performance, 0.15 on retention, 0.09 on transfer, with Bayes
factors favouring the null ([McKay et al. 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC8256521/) —
**A for the null**); reduced/faded feedback frequency has an equally null meta-analysis behind it
(McKay et al. 2022, 61 papers, k = 75, N = 2,228). Every cue below is one external-focus sentence
because that is how coaches talk, **not** because the wording is evidenced. What is graded is the
measure the module closes on.

**3. Folklore is shipped labelled, never omitted.** A shooter will hear "elbow under the ball", "45°
arc", "thumb flick", "square to the rim", "the hop is quicker" from every coach and every YouTube
video they meet. Leaving them out of the app does not protect anyone; listing them as **D** with the
reason does. Fifteen D-graded faults, drill methods and gates ship in the catalogue; §10 lists them
with the six more that are carried as source notes or deliberately not shown at all.

**Grades** (from `healthy-shot-model-2026-09-14.md` §0, mirrored in `ShotEvidenceGrade`):
**A** peer-reviewed on skilled shooters / large-n professional tracking / exact geometry · **B**
peer-reviewed but small n, recreational sample, or indirect · **C** coaching consensus with a
biomechanical rationale, no controlled measurement · **D** opinion, vendor marketing, or an untested
in-house hypothesis.

---

## 1. The measurements a module can close on

ArcLab can score a module gate only on a measure the engine reads out of a saved session's diagnosis.
That set is small and it is worth naming, because everything else in this document is either an
unavailable-with-a-reason or a fault description:

| Gate measure | Unit | Grade of "this matters" | Source |
|---|---|---|---|
| `releaseSpeedSD` (per spot) | m/s | **A** | Slegers, Lee & Wong 2021: velocity SD r = −0.96 with 3P%, r = −0.88 with FT%; skilled band 0.05–0.13 m/s |
| `releaseSpeedSDRatioAcrossDistance` (near → far) | × | **A** | Same study: skilled velocity SD was *identical* at FT and 3-pt (0.086 vs 0.089) |
| `depthMeanCm` past the front rim | cm | **A** | Daly-Grafstein & Bornn 2019: make probability peaks 25–28 cm past the front rim over >50 000 NBA threes |
| `depthSDCm` | cm | **A** (geometry) | 0.1 m/s ≈ 15 cm of depth at ~7.2 m/s over ~5.3 m — the exact range derivative |
| `entryAngleMeanDegrees` | ° | **A** floor, **A** band | asin(d_ball/d_rim) = 31.4–32.1° hard floor; under 3 cm of margin by 40°; NBA makes cluster mid-40s and the probability is flat over a range |
| `lateralMeanCm`, `lateralSDCm` | cm | **A** | Slegers & Love 2022 (spin-axis SD r = 0.80 with lateral accuracy, mean did not predict); Daly-Grafstein & Bornn 2020 (contests raise lateral variance 38 %, mean unmoved) |
| `dipToReleaseChangeAcrossDistance` | s | **B** | No published reference range in any population; only the within-shooter change is readable |

Everything else a coach would like — head stability, stance width, spin-axis tilt, forearm flare,
knee-drive rate, sequencing order, end-to-end session drift — is either not on the diagnosis, has no
published range, or is in ArcLab's untrusted-units class. Those appear as `unavailableReason` strings,
never as numbers. That is CLAUDE.md rule 1 applied to teaching rather than to measurement.

The "not distinguishably wider" gates use **1.43 = exp(1.96/√30)** — `DoctorStats.detectableSDRatio(n: 30)`,
the app's own arithmetic, asserted against the shipped function in `CurriculumTests`. It is not a
coaching number and it is not a published threshold.

---

## 2. Module 1 — Base and balance

**Prerequisites:** none. **Why first:** not because the base is where the accuracy lives (it is not —
the release is), but because every later measurement is read off a shot that repeats. A shot that
lands somewhere new every time cannot be read at all.

**What the coach watches**
- Where the feet start and where they land — the shot should finish inside its own footprints.
- Whether the head travels between the dip and the release.
- Whether the eyes find the rim before the ball starts up.
- Whether the last set of the session looks like the first.

**Cue (external focus):** *"Land where you took off, with your eyes on the back of the ring the whole way."*

**Drills**

| Drill | Reps × sets | Constraint | Ladder | Method grade |
|---|---|---|---|---|
| Footprint holds | 10 × 4 | Chalk the two marks; a shot counts only if both feet land inside them and the finish is held until the ball reaches the rim | Free throw | **C** — Knudson 1993 JOPERD six teaching points (balanced stance, minimise horizontal COM travel); schedule from Shamshiri 2025 (**B**) |
| Hold the look | 10 × 3 | Eyes stay on the back of the ring through the follow-through; tracking the ball out of the hand voids the rep | Any one spot | **B** — Ripoll et al. 1986 (head/eye stabilisation discriminates experts; small n, no effect size) |

**Done, measurably**
- ✅ `depthSDCm` at the practised spot narrows past the detectable ratio (n ≥ 25) — **A** (depth SD is
  the observable consequence of speed SD; the ratio floor is arithmetic).
- ⛔ *Head stops moving dip → release* — **not scorable**. Head displacement is in pixels from a fixed
  tripod, has no published range in any unit, and is not comparable across camera positions
  (`healthy-shot-model` §2.4, §7). Reported as the shooter's own trend, never scored. Grade **B**.
- ⛔ *No drift across the session* — **not scorable as a gate**. The end-to-end change is produced by
  the doctor's over-session trend read-out, not the pass-check reader. Grade **A** for the measure
  (textbook Ch 15 §15.3.4).

**Faults and their fingerprints**

| Fault | In the numbers | Grade | Source |
|---|---|---|---|
| Drifting/fading out of the shot | Lateral mean off centre, lateral SD wider than the same shooter's static sets. Behind-the-shooter clip only | **C** | Knudson 1993 (consensus); that *variance* is what predicts is **A** (Daly-Grafstein & Bornn 2020) |
| Head moving through the shot | Head displacement dip → release, pixels, close clip. No published range → trend only | **B** | Ripoll 1986; Lebeau 2016 quiet-eye meta (large effects, weak designs, gaze unmeasurable from a tripod) |
| Stance too wide / too narrow | **Nothing.** Stance width is metres from the body model, ArcLab's untrusted class | **B** | Cabarkapa, Cabarkapa & Fry 2026: proficient 3-pt shooters were *narrower* (27.4 vs 34.3 cm) — the opposite of "shoulder width or wider" |
| "You must be square to the rim" | **Nothing measurable.** No published squareness range exists at all | **D** | `healthy-shot-model` §2.5, row 18; Cabarkapa 2022's grade-A null (excellent vs good pros: no kinematic differences) |

**Open:** head stability needs a fixed tripod and a pixel-to-scale note; foot contacts and landing
position arrive with Track C (`DESIGN-FOOTWORK-2026-09-15.md`). Until then this module closes on its
*consequence* (depth SD), not on its subject — and the app says so rather than pretending otherwise.

---

## 3. Module 2 — Footwork into the shot

**Prerequisites:** base. **The honest framing:** the coach is not teaching a style. The single measured
test of foot placement found nothing.

> 11 NCAA Division I women, jump shots categorised as dominant-staggered / parallel / cross-dominant:
> **no significant effect of foot placement on accuracy**, though players favoured the dominant
> staggered stance.
> [The Sport Journal, "The Effect of Foot Placement on the Jump Shot Accuracy of NCAA Division I
> Basketball Players"](https://thesportjournal.org/article/the-effect-of-foot-placement-on-the-jump-shot-accuracy-of-ncaa-division-i-basketball-players/)
> — **B** for the null (practitioner journal, not PubMed-indexed, n = 11).

So what is taught is a **repeat**, not an order: the same feet, pointed before the ball arrives.

**What the coach watches**
- Whether the feet are pointed at the rim before the ball arrives, or are still turning as it does.
- Which foot lands first, and whether it is the same one every repetition.
- Whether the hips are square by the time the ball reaches the set point.
- Whether the shooter travels sideways between the catch and the release.

**Cue:** *"Have your feet pointed at the rim before the ball gets to you."*

**Drills**

| Drill | Reps × sets | Constraint | Ladder | Method grade |
|---|---|---|---|---|
| Same-feet catch and shoot | 10 × 4 | Two chalk marks; every shot starts and ends on them, and the ball leaves before the feet move again | Free throw → elbow | **C** (consensus; the one measured stance test found no accuracy difference) |
| One-two ladder | 8 × 6 | The same foot first every rep; a rep where the other foot lands first does not count — *which* foot is not graded, only that it repeated | Elbow → mid-range | **D** — both the 1-2 and the hop are taught as correct by well-known coaches and no peer-reviewed comparison exists ([Dr Dish coaching blog](https://blog.drdishbasketball.com/basketball-shooting-footwork-1-2-vs.-the-hop), searched 2026-09-15) |

**Done, measurably**
- ✅ `lateralMeanCm` inside ±3 cm, filmed from behind (n ≥ 20) — **A**, reused verbatim from the
  shot doctor's lateral-aim package (mean offset near zero in pros; ±11 cm ring tolerance is exact geometry).
- ✅ `lateralSDCm` narrows past the detectable ratio (n ≥ 25) — **A** (Slegers & Love 2022).
- ⛔ *Step order, gather time, landing position repeat* — **not scorable**. ArcLab measures no foot
  contacts yet; Track C is building them and no off-the-dribble footage exists. Grade **C**.

**Faults**

| Fault | In the numbers | Grade | Source |
|---|---|---|---|
| Fading/drifting sideways | Lateral mean off centre, repeating in the same direction. Invisible on a side view | **B** | Daly-Grafstein & Bornn 2020 (disturbance shows in spread first); the drift→offset attribution is **C** |
| Different feet every rep | Lateral SD wider on catch blocks than on the same shooter's stand-still blocks at the same spot | **C** | No study; the block comparison is ArcLab's own |
| Drifting forward into the rim | Mean depth past the 25–28 cm band; release distance shortening between nominally identical blocks | **C** | Band is **A** (Daly-Grafstein & Bornn 2019); the attribution is a coaching inference |
| "The hop is quicker" / "the 1-2 is more balanced" | **Nothing.** Coaches teach both as correct | **D** | Dr Dish blog (the argument, not evidence); Sport Journal null above |

---

## 4. Module 3 — The dip and the rhythm

**Prerequisites:** base. **Why it matters more than it looks:** the published difference between
proficient and non-proficient shooters lives in the **preparatory phase**, not at release — which is
the part most video apps ignore.

> Markerless 120 Hz, 34 males (19 proficient ≥ 70 % FT): proficient shooters moved **slower and lower**
> — knee peak angular velocity 269.4 vs 212.9 °/s (p = 0.005, ES 1.04), COM peak velocity 1.07 vs
> 0.87 m/s — with **no release-phase differences at all**.
> [Cabarkapa et al. 2023, Front Sports Act Living](https://pmc.ncbi.nlm.nih.gov/articles/PMC10436204/) — **B**.

And the dip itself is the one intervention in this whole curriculum with a grade-A acute effect:

> 36 elite males (18 HS, 18 university), within-subject, with and without a dip at four distances
> (3.125–6.75 m): **7–9 % accuracy gain**, F(1,17) = 27.6 and 53.1, p < 0.001.
> [Penner 2021, Front Psychol](https://pmc.ncbi.nlm.nih.gov/articles/PMC8273237/) — **A** for the
> design class; unblinded, single session, acute, no retention test. "Always dip" as a permanent
> prescription is **D**.

Direction of tempo is genuinely contested: higher-level U18s released **12.5 % faster** than
lower-level ones (Botsi et al. 2024 JFMK, 79 players; free-throw release time t(77) = −3.213,
p = 0.002; entry angles 8.1 % closer to 45°, p = 0.006) — the opposite pull to Cabarkapa's "slower and
lower". **Both directions are published, so only the shooter's own consistency is scored.**

**What the coach watches:** whether the ball goes down before it goes up and to the same place;
whether the tempo from the bottom of the dip to the release repeats; whether it changes with distance;
whether the legs start the shot and the ball is the last thing to move.

**Cue:** *"Let the ball sit in the dip for a beat, then send it."*

**Drills**

| Drill | Reps × sets | Constraint | Ladder | Method grade |
|---|---|---|---|---|
| Metronome dip | 8 × 8 | Metronome set to your own near-spot dip→release time; the shot leaves on the second click, from every distance | Near spot then far spot | **C** — reused from `FixLibrary`; the method is untested and the two published directions disagree |
| Dip / no-dip A-B | 10 × 6 | Alternate sets, dip vs ball starting at the set point; each set recorded as its own block | Free throw → mid-range | **A** (acute) — Penner 2021's own within-subject design, run on you |

**Done, measurably**
- ✅ `dipToReleaseChangeAcrossDistance` moves ≥ 0.05 s back toward the near-spot value (n ≥ 20) —
  **B**. There is **no published reference range for dip-to-release in any population**; the target is
  your own near-spot tempo and 0.05 s is the smallest move the measure resolves at these counts.
- ✅ `releaseSpeedSD` at the practised spot narrows past the detectable ratio (n ≥ 25) — **A**.
- ⛔ *Legs lead the arm on most shots* — **not scorable**. Sequencing needs a close waist-up clip and is
  not on the diagnosis; it is a **pattern**, never a lag in milliseconds, because no lag has ever been
  published (Jiang et al. 2025, **B**).

**Faults**

| Fault | In the numbers | Grade | Source |
|---|---|---|---|
| Rushing the gather at range | dip→release falls as distance rises; release-speed SD widens with it | **B** | Cabarkapa 2023 vs Botsi 2024 — opposite directions, so only your own change is read |
| No dip at all | Nothing in one block; only your own alternating dip/no-dip blocks | **A** acute / **D** as a permanent rule | Penner 2021 |
| Shooting with the arm only | Knee-extension peak rate flat as distance rises. Close clip; reported, not scored | **B** | Cabarkapa 2023; Okazaki & Rodacki 2012 (experts changed *speed*, not joint angles, with distance) |
| "One-motion is faster, two-motion is more powerful" | **Nothing.** No comparative biomechanical study of the two exists | **D** | `healthy-shot-model` §2.6 (searched 2026-09-14). Set-point height is in the same class and is deliberately **not shown at all** |

---

## 5. Module 4 — The guide hand

**Prerequisites:** dip and rhythm. **This is the weakest-evidenced module in the curriculum, and the
app says so on the screen.** Searching for measurement of the non-shooting hand's effect on release
(2026-09-15) returns coaching sites and training-aid **patent filings**
([US 10,427,020](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10427020),
[US 5,188,356](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/5188356)) — documents
whose job is to describe a product, not to measure a shot. The patents state the folklore plainly
("the non-shooting hand's thumb rotating forward … spinning the ball about a non-horizontal axis"),
which is a fair description of the mechanism and **no evidence that it happens or that it matters**.

What *is* grade A is the consequence a coach is actually chasing:

> SD of spin-axis alignment predicted lateral accuracy (**r = 0.80** for vertical-axis SD) while *mean*
> misalignment did not. [Slegers & Love 2022](https://pubmed.ncbi.nlm.nih.gov/35611914/).
> NBA contests raise left–right variance 38 % without biasing direction (Daly-Grafstein & Bornn 2020).

**What the coach watches:** where the off hand sits; whether it is still on the ball at release;
whether the off thumb pushes; whether the ball comes back on a straight axis; whether the misses fall
to one side rather than scattering.

**Cue:** *"Roll the ball off the two middle fingers so it comes back straight at you."*

**Drills**

| Drill | Reps × sets | Constraint | Ladder | Method grade |
|---|---|---|---|---|
| Taped-stripe spin set | 10 × 4 | Tape around the seam, camera directly behind; watch the stripe, not the result | Near spot first | **B** — Slegers & Love 2022 for why the axis matters; the capture mode is not shipped |
| One-hand form set | 10 × 4 | Guide hand off the ball entirely, close range, filmed from behind; a shot counts only if the stripe comes back flat | Free throw | **D** — near-universal coaching practice with **no controlled measurement found** |

**Done, measurably**
- ✅ `lateralSDCm` narrows past the detectable ratio (n ≥ 25) — **A**.
- ✅ `lateralMeanCm` inside ±3 cm (n ≥ 20) — **A**.
- ⛔ *Spin axis inside ±10° of pure backspin* — **not scorable**: the taped-stripe mode is unshipped and
  tilt is not on the diagnosis. The ±10° band and the 2–3°/frame resolution are ArcLab's own
  feasibility numbers (`DESIGN-MEMO` §3.7), **not** a published range. Grade **B**.

**Faults**

| Fault | In the numbers | Grade | Source |
|---|---|---|---|
| Thumb flick from the off hand | Tilted spin axis (unmeasurable today); when systematic, a lateral mean on one side | **D** as a cause claim | Patents + coaching sites only. Grade **A** only for "lateral *consistency* predicts, the mean does not" |
| Guide hand still on the ball at release | **Nothing directly** — needs a hand-contact measurement ArcLab does not have | **C** | Consensus with a mechanical rationale (a second force at release) |
| "Thumb up" / "hand at three o'clock" | **Nothing.** No published hand-placement range; coaches teach different clock positions | **D** | Coaching-site instruction only |

**Open:** this module is unscoreable from a side view — everything it touches is in the left–right
channel. The taped-stripe capture mode is the single unlock that would turn its real subject into a
measurement.

---

## 6. Module 5 — Release and follow-through

**Prerequisites:** guide hand. **This is where the accuracy is.** The release parameters are what the
ball leaves with, and their spread — the speed channel above all — is the strongest published
correlate of shooting percentage in the literature (Slegers, Lee & Wong 2021, r = −0.96 with 3P%,
n = 12 skilled, matched measurement class to ArcLab's).

**What the coach watches:** whether the ball leaves the same two fingers at the same moment; whether
the arc clears the front rim with room rather than arriving at a chosen number of degrees; whether the
hand holds its line; whether the misses are short, long, or scattered.

**Cue:** *"Finish every shot with the ball leaving the same two fingers at the same moment."*

**Drills**

| Drill | Reps × sets | Constraint | Method grade |
|---|---|---|---|
| One-spot depth band | 10 × 8 | Same spot all session; a shot counts only if it crosses inside *your own* make band — makes that come in short or long are called as misses | **A** (the measure; Slegers 2021) |
| Over-the-top | 10 × 6 | A pole (or an imagined bar) a metre in front of the rim at rim height + 0.5 m; any shot that would clip it does not count | **C** (the physical-constraint method is consensus; the 40° margin it buys is geometry) |

**Done, measurably**
- ✅ `releaseSpeedSD` narrows past the detectable ratio (n ≥ 25) — **A**.
- ✅ `entryAngleMeanDegrees` inside 40–52° (n ≥ 20) — **A** floor (geometry), **A** band
  (Daly-Grafstein & Bornn 2020: entry is the least peaked of the three rim-plane variables).
- ✅ `depthMeanCm` inside 25–28 cm past the front rim (n ≥ 20) — **A** (>50 000 NBA threes; measured on
  NBA threes, *not* on this shooter).

**Faults**

| Fault | In the numbers | Grade | Source |
|---|---|---|---|
| Flat arc | Entry angle < 40°, where the ball has under 3 cm of margin; below ~32° it cannot fit | **A** | Exact geometry: asin(d_ball/d_rim) = 31.4° (0.2385 m ball), 32.1° at the top of the rulebook tolerance |
| Release speed varying | `releaseSpeedSD`, plus the delta-method speed share of depth variance. 0.1 m/s ≈ 15 cm of depth | **A** | Slegers 2021 + the exact range derivative |
| Short misses | Misses slower than makes; mean depth short of the band | **A** | Mullineaux & Uhl 2010 (misses −0.12 ± 0.10 m/s vs swishes −0.02 ± 0.07, **B**); Daly-Grafstein & Bornn 2019/2020 |
| Elbow flaring from vertical | Frontal forearm-from-vertical — needs a behind clip; ArcLab's elbow today is sagittal | **B** | Cabarkapa & Fry 2021: proficient 7.9 ± 7.2° vs 19.8 ± 17.6°, between groups, n = 17 recreational |
| **"Shoot 45° arc"** | Not a fault and not a target | **D** | Slegers 2022: each shooter's optimum is 4.3 ± 2.1° above their own minimum-velocity angle, r = 0.78 with their own release covariance. The universal traces to vendor marketing (Noah "Building the Perfect Arc") and to per-shot-type averages misread as targets (Nylon Calculus 2018: the same player ≈38° mid-range, 45° from three, 53° FT) |
| **"Keep the elbow under the ball"** as a universal | Between-group association only | **D** as stated | Cabarkapa & Fry 2021 is between-group; Cabarkapa 2022 found *no* kinematic differences between excellent and good professionals |
| **"Hold the follow-through for two seconds"** | **Nothing.** No measurement of hold duration found | **D** | Consensus. The measurable thing a coach is after is a narrower lateral spread |

---

## 7. Module 6 — Range

**Prerequisites:** dip and rhythm, release and follow-through. **Range is not a distance you can
reach; it is the distance at which your shot still behaves like your shot.** The published signature
is not a bigger number anywhere — it is that the spread does not inflate:

> Skilled shooters' release-velocity SD was **the same** at free-throw and three-point range
> (0.086 vs 0.089 m/s). [Slegers, Lee & Wong 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8256521/) — **A**.
>
> Accuracy still falls with distance even in experts (59 % → 37 % from 2.8 m to 6.4 m; release height
> and angle fall, speed rises). [Okazaki & Rodacki 2012](https://pubmed.ncbi.nlm.nih.gov/24149195/) — **B**.
> Some fall-off is normal; only the **spread ratio** is scored.

**What the coach watches:** whether the speed spread widens when the shooter steps back; whether the
tempo changes to buy the distance; whether the arc collapses; whether the extra distance comes from
the floor or the arm.

**Cue:** *"From every distance, send the ball over the front rim to the same spot on the back of the ring."*

**Drills**

| Drill | Reps × sets | Constraint | Ladder | Method grade |
|---|---|---|---|---|
| Distance ladder | 5 × 16 | Step back only after two in a row cross inside your own make band; step forward the moment three in a row miss it | FT → elbow → mid → three | **B** — Shoenfelt et al. 2002: variable-distance practice *equalled* constant practice on delayed retention despite worse practice performance (94 participants, randomised, 3 weeks). Blocked → shuffled follows Shamshiri 2025 (blocked wins acquisition 1.79 vs 1.11–1.52, loses retention 1.28 vs 1.69–1.73, ηp² = 0.24) |
| Step-in range extension | 6 × 8 | One step into the shot from behind the line so the legs supply the extra distance; then the same shot standing still, and compare | Mid-range, three | **C** — Okazaki & Rodacki 2012 suggests experts change *speed*, not joint angles, so "use the legs" is a hypothesis to test, not a prescription |

**Done, measurably**
- ✅ `releaseSpeedSDRatioAcrossDistance` ≤ **1.43** (n ≥ 25) — far÷near spread not distinguishably wider.
  **A**; the ratio is `DoctorStats.detectableSDRatio(n: 30)`, arithmetic from the shipped code.
- ✅ `releaseSpeedSD` at the **far spot** narrows past the detectable ratio (n ≥ 25) — **A**.
- ✅ `entryAngleMeanDegrees` at the **far spot** inside 40–52° (n ≥ 20) — **A**.

**Faults**

| Fault | In the numbers | Grade | Source |
|---|---|---|---|
| Running out of power at range | Far-spot speed SD distinguishably wider than near; misses short | **A** | Slegers 2021 (skilled SD was equal across distance); Okazaki & Rodacki 2012 |
| Arc collapsing at the far spot | Far-spot entry < 40° while the near spot clears it | **A** | Geometry; Okazaki & Rodacki 2012 for angle falling with distance (**B**) |
| Rushing the far shots | Far dip→release shorter than near by more than the near-spot SD | **B** | Cabarkapa 2023 / Botsi 2024, disagreeing |
| Arm-only at range | Knee-drive rate flat while speed rises. Close clip; reported not scored | **B** | Cabarkapa 2023; Okazaki & Rodacki 2012 |
| **"Shoot from further back to build range"** | Nothing measures the method | **D** | No study tested it. The nearest tested thing is variable-distance practice, which merely *equalled* constant practice (Shoenfelt 2002, **B**) |

---

## 8. Module 7 — Off the dribble

**Prerequisites:** footwork, range. **The honest framing is a comparison**, because there is nothing to
import: no peer-reviewed kinematic comparison of catch-and-shoot against off-the-dribble release
parameters was found (searched 2026-09-14 and again 2026-09-15). The number everyone quotes —
catch-and-shoot outperforming off-the-dribble by ~20 % (NBA) to ~40 % (college women) — comes from an
aggregator's summary of play-type data with **no method and no control for shot selection, defence or
clock**, and is graded **D** in `healthy-shot-model` §4.

So the module measures *your* pull-up blocks against *your* catch blocks, same spot, same day, same camera.

**What the coach watches:** whether the gather leaves the feet where the catch version leaves them;
whether the ball reaches the same set point; whether the tempo matches the stand-still tempo; whether
the shooter is still travelling sideways when the ball goes.

**Cue:** *"Pick the ball up into the same place it starts from on a catch."*

**Drills**

| Drill | Reps × sets | Constraint | Ladder | Method grade |
|---|---|---|---|---|
| Pull-up pair | 6 × 8 | Alternate: one set catch-and-shoot from the mark, one set one-dribble pull-up to the same mark; each set its own block | Elbow, mid-range | **C** — the A-B design is sound (`DESIGN-MEMO` §C1); the "should match" claim is consensus |
| Gather tempo match | 8 × 6 | A rep counts only if the ball leaves inside your own catch-and-shoot dip→release band | Elbow | **D** — in-house; matching the band off the dribble is an untested hypothesis |

**Done, measurably**
- ✅ Pull-up block's `releaseSpeedSD` ≤ **1.43 ×** the catch block's (n ≥ 25) — **A** for the versatility
  framing (Slegers 2021 across distance; Amaro 2025 across defender/noise; Daly-Grafstein & Bornn 2020
  for contests raising variance 56 %/38 % without moving the mean) and arithmetic for the ratio.
- ✅ Pull-up `depthMeanCm` still inside 25–28 cm (n ≥ 20) — **A**.
- ⛔ *Same foot first, gather inside band, no drift* — **not scorable**. No foot contacts, no gather
  time, no drift metric, and **no off-the-dribble footage exists yet**. The numbers a drill definition
  would want — a 0.35 s gather, drift < 0.1 stature — are **in-house proposals with no published
  support (D)** and will be reported, never scored, when Track C's metrics land.

**Faults**

| Fault | In the numbers | Grade | Source |
|---|---|---|---|
| Everything widens off the dribble | Speed SD and depth SD wider on pull-up blocks than catch blocks, same spot, same day | **A** for the measure | Slegers 2021. That the dribble caused it is *your* block comparison, not a published fact |
| Drifting sideways out of the dribble | Lateral mean off centre on pull-ups but not on catches. Behind clip only | **C** | Daly-Grafstein & Bornn 2020 (**A**) for disturbance showing laterally; the attribution is a coaching inference |
| Rushing the gather | dip→release on pull-ups shorter than your own catch band | **C** | No published gather-time reference in any population |
| **"Catch-and-shoot is 20–40 % better"** | Nothing actionable — a play-type aggregate mixing selection, defence and clock | **D** | Breakthrough Basketball analytics summary; no method, no control |
| **"You stepped wrong"** | Nothing today; and no published support for *any* step order being correct | **D** | No peer-reviewed comparison found; Sport Journal foot-placement null. When Track C lands, ArcLab can answer the *answerable* question — did your step **repeat**? |

**Filming request for the user (Track C also needs this):** one session of one-dribble pull-ups at the
elbow, alternating with catch-and-shoot at the same mark, filmed twice — once side-on for the arc and
once from directly behind for left–right. Nothing in this module is a result until that exists.

---

## 9. Module 8 — Game speed

**Prerequisites:** off the dribble. **The module where coaching instinct and evidence disagree most
usefully.**

> 18 national-level players, 90 shots each, simulated 105 dBA crowd noise and a 1.2×-height defender at
> 1 m: **no significant effect of opposition or noise on jump height, release height, release angle or
> release velocity** (all p ≥ 0.092, η²p ≤ 0.004).
> [Amaro et al. 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12641682/) — **A**.
>
> But in NBA games, tight contests bias shots **short** and raise depth variance **+56 %** and
> left–right variance **+38 %** (Daly-Grafstein & Bornn 2020) — **A**.

So the fault is not "a defender changes your mechanics"; it is **"your spread widens under pressure"**.

Fatigue is real but not universal: entry angle −3.1 to −3.9 %, release time +15–25 %, makes −14 to
−19 % after a 12-min simulated game in 38 high-level players
([Bourdas et al. 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC10974731/), **A**); accuracy SMD 0.67
moderate / 1.39 severe in meta-analysis (Li et al. 2025, n = 388); and **zero** release change in elite
U18s after repeated sprints ([Slawinski et al. 2018](https://pmc.ncbi.nlm.nih.gov/articles/PMC6006537/)).
**Measure drift; never assume it.**

**What the coach watches:** whether the last set looks like the first; whether the shot survives a
clock and a contest; whether the arc falls late; whether what changed is the average or the spread.

**Cue:** *"Treat the last set like the first one: same routine, same tempo."*

**Drills**

| Drill | Reps × sets | Constraint | Method grade |
|---|---|---|---|
| Bookend sets | 10 × 6 | Two counted sets at the start and two at the end, same spot, rest between blocks; the middle is free shooting | **A** — textbook Ch 15 §15.3.4; a set-of-10 mean depth has SE 4.7 cm, so one pair resolves only a 13 cm change |
| Rested blocks | 10 × 6 | 60 s rest between sets; the session **stops** at the set where entry angle has fallen a full session SD, rather than pushing through | **B** — Bourdas 2024 / Li 2025 / Slawinski 2018 |
| Clock sets | 8 × 6 | Every rep inside a four-second count from the catch; a late shot does not count | **D** — near-universal coaching practice, no controlled measurement found for shooting mechanics; the constraints-led literature is quasi-experimental with no mechanics outcome (**C**) |

**Done, measurably**
- ✅ Late block's `releaseSpeedSD` ≤ **1.43 ×** the first block's (n ≥ 25) — **A**.
- ✅ Late block's `entryAngleMeanDegrees` still inside 40–52° (n ≥ 20) — **A**.
- ⛔ *No end-to-end drift* — **not scorable as a gate** (doctor trend read-out, not the pass-check
  reader). Compare a first and a last block instead; three session pairs pooled resolve ~7.6 cm.

**Faults**

| Fault | In the numbers | Grade | Source |
|---|---|---|---|
| Fading late in the session | Entry angle falling and release time lengthening first block → last block | **A** | Bourdas 2024; Li 2025 |
| Shot drifting through the session | Total change in crossing depth, reported as a total, never a slope | **A** | Textbook Ch 15 §15.3.4; Slawinski 2018 for "measure, don't assume" |
| **"Fatigue always flattens your arc"** | Sometimes nothing at all | **D** | Slawinski 2018 (zero change in elite U18s); Li 2025 (no significant 3-pt effect at moderate fatigue) |
| "A defender changes your mechanics" | At skilled level, not measurably — the **spread** widens, not the mean | **A** (for the correction) | Amaro 2025; Daly-Grafstein & Bornn 2020 |

---

## 10. Everything graded D in the shipped catalogue

Fifteen of the rows below are shipped in `Curriculum.swift` as a **D-graded fault, drill method or
gate**, in the module where a coach would say them. The six marked **†** are carried in a source note
beside a higher-graded claim, stated in `Curriculum.honestyRules` rather than as a fault, or
(set-point height) deliberately not shown in the app at all. This
table is the checklist: if the app ever states one of these as a fact, that is a bug.

| Module | Claim | Why D |
|---|---|---|
| Base | "You must be perfectly square to the rim" | No published squareness range exists; Cabarkapa 2022's grade-A null against any posture target |
| Footwork | "The hop is quicker" / "the 1-2 is more balanced" | Both taught as correct; no peer-reviewed comparison; the one measured stance test found nothing |
| Footwork | Same foot first as a *prescribed* order (the drill's constraint) | No published order; only the repeatability is defensible, and that is in-house |
| Dip | "Always dip" as a permanent prescription † | Penner 2021 is acute, unblinded, single-session, no retention test |
| Dip | "One-motion is faster, two-motion is more powerful" | No comparative biomechanical study exists |
| Dip | Set-point height targets † | No evidence; deliberately **not shown at all** in the app |
| Guide hand | Thumb flick causes the miss | Sources are patents and coaching sites |
| Guide hand | "Thumb up" / "hand at three o'clock" | No published hand-placement range; coaches disagree |
| Guide hand | One-hand form shooting as a method | Universal practice, no controlled measurement found |
| Release | "45° is the optimal entry angle" | Individual by construction (Slegers 2022); vendor marketing origin |
| Release | "Keep the elbow under the ball" as a universal † | Between-group association only; grade-A null between excellent and good pros |
| Release | "Hold the follow-through for two seconds" | No measurement of hold duration |
| Release | "Higher release is better" † | Contradicted across studies (`coaching-evidence` folklore table) |
| Release | "Swish everything / aim for the centre" † | Makes peak 2″ *past* centre |
| Range | "Shoot from further back to build range" | Untested; the nearest tested method merely equalled constant practice |
| Off the dribble | "Catch-and-shoot is 20–40 % better" | Aggregator, no method |
| Off the dribble | "You stepped wrong" | No published support for any step order |
| Off the dribble | 0.35 s gather, drift < 0.1 stature | In-house proposals, no published range |
| Game speed | "Fatigue always flattens your arc" | Contradicted (Slawinski 2018; Li 2025) |
| Game speed | Four-second clock drills as a mechanics intervention | No controlled measurement found |
| All | The teaching **order** itself † | Consensus (C), and the cue *wording* is backed by a grade-A null (McKay 2024) |

---

## 11. What is still open

1. **Five doctor hypotheses have no Learn module** — `speedUndershoot`, `arcVersusTurnover`,
   `spinAxisTilt`, `sequencingDistalDominant`, `releaseHeightDrift`. This is asserted in the tests so
   adding one is a deliberate act, not an accident. (`speedUndershoot` is covered in substance by the
   release module's "short misses" fault; the other four are either a geometry read-out or need
   capture modes that do not exist.)
2. **Three modules close on a consequence rather than on their subject** — base (depth SD instead of
   head/stance), footwork (lateral instead of foot contacts), off the dribble (speed SD instead of the
   gather). Track C's `FootworkMetrics` and the taped-stripe spin mode are the two unlocks.
3. **No off-the-dribble footage exists.** Module 7 is a design until it is filmed.
4. **No module has ever been validated end to end.** Nobody has shot a module's drill and had its gate
   pass and hold. The first shooter to do that will be the user, and that is the product, not a gap to
   hide.

---

## 12. Sources new in this pass

Everything else is cited inline in `healthy-shot-model-2026-09-14.md` and
`coaching-evidence-2026-09-13.md` and is not repeated.

- [The Sport Journal — "The Effect of Foot Placement on the Jump Shot Accuracy of NCAA Division I
  Basketball Players"](https://thesportjournal.org/article/the-effect-of-foot-placement-on-the-jump-shot-accuracy-of-ncaa-division-i-basketball-players/)
  — 11 D-I women; dominant-staggered / parallel / cross-dominant; **no significant effect on
  accuracy**; players favoured the dominant stance. Grade **B** for the null. *(Retrieved via search
  summary 2026-09-15; the journal returned HTTP 403 to a direct fetch, so the design details here come
  from the indexed summary and should be re-verified if the number is ever load-bearing.)*
- [Botsi et al. 2024, JFMK — "Comparative Analysis of 2-Point Jump Shot and Free Throw Kinematics in
  High- and Low-Level U18 Male Basketball Players"](https://pmc.ncbi.nlm.nih.gov/articles/PMC11677033/)
  — 79 U18 males (38 HL / 41 LL); HL free-throw release times 12.5 % faster (t(77) = −3.213, p = 0.002),
  entry angles 8.1 % closer to 45° (t(77) = 2.856, p = 0.006), 24.2 % higher two-point success
  (p = 0.002). Grade **A** for direction. **Verified by direct fetch 2026-09-15**; note that this paper
  does **not** report bilateral landing intervals, stabilisation durations, release height or spin rate
  — a search-engine summary claimed it did, and that claim is false.
- [Dr Dish Basketball — "Basketball Shooting Footwork: 1-2 vs. The Hop"](https://blog.drdishbasketball.com/basketball-shooting-footwork-1-2-vs.-the-hop)
  — cited as evidence of the coaching *disagreement*, not as evidence about shooting. Grade **D**.
- [US Patent 10,427,020](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10427020),
  [US Patent 5,188,356](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/5188356) —
  basketball shot-training devices. Cited as the *origin* of the guide-hand thumb folklore. Grade **D**.

**Searched and not found (2026-09-15):** a peer-reviewed kinematic comparison of hop vs 1-2 footwork; a
peer-reviewed comparison of catch-and-shoot vs off-the-dribble release parameters; any measurement of
guide-hand placement's effect on release; any published reference range for gather time, dip-to-release
time, squareness, or set-point height. Each of those absences is what produces a **D** above rather
than a silence.
