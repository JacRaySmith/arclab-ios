# Digest — Ch 12 (2D joint angles, projection error, squareness, registered metrics) and Ch 13 (Error budget, ICC, effect size, harnesses)

Source: TEXTBOOK.md Ch 12 (lines 12973–13665), Ch 13 (lines 13667–14328). Frames: World
`X, Y, Z` (metres, Z up); image `u, v` (pixels, **v down**). In Ch 12 the symbol `φ` (`phi`)
means **out-of-plane rotation about the vertical axis**, not entry angle.

---

## Ch 12 — Joint angles in 2D

### 12.1 Rotations
- 2D CCW rotation: `R2(θ) = [[cos θ, −sin θ], [sin θ, cos θ]]`. Columns = where basis vectors land.
  `Rᵀ R = I`, `Rᵀ = R⁻¹`, lengths and angles preserved.
- 3D rotation about vertical (World Z): `Rz(φ) = [[c, −s, 0], [s, c, 0], [0, 0, 1]]`.
- A 3D rotation cannot change a real joint angle; only the projection can.

### 12.2 Orthographic side-on projection (camera looks along World Y)
`project(P) = (u, v) = (X, −Z)` — Y is discarded; the minus on Z is the NOTATION sign flip.

### 12.3 Projection experiment `[REQ]`
Elbow at origin; upper arm at `tilt` from vertical in the vertical X–Z plane:
`u = (sin t, 0, cos t)`; forearm rotated by the true angle `a` within that plane:
`w = (u₀·cos a + u₂·sin a, 0, −u₀·sin a + u₂·cos a)`. Rotate both by `Rz(φ)`, project, measure
the apparent angle with `angle_arctan2`. With `tilt = 45°`:

| φ | true 60 | true 90 | true 120 | true 150 |
|---|---|---|---|---|
| 0 | 60.00 | 90.00 | 120.00 | 150.00 |
| 5 | 60.16 | 90.22 | 120.16 | 150.05 |
| 10 | 60.66 | 90.88 | 120.66 | 150.22 |
| 15 | 61.50 | 91.99 | 121.48 | 150.50 |
| 20 | 62.70 | 93.56 | 122.65 | 150.91 |
| 30 | 66.30 | 98.21 | 126.04 | 152.17 |
| 45 | 75.49 | 109.47 | 134.01 | 155.46 |
| 60 | 91.62 | 126.87 | 145.80 | 161.07 |

A true 90° elbow reads 91.99° at φ = 15° and 95.63° at φ = 25° → **3.6° of apparent elbow
variance from torso rotation alone**. Error here is always positive (this arm geometry) — a
**bias**, not noise; does not average away.

### 12.4 Cannot correct, only refuse
True 90°, φ = 20°, sweeping upper-arm tilt from vertical: tilt 0 → +0.00; 15 → +1.78; 30 → +3.09;
45 → +3.56; 60 → +3.09; 75 → +1.78; 90 → +0.00. **Same φ, errors 0–3.6°** depending on limb
orientation → no per-shot correction factor exists (3D pose would be needed: `[ADV]` MeTRAbs).
Errors vanish when the limb lies along a preserved axis (vertical or horizontal) — why
vertical/timing metrics survive rotation better than sagittal angles.

### 12.5 Joint angle `[REQ]`
Book formula: `angle = arccos((A−B)·(C−B) / (‖A−B‖‖C−B‖))`; **implement with arctan2**:
```
u = A − B;  w = C − B
cross = u₀·w₁ − u₁·w₀
angle_deg = rad2deg(|atan2(cross, u·w)|)
```
- `arccos` returns NaN on ordinary valid input: the normalised dot of exactly parallel vectors
  can be `1 + 2.2e−16` (found after 2 random pairs); mirror case `−1.0000000000000002` at 180°
  (extended arm at 175–180° lives there). Clipping to [−1, 1] removes NaN but saturates to exactly
  0.0/180.0 — a wrong number that looks like a measurement.
