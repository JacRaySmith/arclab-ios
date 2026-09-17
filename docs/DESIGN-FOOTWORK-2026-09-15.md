# Footwork and the gather — design (2026-09-15)

Track C of `docs/PLAN-1.1-2026-09-15.md`. The user's ask:

> "if I was shooting off the dribble in a drill (which should be able to be recommended long term)
> then it should be able to tell me if I'm stepping wrong."

Code: `Packages/ShotGeometry/Sources/ShotGeometry/FootworkMetrics.swift`,
tests `Tests/ShotGeometryTests/FootworkMetricsTests.swift`,
probe `Sources/FootworkProbe/main.swift`, card `App/Sources/FootworkCardView.swift`.

---

## 1. The one thing that decides everything else: where the phone is

Footwork is a **ground-plane** measurement — two feet, a separation, a stagger, a drift. A single
camera measures the image plane and refuses depth. So which footwork numbers exist at all is decided
by the camera's bearing, not by the code.

Body frame (`FormModel.swift` header): **x toward the rim, y across (the shooter's left), z up.**
Let θ be the ground-plane angle between the camera and the direction the shooter faces. For a
camera with no roll, the image's horizontal axis carries

```
  image-horizontal  =  y·cos θ  −  x·sin θ
```

which gives the whole design in three lines:

| camera | θ | sees | blind to |
|---|---|---|---|
| square in front (or behind) | → 0° | stance **width**, sideways **drift**, foot yaw (if we had toes) | stagger, travel toward the rim |
| square to the side | → 90° | **stagger**, drift **toward the rim**, forward travel on the jump | stance width, sideways drift |
| 45° front-side | 45° | foot yaw best of all | **both** width and stagger: one image number mixes them in equal measure and no single camera can split it |

That last row is the non-obvious one and it is why this document asks for **two camera positions**
rather than one clever one. It is a fact about projection, not a limitation of the implementation.

Vertical is the exception: the ankle's **image row** is measured well from every bearing, at the
1–2 px the pose stage jitters. So **ground contacts, step counts, the gather and the jump's rise are
available on any view**, and only the horizontal quantities are view-gated.

θ is **measured per shot**, not assumed: the hip line's image span against Winter's biiliac breadth
(0.191 H, the prior `BodySkeletonOptions` already carries) gives |cos θ|. Its spread across the set
window is the error bar, and a number is published only when the error bar sits entirely on one side
of the decision threshold — so a jumping hip point makes ArcLab refuse the view rather than mistake a
side view for a frontal one. Only |cos θ| is recoverable this way (a hip line cannot tell a camera in
front from one behind), which is all these rules need.

### Units

Every length is in **stature units** — the shooter's ankle-to-nose image span, the same ruler
`ShotBodyResult.dipDepthNormalised` uses. Metres appear only through
`FootworkMetrics.metresPerStatureUnit`, which is itself `nil` with a reason unless a standing height
was given, and says "**stated**, not measured" when the height was typed rather than measured.
Shoulder width, for scale: 0.245 H = **0.275 stature units**.

---

## 2. The metrics

| Metric | Definition | Available when |
|---|---|---|
| `contacts` | per foot: intervals where the ankle sits within 0.020 stature of its own floor (90th percentile of its image row), after smoothing over 5 samples. A gap counts as flight only if it lasts ≥ 50 ms **and** reaches 0.30 stature/s of vertical ankle speed — a height test alone reads tracker drift as a step. | any view; refused when the ankle sits on the frame's bottom edge on > 20 % of frames (a clipped ankle's row is the border's, not the joint's) |
| `pattern` | `stationary` / `hop` / `oneTwo` / `singleStep` / `unknown` | both feet readable |
| `stepCount` | touchdowns before the lift, counting only those whose **preceding flight was fully inside the window** — a landing whose take-off predates the clip is a landing, not evidence of a step into this shot | both feet readable |
| `firstFootDown`, `firstFootDownIsShootingSide` | which foot landed first, and whether that is the shooting side | ≥ 1 touchdown and a known shooting side |
| `liftRealTime` | take-off of the **second** foot to leave the floor before the release | both feet leave the floor inside the window |
| `gatherSeconds` | **last touchdown → release**. Undefined, with that said, on a shot with no step into it. | ≥ 1 counted touchdown |
| `liftToReleaseSeconds` | take-off → release. Defined on any shot that leaves the floor, stationary ones included — this is the number a spot-up shooter actually has. | a take-off |
| `ankleSeparationImage` | the ankles' image-horizontal separation at the set ÷ stature. **What the camera measured**, before any attribution. | both ankles seen near the set |
| `stanceWidth` | side-to-side separation = separation ÷ \|cos θ\| | near-frontal view only |
| `stanceStagger` | front-back offset ÷ \|sin θ\|, **+ = the shooting-side foot is the one nearer the rim** | near-side view only, and signed only with a rim bearing |
| `footAngleToRim` | the foot's yaw against the rim bearing | **never.** Vision's body pose has no toe and no heel landmark — only the ankle — so the foot's long axis is not observed on any view at any angle. |
| `hipDriftImage` | mid-hip Δu, last plant (or the set) → release, ÷ stature, signed toward the rim when known | both hips seen at both ends, and the mid-hip never moving faster than 4 stature/s (above that the tracker lost it, and the drift is refused) |
| `hipDriftLateral` / `hipDriftTowardRim` | that drift de-projected across / along the shot line | frontal / side view respectively |
| `jumpRise` | mid-hip rise, take-off → release | a take-off |
| `jumpForwardTravel` / `jumpLateralTravel` | mid-hip travel along / across the shot line over the same interval (digest Ch 12 §12.8 `drift_m`, **sign = toward the rim**) | side / frontal view respectively |
| `viewFrontalProjection`, `viewAzimuth` | \|cos θ\| and θ, unsigned | both hips seen near the set, and the estimate on one side of a threshold |

