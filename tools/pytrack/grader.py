#!/usr/bin/env python
"""Grades a tracking JSON: frame drops, ball coverage/jumps/size/physics, pose coverage/teleports/swaps, ball-hand consistency.
Exit 0 = PASS, 1 = FAIL. Writes a report JSON with error codes the loop can act on. Every number in the report is measured."""
import argparse, json, sys
import numpy as np
from scipy.optimize import least_squares


def fit_projected_parabola(t, u, v):
    """A parabola in a vertical plane seen by a pinhole camera: X, Z linear in t, Y quadratic, so
    u = (a + b t) / (1 + c t), v = (d + e t + f t²) / (1 + c t) with a shared depth term c. Returns params, residuals."""
    t = np.asarray(t) - t[0]
    pu = np.polyfit(t, u, 1); pv = np.polyfit(t, v, 2)
    x0 = np.array([pu[1], pu[0], pv[2], pv[1], pv[0], 0.0])
    def res(x):
        a, b, d, e, f, c = x; den = 1 + c * t
        return np.concatenate([(a + b * t) / den - u, (d + e * t + f * t * t) / den - v])
    r = least_squares(res, x0, loss="soft_l1", f_scale=3.0)
    rr = res(r.x); n = len(t)
    return r.x, rr[:n], rr[n:]

DEFAULT_THRESHOLDS = {
    "frame_drop_fraction_max": 0.02, "frame_gap_real_s_max": 0.1,
    "ball_flight_coverage_min": 0.85, "ball_jump_px": 80.0, "ball_jump_median_factor": 3.0,
    "ball_fit_rms_px_max": 6.0, "ball_u_rms_px_max": 10.0, "ball_g_rel_tol": 0.6, "ball_radius_cov_max": 0.35, "ball_radius_step_max": 0.4,
    "ball_min_flight_frames": 20,
    "pose_coverage_core_min": 0.9, "pose_coverage_limb_min": 0.8, "pose_teleport_px": 60.0, "pose_teleport_fraction_max": 0.01,
    "pose_swap_flips_max": 2, "pose_torso_cov_max": 0.2, "ball_hand_release_diameters_max": 2.5,
}
CORE = ["l_shoulder", "r_shoulder", "l_hip", "r_hip"]; LIMB = ["l_elbow", "r_elbow", "l_wrist", "r_wrist", "l_knee", "r_knee"]
BALL_DIAMETER_M = 0.2385; G = 9.81


def flight_segment(frames, thr):
    """Release = first 'detected' frame after the last 'held' frame (ball more than ~1.2 diameters from the wrists);
    if the tracker never labelled a held frame, the first detected frame. End = last detection before the descent stops
    (rim/floor) or the track is lost for > 8 frames after the apex."""
    det = [(k, f) for k, f in enumerate(frames) if f["ball"]["source"] in ("detected", "merged", "template")]
    if len(det) < 5: return None, "fewer than 5 ball detections"
    held = [k for k, f in enumerate(frames) if f["ball"]["source"] == "held"]
    if held:
        after = [k for k, _ in det if k > held[-1]]
        if not after: return None, "no free-flight detections after the held phase"
        release = after[0]; note = None
    else:
        release = det[0][0]; note = "release not anchored: no held frames (pose/ball never coincided)"
    seq = [(k, f["ball"]) for k, f in det if k >= release]
    if len(seq) < 5: return None, "fewer than 5 detections after release"
    vs = np.array([b["v"] for _, b in seq]); apex = int(np.argmin(vs))
    end = seq[-1][0]
    for j in range(apex + 1, len(seq) - 3):
        if seq[j + 1][0] - seq[j][0] > 8: end = seq[j][0]; break
        if vs[j + 1] < vs[j] - 2 and vs[j + 2] < vs[j] - 2: end = seq[j][0]; break
    return (release, end, note), None


