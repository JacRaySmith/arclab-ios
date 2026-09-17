# Digest — Ch 15 (Fault engine: rules as data, comparisons, baselines, ranking) and Ch 16 (Differential diagnosis, retest, regression to the mean, confounding, efficacy)

Source: TEXTBOOK.md Ch 15 (lines 14864–15522), Ch 16 (lines 15524–16626). Tier vocabulary from
NOTATION.md: Tier A physics/geometry; Tier B deviation from the shooter's own distribution; Tier C
descriptive; Unmeasurable = honest refusal. `tier` is never a severity; priority is `rank`.
Diagnosis confidence and cause confidence are separate; cause confidence is per cause.

---

## Ch 15 — The fault engine

### 15.1 Rules as data `[DEC]`
Each fault is a YAML entry; the engine is generic (reviewable by a coach, diffable in tests).
The `flat_arc` entry is the spec of every engine capability:
```yaml
- id: flat_arc
  tier: A
  metric: entry_angle_deg
  condition: { mean_lt: 40 }
  min_n: 15
  evidence: "Mean entry angle {mean:.1f}° (n={n}). Below 32° a clean swish is
             geometrically impossible; below 40° margin is under 3 cm."
  cost_model: entry_margin            # used for ranking
  causes:
    - id: range_strength
      discriminator: { protocol: distance_ladder, expect: "arc degrades with distance" }
    - id: leg_drive
      discriminator: { metric: knee_ext_velocity_dps, compare: within_shooter_split,
                       expect: "lower on flattest quartile" }
    - id: push_release
      discriminator: { metric: release_x_offset_m, compare: within_shooter_split,
                       expect: "larger on flattest quartile" }
    - id: early_wrist
      discriminator: { metric: elbow_angle_release_deg, compare: within_shooter_split }
    - id: fatigue
      discriminator: { metric: entry_angle_deg, compare: trend_over_session }
    - id: deliberate
      discriminator: { ask_user: "Do you shoot flat on purpose?" }
  cue: "Shoot so the ball drops through the top of the rim, not the front."
```
Keys: `id, tier, metric, condition, min_n, evidence, cost_model, causes, cue`. Discriminator
kinds: `{metric, compare, expect}`, `{protocol, expect}`, `{ask_user}`. Build the engine to
consume exactly this and nothing more.

### 15.2 Loading YAML safely
- `safe_load` only (never `load`). Validate every rule against a schema at load: key set, types,
  `metric` exists in the Ch 2 registry, `tier ∈ {A, B, C}`. Unknown keys are silently ignored by
  YAML → a typo'd key quietly disables a rule.
- YAML 1.1 type traps: `yes/no/on/off` → booleans; `1e3` → the **string** `'1e3'` (`1.0e3` →
  float 1000.0); `null` and `~` → None; `.nan` → float NaN; `'40'` stays a string; `00:40` → string.
  Never let an id/metric/cue be an unquoted yes/no/on/off; assert thresholds are numeric.
- (Ch 16 addition) every `within_shooter_split` discriminator must carry an `expect`; one that
  lacks it is scored `untested`, never `supported`.

### 15.3 The four comparison types `[REQ]`
Toy session (n = 24, seed 15): `entry_angle_deg` mean 41.48 sd 3.09; `knee_ext_velocity_dps`
mean 297.6 sd 50.6; `release_height_m` sagging (`2.44 − 0.004·shot` + noise 0.020).

1. **`mean_lt` / `mean_gt` vs a constant — Tier A only.** Fires iff `mean < threshold and
   n ≥ min_n`. Constants must come from geometry/mechanics (e.g. the 32.06° entry floor), never
   from a population. Worked: `{mean_lt: 40.0}, min_n 15`; mean 41.48, n 24 → fires False.
