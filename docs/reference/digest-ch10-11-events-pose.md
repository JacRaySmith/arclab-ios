# Digest — Ch 10 (Segmentation, release, flight-window end, body phases) and Ch 11 (Pose, filtering)

Source: TEXTBOOK.md Ch 10 (lines 11343–12206), Ch 11 (lines 12207–12972). Frames per
NOTATION.md: tracker output is image frame `(u, v)`, **`v` points DOWN**; conversion to
shooting plane is `y = −(v − v_ref)·s`. Time is axis 0 in every array; `NaN` = not detected.

---

## Ch 10 — Segmentation and phase detection (classical signals, no network — `[DEC]` §10.1)

Release is *defined* as the first frame on the parabola (physics), not "where a human sees the
ball leave the hand".

### 10.2 Shot segmentation `[REQ]`
- Build an up-positive height signal first: `height_px = FLOOR − v_img` (FLOOR = a fixed row,
  e.g. frame height). Apex is a *minimum* of `v` and a *maximum* of `height_px`. **Sign trap**
  (§10.2.1): feeding `v` directly finds the frames where the ball is lowest.
- Peak detection: `find_peaks(height_px, prominence = H, distance = fps·3)` with
  `H ≈ FRAME_H/2` (e.g. 540 px at 1080 rows), `distance = int(fps·3)` = 360 at 120 fps.
  - `prominence` = rise above the higher of the two adjacent valleys (not absolute height).
  - `distance` = minimum samples between accepted peaks; taller peak wins. Encodes "free throws
    are ≥ 3 s apart".
- Each peak ± a generous window is one `Shot`. **Verify count against a hand log** — first
  data-quality alarm. Never fix a mismatch by loosening `prominence`.
- Synthetic reference (§10.2.3): 2484 frames at 120 fps, 5 shots, true releases
  `[297, 754, 1241, 1786, 2324]`, apexes found `[369, 819, 1307, 1862, 2396]`, prominences
  700–900 px; spurious set-position bumps are 26–29 px. Sweep: (20,1) → 7 peaks; (20,360) → 5;
  (540,1) → 5; (540,360) → 5; (1620,360) → **0 with no error**; (540,2400) → 1.
- Mismatch interpretation (§10.2.4): fewer → ball left frame at apex / two shots closer than
  `distance` / tracker died; more → bounce, warm-up or rebound; equal-but-shifted → hand log and
  video start at different points (calibration throw).

### 10.3 Release detection `[REQ]`
Two signals:
1. Separation `sep(t) = ‖ball(t) − wrist(t)‖`; release is near the first frame where `sep`
   increases monotonically for ≥ 4 frames. Gives the search region only.
2. Physics consistency (the precise one, independent of pose quality): fit a parabola to frames
   certainly in flight (book: "separation+5 to apex+10"; reference uses an anchor window
   `apex−45 … apex+45`, 91 frames), then walk backwards computing each earlier frame's residual
   against that fit. Release = earliest frame whose residual `< τ` (book: `τ ≈ 2 px`).

Residual growth before release (§10.3.1): deviation grows like `½·Δa·t²`; reference at 2 px
noise: −10 frames → 34.18 px, −6 → 7.55, −4 → 1.95, −3 → 0.24, −2 → 5.66, −1 → 0.67, 0 → 0.31.
**Kink unmistakable from 6 frames out, invisible from 2.** Transition is not monotone.

**Naive rule (stop at first frame ≥ τ) is fragile** (§10.3.2): with 2 px noise and τ = 3 px, ~13 %
of genuine flight frames exceed τ by chance; walking 27 frames of flight → `0.87²⁷ ≈ 2 %` chance
of reaching release. Errors +15 … +26 frames, scattered (luck-dependent).

