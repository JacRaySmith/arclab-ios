"""Draw every tracker variant's track on each window's reference frame; build per-clip HTML pages, an index
with the scorecard table, and one contact-sheet PNG per clip of the windows where the variants disagree.

    python3 tools/trackviz/trackviz.py --run <run-dir> [--frames <dir>] [--variants a,b,c] [--repo <path>]

<run-dir>/cache/<variant>/ are the caches `TrajectoryProbe session --track-variants ... --dump-windows
<run-dir>/cache` wrote (with their .diag.json files); <run-dir>/scores/<variant>.json are `ShotBench run
--json` scorecards for each (see score.sh). Reference frames are exported once per window into --frames
(default <run-dir>/frames) with `TrajectoryProbe frame`, at the base track's apex. Needs Pillow.
"""
import argparse, json, glob, os, sys, math, subprocess
from collections import defaultdict
from PIL import Image, ImageDraw, ImageFont

ap = argparse.ArgumentParser()
ap.add_argument('--run', required=True)
ap.add_argument('--frames', default=None)
ap.add_argument('--variants', default='base,base-gts,backLink-gts,backLinkBoxes-gts,boxSeeds-gts,extend-gts,gap-gts,aspect-gts,all-gts,allBoxes-gts')
ap.add_argument('--repo', default=os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
ap.add_argument('--probe', default=None, help='TrajectoryProbe binary, used to export missing reference frames')
ap.add_argument('--footage', default=None, help='directory holding the clips (default <repo>/footage/2026-09-13)')
args = ap.parse_args()
REPO = args.repo
RUN = args.run
FRAMES = args.frames or f'{RUN}/frames'
VIZ = f'{RUN}/viz'
os.makedirs(f'{VIZ}/panels', exist_ok=True)
os.makedirs(FRAMES, exist_ok=True)
VARIANTS = [v for v in args.variants.split(',') if os.path.isdir(f'{RUN}/cache/{v}')]
if not VARIANTS:
    sys.exit(f'no variant caches under {RUN}/cache')

labels = {e['windowID']: e for e in json.load(open(f'{REPO}/docs/footage-2026-09-13/window_labels.json'))['labels']}

def load_scores(v):
    p = f'{RUN}/scores/{v}.json'
    if not os.path.exists(p):
        return {}, None
    d = json.load(open(p))
    by = {w['windowID']: w for w in d['windows']}
    for sk in d.get('skipped', []):
        by[sk['windowID']] = {'windowID': sk['windowID'], 'accepted': False, 'refusalReason': 'skipped: ' + sk['reason']}
    return by, d

scores = {}
cards = {}
for v in VARIANTS:
    scores[v], cards[v] = load_scores(v)

def load_diag(v, wid):
    p = f'{RUN}/cache/{v}/{wid}.diag.json'
    return json.load(open(p)) if os.path.exists(p) else None

def load_cache(v, wid):
    p = f'{RUN}/cache/{v}/{wid}.json'
    return json.load(open(p)) if os.path.exists(p) else None

windows = sorted(json.load(open(f'{RUN}/cache/{VARIANTS[0]}/manifest.json')), key=lambda e: e['windowID'])
wids = [e['windowID'] for e in windows]

# Reference frames: one per window, at the first variant's apex (else the window midpoint), exported on demand.
if args.probe:
    footage = args.footage or f'{REPO}/footage/2026-09-13'
    for e in windows:
        out = f"{FRAMES}/{e['windowID']}.png"
        if os.path.exists(out):
            continue
        c = load_cache(VARIANTS[0], e['windowID'])
        s = c['samples'] if c else []
        t_file = min(s, key=lambda x: x['v'])['t'] * c['timeScale'] if len(s) >= 5 else 0.5 * (e['fileStart'] + e['fileStart'] + 8)
        r = subprocess.run([args.probe, 'frame', f"{footage}/{e['clip']}", '--time', f'{t_file:.3f}', '--out', out], capture_output=True, text=True)
        if r.returncode != 0:
            print('frame export failed for', e['windowID'], r.stderr[-200:], file=sys.stderr)

try:
    FONT = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 22)
    FONT_S = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 18)
    FONT_B = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 30)
except Exception:
    FONT = FONT_S = FONT_B = ImageFont.load_default()

COLOURS = {'forward': (0, 210, 255), 'back': (90, 255, 90), 'extend': (255, 90, 255), 'template': (255, 220, 0)}

