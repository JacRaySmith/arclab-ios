# Digest — Ch 17 (Delivery constraints, cue validator, drill schema, back-off) and Ch 18 (Report and overlay), with Ch 19–20 briefly

Source: TEXTBOOK.md Ch 17 (lines 16628–17491), Ch 18 (17493–18368), Ch 19 (18370–19146),
Ch 20 (19148–19793).

---

## Ch 17 — Delivery constraints from motor learning

### 17.1–17.2 The four claims and the evidence (CORRECTIONS C-1, C-2, NOTE N-1 — Ch 17 numbering)
| # | Book's claim | Evidence status |
|---|---|---|
| 1 | External focus beats internal focus (cue about the *effect*, not the body); card shows external cue, body-part data behind a tap | **Contested (Correction C-1).** Wulf 2013 review is real (two free-throw studies favour external); McKay et al. 2024 bias-corrected: `g = 0.01` performance, `0.15` retention, `0.09` transfer, `0.06` EMG; Bayes factors favour null. "We cannot predict when it will appear." |
| 2 | Reduced feedback frequency improves retention; report per set; consider fading; log as intervention variable | **Contested (Correction C-2).** Winstein & Schmidt 1990 is the classic; McKay et al. 2022 (61 papers, k = 75, N = 2,228): no significant effect at any time point, no reversal, "robust evidence is lacking." |
| 3 | One change at a time | Supported with caveats (Buszard 2017: 90 children, 5 instructions/block, lower-WM group got worse). Stronger reason: Ch 16 §16.6 — two interventions are uninterpretable. |
| 4 | Expect a dip: mechanical change degrades performance 1–2 weeks; back-off rule "if not recovered by week 4, we revert" | Phenomenon supported (Soderstrom & Bjork 2015; Carson & Collins 2011/2014); **"reliably", "1–2 weeks" and "week 4" are unsourced (Note N-1)**. Store as config `expected_timeline`, `revert_after_weeks`; log actual recovery week; after ~30 interventions use your own distribution. |
Caveat for all: Wulf & Shea 2002 — simple-task findings do not transfer to complex skills.
**Do not tell a coach these are established findings.**

### 17.3 Why all four rules survive on ArcLab's own grounds (the real spec)
| Rule | ArcLab's reason |
|---|---|
| card shows external cue; body data behind a tap | Ch 1: a body-part instruction asserts an ideal form; there is no consensus correct form |
| report per set, never per shot | a single shot's `entry_angle_deg` carries ~±1.3° reliability vs a ~3.4° shooter spread; ten shots averaged has an error bar a third as wide; the set is the smallest honest unit |
| one change at a time | Ch 16 §16.6 partial unique index: one active `Intervention` |
| expect a dip; back off at week 4 | Ch 16 §16.4 `earliest_session_index` must be filled; a re-test during disruption measures the disruption |
Compute everything per shot; show it per set.

### 17.4 Sample size to settle it yourself
`n_per_group = 2·(z_{1−α/2} + z_{1−β})² / g²`, α = 0.05 (1.96), power 0.80 (0.84):
g 0.01 → 156,978; 0.09 → 1,938; 0.15 → 698; 0.50 → 63; 1.00 → 16. ArcLab cannot detect the
external-focus effect; the efficacy table is scoped to drills (0.5–1.5 SD effects), never
delivery styles. The measurable thing is the n-of-1 within-subject baseline of Ch 16.

### 17.5 Constraints over instructions `[DEC]`
Prefer drills where the environment forces the pattern (shoot over a broom at the front rim =
**add** an obstacle; shoot seated = **remove** a DOF, also diagnostic; guide hand behind back =
**isolate/remove** an input). Taxonomy: add / remove / isolate. Store `constraint_share ∈ [0, 1]`
(1.0 = environment does all; 0.0 = pure instruction). **Every constraint needs a fading plan**;
`progression_criterion` must be about *removing* the constraint.

