# Digest — Ch 5 (Variance decomposition) and Ch 6 (Solution manifold / UCM ratio)

Source: TEXTBOOK.md Ch 5 (lines 6438–7182), Ch 6 (lines 7184–7848). Notation per NOTATION.md:
`θ` radians in code, `v` m/s, `h` m, `Σ` = 3×3 covariance of `(θ, v, h)`, `J` = gradient of an
outcome w.r.t. `(θ, v, h)`. Both chapters consume Ch 4's `forward(theta_rad, v, h, L) ->
(entry_angle_rad, depth_m)` and `grad_forward(theta_rad, v, h, L, steps) -> J` of shape `(2, 3)`,
row 0 = entry angle, row 1 = depth, columns `(theta, v, h)`.

Constants used: `G = 9.81`, `RIM_HEIGHT_M = 3.05`, `RIM_DIAMETER_M = 0.457`,
`LINE_TO_RIM_CENTRE_M = 4.19`, `X_FRONT_RIM_M = 4.19 − 0.457/2 = 3.9615`.

---

## Ch 5 — Variance decomposition

### 5.1 Covariance matrix

- `Cov(a, b) = (1/(n−1)) · Σᵢ (aᵢ − ā)(bᵢ − b̄)` — Bessel's correction, i.e. `ddof = 1`. Always
  pass ddof explicitly (numpy `np.std` defaults ddof=0, `np.cov` effectively ddof=1).
- `Σ` = 3×3 symmetric matrix, variances on the diagonal, `Σ[i,j] = Cov(pᵢ, pⱼ)`.
- Correlation matrix: `corr[i,j] = Σ[i,j] / (sd[i]·sd[j])`, where `sd = sqrt(diag(Σ))`.
- Input shape convention: `(n_shots, 3)`, columns are variables (the `rowvar=False` trap —
  otherwise you get an `(n, n)` matrix; assert `Σ.shape == (3,3)` and `sqrt(diag Σ)` matches SDs).
- **UNIT TRAP (§5.1):** `Σ` must be built with `θ` in **radians**. If `θ` is in degrees and `J` per
  radian the θ term is `(180/π)² = 3283×` too large.

Worked 8-shot example (θ in deg for display): means `[52.5162, 7.0888, 2.1912]`, SDs
`[2.1223, 0.0817, 0.027]`, `corr(θ,v) = −0.364`, `corr(θ,h) = 0.435`, `corr(v,h) = 0.046`.

### 5.2 Delta method  `[REQ]`

```
Var(d) ≈ Jᵀ Σ J,      J = ∇f(p̄)     (evaluate J at the MEAN of the session)
```
Derivation: `f(p) ≈ f(p̄) + J·(p − p̄)`; `Var(Σᵢ Jᵢ xᵢ) = Σᵢ Σⱼ Jᵢ Jⱼ Cov(xᵢ,xⱼ) = JᵀΣJ`.
(Casella & Berger 2nd ed. §5.5.4.)

Decomposition:
```
Var(d) ≈ Σᵢ Jᵢ² Σᵢᵢ   +   Σ_{i≠j} Jᵢ Jⱼ Σᵢⱼ
         individual        covariance term
