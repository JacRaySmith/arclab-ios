#!/usr/bin/env python
"""Ball + shooter tracking from iPhone video (OpenCV + MediaPipe Pose).

Outputs one JSON with per-frame ball position/radius/source and 12 joints (shoulders, elbows, wrists, hips,
knees, ankles). Never invents a ball position: a frame without a detection is marked source="none" (or
"interpolated" when gap filling is enabled, always labelled as such).
"""
import argparse, json, os, sys, time
import numpy as np
import cv2

JOINTS = {"nose": 0, "l_shoulder": 11, "r_shoulder": 12, "l_elbow": 13, "r_elbow": 14, "l_wrist": 15, "r_wrist": 16,
          "l_hip": 23, "r_hip": 24, "l_knee": 25, "r_knee": 26, "l_ankle": 27, "r_ankle": 28}

DEFAULT_CONFIG = {
    "version": 1,
    "ball": {
        "method": "bgdiff",            # bgdiff | bgdiff_orange | orange_only
        "downscale": 2,
        "bg_frames": 9,
        "diff_threshold": 28.0,        # absolute diff score threshold (luma + chroma_weight*Cr)
        "rel_threshold": 0.25,         # fraction of the local max diff
        "chroma_weight": 2.0,
        "expected_diameter_px": 0,     # 0 = estimate from the first confident detection near the hands
        "min_area_frac": 0.15,
        "max_area_frac": 4.0,
        "max_aspect": 2.2,
        "search_radius_factor": 2.5,
        "max_jump_px": 120.0,
        "predict": "velocity",        # none | velocity | parabola
        "centroid_weight_power": 2.0,
        "interpolate_gaps": False,
        "max_gap_frames": 6,
        "two_pass": False,
        "orange_margin": 8,            # Cr above background
        "extent_threshold": 14.0,      # loose local threshold used only to measure the ball's size
        "centroid_mode": "core",       # core: diff-weighted bright core | extent: centre of the full-disc loose component (lighting-invariant)
        "merged_blob_fill": False,
        "predicted_weak_candidates": True,   # once the parabola is established (≥ 10 points), accept weaker blobs within 0.8 D of its prediction
        "template_fill": False,        # post-pass: predict missing frames from the clean-detection parabola and confirm by template matching
        "template_min_score": 0.55,     # ball merged with the hands right after release: take the topmost disc of the oversized blob
        "hough_gap_fill": False,       # when no blob links, look for the ball's circular edge around the prediction (image evidence, not interpolation)
        "hough_param2": 18,
        "circularity_min": 0.5,
        "gate_diameters": 2.0,         # linking gate as a multiple of the ball diameter
        "gate_speed_factor": 2.5,      # … or of the last per-frame step
        "max_offframe_frames": 120,
    },
    "pose": {
        "backend": "legacy",           # legacy (mp.solutions.pose, CPU, mediapipe 0.10.x) | tasks (PoseLandmarker .task model)
        "model_complexity": 1,         # legacy: 0 lite, 1 full, 2 heavy
        "model": "models/pose_landmarker_full.task",
        "min_detection": 0.5, "min_presence": 0.5, "min_tracking": 0.5,
        "crop_to_shooter": False, "crop_margin": 0.35, "crop_upscale": 1.0,
        "smooth": "none",              # none | median3 | savgol
        "visibility_min": 0.5,
    },
}


def deep_update(base, upd):
    for k, v in upd.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict): deep_update(base[k], v)
        else: base[k] = v
    return base


# ----------------------------------------------------------------------------- video
def read_window(path, start, end, downscale):
    cap = cv2.VideoCapture(path)
    if not cap.isOpened(): raise SystemExit(f"cannot open {path}")
    fps = cap.get(cv2.CAP_PROP_FPS)
    cap.set(cv2.CAP_PROP_POS_MSEC, start * 1000.0)
    frames = []; dup = 0; prev_sig = None
    while True:
        ok, fr = cap.read()
        if not ok: break
        t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0 - 1.0 / fps    # POS_MSEC is the *next* frame's time after read()
        if t > end + 1e-6: break
        sig = cv2.resize(fr[:, :, 1], (48, 27), interpolation=cv2.INTER_AREA)
        if prev_sig is not None and np.array_equal(sig, prev_sig): dup += 1; continue     # decoder handed us the same frame twice
        prev_sig = sig
        frames.append((t, fr))
    cap.release()
    if dup: print(f"note: skipped {dup} duplicated frames from the decoder")
    return fps, frames


