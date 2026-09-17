# Phase 0 filming protocol — v1 (2026-09-13)

Every session records the protocol version it was filmed under. This is v1. Amend, bump, never edit history.

The pipeline needs four things from every clip, in this order of importance:
1. **The rim fully visible and unoccluded in at least some frames of every clip** (calibration).
2. **The whole flight in frame**: the ball at release, the apex, and the rim. Release out of frame = no release angle (the pipeline refuses, it does not extrapolate).
3. **A phone that does not move** for the entire clip (tripod, untouched, no zoom).
4. **Ground truth you write down**: make/miss per shot, camera position measurements, shot type.

## The 10-line version

1. Tripod, **lens 1.0–1.3 m above the floor** (waist height). Not higher. Higher = the rim ellipse gets thinner = worse calibration.
2. Side view: tripod on the sideline, **7–9 m from the shot line**, opposite the midpoint between shooter and rim. Landscape.
3. Camera.app → **Slo-mo**, Settings → Camera → Record Slo-mo → **1080p at 240 fps**. 1× lens only, never zoom.
4. Frame it: shooter's feet at the bottom edge, rim in the top third, ~1 m of air above the highest arc. Then **long-press on the shooter until "AE/AF LOCK"** appears.
5. Airplane mode + Do Not Disturb. ≥ 20 GB free. Wipe the lens.
6. Start recording, say out loud: "Block [name], clip [n]". Wait 3 s with no one in frame.
7. Before every shot say the shot number; after it say **"make" or "miss"** (or "airball", "rim out", "bank"). The audio is the log.
8. 15–25 shots per clip. Stop. Don't touch the tripod between clips in the same block.
9. After each block: **tape-measure** (a) lens height, (b) tripod foot → point on the floor directly under the rim centre, (c) tripod foot → the shooter's spot. Photo of the setup.
10. Transfer by **AirDrop or cable, original quality**. Never through iMessage/WhatsApp/Google Photos compression.

## Why those numbers

Computed with the package's 1080p iPhone camera model (64° horizontal field of view, fx ≈ 1536 px; measure it in Phase 3):

| Tripod distance from the shot line | Ball diameter in pixels | Frame width × height at that distance |
|---|---|---|
| 6 m | 61 px | 7.5 × 4.2 m |
| 7 m | 52 px | 8.7 × 4.9 m |
| 8 m | 46 px | 10.0 × 5.6 m |
| 9 m | 41 px | 11.2 × 6.3 m |

Target ball size 30–80 px. A free throw needs ~6.5 m of width (shooter + 4.6 m + backboard + margin), a three needs ~8.5–9.5 m. So: **FT and mid at 7 m, threes at 8–9 m.** Tilt up slightly so the floor is at the bottom edge and there is air above the arc (apex of a three is ~4.5–5 m above the floor).

Rim ellipse axis ratio (minor/major), which must stay above 0.15 for a trustworthy calibration, versus lens height and lens-to-rim distance R:

| Lens height | R = 7 m | R = 9 m | R = 11 m |
|---|---|---|---|
| 1.0 m | 0.28 | 0.22 | 0.18 |
| 1.3 m | 0.25 | 0.19 | 0.16 |
| 1.5 m | 0.22 | 0.17 | 0.14 |
| 1.8 m | 0.18 | 0.14 | 0.11 |

**Lower is better.** A lens at 1.8 m and 9 m from the rim is already marginal. Never film from a balcony at rim height.

## Camera setup (iPhone, Camera.app)

- Settings → Camera → Record Slo-mo → **1080p at 240 fps**.
- Settings → Camera → Record Video → **Lock Camera ON**, **Lock White Balance ON** (if present on your iOS), **Auto FPS / Auto Low Light FPS OFF**.
- Settings → Camera → Formats → leave **High Efficiency** (240 fps needs it). Video HDR can stay off if the setting exists; it does not apply to Slo-mo.
- In the viewfinder: Slo-mo mode, 1×, landscape. Frame the shot, then long-press on the shooter's torso until **AE/AF LOCK** shows. Re-lock after every re-frame.
- Do not zoom, do not switch lenses, do not rotate the phone mid-block. The lens geometry is part of the calibration.
- Airplane mode, Do Not Disturb (a call ends the recording), brightness down, battery > 50 % or plugged in. Slo-mo runs hot; if the phone shows a temperature warning, stop and let it cool — the frame rate silently drops otherwise.
- Storage: ~1 GB per 5 minutes. Clear 20 GB before you go.
- Wipe the lens. Gym dust + fingerprints = blur = noisy detections.

