# Digest — Ch 14 (Missing data is a measurement: discard audit, informativeness test, gates, pre-flight)

Source: TEXTBOOK.md Ch 14 (lines 14330–14862). Consumers: Ch 15 fault engine reads the gates and
will not quote a variance the audit refused; Ch 18 renders discard counts.

---

## 14.1 The bias, quantified `[REQ]`
Tracking fails on shots that are fast (blur), rotated (occlusion), high (ball exits frame) or
sloppy (fatigue) — the extremes of every distribution reported. Dropping them biases every SD
**low** and blinds the fault engine. Simulation: 25 shots, true mean 47.0°, true SD 4.0°, 4000
sessions, three loss mechanisms:

| drop | mechanism | reported SD | bias vs true | reported mean |
|---|---|---|---|---|
| 0 % | any | 3.96 | −1.0 % (ddof=1 small-sample bias) | 47.00 |
| 8 % | random | 3.951 | −1.2 % | 47.01 |
| 8 % | extremes (both tails) | 3.279 | **−18.0 %** | 47.02 |
| 8 % | one tail (flattest) | 3.470 | −13.3 % | 47.57 |
| 16 % | random | 3.949 | −1.3 % | 47.00 |
| 16 % | extremes | 2.835 | **−29.1 %** | 47.02 |
| 16 % | one tail | 3.169 | −20.8 % | 48.11 |
| 24 % | random | 3.934 | −1.6 % | 46.99 |
| 24 % | extremes | 2.474 | −38.2 % | 47.01 |
| 24 % | one tail | 2.938 | −26.6 % | 48.57 |
| 32 % | random | 3.909 | −2.3 % | 46.99 |
| 32 % | extremes | 2.158 | −46.0 % | 47.02 |
| 32 % | one tail | 2.738 | −31.6 % | 49.04 |

- Random loss is nearly free (−2.3 % at 32 %). Extreme loss at the 16 % gate understates SD by
  29 % (true 4.0° → reported 2.8°; vs a 3.4° baseline that looks like "improved").
- **The mean stays innocent under extreme loss** (47.00 at 16 %) — every natural sanity check
  passes; only the variance is wrong, and the variance is the product.
- One-tail loss moves the mean too (48.11 at 16 %). Blur ≈ one-tail (fast flat shots blur most);
  ball-exits-frame is one-tail the other way (moves the mean down). You have a mixture.

### 14.1.1 It corrupts the attribution too
Ch 5's worked shooter (mean (52°, 7.10, 2.20), SD (2°, 0.09, 0.035), corr(θ,v) = −0.45, n = 25,
600 reps): dropping the extremes of **v** moves the % of depth variance attributed to v:
0 % → 77.8 %; 10 % → 75.8 %; 20 % → 72.0 %; 30 % → 67.6 %. Ch 15's `speed_dominant_variance`
rule fires at > 70 % — the attribution walks through the threshold and the rule stops firing;
Ch 16 then prescribes for the wrong variable or none.

## 14.2 The design `[REQ]`
1. **Per-metric validity** (Ch 2 schema): arc stats use shots where arc is valid; elbow stats use
   shots where elbow is valid. Different n per metric; always display n. **There is no such
   thing as "a valid shot"** — validity is a property of the *(shot, metric)* pair; `valid`
   lives on `Metric`, not `Shot`.
2. **Never delete.** `Shot` rows persist with `discard_reason`. Partial data is data — you almost
   always know make/miss (hand-logged at capture, per PROTOCOL.md).
3. **Informativeness test.** Per session, compare make rate on shots invalid for metric X vs
   valid for X. Also compare any metric that *is* valid on the failed shots (e.g. entry angle on
   elbow-invalid shots — continuous, more informative). If they differ materially the report says
   so: `"3 shots excluded from elbow stats; those 3 missed 2 of 3."`
4. **Gates on reporting, per metric:**

| invalid rate | band | behaviour |
|---|---|---|
| < 5 % | `<5%` | report; footnote n |
| 5–15 % (inclusive: 5.0 % and 15.0 % are in this band) | `5-15%` | report with banner; sensitivity check (SD with vs without low-confidence shots) |
| > 15 % | `>15%` | **refuse the variance claim**; report per-shot values only; state it is a capture problem |

