#!/usr/bin/env python
"""Perseverance loop: track → grade → read errors → adjust → repeat. Escalates from parameter tweaks (level 1) to
algorithmic changes (level 2) when gains stall, and stops with an explicit human-intervention request (level 3) at a dead end."""
import argparse, json, os, subprocess, sys, time, copy
PY = sys.executable
HERE = os.path.dirname(os.path.abspath(__file__))

LEVEL1 = {   # error code → list of (path, transform) applied one per iteration, cycling
    "BALL_COVERAGE_LOW": [("ball.template_fill", lambda v: True), ("ball.template_min_score", lambda v: max(0.35, v - 0.1)), ("ball.diff_threshold", lambda v: max(10.0, v * 0.8)), ("ball.gate_diameters", lambda v: min(4.0, v + 0.5)),
                          ("ball.circularity_min", lambda v: max(0.3, v - 0.1)), ("ball.max_area_frac", lambda v: v * 1.3), ("ball.min_area_frac", lambda v: v * 0.7),
                          ("ball.max_gap_frames", lambda v: min(20, v + 4)), ("ball.orange_margin", lambda v: max(2, v - 2))],
    "BALL_NO_FLIGHT": [("ball.diff_threshold", lambda v: max(10.0, v * 0.7)), ("ball.circularity_min", lambda v: max(0.3, v - 0.1)), ("ball.orange_margin", lambda v: max(2, v - 2)),
                       ("ball.max_area_frac", lambda v: v * 1.5), ("ball.gate_diameters", lambda v: min(4.0, v + 0.5))],
    "BALL_FLIGHT_SHORT": [("ball.max_gap_frames", lambda v: min(20, v + 4)), ("ball.gate_diameters", lambda v: min(4.0, v + 0.5)), ("ball.diff_threshold", lambda v: max(10.0, v * 0.8))],
    "BALL_JUMP": [("ball.gate_diameters", lambda v: max(1.0, v - 0.4)), ("ball.gate_speed_factor", lambda v: max(1.5, v - 0.5)), ("ball.predict", lambda v: "parabola")],
    "BALL_PHYSICS_RESIDUAL": [("ball.centroid_mode", lambda v: "extent"), ("ball.extent_threshold", lambda v: max(6.0, v - 3)), ("ball.centroid_weight_power", lambda v: min(4.0, v + 1.0)), ("ball.circularity_min", lambda v: min(0.8, v + 0.1)), ("ball.gate_diameters", lambda v: max(1.0, v - 0.4))],
    "BALL_PHYSICS_GRAVITY": [("ball.circularity_min", lambda v: min(0.8, v + 0.1)), ("ball.chroma_weight", lambda v: min(4.0, v + 1.0))],
    "BALL_SIZE_UNSTABLE": [("ball.extent_threshold", lambda v: max(6.0, v - 3)), ("ball.orange_margin", lambda v: min(20, v + 3)), ("ball.chroma_weight", lambda v: min(4.0, v + 1.0)), ("ball.circularity_min", lambda v: min(0.8, v + 0.1))],
    "BALL_MERGED_INCONSISTENT": [("ball.template_min_score", lambda v: min(0.9, v + 0.1)), ("ball.merged_blob_fill", lambda v: False)],
    "BALL_HAND_INCONSISTENT": [("ball.gate_diameters", lambda v: min(4.0, v + 0.5)), ("ball.max_gap_frames", lambda v: min(20, v + 4))],
    "POSE_COVERAGE_LOW": [("pose.min_detection", lambda v: max(0.2, v - 0.1)), ("pose.min_tracking", lambda v: max(0.2, v - 0.1)),
                          ("pose.model_complexity", lambda v: min(2, v + 1)), ("pose.visibility_min", lambda v: max(0.3, v - 0.1))],
    "POSE_TELEPORT": [("pose.min_tracking", lambda v: min(0.9, v + 0.1)), ("pose.smooth", lambda v: "median3")],
    "POSE_SWAP": [("pose.min_tracking", lambda v: min(0.9, v + 0.1))],
    "POSE_SCALE_UNSTABLE": [("pose.min_tracking", lambda v: min(0.9, v + 0.1)), ("pose.smooth", lambda v: "median3")],
}
LEVEL2 = [   # architectural / algorithmic changes, applied in order when level 1 stalls
    ("ball.template_fill", True, "post-pass template matching at the parabola prediction for missing frames"),
    ("ball.merged_blob_fill", True, "ball merged with the hands after release: topmost disc of the oversized blob"),
    ("ball.interpolate_gaps", True, "interpolate short ball gaps (labelled)"),
    ("ball.predict", "parabola", "parabolic prediction of the ball position"),
    ("ball.bg_frames", 25, "denser median background model"),
    ("pose.crop_to_shooter", True, "run pose on a crop around the shooter"),
    ("pose.crop_upscale", 1.5, "upscale the shooter crop 1.5x before pose"),
    ("pose.smooth", "savgol", "Savitzky-Golay smoothing of joints"),
    ("ball.downscale", 1, "full-resolution ball detection"),
]
UNFIXABLE = {"FRAME_DROPS": "the source video drops frames; re-export or re-film", "FRAME_GAP": "the source video has a timing gap"}