2. **`vs_baseline`** — deviation from the shooter's multi-session `Baseline` in units of the
   metric's **reliability SD** (Ch 13 error budget). Fire iff `|Δ| > 2 × reliability_sd` and
   `n ≥ min_n`. Worked: baseline mean 44.0, reliability_sd 1.2, session mean 41.48 → Δ = −2.52°
   = −2.10 reliability SDs; threshold 2.40 → True. Same Δ divided by the session SD 3.09 =
   −0.82 SD (a different question: "unusual shot for this shooter?"). At 2.10 vs 2.00 the case is
   inside the ±14 % reliability uncertainty → report **borderline**.
3. **`within_shooter_split`** — split the session by the **symptom** metric's quartiles
   (`q1, q3 = percentile(symptom, [25, 75])`; `lo = disc[symptom <= q1]`,
   `hi = disc[symptom >= q3]` — mask from the symptom, applied to the discriminator); compare the
   discriminator between extreme quartiles with Welch t / rank test; **report effect size in SD,
   not a p-value**: `sp = sqrt(((n_lo−1)·var_lo + (n_hi−1)·var_hi)/(n_lo+n_hi−2))`;
   `d = (mean_lo − mean_hi)/sp`; `g = d·(1 − 3/(4(n_lo+n_hi) − 9))`; 90 % Welch CI on the raw
   difference. `expect` is checked against the sign of `g`. Worked: q1 39.32, q3 43.33; 6 vs 6;
   knee means 257.3 vs 336.4; diff −79.0 dps; d −1.989, g −1.836; Welch t −3.44, df 9.8,
   p 0.0065 (report last if at all); 90 % CI (−120.7, −37.4); "lower on flattest quartile" →
   SUPPORTED. Six shots per group → wide CIs; check the symptom metric's invalid rate (Ch 14)
   before trusting a split (extreme quartiles are the most-discarded).
4. **`trend_over_session`** — `slope, intercept = polyfit(shot_index, values, 1)`;
   `change = slope × (n − 1)` (**total change across the session**, not the slope, not a
   p-value); fire iff `|change| > 2 × reliability_sd`. Worked: slope −0.00465 m/shot; change
   −0.1069 m; reliability 0.021 m; threshold 0.0420 → True. Cautions: a trend can be tripod
   settling or lighting; one outlier at an end levers least squares → consider Theil–Sen or
   inspect the scatter.

### 15.4 Baselines `[REQ]` — four guards
1. Baseline requires **≥ 3 sessions and ≥ 60 valid shots** (per metric — validity is per metric).
2. Before that, **Tier B is disabled and the report says why** (never silently omitted).
3. Rolling window: **last 6 sessions**.
4. **Never include the session being evaluated.**
`may_fire = n ≥ min_n and (tier == "A" or have_baseline)`. Example min_n: `flat_arc` 15;
`arc_variance_high` 20; `speed_dominant_variance` 20 (Ch 5 requires n ≥ 20 for attribution).

### 15.5 Ranking and the queue `[REQ]`
- Rank by estimated **cost in makes**. Tier A: geometric make-probability model — sample the shot
  cloud in (entry angle, depth, lateral), shrink the rim by the ball's effective cross-section at
  that entry angle (effective opening `D_rim·sin φ`, margin `D_rim·sin φ − D_ball`, Ch 4), count
  what clears; cost = predicted makes lost per 100 vs the same cloud shifted to the target.
- Tier B: rank by effect size in reliability SDs. Two ranking scales — never mix in one sorted
  list without saying so.