**Rule to implement — sustained MEDIAN** (§10.3.3):
```
find_release_sustained(v_sig, apex, tau=3.0, W=8, max_back=200):
  idx = anchor_window(apex)              # apex-45 .. apex+45
  c   = polyfit(idx/fps, v_sig[idx], 2)  # quadratic in image-frame v
  fr  = [max(0, idx[0]-max_back) .. idx[0]]
  res = |v_sig[fr] − polyval(c, fr/fps)|
  for i in 0 .. len(fr)-W-1:             # walking FORWARD from the earliest candidate
      if median(res[i : i+W]) < tau: return fr[i]
  return idx[0]                          # fallback
```
Reference errors: `[−6, −5, −5, −6, −6]` frames — constant bias, one-frame spread. The bias
(median tolerates the first push frames) shifts every release angle by the same ~1.8°, cancels
for within-shooter comparisons, and can be measured by eye (Task 10.1) and subtracted.
**Do NOT use "all W frames < τ"** — errors `[27, 0, 21, 23, 2]`; `0.87⁸ ≈ 33 %` luck; scatter returns.

**Choosing τ** (§10.3.4; naive-walk sweep at 2 px noise): τ = 0.5/1.0 → +20…+31 late; 2.0 →
+20…+26; 3.0 → +15…+26; 6.0 → −5…0; 12.0 → −6…−5; 25.0 → −9…−8. Too tight → late and short
window; too loose → early and the window swallows push frames (corrupts `g_recovered`). Sign
flips between τ = 3 and 6 (1.5σ–3σ of a 2 px detector). **Set `τ ≈ 1.5 × measured per-frame
centroid noise` (Ch 8), then verify by eye on 20 shots.** With the sustained rule τ = 3 reaches
−5 frames where naive needs τ = 12.

**Sub-frame refinement `[OPT]`** (§10.3.5): linear crossing of τ between the last bad frame
(`r_hi ≥ τ`) and first good frame (`r_lo < τ`): `frac = (r_hi − τ)/(r_hi − r_lo)`,
`release = k0 − frac`. One frame at 120 fps = 8.33 ms; sub-frame buys ~3 ms ≈ 0.1°. Get the
whole-frame estimate right first.

**Cost in degrees** (§10.3.6): `|dθ/dt| = g·cosθ / v` (Ch 3 timing floor, Correction A-C4) →
0.36–0.44°/frame at 120 fps at realistic parameters (**≈ 0.3–0.4° per frame**); at 30 fps
≈ 1.6°/frame. A 5-frame bias ≈ 1.8° systematic bias in `release_angle_deg` — an error-budget row
(Ch 13) that does **not** average down over 25 shots. Reference: errors −5/−6 frames →
θ error +1.70 … +1.94°. Strongest argument for filming at 120 fps.

### 10.4 Free-flight window end
Walk forward from the anchor window; flight end = last frame before the median residual over W
frames exceeds τ:
```
find_flight_end(v_sig, apex, tau=3.0, W=8, max_fwd=200):
  fr = [idx[-1] .. min(T-1, idx[-1]+max_fwd)]
  res = |v_sig[fr] − polyval(c, fr/fps)|
  for i: if median(res[i:i+W]) >= tau: return fr[i+W-1]
  return fr[-1]
```
Free oracle: refit on the final window; `g_recovered = −2·b[0]` (quadratic in metres, y up,
`y = −(v − FLOOR)·s`). Reference: windows within 3 frames of contact recover g to +0.13…+0.30 %;
windows overshooting contact by 4–5 frames give +0.99…+1.35 %. True contact = release + 124
frames in the synthetic. **`g_recovered` validates the window, NOT the release frame** — with
naive release frames θ was 8–13° wrong while g was perfect. Two separate checks; need both.
Refit on the final window `[sustained_release, flight_end]` for the actual parameters.