def small_planes(fr, ds):
    ycrcb = cv2.cvtColor(fr, cv2.COLOR_BGR2YCrCb)
    y = ycrcb[:, :, 0]; cr = ycrcb[:, :, 1]
    if ds > 1:
        y = cv2.resize(y, (y.shape[1] // ds, y.shape[0] // ds), interpolation=cv2.INTER_AREA)
        cr = cv2.resize(cr, (cr.shape[1] // ds, cr.shape[0] // ds), interpolation=cv2.INTER_AREA)
    return y.astype(np.int16), cr.astype(np.int16)


# ----------------------------------------------------------------------------- ball
def body_box(p, margin=0.15):
    if not p: return None
    xs = [j[0] for j in p.values()]; ys = [j[1] for j in p.values()]
    w = max(xs) - min(xs); h = max(ys) - min(ys)
    return (min(xs) - margin * w, min(ys) - margin * h, max(xs) + margin * w, max(ys) + margin * h)


def in_box(u, v, box):
    return box is not None and box[0] <= u <= box[2] and box[1] <= v <= box[3]


class CandidateFinder:
    """Per-frame round, orange, moving blobs from a background difference (median background, half resolution)."""
    def __init__(self, cfg, planes):
        self.c = cfg; self.ds = cfg["downscale"]
        K = min(cfg["bg_frames"], len(planes)); idx = [int(i * (len(planes) - 1) / max(K - 1, 1)) for i in range(K)]
        self.bg_y = np.median(np.stack([planes[i][0] for i in idx]), axis=0).astype(np.int16)
        self.bg_cr = np.median(np.stack([planes[i][1] for i in idx]), axis=0).astype(np.int16)

    def candidates(self, y, cr, D_full):
        """Returns list of (u, v, diameter_px, mean_diff, circularity) in full-res px."""
        ds = self.ds; D = max(4.0, D_full / ds)
        d = np.abs(y - self.bg_y) + self.c["chroma_weight"] * np.abs(cr - self.bg_cr)
        orange = (cr - self.bg_cr) > self.c["orange_margin"]
        mask = ((d >= self.c["diff_threshold"]) & orange).astype(np.uint8)
        n, labels, stats, cents = cv2.connectedComponentsWithStats(mask, connectivity=4)
        exp_area = np.pi * D * D / 4
        out = []
        for k in range(1, n):
            area = stats[k, cv2.CC_STAT_AREA]
            if area < self.c["min_area_frac"] * exp_area or area > self.c["max_area_frac"] * exp_area: continue
            bw, bh = stats[k, cv2.CC_STAT_WIDTH], stats[k, cv2.CC_STAT_HEIGHT]
            if max(bw, bh) / max(1, min(bw, bh)) > self.c["max_aspect"]: continue
            circ = area / (np.pi * (max(bw, bh) / 2) ** 2)
            if circ < self.c["circularity_min"]: continue
            x0, y0 = stats[k, cv2.CC_STAT_LEFT], stats[k, cv2.CC_STAT_TOP]
            sub = (labels[y0:y0 + bh, x0:x0 + bw] == k)
            wts = np.where(sub, d[y0:y0 + bh, x0:x0 + bw], 0).astype(np.float64) ** self.c["centroid_weight_power"]
            sw = wts.sum()
            if sw <= 0: continue
            ys, xs = np.nonzero(sub)
            mu = (wts[ys, xs] * xs).sum() / sw + x0; mv = (wts[ys, xs] * ys).sum() / sw + y0
            # size: re-segment locally with a loose threshold (no orange gate) so the dark side of the ball counts
            R = int(1.5 * D); cx, cy = int(mu), int(mv)
            lx0, ly0 = max(0, cx - R), max(0, cy - R); loc = d[ly0:cy + R + 1, lx0:cx + R + 1]
            lm = (loc >= self.c["extent_threshold"]).astype(np.uint8)
            ln, ll, ls, _ = cv2.connectedComponentsWithStats(lm, connectivity=8)
            lab = ll[min(cy - ly0, lm.shape[0] - 1), min(cx - lx0, lm.shape[1] - 1)]
            if lab > 0 and ls[lab, cv2.CC_STAT_AREA] <= 6 * exp_area:
                lw, lh = ls[lab, cv2.CC_STAT_WIDTH], ls[lab, cv2.CC_STAT_HEIGHT]
                ext = float(min(lw, lh))                                                        # smaller side: motion smear stretches the other
                ext = float(np.clip(ext, max(bw, bh), 2.2 * D))
                if self.c.get("centroid_mode") == "extent" and 0.8 * D <= min(lw, lh) <= 1.3 * D and max(lw, lh) <= 1.8 * D:
                    # full disc captured: its bounding-box centre does not move with the lit side
                    mu = ls[lab, cv2.CC_STAT_LEFT] + lx0 + lw / 2 - 0.5; mv = ls[lab, cv2.CC_STAT_TOP] + ly0 + lh / 2 - 0.5
            else: ext = float(max(bw, bh))
            out.append(((mu + 0.5) * ds, (mv + 0.5) * ds, ext * ds, float(d[y0:y0 + bh, x0:x0 + bw][sub].mean()), float(circ)))
        return out


def nearest_wrist(p, u, v):
    best = None
    if not p: return None
    for w in ("l_wrist", "r_wrist"):
        if w in p and p[w][2] >= 0.3:
            dd = np.hypot(u - p[w][0], v - p[w][1]); best = dd if best is None else min(best, dd)
    return best


def merged_ball(d, pred, D_full, ds, thr, exp_area):
    """Ball merged with hands/arm: find the large blob near the prediction whose top edge is near the predicted height and
    return the centre of its topmost disc (full-res px) or None."""
    D = D_full / ds; cx, cy = int(pred[0] / ds), int(pred[1] / ds)
    R = int(2.5 * D); h, w = d.shape
    x0, y0 = max(0, cx - R), max(0, cy - R); x1, y1 = min(w, cx + R), min(h, cy + R)
    if x1 - x0 < D or y1 - y0 < D: return None
    box = d[y0:y1, x0:x1]; mask = (box >= thr).astype(np.uint8)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=4)
    best = None
    for k in range(1, n):
        area = stats[k, cv2.CC_STAT_AREA]
        if area < 1.3 * exp_area or area > 25 * exp_area: continue
        top = stats[k, cv2.CC_STAT_TOP] + y0
        if abs((top + D / 2) - cy) > 1.2 * D: continue
        ys, xs = np.nonzero(labels == k)
        sel = ys + y0 < top + 0.9 * D
        if sel.sum() < 0.3 * exp_area: continue
        u = xs[sel].mean() + x0; v = top + D / 2
        dist = np.hypot(u - cx, v - cy)
        if best is None or dist < best[0]: best = (dist, u, v)
    return None if best is None else ((best[1] + 0.5) * ds, (best[2] + 0.5) * ds, D_full)


def hough_ball(gray, cr_full, bg_cr_full, pred, D, param2, orange_margin):
    """HoughCircles in a window around the prediction. Accepts only circles within one diameter of the prediction,
    with a radius within 30 % of the ball's and an orange centre (Cr above the background). Returns (u, v, diameter) or None."""
    R = int(1.6 * D); cx, cy = int(pred[0]), int(pred[1])
    x0, y0 = max(0, cx - R), max(0, cy - R); x1, y1 = min(gray.shape[1], cx + R), min(gray.shape[0], cy + R)
    if x1 - x0 < D or y1 - y0 < D: return None
    crop = cv2.GaussianBlur(gray[y0:y1, x0:x1], (5, 5), 1.2)
    circles = cv2.HoughCircles(crop, cv2.HOUGH_GRADIENT, dp=1.2, minDist=D * 0.5, param1=90, param2=param2, minRadius=int(0.35 * D), maxRadius=int(0.65 * D))
    if circles is None: return None
    best = None
    for c in circles[0]:
        u, v, r = c[0] + x0, c[1] + y0, c[2]
        dist = np.hypot(u - pred[0], v - pred[1])
        if dist > 1.0 * D or abs(2 * r - D) > 0.3 * D: continue
        iu, iv = int(np.clip(u, 0, cr_full.shape[1] - 1)), int(np.clip(v, 0, cr_full.shape[0] - 1))
        rr = int(max(2, 0.4 * r)); patch = cr_full[max(0, iv - rr):iv + rr + 1, max(0, iu - rr):iu + rr + 1]; bgp = bg_cr_full[max(0, iv - rr):iv + rr + 1, max(0, iu - rr):iu + rr + 1]
        if float(patch.mean() - bgp.mean()) < orange_margin / 2: continue
        if best is None or dist < best[0]: best = (dist, u, v, 2 * r)
    return None if best is None else (float(best[1]), float(best[2]), float(best[3]))


def track_ball(cfg, frames, planes, poses, W, H, fps_real):
    """Candidates → expected size → release seed (round blob leaving the wrists upward) → forward linking with a
    gravity-aware predictor that keeps the track alive while the prediction is above the frame → backward extension
    into the hands (labelled 'held'). Frames with nothing linked are source='none'."""
    n = len(frames)
    cf = CandidateFinder(cfg, planes)
    D = cfg["expected_diameter_px"] or 60.0
    cands = [cf.candidates(planes[i][0], planes[i][1], D) for i in range(n)]
    relaxed_cfg = dict(cfg); relaxed_cfg.update({"diff_threshold": 0.6 * cfg["diff_threshold"], "min_area_frac": 0.5 * cfg["min_area_frac"],
                                                 "circularity_min": min(cfg["circularity_min"], 0.3), "orange_margin": max(2, cfg["orange_margin"] - 3)})
    cf_relaxed = CandidateFinder.__new__(CandidateFinder); cf_relaxed.c = relaxed_cfg; cf_relaxed.ds = cf.ds; cf_relaxed.bg_y = cf.bg_y; cf_relaxed.bg_cr = cf.bg_cr
    relaxed_cache = {}
    def relaxed(i, Dcur):
        if i not in relaxed_cache: relaxed_cache[i] = cf_relaxed.candidates(planes[i][0], planes[i][1], Dcur)
        return relaxed_cache[i]
    boxes = [body_box(p) for p in poses]
    # size estimate: median diameter of candidates outside the body box (free ball), if enough of them
    free = [c[2] for i in range(n) for c in cands[i] if not in_box(c[0], c[1], boxes[i])]
    if cfg["expected_diameter_px"] == 0 and len(free) >= 10:
        D = float(np.median(free)); cands = [cf.candidates(planes[i][0], planes[i][1], D) for i in range(n)]
    out = [{"u": None, "v": None, "r": None, "score": 0.0, "source": "none"} for _ in range(n)]

    # release seed: first frame with a candidate within 2.5 D of a wrist that then moves up and away over the next frames
    def link_forward(i0, c0):
        track = {i0: c0}
        hist = [(i0, c0[0], c0[1])]
        lost = 0; last_i = i0; exited_top = False
        for i in range(i0 + 1, n):
            # predict with constant velocity + estimated vertical acceleration once the track is long enough
            if len(hist) >= 6 and cfg["predict"] == "parabola":
                ii = np.array([h[0] for h in hist[-10:]], float); uu = np.array([h[1] for h in hist[-10:]]); vv = np.array([h[2] for h in hist[-10:]])
                pu = np.polyfit(ii, uu, 1); pv = np.polyfit(ii, vv, 2); pred = (np.polyval(pu, i), np.polyval(pv, i))
            elif len(hist) >= 2:
                (ia, ua, va), (ib, ub, vb) = hist[-2], hist[-1]; k = (i - ib) / max(1, ib - ia)
                pred = (ub + (ub - ua) * k, vb + (vb - va) * k)
            else: pred = (hist[-1][1], hist[-1][2])
            offframe = exited_top or pred[1] < -0.5 * D or pred[0] < -D or pred[0] > W + D
            step = np.hypot(hist[-1][1] - hist[-2][1], hist[-1][2] - hist[-2][2]) if len(hist) >= 2 else D
            gate = max(cfg["gate_diameters"] * D, cfg["gate_speed_factor"] * step) * (1 + 0.15 * (i - last_i - 1))
            best = None
            for c in cands[i]:
                if in_box(c[0], c[1], boxes[i]) and i - i0 > 4: continue        # ignore body blobs once the ball has left
                if offframe:
                    # re-entry: any ball-sized blob in the top band, ahead of the exit point, ignoring the (unreliable) long extrapolation
                    if c[1] > 0.35 * H or c[0] < hist[-1][1] - D: continue
                    sc = abs(np.log(c[2] / D)) + c[1] / H
                else:
                    dist = np.hypot(c[0] - pred[0], c[1] - pred[1])
                    if dist > gate: continue
                    sc = dist / D + 0.8 * abs(np.log(c[2] / D))
                if best is None or sc < best[0]: best = (sc, c)
            if best is None and cfg.get("predicted_weak_candidates") and not offframe and len(hist) >= 10 and lost < cfg["max_gap_frames"] + 6:
                # descent: the ball gets small and dark; with a well-established parabola, accept a weaker blob very near the prediction
                for c in relaxed(i, D):
                    if in_box(c[0], c[1], boxes[i]): continue
                    dist = np.hypot(c[0] - pred[0], c[1] - pred[1])
                    if dist <= 0.8 * D and 0.4 * D <= c[2] <= 1.6 * D:
                        sc = dist / D + 0.5 * abs(np.log(c[2] / D))
                        if best is None or sc < best[0]: best = (sc, c)
            if best is None and cfg.get("merged_blob_fill") and not offframe and len(hist) >= 2 and i - i0 <= 20 and lost < cfg["max_gap_frames"]:
                dplane = np.abs(planes[i][0] - cf.bg_y) + cfg["chroma_weight"] * np.abs(planes[i][1] - cf.bg_cr)
                mb = merged_ball(dplane, pred, D, cfg["downscale"], cfg["diff_threshold"], np.pi * (D / cfg["downscale"]) ** 2 / 4)
                if mb is not None: best = (0.0, (mb[0], mb[1], mb[2], -1.0, 1.0))      # score -1 marks a merged estimate
            if best is None and cfg.get("hough_gap_fill") and not offframe and len(hist) >= 3 and lost < cfg["max_gap_frames"]:
                g = cv2.cvtColor(frames[i][1], cv2.COLOR_BGR2GRAY)
                ycc = cv2.cvtColor(frames[i][1], cv2.COLOR_BGR2YCrCb)[:, :, 1].astype(np.int16)
                bgcr_full = cv2.resize(cf.bg_cr.astype(np.uint8), (W, H), interpolation=cv2.INTER_NEAREST).astype(np.int16)
                hc = hough_ball(g, ycc, bgcr_full, pred, D, cfg["hough_param2"], cfg["orange_margin"])
                if hc is not None: best = (0.0, (hc[0], hc[1], hc[2], 0.0, 1.0))
            if best is not None:
                track[i] = best[1]; hist.append((i, best[1][0], best[1][1])); lost = 0; last_i = i; exited_top = False
            else:
                lost += 1
                # the ball left through the top edge: keep the track alive and search for re-entry in the top band
                if not exited_top and hist[-1][2] < 1.5 * D and lost >= 2: exited_top = True
                if not offframe and lost > cfg["max_gap_frames"]: break
                if offframe and i - last_i > cfg["max_offframe_frames"]: break
                if not offframe and pred[1] > H + 2 * D: break                  # below the floor: gone
        return track

    best_track = {}; best_free = 0
    seeds_tried = 0
    for i in range(n):
        for c in cands[i]:
            dw = nearest_wrist(poses[i], c[0], c[1])
            if dw is None or dw > 2.5 * D: continue
            seeds_tried += 1
            if seeds_tried > 400: break
            tr = link_forward(i, c)
            if len(tr) < 8: continue
            # a real flight leaves the body: count linked frames outside the (expanded) body box and above the seed
            free = sum(1 for j, cj in tr.items() if not in_box(cj[0], cj[1], boxes[j]) and cj[1] < c[1] - 1.0 * D)
            if free >= 8 and (free > best_free or (free == best_free and len(tr) > len(best_track))):
                best_track, best_free = tr, free
    if not best_track: return out, D
    i0 = min(best_track)
    # backward extension into the hands
    prev = best_track[i0]
    for i in range(i0 - 1, -1, -1):
        cb = None
        for c in cands[i]:
            dist = np.hypot(c[0] - prev[0], c[1] - prev[1])
            if dist < 1.5 * D and (cb is None or dist < cb[0]): cb = (dist, c)
        if cb is None: break
        best_track[i] = cb[1]; prev = cb[1]
    # held = near a wrist, up to the first frame the ball is clearly away from both wrists (the departure)
    order = sorted(best_track)
    depart = None
    for i in order:
        dwi = nearest_wrist(poses[i], best_track[i][0], best_track[i][1])
        if dwi is not None and dwi > 1.5 * D: depart = i; break
    for i, c in best_track.items():
        held = nearest_wrist(poses[i], c[0], c[1])
        src = "held" if (held is not None and held < 1.2 * D and (depart is None or i < depart)) else ("merged" if c[3] < 0 else "detected")
        edge = bool(c[1] - c[2] / 2 < 2 or c[0] - c[2] / 2 < 2 or c[0] + c[2] / 2 > W - 2)      # blob touches the frame edge: centroid biased
        out[i] = {"u": float(c[0]), "v": float(c[1]), "r": float(c[2] / 2), "score": float(c[3]), "source": src, "edge": edge}
    if cfg.get("template_fill"):
        nf = template_fill(out, frames, cfg, D, W, H)
        if nf: print(f"template fill: {nf} frames")
    if cfg.get("interpolate_gaps"): interpolate(out, cfg["max_gap_frames"])
    return out, D


def projected_parabola(t, u, v):
    from scipy.optimize import least_squares
    t = np.asarray(t, float); t0 = t[0]; tt = t - t0
    pu = np.polyfit(tt, u, 1); pv = np.polyfit(tt, v, 2)
    x0 = np.array([pu[1], pu[0], pv[2], pv[1], pv[0], 0.0])
    def res(x):
        a, b, d, e, f, c = x; den = 1 + c * tt
        return np.concatenate([(a + b * tt) / den - u, (d + e * tt + f * tt * tt) / den - v])
    x = least_squares(res, x0, loss="soft_l1", f_scale=3.0).x
    def predict(tq):
        a, b, d, e, f, c = x; q = tq - t0; den = 1 + c * q
        return (a + b * q) / den, (d + e * q + f * q * q) / den
    return predict


def template_fill(out, frames, cfg, D, W, H):
    """Fill missing flight frames near the release (and short descent gaps) with template matches confirmed near the
    parabola prediction. Labelled 'template'; the grader checks them against the clean fit."""
    det = [i for i, b in enumerate(out) if b["source"] == "detected" and not b.get("edge")]
    if len(det) < 8: return 0
    t = [frames[i][0] for i in det]; u = np.array([out[i]["u"] for i in det]); v = np.array([out[i]["v"] for i in det])
    predict = projected_parabola(t, u, v)
    i0 = det[0]; filled = 0
    # template from the first few clean detections (closest in appearance to the release frames)
    def template_for(i):
        j = min(det, key=lambda k: abs(k - i)); r = int(D / 2)
        cx, cy = int(out[j]["u"]), int(out[j]["v"])
        x0, y0 = max(0, cx - r), max(0, cy - r); x1, y1 = min(W, cx + r), min(H, cy + r)
        return cv2.cvtColor(frames[j][1][y0:y1, x0:x1], cv2.COLOR_BGR2GRAY)
    lo = max(0, i0 - 25); hi = min(len(out) - 1, det[-1])
    for i in range(lo, hi + 1):
        if out[i]["source"] != "none": continue
        if i < i0 - 25 or (i > i0 + 25 and not any(abs(i - k) <= 4 for k in det)): continue
        pu, pv = predict(frames[i][0])
        if not (0 <= pu < W and 0 <= pv < H): continue
        tmpl = template_for(i)
        if tmpl.size == 0 or min(tmpl.shape) < 8: continue
        R = int(1.2 * D); x0, y0 = int(max(0, pu - R)), int(max(0, pv - R)); x1, y1 = int(min(W, pu + R)), int(min(H, pv + R))
        win = cv2.cvtColor(frames[i][1][y0:y1, x0:x1], cv2.COLOR_BGR2GRAY)
        if win.shape[0] <= tmpl.shape[0] or win.shape[1] <= tmpl.shape[1]: continue
        m = cv2.matchTemplate(win, tmpl, cv2.TM_CCOEFF_NORMED)
        _, mx, _, loc = cv2.minMaxLoc(m)
        if mx < cfg["template_min_score"]: continue
        cu, cv_ = x0 + loc[0] + tmpl.shape[1] / 2, y0 + loc[1] + tmpl.shape[0] / 2
        if np.hypot(cu - pu, cv_ - pv) > 1.0 * D: continue
        out[i] = {"u": float(cu), "v": float(cv_), "r": float(D / 2), "score": float(mx), "source": "template", "edge": False}
        filled += 1
    return filled


def interpolate(out, max_gap):
    idx = [i for i, b in enumerate(out) if b["source"] in ("detected", "held", "merged", "template")]
    for a, b in zip(idx, idx[1:]):
        gap = b - a - 1
        if 0 < gap <= max_gap:
            for j in range(a + 1, b):
                f = (j - a) / (b - a)
                out[j] = {"u": out[a]["u"] + f * (out[b]["u"] - out[a]["u"]), "v": out[a]["v"] + f * (out[b]["v"] - out[a]["v"]),
                          "r": out[a]["r"] + f * (out[b]["r"] - out[a]["r"]), "score": 0.0, "source": "interpolated"}


# ----------------------------------------------------------------------------- pose
def make_landmarker(cfg):
    import mediapipe as mp
    from mediapipe.tasks.python import vision
    try:
        from mediapipe.tasks.python.core.base_options import BaseOptions
    except Exception:
        from mediapipe.tasks.python import BaseOptions
    try: base = BaseOptions(model_asset_path=cfg["model"], delegate=BaseOptions.Delegate.CPU)
    except Exception: base = BaseOptions(model_asset_path=cfg["model"])
    opts = vision.PoseLandmarkerOptions(base_options=base,
                                        running_mode=vision.RunningMode.VIDEO, num_poses=1,
                                        min_pose_detection_confidence=cfg["min_detection"],
                                        min_pose_presence_confidence=cfg["min_presence"],
                                        min_tracking_confidence=cfg["min_tracking"])
    return mp, vision.PoseLandmarker.create_from_options(opts)


class LegacyPose:
    """mp.solutions.pose wrapper exposing the same detect_for_video() shape as the Tasks API."""
    def __init__(self, cfg):
        import mediapipe as mp
        self.pose = mp.solutions.pose.Pose(static_image_mode=False, model_complexity=int(cfg["model_complexity"]),
                                           min_detection_confidence=cfg["min_detection"], min_tracking_confidence=cfg["min_tracking"], smooth_landmarks=False)
    def landmarks(self, rgb):
        res = self.pose.process(rgb)
        return res.pose_landmarks.landmark if res.pose_landmarks else None
    def close(self): self.pose.close()


def track_pose(cfg, frames, W, H):
    if cfg.get("backend", "legacy") == "legacy":
        mp = None; lm = LegacyPose(cfg)
    else:
        mp, lm = make_landmarker(cfg)
    out = []
    box = None                          # crop box (x0, y0, x1, y1) in full-res px
    for i, (t, fr) in enumerate(frames):
        if cfg["crop_to_shooter"] and box is not None:
            x0, y0, x1, y1 = box
            crop = fr[y0:y1, x0:x1]
            up = cfg["crop_upscale"]
            if up != 1.0: crop = cv2.resize(crop, None, fx=up, fy=up, interpolation=cv2.INTER_CUBIC)
            rgb = cv2.cvtColor(crop, cv2.COLOR_BGR2RGB)
            ox, oy, sx, sy = x0, y0, (x1 - x0) / rgb.shape[1], (y1 - y0) / rgb.shape[0]
        else:
            rgb = cv2.cvtColor(fr, cv2.COLOR_BGR2RGB); ox, oy, sx, sy = 0, 0, 1.0, 1.0
        if mp is None:
            lmk = lm.landmarks(np.ascontiguousarray(rgb))
        else:
            img = mp.Image(image_format=mp.ImageFormat.SRGB, data=np.ascontiguousarray(rgb))
            res = lm.detect_for_video(img, int(round(t * 1000)))
            lmk = res.pose_landmarks[0] if res.pose_landmarks else None
        joints = None
        if lmk is not None:
            joints = {}
            for name, k in JOINTS.items():
                p = lmk[k]
                joints[name] = [ox + p.x * rgb.shape[1] * sx, oy + p.y * rgb.shape[0] * sy, float(getattr(p, "visibility", 1.0) or 0.0)]
            if cfg["crop_to_shooter"]:
                xs = [j[0] for j in joints.values()]; ys = [j[1] for j in joints.values()]
                mw = cfg["crop_margin"] * (max(xs) - min(xs) + 1); mh = cfg["crop_margin"] * (max(ys) - min(ys) + 1)
                box = (int(max(0, min(xs) - mw - 60)), int(max(0, min(ys) - mh - 60)), int(min(W, max(xs) + mw + 60)), int(min(H, max(ys) + mh + 60)))
                if box[2] - box[0] < 64 or box[3] - box[1] < 64: box = None
        else:
            box = None
        out.append(joints)
    lm.close()
    if cfg["smooth"] != "none":
        smooth_pose(out, cfg["smooth"])
    return out


def smooth_pose(poses, mode):
    names = list(JOINTS.keys())
    for name in names:
        idx = [i for i, p in enumerate(poses) if p and name in p]
        if len(idx) < 5: continue
        arr = np.array([poses[i][name] for i in idx])
        if mode == "median3":
            for c in range(2):
                arr[:, c] = np.array([np.median(arr[max(0, k - 1):k + 2, c]) for k in range(len(arr))])
        elif mode == "savgol":
            from scipy.signal import savgol_filter
            win = min(9, len(arr) - (1 - len(arr) % 2))
            if win >= 5:
                for c in range(2): arr[:, c] = savgol_filter(arr[:, c], win, 2)
        for k, i in enumerate(idx): poses[i][name] = [float(arr[k, 0]), float(arr[k, 1]), float(arr[k, 2])]


# ----------------------------------------------------------------------------- render
def render(path_out, frames, balls, poses, fps_out=30):
    H, W = frames[0][1].shape[:2]
    vw = cv2.VideoWriter(path_out, cv2.VideoWriter_fourcc(*"mp4v"), fps_out, (W, H))
    bones = [("l_shoulder", "r_shoulder"), ("l_shoulder", "l_elbow"), ("l_elbow", "l_wrist"), ("r_shoulder", "r_elbow"), ("r_elbow", "r_wrist"),
             ("l_shoulder", "l_hip"), ("r_shoulder", "r_hip"), ("l_hip", "r_hip"), ("l_hip", "l_knee"), ("l_knee", "l_ankle"), ("r_hip", "r_knee"), ("r_knee", "r_ankle")]
    for i, (t, fr) in enumerate(frames):
        im = fr.copy()
        for j in range(max(0, i - 200), i):
            b = balls[j]
            if b["u"] is not None: cv2.circle(im, (int(b["u"]), int(b["v"])), 3, (255, 200, 0) if b["source"] in ("detected", "held", "merged", "template") else (0, 165, 255), -1)
        b = balls[i]
        if b["u"] is not None:
            col = (255, 255, 255) if b["source"] == "detected" else ((200, 200, 200) if b["source"] == "held" else (0, 165, 255))
            cv2.circle(im, (int(b["u"]), int(b["v"])), int(max(4, b["r"])), col, 3)
        p = poses[i]
        if p:
            for a, c in bones:
                if a in p and c in p and p[a][2] > 0.3 and p[c][2] > 0.3:
                    cv2.line(im, (int(p[a][0]), int(p[a][1])), (int(p[c][0]), int(p[c][1])), (0, 255, 0), 2)
            for name, j in p.items():
                cv2.circle(im, (int(j[0]), int(j[1])), 4, (0, 255, 0) if j[2] > 0.5 else (0, 0, 255), -1)
        cv2.rectangle(im, (0, 0), (900, 40), (0, 0, 0), -1)
        cv2.putText(im, f"frame {i}  t_file {t:.3f}s  ball {b['source']}", (10, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)
        vw.write(im)
    vw.release()


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video"); ap.add_argument("--start", type=float, required=True); ap.add_argument("--end", type=float, required=True)
    ap.add_argument("--time-scale", type=float, default=1.0, help="file time / real time (4 for 120 fps slo-mo exported at 30)")
    ap.add_argument("--config"); ap.add_argument("--out", required=True); ap.add_argument("--render")
    a = ap.parse_args()
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    if a.config: deep_update(cfg, json.load(open(a.config)))
    t0 = time.time()
    fps, frames = read_window(a.video, a.start, a.end, cfg["ball"]["downscale"])
    if len(frames) < 10: raise SystemExit("too few frames decoded")
    H, W = frames[0][1].shape[:2]
    planes = [small_planes(fr, cfg["ball"]["downscale"]) for _, fr in frames]
    poses = track_pose(cfg["pose"], frames, W, H)
    balls, D_est = track_ball(cfg["ball"], frames, planes, poses, W, H, fps * a.time_scale)
    result = {"meta": {"video": a.video, "start": a.start, "end": a.end, "time_scale": a.time_scale, "fps_file": fps, "fps_real": fps * a.time_scale,
                       "width": W, "height": H, "n_frames": len(frames), "config": cfg, "runtime_s": time.time() - t0, "ball_diameter_est_px": D_est},
              "frames": [{"i": i, "t_file": t, "t": t / a.time_scale, "ball": balls[i], "pose": poses[i]} for i, (t, _) in enumerate(frames)]}
    json.dump(result, open(a.out, "w"))
    nb = sum(1 for b in balls if b["source"] in ("detected", "held")); npz = sum(1 for p in poses if p)
    print(f"tracked {len(frames)} frames in {time.time()-t0:.1f}s: ball detected on {nb}, pose on {npz}; wrote {a.out}")
    if a.render: render(a.render, frames, balls, poses); print(f"rendered {a.render}")


if __name__ == "__main__":
    main()