- **Surface one finding; hold the rest in the queue.** Enforce in the data model: all `Finding`
  rows persist with `rank`, exactly one marked active (matches Ch 16's one active `Intervention`).

### 15.6 Golden tests `[REQ]`
`tests/golden/fixtures/<rule>__fires.json`, `<rule>__no_fire_<guard>.json` (hand-built, small:
six shots, three metrics) with `expected/<same>.json`; parametrised test asserting
`run_engine(fixture) == expected`. Every rule: ≥ 1 firing fixture and ≥ 1 non-firing fixture
exercising guards (n < min_n, no baseline, invalid rate > 15 %). Regenerate expected only with an
explicit `--update-golden`; the diff is the review artifact. Extra test: every rule id in the YAML
appears in at least one firing fixture.

### 15 Pitfalls
| Symptom | Cause | Fix |
|---|---|---|
| rule silently stops firing after edit | typo'd key ignored | schema validation at load |
| TypeError float vs str | `1e3` parsed as string | `1.0e3`; assert types |
| cause id evaluates False | yes/no/on/off booleans | quote or avoid |
| arbitrary code from rule file | `yaml.load` | `safe_load` |
| Tier B fires on noise | divided by shooter spread | reliability SD |
| Tier B rule with constant threshold | asserts an ideal form (Ch 1 forbids) | constants are Tier A only |
| fires one run not the next | inside ±14 % on reliability SD | borderline; don't tune |
| baseline drifts toward bad session | included session under evaluation | never include |
| Tier B section missing | disabled and silent | say why |
| implausible split effect | 6 per group; extremes discarded | report CI; check invalid rate |
| p-value in report | spec wants effect size | `g` + interval |
| trend fires on one outlier | least squares levers | robust slope / inspect |
| four findings on report | "one" enforced in renderer | data model `rank` + one active |
| golden diffs accepted unread | reflexive `--update-golden` | diff is the review |
| rule has no test | no coverage assertion | every id in a firing fixture |

### Project Task 15.1 (Python signatures, keep)
Required rules (≥ 8): `flat_arc`, `steep_arc`, `depth_bias`, `lateral_bias` (front view),
`arc_variance_high` (vs_baseline), `release_height_drop` (trend), `unforced_drift`,
`speed_dominant_variance` (Ch 5 attribution > 70 %).
```python
@dataclass(frozen=True)
class Rule:
    id: str
    tier: str                       # "A" | "B" | "C"
    metric: str                     # must exist in metrics.py
    condition: dict                 # {"mean_lt": 40} etc.
    min_n: int
    evidence: str                   # format template
    cost_model: str | None
    causes: list[Cause]
    cue: str

def load_rules(path: Path, registry: MetricRegistry) -> list[Rule]   # safe_load + schema; raises on unknown key, bad tier, unknown metric

def mean_lt(values: np.ndarray, threshold: float) -> ComparisonResult
def vs_baseline(values: np.ndarray, baseline: Baseline, reliability_sd: float) -> ComparisonResult
def within_shooter_split(symptom: np.ndarray, discriminator: np.ndarray) -> ComparisonResult
def trend_over_session(values: np.ndarray, shot_index: np.ndarray, reliability_sd: float) -> ComparisonResult

@dataclass
class ComparisonResult:
    fired: bool
    statistic: float                # delta in reliability SDs, or effect size
    ci: tuple[float, float] | None
    n: int
    detail: dict                    # everything the evidence template may need

def evaluate(session_id: str, rules: list[Rule]) -> list[Finding]
```
Comparisons are pure functions of arrays. Done criteria: `load_rules` rejects unknown key /
unknown metric / bad tier / string threshold; each comparison reproduces §15.3's numbers to
1e−9; eight rules each with firing and non-firing fixtures; Tier B provably disabled without
baseline with an explanation string; engine refuses variance claims for metrics gated > 15 %
(Ch 14 `may_report_variance`); exactly one active finding, rest ranked.

Expected ranges: rules ≥ 8; golden fixtures ≥ 16; findings per session 1 active + 0–4 queued
(> ~6 → thresholds loose); `vs_baseline` statistic ±0–4 reliability SDs (≫ 4 routinely →
reliability understated); split group size ~n/4 (< 5 → say so).

---

## Ch 16 — Differential diagnosis and the closed loop

### 16.1 Symptom ≠ cause `[REQ]`
| Question | Answered by | Field |
|---|---|---|
| Is the symptom real? | tier, n, g-test, discard audit | `diagnosis_confidence` — one per finding (high for Tier A, e.g. 0.93–0.95) |
| Which mechanism? | a discriminator per cause | `support ∈ {supported, unsupported, untested}` + `effect_sd` — one per cause |

```python
@dataclass(frozen=True)
class CauseResult:
    cause_id: str
    support: str                       # "supported" | "unsupported" | "untested"
    effect_sd: float | None            # Hedges' g on the discriminator, None when untested
    ci: tuple[float, float] | None     # 90% CI on the raw difference
    detail: str

@dataclass(frozen=True)
class Diagnosis:
    fault_id: str
    tier: str
    diagnosis_confidence: float        # is the SYMPTOM real?
    causes: list[CauseResult]          # support and effect are PER CAUSE
    next_session_tasks: list[str] = field(default_factory=list)
    @property
    def leading(self) -> CauseResult | None:   # supported cause with the largest |effect_sd|; derived, never stored
```
Leading cause = supported cause with the largest **`abs(effect_sd)`** (sign is direction, not
strength). If none supported → required output: **"cause undetermined — run the distance-ladder
protocol next session"** plus tasks from untested causes.

### 16.2 Scoring a discriminator
- `split_effect(symptom, disc)` = the §15.3.3 quartile split returning `(g, ci90, n_lo, n_hi)`.
- Support rule: `expect` gives a direction ("lower" → require `g < 0`; "larger" → `g > 0`);
  `supported` if the sign matches, `unsupported` otherwise; **no `expect` → `untested`** even if
  the CI excludes zero (keep and store the `effect_sd` for later rescoring).
- Worked session (seed 161, n = 24; knee drives entry at 0.045°/dps, push and elbow unrelated):
  `knee_ext_velocity_dps` g −2.59 CI [−132, −60] → supported (leg_drive); `release_x_offset_m`
  g −0.28 CI [−0.011, 0.00615] → unsupported (push_release expects larger); `elbow_angle_release_deg`
  g −1.06 CI [−8.72, −0.321] — **excludes zero by chance with nothing planted** → untested
  (early_wrist has no `expect`). Trend: slope −0.0113°/shot, change −0.26° over 24 shots vs
  `2 × 1.3 = 2.6°` → fatigue unsupported (effect −0.20). `range_strength` (needs
  `distance_ladder`: 5 shots at each of 4.2, 5.2, 6.2 m) and `deliberate` (ask_user) → untested →
  next-session tasks.
- Expected: supported causes per finding 0–2 (4 of 6 → scoring intervals not predictions); real
  cause g 1.0–3.0 at 6 per quartile (> 4 → metric derived from symptom); absent cause g −1…+1
  with CI spanning 0.

### 16.3 Next-session tasks
Three kinds: capture protocol (must reach the shooter *before* the session), a question on the
report (`ask_user`), a rule-authoring task (missing `expect` → your issue tracker). Task record:
`created_session_id`, `status ∈ {pending, done, abandoned}`, `resolved_session_id`; show pending
tasks from any earlier session (tasks never expire silently).

### 16.4 Re-test protocols `[REQ]`
Every prescription specifies: `n_shots` (fixed in advance), one `metric` (named before the
session), `target` (in metric units, decided before looking), `earliest_session_index` (mechanical
change looks worse before better — Ch 17).
```
effect_sd = (after_mean − before_baseline_mean) / reliability_sd
```
`before_baseline` = the multi-session baseline (rolling 6), **not** the firing session.
Worked: (45.4 − 44.0)/1.3 = 1.08 SD; with reliability ±15 % → 0.94–1.27. Quote `effect_sd` to
**two significant figures**; never treat 1.08 and 0.94 as different. Divide by reliability SD
(instrument error), not the shooter's spread. Comparing a session mean to a per-shot reliability
SD is deliberately conservative (~√n) because the dominant release-angle error is systematic
within a session and does not shrink with n.

**Which sessions are the baseline (§16.4.2):**
| Moment | Session evaluated | Baseline window |
|---|---|---|
| finding fires | session 6 (bad) | sessions 1–5 |
| re-test scored | session 7 | sessions 1–6, **including the bad one** |

### 16.5 Regression to the mean `[REQ]`
- Simulation (μ 44.0°, session SD 1.8°, reliability 1.3°, 6 history sessions + 1 follow-up,
  20 000 shooters, no change): worst-of-6 mean 41.717 (−1.76 rel SD); next session 44.011 (0.01);
  **apparent improvement +2.29° = +1.76 reliability SD from a drill that does nothing.**
- Law: `E[next | this] = μ + ρ·(this − μ)`; expected rebound `(1 − ρ)(this − μ)`;
  `ρ = var(persistent) / (var(persistent) + var(transient))` = session-level reliability.
  Verified (worst decile selected, SD_TOT 1.8): ρ 0 → selected 40.837, next 43.991, rebound
  3.154; ρ 0.25 → next 43.213; 0.5 → 42.411; 0.75 → 41.630; 1.0 → no rebound. Predicted matches
  to 3 decimals. Assume ρ = 0 for guard design. **A noisier pipeline produces more RTM and thus
  more apparent drill efficacy.**
- **Guard 1:** Tier-B deviation must be present across **three consecutive sessions** in the
  baseline window. False-positive rates at gate 2 × 1.3 = 2.6°, session SD 1.8: true change 0 →
  1-session 18.1 %, 3-session 4.1 %; −1° → 23.7 % / 10.7 %; −2° → 38.6 % / 31.6 %; −3° → 58.2 % /
  62.4 %. Report "watching — 2 of 3 sessions" during the latency.
- **Guard 2:** score against the baseline. Null drill: vs firing session +1.76 SD; vs 6-session
  baseline 0.01 (exact; true 0.38 → 0.39, 0.77 → 0.78); vs baseline **excluding** the firing
  session −0.34 SD (biased low: removing the minimum raises the mean to 44.456).
- **RTM sentence** (§16.5.5), generated from data; show only when the firing session is in the
  worst or best third of the window, else `None`:
  "Your entry angle last session was 41.7 deg, the lowest of your last 6 sessions (baseline 44.5
  +/- 0.8 deg, n=5 sessions). Some rebound is expected next session with no change at all -- on
  these numbers about +2.8 deg. We score the drill against the baseline, not against last
  session, for exactly that reason." (baseline at firing time = history[:-1] mean 44.46; at
  retest time = all 6, 44.00.)