### 17.6 Cue validator (heuristic lint, not a certifier)
```
BODY   = {elbow, wrist, knee, knees, shoulder, hip, hips, arm, arms, hand, hands, finger,
          fingers, legs, leg, foot, feet, core, follow-through, your body, flick, extend, extension}
EFFECT = {ball, rim, hoop, net, backboard, arc, target, top of the rim, front of the rim,
          broom, chair, line, flight, trajectory}
words = set(lowercase cue with ',' '.' → ' ', split on whitespace)
internal = words ∩ BODY; external = words ∩ EFFECT
internal & !external → "internal"; external & !internal → "external";
both → "mixed"; neither → "unclassified"
```
Only `"external"` passes; `mixed` and `unclassified` both fail (a cue that says nothing is
worse than an internal one). Examples: "Shoot so the ball drops through the top of the rim, not
the front." → external; "Extend your knees more and follow through." → internal; "Keep your
elbow under the ball." → mixed (surface for a human); "Be smooth." → unclassified. Note the
multi-word BODY/EFFECT entries will never match a whitespace split — the book's lint is
word-level; treat multi-word entries as aspirational or add phrase matching.

### 17.7 Feedback schedule (data on the `Intervention` row)
`feedback_schedule(n_sets, every, fade_after)`: `k = every`; for set s: if `s > 0 and s %
fade_after == 0: k += 1`; show iff `s % k == 0`. 12 sets: (1, 99) → 12/12 = 100 %; (1, 4) →
`FFFFF.F..F..` 7/12 = 58 %; (2, 4) → `F.F...F.F...` 4/12 = 33 %. `fade_after = 99` = never
fade (control condition). Per-shot over 12 sets of 10 = 120 deliveries. **Store the realised
schedule**: `feedback_sets_shown`, `feedback_sets_total`.

### 17.8 Drill schema — 14 required fields (every field required to ship)
`drill_id, target_fault, candidate_cause, mechanism (constraint|instruction|both),
constraint_description, external_cue, reps_sets, practice_structure (blocked→random),
progression_criterion, regression_criterion, retest_protocol, expected_timeline, evidence_tier,
contraindications`. Groups: targeting (3) / mechanism (3) / dosage & progression (4) /
evaluation (4). `evidence_tier ∈ {coach_recommended, in_house_n10, in_house_n30}` — v1 ships all
`coach_recommended`; the other two are computed by Ch 16's efficacy query, never hand-written.
`retest_protocol` must carry Ch 16's four fields: `n_shots, metric, target,
earliest_session_index`. `regression_criterion` is the one people leave blank ("a ratchet has
no way to fail"). `contraindications` example: "do not prescribe leg-drive drills when the
distance ladder indicates a strength limit; reduce range instead." Optional extra:
`constraint_share` (validate if present, not in the 14).

Validator (`validate_drill`): every field present and non-empty (an `in` check alone lets
`external_cue: ""` through); `mechanism` in enum; `evidence_tier` in enum (YAML `no` → False
trap); `cue_focus(external_cue) == "external"` (override flag allowed, with a review note);
`retest_protocol` has all four keys. Load with `safe_load`.

Reference drill: `broom_arc` — target `flat_arc`, cause `push_release`, mechanism constraint,
"broom held horizontally at the front of the rim, 30 cm above it", cue "Send the ball over the
broom, not at the rim.", "3 sets of 10, feedback after each set", blocked → random,
progression "8 of 10 clear the broom in 2 consecutive sets", regression "fewer than 5 of 10
clear in 2 consecutive sets", retest `{n_shots: 25, metric: entry_angle_deg, target: 42.0,
earliest_session_index: 3}`, timeline "2-4 weeks", `coach_recommended`, contraindication "Do
not use with a shooter already above the 47 deg band.", `constraint_share: 0.9`.

### 17.9 The dip and the back-off rule
`effect_sd = (after − before_baseline) / reliability_sd` with **`before_baseline` frozen at the
pre-intervention value for the whole intervention** (never rolled forward — it would absorb
the dip). Example (BASE 44.0, REL 1.3): recovers `[41.9, 42.6, 44.1, 45.0, 45.6]` → effects
`[−1.62, −1.08, +0.08, +0.77, +1.23]`; stalls `[41.8, 42.0, 42.3, 42.5, 42.4]` → `[−1.69, −1.54,
−1.31, −1.15, −1.23]`. **Back-off rule: `effect_sd ≤ 0` at week 4 → REVERT** to the previous
pattern; otherwise keep going. Weeks 1–2 are indistinguishable (−1.6 vs −1.7): do not act on the
first two data points. `earliest_session_index` prevents scoring the dip as failure.

### 17 Pitfalls
| Symptom | Cause | Fix |
|---|---|---|
| told a coach external focus is established | sources predate 2024 meta-analysis | "contested; we use external cues because we have no standing to prescribe body positions" |
| cue drifted to body parts | no validation | `cue_focus` in validator |
| cue passes and says nothing | unclassified accepted | require an effect word |
| feedback rule only in renderer | raw table visible | per-set is delivery; per-shot storage separate |
| drill reverted at week 2 | acted inside the dip | back-off at week 4 |
| dip vanished | baseline rolled forward | freeze baseline |
| progression without regression | blank shipped | both required |
| two drills "go together" | claim 3 as preference | unique index |
| works only with the broom | no fading plan | progression = removing constraint |
| `evidence_tier: no` → False | YAML 1.1 | quote + enum |
| A/B test of cue wording on 12 shooters | g ≈ 0.15 needs ~700/group | scope efficacy to drills |
| coach objections absorbed without trace | review is an artifact | dated `ReviewNote` per edit |

### Project Task 17.1 (Python signatures, keep)
```python
@dataclass(frozen=True)
class RetestProtocol:              # the four fields from Ch 16 §16.4
    n_shots: int
    metric: str
    target: float
    earliest_session_index: int