def get(cfg, path):
    d = cfg
    for k in path.split("."): d = d[k]
    return d
def put(cfg, path, v):
    d = cfg; ks = path.split(".")
    for k in ks[:-1]: d = d.setdefault(k, {})
    d[ks[-1]] = v


def run(cmd, log):
    log.write("$ " + " ".join(cmd) + "\n"); log.flush()
    p = subprocess.run(cmd, capture_output=True, text=True)
    log.write(p.stdout + p.stderr + "\n"); log.flush()
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video"); ap.add_argument("--start", type=float, required=True); ap.add_argument("--end", type=float, required=True)
    ap.add_argument("--time-scale", type=float, default=1.0); ap.add_argument("--max-iter", type=int, default=14)
    ap.add_argument("--runs-dir", default=os.path.join(HERE, "runs")); ap.add_argument("--config"); ap.add_argument("--render-final", action="store_true")
    a = ap.parse_args()
    ts = time.strftime("%Y%m%d-%H%M%S"); rd = os.path.join(a.runs_dir, ts); os.makedirs(rd, exist_ok=True)
    cfg = json.load(open(a.config)) if a.config else {}
    history = []; level = 1; l2_index = 0; tweak_counts = {}; last_l2_iter = -10; bad_tweaks = set(); last_tweaks = []
    log = open(os.path.join(rd, "loop.log"), "w")
    best = None
    print(f"loop run dir: {rd}")
    for it in range(1, a.max_iter + 1):
        idir = os.path.join(rd, f"iter{it:02d}"); os.makedirs(idir, exist_ok=True)
        cpath = os.path.join(idir, "config.json"); json.dump(cfg, open(cpath, "w"), indent=1)
        tpath = os.path.join(idir, "tracking.json"); rpath = os.path.join(idir, "report.json")
        p = run([PY, os.path.join(HERE, "track.py"), a.video, "--start", str(a.start), "--end", str(a.end), "--time-scale", str(a.time_scale), "--config", cpath, "--out", tpath], log)
        if p.returncode != 0:
            print(f"iter {it}: tracker crashed:\n{p.stderr[-800:]}"); history.append({"iter": it, "score": 0, "errors": ["TRACKER_CRASH"]}); 
            if it >= 2: print("HUMAN INTERVENTION NEEDED: the tracker crashes; see", os.path.join(rd, "loop.log")); return 2
            continue
        g = run([PY, os.path.join(HERE, "grader.py"), tpath, "--report", rpath], log)
        rep = json.load(open(rpath)); codes = [e["code"] for e in rep["errors"]]
        history.append({"iter": it, "score": rep["score"], "errors": codes, "level": level})
        print(f"iter {it:2d} [level {level}] score {rep['score']:5.1f}  {'PASS' if rep['pass'] else 'FAIL: ' + ', '.join(codes)}")
        for e in rep["errors"]: print(f"       {e['message']}")
        regressed = best is not None and rep["score"] < best[0] - 5
        if best is None or rep["score"] > best[0]: best = (rep["score"], copy.deepcopy(cfg), it)
        if regressed and last_tweaks:
            # hill-climb: undo the tweaks that made it worse and remember not to repeat them
            print(f"       regression from {best[0]:.1f}: reverting " + ", ".join(f"{c}:{p}" for c, p in last_tweaks))
            bad_tweaks.update(last_tweaks); cfg = copy.deepcopy(best[1])
        if rep["pass"]:
            json.dump(cfg, open(os.path.join(rd, "best_config.json"), "w"), indent=1); json.dump(history, open(os.path.join(rd, "history.json"), "w"), indent=1)
            print(f"PASS at iteration {it}. Best config: {os.path.join(rd, 'best_config.json')}")
            if a.render_final:
                run([PY, os.path.join(HERE, "track.py"), a.video, "--start", str(a.start), "--end", str(a.end), "--time-scale", str(a.time_scale), "--config", cpath, "--out", tpath, "--render", os.path.join(rd, "final_review.mp4")], log)
                print("review video:", os.path.join(rd, "final_review.mp4"))
            return 0
        unfix = [c for c in codes if c in UNFIXABLE]
        if unfix and len(unfix) == len(codes):
            print("HUMAN INTERVENTION NEEDED: " + "; ".join(UNFIXABLE[c] for c in unfix)); return 3
        # stall detection: no score gain over the last 3 iterations at level 1 → escalate
        scores = [h["score"] for h in history]
        stalled = len(scores) >= 3 and max(scores[-3:]) <= max(scores[:-3] + [scores[-3]]) + 1.0
        if level == 1 and (stalled or all(tweak_counts.get(c, 0) >= 3 for c in codes if c in LEVEL1)):
            level = 2
        if level == 2 and (it - last_l2_iter) >= 3:
            # apply the next architectural change on top of the best config so far, then allow 2 iterations of tweaks on it
            cfg = copy.deepcopy(best[1]); last_l2_iter = it
            if l2_index >= len(LEVEL2):
                print("HUMAN INTERVENTION NEEDED: all parameter and algorithmic fixes exhausted. Remaining errors: " + ", ".join(codes))
                print("  Needed: a trained ball detector (Create ML / WASB) and/or a human check of the review video for the release frame."
                      " Best so far: iteration %d, score %.1f, config %s" % (best[2], best[0], os.path.join(rd, f"iter{best[2]:02d}", "config.json")))
                json.dump(history, open(os.path.join(rd, "history.json"), "w"), indent=1); return 4
            path, val, desc = LEVEL2[l2_index]; l2_index += 1
            put(cfg, path, val); print(f"       escalate (level 2): {desc}")
            continue
        # level 1: one tweak per error code, cycling through the list, skipping tweaks that previously caused a regression
        last_tweaks = []
        for c in codes:
            if c not in LEVEL1: continue
            k = tweak_counts.get(c, 0); tries = 0
            while tries < len(LEVEL1[c]) and (c, LEVEL1[c][k % len(LEVEL1[c])][0]) in bad_tweaks: k += 1; tries += 1
            if tries >= len(LEVEL1[c]): continue
            path, fn = LEVEL1[c][k % len(LEVEL1[c])]; tweak_counts[c] = k + 1
            base = json.load(open(os.path.join(HERE, "default_config.json"))) if os.path.exists(os.path.join(HERE, "default_config.json")) else None
            try: cur = get(cfg, path)
            except KeyError:
                import importlib.util
                spec = importlib.util.spec_from_file_location("track", os.path.join(HERE, "track.py")); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
                cur = get(mod.DEFAULT_CONFIG, path)
            new = fn(cur)
            if new == cur:            # no-op (already at that value): try the next tweak for this code
                k2 = k + 1; path2, fn2 = LEVEL1[c][k2 % len(LEVEL1[c])]; tweak_counts[c] = k2 + 1
                try: cur = get(cfg, path2)
                except KeyError: continue
                path, new = path2, fn2(cur)
                if new == cur: continue
            put(cfg, path, new); last_tweaks.append((c, path)); print(f"       tweak: {path} {cur} → {new}")
    json.dump(history, open(os.path.join(rd, "history.json"), "w"), indent=1)
    print(f"stopped after {a.max_iter} iterations without a pass; best score {best[0]} at iteration {best[2]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
