#!/usr/bin/env python
"""Per-shot metrics and a block report from pytrack outputs.
Pose metrics are 2-D angles of the camera-side limbs (valid for near-side views only, per the brief); make/miss is
INFERRED from the ball's behaviour at the rim and labelled as such; geometry comes from the Swift ShotGeometry pipeline."""
import argparse, json, os, re, subprocess, sys
import numpy as np
sys.argv_backup = sys.argv; sys.argv = ['x']; import grader as G; sys.argv = sys.argv_backup
HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "..", "..", "Packages", "ShotVideo", ".build", "release", "TrajectoryProbe")
BALL_M = 0.2385


def angle(a, b, c):
    """Angle at b (degrees) between ba and bc."""
    v1 = np.array(a[:2]) - np.array(b[:2]); v2 = np.array(c[:2]) - np.array(b[:2])
    cosang = np.dot(v1, v2) / (np.linalg.norm(v1) * np.linalg.norm(v2) + 1e-9)
    return float(np.degrees(np.arccos(np.clip(cosang, -1, 1))))


def side_of(frames, vis_min=0.5):
    l = np.mean([1 for f in frames if f["pose"] and f["pose"]["l_elbow"][2] >= vis_min] or [0]) * 0 + sum(1 for f in frames if f["pose"] and f["pose"]["l_elbow"][2] >= vis_min)
    r = sum(1 for f in frames if f["pose"] and f["pose"]["r_elbow"][2] >= vis_min)
    return "l" if l > r else "r"


def release_from_pose(track, D):
    """Release = first tracked frame where the ball is at least 1.0 D from the nearer wrist, above it, and rising
    (v decreasing over the next 3 detections). Returns a frame index or None."""
    frames = track["frames"]
    det = [i for i, f in enumerate(frames) if f["ball"]["u"] is not None and f["ball"]["source"] in ("detected", "held", "template", "merged")]
    for n, i in enumerate(det):
        f = frames[i]; p = f["pose"]
        if not p: continue
        b = f["ball"]; best = None
        for w in ("l_wrist", "r_wrist"):
            if p[w][2] >= 0.3:
                d = np.hypot(b["u"] - p[w][0], b["v"] - p[w][1]); best = (d, p[w]) if best is None or d < best[0] else best
        if best is None or best[0] < 1.0 * D or b["v"] > best[1][1]: continue
        nxt = [frames[j]["ball"]["v"] for j in det[n + 1:n + 4]]
        if len(nxt) >= 2 and nxt[-1] < b["v"] - 2: return i
    return None


def pose_metrics(track, rel, end):
    frames = track["frames"]; side = side_of(frames); vis = 0.4
    def j(f, name): 
        p = f["pose"]; return p[f"{side}_{name}"] if p and p[f"{side}_{name}"][2] >= vis else None
    out = {"side": side}
    D = 2 * float(np.median([f["ball"]["r"] for f in frames if f["ball"]["r"]])) if any(f["ball"]["r"] for f in frames) else None
    px_per_m = D / BALL_M if D else None
    # dip bottom from the camera-side wrist (continuous), lowest wrist in the 1.2 s before release
    fr = frames[rel]
    pre = [f for f in frames[:rel] if f["t"] >= fr["t"] - 1.2 and j(f, "wrist")]
    dip = max(pre, key=lambda f: j(f, "wrist")[1]) if pre else None
    e, s, w = j(fr, "elbow"), j(fr, "shoulder"), j(fr, "wrist")
    if e and s and w: out["elbow_release_deg"] = angle(s, e, w)
    ext = [angle(j(f, "shoulder"), j(f, "elbow"), j(f, "wrist")) for f in frames[max(0, rel - 6):rel + 7] if j(f, "shoulder") and j(f, "elbow") and j(f, "wrist")]
    if ext: out["elbow_max_near_release_deg"] = float(max(ext))
    if dip:
        e2, s2, w2 = j(dip, "elbow"), j(dip, "shoulder"), j(dip, "wrist")
        if e2 and s2 and w2: out["elbow_set_deg"] = angle(s2, e2, w2)
        out["dip_to_release_s"] = fr["t"] - dip["t"]
        if px_per_m: out["dip_depth_m"] = (j(dip, "wrist")[1] - w[1]) / px_per_m if w else None
    # knee: minimum angle in the 0.6 s before release
    knees = []
    for f in frames:
        if f["t"] < fr["t"] - 0.6 or f["t"] > fr["t"]: continue
        h, k, a = j(f, "hip"), j(f, "knee"), j(f, "ankle")
        if h and k and a: knees.append(angle(h, k, a))
    if knees: out["knee_min_deg"] = float(min(knees))
    # jump: ankle rise from stance (median ankle y in the first 0.3 s of the window) to its minimum y after release
    stance = [j(f, "ankle")[1] for f in frames if f["t"] < frames[0]["t"] + 0.3 and j(f, "ankle")]
    after = [j(f, "ankle")[1] for f in frames[rel:] if f["t"] < fr["t"] + 0.4 and j(f, "ankle")]
    if stance and after and px_per_m: out["jump_m"] = float((np.median(stance) - min(after)) / px_per_m)
    if w and s and px_per_m: out["wrist_above_shoulder_m"] = float((s[1] - w[1]) / px_per_m)
    return out