@dataclass(frozen=True)
class Drill:
    drill_id: str
    target_fault: str
    candidate_cause: str
    mechanism: str                 # "constraint" | "instruction" | "both"
    constraint_description: str
    external_cue: str
    reps_sets: str
    practice_structure: str
    progression_criterion: str
    regression_criterion: str
    retest_protocol: RetestProtocol
    expected_timeline: str
    evidence_tier: str             # Ch 16 §16.7's three tiers
    contraindications: str
    constraint_share: float | None = None       # §17.5, optional
    review_notes: tuple[ReviewNote, ...] = ()   # dated coach objections

@dataclass(frozen=True)
class ReviewNote:
    date: str                      # ISO
    reviewer: str
    field_changed: str
    was: str
    note: str

def load_drills(path: Path, rules: list[Rule]) -> list[Drill]   # safe_load + validate + cross-check (fault, cause) vs rules; orphan = error
def coverage(drills: list[Drill], rules: list[Rule]) -> dict[tuple[str, str], int]   # (fault_id, cause_id) -> n drills
```
Done criteria: `load_drills` rejects missing/empty fields, bad enums, incomplete
`retest_protocol`, non-external cue (override flag); **≥ 2 drills per (fault, cause) pair**;
no orphans; all `coach_recommended` at v1; coach review of four hours produced ≥ 1 dated
`ReviewNote`. Expected: ~6 causes × 8 faults; `mechanism: constraint` ≥ half;
`constraint_share` 0.6–1.0 for constraint drills; 20–40 % of first-draft cues fail the lint
(0 % → lint not wired); 10–30 review notes.

Review protocol: send YAML + one rendered card in advance; go cause by cause; record objections
in their words (`was`, `note`); ask explicitly about `contraindications`; use the coach's drill
names.

### Milestone gate M8
- [ ] Golden tests cover every rule, firing and non-firing.
- [ ] Baselines computed across ≥ 3 own sessions; Tier B fires only above 2× reliability.
- [ ] One fault → cause → drill → re-test cycle completed on yourself and logged (needs ≥ 3
      sessions of separation before the re-test counts).
- [ ] Coach review done; changes recorded.

---

## Ch 18 — The report and the overlay

### 18.1 Report is a pure function of the database `[REQ]`
`render_report(conn, session_id, rules, drills, budget) -> str` — nothing from in-memory
pipeline state. Enforce with (a) the signature and (b) a test that renders **in a fresh
process** from a database file with the pipeline never imported. Stamp `pipeline_version`
and `rules_version` (hash of the rule YAML) in the footer.

### 18.2 Template engine settings (Jinja2 specifics; translate the invariants)
- Autoescape data, never template text (default is OFF — a coach's `<` breaks layout).
- **Strict undefined**: a missing value must raise, never render as empty (Ch 14: a metric
  must never silently disappear).
- Formatting in filters, not inline: `deg → "{:.1f}°"`, `m → "{:.3f} m"`, `pct → "{:.0f}%"`,
  `pm(v, e) → "{v:.1f} ± {e:.1f}"` — every reported value carries its random error.
- `jinja2.Markup` removed in 3.x (`markupsafe.Markup`).

### 18.3 Figures embedded as base64 data URIs
`data:image/png;base64,…`; base64 overhead **1.335×**; reference figure 4.0×1.6 in at 110 dpi =
440×176 px, ~15 KB PNG → ~20.8 K chars; six figures ≈ 90 KB PNG ≈ 120 KB text. Set pixel
size in the figure, not by CSS scaling. Headless raster backend; close every figure in a loop
(>20 open → warning + memory growth); PNG output is byte-deterministic (needed for the
re-render test).

### 18.4 Order on the page — fixed (delivery rules as vertical position)
| # | Section | Rule |
|---|---|---|
| 1 | The **one** active finding: tier badge, external cue, drill, re-test (no body-part data on this card) | Ch 17 rule 1 & 3; Ch 15 §15.5 |
| 2 | Stage 2 physics: release angle/speed/height each **with ±**, entry angle vs band, depth, `n` | Ch 1 §1.2; Ch 13 §13.6 |
| 3 | Variance **attribution sentence** (Ch 5, has units: "release speed accounts for 71 % of your depth variance, and your depth SD is 14.1 cm"), THEN the manifold percentage (Ch 6) with SD(depth) beside it | Note A-N3 |
| 4 | Consistency trend across sessions | Ch 1 §1.5 |
| 5 | Descriptive kinematics, distributions, **no targets** (a green band would promote Tier C to a norm) | Ch 1 §1.3 |
| 6 | Capture quality: g-test result, discard counts, informativeness note, what could not be measured and why — always present | Ch 9 §9.9, Ch 14 |

Section 1 with two active findings must **raise** in the renderer (never `findings[:1]`); on a
session with no finding, section 1 says so.

Context contract (`check_report_context(ctx) -> list[str]`, raise if non-empty):
`SECTIONS = ["finding", "physics", "attribution", "trend", "descriptive", "capture"]` in that
order; `len(active_findings) == 1`; `ucm_ratio_pct` present ⇒ `sd_depth_m` present;
attribution after physics; no descriptive metric has a `target`; capture block has
`g_recovered`.

### 18.5 Overlay — exactly five elements
| Element | Source | What it reveals |
|---|---|---|
| Ball detections (Ch 9 **gated raw**) | tracker input | jump to a jersey; gap on blurred frames |
| Fitted parabola (Ch 3) | model | curve off the detections → wrong window bounds |
| Skeleton (Ch 11) | pose | L/R swaps, teleporting limbs |
| Phase markers (Ch 10: release, set, apex) | events | does the release marker land where your eye lands? |
| Per-frame validity flags (Ch 14) | which frames metrics used | metric from untrusted frames |

Drawing conventions: points are `(u, v)` = `(col, row)`; image array is `[rows, cols, BGR]`;
colours BGR (orange `(0,165,255)`, green `(0,255,0)`); sub-pixel via `shift = 4` (coords ×16;
~0.02 px placement vs up to 0.4 px at shift 0 — match Ch 9's harness convention); polylines
need a list of `[N,1,2]` int32; text origin is bottom-left; draw a 60 % translucent dark box
behind labels (`addWeighted(box, 0.6, frame, 0.4)`). **Assert the overlay drew something**
(count non-background pixels; reference frame: 3,939 of 240×400).
Validity per frame: accepted detection → filled circle; gated-out/missing → hollow circle at the
filter's predicted position in a second colour; outside fit window → dimmed. Never leave a frame
with no marker (indistinguishable from unprocessed).

Encoding: `ffmpeg -framerate <fps_measured> -start_number 1 -i overlay/%06d.png -c:v libx264
-crf 18 -pix_fmt yuv420p -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" overlay.mp4`. `-framerate` is an
input option (before `-i`; default 25); use **`fps_measured`, never `fps_nominal`**;
`-start_number` default 0; `yuv420p` needs even dimensions (the pad filter) and is required for
QuickTime/browser playback; crf 18 ≈ visually lossless. For *extracting* frames use
`-fps_mode passthrough` (Correction B-C2): `-vsync 0` is deprecated on 5.1–7.x and removed in
8.x; `-fps_mode 0` does NOT work (the value must be the word).
Release-marker test (§18.5.5): step through 20 shots, write down your release frame *before*
looking; median disagreement > 1–2 frames ⇒ Ch 10 bias (~0.4°/frame at 120 fps) → error budget.

