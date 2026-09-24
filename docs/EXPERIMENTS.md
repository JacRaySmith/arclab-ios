# Experiment ledger

One row per `ShotBench compare` you act on. The point of the row is that a decision (kept /
reverted / inconclusive) is traceable back to a p-value and a corpus, not a memory of "it looked
better". See `docs/PIPELINE.md` for how to build the cache and run a comparison.

**Acceptance rate is never read alone** — the "result" column should name the metric that actually
moved (gError, rmsPx, within-block spread, a verdict-flip count), not just "accepted more".

## How to add a row

1. Build or reuse a cache (`docs/PIPELINE.md`, "Building the cache").
2. `ShotBench run <cache> --variant baseline --json base.json`
3. Make the change; add or adjust a `Variant` in `Variants.swift` if the change is an
   `AnalysisOptions` experiment (most are), or point `--variant` at an existing one.
4. `ShotBench run <cache> --variant <candidate> --json cand.json`
5. `ShotBench compare base.json cand.json --markdown compare.md`
6. Add a row below with the date, the hypothesis you were testing, the variant name, which cache
   (clip(s) + spot(s) + window count) it ran on, the metric that decided it, the result with its p,
   and the decision. Link or keep `compare.md` alongside the row if you want the full breakdown
   preserved.

## Ledger

| date | hypothesis | variant | corpus | metric | result (p) | decision |
|---|---|---|---|---|---|---|
| 2026-09-24 | dropping session pooling (isolating `azimuthByFixedGravity` alone) should only move windows on a clip where `baseline`'s pooling actually engaged | `fixedGravityAzimuth` vs `baseline` | full corpus, 98 windows (`IMG_1764`/`1765`/`1766`) | McNemar per clip | elbow: net −3 (b=4,c=1), p=0.375, n too small to be significant below n=6; free throw & three: 0 discordant (identical) | inconclusive — behaves exactly as designed (a pooling-free reference point), not evidence for or against pooling itself |
| 2026-09-24 | a known shooting distance should stop the azimuth wandering and raise acceptance, without an extra sensor | `knownDistance` vs `baseline` | freeThrow + three, 55 windows (elbow skipped — no fixed distance) | McNemar per clip | free throw: net −1 (p=1.0); three: net −1, 1→0 accepted (p=1.0); overall regression: freeThrow within-block height SD widened 0.430→0.465 m | **reverted** — confirms `docs/research/three-point-acceptance-2026-09-24.md`'s own rejection of this candidate |
| 2026-09-24 | constraining the rim solve's plane normal to a measured vertical (`knownUp`, from each clip's vanishing point) should recover the three-point block without breaking the free-throw/elbow controls | `gravityUp` vs `baseline` | full corpus, 98 windows | McNemar per clip + median |gError|/rmsPx + within-block spread | **three: net +10 accepted (1→11), p = 0.0063**, median |gError| 0.3%→4.6%; free throw: net −1 (p=1.0), height SD 0.430→0.491 m (widened); elbow: net +2 (p=0.5, n too small below 6), |gError| improves 6.5%→5.4% | **kept as a safety net** — see `docs/BENCH-RESULTS-2026-09-24.md` §4–5 for the full per-clip table and the honest caveats (a clean trace still beats it; the free-throw cost is small and non-significant but real) |
| 2026-09-24 | the auto-found rim trace (RimFinder, no extra sensor, no hand-tracing) should do at least as well as `gravityUp` on the three-point block, since it fixes the whole ellipse rather than only its normal | `autoFoundTrace` vs `baseline` | full corpus, 98 windows | McNemar per clip + median |gError|/rmsPx + within-block spread | **three: net +12 accepted (1→12), p = 0.0010**, median |gError| 0.3%→1.0% (best of any variant); free throw: accepted *set* unchanged (0 discordant), |gError| 1.3%→1.5%; elbow: net +2 (p=0.5, n too small below 6), |gError| improves 6.5%→2.7% | **kept, preferred over `gravityUp`** — larger and statistically cleaner win on the target, and the only variant that does not move the free-throw control's accepted windows at all; see `docs/BENCH-RESULTS-2026-09-24.md` |

Full per-clip tables, the overall (pooled) numbers, and the regressions `ShotBench compare` flags on
each are in `docs/BENCH-RESULTS-2026-09-24.md` — read it before acting on any row above; the pooled
McNemar test alone (mixing all three clips into one number) hides exactly the elbow/free-throw vs
three-point split that matters here.