def infer_outcome(track, rim_center, D):
    """After the ball reaches the rim zone: tracked below the ring inside its width → make; tracked leaving → miss.
    When the ball vanishes at the rim (net occlusion), use its last tracked direction: heading down into the ring's
    width → likely make; heading up or sideways → likely miss. All labelled inferred."""
    frames = track["frames"]; ru, rv = rim_center
    det = [f for f in frames if f["ball"]["u"] is not None and f["ball"]["source"] in ("detected", "template", "merged")]
    zone = [f for f in det if np.hypot(f["ball"]["u"] - ru, f["ball"]["v"] - rv) < 2.0 * D]
    if not zone: return {"outcome": "unknown", "reason": "ball never tracked within 2 diameters of the rim"}
    t_arr = zone[0]["t"]
    after = [f for f in det if t_arr < f["t"] <= t_arr + 1.2]
    below = [f for f in after if f["ball"]["v"] > rv + 1.5 * D and abs(f["ball"]["u"] - ru) < 1.5 * D]
    away = [f for f in after if abs(f["ball"]["u"] - ru) > 2.5 * D or f["ball"]["v"] < rv - 1.0 * D]
    if len(below) >= 3 and len(away) < 2: return {"outcome": "make", "reason": f"ball tracked {len(below)} frames below the ring inside its width", "confidence": "inferred"}
    if len(away) >= 3 and len(below) < 2: return {"outcome": "miss", "reason": f"ball tracked {len(away)} frames leaving the rim zone", "confidence": "inferred"}
    # vanished at the rim: direction of the last 4 tracked points
    last = [f for f in det if f["t"] <= t_arr + 0.4][-4:]
    if len(last) >= 3:
        du = last[-1]["ball"]["u"] - last[0]["ball"]["u"]; dv = last[-1]["ball"]["v"] - last[0]["ball"]["v"]
        u_end = last[-1]["ball"]["u"]; v_end = last[-1]["ball"]["v"]
        inside = abs(u_end - ru) < 0.8 * D and v_end > rv - 0.5 * D
        if dv > 0 and inside: return {"outcome": "make", "reason": "ball vanished at the rim heading down inside the ring's width (net occlusion)", "confidence": "inferred-weak"}
        if dv < 0 or abs(u_end - ru) > 1.2 * D: return {"outcome": "miss", "reason": "ball vanished at the rim heading up or outside the ring", "confidence": "inferred-weak"}
    return {"outcome": "unknown", "reason": f"ambiguous rim behaviour (below {len(below)}, away {len(away)})"}


LEVEL_PITCH = None   # set from --level-pitch: replaces the rim ellipse's normal with a zero-roll camera pitched up by this many degrees