### 18.6 Re-render test
Canonical row digest: sort rows by `(shot_id, name)`, serialise with sorted keys and no
whitespace, sha256 (first 16 hex). Change one rule threshold (e.g. `flat_arc` 40.0 → 38.0),
re-render a stored session: findings differ, metric-row digest identical. Proves the renderer
did not write; the fresh-process test proves it did not read pipeline state. Do both.

### 18 Pitfalls (condensed; see Appendix E "Reporting and rendering")
number silently missing → strict undefined; coach note broke layout → autoescape; precision
differs between blocks → filters; hangs on server → headless backend; >20 figures → close;
blurry charts → size in figure; multi-MB report → embedded frames (video is a file); two
findings → renderer must raise; UCM alone → SD(depth) + attribution first; Tier-C with a band
→ context check; nothing about a failed metric → section 6 mandatory; markers transposed →
(u,v) vs [row,col]; red came out blue → BGR, read a pixel back; label off top → bottom-left
origin; polylines nonsense → list of [N,1,2] int32; unannotated video → count pixels; wrong
speed → fps_measured; ffmpeg reads no frames → `-framerate` before `-i`, start number;
"height not divisible by 2" → pad; won't play on phone → yuv420p via ffmpeg; re-render changed
stored metrics → digest rows; two reports disagree → version stamps.