Band logic (§14.4): `rate < 0.05 → "<5%"`; `rate <= 0.15 → "5-15%"`; else `">15%"`.
Verified: 2 %, 4 % → <5 %; 5 %, 9 %, 15 % → 5–15 %; 16 %, 30 % → >15 %.

### 14.2.1 Aggregation fields per metric per session
`n_total` (shots attempted), `n_valid` (valid = True for THIS metric), `invalid_rate = 1 −
n_valid/n_total`, `reasons` (counts by `invalid_reason` — the histogram is the diagnosis: 18 %
all `out_of_plane` = one fixable tripod problem; 18 % split across `track_terminated`,
`low_event_confidence`, `requires_front_view` = three problems, one unfixable), `band`.

## 14.3 Informativeness test
Simulation (execution quality q ~ N(0,1); `P(made) = sigmoid(0.4 + 0.9q)`;
`P(valid) = sigmoid(2.2 + 0.9q)`; 2000 sessions × 25 shots): make rate on valid shots 0.608, on
invalid 0.440, mean invalid rate 13.2 % → a 17-point gap; the survivors describe a better shooter
than the one present. Example single session: n = 25, 5 invalid (20 %); make rate valid 45 %
(9/20), invalid 20 % (1/5); report line exactly:
`"5 shots excluded from this metric; those 5 missed 4 of 5."`
- The test is a **flag, not a hypothesis test**: report counts with denominators; **never attach a
  p-value to five shots**.

## 14.4 Sensitivity check (5–15 % band)
Compute the metric SD over all valid shots and over valid shots excluding the low-confidence
ones; report both. Worked example: 25 release angles, drop the 6 least-confident (confidence
anti-correlated with extremity): SD all = 3.897, SD high-conf = 2.937, difference −24.6 %.
**Rule:** if the two SDs differ by more than the metric's reliability SD (Ch 13), the banner must
say the low-confidence shots materially change the answer.

`[DEC]` Refusing at 15 % is deliberately strict: a variance from 60 % of a session is biased, not
weaker; no confidence interval fixes bias. **You cannot report a biased variance more cautiously;
you can only decline.** Loosen only with informativeness-test evidence that the discards are
ignorable (same make rate AND same distribution on every metric valid for them) — rarely
achievable. The refusal is scoped to the variance claim: per-shot values still reported,
make/miss logged, shots count toward the baseline shot total, capture problem named.

## 14.5 Pre-flight `[REQ]` — run on the calibration throw, ~30 s, before shot one
| Check | Passes if | From | Fix if fails |
|---|---|---|---|
| fps measured | `fps_measured` matches `fps_nominal` to ~0.1 %; file is CFR | Ch 7 §7.1 | re-export; never via a messaging app |
| calibration id matches recording mode | mode string equals the calibration's | Ch 7 §7.4 | recalibrate for this mode |
| undistortion sane | a straight edge bows < 1 px | Ch 7 §7.5.3 | wrong calibration |
| ball detected on calibration throw | recall high through flight | Ch 8 | lighting; nothing orange in shot |
| g-test | scales (`s_from_g` vs `s_from_ball`) agree within 3 %; residual RMS < 1.5 px; ≥ 25 free-flight frames | Ch 9 §9.9.5 | clean factor → constant or fps; a few % → geometry (ball size ≈ 4–5 %) |
| framing | shooter fully in frame at jump peak, headroom for the ball: apex + margin inside frame, no keypoint leaves frame during the throw | Ch 14 | move tripod back |
| squareness | window median below the shooter's calibrated threshold | Ch 12 §12.7 | rotate the tripod, not the shooter |

Requirements: report **which** check failed and **the specific fix**; runs on the calibration
throw alone. A ball exiting the top of frame is the most common cause of a short free-flight
window (wrecks `g_recovered` precision, Ch 9 §9.8.5).

