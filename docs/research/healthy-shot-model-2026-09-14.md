# A healthy, versatile shot — what the evidence supports, as measurable ranges

Date: 2026-09-14. Scope: turn "the metrics from the video should be more helpful" into a profile the
app can compare a session against, with every claim graded and every number sourced.

Companion to `docs/research/coaching-evidence-2026-09-13.md` (the rule-by-rule evidence review, the
folklore table, and the intervention evidence). That document is **not repeated**; this one adds the
joint-kinematics, sequencing, versatility and practice-method literature the earlier pass did not
cover, and then assembles the profile.

## 0. Grading scheme used throughout

| Grade | Meaning |
|---|---|
| **A** | Peer-reviewed measurement on skilled shooters (competitive/collegiate/pro, or large-n tracking of professionals), or exact geometry |
| **B** | Peer-reviewed but small n, recreational/novice population, indirect measure, or a result whose internal consistency is questionable |
| **C** | Expert coaching consensus with a biomechanical rationale but no controlled measurement |
| **D** | Opinion, vendor marketing, or an untested in-house hypothesis |

Two rules from `docs/BRIEF.md` and `docs/DESIGN-MEMO-2026-09-13.md` §3 govern every sentence below
and every sentence the app derives from it:

- **"Associated with", never "because."** Nothing in this literature is a demonstrated cause of a
  make for an individual shooter.
- **No target presented as universal.** Every range here is *where measured shooters sat*, not where
  this shooter should sit. The one exception is pure geometry (the entry-angle floor), which is a
  fact about a ball and a ring, not about a person.

## 1. What the trajectory literature establishes

### 1.1 Release-speed consistency is the strongest measured correlate — **A**

In 12 skilled shooters measured by video trajectory fit (the same measurement class as ArcLab),
release-**velocity** SD correlated r = −0.96 with 3-point performance and r = −0.88 with free-throw
performance; release-**angle** SD was weak (r = −0.41, p = 0.19 at 3-pt). Skilled range for velocity
SD: **0.05–0.13 m/s** at both free-throw and 3-point distance; angle SD **1.2–1.3°**.
[Slegers, Lee & Wong 2021, JSSM](https://pmc.ncbi.nlm.nih.gov/articles/PMC8256521/) — **A** (skilled
shooters, matched measurement class; n = 12, between-subject correlation).

Corroborating, indirectly: at the free-throw line misses released **−0.12 ± 0.10 m/s** below the
optimal speed vs **−0.02 ± 0.07** for swishes.
[Mullineaux & Uhl 2010](https://pubmed.ncbi.nlm.nih.gov/20552519/) — **B** (3 makes vs 3 misses per
subject).

**Why this is the metric that should lead.** Speed error converts to depth error through the range
derivative: at ~7.2 m/s over ~5.3 m, 0.1 m/s ≈ **15 cm** of depth at the rim. A 0.30 m/s SD is
therefore ±45 cm of depth — wider than the ring. That conversion is geometry, so it is **A**.

### 1.2 Depth at the rim: makes peak *past* centre — **A**