### 10.5 Body phases `[REQ]` (needs FILTERED keypoints — Ch 11)
| Event | Definition |
|---|---|
| set | ball vertical velocity ≈ 0 and hip vertical velocity ≈ 0, before the dip |
| dip | local minimum of ball height before the rise |
| load | minimum knee angle |
| rise onset | ball vertical velocity crosses a positive threshold |
| release | from §10.3 |
| follow-through peak | maximum wrist height after release |
| landing | ankle vertical velocity returns to ≈ 0 after peak jump |

Ordering constraint: set < dip < load < rise < release < follow < landing. Search each event only
between its neighbours; implement as a chain anchored on release, working outward.

**Event confidence** (§10.5.1) = `prominence / noise`, with per-frame noise from a still stretch:
`noise = std(diff(signal_still)) / √2` (differencing doubles variance). Use the longest still
stretch available (99 differences gives ±17 % sampling error because consecutive differences are
correlated). Reference: noise 1.53 px (2.0 injected); apex ratios ≈ 450–590. A dip at 3× noise is
a guess; Ch 14 turns low ratios into `invalid_reason` per metric (excluded from dip stats, not
from arc stats).

### 10 Pitfalls
| Symptom | Cause | Fix |
|---|---|---|
| peaks are where ball is lowest | fed image v (down) | negate / `FLOOR − v` |
| zero shots, no error | prominence above peak height | set from geometry; check hand log |
| more shots than log | dribbles/warm-ups/rebounds | raise `distance`; segment within logged session |
| count matches after tuning prominence | fitted tuning to answer | windows wrong; nothing downstream complains |
| release 15–30 late, differs per shot | naive walk stopped on one noisy frame | median-over-W |
| release late by scattered 0–30 | required all W < τ | median, not all |
| release consistently late, short window | τ too tight | τ ≈ 1.5× measured centroid error |
| release early, g drifts | τ too loose, push frames in window | tighten τ; check g per shot |
| g fine, θ wildly wrong | release frame wrong | validate both independently |
| θ biased ~2° across session | systematic release bias | measure on 20 shots by eye; correct; doesn't average down |
| release angle much worse at 30 fps | 1.6°/frame vs 0.4° | film at 120 |
| body-phase velocities pure noise | unfiltered keypoints | Ch 11 first |
| min knee angle during shoe-tie | searched whole session | chain search between neighbours |
| confidence ratios enormous | no `/√2` | differencing doubles variance |
| noise estimate jumps between sessions | short still stretch | longest still stretch |

### Project Task 10.1 (Python signatures, keep)
```python
@dataclass
class Event:
    name: str                 # 'set'|'dip'|'load'|'rise'|'release'|'follow'|'landing'
    frame: int
    frame_subpixel: float     # == frame unless §10.3.5
    confidence: float         # prominence / noise
    method: str               # which signal found it

@dataclass
class ShotWindow:
    shot_index: int
    frame_start: int          # generous bounds for the whole shot
    frame_end: int
    release_frame: int
    flight_start: int         # == release_frame
    flight_end: int           # rim/backboard contact
    events: dict[str, Event]
    g_recovered: float        # from the final refit, per shot

def segment_session(ball_v: np.ndarray, fps: float, prominence_px: float,
                    min_gap_s: float = 3.0) -> list[int]      # apex frame indices; does the sign flip internally
def find_release(ball_v, apex: int, fps: float, tau_px: float, W: int = 8) -> tuple[int, float]  # (frame, confidence)
def find_flight_end(ball_v, apex: int, fps: float, tau_px: float, W: int = 8) -> int
def detect_events(track: Track, window: ShotWindow, fps: float) -> dict[str, Event]  # FILTERED keypoints
```
Do the sign flip in exactly one place.

Done criteria: shot count matches hand log on 3 sessions without tuning prominence;
`g_recovered` per shot within tolerance on every accepted shot, others *marked* not dropped;
release within 1 frame of eye on ≥ 18/20 shots; every event has a confidence; overlay watched
for 20 shots (log: shot index, eye release, algorithm release, difference).

