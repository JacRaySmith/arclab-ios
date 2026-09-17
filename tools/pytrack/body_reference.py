#!/usr/bin/env python
"""Independent body-pose reference for the ArcLab body model.

Runs MediaPipe's legacy `mp.solutions.pose` (33 landmarks: eyes, ears, mouth, heels, foot index —
everything Apple Vision's 19-point 2-D / 17-joint 3-D models lack) over one shot window and writes
per-frame JSON: `pose_landmarks` (normalised image coordinates, converted here to full-frame pixels)
and `pose_world_landmarks` (metres, hip-centred, MediaPipe's own metric space).

This is a *reference*, not a ground truth: MediaPipe is a second opinion from a different model
family. Where it and Vision disagree the frames are rendered (--render) and looked at.

    tools/pytrack/.venv-legacy/bin/python tools/pytrack/body_reference.py \
        footage/2026-09-13/IMG_1765.mov --start 88.5 --end 95.5 --time-scale 4 \
        --out /tmp/body_ref_t89.json [--complexity 2] [--crop] [--render dir --render-times a,b,c]

Run with `.venv-legacy` (mediapipe 0.10.14 legacy solutions); the Tasks API in newer wheels does not
expose the same solution. Frame reading mirrors `track.py:read_window` exactly, including the
duplicate-frame guard, so frame indices line up with the pytrack shot JSONs.
"""
import argparse, json, os, sys, time
import numpy as np
import cv2

# The 33 BlazePose landmarks, under ArcLab's canonical names where one exists.
LANDMARKS = {
    0: "nose", 1: "l_eye_inner", 2: "l_eye", 3: "l_eye_outer", 4: "r_eye_inner", 5: "r_eye",
    6: "r_eye_outer", 7: "l_ear", 8: "r_ear", 9: "mouth_l", 10: "mouth_r",
    11: "l_shoulder", 12: "r_shoulder", 13: "l_elbow", 14: "r_elbow", 15: "l_wrist", 16: "r_wrist",
    17: "l_pinky", 18: "r_pinky", 19: "l_index", 20: "r_index", 21: "l_thumb", 22: "r_thumb",
    23: "l_hip", 24: "r_hip", 25: "l_knee", 26: "r_knee", 27: "l_ankle", 28: "r_ankle",
    29: "l_heel", 30: "r_heel", 31: "l_foot_index", 32: "r_foot_index",
}


