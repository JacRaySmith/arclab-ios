# pytrack — self-correcting ball + shooter tracking (OpenCV + MediaPipe Pose)

Desktop research tooling beside the iOS app. Not part of any shipped target; nothing here goes on the phone.

```
cd tools/pytrack
.venv-legacy/bin/python run_loop.py ../../footage/2026-09-13/IMG_1765.mov --start 88.5 --end 95.5 --time-scale 4 --config best_config_ft.json --render-final
```

| File | Role |
|---|---|
| `track.py` | Tracker. MediaPipe Pose (legacy `mp.solutions.pose`, CPU; mediapipe 1.0 aborts in its Metal path on this Mac) for 13 joints; ball = round orange moving blobs from a median-background difference, seeded at the wrists, linked by a gravity-aware predictor that survives the ball leaving the top of the frame, extended backwards into the hands (`held`), optional post-pass template matching at the parabola prediction (`template`). A frame without evidence is `source: none`; interpolation, if enabled, is labelled. |
| `grader.py` | Judge. Frame drops/gaps, flight segmentation from the held→free transition, coverage (off-frame frames excused via the parabola, edge-clipped blobs excluded), jumps, size stability, projected-parabola physics (perspective-correct model, gravity via ball size), template/merged estimates validated against the clean fit, side-aware pose coverage, teleports, left/right flips, torso scale. Exit 0 = PASS. |
| `run_loop.py` | Perseverance loop. Level 1: per-error parameter tweaks with revert-on-regression. Level 2: algorithmic changes (template fill, interpolation, parabola prediction, denser background, pose crop/upscale, smoothing, full-res). Level 3: stops and states what human input or model is needed. Everything logged under `runs/<timestamp>/iterNN/`. |
| `best_config_ft.json` | Configuration that passed on free throws at 89 s and 817 s (2026-09-14). |

Time scale: the 2026-09-13 clips are 120 fps slo-mo exported with 30 fps timestamps → `--time-scale 4`.

| `session.py` | Whole-clip shot finder (ball arrivals at the rim from a fast half-res candidate scan) + the perseverance loop per shot; resumable; outputs `shots/<block>/shotNN.json` + report. |
| `report.py` | Per-shot metrics: geometry via the Swift analyzer (`--track-json`, flight range and pose-based release passed through), 2-D pose metrics (camera-side elbow at set/release/max, knee min, dip→release, jump), inferred make/miss, block summary restricted to shots passing the 8 % gravity gate, makes-per-100 under the placeholder make surface. |

Status 2026-09-14 02:30: free throws — 31 windows, 12 pass the tracking grader, 6 pass the 8 % gravity gate:
release 46.6 ± 3.6°, height 2.43 ± 0.26 m, speed 7.23 ± 0.11 m/s, entry 38.4 ± 3.4°, depth 17.7 ± 4.7 cm past the front rim.
Pose metrics are noisy (elbow at release SD ~38°): MediaPipe at 8 m in a 20°-oblique view; treat as relative only.
Elbow block (alternating sides, known distance 4.85 m): 43 windows, 23 pass the grader, 16 pass the gravity gate:
release 49.0 ± 3.1°, height 2.47 ± 0.26 m, speed 6.66 ± 0.30 m/s, entry 41.8 ± 3.0°, depth 28.6 ± 14.0 cm; inferred misses are mostly long (5 of 8 by > 7 cm).
`summarize.py report.json` prints make/miss splits with Cohen's d and refuses claims below n = 5 per group.
Auto-labels for a trained detector: `export_labels.py` → `~/Desktop/arclab-labels*/` (1,417 ball tiles so far); trainer in `tools/createml/train_ball_detector.swift`.
Run one session at a time: three concurrent sessions exhausted memory.