### 16.6 Confounding `[REQ]`
- One active `Intervention` per shooter, enforced in the **schema**:
  `CREATE UNIQUE INDEX one_active_per_shooter ON Intervention (shooter_id) WHERE status = 'active';`
- Null case (prescription ignored): `status = 'ignored'` (not deleted), `compliance` = sets
  done/prescribed, re-test anyway — it is the control arm and a direct RTM estimate. Ten null +
  ten compliant cases of one drill → efficacy with the RTM artefact subtracted.
- Third confound: any simultaneous change (new phone, recalibration, gym, `pipeline_version`
  bump). Store `pipeline_version` on `RetestResult`; refuse to compute an effect across a
  version boundary without saying so.

### 16.7 Efficacy table
`(fault_id, cause_id, drill_id) → distribution of effect_sd, n`; group by **all three**; include
`ignored` rows as a separate status, never averaged in; store raw effects (a mean hides a bimodal
drill). Evidence tiers: `coach_recommended` → `in_house (n≥10)` → `in_house (n≥30)`; display tier
and n next to every drill ("Evidence: in-house, n = 12, mean effect +0.6 ± 0.8 SD").
Noise per intervention: `sqrt(SD_session² · (1 + 1/6)) / reliability_sd` = ±1.50 SD (1.8, 1.3);
SE of mean effect: n = 10 → 0.47 (90 % half-width 0.78); n = 30 → 0.27 (0.45); n = 100 → 0.15
(0.25). v1 has n = 1.