### Project Task 18.1 (Python signatures, keep)
```python
def build_context(conn: sqlite3.Connection, session_id: str, rules: list[Rule],
                  drills: list[Drill], budget: ErrorBudget) -> dict      # NOTHING from the pipeline run
def check_report_context(ctx: dict) -> list[str]                          # §18.4.3; raise if non-empty
def render_report(conn, session_id, rules, drills, budget) -> str         # build_context -> check -> render
def fig_to_data_uri(fig, dpi: int = 110) -> str

def draw_frame(frame: np.ndarray,          # [H, W, 3] uint8, BGR
               ball_uv: np.ndarray,        # [T, 2] image frame, NaN where missing
               ball_source: np.ndarray,    # [T] "detected" | "predicted" | "outside"
               fit_uv: np.ndarray,         # [T, 2] fitted parabola
               pose: np.ndarray | None,    # [K, 3] (u, v, confidence) for this frame
               phases: dict[str, int],     # {"set": 1031, "release": 1042, ...}
               frame_index: int) -> np.ndarray
def render_overlay(conn, shot_id: str, frames_dir: Path, out_dir: Path) -> Path   # writes out_dir/%06d.png
def encode(out_dir: Path, fps_measured: float, dest: Path) -> None                 # fps_measured, never nominal
```
Done criteria: one self-contained HTML (no external CSS/images/fetches; identical offline);
fresh-process render; context check called and raises on all six violations; six sections on
every report incl. no-finding sessions; no UCM % without SD(depth); every value ± random error,
every session SD with n; overlay draws all five elements, gated vs accepted visibly different;
encoded file plays in browser and QuickTime at the right speed; re-render test passes both
halves.
Expected ranges: report 100–400 KB (> 2 MB → frames embedded); 4–8 figures; 8–30 KB per PNG;
render < 2 s (> 30 s → recomputing); overlay encode 1–3× realtime; release-marker disagreement
median 0–2 frames (≥ 4 → ~1.6° bias); digest match exact.