def verdict_text(sc):
    if sc is None:
        return 'not scored', (200, 200, 200)
    if sc.get('accepted'):
        ge = sc.get('gError')
        ge = f"g {ge*100:+.1f}%" if isinstance(ge, (int, float)) else ''
        h = sc.get('releaseHeight')
        h = f" h {h:.2f} m" if isinstance(h, (int, float)) else ' (no release)'
        return f"ACCEPTED {ge}{h}", (80, 255, 80)
    r = sc.get('refusalReason') or 'refused'
    ge = sc.get('gError')
    if isinstance(ge, (int, float)) and abs(ge) < 50:
        r += f" (g {ge*100:+.0f}%)"
    return 'REFUSED: ' + r[:60], (255, 90, 90)

def draw_panel(wid, v):
    out = f'{VIZ}/panels/{wid}__{v}.jpg'
    frame_path = f'{FRAMES}/{wid}.png'
    diag = load_diag(v, wid)
    cache = load_cache(v, wid)
    if not os.path.exists(frame_path):
        img = Image.new('RGB', (1920, 1080), (30, 30, 30))
    else:
        img = Image.open(frame_path).convert('RGB')
    d = ImageDraw.Draw(img)
    if cache:
        for p in cache['rimBoundary']:
            d.ellipse([p[0]-3, p[1]-3, p[0]+3, p[1]+3], fill=(0, 255, 0))
    if diag:
        for s in diag['seeds']:
            d.ellipse([s[1]-3, s[2]-3, s[1]+3, s[2]+3], fill=(160, 160, 160))
        dets = diag['detections']
        prev = None
        for x in sorted(dets, key=lambda x: x['frameIndex']):
            stage = (x.get('origin') or 'forward').split('.')[0]
            if x['source'] == 'template':
                stage = 'template'
            col = COLOURS.get(stage, (255, 255, 255))
            r = max(4, x['diameterPx'] / 2)
            width = 3
            if x['edge']:
                col = (255, 60, 60); width = 2
            d.ellipse([x['u']-r, x['v']-r, x['u']+r, x['v']+r], outline=col, width=width)
            if prev is not None:
                d.line([prev, (x['u'], x['v'])], fill=col, width=2)
            prev = (x['u'], x['v'])
        n = len(dets)
        clean = [x for x in dets if not x['edge']]
        span = (max(x['pts'] for x in clean) - min(x['pts'] for x in clean)) / diag['timeScale'] if len(clean) > 1 else 0
        stages = defaultdict(int)
        for x in dets:
            st = 'template' if x['source'] == 'template' else (x.get('origin') or 'forward').split('.')[0]
            stages[st] += 1
        stage_txt = ' '.join(f"{k}:{c}" for k, c in sorted(stages.items()))
        line2 = f"n={n} ({len(clean)} clean)  span {span:.2f} s  ts x{diag['timeScale']:.0f}  {stage_txt}"
    else:
        line2 = 'no track'
    vt, vc = verdict_text(scores.get(v, {}).get(wid))
    d.rectangle([0, 0, 1920, 110], fill=(0, 0, 0))
    d.text((16, 8), f"{v}", font=FONT_B, fill=(255, 255, 255))
    d.text((16, 46), line2, font=FONT, fill=(220, 220, 220))
    d.text((16, 76), vt, font=FONT, fill=vc)
    if diag and diag.get('note'):
        d.text((900, 8), 'time scale re-derived from gravity (x1 content)', font=FONT_S, fill=(255, 200, 80))
    img = img.resize((640, 360), Image.LANCZOS)
    img.save(out, quality=82)
    return out

# ---- panels
for wid in wids:
    for v in VARIANTS:
        draw_panel(wid, v)

# ---- summary table
def pct(x):
    return f"{100*x:.1f} %" if isinstance(x, (int, float)) else '—'

rows = []
for v in VARIANTS:
    c = cards.get(v)
    if not c:
        rows.append((v, {}))
        continue
    wl = c['windowLabelScoring']
    ov = wl.get('overall', {})
    per = {p['label']: p for p in wl.get('perClip', [])}
    q = c['overall']['quality']
    spreads = {b['clip']: b for b in q.get('withinBlockSpread', [])}
    rows.append((v, {
        'accepted': c['overall']['accepted'], 'n': c['overall']['windowsAnalysed'],
        'recall': ov.get('recall'), 'precision': ov.get('precision'),
        'r1765': per.get('IMG_1765.mov', {}).get('recall'), 'r1766': per.get('IMG_1766.mov', {}).get('recall'), 'r1764': per.get('IMG_1764.mov', {}).get('recall'),
        'gErr': q.get('medianAbsGError'), 'rms': q.get('medianRmsPx'),
        'hsd1765': spreads.get('IMG_1765.mov', {}).get('releaseHeightSD'), 'hsd1764': spreads.get('IMG_1764.mov', {}).get('releaseHeightSD'), 'hsd1766': spreads.get('IMG_1766.mov', {}).get('releaseHeightSD'),
        'summary': c.get('variantSummary', ''),
    }))