Every one is a `FootworkValue`: a `BodyMeasure` (value, unit, unavailable reason) plus a
**provenance** string. `BodyMeasure.Unit` has no "stature" case and `BodyKinematics.swift` was not
this track's to edit, so stature lengths ride as `.ratio` with the ruler named in the provenance.

### Thresholds that are engineering, not coaching

`liftHeightStature = 0.020` (≈ 3.4 cm on a 1.70 m shooter) is 5–10× the ankle's measured 1–2 px of
jitter. `flightSpeedStaturePerSecond = 0.30`, `minimumContactSeconds = 0.05`,
`minimumFlightSeconds = 0.05`, `hipMatchToleranceSeconds = 0.08`,
`maximumHipSpeedStaturePerSecond = 4.0`. These are detector settings tied to the measurement's own
noise. They are not claims about shooting and are not graded as such.

---

## 3. "Stepping wrong", per drill, with grades

`FootworkEvaluation.evaluate(metrics, drill:, shootingSide:)`. Grades are `ShotEvidenceGrade`
(`ShotDoctor.swift` lines 1–40): **A** measured on skilled shooters or exact geometry, **B**
peer-reviewed but small-n/indirect, **C** coaching consensus with a rationale, **D** opinion or an
untested in-house hypothesis.

Every rule returns a finding **including when it could not be checked** (`severity = .unmeasured`),
because a rule that goes quiet for want of a camera angle looks exactly like a rule that passed.