```
- individual term i: `cᵢ = Jᵢ² · Σᵢᵢ`; percentage `100·cᵢ / Var(d)`.
- covariance term: `c_cov = Σ_{i≠j} Jᵢ Jⱼ Σᵢⱼ` (both `(i,j)` and `(j,i)` counted), i.e. pairwise
  contribution for one unordered pair is `2 · Jᵢ · Jⱼ · Σᵢⱼ`. Equivalently
  `c_cov = Var(d) − Σᵢ cᵢ`.
- Normalise ALL percentages by the full `JᵀΣJ`, never by the sum of individual terms.
- Report each individual term as a percentage and the covariance term separately; also report
  the three **pairwise** terms with a `cancels` (negative) / `compounds` (positive) label.

Reference worked shooter (code units): `mean_p = (deg2rad(52.0), 7.10, 2.20)`,
`sd_p = (deg2rad(2.0), 0.09, 0.035)`, corr = `[[1, −0.45, 0.20], [−0.45, 1, 0.10], [0.20, 0.10, 1]]`,
`Σ = outer(sd, sd) ⊙ corr`. Results with the reference `forward` (default `L = 4.19`):
`J(depth) = [−0.5748, 1.4559, 1.143]` m per (rad, m/s, m); `Var(depth) = 0.022267 m²`,
`SD = 14.92 cm`; parts θ 1.8 %, v 77.1 %, h 7.2 %, cov 13.9 %; pairwise
`2JθJv Cov = +0.002366` (compounds), `2JθJh Cov = −0.000321` (cancels), `2JvJh Cov = +0.001048`
(compounds). Use as a regression fixture.

### 5.3 Shape checks (assert before trusting)

```
Σ.shape == (3,3);  Σ == Σᵀ (allclose);  all eigvalsh(Σ) >= −1e−12;  J.shape == (3,)
```
Exactly-zero eigenvalue = one variable constant or column duplicated.

### 5.4 Compensation sign — CORRECTION/NOTE A-N2

- Pairwise covariance contribution `2·Jᵢ·Jⱼ·Σᵢⱼ` is **helpful (negative) only when
  `Jᵢ·Jⱼ·Σᵢⱼ < 0`** — NOT simply when `Σᵢⱼ < 0`. Compute the sign, never assume.
- `∂depth/∂θ` changes sign at the maximum-range angle. At `v = 7.1, h = 2.2` the turnover is
  `θ = 50.72°`:

| θ | entry | depth | ∂depth/∂θ (m/rad) |
|---|---|---|---|
| 44° | 28.4° | 0.046 m | +3.53 |
| 48° | 35.1° | 0.212 m | +1.30 |
| 50.72° | 39.3° | 0.242 m | 0.00 |
| 52° | 41.2° | 0.236 m | −0.57 |
| 54° | 44.1° | 0.201 m | −1.43 |

- Below the turnover, "flatter when harder" (`Cov(θ,v) < 0`) cancels. Above it (most high-arc
  shooters, and the worked example at 52°), the same behaviour **compounds**; the compensating
  pattern there is "steeper when harder". Report pairwise terms so the finding names the pair.

### 5.5 Linearization check  `[REQ]`

- Draw `n = 10 000` samples from `N(p̄, Σ)` (multivariate, preserving correlations), push through
  `forward`, take variance of depth (ddof=1) over the **non-NaN** draws, compare to `JᵀΣJ`.
- Disagreement `100·(mc − lin)/lin`. If `> ~10 %`: Σ is too wide for linearization; **report the MC
  total plus the linear attribution with a note** (Shapley attribution is `[ADV]`). Do not
  silently substitute; do not assert — a failing session must still produce a report.
- NaN mask is mandatory (`forward` returns NaN for draws that never reach rim height); report
  how many draws were lost.
- Reference results: measured spread → −0.0 % (10000/10000 reach rim); 3× SDs → +11.3 %
  (9952/10000); 6× SDs → +20.7 % (8965/10000).
- Use a seeded local RNG (`default_rng(seed)`), never global state.

### 5.6 Sample-size honesty  `[REQ]`

- Relative standard error of an SD estimate: `≈ 1/√(2n)` (slightly optimistic at small n).
  n=10: 22.4 % (measured 23.8 %); n=20: 15.8 % (16.3 %); n=25: 14.1 % (14.6 %); n=50: 10.0 %;
  n=100: 7.1 %; n=400: 3.5 %.
- Percent attributions carry ±10–15 points at session level (n ≈ 25). Report `n` with every
  attribution; the fault engine (Ch 15) requires `n ≥ 20` before quoting them.

### 5.7 Bootstrap

- Resample **shots** (rows) with replacement: `idx = integers(0, n, n)`; `P[idx]`; recompute the
  whole attribution; repeat B times. Never resample θ and v independently (destroys correlation).
- Percentile bootstrap: 90 % interval = 5th and 95th percentiles of each of the four columns
  `(theta, v, h, cov)`.
- `B = 1 000` for interactive work, `10 000` for anything printed.
- Reference (n=25 synthetic session from the worked shooter, seed 0): point
  `θ 1.3 %, v 76.7 %, h 3.3 %, cov 18.7 %`; 90 % CIs `θ [0.5, 2.8]`, `v [67.2, 88.7]`,
  `h [1.9, 5.5]`, `cov [6.8, 27.2]`; widths 2.3 / 21.4 / 3.6 / 20.4 points.
- A finding "survives the interval" if the intervention is the same at the pessimistic end.
- n = 8 → intervals span most of 0–100 %; correct, not a bug.

`attribution(P_rad)` reference algorithm: `mean_p = mean(P)`; `S = cov(P)`;
`Jd = grad_forward(*mean_p)[1]`; `total = Jd·S·Jd`; `parts[i] = Jd[i]²·S[i,i]`;
`cov_t = total − Σ parts`; return `100·[parts…, cov_t]/total`.

### 5 Pitfalls (symptom → cause → fix)

| Symptom | Cause | Fix |
|---|---|---|
| Σ is (25,25) not (3,3) | rows treated as variables | columns = variables; assert shape |
| θ contributes 99.9 % | Σ in degrees, J per radian (×3283) | radians before building Σ |
| Percentages sum to 87 % or 112 % | dropped covariance term, or counted each off-diagonal once | pair contribution is `2JᵢJⱼΣᵢⱼ` |
| A percentage is negative | expected for covariance term only | negative *individual* term = sign/index bug |
| Attribution changes on column reorder | Σ and J in different orders | fix `(theta, v, h)` order; index by name in tests |
| MC variance is NaN | draws that never reach rim | mask NaN, report count lost |
| MC vs linear disagree 40 % with normal SDs | J evaluated away from the mean (e.g. first shot) | `grad_forward` at `P.mean` |
| Bootstrap intervals absurdly narrow | indices drawn but not applied | print two reps, check they differ |
| Interval spans 0–100 % | n too small or Σ near-singular | check `eigvalsh(Σ)`; report n; refuse finding |
| Results change between runs | global RNG / no seed | explicit seeded generator |
| Var(depth) enormous, SD exceeds court | Σ not positive semi-definite | eigvalsh ≥ 0 |

### Project Task 5.1 (Python signatures, keep)

```python
@dataclass(frozen=True)
class Decomposition:
    outcome: str                 # "depth_m" or "entry_angle_deg"
    n: int                       # trials used
    total_var: float             # J^T Sigma J, outcome units squared
    mc_var: float                # Monte-Carlo variance from the same Sigma
    parts: dict[str, float]      # {"theta": pct, "v": pct, "h": pct, "cov": pct}
    ci90: dict[str, tuple]       # same keys -> (lo_pct, hi_pct)