def fmt(x, f):
    return f.format(x) if isinstance(x, (int, float)) else '—'

table = ['<table class="sum"><tr><th>tracking variant</th><th>accepted</th><th>recall</th><th>precision</th><th>free throw</th><th>three</th><th>elbow</th><th>median |g err|</th><th>median rms px</th><th>FT height SD</th><th>elbow height SD</th><th>three height SD</th></tr>']
for v, r in rows:
    if not r:
        table.append(f'<tr><td>{v}</td><td colspan=11>not scored</td></tr>'); continue
    table.append(f"<tr><td><b>{v}</b></td><td>{r['accepted']} / {r['n']}</td><td><b>{pct(r['recall'])}</b></td><td>{pct(r['precision'])}</td>"
                 f"<td>{pct(r['r1765'])}</td><td>{pct(r['r1766'])}</td><td>{pct(r['r1764'])}</td>"
                 f"<td>{fmt(r['gErr'], '{:.3f}')}</td><td>{fmt(r['rms'], '{:.1f}')}</td>"
                 f"<td>{fmt(r['hsd1765'], '{:.3f}')}</td><td>{fmt(r['hsd1764'], '{:.3f}')}</td><td>{fmt(r['hsd1766'], '{:.3f}')}</td></tr>")
table.append('</table>')
json.dump({v: r for v, r in rows}, open(f'{VIZ}/summary.json', 'w'), indent=1)

# ---- per-window verdict matrix (for choosing interesting rows)
def verdict(v, wid):
    sc = scores.get(v, {}).get(wid)
    return None if sc is None else bool(sc.get('accepted'))

interesting = []
for wid in wids:
    vs = [verdict(v, wid) for v in VARIANTS]
    if len(set(vs)) > 1:
        interesting.append(wid)

# ---- HTML
CSS = """
body{font-family:-apple-system,Helvetica,sans-serif;background:#111;color:#eee;margin:0;padding:12px}
table.sum{border-collapse:collapse;font-size:14px;margin-bottom:16px}
table.sum th,table.sum td{border:1px solid #444;padding:4px 8px;text-align:right}
table.sum td:first-child,table.sum th:first-child{text-align:left}
.grid{display:grid;grid-auto-rows:max-content;gap:6px}
.hdr{position:sticky;top:0;background:#111;padding:4px;font-weight:bold;z-index:2}
.row{display:contents}
.rowhdr{writing-mode:vertical-rl;transform:rotate(180deg);font-size:13px;padding:4px;color:#ccc}
img{width:100%;display:block}
.shot{color:#8f8}.notShot{color:#f88}.unsure{color:#fc8}
.legend span{display:inline-block;padding:2px 8px;margin-right:8px;border-radius:3px;font-size:13px}
a{color:#8cf}
"""
LEGEND = ('<div class="legend"><span style="background:#00d2ff;color:#000">forward pass</span>'
          '<span style="background:#5aff5a;color:#000">backward pass</span>'
          '<span style="background:#ff5aff;color:#000">parabola extend</span>'
          '<span style="background:#ffdc00;color:#000">template fill</span>'
          '<span style="background:#ff3c3c;color:#000">edge-clipped (not fitted)</span>'
          '<span style="background:#a0a0a0;color:#000">scanner seeds</span>'
          '<span style="background:#00ff00;color:#000">rim trace</span></div>')