| Rule | Drills | Fires on | Grade | Source |
|---|---|---|---|---|
| **Pattern matches the drill** | all | pattern ∉ the drill's expected set → `fault` | C | Definitional — the drill says what step it wants. `stationaryCatch` expects `stationary`; catch-and-shoot and both pull-ups expect `hop` or `oneTwo`. |
| **Shooting-side foot first on a 1-2** | catch-and-shoot, pull-ups | other foot first → `watch`, never `fault` | C | Coaching consensus: on the 1-2 the inside / shooting-side foot lands first and turns the hips to the rim ([Dr Dish, *1-2 vs. the Hop*](https://blog.drdishbasketball.com/basketball-shooting-footwork-1-2-vs.-the-hop); [Breakthrough Basketball forum](https://www.breakthroughbasketball.com/forum/viewtopic.php?f=63&t=1183)). **No controlled measurement shows the other order shoots worse**, which is why this can never be a fault. |
| **Hop vs 1-2 preference** | — | **not implemented, deliberately.** Coaches split on it and the honest reading of the sources is "be able to do both". Asserting a preference would be grade D dressed as advice. | — | same sources |
| **Gather ≤ 350 ms** | catch-and-shoot, pull-ups | over → `watch` | **D** | **ArcLab's own provisional ceiling** (`PLAN-1.1` Track C). No measured distribution stands behind it. Retires the moment ArcLab has ~30 of the user's own off-the-dribble shots and can use their own median. |
| **Sideways drift ≤ 0.10 stature** | all | over → `fault` | C (direction), D (number) | Lateral travel rotates the shot plane and adds a sideways velocity the release must cancel — the mechanism is sound; the 0.10 figure (about half a foot length) is ArcLab's. |
| **Travel along the shot line ≤ 0.15 stature** | all | over → `watch` | **D** | ArcLab's own. The ball metrics already measure the consequence directly as release distance; this only attributes it to the feet. Digest Ch 12 §12.8 registers the same quantity as `drift_m`, sign toward the rim. |
| **Stance width 0.20–0.36 stature** | all | outside → `watch` | C | "About shoulder width, slightly less to a little more" ([Physiopedia, *Biomechanics of the Basketball Jump Shot*](https://www.physio-pedia.com/Biomechanics_of_the_Basketball_Jump_Shot)). Shoulder width itself is 0.275 stature from Winter's biacromial 0.245 H. |
| **Stagger** | all | reported, never faulted | B | Measured: jump shooters used a ~**12 cm** stagger, shooting-side foot ahead (0.073 stature on a 1.85 m player) — Physiopedia, summarising the foot-placement literature. **Counter-evidence carried in the same source line:** [The Sport Journal, *The Effect of Foot Placement on the Jump Shot Accuracy of NCAA Division I Basketball Players*](https://thesportjournal.org/article/the-effect-of-foot-placement-on-the-jump-shot-accuracy-of-ncaa-division-i-basketball-players/) and the [ISBS take-off foot-position study](https://commons.nmu.edu/cgi/viewcontent.cgi?article=2956&context=isbs) find the staggered stance is not necessary for advanced shooters. So ArcLab **reports** your stagger and does not ask you to change it. |
| **Feet pointed at the rim** | all | `unmeasured`, **flagged `isFolklore`** | **D** | Listed so the user can see ArcLab is not quietly ignoring the most commonly given footwork cue. "Turn both feet to the rim" and its opposite, the turned "ten-and-two" stance, are both folklore: shooters at every level do both and no measurement separates them. And ArcLab could not test it anyway — no toe landmark. |

---

## 4. What the 110 phone shots actually show

`swift run -c release FootworkProbe <dir>` over
`scratchpad/phone2/body` — 110 shots, three sessions (free throws, threes, college threes), all
**stationary catch / spot-up**, all filmed side-on. Lengths in stature units.

```
pattern:  stationary=95  singleStep=9  oneTwo=3  unknown=3
contacts found on BOTH feet: 110/110; neither foot refused on any shot
contacts per shot: left  med 2 (1–3)     right med 2 (1–3)

steps before lift    n=110  med 0     p75 0      max 2
gather s             n= 15  med 0.817 (0.146–1.121)
lift→release s       n=107  med 0.154  p25 0.129  p75 0.188   (46–392 ms)
ankle sep (image)    n=108  med 0.018  p25 0.015  p75 0.026
stance width         n=  0   — refused on every shot
stance stagger       n=107  med +0.005 p25 −0.008 p75 +0.016  (−0.029 … +0.170)
hip drift → rim      n=107  med +0.032 p25 +0.026 p75 +0.039  (all positive)
hip drift sideways   n=  0   — refused on every shot
jump rise            n=107  med 0.087  p25 0.078  p75 0.104
jump forward travel  n=107  med +0.020 p25 +0.013 p75 +0.028
θ (camera off your facing direction)  n=107  med 85.7°  range 78.3–87.7°

warnings raised:  95×  ankle separation under 5× its own noise — the stagger is not trustworthy
                   3×  mid-hip jumped faster than 4 stature/s: the drift over that interval refused
                   3×  a foot on the floor for only 33 % of the window: floor level itself uncertain
evaluation:      339 of 660 findings unmeasured; 12 pattern faults (the 12 non-stationary shots
                 graded against a stationary-catch drill), no drift or travel faults
```

**What this says.**

1. **The contact detector works on real phone footage.** Both feet gave contact intervals on
   110/110 shots; nothing was refused for clipping or confidence. That is the load-bearing result:
   the machinery that will read an off-the-dribble 1-2 is proven on video we already have.
2. **The camera was 78–88° off the shooter's facing direction on every usable shot** — a true side
   view, exactly as the filming protocol asked for the *ball*. The consequence: **stance width and
   sideways drift are unavailable on all 110 shots**, and no amount of processing will change that.
3. **95/110 read as stationary**, which is correct for spot-ups. The 15 that did not are genuine foot
   resets ~0.8 s before the release (the gather median of 0.817 s is far too long to be a gather);
   they are the shooter adjusting their feet in their routine, not stepping into the shot. This is
   also the honest limit of the metric on this footage: **there is no off-the-dribble data here, so
   the 1-2 / hop branch is proven only on synthetic timelines.**
4. **Take-off to release is a tight 154 ms** (p25–p75 129–188 ms) across three sessions — a real,
   repeatable tempo number that ArcLab did not have before, and one that is available on *every*
   view.
5. **Jump rise 0.087 stature** ≈ 13 cm of hip rise from take-off to release on a 1.70 m shooter.
6. **Every shot drifts toward the rim**, 0.014–0.158 stature (median 3 cm of the user's height ≈
   5 cm), and the jump's own forward travel is +0.020 median. Consistently *into* the shot, never
   away. Under the current (grade-D) ceiling of 0.15 this fires on ~1 shot in 110 — so the ceiling is
   not doing any work yet and should be replaced by the user's own distribution.
7. **Stagger sits at +0.005 stature, straddling zero** (p25 −0.008, p75 +0.016) against a reference
   of 0.073 for a "normal" 12 cm stagger. Read literally that is a **square stance** — and it must
   **not** be acted on. `FootworkMetrics` warns whenever the measured ankle separation is under 5×
   its own per-frame noise, and **that warning fires on 95 of the 110 shots**. On a near-side view
   the far ankle is partly hidden behind the near one and pose detectors pull the hidden joint toward
   the visible one, so a square stance and an unresolvable one look identical. The number is
   published with the warning attached; the question is open until a frontal clip exists. This is the
   single strongest argument for the filming request in §6.
8. **3 shots refused the view entirely** — the hip line's image span swung enough across the set
   window to put the camera anywhere from frontal to side-on. Those same three shots previously
   produced a "drift" of −4 stature (four body heights across the image in a fraction of a second);
   the hip-speed guard now refuses them instead. Worth keeping as a tracker-failure signal for
   Track A.

---

## 5. Drill catalogue for off-the-dribble work

What ArcLab will measure, and what has to be filmed for each. "Two-position" drills need the same
reps shot twice, once per camera position — or two phones.

| Drill | What you do | ArcLab measures | Camera |
|---|---|---|---|
| **D1 Stationary form** | 10 spot-ups, no step | pattern = stationary, take-off→release, rise, tempo spread | **side** (existing protocol) |
| **D2 Catch-and-shoot, 1-2** | pass to yourself / from a partner, step in 1-2, shoot. 10 reps each side of the floor | pattern, first foot, step separation, gather, drift toward the rim | **side** for gather and rim-ward drift; **front** for width and sideways drift |
| **D3 Catch-and-shoot, hop** | same, hop gather | pattern = hop, simultaneity, gather | **side** |
| **D4 Pull-up, strong side** | one or two hard dribbles right (right-handed), gather, pull up. 10 reps | pattern, first foot, gather, **sideways drift** (the one that matters going across the floor) | **front** primary, **side** secondary |
| **D5 Pull-up, weak side** | same going left. 10 reps | as D4 — this is the one the user asked about, and the one where sideways drift is expected to appear | **front** primary, **side** secondary |
| **D6 Step-back** | dribble, step back, shoot. 10 reps | travel *away* from the rim, gather, rise | **side** |
| **D7 Stance audit** | 5 spot-ups, nothing else | stance width, stagger, square-vs-staggered, settled once and for all | **front only** |

Not in the catalogue and not planned: any drill whose grading depends on the **foot's angle**. ArcLab
cannot see it and will not pretend to. If it ever ships, it needs a foot/toe detector and a 45°
front-side camera, and the same clip will then refuse both width and stagger.

---

## 6. The filming request (what to actually do next)

The 110 shots we have answer the tempo questions and none of the lateral ones. One session fixes
that. Phone at **1080p 120 fps or better**, landscape, on something solid — a tripod, a ball rack, a
bag — not held.

**Position F — "front".** Phone on the floor line **behind the rim, facing the shooter**, or on the
baseline directly in the shooter's line to the rim. Roughly rim height to chest height, far enough
back that **both feet and the top of the head are in frame with room to spare** — the ankles must
never touch the bottom edge of the picture, which is the one thing that refuses the whole metric.
About 4–6 m behind the shooter's line works.

**Position S — "side".** The existing protocol's position: square to the side, feet and head in
frame.

Then, from the **elbow or the wing at 4.5–5.5 m**:

| # | Drill | Reps | Camera |
|---|---|---|---|
| 1 | D7 stance audit — just stand and shoot, 5 shots | 5 | **F** |
| 2 | D2 catch-and-shoot 1-2 | 10 | **F** |
| 3 | D2 catch-and-shoot 1-2 (same shots again) | 10 | **S** |
| 4 | D5 pull-up **going left** (the weak side) | 10 | **F** |
| 5 | D5 pull-up going left (again) | 10 | **S** |
| 6 | D4 pull-up going right | 10 | **F** |
| 7 | D4 pull-up going right (again) | 10 | **S** |

**70 shots, about 25 minutes.** Say out loud at the start of each clip which drill it is, or keep
them as separate recordings named for the drill — ArcLab has no drill picker yet and currently
*infers* the drill from the step pattern it measures, which cannot distinguish a left pull-up from a
right one.

If only one position is possible: **shoot Position F.** Every number Position S would add (gather,
rise, tempo) is already measured on the 110 shots we have; nothing lateral is.

---

## 7. What is open

- **No off-the-dribble footage exists.** The hop / 1-2 branch, the first-foot rule and the gather
  ceiling are proven against synthetic timelines only (`FootworkMetricsTests`). Section 6 is the fix.
- **The gather ceiling (350 ms) and the travel ceiling (0.15 stature) are grade D.** They should be
  replaced by the user's own distribution once ~30 pull-ups exist. The code already carries them as
  `FootworkNorms` values with their grade and source attached, so swapping them is one edit.
- **No drill picker in the app.** `FootworkRulesView` infers the drill from the measured pattern and
  says so on screen. A picker belongs with Track B's practice blocks: the block already knows what
  drill it is.
- **The square-stance reading needs a frontal clip** before it is repeated to the user (§4.7).
- **Foot angle is permanently unavailable** with Vision's landmark set. Revisit only if a foot/toe
  detector is added.
- **The 3 refused shots** are a tracker-failure signature (the hip line's span swinging). Worth
  handing to Track A as test cases.
- **Metres.** Every length here is a fraction of the shooter's own height; the metre conversion rides
  on a *stated* standing height and says so. A measured height, or the rim ruler when the shooter is
  at rim depth, would upgrade it.

---

## Sources

- [Dr Dish Basketball — *Basketball Shooting Footwork: 1-2 vs. The Hop*](https://blog.drdishbasketball.com/basketball-shooting-footwork-1-2-vs.-the-hop) (grade C/D: coaching blog)
- [Breakthrough Basketball forum — *Footwork of the jump shot*](https://www.breakthroughbasketball.com/forum/viewtopic.php?f=63&t=1183) (grade D: coaching opinion)
- [Physiopedia — *Biomechanics of the Basketball Jump Shot*](https://www.physio-pedia.com/Biomechanics_of_the_Basketball_Jump_Shot) (grade B/C: secondary summary of the biomechanics literature; source of the 12 cm stagger and the shoulder-width base)
- [The Sport Journal — *The Effect of Foot Placement on the Jump Shot Accuracy of NCAA Division I Basketball Players*](https://thesportjournal.org/article/the-effect-of-foot-placement-on-the-jump-shot-accuracy-of-ncaa-division-i-basketball-players/) (grade B: the counter-evidence on staggered stance)
- [ISBS — *The relationship between foot position in the take-off phase*](https://commons.nmu.edu/cgi/viewcontent.cgi?article=2956&context=isbs) (grade B)
- [Biomechanical Analysis of the Jump Shot in Basketball, PMC4234772](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4234772/) (grade B: force-plate and motion-capture jump-shot kinematics)
- `docs/reference/digest-ch12-13-angles-errorbudget.md` §12.8 — the registered `drift_m` metric and
  its toward-rim sign convention, and the `requires_front_view` idea this design generalises.
- Winter's segment table as carried in `BodySkeletonOptions`: biacromial 0.245 H, biiliac 0.191 H,
  ankle-to-nose 0.891 H.