### 16 Pitfalls
| Symptom | Cause | Fix |
|---|---|---|
| every drill works by ~1.8 SD | scored vs firing session | vs multi-session baseline |
| every drill under-performs ~0.3 SD | excluded firing session from baseline | exclude only the session being evaluated (the re-test) |
| Tier-B finding almost every session, stable shooter | single-session firing, 18 % FP | three consecutive sessions |
| drills more effective after pipeline change | pipeline noisier → more RTM | compare reliability across `pipeline_version` |
| cause supported on CI excluding zero | 6 per quartile, 4 discriminators | require predicted direction |
| wrist drill for a leg problem | no-`expect` discriminator scored | untested; assert at load |
| `leading` picks weakest | ranked on signed effect | `abs` |
| two active interventions | app-level enforcement | partial unique index |
| no control arm | ignored prescriptions deleted | `status='ignored'`, re-test anyway |
| re-test metric chosen afterwards | no metric in protocol | fix n, metric, target beforehand |
| re-test 3 days later shows decline | measured disruption | `earliest_session` required |
| effect sizes to 3 decimals | ±15 % inherited | 2 sig figs + n |
| task from March never ran | silent expiry | status pending/done/abandoned; show pending |
| cause list = guesses | no discriminators | every cause has one |
| symptom, no next step | no "nothing supported" branch | "cause undetermined — run distance-ladder" |