def read_window(path, start, end):
    """Identical to track.py:read_window (downscale unused here)."""
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise SystemExit(f"cannot open {path}")
    fps = cap.get(cv2.CAP_PROP_FPS)
    cap.set(cv2.CAP_PROP_POS_MSEC, start * 1000.0)
    frames, dup, prev_sig = [], 0, None
    while True:
        ok, fr = cap.read()
        if not ok:
            break
        t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0 - 1.0 / fps
        if t > end + 1e-6:
            break
        sig = cv2.resize(fr[:, :, 1], (48, 27), interpolation=cv2.INTER_AREA)
        if prev_sig is not None and np.array_equal(sig, prev_sig):
            dup += 1
            continue
        prev_sig = sig
        frames.append((t, fr))
    cap.release()
    if dup:
        print(f"note: skipped {dup} duplicated frames from the decoder", file=sys.stderr)
    return fps, frames


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--start", type=float, required=True)
    ap.add_argument("--end", type=float, required=True)
    ap.add_argument("--time-scale", type=float, default=1.0)
    ap.add_argument("--complexity", type=int, default=2, help="0 lite, 1 full, 2 heavy")
    ap.add_argument("--crop", action="store_true",
                    help="track a padded crop around the previous frame's landmarks (Vision's strategy)")
    ap.add_argument("--crop-pad", type=float, default=0.6)
    ap.add_argument("--out", required=True)
    ap.add_argument("--render", default=None, help="directory for annotated PNGs")
    ap.add_argument("--render-times", default="", help="comma-separated file times to render")
    ap.add_argument("--every", type=int, default=1,
                    help="analyse every Nth decoded frame (a 1.9 s window at 240 fps is 456 frames)")
    ap.add_argument("--compare", default=None,
                    help="a TrajectoryProbe `body --json` file; print the per-joint median |Δ| in pixels "
                         "between Vision's 2-D points and MediaPipe's, on the frames both carry")
    a = ap.parse_args()

    import mediapipe as mp
    t0 = time.time()
    fps, frames = read_window(a.video, a.start, a.end)
    if not frames:
        raise SystemExit("no frames in window")
    H, W = frames[0][1].shape[:2]
    pose = mp.solutions.pose.Pose(static_image_mode=False, model_complexity=a.complexity,
                                  min_detection_confidence=0.5, min_tracking_confidence=0.5,
                                  smooth_landmarks=False)
    render_times = [float(x) for x in a.render_times.split(",") if x.strip()]
    if a.render:
        os.makedirs(a.render, exist_ok=True)

    out, box = [], None
    if a.every > 1:
        frames = frames[::a.every]
    for i, (t, fr) in enumerate(frames):
        if a.crop and box is not None:
            x0, y0, x1, y1 = box
            sub = fr[y0:y1, x0:x1]
            ox, oy = x0, y0
        else:
            sub, ox, oy = fr, 0, 0
        rgb = cv2.cvtColor(np.ascontiguousarray(sub), cv2.COLOR_BGR2RGB)
        res = pose.process(rgb)
        rec = {"i": i, "t_file": t, "t": t / a.time_scale, "points2D": None, "world": None}
        if res.pose_landmarks:
            h, w = sub.shape[:2]
            pts, xs, ys = {}, [], []
            for k, name in LANDMARKS.items():
                p = res.pose_landmarks.landmark[k]
                u, v = ox + p.x * w, oy + p.y * h
                pts[name] = [float(u), float(v), float(p.visibility)]
                xs.append(u); ys.append(v)
            rec["points2D"] = pts
            if res.pose_world_landmarks:
                rec["world"] = {LANDMARKS[k]: [float(p.x), float(p.y), float(p.z), float(p.visibility)]
                                for k, p in enumerate(res.pose_world_landmarks.landmark)}
            if a.crop:
                mw = a.crop_pad * (max(xs) - min(xs) + 1) * 0.5
                mh = a.crop_pad * (max(ys) - min(ys) + 1) * 0.5
                box = (int(max(0, min(xs) - mw)), int(max(0, min(ys) - mh)),
                       int(min(W, max(xs) + mw)), int(min(H, max(ys) + mh)))
                if box[2] - box[0] < 64 or box[3] - box[1] < 64:
                    box = None
        else:
            box = None
        out.append(rec)

        if a.render and any(abs(t - rt) < 0.5 / fps for rt in render_times):
            img = fr.copy()
            if rec["points2D"]:
                for name, (u, v, vis) in rec["points2D"].items():
                    c = (0, 255, 0) if vis >= 0.5 else (0, 128, 255)
                    cv2.circle(img, (int(round(u)), int(round(v))), 3, c, -1)
                for aa, bb in [("l_shoulder", "l_elbow"), ("l_elbow", "l_wrist"), ("r_shoulder", "r_elbow"),
                               ("r_elbow", "r_wrist"), ("l_shoulder", "r_shoulder"), ("l_hip", "r_hip"),
                               ("l_hip", "l_knee"), ("l_knee", "l_ankle"), ("r_hip", "r_knee"),
                               ("r_knee", "r_ankle"), ("l_ankle", "l_foot_index"), ("r_ankle", "r_foot_index")]:
                    pa, pb = rec["points2D"][aa], rec["points2D"][bb]
                    cv2.line(img, (int(pa[0]), int(pa[1])), (int(pb[0]), int(pb[1])), (0, 255, 255), 1)
                xs = [p[0] for p in rec["points2D"].values()]; ys = [p[1] for p in rec["points2D"].values()]
                x0 = int(max(0, min(xs) - 60)); x1 = int(min(W, max(xs) + 60))
                y0 = int(max(0, min(ys) - 60)); y1 = int(min(H, max(ys) + 60))
                img = img[y0:y1, x0:x1]
                img = cv2.resize(img, None, fx=2.0, fy=2.0, interpolation=cv2.INTER_CUBIC)
            cv2.imwrite(os.path.join(a.render, f"mp_{t:.3f}.png"), img)

    pose.close()
    found = sum(1 for r in out if r["points2D"])
    meta = {"video": a.video, "start": a.start, "end": a.end, "time_scale": a.time_scale,
            "fps_file": fps, "fps_real": fps * a.time_scale, "width": W, "height": H,
            "n_frames": len(out), "n_pose": found, "model": f"mp.solutions.pose complexity {a.complexity}",
            "mediapipe": mp.__version__, "crop": a.crop, "runtime_s": time.time() - t0}
    meta["every"] = a.every
    json.dump({"meta": meta, "frames": out}, open(a.out, "w"))
    print(f"{a.out}: {found}/{len(out)} frames with a pose, {meta['runtime_s']:.1f}s")
    if a.compare:
        compare(out, a.compare, fps)