Expected ranges (120 fps): free-flight window 100–130 frames (alarm < 60); `g_recovered` per
shot within 2 % (whole session off in one direction → fps, Ch 9 §9.9.6 / B-C1); release
confidence large (residual step ~10× noise; near 1 → bad ball track); release error ≤ 1 frame on
18/20 (consistent offset → Ex 10.2); θ spread across a session a few degrees (15°+ → release
instability, not the shooter).

Suggested tests: synthetic segmentation count and apex ±3; synthetic release within 2 frames at
noise 0/1/2/4 px, graceful degradation; median rule's worst error over 10 seeds < naive's worst;
regression that release is not ~25 frames late (no `all()`); appended post-contact kink →
`flight_end` before it; sign flip applied once (apex is min of input, max of internal signal).

### Verification (Ch 10)
Shot count matches hand log on 3 sessions; release within 1 frame on ≥ 18/20; free-flight window
never includes a post-contact frame (`g_recovered` within tolerance per shot). Passing example:
26 peaks = 25 shots + 1 calibration throw; windows 116–124 frames; `g_recovered` mean 9.803,
sd 0.041, all within 2 %; release confidence min 388, median 442; eye 19/20. Failures: 31 peaks
vs 26 → warm-ups (clustered at start) or dribbles (scattered): bound the search, don't raise
prominence; g fine on 24 and 8.1 on one → contact frames or dead tracker: mark, don't drop; all
releases 5 frames later than eye → check τ then W; g fine on all but θ spread 15° → release
frames wrong.

---

## Ch 11 — Pose as a black box, filtering before differentiating

### 11.1 What a pose estimator gives `[REQ]`
Per frame K = 17 COCO keypoints `(u, v, confidence)`. Confidence is a heatmap peak score —
monotone with reliability, **not** a probability (never multiply confidences). Left/right are the
**subject's**: facing the camera, `left_shoulder` has *larger* `u` than `right_shoulder`
(verified: 363.8 vs 282.5). Jitter 2–5 px on a still subject; occasional L/R swaps on side views
where limbs overlap; confidence collapse under occlusion (shooting arm crossing torso at set
point on a side view); drift when subject is small in frame.

### 11.2 Backend `[DEC]`
rtmlib `Body` (RTMPose via ONNX Runtime; ~77 ms/frame CPU ≈ 13 fps; 9000-frame session ≈ 12 min;
~20 MB model download first use; pin version 0.0.16 — no `__version__`). Real API: classes are
**callable**, return two arrays `keypoints [n_persons, K, 2] float64` and
`scores [n_persons, K] float32` (Note B-N2; no `.estimate()`). Keypoint order is exactly
NOTATION.md's COCO-17. Adapter: pick the person (rule: largest box or closest to previous
frame — decide, document, and **count frames with > 1 person** as a quality signal), hstack to
`[K, 3]`. Use `Body`, not `Wholebody` (133 kps breaks K = 17). Alternatives: MediaPipe (33
points, different order), YOLO-pose (COCO-17), MeTRAbs `[ADV]` (metric 3D). Never fine-tune pose
with `fliplr` augmentation (swaps L/R). Print the 17-row order table once with your backend.

### 11.3 Filtering `[REQ]`
- Noise amplification: central difference `(x[i+1] − x[i−1])/(2Δt)` amplifies jitter by
  `√2/(2Δt)` = 84.9 px/s per px at 120 fps; forward difference by `√2/Δt` = 170. Book's figure
  "3 px → 360 px/s" (= 3 × 120) sits between (255 central, 509 forward). Reference: 3 px jitter →
  257 px/s velocity noise vs 981 px/s true peak wrist speed. Higher fps makes this *worse*.
