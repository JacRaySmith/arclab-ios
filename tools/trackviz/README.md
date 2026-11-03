# trackviz — pictures of tracker variants, side by side

Desktop tooling beside the app (nothing here ships). It turns a `--track-variants` cache into the
pages and contact sheets the 2026-09-29 tracking decision was made from: one row per window, one column
per variant, every detection drawn with its stage (forward pass, backward pass, parabola walk, template
fill, edge-clipped) on the frame at the arc's apex, with the ShotBench verdict in the corner.

```
# 1. one decode per window, every variant tracked on it, each dumped to run/cache/<variant>/
swift run -c release TrajectoryProbe session footage/2026-09-13/IMG_1765.mov --rim footage/2026-09-13/rim_1765.json \
   --time-scale 4 --spot freeThrow --no-pose --track-variants base,backLink,boxSeeds,extend,gap,aspect,all \
   --gravity-time-scale --dump-windows run/cache        # repeat for the other clips
# 2. score every variant cache (from the repo root, so the labels resolve)
tools/trackviz/score.sh run <path-to-ShotBench>
tools/trackviz/compare.sh run <path-to-ShotBench>      # paired McNemar, base vs base-gts and base-gts vs each lever
# 3. draw
python3 tools/trackviz/trackviz.py --run run --probe <path-to-TrajectoryProbe>
open run/viz/index.html            # summary table + per-clip pages; run/viz/sheet-<clip>.png are the contact sheets
```

Needs Pillow (`pip install pillow`). The reference frames are exported once per window into `run/frames`.
`ShotBench` and `TrajectoryProbe` have to be built outside the tree on this Mac (`--scratch-path` under
`/tmp`, see `CLAUDE.md`); the binary needs its `ShotVideo_ShotVideo.bundle` beside it, so point at the
build product, do not copy the executable alone.

## Frame-by-frame review movies

```
swift run -c release TrajectoryProbe review footage/2026-09-13/IMG_1765.mov --cache run/cache/base-gts \
   --scores run/scores/base-gts.json --rim-found footage/2026-09-13/rim_1765_found.json \
   --out ~/Desktop/arclab-review/review-IMG_1765.mov       # one movie per clip, every window in order
```

Each window opens with a title card (id, hand label, bench verdict, sample count, time scale), then every
source frame plays with the current detection ringed (white = the fit used it, cyan = tracked but outside
the flight window, red = edge-clipped and left out, yellow = template fill), the trail so far coloured by
tracker pass, the fitted arc, the release (red double ring) and the flight end (orange ring). Step it with
the arrow keys in QuickTime Player. Windows that are ×1 content are written three times per frame so they
play at a third of the speed. About 1 GB and 4 minutes per 20-minute clip.