# MediaPipe name -> the ArcLab/Vision 2-D name it is the same anatomical point as. `neck` has no
# MediaPipe landmark: BlazePose has no neck, so the mid-shoulder stands in for it and the row says so.
COMPARE = {
    "nose": "nose", "l_eye": "leftEye", "r_eye": "rightEye", "l_ear": "leftEar", "r_ear": "rightEar",
    "l_shoulder": "leftShoulder", "r_shoulder": "rightShoulder",
    "l_elbow": "leftElbow", "r_elbow": "rightElbow", "l_wrist": "leftWrist", "r_wrist": "rightWrist",
    "l_hip": "leftHip", "r_hip": "rightHip", "l_knee": "leftKnee", "r_knee": "rightKnee",
    "l_ankle": "leftAnkle", "r_ankle": "rightAnkle",
}


def compare(mp_frames, body_json, fps):
    """Per-joint median |Δ| px, Vision's 2-D points against MediaPipe's, on the frames both carry.

    Two different model families landing on the same pixel is the only independent check available
    without hand-labelling, so this is the check the joint table is read against. It is *agreement*,
    not accuracy: where they disagree the frame has to be looked at (`--render`).
    """
    doc = json.load(open(body_json))
    vision = {}
    for f in doc.get("visionTimeline", doc.get("timeline", {})).get("frames", []):
        vision[round(f["fileTime"] * fps)] = f.get("points2D", {})
    rows, matched = {}, 0
    for r in mp_frames:
        if not r["points2D"]:
            continue
        key = round(r["t_file"] * fps)
        v = vision.get(key) or vision.get(key - 1) or vision.get(key + 1)
        if not v:
            continue
        matched += 1
        for mpn, vn in COMPARE.items():
            if vn not in v or mpn not in r["points2D"]:
                continue
            if v[vn].get("confidence", 0) < 0.3:
                continue
            du = v[vn]["u"] - r["points2D"][mpn][0]
            dv = v[vn]["v"] - r["points2D"][mpn][1]
            rows.setdefault(vn, []).append((du * du + dv * dv) ** 0.5)
        # The neck: BlazePose has none, so compare Vision's against MediaPipe's mid-shoulder and
        # label it, rather than quietly pretending the two models define the same point.
        if "neck" in v and v["neck"].get("confidence", 0) >= 0.3 \
                and "l_shoulder" in r["points2D"] and "r_shoulder" in r["points2D"]:
            mu = 0.5 * (r["points2D"]["l_shoulder"][0] + r["points2D"]["r_shoulder"][0])
            mv = 0.5 * (r["points2D"]["l_shoulder"][1] + r["points2D"]["r_shoulder"][1])
            rows.setdefault("neck (vs mid-shoulder)", []).append(
                ((v["neck"]["u"] - mu) ** 2 + (v["neck"]["v"] - mv) ** 2) ** 0.5)
    print(f"compare: {matched} frames carry both a Vision and a MediaPipe pose")
    print(f"  {'joint':24s} {'median |d| px':>13s} {'p90':>7s} {'n':>5s}")
    for name in sorted(rows):
        d = sorted(rows[name])
        p90 = d[min(len(d) - 1, int(0.9 * (len(d) - 1)))]
        print(f"  {name:24s} {d[len(d) // 2]:13.1f} {p90:7.1f} {len(d):5d}")
    allp = sorted(x for v in rows.values() for x in v)
    if allp:
        print(f"  {'all joints':24s} {allp[len(allp) // 2]:13.1f}")


if __name__ == "__main__":
    main()