def session_covariance(params: np.ndarray) -> np.ndarray:
    """params: (n, 3) float64, columns (theta_RAD, v_mps, h_m). Returns (3, 3)."""

def decompose(params: np.ndarray, outcome: str, L: float,
              n_mc: int = 10_000, n_boot: int = 1_000, seed: int = 0) -> Decomposition:
```
- `params` carries θ in radians; conversion from `release_angle_deg` rows happens in ONE function.
- `L` is an argument (per-session from rim annotation, Ch 9); depth moves metre-for-metre with L.
- Oracle data: SPL 2025-12-18 session P0001, 88 trials at 60 fps (NOT the 2024 session's 125 — its
  ball track stops at apex; Correction A-C1). Do both outcomes: depth and entry angle.

Done criteria: percentages sum to `100.0 ± 0.1` incl. covariance, for both outcomes; MC vs linear
within 10 % on SPL and the code *reports* (not asserts) the disagreement; bootstrap resamples
trials; every number carries `n`; same Σ and J handed to Ch 6 unchanged.

Expected ranges (§Task 5.1):

| Quantity | Real session | Alarm if |
|---|---|---|
| SD(depth) | 8–20 cm | < 3 cm (check L, units) or > 50 cm |
| speed attribution to depth | 50–90 % | < 10 %: Σ not in radians |
| angle attribution to depth | 1–25 % | > 60 % with normal SD(θ): unit error |
| covariance term | −25 % to +25 % | beyond ±60 %: Σ near-singular |
| MC vs linear | within 2 % at realistic spreads | > 10 %: report MC, note it |
| 90 % CI width, n≈25 | 15–30 points on dominant term | < 5 points: bootstrap not resampling |
| entry-angle decomposition | dominated by θ and h, not v | v dominating: used row 1 of J instead of row 0 |

Ch 4 Jacobian check: `∂entry/∂v = 0.0796` vs `∂entry/∂θ = 1.463` — entry angle barely notices
speed, so depth and entry-angle tables must attribute to *different* variables.

Suggested tests: (1) delta = MC exactly for a deliberately linear f (within `~1/√(2n)` relative);
(2) four parts sum to 100 for 20 random PD Σ; (3) covariance term = 0 for diagonal Σ; (4) doubling
SD(v) alone ≈ quadruples v's contribution in m².

### Verification (Ch 5)
Percentages sum to 100 % incl. covariance (may be negative). MC and linear agree within 10 % on
SPL. Intervals wide but not absurd. Failure table: covariance missing → normalised by sum of
individual terms; θ at 99 % → degrees; MC == linear exactly → MC computed from tangent plane;
MC NaN → unmasked; CI `[77.0, 77.0]` → indices unused; 0–100 % everywhere → n small / near-zero
eigenvalue; depth and entry attribute identically → same J row; attribution flips between two
sessions of same shooter → check `L` and release-point convention first.

---

## Ch 6 — Solution manifold / UCM ratio

### 6.1 The manifold  `[REQ]`
Solution manifold = `{p : f(p) = d_target}`, a curve in the `(θ, v)` plane at fixed `h`.
Default `d_target = RIM_D/2 = 0.2285 m` (ball centre through rim centre; depth measured from
front rim). Compute explicitly by bisection on `v` for each θ: `forward(θ, v, h̄)[1] − d_target = 0`,
bracket `v ∈ [4.0, 12.0]`, 200 iterations (check both bracket ends have opposite signs).

Reference manifold at `h̄ = 2.20 m`, `d_target = 0.2285`:

| θ (deg) | v (m/s) | entry (deg) |
|---|---|---|
| 46 | 7.1519 | 32.20 |
| 48 | 7.1110 | 35.18 |
| 50 | 7.0923 | 38.17 |
| 52 | 7.0951 | 41.16 |
| 54 | 7.1197 | 44.15 |
| 56 | 7.1666 | 47.12 |
| 58 | 7.2368 | 50.07 |

Valley floor near 52° (where `∂depth/∂θ = 0`). Trap: the manifold is defined by depth only and
extends below the geometric entry floor 32.06° — overlay the entry floor when plotting.

### 6.2 Computation  `[REQ]`  (2-D, `(θ, v)` at the shooter's mean h)

1. Standardize: `z = (p − p̄) / σ` per variable, `σ = sample SD (ddof=1)` — the shooter's own SD.
   Gradient in z-space: `J_z = J ⊙ σ` (elementwise; chain rule with `p = p̄ + σ z`).
2. Unit normal (costly direction): `u = J_z / ‖J_z‖`.
3. Unit tangent (harmless direction): `w = (−u₂, u₁)` (or `(u₂, −u₁)`; be consistent).
   Per shot: `oᵢ = zᵢ · u`, `tᵢ = zᵢ · w` (signed projections; 1 DOF each in 2-D).
4. `V_ORT = Var(oᵢ)`, `V_UCM = Var(tᵢ)` (ddof=1).
5. `UCM ratio = V_UCM / V_ORT`. `> 1` = exploiting the manifold (compensating); `< 1` = mostly
   costly variability. `harmless_pct = 100 · V_UCM / (V_UCM + V_ORT)`.
   Report sentence: "X % of your release variability is in a direction that doesn't affect depth."
6. `sd_depth_m = sqrt(V_ORT) · ‖J_z‖` — ALWAYS reported beside the ratio.

Reference (synthetic n=88, mean (52°, 7.10), SD (2°, 0.09), ρ = −0.45, seed 0):
`J = [−0.6539, 1.4529]`, `J_z = [−0.020447, 0.127153]`, `‖J_z‖ = 0.128787`,
`u = [−0.1588, 0.9873]`, `w = [−0.9873, −0.1588]`, `V_ORT = 1.1112`, `V_UCM = 0.8888`,
ratio `0.800`, harmless `44.4 %`, `V_ORT·‖J_z‖² = JᵀΣJ = 0.018429990012 m²`.

### 6.3 Identity with Ch 5 (make it a live assertion)
```
Jᵀ Σ J = J_zᵀ Σ_z J_z = ‖J_z‖² · uᵀ Σ_z u = ‖J_z‖² · V_ORT
```
where `Σ = diag(σ) Σ_z diag(σ)` and `Σ_z` is the correlation matrix. Assert
`isclose(v_ort · ‖J_z‖², J2 · Σ2 · J2, rtol = 1e−10)` (book prints agreement to 1e−12).
**Compare like with like:** use the 2×2 block `Σ[:2,:2]` and the 2-element gradient on both
sides; Ch 5's full 3-D `Var(depth)` is larger (includes h).

### 6.4 Blindness of the ratio — NOTE A-N3
- After standardisation each variable has variance 1, so `V_ORT + V_UCM = 2` (number of
  variables) exactly, always.
- With `Σ_z = [[1, ρ],[ρ, 1]]`: `V_ORT = 1 + 2ρu₁u₂`, `V_UCM = 1 − 2ρu₁u₂`,
  `ratio = (1 − 2ρu₁u₂) / (1 + 2ρu₁u₂)`. **Depends only on ρ and the gradient direction; the
  shooter's SD magnitudes cancel.**
- Table (mean 52°, 7.10, h 2.20):

| SD(θ) | SD(v) | ρ | ratio | harmless | SD(depth) |
|---|---|---|---|---|---|
| 2.0 | 0.09 | 0.00 | 0.989 | 49.7 % | 13.28 cm |
| 2.0 | 0.09 | −0.45 | 0.759 | 43.1 % | 14.11 cm |
| 2.0 | 0.09 | +0.45 | 1.289 | 56.3 % | 12.39 cm |
| 4.0 | 0.18 | 0.00 | 0.989 | 49.7 % | 26.55 cm |
| 4.0 | 0.18 | −0.45 | 0.763 | 43.3 % | 28.17 cm |
| 2.0 | 0.09 | −0.90 | 0.574 | 36.5 % | 14.92 cm |
| 6.0 | 0.04 | −0.45 | 0.391 | 28.1 % | 10.05 cm |

- Doubling all SDs leaves ratio at 0.76 while SD(depth) goes 14.1 → 28.2 cm. Row 7: worst ratio,
  best depth consistency. **Never print the UCM percentage without SD(depth); never rank shooters
  by the ratio.** Ch 18's report puts the Ch 5 attribution before the manifold percentage.
- At 52° (past max-range angle) a *positive* ρ gives ratio > 1 (compensating = "steeper when
  harder"); flatter shooters the opposite. Compute the sign.

### 6.5 Curvature check (`[OPT]` for v1, but run it and report the %)
Compare `Var(linear orthogonal component)` vs `Var((depth − d_target)/‖J_z‖)` over MC draws
(mask NaN), `d_target = forward(p̄)[1]`. Reference (ρ = −0.45, n=2000, seed 3):
SD(θ,v) = (2°, 0.09): 1.0 % error; (4°, 0.18): 3.9 %; (8°, 0.36): 14.8 % (1969/2000 usable);
(16°, 0.72): 35.9 % (1740/2000). Linear tangent is fine at 1–2× a real spread.

### 6 Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `V_ORT + V_UCM ≠ 2.0` | mixed ddof=0/ddof=1, or population SD | one `σ = std(ddof=1)` everywhere incl. inside `J_z` |
| ratio exactly 1.000 every time | `Σ_z` is identity (uncorrelated data) | print ρ; ratio 1 at ρ=0 is correct |
| `V_ORT·‖J_z‖²` ≠ Ch 5 | 2-D vs 3-D comparison | `Σ[:2,:2]` and 2-element J both sides |
| identity off by `(180/π)²` in one term | degrees | radians |
| `u ≈ (1, 0)`, "angle is costly" | forgot `J_z = J ⊙ σ` | chain rule step 1 |
| ratio changes rescaling v to cm/s | standardisation missing or after projection | z first |
| `w` not perpendicular | mixed `(u₂,−u₁)` and `(−u₂,u₁)` | either; be consistent |
| manifold curve gaps/jumps | bracket `[4, 12]` lacks a root at that θ | check both bracket ends |
| manifold below 32° entry | correct; defined by depth only | overlay entry floor |
| ratio 0.39 on your best shooter | ratio without SD(depth) | report both |

### Project Task 6.1 (Python signature, keep)

```python
@dataclass(frozen=True)
class ManifoldResult:
    n: int
    u: np.ndarray            # (2,) unit normal in z-space, order (theta, v)
    v_ort: float             # variance along u, dimensionless
    v_ucm: float             # variance along w, dimensionless
    ratio: float             # v_ucm / v_ort
    harmless_pct: float      # 100 * v_ucm / (v_ucm + v_ort)
    sd_depth_m: float        # sqrt(v_ort) * ||J_z||  -- report ALWAYS
    d_target_m: float        # the target this manifold was built for