Over >50,000 NBA 3-point trajectories, make probability peaked at **11 in (27.9 cm) past the front
rim** — the ring centre is 9 in (22.9 cm) — with 9 in made 60.1 % and 10 in made 64.5 %; "depths
between 10 and 11 in maximize 3P%". Tight contests biased shots **short** and raised depth variance
**+56 %** and left-right variance **+38 %**.
[Daly-Grafstein & Bornn 2019 JQAS](https://www.lukebornn.com/papers/dalygrafstein_jqas_2019.pdf);
[2020 JSA](https://www.lukebornn.com/papers/dalygrafstein_jsa_2020.pdf) — **A** (large n,
professionals; depth is model-estimated from 25 Hz tracking, not directly measured).

### 1.3 Entry angle: a band, not a point — **A** for the band, **A** for the floor, **D** for "45"

Make probability is "more consistent over a range of entry angles compared to either left-right
distance or shot depth" (Daly-Grafstein & Bornn 2020, above) — i.e. entry angle is the *least*
peaked of the three rim-plane variables. NBA mean entry ≈ 45°. Higher-level U18 players had entry
angles closer to 45° than lower-level (p = 0.006) and 12.5 % faster release times (p = 0.002)
([Botsi et al. 2024, JFMK](https://pmc.ncbi.nlm.nih.gov/articles/PMC11677033/) — **A**, direction
only, no effect size).

Geometry (**A**, exact): a size-7 ball (0.2413 m) through an 0.4572 m ring needs entry
≥ asin(0.2413/0.4572) = **32.06°** for a clean pass to be possible at all; by 40° the margin is under
3 cm. Below 40° is therefore a statement about the ring, not about the shooter.

"45° is optimal for everyone" and "great shooters vary only ±2° in arc" are vendor claims with no
published method — **D**. See the folklore table in `coaching-evidence-2026-09-13.md`.

### 1.4 Release angle falls as distance rises — **B**

- 15 males, 3-D film: **52–55°** at 2.74/4.57 m, **48–50°** at 6.40 m
  ([Miller & Bartlett 1996](https://pubmed.ncbi.nlm.nih.gov/8809716/)) — **B** (1996, n = 15).
- 10 professionals: FT **60.8 ± 6.3°**, 2-pt **58.9 ± 7.4°**, 3-pt **56.9 ± 8.5°** (p = 0.003), and
  — importantly — *no* kinematic difference between excellent and good shooters
  ([Cabarkapa et al. 2022, JFMK](https://pmc.ncbi.nlm.nih.gov/articles/PMC9590067/)) — **A** for the
  distance pattern, **A** for the null on proficiency.
- 10 male experts across 2.8 / 4.6 / 6.4 m: accuracy fell 59 % → 37 %, release height fell
  2.46 → 2.38 → 2.33 m and release angle fell, with compensatory speed increase; **no** significant
  change in ankle, knee or hip angular displacement
  ([Okazaki & Rodacki 2012, JSSM](https://pubmed.ncbi.nlm.nih.gov/24149195/)) — **B**: the *direction*
  is consistent with everyone else, but the absolute release angles reported (78.9° close, 65.6°
  intermediate) are incompatible with every other trajectory study (49–61°), so only the direction is
  usable.

**Implication for the app:** a release-angle number is only interpretable against that shot's own
distance. Never compare a free-throw release angle to a three's.

**The distance-free version of the same question is geometry and is grade A:** for a given release
height, speed and distance there is a **depth-turnover angle** at which ∂depth/∂θ changes sign. Below
it, releasing harder sends the ball *shorter* for a given angle error; above it, the compensation
reverses. `ReleaseSensitivity.depthTurnoverAngle` computes it per shot, so the app can say where this
shooter's release angle sits relative to *their own* turnover rather than to a population.

### 1.5 Release height: direction unknown — **B**, do not assert

Contradictory across studies: made FTs 2.28 ± 0.06 m vs missed 2.19 ± 0.07 m (d = 1.85) in a 2-D
study whose uniform d ≈ 1.9 across every variable is itself a warning sign
([Wang et al. 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC13291941/), **B**); *missed* FTs had the
higher release within proficient shooters (1.19 vs 1.17 m, p = 0.035, ES 0.161)
([Cabarkapa 2023](https://pmc.ncbi.nlm.nih.gov/articles/PMC10436204/), **B**); ρ = 0.116,
η²p < 0.01 in 18 national-level players over 710 shots
([Amaro et al. 2025, JFMK](https://pmc.ncbi.nlm.nih.gov/articles/PMC12641682/), **A**). "Release as
high as possible" is **C at best and contradicted at worst**. The app should report release height and
say plainly that the literature gives it no direction.

## 2. Joint kinematics of proficient shooters

### 2.1 Elbow — **B**, and the two published directions disagree

| Finding | Numbers | Grade |
|---|---|---|
| Proficient vs non-proficient FT shooters: smaller elbow angle *and* far less lateral forearm deviation | elbow 71.9 ± 5.6° vs 80.5 ± 6.3°; forearm-from-vertical 7.9 ± 7.2° vs 19.8 ± 17.6°; knee flexion 108.5 ± 9.8° vs 117.9 ± 16.3°; DFA classifies 89.5 % | **B** — [Cabarkapa & Fry 2021, CEJSSM](https://wnus.usz.edu.pl/cejssm/file/article/download/19306/78716.pdf) (17 recreationally active males) |
| Within proficient female shooters, 3-pt makes had *smaller* elbow angle and higher release angle | elbow 47.0° vs 53.0° (p = 0.013); release angle 42.0° vs 38.0° (p = 0.020) | **B** — [Cabarkapa et al. 2023, JFMK](https://pmc.ncbi.nlm.nih.gov/articles/PMC10531893/) (18 recreationally active females) |
| Made FTs had *greater* elbow extension at release, in both athletes and novices | 158.1 ± 3.1° vs 152.3 ± 3.8° (athletes), d = 1.92; r = 0.75 with accuracy | **B** — [Wang et al. 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC13291941/) |

The conflict is definitional (interior elbow angle vs extension angle vs forearm-from-vertical), not
necessarily empirical — which is exactly why an app must not import an elbow *target*. What survives
across all three: **the elbow behaves consistently within a proficient shooter, and the group
difference is in the frontal plane (flare), not the sagittal one.** Frontal-plane forearm deviation
needs a frontal view; ArcLab's elbow numbers today are sagittal 2-D from a side view.

### 2.2 Knee and the preparatory phase — **B**

Markerless 120 Hz, 34 males (19 proficient ≥70 % FT): proficient shooters moved **slower and lower**
in preparation — knee peak angular velocity 269.4 vs 212.9 °/s (p = 0.005, ES 1.037), COM peak
velocity 1.07 vs 0.87 m/s (ES 0.988), trunk lean 1.87 vs −1.11° (ES 0.880) — with **no release-phase
differences** (release angle 52.1 ± 5.4 vs 51.4 ± 3.2, n.s.).
[Cabarkapa et al. 2023, Front Sports Act Living](https://pmc.ncbi.nlm.nih.gov/articles/PMC10436204/).
At 3-pt range (24 males): proficient knee 113.2° vs 94.3°, hip 155.9° vs 143.1°, stance 27.4 vs
34.3 cm, and again no significant release-height or jump-height difference
([Cabarkapa, Cabarkapa & Fry 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC12935449/)). Both **B**:
recreational populations, between-group, and an ES of 3.96 on a knee angle is implausible enough that
only direction should be taken.

**The consistent signal is that the difference lives in the preparatory phase, not at release.** That
is a genuinely useful re-framing for a video app: the part of the shot most apps ignore is the part
where the groups actually differ.

### 2.3 Proximal-to-distal sequencing — **B**

20 players (10 collegiate, 10 recreational), 13-camera 240 Hz, vector-coded coupling at 3.2/5/6.8 m:
collegiate athletes showed **proximal-dominant** shoulder–elbow coupling at 3.2 m and shifted to
in-phase/anti-phase at 6.8 m; recreational players showed **distal-dominance** at 3.2 m and collapsed
to in-phase (shoulder and elbow straightening simultaneously) at longer range. Coordination
variability differed between groups at 6.8 m (z = 2.111, p = 0.035).
[Jiang et al. 2025, J Hum Kinet](https://pmc.ncbi.nlm.nih.gov/articles/PMC12121896/) — **B**
(3 successful shots per distance per player).

Free-throw accuracy is "primarily determined by distal segment mechanics … supported by coordinated
shoulder–elbow–wrist sequencing", with lower limb and trunk serving as stabilisers
([Wang et al. 2026](https://www.frontiersin.org/journals/sports-and-active-living/articles/10.3389/fspor.2026.1834844/full)) — **B**.

So: **sequencing order (proximal → distal) is a real expert marker; a specific lag in milliseconds is
not published.** ArcLab's `KineticChain.proximalToDistal` flag is defensible as a *pattern* readout;
its `lagsMilliseconds` have no published reference range and must not be scored.

### 2.4 Head and eye stabilisation — **B**

Head/eye stabilisation on target discriminates experts from beginners and successful from failed
shots; "the efficiency of head and eyes stabilisation on target has a strong influence on the success
of shooting"
([Ripoll et al. 1986, Human Movement Science](https://www.sciencedirect.com/science/article/abs/pii/0167945786900059))
— **B** (1986, small n, no retrievable effect size). The quiet-eye literature gives large effects
(intervention d = 1.53, performance d = 0.84, expert–novice d = 1.04;
[Lebeau et al. 2016 meta](https://journals.humankinetics.com/view/journals/jsep/38/5/article-p441.xml))
but on weak designs, and **gaze is not measurable from a tripod**. Head *displacement* is. Treat head
stability as a **B** descriptive marker with no published pixel/metre range — report the shooter's own
SD and its trend, never a threshold.

### 2.5 Stance, trunk lean, squareness — **C**

Coaching consensus with a biomechanical rationale: feet slightly less than shoulder width, shooting
foot slightly forward, minimise horizontal COM travel, release near the top of the jump
([Knudson 1993, JOPERD](https://www.tandfonline.com/doi/abs/10.1080/07303084.1993.10606710)) — **C**.
The measured support is thin and partly contrary: proficient 3-pt shooters had a **narrower** stance
(27.4 vs 34.3 cm) than non-proficient (Cabarkapa 2026, **B**), and trunk lean did not separate made
from missed FTs (5.5 ± 1.7° vs 6.1 ± 2.0°, p = 0.20, d = 0.33; Wang 2026, **B**). There is **no
published squareness range**. Shoulder-line yaw is a descriptive, within-shooter consistency measure
only.

### 2.6 Set point, one-motion vs two-motion, "elbow under the ball" — **C/D**

No peer-reviewed comparative biomechanical study of one-motion vs two-motion shooting was found
(searched 2026-09-14). "Set point above the eyebrow", "one-motion is faster, two-motion is more
powerful", "keep the elbow under the ball" are **C** at best and **D** as stated — the elbow claim is
a between-group association only, and excellent vs good professionals showed *no* kinematic
differences at all (Cabarkapa 2022, **A** null). **Do not ship a set-point or elbow-alignment target.**

### 2.7 The dip — **A** for an acute effect, **D** as a permanent prescription

36 elite males (18 HS, 18 university), within-subject with and without a dip at four distances
(3.125–6.75 m): **7–9 % accuracy gain**, F(1,17) = 27.6 (HS) and 53.1 (university), p < 0.001
([Penner 2021, Front Psychol](https://pmc.ncbi.nlm.nih.gov/articles/PMC8273237/)) — **A** for the
population and design class, with the caveat that it is unblinded, single-session and acute, with no
retention test. The **timing** of the dip (dip-bottom to release) has no published reference range;
high-level U18s released 12.5 % faster than lower-level (Botsi 2024, **A**, direction only).

## 3. Consistency vs accuracy — what "repeatable" actually means

1. **Variability of the release *parameters* is what tracks performance**, and specifically the speed
   channel (§1.1, **A**). Angle variability is a weak correlate.
2. **Not all variability is bad.** The accurate shooter's cost function combines tolerance, noise and
   covariation; "C-cost is smaller for the participant whose shot probability of success was high"
   ([Nakano, Fukashiro & Yoshioka 2018, ISBS](https://commons.nmu.edu/isbs/vol36/iss1/32/)) — **B**
   (conference abstract, qualitative). Individual optimal release angles sit 4.3 ± 2.1° above the
   minimum-velocity angle and correlate r = 0.78 with the shooter's own release covariance
   ([Slegers 2022, IJPAS](https://digitalcommons.georgefox.edu/mece_fac/129/)) — **A**. In plain
   words: **the right release angle depends on the shape of your own error, so it is individual by
   construction.**
3. **Coordination variability is not a fault either.** Collegiate athletes' coupling variability was
   *highest* at their mid distance, not lowest (Jiang 2025, **B**) — compensating variability is how
   skilled performers absorb noise.
4. **Detectability floor (in-house, geometry + statistics).** The ratio of two depth SDs detectable at
   95 % is 1.36× at n = 30 per side, 1.28× at 50, 1.20× at 100, 1.14× at 200
   (`DESIGN-MEMO-2026-09-13.md` §3.5) — **A** as arithmetic. Below ~100 shots the app cannot honestly
   claim a consistency change smaller than 20 %.

## 4. What "versatile" means measurably

"Versatile" is not one number. Four things in the literature can stand in for it:

| Facet | What the evidence says | Grade |
|---|---|---|
| **Holds up with distance** | Accuracy falls 59 % → 37 % from 2.8 m to 6.4 m in experts; release height and angle fall and speed rises ([Okazaki & Rodacki 2012](https://pubmed.ncbi.nlm.nih.gov/24149195/)). The *versatile* signature is that the adaptation is smooth and the speed SD does not inflate with distance — Slegers 2021 found skilled velocity SD was the **same** at FT and 3-pt (0.086 vs 0.089 m/s). | **A** |
| **Holds up under pressure** | 18 national-level players, 90 shots each, with simulated 105 dBA crowd noise and a 1.2×-height defender at 1 m: **no significant effect of opposition or noise on jump height, release height, release angle or release velocity** (all p ≥ 0.092, η²p ≤ 0.004) ([Amaro et al. 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12641682/)). At skilled level, release parameters are *already* robust to a defender; the NBA in-game contest effect is on **variance** (+56 % depth, +38 % lateral), not on the mean ([Daly-Grafstein & Bornn 2020](https://www.lukebornn.com/papers/dalygrafstein_jsa_2020.pdf)). So the versatile signature is **unchanged depth/lateral SD across conditions**, not unchanged mechanics. | **A** |
| **Holds up under fatigue** | 12-min simulated game, 38 high-level players: entry angle −3.1 to −3.9 %, release time +15 to +25 %, makes −14 to −19 % ([Bourdas et al. 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC10974731/)). But elite U18s showed **zero** release change after repeated sprints ([Slawinski et al. 2018](https://pmc.ncbi.nlm.nih.gov/articles/PMC6006537/)). Meta-analysis: accuracy SMD 0.67 moderate / 1.39 severe ([Li et al. 2025](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2025.1435810/full)). **Drift must be measured per player, never assumed.** | **A** |
| **Holds up off the dribble** | Catch-and-shoot outperforms off-the-dribble by ~20 % (NBA) to ~40 % (college women) in observational play-type data ([Breakthrough Basketball's analytics summary](https://www.breakthroughbasketball.com/training/shooting-analytics-19)) — **D** as cited (aggregator, no method). No peer-reviewed kinematic comparison of catch-and-shoot vs off-the-dribble release parameters was found. | **D** |

**The honest one-line definition ArcLab can defend:** a versatile shot is one whose **release-speed SD
and depth SD do not inflate when the distance, the condition or the fatigue state changes** — a
statement about *stability of spread*, which is exactly what a per-cell SD history measures, and
which needs at least two comparable cells or two comparable sessions to say anything about.

## 5. What actually moves these numbers

| Method | Best evidence | Effect | Grade |
|---|---|---|---|
| **The dip** | Penner 2021, 36 elite males, within-subject | +7–9 % accuracy, acute, unblinded, no retention | **A** (acute only) |
| **Variable / variable-distance practice** | [Shoenfelt et al. 2002](https://journals.sagepub.com/doi/10.2466/pms.2002.94.3c.1113), 94 participants, 3 weeks, randomised | Variable **equalled** constant on delayed retention despite worse practice performance | **B** |
| **Random vs blocked scheduling** | [Shamshiri et al. 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12481044/), 84 novice females, randomised | Blocked best in acquisition (1.79 vs 1.11–1.52), **worst** in retention (1.28 vs 1.69–1.73, ηp² = 0.24) and transfer (0.54 vs 1.27–1.38) | **B** (novices, 3 days) |
| **External focus cues** | [McKay et al. 2024 bias-corrected meta](https://pmc.ncbi.nlm.nih.gov/articles/PMC8256521/ "see digest Ch 17 C-1") | g = 0.01 performance, 0.15 retention, 0.09 transfer — Bayes factors favour the null | **A** for the null |
| **Reduced / faded feedback frequency** | McKay et al. 2022, 61 papers, k = 75, N = 2,228 | No significant effect at any time point; "robust evidence is lacking" | **A** for the null |
| **Trajectory/AR feedback (what ArcLab is)** | [Ueyama & Harada 2024, Sci Rep](https://pmc.ncbi.nlm.nih.gov/articles/PMC10776772/), 20 novices randomised | AR group 22.0 → 41.0 % (p = 0.0039), control 33.0 → 34.5 % (p = 0.70), **no significant between-group difference**; baseline imbalance | **B** |
| **Self-controlled video feedback** | [Aiken, Fairbrother & Post 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3438820/), 28 novice women | Better *form* on transfer (η² = 0.153), **no accuracy difference** | **B** |
| **Quiet-eye training** | [Lebeau et al. 2016 meta](https://journals.humankinetics.com/view/journals/jsep/38/5/article-p441.xml) | QE d = 1.53, performance d = 0.84 — weak designs, unmeasurable by ArcLab | **B** |
| **Constraints-led / game-based training** | [quasi-experimental 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC13293939/) | Transfer mediated by psychological readiness; quasi-experimental, no shooting-mechanics outcome | **C** |

**The uncomfortable conclusion, and it must be shipped as such:** nothing in this table licenses "do
X and your percentage rises N %". The two cue-delivery beliefs a shooting app would most naturally
adopt — external focus and faded feedback — are the two with grade-**A** *null* meta-analyses against
them. What ArcLab can honestly do is (a) measure within-player associations, (b) measure drift on the
player's own session, and (c) run the player's own A/B with a frozen baseline and a retention test.

## 6. The profile — "a healthy, versatile shot" as measurable ranges

Read every row as *"measured shooters in this population sat here"*, never as *"you should sit here"*.

| # | Measure | Where measured shooters sat | Grade | Established, or lore? |
|---|---|---|---|---|
| 1 | **Release-speed SD** (per spot) | 0.05–0.13 m/s, and the same at FT and 3-pt | **A** | Established, and the strongest single correlate |
| 2 | **Depth SD at the rim** | derived: ±0.05–0.13 m/s ≈ ±7–20 cm of depth | **A** (geometry) | Established as arithmetic |
| 3 | **Mean depth past front rim** | makes peak 25–28 cm (10–11 in); ring centre 22.9 cm | **A** | Established for NBA 3-pt; unstudied for youth/practice |
| 4 | **Left-right SD** | mean offset ≈ 0; *consistency* is what predicts (spin-axis SD r = 0.80) | **A** | Established that the **variance** matters, not the mean |
| 5 | **Entry angle mean** | NBA ≈ 45°, makes cluster mid-40s, probability flat over a range; ≥ 32.06° is geometric necessity, ≥ 40° for a 3 cm margin | **A** band / **A** floor | Band established; "45 for everyone" is **D** lore |
| 6 | **Release angle** | 52–55° at 2.7–4.6 m, 48–50° at 6.4 m (amateur/collegiate); pros 60.8/58.9/56.9° FT/2-pt/3-pt; individual optimum sits 4.3 ± 2.1° above each shooter's minimum-speed angle | **B** ranges / **A** individuality | Distance pattern established; a single correct angle is lore |
| 7 | **Release angle vs own depth-turnover angle** | below turnover, speed and angle errors **compound**; above it they partly cancel | **A** (geometry, per shot) | Established arithmetic — and distance-free, so it beats row 6 |
| 8 | **Release height** | 2.15–2.47 m across studies; **direction of effect unknown** | **B** | Contradictory — never assert a direction |
| 9 | **Dip present** | +7–9 % accuracy, acute, elite males | **A** (acute) | Established acutely; "always dip" is lore |
| 10 | **Dip-to-release time** | no published reference range; higher-level U18 released 12.5 % faster | **A** direction / **D** range | Only the *consistency within a shooter* is safe to show |
| 11 | **Elbow at release** | disputed by definition: 71.9 ± 5.6° (proficient, interior) / 158.1 ± 3.1° (made, extension) | **B** | Only within-shooter consistency is safe |
| 12 | **Forearm/elbow flare (frontal)** | proficient 7.9 ± 7.2° vs 19.8 ± 17.6° from vertical | **B** | Needs a frontal view; between-group only |
| 13 | **Knee flexion minimum** | 108.5 ± 9.8° (proficient FT) vs 117.9 ± 16.3°; 113.2° vs 94.3° at 3-pt | **B** | Direction only; the two studies disagree in sign by distance |
| 14 | **Preparatory-phase speed** | proficient move **slower**: knee peak 212.9 vs 269.4 °/s; COM 0.87 vs 1.07 m/s | **B** | The most interesting under-used finding |
| 15 | **Sequencing** | proximal-dominant shoulder→elbow in collegiate; distal-dominant/in-phase in recreational | **B** | Pattern established; no published lag in ms |
| 16 | **Head stability dip→release** | no published range; stabilisation on target discriminates success | **B** | Within-shooter SD and trend only |
| 17 | **Stance width** | proficient 3-pt shooters **narrower** (27.4 vs 34.3 cm); coaching says "shoulder width" | **B** / **C** | Coaching consensus is not supported in the direction claimed |
| 18 | **Squareness (shoulder-line yaw)** | no published range at all | **C** | Lore. Consistency only |
| 19 | **Trunk lean** | did not separate made from missed (p = 0.20, d = 0.33); proficient less forward lean | **B** | Weak |
| 20 | **Set point height, one- vs two-motion** | no comparative study found | **C/D** | Lore — do not ship a target |
| 21 | **Within-session drift** | entry −3 to −4 %, release time +15–25 % after 12 min simulated game; **zero** after sprints in elite U18 | **A** | Established that it *can* happen; measure, never assume |
| 22 | **Spread stability across distance/condition** | skilled velocity SD equal at FT and 3-pt; defender/noise changed **nothing** in release parameters at national level, but raised depth variance 56 % in NBA games | **A** | The defensible definition of "versatile" |

### Individual-variation caveats that must travel with the profile

1. **Excellent and good professionals showed no kinematic differences at all** (Cabarkapa 2022) — the
   between-group studies above separate *proficient from non-proficient*, not *good from great*.
2. **The optimal release angle is a function of the shooter's own error covariance** (Slegers 2022,
   r = 0.78) — so the same "correct" angle is wrong for two different shooters.
3. Most joint-kinematics numbers come from **recreationally active** samples of 17–34, measured
   between groups, at one session. They are hypotheses about a shooter, not descriptions of one.
4. **Nothing here is measured on youth or on practice shots.** ArcLab's per-cell baselines will be the
   first such reference for each user; that is the product, not a limitation to hide.

## 7. Mapping the profile onto what ArcLab can measure today

Sources: `App/Sources/BlockSummary.swift` (`BlockRow`, `BlockStat`) and
`Packages/ShotGeometry/Sources/ShotGeometry/BodyKinematics.swift` (`BodyModel`). Trust levels are the
shooter-report position of 2026-09-14: 2-D-derived cues good; 3-D angles noisy; metres from the body
model unreliable.

| Profile row | Healthy range / pattern | Grade | In `BlockRow` today? | What the app shows/says now | What unlocks the rest |
|---|---|---|---|---|---|
| Release-speed SD | 0.05–0.13 m/s | A | ✅ `releaseSpeed` | Says line + work-on rule, scored in **cm of depth at the rim**; profile row vs the skilled band | nothing — shipped |
| Depth spread and its cause | ±7–20 cm | A | ✅ `depthPastFrontRim`, + θ/v/h for the Ch 5 delta method | Says line splitting depth variance into speed / angle / height shares at n ≥ 20 | nothing — shipped |
| Mean depth | 25–28 cm past front rim | A | ✅ | Profile row; miss front/back pattern at ≥ 5 inferred misses | outcome tags raise the miss-pattern n |
| Left-right SD | mean ≈ 0, variance is the signal | A | ✅ `lateralDeviation` | Profile row with the frontal/oblique-view caveat | a frontal or 45° camera position for tier-A lateral |
| Entry angle | mid-40s band, 40° margin, 32.06° floor | A | ✅ `entryAngleDegrees` | Says line + flat-arc work-on rule | nothing — shipped |
| Release angle vs distance | falls with distance | B | ⚠️ distance re-derived from the shot's own fit | Profile row states the shot's estimated distance alongside the angle | **TODO(BlockRow): `releaseDistance`** from `ShotMetrics.release?.distance` |
| Release angle vs own turnover | geometry, per shot | A | ⚠️ derived from θ, v, h, L | Profile row: degrees above/below this shooter's own turnover angle | same `releaseDistance` TODO removes the re-derivation |
| Release height | no direction | B | ✅ `releaseHeight` | Profile row that explicitly says the literature gives no direction | nothing — shipped |
| Dip-to-release time | consistency only | A dir. / D range | ✅ `dipToReleaseSeconds` | Says line (side views), profile row, and the **within-session r against release speed at n ≥ 15** | nothing — shipped; the correlation is reported as grade D |
| Elbow at release | within-shooter consistency only | B | ✅ `elbowAtReleaseDegrees` (2-D, side only) | Profile row, side-view only, labelled relative-only | 3-D elbow needs the body model's 3-D trust to improve |
| Elbow flare (frontal) | 7.9 ± 7.2° proficient | B | ❌ | nil-with-reason row | frontal view class + `BodyKinematics` frontal forearm angle; **TODO(BlockRow): `forearmFromVerticalDegrees`** |
| Knee flexion minimum | direction only | B | ✅ `kneeMinimumDegrees` (2-D) | Profile row, side-view only | — |
| Preparatory-phase speed | proficient move slower | B | ❌ | nil-with-reason row | **TODO(BlockRow): `kneeExtensionPeakDegreesPerSecond`** from `KineticChainEvent.peakRateDegreesPerSecond` |
| Sequencing proximal→distal | pattern only | B | ❌ | nil-with-reason row | **TODO(BlockRow): `proximalToDistal: Bool?`** from `KineticChain.proximalToDistal`. Show the **pattern**, never the lag in ms |
| Head stability | within-shooter only | B | ❌ | nil-with-reason row | **TODO(BlockRow): `headStabilityPx`** from `HeadMetrics.stabilityPx`. Needs a fixed tripod and a pixel-to-scale note before it can be compared across sessions |
| Squareness | no published range | C | ❌ | nil-with-reason row | **TODO(BlockRow): `shoulderLineYawDegrees`** from `StanceMetrics.shoulderLineYaw`. **3-D yaw is in the noisy class today — do not show a number until the 3-D trust level is re-established** |
| Stance width | narrower in proficient 3-pt | B | ❌ | nil-with-reason row | `StanceMetrics.feetSeparation` is in **metres from the body model, which is the unreliable class** — must not be shown until the metre scale is validated against the rim calibration |
| Set point height | no evidence | C/D | ❌ | **not shown at all**, by design | nothing unlocks it; there is no range to compare against |
| Within-session drift | measure, never assume | A | ✅ shot order over `rows` | Work-on rule at \|change\| > 2 SD | — |
| Spread stability across cells | the versatility definition | A | ❌ (one block at a time) | not shown | needs the multi-block/multi-session comparison the card does not see; the card says so |

**Metrics that need better tracking before they are shown at all:** stance width and any other body
metre (`metres` unit from `BodyModel`), 3-D shoulder-line yaw and 3-D joint angles, kinetic-chain lags
in milliseconds, and head stability across sessions (pixel units are camera-position dependent).
Sequencing **order** and head-stability **within-session SD** are safe as patterns; their numbers are
not comparable across setups.

## 8. Sources

All URLs cited inline above. New this pass (not in `coaching-evidence-2026-09-13.md`):
[Okazaki & Rodacki 2012](https://pubmed.ncbi.nlm.nih.gov/24149195/) ·
[Jiang et al. 2025 arm-joint coordination](https://pmc.ncbi.nlm.nih.gov/articles/PMC12121896/) ·
[Amaro et al. 2025 constraints](https://pmc.ncbi.nlm.nih.gov/articles/PMC12641682/) ·
[Wang et al. 2026 free-throw 2-D](https://pmc.ncbi.nlm.nih.gov/articles/PMC13291941/) ·
[Ripoll et al. 1986 head/eye stabilisation](https://www.sciencedirect.com/science/article/abs/pii/0167945786900059) ·
[Knudson 1993 six teaching points](https://www.tandfonline.com/doi/abs/10.1080/07303084.1993.10606710) ·
[Sirnik, Erčulj & Rošker 2022 visual-attention meta](https://journals.sagepub.com/doi/full/10.1177/17479541221075740) ·
[constraints-led transfer 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC13293939/).
