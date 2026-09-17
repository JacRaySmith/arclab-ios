#!/usr/bin/env python
"""Whole-clip shot finder + per-shot tracking/grading.
Pass 1 (fast, no pose): half-res candidates against a clip-wide median background, flights linked from any rising seed
that ends near the rim. Pass 2: run track.py + grader.py on each window; write shots/<clip>/shotNN.{json,report.json}."""
import argparse, json, os, re, shutil, subprocess, sys, time
import numpy as np, cv2
sys.argv_backup = sys.argv; sys.argv = ['x']
import track as T
sys.argv = sys.argv_backup
PY = sys.executable; HERE = os.path.dirname(os.path.abspath(__file__))


def coarse_scan(video, cfg_ball, rim_center, D_guess, step_sample=400, max_frames=None, log=print):
    cap = cv2.VideoCapture(video); fps = cap.get(cv2.CAP_PROP_FPS); N = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    ds = cfg_ball["downscale"]
    # background: median of 15 frames spread over the clip
    picks = [int(k * (N - 1) / 14) for k in range(15)]; ys, crs = [], []
    for p in picks:
        cap.set(cv2.CAP_PROP_POS_FRAMES, p); ok, fr = cap.read()
        if ok: y, cr = T.small_planes(fr, ds); ys.append(y); crs.append(cr)
    bg_y = np.median(np.stack(ys), 0).astype(np.int16); bg_cr = np.median(np.stack(crs), 0).astype(np.int16)
    cf = T.CandidateFinder.__new__(T.CandidateFinder); cf.c = cfg_ball; cf.ds = ds; cf.bg_y = bg_y; cf.bg_cr = bg_cr
    cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
    cands = []; times = []; i = 0; t0 = time.time(); prev_sig = None
    while True:
        ok, fr = cap.read()
        if not ok or (max_frames and i >= max_frames): break
        t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0 - 1.0 / fps
        sig = cv2.resize(fr[:, :, 1], (48, 27), interpolation=cv2.INTER_AREA)
        if prev_sig is not None and np.array_equal(sig, prev_sig): continue
        prev_sig = sig
        y, cr = T.small_planes(fr, ds)
        cands.append(cf.candidates(y, cr, D_guess)); times.append(t); i += 1
        if i % 2000 == 0: log(f"  scanned {i} frames, t = {t:.0f} s, {time.time() - t0:.0f} s")
    cap.release()
    return fps, times, cands


def find_flights(times, cands, rim_center, D, H=1080, W=1920):
    """Greedy linking from rising seeds; a flight must rise > 3 D, last > 25 frames, and end within 4 D of the rim centre
    or leave through the top edge and come back (handled by the re-entry rule)."""
    n = len(cands); used = np.zeros(n, bool); flights = []
    for i in range(n):
        for c in cands[i]:
            if used[i]: break
            # link forward
            hist = [(i, c[0], c[1])]; track = {i: c}; lost = 0; exited = False; last = i
            for j in range(i + 1, min(n, i + 700)):
                if len(hist) >= 6:
                    ii = np.array([h[0] for h in hist[-10:]], float); pu = np.polyfit(ii, [h[1] for h in hist[-10:]], 1); pv = np.polyfit(ii, [h[2] for h in hist[-10:]], 2)
                    pred = (np.polyval(pu, j), np.polyval(pv, j))
                elif len(hist) >= 2:
                    (ia, ua, va), (ib, ub, vb) = hist[-2], hist[-1]; k = (j - ib) / max(1, ib - ia); pred = (ub + (ub - ua) * k, vb + (vb - va) * k)
                else: pred = (hist[-1][1], hist[-1][2])
                step = np.hypot(hist[-1][1] - hist[-2][1], hist[-1][2] - hist[-2][2]) if len(hist) >= 2 else D
                gate = max(2.0 * D, 2.5 * step) * (1 + 0.15 * (j - last - 1))
                best = None
                for cj in cands[j]:
                    if exited:
                        if cj[1] > 0.35 * H or cj[0] < hist[-1][1] - D: continue
                        sc = abs(np.log(cj[2] / D)) + cj[1] / H
                    else:
                        dist = np.hypot(cj[0] - pred[0], cj[1] - pred[1])
                        if dist > gate: continue
                        sc = dist / D + 0.8 * abs(np.log(cj[2] / D))
                    if best is None or sc < best[0]: best = (sc, cj)
                if best:
                    track[j] = best[1]; hist.append((j, best[1][0], best[1][1])); lost = 0; last = j; exited = False
                else:
                    lost += 1
                    if not exited and hist[-1][2] < 1.5 * D and lost >= 2: exited = True
                    if not exited and lost > 6: break
                    if exited and j - last > 120: break
            if len(track) < 25: continue
            vs = [track[k][1] for k in track]; rise = c[1] - min(vs)
            end_c = track[max(track)]
            near_rim = np.hypot(end_c[0] - rim_center[0], end_c[1] - rim_center[1]) < 6 * D
            if rise > 3 * D and near_rim:
                ks = sorted(track); flights.append((times[ks[0]], times[ks[-1]], len(track), rise))
                used[ks[0]:ks[-1] + 1] = True
                break
    # merge overlapping/adjacent flights
    flights.sort(); merged = []
    for f in flights:
        if merged and f[0] - merged[-1][1] < 1.0: merged[-1] = (merged[-1][0], max(merged[-1][1], f[1]), merged[-1][2] + f[2], max(merged[-1][3], f[3]))
        else: merged.append(f)
    return merged


