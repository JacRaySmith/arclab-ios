# Ball handling, and the practice→game gap — what is actually known

Date: 2026-09-19. Written for 1.4 "game", from the user's two sentences:

> *"I want to add ball handling drills. These should be as applicable to game situations as possible."*
>
> *"There is often a big split between practice shooting and game shooting. Try to address this."*

Grades are the same A–D scheme as everywhere else
(`docs/research/healthy-shot-model-2026-09-14.md` §0, mirrored in `ShotEvidenceGrade`):
**A** peer-reviewed on skilled players / large-n professional tracking / exact geometry ·
**B** peer-reviewed but small n, novice or single-team sample, or indirect ·
**C** coaching consensus with a rationale, no controlled measurement ·
**D** opinion, vendor marketing, or an untested in-house hypothesis.

Shipped as the `ballHandling` and `handlingUnderPressure` modules in
`Packages/ShotGeometry/Sources/ShotGeometry/Curriculum.swift`, the game-like block variants in
`NextBlock.swift`, and the game log + practice-vs-game comparison in `GameTransfer.swift` /
`App/Sources/GameLogView.swift`.

---

## 0. The one-line summary

**Ball handling is the least evidenced thing ArcLab has ever shipped, and the app cannot measure any
of it.** Nothing in this document justifies a number on a screen. What it justifies is a set of
drills tied to game situations, labelled C and D, with gates the *shooter* counts and the app says it
did not measure — plus one thing the app genuinely can do: measure the **shot that comes out of the
handling**, which is the same shot it already measures.

The practice→game gap is better evidenced than the handling is. There is a measured gap
(grade B), a measured mechanism for part of it (grade A), and a practice-schedule literature that
speaks directly to transfer (grade B). That is what the game-like block variants and the game log are
built on.

---

## 1. Ball handling: what evidence exists

### 1.1 What was searched (2026-09-19)

Searched: a randomised or controlled trial of dribbling / ball-handling training with a **game**
outcome; any measurement of a ball-handling drill transferring to game ball security; any published
reference range for a dribbling measure in skilled players.

**Not found.** No peer-reviewed controlled trial was located in which a ball-handling drill programme
was measured against game ball-handling performance in skilled players. The nearest hits:

| Study | What it is | Grade | Why it does not settle the question |
|---|---|---|---|
| [Effects of CrossFit™ versus regular training on physical fitness and skills in U12 basketball players — RCT](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12303471/) | 40 male U12s, 8 weeks, 4 sessions/week, randomised; experimental group improved "full-court dribble to layup" and 1-min shooting | **B** for the trial, **D** for our question | The intervention is conditioning, not ball handling; the outcome is a drill test, not a game. U12. *(Retrieved via search summary; effect sizes NOT verified by direct fetch — **UNVERIFIED**.)* |
| [Effectiveness of Dribbling Exercise Variations on Improving the Dribbling Ability of Basketball Players (IJOK)](https://journal.unesa.ac.id/index.php/IJOK/article/view/37204) | Dribbling-variation training vs control, dribbling test outcome | **D** | Non-indexed journal, method not retrieved, outcome is the trained test itself. **UNVERIFIED** — listed only so the absence is visible. |
| [Acquisition of a Complex Basketball-Dribbling Task in School Children as a Function of Bilateral Practice Order](https://www.researchgate.net/publication/51243958_Acquisition_of_a_Complex_Basketball-Dribbling_Task_in_School_Children_as_a_Function_of_Bilateral_Practice_Order) | Bilateral (weak-hand-first vs strong-hand-first) practice order, school children | **B** for the learning question, **D** for ours | School children, acquisition of a lab task, no game outcome. **UNVERIFIED** — abstract only. |
| [Breakthrough Basketball — ball-handling fundamentals](https://www.breakthroughbasketball.com/fundamentals/ballhandling) | Coaching content | **D** | Aggregator with no method. Cited as the *origin* of the conventions below, never as evidence. |

**Therefore every "this drill improves your handling" claim in the `ballHandling` module ships as
C (coaching consensus with a rationale) or D (convention nobody has tested).** Specifically graded D:
two-ball drills, stationary cone series, and any claim about which move beats a defender.

### 1.2 What *is* known, and is worth borrowing

Two findings from the existing ArcLab research carry over to handling drills without being about
handling:

1. **Practice schedule affects transfer, not practice performance.**
   [Shamshiri et al. 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12481044/) (84 novice females,
   randomised, 3 days): one-condition practice was best *during* practice (1.79 vs 1.11–1.52) and
   **worst** on a later test (1.28 vs 1.69–1.73, ηp² = 0.24) and worst on transfer (0.54 vs
   1.27–1.38). Grade **B** — novices, three days, so the size of the effect in a 300-rep high-school
   player is unknown. This is the single strongest reason to ship shuffled, decision-coupled drills
   rather than a cone course.
2. **Varying the practice condition costs nothing.**
   [Shoenfelt et al. 2002](https://journals.sagepub.com/doi/10.2466/pms.2002.94.3c.1113) (94
   participants, 3 weeks, randomised): variable practice **equalled** constant practice on delayed
   retention despite looking worse during practice. Grade **B**.

Neither study used a ball-handling task. Applying them to dribbling is an **inference**, graded
**C**, and the module says so in those words.

3. **Game-based / constraints-led training**:
   [quasi-experimental 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC13293939/) — transfer mediated
   by psychological readiness, no shooting-mechanics outcome, not randomised. Grade **C**. It
   supports "make the drill look like the game" as a coaching principle; it measures nothing about
   mechanics.

### 1.3 What ArcLab can and cannot measure about handling

**Cannot, today and with no plan to:** dribble height, hand speed, how many dribbles, whether the
ball was ever loose, whether the defender was beaten, whether the pocket pass was open. The app has
**no ball-handling metric**. There is no detector, no reference range, and nothing filmed.

**Can:** the shot that comes *out* of the handling — release speed and its spread, entry angle, depth
past the front of the ring, left/right at the ring. That is the same measurement class the
`offTheDribble` module already uses, and it is the only honest gate a handling module can close on.

So every drill in `ballHandling` has one of two gate shapes, and the module says which:

* **counted by you, not measured by the app** — a self-timed or partner-scored count, stated in
  those words (`DoneCheck.unavailableReason`), or
* **the shot afterwards** — an ordinary `PassCheck` on release-speed spread or depth, scored exactly
  the way a plan is.

No third shape exists. A fabricated "handling score" would break CLAUDE.md rule 1.

---

## 2. The practice→game gap

### 2.1 The gap is real and has been measured

[Kozar, Vaughn, Lord & Whitfield 1995, *Journal of Sport Behavior* 18(2):123–129 — "Basketball
free-throw performance: practice implications"](https://go.gale.com/ps/i.do?id=GALE%7CA17175398&sid=googleScholar&v=2.1&it=r&linkaccess=abs&issn=01627341&p=AONE&sw=w):
practice free-throw percentage was **significantly higher** than game free-throw percentage for one
NCAA team across two seasons.

Grade **B**: one team, two seasons, retrospective. **The magnitude is UNVERIFIED** — the full text is
behind Gale and only the finding's direction was retrievable on 2026-09-19. The app therefore quotes
the *direction* ("players usually shoot better in practice than in games") and never a percentage
from this paper. Any number the app shows for the gap is the **user's own**, computed from their own
log.

This is the citation behind the whole game-log feature: the gap is not folklore, but its size is
personal and has to be measured on the individual.

### 2.2 What changes between practice and a game — and what does not

| What changes | Evidence | Grade |
|---|---|---|
| **Scatter under a contest**, not technique: in NBA tracking, tightly contested shots were biased short and scattered **56 %** more front-to-back and **38 %** more left-to-right | [Daly-Grafstein & Bornn 2020](https://arxiv.org/abs/1908.03377) (>50 000 tracked trajectories) | **A** |
| **Release mechanics do not change** for skilled shooters under a defender or crowd noise: no significant effect of a 1.2×-height defender at 1 m or 105 dBA noise on jump height, release height, release angle or velocity (all p ≥ 0.092, η²p ≤ 0.004) | Amaro et al. 2025, 18 national-level players, 90 shots each | **A** for the null |
| **Fatigue moves the shot** — after 12 min of simulated game load in 38 high-level players: entry angle −3.1 to −3.9 %, release time +15–25 %, makes **−14 to −19 %** | Bourdas et al. 2024; [Li et al. 2025 meta](https://pmc.ncbi.nlm.nih.gov/articles/PMC12481044/ "see healthy-shot-model §4") k = 14, n = 388, accuracy SMD 0.67 moderate / 1.39 severe | **A** |
| …but **not for everyone**: elite U18s showed **zero** release change after repeated sprints | Slawinski et al. 2018 | **A** for the exception |

Read together these say something precise and slightly counter-intuitive, and it is what the
game-like blocks are built on: **a defender does not change a skilled shooter's technique — it
changes how much the result scatters, and tiredness is the one condition that moves the shot itself,
for some players and not others.** So the honest game-like block is one that measures **spread**
across conditions, and measures fatigue drift **on you** instead of assuming it.

### 2.3 What a game-like block can and cannot claim

The app records the same shot numbers in a game-like block as in any other block. It **cannot see the
defender, the clock, the score, or the call**. So:

* A contested block's grade is **A for the measure** (release-speed spread, depth) and **D for the
  claim that the partner's closeout resembles a game defender** — nobody has measured that.
* A decision-coupled block's grade is **C** (constraints-led consensus) and what the app stores is
  whatever the user types in: which call was made. It is self-reported, and the screen says so.
* A fatigued block's grade is **A**, because the 12-minute game-load protocol is the one condition in
  this table with a measured effect on the shot — and the block exists to find out whether *this*
  shooter is a Bourdas player or a Slawinski player.
* A random-spot block's grade is **B** (Shamshiri, Shoenfelt — novices), and it is the one variant
  where the app knows the whole sequence in advance, because it generated it. **It shuffles sets,
  not single shots**, and that is a measurement limit rather than a preference: one recording is
  saved at one spot, and the brief's own rule is that shots from different spots are different
  populations and are never pooled. A block holding one shot from each of four spots would have to
  label all four with one spot — a number nobody measured. So a one-shot-per-spot drill is a thing
  ArcLab cannot measure at all, and the shipped variant says so on its own card.

### 2.4 Why the app must not just tell the user "shoot better in games"

Two limits, both stated on the screen:

1. **Make rates need shots.** Comparing two make rates is comparing two proportions. At n = 20 a side
   and rates near 50 %, the smallest difference distinguishable from chance at 95 % is about
   **31 percentage points** (1.96 × √(0.25/20 + 0.25/20)); at n = 50 a side, about 20 points; at
   n = 100 a side, about 14. So a game log with 12 shots in it can say almost nothing, and the app
   says that instead of drawing a chart. The floor shipped is **20 counted shots on each side**,
   reused from `ShotDoctor.attributionFloor` rather than invented, and the smallest tellable
   difference is printed **at the user's own n** every time.
2. **A practice make is inferred, a game make is typed.** ArcLab's practice make/miss comes from
   `RimOutcome.infer` watching the ball at the ring, and it returns `unknown` when it did not see the
   ball resolve. Game shots are entered by hand from memory. These are two different measurement
   processes, and pooling them into one percentage would be dishonest. They are shown side by side,
   with both n's, and never added together.

---

## 3. What ships, and at what grade

| Thing | Grade | Basis |
|---|---|---|
| `ballHandling` module exists and is taught after the base | **C** | Coaching consensus; no teaching-order study exists (same position as the rest of the curriculum). |
| Each handling drill "improves your handling" | **C**/**D** per drill | §1.1. Stated in each drill's `why`. |
| Handling drills should be shuffled and decision-coupled rather than blocked | **C** (inference from **B**) | Shamshiri 2025, Shoenfelt 2002 — not on a handling task. |
| Two-ball drills | **D** | Convention. No trial found. |
| The shot after the move can be measured and scored | **A** | Same measures, same gates as every other module. |
| A contest widens scatter without moving technique | **A** | Daly-Grafstein & Bornn 2020; Amaro et al. 2025. |
| Game load costs makes and entry angle, for some players | **A** | Bourdas 2024; Li 2025; Slawinski 2018 for the exception. |
| Practice % > game % | **B**, magnitude **UNVERIFIED** | Kozar et al. 1995. |
| The floor of 20 shots a side, and the printed detectable difference | **A** (arithmetic) | Wald interval on a difference of proportions; `GameTransfer.detectableMakeRateDifference`. |

---

## 4. Explicitly UNVERIFIED

1. Kozar et al. 1995's **effect size** — direction only. Do not quote a percentage from it.
2. The CrossFit U12 RCT's effect sizes and the IJOK dribbling paper's method — search summaries only.
3. The bilateral-practice-order dribbling study — abstract only.
4. **No ball-handling drill in this app has ever been tested against anything**, including by the
   user. Every gate in `ballHandling` is a design until somebody shoots it.
5. Whether a partner closeout resembles a game contest at all. Assumed by every coach; measured by
   nobody found.

---

## 5. Searched and not found (2026-09-19)

* A controlled trial of ball-handling training with a game ball-handling outcome.
* Any published reference range for dribble height, hand speed, or change-of-direction time in
  skilled basketball players.
* Any measurement of "escape dribble", "pocket dribble" or "retreat dribble" as distinct skills.
* A replication of Kozar et al. 1995 with modern tracking data.

Each of those absences is what produces a **C** or **D** above rather than a silence.