- Filter: 4th-order Butterworth low-pass, zero-phase (forward-backward), then differentiate:
  `b, a = butter(4, fc/(fs/2))`; `kp_f = filtfilt(b, a, kp, axis=0)`; `vel = gradient(kp_f, 1/fs, axis=0)`.
  `Wn = fc/(fs/2)` normalised to Nyquist, must be in (0, 1); fs = 120 → Nyquist 60; fc = 10 → Wn 0.1667.
  **`axis = 0`** (time) — the default axis=−1 filters across coordinates and yields plausible garbage.
  Filter only the `u, v` columns; leave the confidence column untouched.
- **Note B-N1 (§11.3.3):** forward-backward filtering *squares* the amplitude response. `butter(4)` +
  filtfilt = effective 8th order; gain at nominal fc is 0.500 (−6.02 dB), true −3 dB at nominal
  10 Hz is **9.00 Hz** (butter(2) + filtfilt: 8.09 Hz, effective order 4). Winter's convention:
  2nd-order run twice with correction `C = (2^(1/2) − 1)^(1/4) = 0.8022`, designing at `fc/C`
  (10/0.8022 → real −3 dB 10.13 Hz). Keep `butter(4)`, but **record** "nominal fc = 10 Hz,
  butter(4)+filtfilt, effective order 8, true −3 dB ≈ 9 Hz".
- Zero-phase is mandatory (§11.3.4): one-pass causal filter lags **+7 frames (58.3 ms)** at
  fc = 10, fs = 120 → every event 7 frames late → ~2.3° systematic release-angle bias.

### 11.4 Cutoff by residual analysis `[DEC]`
Plot `RMS(raw − filtered)` vs `fc`; pick the knee (where it stops falling steeply and creeps
along the noise floor). Reference (2 px jitter, 120 fps): fc 2 → 10.522; 4 → 2.511; 6 → 2.001;
8 → 1.803; 10 → 1.717; 12 → 1.661; 16 → 1.580; 20 → 1.489; 30 → 1.269; 45 → 1.006. Knee 6–8 Hz;
true velocity error minimised at **8 Hz** (26.8 px/s). Expected on real wrists at 120 fps:
**8–12 Hz**; across 6–10 Hz the velocity error stays < 1 % of peak speed; 20 Hz more than doubles
it. Do once per backend, store the plot and the number in config (Ch 13 cites it).

### 11.5 Two traps
1. `filtfilt` pads by `3·max(len(a), len(b))` = **15 samples** for butter(4) → input of ≤ 15
   frames raises. Filter the whole shot then slice; or mark the metric invalid. Never fall back
   to raw silently.
2. One `NaN` in one keypoint → the **entire** trajectory of that keypoint becomes NaN
   (neighbours untouched). Interpolate or mask **before** filtering; record interpolated-frame
   counts per keypoint per shot (Ch 14 audit input; 40 % interpolated is not a measurement).

### 11.6 Do NOT filter the ball
The ball has a genuine acceleration kink at release. Filter distortion within ±5 frames of the
kink (no noise): fc 6 → 1.37 px; 10 → 0.51; 20 → 0.15; 40 → 0.05. Compare with the genuine
physics residual 0.24 px at −3 frames, 1.06 px at −6: **the filter's distortion is larger than
the release signal, same shape, same place, every shot** — systematic, not averaged by the
median rule. Filter the body; leave the ball raw until release is found; use the Ch 9 Kalman
filter for smooth ball velocities afterwards.

### 11.7 Left/right swap repair `[OPT]`
v1 greedy rule per frame f (for a left/right pair L, R):
```
keep = ‖L[f] − L[f−1]‖ + ‖R[f] − R[f−1]‖
swap = ‖R[f] − L[f−1]‖ + ‖L[f] − R[f−1]‖
if swap < keep: exchange L[f], R[f]
```
Reference: 3 injected swaps (frames 25–27) → exactly 3 repaired. A step-threshold detector
(`|step| > 4·median(step)`) only flags the run's two ends (25 and 28) — runs look like two
isolated jumps, so use the assignment test. Cautions: greedy, one bad repair propagates; fails
where shoulders coincide (side view at set point) — **least reliable on the views ArcLab uses
most**. Count repairs per shot; high count = quality flag, not a fix. Full version: per-joint
Kalman with innovation gate (Ch 9).