def find_arrivals(times, cands, rim_center, D, time_scale, H=1080):
    """Shots as ball arrivals at the rim: a ball-sized candidate within 2.5 D of the rim centre, moving downward
    (v increasing over the previous frames), preceded within 1.5 s real by candidates in the upper 40 % of the frame."""
    times = np.asarray(times); n = len(cands); arrivals = []
    last_t = -1e9
    for i in range(3, n):
        near = [c for c in cands[i] if np.hypot(c[0] - rim_center[0], c[1] - rim_center[1]) < 2.5 * D and 0.5 * D < c[2] < 2.0 * D]
        if not near: continue
        c = min(near, key=lambda c: np.hypot(c[0] - rim_center[0], c[1] - rim_center[1]))
        # downward: some candidate in the previous 3 frames above this one and near it
        prev = [pc for k in range(i - 3, i) for pc in cands[k] if np.hypot(pc[0] - c[0], pc[1] - c[1]) < 2.5 * D and pc[1] < c[1] - 2]
        if not prev: continue
        # preceded by high candidates (the descent) within 1.5 s real
        w0 = np.searchsorted(times, times[i] - 1.5 * time_scale)
        high = sum(1 for k in range(w0, i - 3) for hc in cands[k] if hc[1] < 0.4 * H and hc[0] < c[0] + 2 * D and 0.4 * D < hc[2] < 2.0 * D)
        if high < 6: continue
        if times[i] - last_t < 3.0 * time_scale: continue          # one arrival per shot
        arrivals.append(times[i]); last_t = times[i]
    return arrivals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video"); ap.add_argument("--rim", required=True); ap.add_argument("--time-scale", type=float, default=4.0)
    ap.add_argument("--config", default=os.path.join(HERE, "best_config_ft.json")); ap.add_argument("--out", required=True)
    ap.add_argument("--ball-px", type=float, default=68.0); ap.add_argument("--max-frames", type=int); ap.add_argument("--limit", type=int, default=999)
    ap.add_argument("--pre", type=float, default=1.4, help="seconds of file time before the flight start"); ap.add_argument("--post", type=float, default=2.0)
    ap.add_argument("--max-iter", type=int, default=5)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    cfg = json.loads(json.dumps(T.DEFAULT_CONFIG)); T.deep_update(cfg, json.load(open(a.config)))
    rim = json.load(open(a.rim)); rc = np.mean(np.array(rim["points"]), 0)
    t0 = time.time()
    cache = os.path.join(a.out, "coarse.pkl")
    import pickle
    if os.path.exists(cache) and not a.max_frames: fps, times, cands = pickle.load(open(cache, "rb"))
    else:
        fps, times, cands = coarse_scan(a.video, cfg["ball"], rc, a.ball_px, max_frames=a.max_frames)
        if not a.max_frames: pickle.dump((fps, times, cands), open(cache, "wb"))
    arrivals = find_arrivals(times, cands, rc, a.ball_px, a.time_scale)
    print(f"coarse scan: {len(times)} frames in {time.time() - t0:.0f} s → {len(arrivals)} rim arrivals: " + " ".join(f"{t:.1f}" for t in arrivals))
    flights = [(t - 1.3 * a.time_scale, t) for t in arrivals]        # flight ≈ 1 s real before the arrival, with margin
    json.dump([{"arrival": t} for t in arrivals], open(os.path.join(a.out, "arrivals.json"), "w"), indent=1)
    rows = []
    for k, f in enumerate(flights[:a.limit]):
        s, e = max(0, f[0] - a.pre), f[1] + a.post
        tj = os.path.join(a.out, f"shot{k + 1:02d}.json"); rj = os.path.join(a.out, f"shot{k + 1:02d}.report.json")
        runs_dir = os.path.join(a.out, "runs")
        if os.path.exists(tj) and os.path.exists(rj):          # resume: keep shots already processed
            rep = json.load(open(rj)); mtr = rep["metrics"]
            rows.append({"shot": k + 1, "file_start": s, "file_end": e, "pass": rep["pass"], "score": rep["score"], "errors": [x["code"] for x in rep["errors"]],
                         "iterations": None, "coverage": mtr.get("ball_flight_coverage"), "rms_v": mtr.get("ball_fit_rms_v_px"), "g_est": mtr.get("ball_g_est_m_s2")})
            continue
        p = subprocess.run([PY, os.path.join(HERE, "run_loop.py"), a.video, "--start", str(s), "--end", str(e), "--time-scale", str(a.time_scale), "--config", a.config,
                            "--max-iter", str(a.max_iter), "--runs-dir", runs_dir], capture_output=True, text=True)
        m = re.search(r"loop run dir: (\S+)", p.stdout)
        if not m: print(f"shot {k + 1}: loop failed to start: {p.stderr[-300:]}"); continue
        rd = m.group(1); hist = json.load(open(os.path.join(rd, "history.json"))) if os.path.exists(os.path.join(rd, "history.json")) else []
        if not hist: print(f"shot {k + 1}: no iterations recorded"); continue
        best_it = max(hist, key=lambda h: h["score"])["iter"]
        shutil.copy(os.path.join(rd, f"iter{best_it:02d}", "tracking.json"), tj); shutil.copy(os.path.join(rd, f"iter{best_it:02d}", "report.json"), rj)
        rep = json.load(open(rj)); mtr = rep["metrics"]
        rows.append({"shot": k + 1, "file_start": s, "file_end": e, "pass": rep["pass"], "score": rep["score"], "errors": [x["code"] for x in rep["errors"]],
                     "iterations": len(hist), "coverage": mtr.get("ball_flight_coverage"), "rms_v": mtr.get("ball_fit_rms_v_px"), "g_est": mtr.get("ball_g_est_m_s2")})
        print(f"shot {k + 1:2d}  file {s:7.1f}–{e:7.1f}  {'PASS' if rep['pass'] else 'FAIL'} {rep['score']:5.1f} after {len(hist)} it  cov {mtr.get('ball_flight_coverage', 0):.2f}  rms_v {mtr.get('ball_fit_rms_v_px', float('nan')):.1f}  g {mtr.get('ball_g_est_m_s2', float('nan')):.1f}  {','.join(x['code'] for x in rep['errors'])}", flush=True)
    json.dump(rows, open(os.path.join(a.out, "summary.json"), "w"), indent=1)
    print(f"{sum(1 for r in rows if r['pass'])}/{len(rows)} shots pass; total {time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()