### Project Task 16.1 (Python signatures, keep)
```python
def evaluate_causes(finding: Finding, session: MetricTable, budget: ErrorBudget) -> list[CauseResult]
    # one CauseResult per cause; a missing discriminator metric is `untested`, never an exception
def next_session_tasks(causes: list[CauseResult]) -> list[Task]     # only from `untested`; dedup by protocol id

@dataclass(frozen=True)
class RetestProtocol:
    n_shots: int
    metric: str                    # one metric, from the Ch 2 registry
    target: float
    earliest_session_index: int    # counted from the prescription

def score_retest(protocol: RetestProtocol, after: np.ndarray, baseline: Baseline,
                 reliability_sd: float) -> RetestResult
    # effect_sd = (after.mean() - baseline.mean) / reliability_sd; status='too_early' if before earliest
def rtm_note(history: np.ndarray, fired_value: float) -> str | None   # §16.5.5 sentence or None mid-window
def efficacy_table(conn) -> list[EfficacyRow]   # (fault_id, cause_id, drill_id, n, mean_effect_sd, ci, evidence_tier)
```
Done criteria: one `CauseResult` per cause; no-`expect` → untested; `leading` None → "cause
undetermined" with a named protocol; `score_retest` refuses before `earliest_session_index` with
a reason; **baseline includes the firing session and excludes the re-test session (test
directly)**; `rtm_note` sentence for worst-in-window, None mid-window; efficacy groups by all
three and separates `ignored`; one fault run end-to-end on yourself across three sessions.

Expected ranges: `effect_sd` on a real drill 0.3–1.5 (> 3 → check baseline anchor); on a null
case −0.5…+0.5 (≈ +1.8 → anchored on firing session); Tier-B firing rate on a stable shooter
< 5 % of sessions per rule (≈ 18 % → single-session firing); efficacy n at end of v1 = 1.

Suggested tests: cause without expect is untested; leading ranks on |effect| (−2.6 beats +0.4);
leading None when nothing supported; missing discriminator metric → untested not exception;
retest baseline includes firing session; retest refuses before earliest; simulated RTM null data
scored the book's way → |mean effect| < 0.1 SD; **the same data scored against the firing session
→ ≈ +1.7…+1.9 SD (regression test that the wrong way stays wrong)**; second active intervention
insert fails at the DB; efficacy groups by fault, cause, drill; ignored not averaged in.

### Verification (Ch 16)
RTM regression test passes both ways (< 0.1 vs +1.7…+1.9); a stable shooter over six simulated
sessions produces < 1 Tier-B finding per 20 session-rule pairs; `evaluate_causes` with a missing
metric returns the full list with that cause untested, no raise; report for a finding with no
supported cause is non-empty and names a protocol; second active `Intervention` raises an
integrity error from the database. Common failures: effect exactly 0.0 on every null case (after
subtracted from itself); `leading` changes between runs (unseeded RNG in the split); every cause
untested (`expect` strings not read — YAML key typo).