def grade(track, thr):
    frames = track["frames"]; meta = track["meta"]; errors = []; metrics = {}
    fps_real = meta["fps_real"]

    # --- frame drops
    t = np.array([f["t"] for f in frames]); dt = np.diff(t); med = float(np.median(dt)) if len(dt) else 0
    drops = int(np.sum(dt > 1.5 * med)) if med > 0 else 0
    metrics["frame_interval_median_s"] = med; metrics["frame_drops"] = drops; metrics["frame_gap_max_s"] = float(dt.max()) if len(dt) else 0
    if len(dt) and drops / len(dt) > thr["frame_drop_fraction_max"]:
        errors.append({"code": "FRAME_DROPS", "value": drops / len(dt), "threshold": thr["frame_drop_fraction_max"], "message": f"{drops} of {len(dt)} intervals > 1.5x median"})
    if len(dt) and dt.max() > thr["frame_gap_real_s_max"]:
        errors.append({"code": "FRAME_GAP", "value": float(dt.max()), "threshold": thr["frame_gap_real_s_max"], "message": "a frame gap exceeds the limit"})

    # --- ball
    seg, why = flight_segment(frames, thr)
    if seg is None:
        errors.append({"code": "BALL_NO_FLIGHT", "value": 0, "threshold": 5, "message": why})
    else:
        rel, end, note = seg
        metrics["release_frame"] = rel; metrics["flight_end_frame"] = end; metrics["flight_note"] = note
        fl = frames[rel:end + 1]
        det = [f for f in fl if f["ball"]["source"] == "detected" and not f["ball"].get("edge", False)]
        merged = [f for f in fl if f["ball"]["source"] in ("merged", "template")]
        merged_ok = 0
        if merged and len(det) >= 8:
            tt0 = np.array([f["t"] for f in det]); uu0 = np.array([f["ball"]["u"] for f in det]); vv0 = np.array([f["ball"]["v"] for f in det])
            x, _, _ = fit_projected_parabola(tt0, uu0, vv0); a_, b_, d_, e_, f_, c_ = x
            D_px = 2 * float(np.median([f["ball"]["r"] for f in det]))
            bad = 0
            for f in merged:
                tq = f["t"] - tt0[0]; den = 1 + c_ * tq
                pu, pv = (a_ + b_ * tq) / den, (d_ + e_ * tq + f_ * tq * tq) / den
                if np.hypot(pu - f["ball"]["u"], pv - f["ball"]["v"]) <= 0.6 * D_px: merged_ok += 1
                else: bad += 1
            metrics["merged_consistent"] = merged_ok; metrics["merged_inconsistent"] = bad
            if bad > 0: errors.append({"code": "BALL_MERGED_INCONSISTENT", "value": bad, "threshold": 0, "message": f"{bad} merged/template estimates deviate > 0.6 diameters from the clean fit"})
        n_edge = sum(1 for f in fl if f["ball"]["source"] == "detected" and f["ball"].get("edge", False)); metrics["flight_edge_clipped"] = n_edge
        # excuse frames where a parabola through the detections predicts the ball above the frame
        tt = np.array([f["t"] for f in det]); uu = np.array([f["ball"]["u"] for f in det]); vv = np.array([f["ball"]["v"] for f in det])
        excused = 0
        if len(det) >= 6:
            pv = np.polyfit(tt, vv, 2)
            for f in fl:
                if f["ball"]["source"] != "detected" and np.polyval(pv, f["t"]) < 0: excused += 1
        denom = max(1, len(fl) - excused - n_edge)
        cov = (len(det) + merged_ok) / denom
        metrics["flight_frames"] = len(fl); metrics["flight_detected"] = len(det); metrics["flight_excused_offframe"] = excused; metrics["ball_flight_coverage"] = cov
        if len(fl) < thr["ball_min_flight_frames"]:
            errors.append({"code": "BALL_FLIGHT_SHORT", "value": len(fl), "threshold": thr["ball_min_flight_frames"], "message": "flight segment too short"})
        if cov < thr["ball_flight_coverage_min"]:
            errors.append({"code": "BALL_COVERAGE_LOW", "value": cov, "threshold": thr["ball_flight_coverage_min"], "message": f"{len(det)}/{denom} flight frames have a detection"})
        # jumps
        steps = np.hypot(np.diff(uu), np.diff(vv)) / np.maximum(1, np.diff([f["i"] for f in det]))
        if len(steps):
            lim = max(thr["ball_jump_px"], thr["ball_jump_median_factor"] * float(np.median(steps)))
            jumps = int(np.sum(steps > lim)); metrics["ball_jumps"] = jumps; metrics["ball_step_median_px"] = float(np.median(steps))
            if jumps > 0: errors.append({"code": "BALL_JUMP", "value": jumps, "threshold": 0, "message": f"{jumps} per-frame steps above {lim:.0f} px"})
        # size
        rr = np.array([f["ball"]["r"] for f in det])
        if len(rr) >= 5:
            cov_r = float(rr.std() / rr.mean()); metrics["ball_radius_median_px"] = float(np.median(rr)); metrics["ball_radius_cov"] = cov_r
            stepr = np.abs(np.diff(rr)) / rr[:-1]
            if cov_r > thr["ball_radius_cov_max"] or (stepr > thr["ball_radius_step_max"]).sum() > 2:
                errors.append({"code": "BALL_SIZE_UNSTABLE", "value": cov_r, "threshold": thr["ball_radius_cov_max"], "message": f"radius CoV {cov_r:.2f}, {(stepr > thr['ball_radius_step_max']).sum()} big steps"})
        # physics: projected parabola (shared perspective denominator) against real time
        if len(det) >= 8 and tt[-1] - tt[0] > 0.1:
            x, res_u, res_v = fit_projected_parabola(tt, uu, vv)
            a_, b_, d_, e_, f_, c_ = x
            rms_v = float(np.sqrt(np.mean(res_v ** 2))); rms_u = float(np.sqrt(np.mean(res_u ** 2)))
            g_px = 2 * f_                                   # image-space vertical acceleration at t0 (down = positive)
            px_per_m = float(np.median(rr)) * 2 / BALL_DIAMETER_M
            g_est = g_px / px_per_m
            metrics.update({"ball_fit_rms_v_px": rms_v, "ball_fit_rms_u_px": rms_u, "ball_g_px_s2": float(g_px), "ball_g_est_m_s2": float(g_est),
                            "px_per_m_from_ball": px_per_m, "ball_depth_rate": float(c_)})
            if rms_v > thr["ball_fit_rms_px_max"] or rms_u > thr["ball_u_rms_px_max"]:
                errors.append({"code": "BALL_PHYSICS_RESIDUAL", "value": max(rms_v, rms_u), "threshold": thr["ball_fit_rms_px_max"], "message": f"projected-parabola residual v {rms_v:.1f} px, u {rms_u:.1f} px"})
            if g_px <= 0 or abs(g_est - G) / G > thr["ball_g_rel_tol"]:
                errors.append({"code": "BALL_PHYSICS_GRAVITY", "value": float(g_est), "threshold": G, "message": f"image-space gravity {g_est:.1f} m/s² (via ball size) vs 9.81"})
        else:
            errors.append({"code": "BALL_PHYSICS_UNTESTABLE", "value": len(det), "threshold": 8, "message": "not enough flight detections to fit"})
        # ball-hand consistency at release
        p = frames[rel]["pose"]; b = frames[rel]["ball"]
        if p and b["u"] is not None:
            dmin = min([np.hypot(b["u"] - p[w][0], b["v"] - p[w][1]) for w in ("l_wrist", "r_wrist") if w in p] or [1e9])
            metrics["release_ball_wrist_diameters"] = float(dmin / (2 * b["r"]))
            if dmin / (2 * b["r"]) > thr["ball_hand_release_diameters_max"]:
                errors.append({"code": "BALL_HAND_INCONSISTENT", "value": float(dmin / (2 * b["r"])), "threshold": thr["ball_hand_release_diameters_max"], "message": "release frame ball is far from both wrists"})

    # --- pose
    n = len(frames); vis_min = meta["config"]["pose"]["visibility_min"]
    covs = {}
    for name in CORE + LIMB:
        covs[name] = sum(1 for f in frames if f["pose"] and name in f["pose"] and f["pose"][name][2] >= vis_min) / n
    metrics["pose_coverage"] = covs
    # side view: the far side of the body is legitimately occluded. Require the limbs of the better-seen side.
    l_mean = np.mean([covs[k] for k in LIMB if k.startswith("l_")]); r_mean = np.mean([covs[k] for k in LIMB if k.startswith("r_")])
    near = "l_" if l_mean >= r_mean else "r_"; metrics["pose_near_side"] = near
    low = [k for k in CORE if covs[k] < thr["pose_coverage_core_min"]] + [k for k in LIMB if k.startswith(near) and covs[k] < thr["pose_coverage_limb_min"]]
    if low: errors.append({"code": "POSE_COVERAGE_LOW", "value": min(covs[k] for k in low), "threshold": thr["pose_coverage_limb_min"], "message": "low coverage: " + ", ".join(f"{k} {covs[k]:.2f}" for k in low)})
    tele = 0; pairs = 0; flips = 0; torso = []
    prev = None; prev_sign = None
    for f in frames:
        p = f["pose"]
        if not p: prev = None; continue
        if prev:
            for name in CORE + LIMB:
                if name in p and name in prev and p[name][2] >= vis_min and prev[name][2] >= vis_min:
                    pairs += 1
                    if np.hypot(p[name][0] - prev[name][0], p[name][1] - prev[name][1]) > thr["pose_teleport_px"]: tele += 1
        if all(k in p for k in ("l_hip", "r_hip", "l_shoulder", "r_shoulder")) and p["l_hip"][2] >= vis_min and p["r_hip"][2] >= vis_min:
            # left/right order is only testable when the hips are separated by > 15 % of the torso length (not in a pure side view)
            tl = np.hypot((p["l_shoulder"][0] + p["r_shoulder"][0]) / 2 - (p["l_hip"][0] + p["r_hip"][0]) / 2, (p["l_shoulder"][1] + p["r_shoulder"][1]) / 2 - (p["l_hip"][1] + p["r_hip"][1]) / 2)
            sep = p["l_hip"][0] - p["r_hip"][0]
            if tl > 0 and abs(sep) > 0.15 * tl:
                sgn = np.sign(sep)
                if prev_sign is not None and sgn != prev_sign: flips += 1
                prev_sign = sgn
        if all(k in p for k in ("l_shoulder", "r_shoulder", "l_hip", "r_hip")):
            ms = ((p["l_shoulder"][0] + p["r_shoulder"][0]) / 2, (p["l_shoulder"][1] + p["r_shoulder"][1]) / 2)
            mh = ((p["l_hip"][0] + p["r_hip"][0]) / 2, (p["l_hip"][1] + p["r_hip"][1]) / 2)
            torso.append(np.hypot(ms[0] - mh[0], ms[1] - mh[1]))
        prev = p
    metrics["pose_teleports"] = tele; metrics["pose_pairs"] = pairs; metrics["pose_swap_flips"] = flips
    if pairs and tele / pairs > thr["pose_teleport_fraction_max"]:
        errors.append({"code": "POSE_TELEPORT", "value": tele / pairs, "threshold": thr["pose_teleport_fraction_max"], "message": f"{tele} joint jumps > {thr['pose_teleport_px']} px in {pairs} pairs"})
    if flips > thr["pose_swap_flips_max"]:
        errors.append({"code": "POSE_SWAP", "value": flips, "threshold": thr["pose_swap_flips_max"], "message": f"left/right shoulder order flipped {flips} times"})
    if len(torso) > 5:
        tcov = float(np.std(torso) / np.mean(torso)); metrics["pose_torso_cov"] = tcov
        if tcov > thr["pose_torso_cov_max"]:
            errors.append({"code": "POSE_SCALE_UNSTABLE", "value": tcov, "threshold": thr["pose_torso_cov_max"], "message": f"torso length CoV {tcov:.2f}"})

    # score: 100 minus 15 per error, minus proportional penalties
    score = 100.0
    for e in errors: score -= 60 if e["code"] in ("BALL_NO_FLIGHT",) else (25 if e["code"] in ("BALL_FLIGHT_SHORT", "BALL_PHYSICS_UNTESTABLE") else 10)
    score -= 30 * max(0.0, thr["ball_flight_coverage_min"] - metrics.get("ball_flight_coverage", 0))
    score -= 5 * max(0.0, metrics.get("ball_fit_rms_v_px", 0) - thr["ball_fit_rms_px_max"])
    return {"pass": len(errors) == 0, "score": round(max(0.0, score), 1), "errors": errors, "metrics": metrics, "thresholds": thr}


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("tracking"); ap.add_argument("--report", required=True); ap.add_argument("--thresholds")
    a = ap.parse_args()
    thr = dict(DEFAULT_THRESHOLDS)
    if a.thresholds: thr.update(json.load(open(a.thresholds)))
    rep = grade(json.load(open(a.tracking)), thr)
    json.dump(rep, open(a.report, "w"), indent=1, default=float)
    print(f"GRADE: {'PASS' if rep['pass'] else 'FAIL'}  score {rep['score']}")
    for e in rep["errors"]: print(f"  [{e['code']}] {e['message']} (value {e['value']:.3g}, threshold {e['threshold']})")
    m = rep["metrics"]
    keys = ["release_frame", "flight_end_frame", "flight_frames", "flight_detected", "flight_excused_offframe", "ball_flight_coverage", "ball_jumps", "ball_radius_median_px",
            "ball_fit_rms_v_px", "ball_fit_rms_u_px", "ball_g_est_m_s2", "release_ball_wrist_diameters", "pose_teleports", "pose_swap_flips", "pose_torso_cov"]
    print("  metrics: " + ", ".join(f"{k}={m[k]:.3g}" if isinstance(m.get(k), float) else f"{k}={m.get(k)}" for k in keys if k in m))
    if "pose_coverage" in m: print("  pose coverage: " + ", ".join(f"{k} {v:.2f}" for k, v in m["pose_coverage"].items()))
    sys.exit(0 if rep["pass"] else 1)


if __name__ == "__main__":
    main()
