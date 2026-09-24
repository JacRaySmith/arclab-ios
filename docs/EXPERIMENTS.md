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
| 2026-09-24 | *(example row — not a real result)* fixing the azimuth by whole-track gravity instead of the per-shot shape solve should raise acceptance on the three-point block without worsening the gravity fit | `fixedGravityAzimuth` vs `baseline` | `IMG_1766.mov`, spot `three`, 27 windows | McNemar (verdict flips) + paired gError | net +2 accepted, McNemar p = 0.48; median ΔgError +0.001 (n=9, sign-test p=0.73) | inconclusive — not distinguishable from chance on this corpus; needs a larger corpus or a real second night of footage |

*(No real experiment has been run and decided yet as of this pipeline's build — 2026-09-24's work
was building and round-trip-verifying the tool itself. The row above is the example the "how to add
a row" section describes; replace or delete it once the first real comparison lands.)*
