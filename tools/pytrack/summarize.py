#!/usr/bin/env python
"""Make/miss split and consistency summary from a report.json (no recomputation). Only gravity-accepted shots (|g err| ≤ 8 %).
Effect sizes are Cohen's d with n; nothing is claimed below n = 5 per group, and the brief's n ≥ 30 rule for findings is stated."""
import json, sys
import numpy as np


def main(path, block):
    rows = json.load(open(path))
    def ok(r):
        g = r.get("geometry", {})
        if g.get("g_err_pct") is None or abs(g["g_err_pct"]) > 8: return False
        h, v, d = g.get("release_h_m"), g.get("release_v_mps"), g.get("depth_m")
        return (h is None or 1.6 <= h <= 3.3) and (v is None or 4.5 <= v <= 11) and (d is None or -0.6 <= d <= 1.0)
    acc = [r for r in rows if ok(r)]
    rej = [r for r in rows if r.get("geometry", {}).get("g_err_pct") is not None and abs(r["geometry"]["g_err_pct"]) <= 8 and not ok(r)]
    if rej: print(f"  {len(rej)} shots passed the gravity gate but have impossible release/crossing values (plane solve failed): shots " + ", ".join(str(r["shot"]) for r in rej))
    print(f"=== {block}: {len(rows)} windows, {len(acc)} gravity-accepted ===")
    for key, unit in [("release_deg", "°"), ("release_h_m", "m"), ("release_v_mps", "m/s"), ("entry_deg", "°"), ("depth_m", "m")]:
        mk = [r["geometry"][key] for r in acc if r["outcome"]["outcome"] == "make" and r["geometry"].get(key) is not None]
        ms = [r["geometry"][key] for r in acc if r["outcome"]["outcome"] == "miss" and r["geometry"].get(key) is not None]
        al = [r["geometry"][key] for r in acc if r["geometry"].get(key) is not None]
        line = f"  {key:14s} all {np.mean(al):6.2f} ± {np.std(al, ddof=1) if len(al) > 1 else float('nan'):5.2f} {unit} (n {len(al)})"
        if len(mk) >= 2 and len(ms) >= 2:
            sp = np.sqrt(((len(mk) - 1) * np.var(mk, ddof=1) + (len(ms) - 1) * np.var(ms, ddof=1)) / (len(mk) + len(ms) - 2))
            d = (np.mean(ms) - np.mean(mk)) / sp if sp > 0 else float("nan")
            line += f" | makes {np.mean(mk):6.2f} (n {len(mk)})  misses {np.mean(ms):6.2f} (n {len(ms)})  d(miss−make) {d:+.2f}"
            if len(mk) < 5 or len(ms) < 5: line += "  [too few per group to claim anything]"
        print(line)
    dep = [(r["geometry"]["depth_m"], r["outcome"]["outcome"]) for r in acc if r["geometry"].get("depth_m") is not None]
    if dep:
        short = [d for d, o in dep if o == "miss" and d < 0.20]; long_ = [d for d, o in dep if o == "miss" and d > 0.30]
        print(f"  misses (inferred): {len(short)} short of centre by > 3 cm, {len(long_)} long by > 7 cm, of {sum(1 for _, o in dep if o == 'miss')} misses with depth")
    print("  note: outcomes are inferred from the ball's behaviour at the rim; findings require n ≥ 30 per cell (brief §6) — these are previews.")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "")
