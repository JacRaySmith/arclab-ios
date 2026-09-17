# Digest — Constants (Appendix A / NOTATION.md / Ch 0.5 / Ch 4 / Ch 9) and the Corrections & Notes index (Appendix C, plus Ch 17/20 blocks)

Sources: NOTATION.md; BACK.md Appendix A, C, D; TEXTBOOK.md Ch 0.5 §0.5.1, Ch 3 §3.10,
Ch 4 §4.3–4.7, Ch 9 §9.8.5/§9.9.5, Ch 13–20.

---

## 1. Canonical constants (NOTATION.md / Appendix A) — use exactly these in formulas

| Name | Value | Unit | Imperial origin (Ch 0.5 §0.5.1) |
|---|---|---|---|
| `RIM_DIAMETER_M` (inner) | **0.457** | m | 18 in = 0.4572 m |
| `RIM_HEIGHT_M` | **3.05** | m | 10 ft = 3.048 m |
| `LINE_TO_RIM_CENTRE_M` (free-throw line → rim centre) | **4.19** | m | 13.75 ft = 4.191 m |
| `X_FRONT_RIM_M` | **3.9615** | m | `4.19 − 0.457/2` |
| rim centre depth past front rim | **0.2285** | m | `0.457/2`; default `d_target` for the manifold |
| `BALL_DIAMETER_M` size 7 | **0.2426** | m | 30.0 in circumference; NOT hardcoded — configuration (Note A-N1) |
| size-6 ball | **≈ 0.232** | m | |
| `G` | **9.81** | m/s² | 32.17 ft/s² = 9.8054 m/s² |
| `FOOT_M` | 0.3048 (exact) | m | |
| `INCH_M` | 0.0254 (exact) | m | |
| entry floor `arcsin(D_ball/D_rim)` | **32.06°** (book rounds to 32.1°) | deg | size 7; size 6 → **30.51°**; NBA 0.2385 m → 31.46°; FIBA max 0.2483 m → 32.91° |
| commercial arc target | 45°, band **43–47°** | deg | Noah "45/11": 45° entry, 11 in (0.2794 m) from front rim ≈ 5 cm past centre, 0 in lateral; 91 % of NBA players 43–47° at 10–12 in |
| NBA free-throw launch (Hawk-Eye, 21,964 shots, 72 players) | **48.7 ± 3.0°**, **6.6 ± 0.15 m/s**, **2.71 ± 0.13 m** | | paper: 48.66 ± 2.99°, 14.74 ± 0.33 mph (6.589, SD 0.148), 8.89 ± 0.42 ft (2.710, SD 0.128). Debugging sanity range only, never a target |
| FIBA size-7 circumference | 749–780 mm → D 0.2384–0.2483 m; mass 567–650 g | | |
| ball mass (drag calc) | ≈ 0.62 kg (0.6–0.62) | kg | |
| air density ρ | 1.2 | kg/m³ | |
| drag coefficient C_d | 0.5 (literature 0.47–0.54) | — | |
| cross-section A = πD²/4 | 0.04622 | m² | |
| ½ρC_dA | 0.01387 | kg/m | |
| drag deceleration at 7.0 m/s | **1.096 m/s² = 11.2 % of g** | | at 6.6: 0.974 (9.9 %); 5.7: 0.727 (7.4 %); 4.5: 0.453 (4.6 %); 3.0: 0.201 (2.1 %) |
| drag effect on drag-free fit | `g_recovered` **+1.20 %**; depth **4.8 cm** | | Correction A-C2; ignore for v1 |
| max-range angle at v = 7.1, h = 2.2 | **50.72°** | deg | `∂depth/∂θ` changes sign here (Note A-N2) |
| Ch 4 operating point | θ = 52°, v = 7.1 m/s, h = 2.2 m, L = 4.19 m | | |
| Jacobian at operating point `J = grad_forward(52°, 7.1, 2.2)` rows (entry_rad, depth_m), cols (θ_rad, v, h) | `[[1.463, 0.0796, 0.3324], [−0.5748, 1.4559, 1.143]]` | | per natural unit: +1° θ → entry +1.463°, depth −1.00 cm; +0.1 m/s → entry +0.456°, depth **+14.56 cm**; +1 cm h → entry +0.190°, depth +1.14 cm |
| forward at operating point | entry 41.2°, depth 0.236 m | | Ch 5 §5.4 table |
| effective opening | `D_rim·sin φ`; margin `D_rim·sin φ − D_ball`; horizontal window `W(φ) = D_rim − D_ball/sin φ` | m | φ = 32.06: 0 / 0; 35: 0.0195 / 0.0340; 40: 0.0512 / 0.0796; 45: 0.0805 / 0.1139; 50: 0.1075 / 0.1403; 55: 0.1318 / 0.1608 |
| optimum entry angle | ≈ **48°**, broad 44–52°; **44.5–54°** across error mixes (Correction A-C5) | deg | flatter when angle error dominates, steeper when speed error dominates |
| timing floor `|dθ/dt| = g·cosθ/v` | **0.406°/frame at 120 fps; 0.812 at 60; 1.625 at 30** (Correction A-C4: exact 0.47°/1.95° at 120/30 in Ch 3's evaluation) | deg/frame | book's `g·Δt/(v cosθ)` (1.07°, 4.30°) is `d(tanθ)`; Ch 10 measured 0.36–0.44°/frame |
| fit-noise floor, 5 mm noise, 108 frames at 120 fps | SD θ **0.039°**, SD v 0.0056 m/s, SD h 0.0013 m → SD entry **0.067°** | | 60 fr: 0.093°/0.0136/0.0018 → 0.153°; 30 fr: 0.245°/0.0360/0.0023 → 0.397° |
| g-test scale | `s_from_g = g / (−2·b₂_px)`; `s_from_ball = D_ball / d_px` (use minor axis under blur) | m/px | use `s_from_g` downstream; `s_from_ball` is the check; never average |
| size-6 filmed as size-7 | `s_from_ball` high by **+4.57 %** (Ch 9) / **+4.71 %** (Ch 4) | | exceeds 3 % gate with 1.52× margin |
| g vs fps | `g_recovered = g_true · (fps_claimed/fps_true)²` (Correction B-C1); `g_recovered = g·(s_assumed/s_true)`; tilt `g·cos φ` | | low g ⇒ file runs FASTER than metadata |
| `g_recovered` precision vs free-flight frames (σ 2 px, s 0.0035, 120 fps) | 15 fr: 31.5 %; 20: 15.4 %; **25: 8.8 % (P(within 2 %) = 19.2 %)**; 30: 5.6 %; 40: 2.8 %; 60: 1.0 %; 80: 0.5 %; 120: 0.2 % | | 25 is a floor, not a target |
| sd(θ), sd(v) vs frames (same MC) | 25 fr: 0.47°, 1.00 %; 40: 0.24°, 0.51 %; 60: 0.13°, 0.27 %; 120: 0.05°, 0.10 % | | |

## 2. Gates, thresholds and tolerances (chapter-cited)

| Gate | Value | Where |
|---|---|---|
| g-test (all three): scales agree | within **3 %** | Ch 9 §9.9.5, Ch 14 §14.5 |
| g-test: fit residual RMS on **gated raw detections** | **< 1.5 px** | Ch 9 §9.9.5 |
| g-test: free-flight frames | **≥ 25** at 120 fps | Ch 9 §9.9.5 |
| per-shot `g_recovered` | within **2 %** | Ch 10 Task; Ch 19 flag |
| Kalman mean NIS (clean track) | ≈ 2 (1.0–4.0); alarm > 10 or < 0.5 | Ch 9 |
| fps check | `fps_measured` vs nominal within ~0.1 %; CFR | Ch 7 §7.1 |
| undistortion | straight edge bows < 1 px | Ch 7 §7.5.3 |
| shot segmentation | `prominence ≈ FRAME_H/2`, `distance = fps·3` | Ch 10 §10.2 |
| release τ | ≈ 2 px (book); **1.5× measured centroid noise**; median over W = 8 | Ch 10 §10.3 |
| separation signal | sep increasing monotonically ≥ 4 frames | Ch 10 §10.3 |
| free-flight window length | 100–130 frames expected at 120 fps; alarm < 60 | Ch 10 |
| release vs eye | ≤ 1 frame on ≥ 18/20 shots | Ch 10 verification |
| event noise estimate | `std(diff(still)) / √2` | Ch 10 §10.5.1 |
| Butterworth | order 4, `Wn = fc/(fs/2)`, zero-phase, `fc` 8–12 Hz at 120 fps (alarm < 4, > 20); effective order 8, true −3 dB ≈ 0.90·fc (9.00 Hz at 10); Winter C = 0.8022 | Ch 11 §11.3–11.4 |
| filtfilt padlen | 15 samples for order 4 → inputs ≤ 15 frames raise | Ch 11 §11.5 |
| one-pass filter lag | +7 frames (58 ms) at fc 10/fs 120 | Ch 11 §11.3.4 |
| pose confidence, jitter | conf 0.5–0.9 visible (alarm < 0.3); jitter 2–5 px (alarm > 8) | Ch 11 |
| stationary filtered velocity | < 20 px/s; release wrist velocity within 15 % of 3-frame raw difference | Ch 11 verification |
| swap-repair step flag | `|step| > 4·median(step)` (detector only; use assignment test) | Ch 11 §11.7 |
| squareness threshold | ≈ **0.207** at 15° for 0.40 m shoulders/0.50 m torso — calibrate per shooter at 0/15/30°; gate on window median; good session ≤ ~0.2, alarm > 0.3 | Ch 12 §12.7 |
| squareness sensitivity | 0.0135/degree; 1 px ≈ 0.52° | Ch 12 §12.7.2 |
| projection error | 90° elbow reads 91.99° at φ 15°, 93.56° at 20°, 95.63° at 25°, 109.47° at 45° | Ch 12 §12.3 |
| angle random error (1.5 px, 90 px) | 1.36° bent, 2.3° straight | Ch 12 §12.5 |
| fraction gated by squareness | < 10 % under protocol; > 15 % refuses variance | Ch 12 |
| ICC interpretation | < 0.5 poor; 0.5–0.75 moderate; 0.75–0.9 good; > 0.9 excellent; use ICC(2,1)/ICC(A,1) with CI | Ch 13 §13.3 |
| relative SE of an SD | `1/√(2n)`: 14 % at n = 25 | Ch 5 §5.6, Ch 13 §13.3.4 |
| Hedges' correction | `g = d·(1 − 3/(4N − 9))` | Ch 13 §13.4 |
| two-phone bias | < 1° / < 2 cm | Ch 13 |
| discard-audit bands | < 5 % report; **5–15 %** banner + sensitivity; **> 15 %** refuse variance | Ch 14 §14.2 |
| SD bias from extreme loss | −18 % at 8 %; **−29 % at 16 %**; −38 % at 24 %; −46 % at 32 % | Ch 14 §14.1 |
| sensitivity banner | flag if SD(all) vs SD(high-conf) differ by more than the reliability SD | Ch 14 §14.4 |
| pre-flight runtime | ~30 s (alarm: minutes) | Ch 14 §14.5 |
| Tier B firing | `|Δ| > 2 × reliability_sd`, `n ≥ min_n`; borderline within ±14 % | Ch 15 §15.3.2 |
| baseline | ≥ 3 sessions, ≥ 60 valid shots (per metric); rolling last 6; exclude session evaluated | Ch 15 §15.4 |
| trend | `|slope·(n−1)| > 2 × reliability_sd` | Ch 15 §15.3.4 |
| `speed_dominant_variance` | attribution > 70 %; min_n 20 | Ch 15 Task |
| `flat_arc` | mean entry < 40°, min_n 15 | Ch 15 §15.1 |
| MC vs delta | report MC + note if > ~10 % | Ch 5 §5.5 |
| bootstrap | resample shots; 1 000 reps interactive, 10 000 printed; 90 % percentile CI | Ch 5 §5.7 |
| RTM guards | three consecutive sessions (FP 18.1 % → 4.1 %); score vs multi-session baseline incl. firing session | Ch 16 §16.5 |
| efficacy tiers | `coach_recommended` → `in_house_n10` → `in_house_n30`; per-intervention noise ±1.50 SD; SE 0.47 (n 10), 0.27 (n 30) | Ch 16 §16.7 |
| back-off | `effect_sd ≤ 0` at week 4 → revert; 1–2 weeks dip and week 4 are unsourced config | Ch 17 §17.9 |
| power | `n = 2(z_{1−α/2} + z_{1−β})²/g²`: 63 at g 0.5; 698 at 0.15 | Ch 17 §17.4 |
| report size | 100–400 KB; render < 2 s; base64 1.335× | Ch 18 |
| overlay | 5 elements; `shift = 4`; crf 18; `yuv420p` + even pad; `fps_measured` | Ch 18 §18.5 |
| acceptance | synthetic at 60/120/240 (θ ≤ 1°, v ≤ 2 %, g ≤ 2 %); g-test ≥ 90 % of sessions; reliability SDs ≤ 1.5° (absolute agreement); invalid < 10 % per metric; 3 shooters incl. lefty + size 6; bad session refused; coach review | Ch 20 §20.1 |
| fps floor from reliability | 30 fps fails (1.625°); 60 fps floor (0.812°, 1.8×); 120 target (0.406°, 3.7×) | Ch 20 §20.2 |
| stale L after anchor shift | depth error 3.6 cm at 120 fps, **14.6 cm at 30 fps** | Ch 20 §20.2 |

## 3. Dataset facts (Appendix A/D, Ch 2, Ch 13)
- Oracle for ball flight (Ch 2–6): SPL-Open-Data `basketball/freethrow/data/2025-12-18/P0001/`
  — **88 trials at 60 fps** (Correction A-C1). Body kinematics only: `2024-08-28/P0001/`, 125
  trials at 30 fps (ball track stops at apex). SPL now: 5 participants, 583 trials.
- Positions in **feet**; hoop coordinates `landing_x/y` in **inches**; `time` in
  **milliseconds**; literal `NaN` in JSON; per-trial truth `result`, `entry_angle` (deg),
  `landing_x`, `landing_y`.
- 69 keypoints (SCREAMING_SNAKE); first 17 in the JSON dict are COCO order — **index by name**
  (SPL README numbers differ: `NECK` = 6, `LEFT_HIP` = 58). `NECK`, `MID_HIP` have no COCO
  equivalent. SPL third coordinate is Z (metres); phone pipeline third coordinate is confidence
  0–1 — `pose[:, :, 2] > 0.5` is nonsense on SPL.
- 2025 ball stream carries correlated 10–20 mm errors → `g_recovered` moves ±3–5 % with the
  window (apex-anchored ≈ 9.4, −4 %; release-to-rim 9.80–9.98) (Note A-C6).
- COCO-17 order: nose, left_eye, right_eye, left_ear, right_ear, left_shoulder,
  right_shoulder, left_elbow, right_elbow, left_wrist, right_wrist, left_hip, right_hip,
  left_knee, right_knee, left_ankle, right_ankle. Left/right = subject's.
- Registry metric names (Ch 2): `release_angle_deg, release_speed_mps, release_height_m,
  entry_angle_deg, depth_m, lateral_m, flight_frames` + the 12 kinematic metrics of Ch 12.
- Frames: World `X,Y,Z` (Z up, m); shooting plane `x,y` (y up, m); image `u,v` (v DOWN, px).
  Sign flip `y = −(v − v_ref)·s`. Radians in code, degrees at the boundary.

## 4. Corrections and Notes index — one line each
(Appendix C lists 8 corrections + 7 notes with A-/B- prefixes; Ch 17 adds C-1, C-2, N-1 and
Ch 20 adds an unnumbered note. All numbered blocks below.)

### Corrections (the book was wrong; original text kept with the correction beside it)
1. **A-C1** (Ch 2 §2.6, 3 §3.12, gate M1) — The 2024-08-28 session's ball track stops at apex; the oracle for g-test/release recovery is the **2025-12-18 session, P0001, 88 trials at 60 fps**; 2024 stays valid for body kinematics.
2. **A-C2** (Ch 3 §3.10) — Drag deceleration at release is **1.096 m/s² = 11.2 % of g** (book: 0.2–0.3 m/s², 3 %); the drag-free fit shifts `g_recovered` **+1.20 % (high, not low)** and depth by **4.8 cm**; still ignore for v1. (Ch 13's in-chapter restatement says "low" — trust Appendix C.)
3. **A-C3** (Ch 2 §2.3) — Trial path moved to `basketball/freethrow/data/<session-date>/P0001/`; the book's path 404s.
4. **A-C4** (Ch 3 §3.9) — Timing floor is `|dθ/dt| = g·cosθ/v`, not `g·Δt/(v cosθ)` (that is `d(tanθ)`); one-frame anchor error costs **0.47° at 120 fps, 1.95° at 30 fps**; the book's 1° is kept as a conservative floor.
5. **A-C5** (Ch 4 §4.6) — The entry-angle optimum lands at **44.5–54°**, centred near 48°, and **moves with the shooter's error mix**; the 43–47° band does not generalise.
6. **A-C6** (Ch 2 §2.6, about the replacement oracle) — 2025 ball stream has correlated 10–20 mm errors; `g_recovered` moves **±3–5 % with the window**; the Ch 10 window rule decides whether the 2 % bar is reached.
7. **B-C1** (Ch 9 §9.9.6; carried into Ch 7, 19, 20) — `g_recovered = g_true · (fps_claimed/fps_true)²` (book inverted); **a low g means the file runs faster than its metadata**.
8. **B-C2** (Ch 7 §7.2.1, Ch 18) — `-vsync 0` is deprecated (5.1–7.x) and removed in master; use **`-fps_mode passthrough`**; `-fps_mode 0` does not work.
9. **C-1 (Ch 17 §17.2.1)** — External-focus advantage shrinks to ≈ 0 after publication-bias correction (McKay 2024: g 0.01/0.15/0.09/0.06); keep the rule for Ch 1's reason (no standing to prescribe body positions); never call it an established finding.
10. **C-2 (Ch 17 §17.2.2)** — Reduced feedback frequency effect: "robust evidence is lacking" (McKay 2022, k = 75, N = 2,228); keep per-set reporting because a single shot is inside measurement noise.

### Notes (not wrong; a better figure or an unstated consequence)
11. **A-N1** (App. A, Ch 4 §4.4) — Size-7 diameter 0.2426 m is legal (FIBA 0.2384–0.2483; NBA 0.2385) and conservative; keep it, **never hardcode it**; floors 31.46°/32.06°/32.91°/30.51° (size 6).
12. **A-N2** (Ch 5 §5.4) — Covariance helps when `Jᵢ·Jⱼ·Σᵢⱼ < 0`, not when `Σᵢⱼ < 0`; `∂depth/∂θ` flips sign at 50.72°, so "flatter when harder" cancels below and **compounds above**; compute the sign.
13. **A-N3** (Ch 6 §6.4, Ch 18 §18.4.2) — UCM ratio = `(1 − 2ρu₁u₂)/(1 + 2ρu₁u₂)` is blind to magnitude; **never print it without SD(depth); never rank shooters by it**.
14. **A-N4** (Ch 3 §3.4) — `np.polyfit` is the legacy API; `Polynomial.fit` preferred, opposite coefficient order and rescaled domain.
15. **A-N5** (Ch 0.1 §0.1.7) — A bare `np.set_printoptions()` does not reset (defaults precision 8, suppress False); use the context manager.
16. **B-N1** (Ch 11 §11.3.3) — Forward-backward filtering squares the amplitude response: `butter(4)` + filtfilt is 8th order, true −3 dB at nominal 10 Hz is **8.99–9.00 Hz** (gain 0.50); record the effective cutoff; Winter's `C = 0.8022`.
17. **B-N2** (Ch 11 §11.2.2) — rtmlib has no `.estimate()`; classes are callable and return `(keypoints [N,K,2], scores [N,K])`; `PoseBackend.estimate` is the book's wrapper.
18. **C-N1 (Ch 17 §17.2.4)** — The dip's "reliably", "1–2 weeks" and "week 4" are unsourced practitioner defaults; store as config, log actual recovery weeks.
19. **Ch 20 §20.2 note (unnumbered)** — A ~2° *systematic* release-angle bias does not violate the 1.5° *reliability* criterion (shared bias cancels in a two-camera difference); and the 1.5° criterion implies a **60 fps floor** (30 fps: 1.625°/frame).
20. **Ch 16 §16.2.3 addition** — Every `within_shooter_split` discriminator must carry an `expect`; a cause without one is `untested`, never `supported` (the book's `early_wrist` lacks one).
21. **Ch 20 §20.3 refinement** — "every metric wrong by 4–5 %" is four of seven (`release_speed_mps`, `release_height_m`, `depth_m`, `lateral_m`); angles and `flight_frames` are scale-invariant; the entry floor must be computed from the configured diameter.

## 5. Traps that contradict common assumptions (cross-chapter)
- Depth is measured from the **front rim**; rim centre is 0.2285 m past it (the "11 inches"
  commercial target is 0.279 m from the front, ~5 cm deeper than centre).
- `v` (image) points **down**; apex is a minimum of `v`; the sign flip is the #1 bug.
- Σ must be built with θ in radians or the θ term is 3283× too large.
- A negative correlation between angle and speed is *not* automatically compensation.
- `g_recovered` validates the window, not the release frame; a low residual RMS on a
  23-frame window is a broken shot, not a good one.
- Filter the body, never the ball; use zero-phase or every event is 7 frames late.
- Out-of-plane angle error cannot be corrected per shot, only gated.
- ICC consistency form hides a constant camera offset; use absolute agreement and report the
  mean difference.
- Losing 16 % of shots at the extremes drops the SD 29 % while the mean is untouched.
- Divide deviations by the **reliability SD**, not the shooter's spread.
- Score re-tests against the multi-session baseline that **includes** the firing session;
  excluding it biases every drill −0.34 SD; scoring vs the firing session biases +1.76 SD.
- `1e3` in YAML is a string; `yes/no/on/off` are booleans.
- Low `g_recovered` ⇒ video runs faster than claimed, not slower.