Check the first clip before shooting 200 reps: scrub it in Photos, confirm the rim, the ball at release, and the apex are all inside the frame, and that the ball is sharp mid-flight (if it is a smear, the gym is too dark for 1/240 s — nothing to do but note it).

## Positions

All positions: tripod untouched for the whole block, rim never blocked by a person during flight, no loose balls or ball rack in frame (an orange ball on the floor is a false detection every frame), nothing orange in the background if avoidable.

**Side (most important, do first, most reps).** Tripod on the sideline side, on the line perpendicular to the shot line through its midpoint. Verify "square" with court lines: for a free throw, stand the tripod on the free-throw line extended (the lane's end line) or on a line parallel to the baseline through the midpoint. Shooting-hand side of the body facing the camera is not required, but note which side it is.

**45°.** Same distance, tripod moved along an arc so that it sits at 45° to the shot line, still centred on the midpoint. Point the lens at the midpoint. Note which side (left/right of the shooter).

**Head-on.** Tripod on the shot line **behind the shooter**, 3.5–4.5 m behind, lens as high as the tripod goes (1.5–1.8 m is fine here, the rim is far), offset 0.5–1.0 m toward the shooting-hand side so the shooting arm is not hidden by the body. The rim will be occluded by the head at release; that is expected. Record 3 s of empty frame at the start of each clip so the rim is seen clean.

Do not put the phone under or behind the basket. It gets hit.

## Blocks (priority order)

Shot type for all blocks: your normal set shot from a self-toss or a partner's pass (catch-and-shoot). Same ball all day. Note the ball size.

| # | View | Distance | Shots | Notes |
|---|---|---|---|---|
| 1 | Side | Free throw | 30 | The reference block. |
| 2 | Side | Mid (~5.5 m: elbow / FT-line extended) | 25 | |
| 3 | Side | Three (your court's line) | 30 | Tripod back to 8–9 m. |
| 4 | Side | Free throw, **deliberately varied** | 40 | 10 flat, 10 high-arc, 10 short (front rim), 10 long. Say which before each. This is the injected pattern the findings engine must find. |
| 5 | 45° | Free throw | 25 | |
| 6 | 45° | Three | 25 | |
| 7 | Head-on | Free throw | 25 | |
| 8 | Head-on | Three | 20 | |
| 9 | Side | Free throw, **simultaneous 30 fps handheld** | 25 | Second phone handheld beside the tripod at 1080p30 (not 4K, not 60, Auto FPS off, Lock Camera on). Same shots on both phones. Start both recordings, clap once in view of both. |
| 10 | Handheld only | Free throw | 25 | 10 standing still, 10 walking/shaky, 5 with the shooter cropped out (rim only). These must come out tier B / B or C / C. |
| 11 | Side | Free throw, **fatigue** (optional) | 50 straight, no rest | Last thing you do. Drift rule anchor. |

Blocks 1–4 alone make Phase 2 and Phase 3 possible. Everything after is bonus in the order listed.

If you have two phones that both do 240 fps, add a **two-phone block**: both on tripods 30 cm apart, both side view, 25 free throws. That is the reliability test (do two identical cameras agree within 1.5° on release angle?) and it is worth more than any single block after #4.

## What to write down (per block)

- Block number, view, distance, court type (HS 19'9" / NCAA 22'1¾" / FIBA 6.75 m / NBA), ball size (6 or 7), backboard type (rectangular glass / fan / other), rim type.
- Lens height above floor (m).
- Tripod foot → floor point directly under the rim centre (m). Have someone hold the tape under the rim.
- Tripod foot → shooter's spot (m).
- Which side of the shooter the camera is on (left/right), and shooting hand.
- Number of shots, number of makes, and anything that went wrong (someone walked through, ball hit the phone, clip split).
- A photo of the setup from behind the tripod.
- Player height (m). A release-height sanity check needs it.

Keep a note on the phone or paper. Say the shot numbers out loud anyway; the paper is the backup.

## Between blocks

- Stop recording, move the tripod, re-frame, re-lock exposure, 3 s of empty frame, new clip name.
- Never re-encode, trim, or "edit" the clips on the phone. Trimming in Photos re-writes the file.
- Never change the recording mode inside a block.

## Transfer

AirDrop to the Mac with "original" quality, or cable + Image Capture / Finder. Confirm on the Mac that a 10 s slo-mo clip decodes to ~2400 frames; if it shows ~300, the copy was transcoded.

Put the clips in `~/Desktop/arclab-footage/2026-09-13/<block>-<clip>.mov` with the notes as `notes.md` in the same folder.