## Pitfalls
| Symptom | Cause | Fix |
|---|---|---|
| SD looks great, shooter has not improved | dropped extremes; −29 % at 16 % | discard audit; don't trust the mean as a check |
| mean drifted, SD fine | one-tail loss (blur) | informativeness test; reasons histogram |
| attribution blames wrong variable | extremes of that variable dropped | §14.1.1 |
| `valid` on the `Shot` row | validity is (shot, metric) | put on `Metric` |
| failed shots vanish | deleted, not soft-discarded | never delete |
| informativeness test cannot run | make/miss not logged for untracked shots | hand-log at capture |
| p-value on a 5-shot comparison | flag, not test | counts with denominators |
| 18 % invalid, undiagnosable | stored rate, not reasons histogram | store reasons |
| gates applied to whole session | boundaries are per metric | different n per metric |
| 15 % loosened to 25 % | only informativeness evidence permits | biased variance can't be reported cautiously |
| every session fails pre-flight squareness | calibrated on a different shooter | per-shooter |
| pre-flight takes 5 min | nobody runs it | 30 s, calibration throw only |

## Project Task 14.1 (Python signatures, keep)
```python
@dataclass
class MetricAudit:
    metric_name: str
    session_id: str
    n_total: int
    n_valid: int
    invalid_rate: float
    reasons: dict[str, int]              # invalid_reason -> count
    band: str                            # "<5%" | "5-15%" | ">15%"
    make_rate_valid: float | None
    make_rate_invalid: float | None
    sensitivity_sd_all: float | None     # 5-15% band only
    sensitivity_sd_highconf: float | None
    report_sentence: str | None          # the book's phrasing, pre-rendered

def audit_metric(rows: list[MetricRow], shots: list[Shot]) -> MetricAudit
def audit_session(session_id: str) -> list[MetricAudit]
def may_report_variance(audit: MetricAudit) -> bool      # the >15% gate, ONE place (report, engine, CLI all call it)

@dataclass
class CheckResult:
    name: str
    passed: bool
    value: str
    fix: str | None                      # REQUIRED when passed is False

def preflight(calibration_throw: SessionFrames, session: Session) -> list[CheckResult]
```

Done criteria: validity aggregates per metric (two metrics, same session, different n); no
`Shot` row deleted, `discard_reason` populated; informativeness sentence produced verbatim in
format; all three bands exercised by fixtures incl. a refusing `>15%` case; pre-flight runs
< 1 min on a calibration throw and prints a specific fix per failing check; **one deliberately
bad session filmed (camera 25° off) and the system refuses correctly and says why**.

Expected ranges: invalid rate on ball metrics < 5 % (alarm > 10 %); sagittal angles < 10 % (alarm
> 15 % → refused); front-view metrics on a side-only session 100 %; make-rate gap small but noisy
at n = 25 (alarm: large gap AND large n); sensitivity difference within the metric's reliability
SD; pre-flight ~30 s.

Suggested tests: validity per metric (one shot, two metrics, different `valid`, different n);
never deletes; band boundaries at **4.9 %, 5.0 %, 15.0 %, 15.1 %** (`<` vs `<=`); refusal is
scoped (per-shot values still reported at > 15 %); fixture with 3 invalid of which 2 missed →
exactly `"3 shots excluded from elbow stats; those 3 missed 2 of 3."`; every failed
`CheckResult` has a non-empty `fix`; the gate is enforced in one place (report and engine both
call `may_report_variance`).

## Milestone gate M6/M7
- [ ] Error budget complete; unknown rows listed.
- [ ] SPL reprojection harness passes every kinematic metric at φ = 0 and fails validity correctly
      at φ = 20°.
- [ ] Two-phone retest done; every metric's reliability recorded.
- [ ] Discard audit runs; gates enforced; pre-flight QC command works.
- [ ] Deliberately film one bad session (camera 25° off) and confirm the system refuses correctly
      — the real checkbox; the common first failure is refusing without saying *why*.

## Appendix E additions relevant to Ch 14
"A session at 12 % invalid: pass or fail?" → a legitimate report (5–15 % banner) AND a failed
Ch 20 acceptance criterion, both.