def page(title, wid_list, filename, note=''):
    cols = len(VARIANTS) + 1
    h = [f'<html><head><meta charset="utf-8"><title>{title}</title><style>{CSS}</style></head><body>']
    h.append(f'<h2>{title}</h2>{note}{LEGEND}<p><a href="index.html">index</a></p>')
    h.append(f'<div class="grid" style="grid-template-columns:28px repeat({len(VARIANTS)},minmax(360px,1fr))">')
    h.append('<div class="hdr"></div>' + ''.join(f'<div class="hdr">{v}</div>' for v in VARIANTS))
    for wid in wid_list:
        lab = labels.get(wid, {}).get('label', '?')
        h.append(f'<div class="rowhdr"><span class="{lab}">{lab}</span> {wid}</div>')
        for v in VARIANTS:
            h.append(f'<div><img loading="lazy" src="panels/{wid}__{v}.jpg"></div>')
    h.append('</div></body></html>')
    open(f'{VIZ}/{filename}', 'w').write('\n'.join(h))

clips = sorted(set(e['clip'] for e in windows))
index = [f'<html><head><meta charset="utf-8"><title>Tracking variants</title><style>{CSS}</style></head><body>']
index.append('<h1>Shot tracking variants — 2026-09-13 corpus, 98 windows</h1>')
index.append('<p>Geometry: <code>autoFoundNoPool</code>, shipping acceptance rule, precision/recall against the hand labels (88 shot / 6 notShot / 4 unsure). '
             '<b>-gts</b> = the same tracker with the window\'s time scale re-derived from gravity where the declared ×4 gave a fit far outside the gate (the clip\'s normal-speed ends).</p>')
index.append(''.join(table))
index.append('<h3>Pages</h3><ul>')
index.append(f'<li><a href="disagree.html">Windows where the variants disagree on the verdict</a> ({len(interesting)})</li>')
for c in clips:
    stem = c.replace('.mov', '')
    index.append(f'<li><a href="{stem}.html">{c}</a> — all windows</li>')
index.append('</ul><h3>Variant summaries</h3><ul>')
for v, r in rows:
    index.append(f'<li><b>{v}</b>: {r.get("summary", "")}</li>')
index.append('</ul></body></html>')
open(f'{VIZ}/index.html', 'w').write('\n'.join(index))
page('Windows where the variants disagree', interesting, 'disagree.html')
for c in clips:
    stem = c.replace('.mov', '')
    page(c, [w for w in wids if w.startswith(stem)], f'{stem}.html')

# ---- contact sheets (PNG): the disagreeing windows, a chosen subset of columns
SHEET_VARIANTS = [v for v in ['base', 'base-gts', 'backLink-gts', 'boxSeeds-gts', 'extend-gts', 'all-gts', 'allBoxes-gts'] if v in VARIANTS]
PW, PH = 480, 270
for c in clips:
    stem = c.replace('.mov', '')
    rws = [w for w in interesting if w.startswith(stem)]
    if not rws:
        continue
    header = 150
    sheet = Image.new('RGB', (40 + PW * len(SHEET_VARIANTS), header + PH * len(rws)), (12, 12, 12))
    d = ImageDraw.Draw(sheet)
    d.text((10, 8), f'{c}: windows where the variants disagree ({len(rws)} of {sum(1 for w in wids if w.startswith(stem))})', font=FONT_B, fill=(255, 255, 255))
    for j, v in enumerate(SHEET_VARIANTS):
        r = dict(rows).get(v, {})
        d.text((40 + j * PW + 6, 52), v, font=FONT, fill=(255, 255, 255))
        d.text((40 + j * PW + 6, 80), f"recall {pct(r.get('recall'))}  prec {pct(r.get('precision'))}", font=FONT_S, fill=(200, 200, 200))
        d.text((40 + j * PW + 6, 104), f"|g err| {fmt(r.get('gErr'), '{:.3f}')}  rms {fmt(r.get('rms'), '{:.1f}')} px", font=FONT_S, fill=(200, 200, 200))
    for i, wid in enumerate(rws):
        lab = labels.get(wid, {}).get('label', '?')
        col = {'shot': (140, 255, 140), 'notShot': (255, 140, 140)}.get(lab, (255, 200, 140))
        tag = Image.new('RGB', (PH, 40), (12, 12, 12))
        td = ImageDraw.Draw(tag)
        td.text((4, 6), f'{wid}  {lab}', font=FONT_S, fill=col)
        sheet.paste(tag.rotate(90, expand=True), (0, header + i * PH))
        for j, v in enumerate(SHEET_VARIANTS):
            p = Image.open(f'{VIZ}/panels/{wid}__{v}.jpg').resize((PW, PH), Image.LANCZOS)
            sheet.paste(p, (40 + j * PW, header + i * PH))
    sheet.save(f'{VIZ}/sheet-{stem}.png')
print('viz written to', VIZ, 'interesting windows:', len(interesting))
