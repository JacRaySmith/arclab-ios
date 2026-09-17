#!/usr/bin/env python
"""Export auto-labels from grader-passing tracks as Create ML object-detection data: 512x512 tiles around the ball
(random offset so the ball is not always centred) plus negative tiles, with annotations.json (top-left origin, pixels)."""
import argparse, json, os, random
import numpy as np, cv2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("shots_dir", nargs="+"); ap.add_argument("--video", action="append", required=True, help="video per shots_dir, same order")
    ap.add_argument("--out", required=True); ap.add_argument("--tile", type=int, default=512); ap.add_argument("--every", type=int, default=2)
    ap.add_argument("--negatives", type=float, default=0.3); ap.add_argument("--min-score", type=float, default=100)
    a = ap.parse_args()
    os.makedirs(os.path.join(a.out, "images"), exist_ok=True)
    rng = random.Random(0); ann = []; n_pos = n_neg = 0
    for sd, video in zip(a.shots_dir, a.video):
        cap = cv2.VideoCapture(video); fps = cap.get(cv2.CAP_PROP_FPS)
        for fn in sorted(os.listdir(sd)):
            if not fn.endswith(".report.json"): continue
            rep = json.load(open(os.path.join(sd, fn)))
            if rep["score"] < a.min_score: continue
            track = json.load(open(os.path.join(sd, fn.replace(".report.json", ".json"))))
            frames = [f for f in track["frames"] if f["ball"]["source"] == "detected" and not f["ball"].get("edge")]
            for k, f in enumerate(frames[::a.every]):
                cap.set(cv2.CAP_PROP_POS_MSEC, f["t_file"] * 1000.0); ok, im = cap.read()
                if not ok: continue
                H, W = im.shape[:2]; T = a.tile; u, v, r = f["ball"]["u"], f["ball"]["v"], f["ball"]["r"]
                x0 = int(np.clip(u - rng.uniform(0.2, 0.8) * T, 0, W - T)); y0 = int(np.clip(v - rng.uniform(0.2, 0.8) * T, 0, H - T))
                tile = im[y0:y0 + T, x0:x0 + T]
                name = f"{os.path.basename(sd)}_{fn[:6]}_{f['i']:04d}.jpg"
                cv2.imwrite(os.path.join(a.out, "images", name), tile, [cv2.IMWRITE_JPEG_QUALITY, 92])
                ann.append({"image": name, "annotations": [{"label": "ball", "coordinates": {"x": float(u - x0), "y": float(v - y0), "width": float(2 * r), "height": float(2 * r)}}]}); n_pos += 1
                if rng.random() < a.negatives:      # a tile elsewhere in the same frame with no ball
                    for _ in range(10):
                        nx = rng.randint(0, W - T); ny = rng.randint(0, H - T)
                        if not (nx <= u <= nx + T and ny <= v <= ny + T):
                            nname = f"neg_{os.path.basename(sd)}_{fn[:6]}_{f['i']:04d}.jpg"
                            cv2.imwrite(os.path.join(a.out, "images", nname), im[ny:ny + T, nx:nx + T], [cv2.IMWRITE_JPEG_QUALITY, 92])
                            ann.append({"image": nname, "annotations": []}); n_neg += 1; break
        cap.release()
    json.dump(ann, open(os.path.join(a.out, "annotations.json"), "w"))
    print(f"wrote {n_pos} ball tiles and {n_neg} negative tiles to {a.out} (Create ML object-detection format; coordinates are box centres in pixels)")


if __name__ == "__main__":
    main()