### Verification (Ch 18)
Fresh-process render exits 0 with identical bytes; opens offline; all six sections on an empty
session; context check fires on each of six violations; re-render passes both halves; twenty
shots watched with your release frame written first, median disagreement recorded into the
Ch 13 budget. Common failures: 4 MB report; strict-undefined exception on first real session
(the setting working — add an explicit "not measured" key, do not remove the setting); ball
track not drawn because float64 given to polylines.

---

## Ch 19 — Debugging as reasoning (brief)
- Loop: Observation (number + context written) → Hypothesis (list ordered by test cost) →
  Experiment (two outcomes point different ways) → Evidence (the number) → Diagnosis (one
  sentence naming a mechanism) → Fix (one change) → Verification (re-measure + regression test).
- Oracles in cost order: `s_from_g` vs `s_from_ball` (geometry, 1 min) → golden tests (engine,
  1) → synthetic harness (math/fit, 2) → SPL reprojection (formulas, 5) → detections into the
  harness (tracker, 10) → pose overlay + confidences (15) → detector eval on this session (20)
  → overlay 20 shots (events, 30). Four minutes clears three stages. A failing oracle names its
  stage; stop and fix. The synthetic harness supplies its own scale and fps so it **cannot**
  test their acquisition.
- When nothing fails: shrink the input (session → shot → window); `git bisect` with oracle
  scripts; suspect the seams (units, NaN, frame-index meaning at boundaries).
- `g_recovered` hypothesis table (**Correction B-C1**): `g_recovered = g_true ·
  (fps_claimed/fps_true)²` (book had it inverted; low g ⇒ file runs *faster* than metadata);
  `g_recovered = g · (s_assumed/s_true)` (scale linear); tilt: `g_recovered = g·cos φ`
  (cannot explain g > 9.81). Reference: 7.4 → ratio 0.754 → fps ratio 0.869 (+15.1 % faster),
  or scale 24.6 % low, or tilt 41.0°; ball size can only move things **+4.57 % / +4.71 %**
  (ruled out by magnitude); 240-fps-with-frames-dropped ⇒ 4g = 39.24 (ruled out by sign).
- Case B fingerprints for an inflated elbow SD (30 shots): `r(angle, per-shot squareness) ≈
  0.96` ⇒ squareness varies; `r(angle, set frame) ≈ 1.00` ⇒ event wandering; max **robust z**
  `|h − median| / (1.4826·MAD)` in the hundreds ⇒ L/R swaps (ordinary z ≈ 2, useless). The SD
  alone (4.7 / 5.8 / 6.9) does not discriminate. Upstream swap test: NIS spikes (Ch 9).