### 11 Pitfalls
| Symptom | Cause | Fix |
|---|---|---|
| no `.estimate` on backend | classes callable | adapter |
| extra leading dimension | `[n_persons, K, 2]` | pick person, log count > 1 |
| confidences separate | `(keypoints, scores)` | hstack to `[K,3]` |
| right-hander shows dominant left elbow | L/R are subject's | print the order table |
| velocities pure noise | unfiltered | filter first |
| filtered output garbage, no error | axis=−1 | axis=0 |
| every event ~7 frames late | causal one-pass filter | zero-phase |
| cutoff doesn't match a paper | gain halved at nominal fc; order doubled | record nominal, order, effective −3 dB |
| padlen error | window ≤ 15 frames | filter whole shot then slice |
| one keypoint all NaN | NaN propagation | interpolate/mask first; log count |
| release worse after filtering | filtered the ball | body only |
| swap repair broke frames | greedy propagation | count repairs; quality flag |
| pose slowest stage | 77 ms/frame | run once, cache `pose[T,K,3]` raw in `.npz` |

### Project Task 11.1 (Python signatures, keep)
```python
class PoseBackend(Protocol):
    KEYPOINT_NAMES: list[str]                 # COCO-17, NOTATION.md order
    def estimate(self, frame: np.ndarray) -> np.ndarray: ...   # -> [K, 3] = (u, v, conf)

class RtmlibBackend:                          # implements PoseBackend
    def __init__(self, mode: str = "balanced", device: str = "cpu") -> None: ...

def estimate_session(frame_paths: list[Path], backend: PoseBackend) -> np.ndarray   # [T, K, 3], NaN where not detected
def filter_pose(pose: np.ndarray, fs: float, fc: float, order: int = 4) -> np.ndarray  # filters u,v only, conf untouched, axis=0
def velocities(pose_f: np.ndarray, fs: float) -> np.ndarray                          # [T, K, 2] px/s
def residual_analysis(pose: np.ndarray, fs: float, fcs: np.ndarray) -> np.ndarray     # [len(fcs)] RMS
```
Done criteria: keypoint-order table printed with your backend; adapter returns `[K,3]`, test
asserts shape and column 2 ∈ [0,1]; residual analysis run, plot exists, `fc` in config with the
plot; `pose[T,K,3]` stored **raw** (filtering is cheap; backend re-run is 12 min);
interpolated-frame counts recorded; `filter_pose` raises/marks invalid on short windows.

Expected ranges: K = 17 (33 → MediaPipe, 133 → Wholebody); confidence on visible keypoints
0.5–0.9 (< 0.3 across a shot → subject too small/occluded); jitter on still subject 2–5 px
(> 8 px → subject too small); chosen fc at 120 fps 8–12 Hz (alarm < 4 or > 20); inference
~77 ms/frame CPU lightweight (≫ → reloading model per frame); persons returned 1.

Suggested tests: backend contract `[K,3]`, K=17, conf ∈ [0,1]; `KEYPOINT_NAMES` equals
NOTATION list exactly in order; filter along axis 0 only (vary K, output unchanged along K);
confidence column identical before/after; one NaN does not produce all-NaN; 10-frame window
raises/marks invalid; zero lag on a known sinusoid (cross-correlation lag 0).

### Verification (Ch 11)
- Stationary subject: filtered velocity magnitude **< 20 px/s** (fails if fc too high).
- Release frame: filtered wrist velocity within **15 %** of the raw finite-difference over a
  3-frame window (fails if fc too low — smeared the fastest event).
Both must hold; if not, fc is wrong or jitter > 5 px (a framing problem).
