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
| 2026-09-24 | the shot-plane azimuth is one number per block, so pooling it robustly (median + MAD over *all* windows, not the mean over accepted ones) should raise recall and tighten within-block spread | `autoFoundPooledMedian` vs `autoFoundTrace` | full corpus, 98 windows, labelled (88 shot / 6 notShot / 4 unsure) | recall + McNemar per clip + within-block spread | overall recall 56.8 % → 48.9 %; **free throw: net −8 accepted (12→4), p = 0.0078** — pooling one azimuth over a clip that holds two shooting positions; elbow and three unchanged in verdict, spread unchanged or wider; precision 100 % throughout | **reverted** — the hypothesis is refuted, see `docs/BENCH-RESULTS-azimuth-2026-09-24.md` |
| 2026-09-24 | pooling gated on robust agreement (1.4826·MAD ≤ 10°) rather than "≥3 accepted shots within 25°" should pool the clips that should be pooled and refuse the one that should not | `autoFoundPooledGated` vs `autoFoundTrace` | full corpus, 98 windows | recall + McNemar + paired gError/rmsPx | **0 discordant windows** (recall identical, 56.8 %); it correctly refuses `IMG_1765` (MAD 37.5°) and pools the other two; rmsPx improves (sign test p = 0.0015), gError worsens (p = 0.033); elbow height SD 0.257 → 0.258 m | **inconclusive** — a better-stated rule that changes no verdict on this corpus; keeps the refusal honest but buys nothing measurable |
| 2026-09-24 | iterating (pool → re-solve each window over the flight window the pooled azimuth implies → re-pool) should converge on a better block azimuth | `autoFoundPooledIterated` vs `autoFoundTrace` | full corpus, 98 windows | recall + McNemar per clip | same −8 free-throw loss as `autoFoundPooledMedian` (p = 0.0078); on `IMG_1765` the iteration *diverges* (robust spread 37.5° → 42.8°, max deviation 78° → 139°); elbow spread 0.257 → 0.210 m, the one improvement | **reverted** — iteration cannot fix a clip whose windows belong to two different geometries |
| 2026-09-24 | if the free-throw clip really holds two shooting positions, pooling *within* each azimuth cluster should recover its recall and tighten its spread | `autoFoundPooledClustered` (15° gap) / `autoFoundPooledClusteredTight` (10°) vs `autoFoundTrace` | full corpus, 98 windows | recall + McNemar + within-block spread | 15° does not separate the modes (junk windows bridge the valley) and repeats the −8 loss; 10° separates them (centres 241.3° and 293.7°) and lands at free-throw recall 35.7 % vs 39.3 %, b/c 2/1, **p = 1.0**, height SD 0.465 → 0.436 m, median gError 0.015 → 0.029 | **inconclusive** — correct clustering neither costs nor buys anything significant; the spread stays ~0.44 m, so the azimuth was not what set it |
| 2026-09-24 | sensitivity probe (not a candidate): how far do release height and g-error actually move per degree of azimuth error? | `autoFoundAzimuthOffset5` (pooled azimuth + 5°, deliberately wrong) vs `autoFoundPooledMedian` | full corpus, 98 windows | paired &#124;Δrelease height&#124; and median &#124;gError&#124; | 5° ⇒ median &#124;Δheight&#124; 0.103 / 0.114 / 0.157 m (elbow / free throw / three) ≈ **0.025 m per degree**, and median &#124;gError&#124; 0.019 → 0.056 ≈ **0.0074 per degree**; within-block spread did *not* widen (elbow 0.231 → 0.167 m) | **kept as a measurement** — this is the number that rules the pooling hypothesis out: the within-block azimuth spread is 1.2–2.5°, so azimuth explains ~0.03–0.07 m of a 0.22–0.35 m spread |
| 2026-09-24 | control: does the legacy pooling rule earn its place at all, given the auto-found trace? | `autoFoundNoPool` vs `autoFoundTrace` | full corpus, 98 windows | recall + McNemar + within-block spread | recall 56.8 % → **59.1 %** (three 52.4 % → 61.9 %), b/c 0/2, **p = 0.50**; on the windows accepted in both arms the spread is *tighter* without pooling (elbow 0.257 → 0.219 m, three 0.423 → 0.348 m); `compare` verdict NO DIFFERENCE | **inconclusive, but the direction is against pooling** — 2 discordant windows can never reach significance; re-test on the next session's footage before removing the live pass-1/pass-2 pooling |

Full per-clip tables, the overall (pooled) numbers, and the regressions `ShotBench compare` flags on
each are in `docs/BENCH-RESULTS-2026-09-24.md`, and the azimuth-pooling rows' full diagnosis (why
the free-throw clip disagrees by 45°, and what a degree of azimuth is worth in metres) is in
`docs/BENCH-RESULTS-azimuth-2026-09-24.md` — read them before acting on any row above; the pooled
McNemar test alone (mixing all three clips into one number) hides exactly the elbow/free-throw vs
three-point split that matters here.