- Case C: blur raises in-window residual RMS (1.16 → 2.13 px, fails the < 1.5 px gate) and
  shifts release +6; a late anchor window leaves RMS untouched and shifts +1. Compute release
  from both the physics and separation signals to test the wrist-confidence hypothesis.
  Compare sessions to each other, not to "truth" (the median rule's ~2-frame bias is known).
- Store per-shot evidence in the `Metric` row (window bounds, `resid_rms_px`, `squareness`,
  `n_frames`, `g_rec`); flags: `n_frames < 25` (window too short), `resid_rms_px ≥ 1.5`,
  `squareness < threshold`, `|g_rec − 9.81|/9.81 > 0.02`. A 23-frame window with the lowest
  RMS on the page recovered g 7 % low — a low residual is not a good fit. `SELECT`, not `print`.
- Exercise 19.1 expected: fps error found in 1–5 min via g-test (report must print
  `g_recovered` and `fps_measured`); keypoint swap 5–20 min via overlay; threshold edit minutes
  with a rules version stamp, hours without.

## Ch 20 — Evaluation (brief)
Acceptance criteria `[REQ]` (make it a test file, one stored number + date + `pipeline_version`
per row):
| Criterion | Passes means |
|---|---|
| Synthetic property test | θ within 1°, v within 2 %, g within 2 % from rendered video at **60/120/240 fps** |
| Real-video g-test | ≥ 90 % of protocol-compliant sessions pass all **three** conditions: scales agree within 3 %, residual RMS < 1.5 px on gated raw detections, ≥ 25 free-flight frames |
| `release_angle` reliability (two-phone) | SD ≤ 1.5°, absolute agreement (ICC(2,1)/ICC(A,1)); report mean (bias) and SD of differences |
| `entry_angle` reliability | SD ≤ 1.5°, same |
| Invalid rate under protocol | < 10 % **per metric** (Ch 14 bands: < 5 pass; 5–10 pass with banner; 10–15 legitimate report but **fail**; > 15 refuse and fail) |
| Golden tests | every rule has firing and non-firing fixtures; all pass |
| 3 shooters unlike you (incl. a lefty and a size-6 ball) | reports generated, no crashes, deliberately bad session refused by pre-flight naming check and fix |
| Coach review | reads the report unaided; finds *the finding* credible; objections logged (separate from Ch 17's drill review) |

§20.2 attainability at θ = 52°, v = 7.1, h = 2.2, L = 4.19: one-frame release-anchor cost
`rad2deg(g·cosθ/v / fps)` = **1.625° at 30 fps (fails 1.5° alone), 0.812° at 60 (1.8× margin),
0.406° at 120 (3.7×)**; fit noise 0.039° over 108 frames → RSS 0.408°. **60 fps is the floor;
120 the target.** Entry angle and depth are exactly invariant to the release anchor
(`d(entry) = −6.4e−15°`) — but only if `L` is updated (`L2 = L − vx·dt`); stale L → depth error
3.6 cm at 120 fps, **14.6 cm at 30 fps** with a perfect entry angle. Entry-angle fit-noise
floor: 0.397° (30-frame window; SD θ 0.245°, v 0.0360, h 0.0023), 0.153° (60 fr), **0.067°**
(108 fr). Note: a ~2° *systematic* release-angle bias does not violate a 1.5° *reliability*
criterion (shared bias cancels in a difference). What decides both 1.5° criteria is capture
geometry (tripod, squareness, undistortion, two phones 30 cm apart), measured only by the
two-phone test.

§20.3 size-6 test: `0.2426/0.232 − 1 = +4.57 %` on `s_from_ball` > 3 % gate ⇒ **refused
before shot one, 1.52× margin**. Scale-derived metrics (wrong by 4.57 %): `release_speed_mps`,
`release_height_m`, `depth_m`, `lateral_m`; scale-invariant: `release_angle_deg`,
`entry_angle_deg`, `flight_frames`. Entry floor must be **computed** `arcsin(D_ball/D_rim)`:
32.06° (size 7), **30.51°** (size 6) — a pasted 32.1° is a false Tier-A claim for a size-6
shooter. The size-6 shooter tests three things: the scale gate, `D_ball` as configuration, the
computed floor.

§20.4 example run: g-test pass rate 0.93; release reliability 0.9°; entry 1.2°; invalid rates
entry 4 %, depth 7 %, elbow_release **12 % → the one failing test**. Done criteria: stored
numbers with date and version; three shooters filmed to PROTOCOL.md by someone else; one
deliberately bad session refused; separate coach review; every red cell has an owner/next step
or a written ship decision (never for a Tier-A criterion, e.g. g-test at 80 %).
§20.4.2: n = 3 is a robustness test, not a study. SPL now has five participants / 583 trials
(extra mocap validation subjects, not "shooters unlike you").
§20.5 next, by value: front camera (removes an Unmeasurable; sync unverified) → spin at
240 fps → metric 3D pose `[ADV]` (replaces refusal with estimate — be sure) → drag term
(+1.20 % g, 4.8 cm depth; loses closed form) → on-device pre-flight. Missing from the list:
more shooters (efficacy n = 30 ⇒ ±0.45 SD).
Milestone M9: every row stored with number/date/version; every row passes or has a written
ship decision; bad session refused naming check and fix; coach review logged; Exercise 19.1
run and its changes merged.

Final checkpoint (five answers, to a coach and an engineer): `s_from_g = g/(−2·b₂_px)` vs
`s_from_ball = D_ball/d_px`; arc optimum near 48° (44–52° broad; 44.5–54° with error mix,
A-C5) with the `∂depth/∂θ` sign flip at 50.72° (A-N2); discard bias −29 %/−38 % at 16 %/24 %;
diagnosis vs cause confidence; one thing at a time (+1.76 SD RTM artefact otherwise).