- `arctan2` buys **robustness, not precision**: with 1.5 px jitter on 90 px segments both give
  identical SD: true 5° → 1.363°; 20° → 1.404°; 90° → 1.898°; 160° → 2.341°; 175° → 2.264°.
- **Random-error floor for angle metrics: 1.36° at a bent joint, 2.3° at a straight one**
  (1.5 px jitter, 90 px segments); scales as 1/(segment length in px); worst at straight limbs
  (middle keypoint contributes ~`2σ/L` instead of `√2·σ/L`). Budget 2.3° for
  `elbow_angle_release_deg` (arm at 170–180°).

### 12.6 Consequences `[REQ]`
1. Sagittal angles (elbow flexion, knee flexion, trunk lean) are trustworthy only when the camera
   is square to the shoulder line.
2. Frontal-plane measures (elbow alignment, "flare") need a front camera AND normalisation by
   shoulder-line orientation. v1: mark `requires_view = "front"` in the registry and emit a
   `Metric` row with `valid = False, invalid_reason = "requires_front_view"` — **never skip the
   row** (Ch 14's audit cannot count rows never written).

### 12.7 Squareness check `[REQ]`
```
squareness = ‖L_shoulder − R_shoulder‖ / ‖mid_shoulder − mid_hip‖
```
Scale-free. Model (0.40 m shoulders, 0.50 m torso, s = 0.0035 m/px): shoulder separation goes
as `sin(rotation)`; rotation 0 → 0.000; 5 → 0.070; 10 → 0.139; **15 → 0.207**; 20 → 0.274;
30 → 0.400; 45 → 0.566; 60 → 0.693; 90 → 0.800. The 15° threshold ≈ **0.207 for this build only**
— **calibrate per shooter** by filming at 0°, 15°, 30° and interpolating; store three ratios +
threshold.
- Sensitivity `d(squareness)/d(rotation) = (SHOULDER/TORSO)·cos(15°)·π/180 = 0.0135 per degree`;
  1 px shoulder noise ≈ 0.52° implied rotation; 2–5 px jitter → 1–2.6° per frame.
- **Aggregate over the load→release window** (median, or a high percentile to be strict); never
  gate per frame (flickers).
- Near 0° the shoulders coincide → noisiest where smallest (source of L/R swaps) — acceptable
  because that is the accept region.
- Gate, not correction: if window squareness exceeds the threshold, mark the **four sagittal
  angle metrics** `valid = False, invalid_reason = "out_of_plane"`.

### 12.8 Registered metrics (all Tier B or C; **no target values in code**)
| Metric | Definition | Requires | Squareness-gated? |
|---|---|---|---|
| `elbow_angle_set_deg` | elbow angle at set | shoulder, elbow, wrist | yes |
| `elbow_angle_release_deg` | elbow angle at release | same | yes |
| `knee_min_deg` | min knee angle in load | hip, knee, ankle | yes |
| `knee_ext_velocity_dps` | peak knee angular velocity load→release | same | yes |
| `release_lag_ms` | release time − peak knee extension time | knee, ball | no |
| `dip_to_release_ms` | release − dip | ball | no |
| `release_x_offset_m` | horizontal release point − hip x, metres | ball, hip | no |
| `jump_height_m` | peak hip height − set hip height | hip | no |
| `drift_m` | landing ankle x − takeoff ankle x (**sign = toward rim**) | ankle | no |
| `head_stability_px` | SD of nose position during rise (px on purpose; Tier C) | nose | no |
| `elbow_alignment_deg` | frontal elbow deviation from shoulder–wrist line | **front view** | requires_front_view |
| `lateral_m` | ball lateral offset at rim plane | **front view** | requires_front_view |

`requires` is data (list of keypoint names) → auto-invalidate when required keypoints have low
confidence. Test that a synthetic drift toward the rim is positive.

### 12 Pitfalls
| Symptom | Cause | Fix |
|---|---|---|
| NaN in angle arrays | arccos of dot a few ULP outside [−1,1] | arctan2 |
| angles pile at exactly 0.0 / 180.0 | clipped arccos | arctan2 |
| elbow SD 14° on a repeatable shooter | torso rotation varies | squareness gate |
| tried per-shot φ correction | error depends on limb orientation | gate, don't correct |
| squareness flickers within a shot | per-frame gating | window median |
| threshold works for you, not others | shoulder/torso ratio personal | calibrate per shooter |
| front-view metrics silently absent | skipped row | write row with `invalid_reason` |
| angle noise larger on one session | subject further away; 1/length | framing problem |
| `drift_m` wrong sign | convention untested | test toward-rim positive |
| all 12 invalid on a good session | blanket gate | gate only sagittal angles |

### Project Task 12.1 (Python signatures, keep)
```python
def joint_angle(A: np.ndarray, B: np.ndarray, C: np.ndarray) -> np.ndarray   # [T,2] or [2] -> [T] or scalar, DEGREES, arctan2
def squareness(pose: np.ndarray, kp: dict[str, int]) -> np.ndarray             # [T,K,3] -> [T]
def squareness_to_rotation_deg(ratio: float, calib: SquarenessCalibration) -> float

@dataclass
class SquarenessCalibration:
    shooter_id: str
    ratio_at_0: float
    ratio_at_15: float
    ratio_at_30: float
    threshold_ratio: float          # the value corresponding to 15 degrees

def compute_metrics(track: Track, events: dict[str, Event], session: Session) -> list[MetricRow]
    # one MetricRow per registered metric, ALWAYS -- valid=False where refused
```
Done criteria: φ table in notes (know what 20° does to a 90° elbow: +3.6°); `joint_angle` via
arctan2 with a no-NaN test for parallel/anti-parallel; squareness calibrated on you at 0/15/30°
stored per shooter; per-shot squareness over load→release gates the four sagittal metrics only;
every metric a row per shot with `valid`, `confidence`, `n_frames_used`, `invalid_reason`;
distribution plot per metric with n.

Expected ranges: squareness on a good side-on session ≤ ~0.2 and stable (alarm > 0.3 or
swinging); angle noise 1.4° bent / 2.3° straight (≫ → subject too small); `elbow_angle_release_deg`
150–175° (> 179 or exactly 180.0 → clipping); `knee_min_deg` 110–150° (< 90 unusual); fraction
gated by squareness < 10 % under protocol (> 15 % → Ch 14 refuses the variance claim);
front-view metrics on a side-only session 100 % `valid=False`.

Suggested tests: parallel/anti-parallel → 0.0/180.0 not NaN over 10 000 random pairs; arctan2 vs
clipped arccos agree to 1e−9 for 20–160°; `apparent(90, 0) == 90` exactly and
`apparent(90, 45) > 105`; squareness invariant to 2× keypoint scaling; timing metrics stay valid
on an out-of-plane-gated shot; a no-front-view shot yields 12 rows with exactly 2
`requires_front_view`; drift sign.

### Milestone gate M5
- [ ] Projection experiment done; φ table in notes.
- [ ] Squareness calibrated; per-shot sagittal validity being set.
- [ ] All registered metrics compute with `valid`, `confidence`, `n_frames_used`.
- [ ] Phase markers validated by eye on 20 shots.
- [ ] Distribution plot per metric for one session, with n shown (if every metric has n = 25 on
      a session where the shooter rotated, validity flags are not being set).

---

## Ch 13 — Error budget

### 13.1 Vocabulary `[REQ]`
- Systematic error (bias): constant offset (wrong scale, tilted camera). Cancels in
  within-shooter comparisons; does not cancel in absolute claims.
- Random error: jitter; averages down as `1/√n`; sets per-shot precision floor.
- Reliability: same shot measured twice → same number? ICC, or SD of test–retest differences.
- Validity: only an external oracle (SPL) can tell you.

| | Systematic | Random |
|---|---|---|
| shrinks with n? | no | yes, 1/√n |
| hurts Tier A ("entry < 32° cannot swish")? | yes, badly | a little |
| hurts Tier B ("release height fell 7 cm")? | no — cancels | yes |
| example | scale wrong 4 %, release 5 frames late | keypoint jitter, centroid noise |

Keep the two columns separate; a single ± mixing them is useless.

**Known systematic entries before measuring anything:**
- Release-frame bias: 0.3–0.4°/frame at 120 fps × ~5–6 frame median-rule bias ≈ **1.8–2°**.
- **Drag (Correction A-C2):** deceleration at release ≈ **1.10 m/s² = 11 % of g** (book said
  0.2–0.3 m/s², 3 %; that is the value at 3 m/s not 7). Use 1.1 m/s² in the systematic column.
  TRAP: the Ch 13 in-chapter block says drag shifts `g_recovered` *low*; Appendix C A-C2 says
  the fitted drag-free shift is **+1.20 % (high, not low)** with a **4.8 cm** depth error. Trust
  Appendix C for the sign. Either way: ignore for v1, a few cm of depth bias.
- **Timing floor (Correction A-C4):** `|dθ/dt| = g·cosθ / v` (book's `g·Δt/(v cosθ)` is
  `d(tanθ)`). One-frame anchor error costs **0.47° at 120 fps, 1.95° at 30 fps** (book: 1.07°,
  4.30° — an over-estimate; keeping 1° is a conservative margin). Ch 10 measured ≈ 0.4°/frame.

### 13.2 Three harnesses `[REQ]`
1. **Synthetic** (Ch 9): perfect detector and geometry → the floor; failure = bug in your maths.
2. **SPL reprojection:** SPL 3D keypoints + ball → `Rz(φ)` → orthographic side camera
   (`u = X, v = −Z`) → scale `1/s` to px, offset into frame → add Gaussian jitter matched to your
   backend (2–5 px) → run the **unmodified** 2D `compute_metrics` → compare with the same metrics
   computed directly in 3D. Repeat at φ = 0°, 10°, 20°, jitter 0, 2, 5 px.
3. **Test–retest:** same 20 shots, two phones simultaneously, tripods 30 cm apart, both "square".
   Metrics disagreeing beyond claimed uncertainty are camera-position detectors.

| φ | Expect | If not |
|---|---|---|
| 0°, jitter 0 | match 3D to numerical precision | **formula bug** |
| 0°, jitter 2–5 px | scatter by random error | this row IS the random-error column |
| 10° | small bias, squareness passing | gate over-firing |
| 20° | sagittal angles biased several degrees; squareness gate fires | gate mis-calibrated |

SPL notes (§13.2.1): use **2025-12-18** for anything with the ball (2024-08-28 ball track ends
at apex — 119/240 frames, peak at the last tracked frame); either for body kinematics.
**K = 69** with SCREAMING_SNAKE names plus `NECK`, `MID_HIP` → explicit 69→17 name map (index by
name; test each mapped keypoint is nearer its anatomical neighbour than any other joint).
Positions in **feet**, hoop coordinates in **inches**, `time` in **milliseconds**, literal
`NaN` in JSON.

### 13.3 ICC
From `x [n_shots, k_phones]`, grand mean `gm`:
```
MSB = k · Σᵢ (rowmeanᵢ − gm)² / (n − 1)                 # between shots (signal)
MSJ = n · Σⱼ (colmeanⱼ − gm)² / (k − 1)                 # between phones (systematic offset)
MSE = Σᵢⱼ (xᵢⱼ − rowmeanᵢ − colmeanⱼ + gm)² / ((n−1)(k−1))   # residual noise
ICC(2,1) = (MSB − MSE) / (MSB + (k−1)·MSE + k·(MSJ − MSE)/n)   # absolute agreement  (= ICC(A,1))
ICC(3,1) = (MSB − MSE) / (MSB + (k−1)·MSE)                      # consistency         (= ICC(C,1))
```
- Bias simulation (200 shots, shooter SD 5, noise SD 1): phone bias 0 → ICC(2,1) 0.9645, ICC(3,1)
  0.9648; 0.5 → 0.9681/0.9705; 1.2 → 0.9373/0.9667; 3.0 → 0.8446/0.9707; 6.0 → 0.5957/0.9647.
  SD of diffs ≈ 1.4 throughout (blind to bias); per-measurement noise = `sd(diff)/√2` ≈ 1.0.
- **Use absolute agreement ICC(2,1)/ICC(A,1)** for the two-phone retest (Koo & Li 2016: two-way,
  absolute agreement, single measurement). Name the form. Report **mean difference (= bias)**
  and SD of differences alongside.
- pingouin returns six rows named `ICC(1,1), ICC(A,1), ICC(C,1), ICC(1,k), ICC(A,k), ICC(C,k)`;
  pick the form *before* looking. Example n = 20, bias 2.5: ICC(A,1) 0.8886 CI **[0.01, 0.97]**;
  ICC(C,1) 0.9703 [0.93, 0.99].
- Koo & Li interpretation: < 0.5 poor; 0.5–0.75 moderate; 0.75–0.9 good; > 0.90 excellent.
  Always report the CI.
- Uncertainty of a reliability SD: relative SE ≈ `1/√(2n)`: n=10 → 23.0 %; 20 → 16.2 %;
  25 → 14.3 %; 40 → 11.3 %; 100 → 7.1 %. A 1.2° reliability SD from 25 shots could be 1.0–1.4°;
  propagates into Ch 15's `2 × reliability SD` firing threshold. Report n with every reliability.

### 13.4 Effect size, not p-values
- Welch t-test (unequal variances), fractional df, `confidence_interval(0.90)`. Example
  n = 12 vs 12: t = −1.901, df = 21.96, p = 0.0706, 90 % CI on mean diff [−7.094, −0.359].
- Cohen's d: `sp = sqrt(((nₐ−1)·varₐ + (n_b−1)·var_b) / (nₐ + n_b − 2))`; `d = (mean_b − mean_a)/sp`.
- **Hedges' g** (use always, n is small): `g = d · (1 − 3/(4·(nₐ+n_b) − 9))`; correction 3.4 % at
  n = 12 per group. Example: sp 4.803, d +0.776, g +0.749.
- Report `d`/`g`, its CI, and n; p-value last if at all.

### 13.5 Error budget document `[REQ]`
One row per registered metric: `metric | random error (per shot) | systematic error (session) |
reliability (test–retest SD) | source`. Example row: `release_angle_deg | ±1.2° | ±0.8° | 1.0° |
synthetic + retest`. "unknown" is a legitimate entry — never fabricate.

Pre-computed contributions to `release_angle_deg`:
| Contribution | Size | Kind |
|---|---|---|
| release-frame timing per frame at 120 fps | 0.47° | mostly systematic |
| median-rule bias ~5 frames | ≈ 2° | systematic |
| detector centroid noise through fit | sd(θ) 0.24° at 40 frames, 0.05° at 120 | random |
| scale error (`s_from_g` vs `s_from_ball` ≤ 3 %) | none on θ (scale-invariant) | — |
| out-of-plane rotation | n/a for θ; several degrees for elbow | systematic per shot |
| keypoint jitter → angle (1.5 px, 90 px) | 1.4° bent, 2.3° straight | random |

Release angle: excellent precision, mediocre accuracy → Tier B trustworthy, Tier A suspect.

### 13.6 Uncertainty in the product `[REQ]`
- Every reported value carries ± its **random** error (systematic goes in a footnote about
  absolute claims). Every session SD is reported with n.
- Tier-B finding requires deviation > `2 × reliability SD` (Ch 15); the threshold itself has
  ±14 % uncertainty at n = 25 → deviations within 14 % of threshold are reported **"borderline"**.
- Error budget is **versioned data keyed by `pipeline_version`**, stored in the DB; a budget
  change invalidates Tier-B findings computed under the old budget.

### 13 Pitfalls
| Symptom | Cause | Fix |
|---|---|---|
| reliability excellent, phones disagree 3° | reported consistency ICC | absolute agreement |
| SD of diffs fine, absolute wrong | SD blind to bias | report mean diff |
| quoted highest of six rows | flattering-form abuse | choose form first |
| ICC 0.89 quoted as settled | CI [0.01, 0.97] at n=20 | report interval; more shots |
| reliability differs between shooters | ICC is a ratio of shooter spread | also report SD of diffs |
| reprojection passes everything | called a 3D-aware code path | same `compute_metrics` |
| plausible wrong joint angles | 69→17 map mis-wired | anatomical-neighbour test |
| ball metrics NaN on SPL | 2024-08-28 session | 2025-12-18 |
| SPL distances off 12× | feet vs inches | two units in one file |
| effect sizes large on tiny groups | d biased up | Hedges' g |
| engine fires/un-fires between runs | within ±14 % of threshold | "borderline"; don't tune |
| old findings disagree with new budget | unversioned budget | key by `pipeline_version` |

### Project Task 13.1 (Python signatures, keep)
```python
@dataclass
class ReprojectionResult:
    trial_id: str
    phi_deg: float
    jitter_px: float
    metrics_2d: dict[str, float]        # from the REAL pipeline code
    metrics_3d: dict[str, float]        # computed directly from 3D
    squareness: float
    gated_out: list[str]

def spl_to_coco17(pose69: np.ndarray, names69: list[str]) -> np.ndarray    # [T,69,3] -> [T,17,3]
def reproject(pose_xyz, ball_xyz, phi_deg: float, scale_m_per_px: float, fps_out: float,
              jitter_px: float, frame_size: tuple[int,int], seed: int) -> tuple[np.ndarray, np.ndarray]
              # -> pose[T,17,3] (conf column = 1.0 or simulated), ball[T,2] in px
def run_reprojection_suite(trials: list[Path], phis=(0., 10., 20.), jitters=(0., 2., 5.)) -> list[ReprojectionResult]
def icc(x: np.ndarray, form: str = "A1") -> tuple[float, tuple[float,float]]   # x: [n_shots, k_phones] -> (icc, ci95)
def retest_report(paired: dict[str, np.ndarray]) -> pd.DataFrame   # metric -> [n,2]; mean diff (bias), sd diffs, icc, ci, n
```
Done criteria: φ=0, jitter=0 → every kinematic metric matches 3D to numerical precision (the
formula acceptance test); φ=20° → squareness gate fires, sagittal metrics `valid=False`;
two-phone retest on ≥ 20 shots with bias and SD of diffs per metric; ICC with form named and CI;
budget with a row per metric, "unknown" where honest, keyed by `pipeline_version`.

Expected ranges: reprojection agreement at φ=0/jitter=0 < 1e−6; scatter at jitter 2 px ~1.8°
bent / ~3° straight; squareness at φ=20° above threshold; two-phone bias < 1° / < 2 cm;
ICC(A,1) for `release_angle_deg` > 0.9 (alarm < 0.75); `release_angle` reliability SD ≤ 1.5°
(Ch 20 acceptance; alarm > 2°).

Suggested tests: anatomical keypoint map; reprojection identity to 1e−9; gate flips between 10°
and 20°; `icc()` equals mean-squares formula to 1e−9; adding a constant to one column lowers
ICC(A,1) but not ICC(C,1); `|g| < |d|` at small n; budget has a row per metric.

### Verification (Ch 13) — passing output
`phi=0 jitter=0: 12/12 match 3D, max |err| 3.2e−09`; `phi=0 jitter=2: elbow_angle_release_deg sd
1.28°, knee_min_deg sd 1.41°`; `phi=10: squareness 0.141 (thr 0.207) valid`; `phi=20: squareness
0.274 → GATED, 4 sagittal invalid, 8 valid`. Retest n=22: `release_angle_deg bias +0.31, sd_diff
1.04, ICC(A,1) 0.941 [0.86,0.97]`; `entry_angle_deg +0.28, 1.19, 0.928`; `release_height_m
+0.004, 0.021, 0.902`; `elbow_angle_release_deg +1.90, 2.87, 0.611 [0.26,0.82] ← investigate`
(partly a camera-position detector; budget row must say so).
Failures: φ=0 mismatch → formula bug, bisect by metric; gate never fires at 20° → calibration
wrong or median smoothed it; superb ICC with large bias → you reported consistency.