def swift_geometry(video, tj, start, end, rim_json, time_scale, hfov, known, flight_range=None, release_time=None):
    cmd = [PROBE, "analyze", video, "--rim", rim_json, "--start", str(start), "--end", str(end), "--time-scale", str(time_scale), "--hfov", str(hfov),
           "--rim-diameter", "0.4572", "--track-json", tj] + (["--known-distance", str(known)] if known else [])
    if flight_range: cmd += ["--flight-range", f"{flight_range[0]:.4f},{flight_range[1]:.4f}"]
    if release_time is not None: cmd += ["--release-time", f"{release_time:.4f}"]
    if LEVEL_PITCH is not None: cmd += ["--level-pitch", str(LEVEL_PITCH)]
    p = subprocess.run(cmd, capture_output=True, text=True); out = p.stdout
    g = {}
    m = re.search(r"g_fit ([-\d.]+) \(([-\d.]+)%\) (\w+)\s+rms ([\d.]+) px", out)
    if m: g.update({"g_fit": float(m[1]), "g_err_pct": float(m[2]), "verdict": m[3], "rms_px": float(m[4])})
    m = re.search(r"view ([-\d.]+)°", out)
    if m: g["view_deg"] = float(m[1])
    m = re.search(r"release θ ([-\d.]+)°\s+h ([\d.]+) m\s+v ([\d.]+) m/s\s+L ([\d.]+) m", out)
    if m: g.update({"release_deg": float(m[1]), "release_h_m": float(m[2]), "release_v_mps": float(m[3]), "release_L_m": float(m[4])})
    m = re.search(r"entry ([-\d.]+)°", out)
    if m: g["entry_deg"] = float(m[1])
    m = re.search(r"depth past front rim ([-\d.]+) m", out)
    if m: g["depth_m"] = float(m[1])
    if "release θ nil" in out: g["release_note"] = "release not observed"
    g["raw"] = out[-600:]
    return g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("shots_dir"); ap.add_argument("--video", required=True); ap.add_argument("--rim", required=True)
    # hFOV: MEASURED for the 2026-09-13 1080p120 clips (vanishing-point calibration of all three
    # clips: 66.3°, 67.8°, 65.4°). Never infer it from an assumed rim distance — the 48° that was
    # inferred that way cost the three-point block 9-16 % of g. See docs/PHASE2-PREP.md,
    # "Three-point scale error: root cause (2026-09-14)".
    ap.add_argument("--time-scale", type=float, default=4.0); ap.add_argument("--hfov", type=float, default=66.5); ap.add_argument("--known-distance", type=float)
    ap.add_argument("--out", required=True); ap.add_argument("--block", default="")
    ap.add_argument("--level-pitch", type=float, help="assume a zero-roll camera pitched up by this many degrees instead of the rim ellipse's normal (use when the ellipse is thin/tilted)")
    a = ap.parse_args()
    global LEVEL_PITCH; LEVEL_PITCH = a.level_pitch
    rim = json.load(open(a.rim)); rc = np.mean(np.array(rim["points"]), 0)
    sp = os.path.join(a.shots_dir, "summary.json")
    if os.path.exists(sp): summary = json.load(open(sp))
    else:   # session still running: build the list from the per-shot files present
        summary = []
        for fn in sorted(os.listdir(a.shots_dir)):
            m = re.match(r"shot(\d+)\.json$", fn)
            if m:
                tr = json.load(open(os.path.join(a.shots_dir, fn)))["meta"]
                summary.append({"shot": int(m.group(1)), "file_start": tr["start"], "file_end": tr["end"]})
    rows = []
    for srow in summary:
        k = srow["shot"]; tj = os.path.join(a.shots_dir, f"shot{k:02d}.json"); rj = os.path.join(a.shots_dir, f"shot{k:02d}.report.json")
        if not os.path.exists(tj): continue
        track = json.load(open(tj)); rep = json.load(open(rj))
        # If the caller's time scale differs from the one the track was made with (e.g. a recording rate derived from the
        # gravity residual), re-time every frame from its file time and hand the Swift analyzer the re-timed file.
        if abs(track["meta"].get("time_scale", a.time_scale) - a.time_scale) > 1e-6:
            for f in track["frames"]: f["t"] = f["t_file"] / a.time_scale
            track["meta"]["time_scale"] = a.time_scale; track["meta"]["fps_real"] = track["meta"]["fps_file"] * a.time_scale
            tj = tj.replace(".json", ".retimed.json"); json.dump(track, open(tj, "w"))
        row = {"shot": k, "file_start": srow["file_start"], "grade_pass": rep["pass"], "grade_score": rep["score"], "grade_errors": [e["code"] for e in rep["errors"]]}
        D = 2 * float(np.median([f["ball"]["r"] for f in track["frames"] if f["ball"]["r"]])) if any(f["ball"]["r"] for f in track["frames"]) else 60.0
        row["outcome"] = infer_outcome(track, rc, D)
        seg, why = G.flight_segment(track["frames"], G.DEFAULT_THRESHOLDS)
        rel_pose = release_from_pose(track, D)
        if seg:
            rel, end, note = seg
            if rel_pose is not None and abs(rel_pose - rel) <= 12: rel = rel_pose; note = None     # pose-based release wins when consistent
            seg = (rel, end, note)
            row["release_frame"] = rel; row["release_from_pose"] = rel_pose
            row["pose"] = pose_metrics(track, rel, end)
        else: row["pose"] = {"note": why}
        if rep["pass"] or rep["score"] >= 60:
            fr_range = None; known = None
            if seg:
                rel, end, note = seg; fr_range = (track["frames"][rel]["t"] - 0.02, track["frames"][end]["t"] + 0.02)
                if note is None: known = a.known_distance          # release anchored at the hands: the first flight sample is at the known distance
            row["release_anchored"] = bool(seg and seg[2] is None)
            rel_t = track["frames"][rel]["t"] if seg else None
            row["geometry"] = swift_geometry(a.video, tj, srow["file_start"], srow["file_end"], a.rim, a.time_scale, a.hfov, known, fr_range, rel_t)
        rows.append(row)
        g = row.get("geometry", {}); p = row["pose"]
        print(f"shot {k:2d} {'PASS' if rep['pass'] else 'fail'} {row['outcome']['outcome']:7s} g {g.get('g_fit', float('nan')):5.2f} θ {g.get('release_deg', float('nan')):5.1f}° h {g.get('release_h_m', float('nan')):4.2f} v {g.get('release_v_mps', float('nan')):4.2f} entry {g.get('entry_deg', float('nan')):5.1f}° depth {g.get('depth_m', float('nan')):5.2f} | elbow rel {p.get('elbow_release_deg', float('nan')):5.1f}° set {p.get('elbow_set_deg', float('nan')):5.1f}° knee {p.get('knee_min_deg', float('nan')):5.1f}° dip→rel {p.get('dip_to_release_s', float('nan')):.2f}s jump {p.get('jump_m', float('nan')):.2f}m")
    json.dump(rows, open(a.out, "w"), indent=1, default=float)
    # block summary
    def accepted(r):   # brief §4.7: gravity within 8 % of 9.81, AND physically possible release/crossing values (else the plane solve failed)
        g = r.get("geometry", {})
        if g.get("g_err_pct") is None or abs(g["g_err_pct"]) > 8.0: return False
        h, v, d = g.get("release_h_m"), g.get("release_v_mps"), g.get("depth_m")
        if h is not None and not (1.6 <= h <= 3.3): return False
        if v is not None and not (4.5 <= v <= 11.0): return False
        if d is not None and not (-0.6 <= d <= 1.0): return False
        return True
    n_acc = sum(1 for r in rows if accepted(r))
    def stats(key, src):
        vals = [r[src][key] for r in rows if (src != "geometry" or accepted(r)) and src in r and r[src].get(key) is not None and np.isfinite(r[src][key])]
        return (float(np.mean(vals)), float(np.std(vals, ddof=1)) if len(vals) > 1 else float("nan"), len(vals)) if vals else None
    print(f"\n=== block summary {a.block} ({len(rows)} windows, {sum(1 for r in rows if r['grade_pass'])} pass the tracking grader, {n_acc} pass the 8 % gravity gate; geometry rows use only those {n_acc}) ===")
    for label, key, src, unit in [("release angle", "release_deg", "geometry", "°"), ("release height", "release_h_m", "geometry", "m"), ("release speed", "release_v_mps", "geometry", "m/s"),
                                  ("entry angle", "entry_deg", "geometry", "°"), ("depth past front rim", "depth_m", "geometry", "m"), ("g_fit", "g_fit", "geometry", "m/s²"),
                                  ("elbow at release", "elbow_release_deg", "pose", "°"), ("elbow max near release", "elbow_max_near_release_deg", "pose", "°"), ("elbow at set", "elbow_set_deg", "pose", "°"), ("knee min", "knee_min_deg", "pose", "°"),
                                  ("dip→release", "dip_to_release_s", "pose", "s"), ("jump", "jump_m", "pose", "m")]:
        st = stats(key, src)
        if st: print(f"  {label:22s} mean {st[0]:7.2f} {unit:4s} SD {st[1]:6.2f}  n {st[2]}")
    # consistency → makes per 100 under the placeholder make surface (same shape as SoftMakeModel in ShotGeometry; NOT fitted to this player)
    depths = [r["geometry"]["depth_m"] for r in rows if accepted(r) and r["geometry"].get("depth_m") is not None]
    if len(depths) >= 5:
        d = np.array(depths); along = d - 0.4572 / 2
        p_make = 0.92 * np.exp(-((along - 0.03) / 0.16) ** 2)              # lateral unknown in a side view: assumed centred
        rng = np.random.default_rng(0); sd = float(np.std(d, ddof=1)); mean = float(np.mean(d))
        def makes(sd_):
            x = rng.normal(mean, sd_, 20000) - 0.4572 / 2; return 100 * float(np.mean(0.92 * np.exp(-((x - 0.03) / 0.16) ** 2)))
        print(f"  depth spread: mean {mean * 100:.1f} cm past the front rim, SD {sd * 100:.1f} cm (n {len(d)})")
        print(f"  expected makes per 100 from this depth spread (placeholder surface, lateral assumed centred): {makes(sd):.0f}; if the SD were halved: {makes(sd / 2):.0f}")
    oc = [r["outcome"]["outcome"] for r in rows]
    print(f"  outcomes (inferred): {oc.count('make')} make, {oc.count('miss')} miss, {oc.count('unknown')} unknown")


if __name__ == "__main__":
    main()