def manifold_analysis(params: np.ndarray, h_bar: float, L: float,
                      d_target: float) -> ManifoldResult:
    """params: (n, 2) float64, columns (theta_RAD, v_mps). h held at h_bar."""
```
Done criteria: identity assertion at `rtol=1e−10` on real data (the M2 checkbox);
`v_ort + v_ucm == 2.0` to fp; plot has cloud, explicit manifold curve, tangent line at mean,
normal, error ellipse with axes along `u` and `w`; §6.5 curvature % reported; sentence names `n`
and `d_target`.

Expected ranges:

| Quantity | Typical | Alarm |
|---|---|---|
| `‖J_z‖` | 0.10–0.20 m per SD | < 0.02: gradient not in z-space |
| `u` | dominated by v component (mid-arc shooter) | dominated by θ: check `J_z = J⊙σ` |
| `v_ort`, `v_ucm` | each 0.3–1.7, sum 2.000 | not 2 |
| UCM ratio | 0.4–2.5 | exactly 1.000, or negative |
| `harmless_pct` | 25–70 % | 0 % or 100 % |
| `sd_depth_m` | 0.08–0.20 | see Ch 5 table |
| curvature error | < 5 % | > 15 %: use explicit manifold |

Suggested tests: `v_ort + v_ucm == 2` for 50 random Σ (1e−12); identity with delta method (1e−10);
ratio invariant to v in cm/s; a shooter constructed exactly on the manifold (+ small noise) gives
`v_ort ≈ 0` and a very large ratio.

Exercise 6.2 facts: Noah "45/11" = 45° entry, 11 in depth from front rim (0.279 m) = ~5 cm deeper
than rim centre (0.2285 m); 91 % of NBA players 43–47° at 10–12 in. Empirical best depth at n=25
has huge SE.

### Verification (Ch 6)
`v_ort + v_ucm` prints `2.0000000000`; identity passes at rtol 1e−10; cloud's long axis aligns with
the tangent when ratio > 1 and across it when < 1; curvature check a few %; rerun with v in cm/s
changes nothing. Failures: identity off ×3283 → degrees; off a few % → ddof mismatch; off by an
unstructured amount → J not at `p̄` or 3-D vs 2-D; ellipse axes misaligned → eigenvectors of Σ in
natural units rather than z-space; ratio vs SD(depth) opposite stories → not a failure, report both.

### Milestone gate M2
- [ ] `forward` unit-tested against synthetic parabolas; gradient validated vs finite-difference.
- [ ] Entry-floor and arc-sensitivity derivations done and plotted.
- [ ] Variance decomposition on SPL with bootstrap intervals and MC check.
- [ ] Manifold analysis on SPL; numerical identity `V_ORT·‖J_z‖²` = delta-method `Var(d)` confirmed.
- [ ] One-page hand-written report for the SPL shooter, coach language; shown to one shooter;
      record what they skipped. **If not compelling, stop.**

One-page report must contain (5 lines, no jargon): (1) what measured and how many shots;
(2) release angle / speed / height as mean ± SD in deg, m/s, m; (3) the Ch 5 sentence "X % of how
much your shots vary front-to-back comes from how hard you throw it" with interval and n;
(4) the Ch 6 sentence with SD(depth) beside it; (5) the one thing to work on and how you'd know in
three weeks. Failure modes: reader cannot restate; asks "so what should I do?"; agrees with
everything (read none of it).
