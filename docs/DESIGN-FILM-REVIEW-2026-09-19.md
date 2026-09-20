# Game film review — design note, 2026-09-19 (1.4)

The ask was: *"Upload your own game footage, have possessions auto-tagged, and review your decisions
('you passed up an open three here')."*

The first half of that is buildable today. The second half — **auto-tagged possessions and automatic
reads** — is not, on this device, in this codebase, this year. This note says what v1 actually does,
what auto-tagging would need part by part, which of those parts the current pipeline could supply,
which Apple APIs are *verified* to exist for the rest, what the licence position is, and where the
accuracy would come apart. Nothing below is a promise.

---

## 1. What v1 does

`App/Sources/Film/` — `FilmStore.swift`, `FilmModel.swift`, `FilmReviewView.swift`,
`FilmReviewEntryCard.swift`.

1. **Import.** A clip from Photos through the existing `ClipImporter` (PhotoKit original resource
   first, so a slo-mo file is not silently handed over as a 30 fps composition). Any frame rate, any
   length — the review path has no frame-rate requirement at all, unlike the shot analysis.
2. **Play and scrub.** `AVPlayer` in an `AVKit` `VideoPlayer`, with a scrub strip
   (`FilmTimelineStrip`) that carries two kinds of mark: candidates the app found (orange) and tags
   the person made (blue). ±1 s nudge buttons and a play/pause.
3. **Assisted markers — the one thing the app finds on its own.** Where the rim is in view and the
   person has marked it once (`RimMarkingView`, reused unchanged, on the existing `AnalysisModel`),
   `SessionScanner.run` sweeps the clip and returns arrival windows. Each becomes a **shot
   candidate** on the timeline: a place to scrub to, labelled as a candidate everywhere it appears,
   with the count found and the caveat attached to it. If the rim is not marked, the screen says the
   timeline has no candidates and why — it does not quietly show an empty list.
4. **Manual possession tagging.** Sticky pickers for *who* (me / a teammate) and *where from* (not
   said / inside / three), a "possession starts here" flag, six big decision buttons — open shot,
   contested shot, pass, drive, passed up an open shot, turnover — and an "ends here". One tap on a
   decision writes a tag at the current playhead. Notes are optional and added afterwards.
5. **Review.** The person's own tags rendered as lines — `3:12 — You passed up an open three` — plus
   counts per decision with the n they came from, and a per-film summary paragraph that names n and
   states whose judgement the lines are. Teammate tags are listed separately and never mixed into the
   counts for the shooter's own reads.
6. **Persistence.** `FilmStore` writes `film.json` beside `practice.json` and `sessions.json`. The
   clip itself lives in the temp directory, which iOS may empty; the tags are written to survive
   without it, and the screen says when the video has gone rather than showing a broken player.
7. **Log.** `film.imported`, `film.candidates`, `film.tag`, `film.review.shown`.

### What v1 explicitly does not do

It does not know who has the ball. It does not know who is open. It does not know which team anyone
is on, where the court is, or when a possession changed hands. It never says a decision was right or
wrong. Every review line is the person's own tag, and the screen says so in the summary, in the
footers and in the entry card.

---

## 2. What auto-tagging would need, part by part

| Part | What it has to do | State in this codebase |
|---|---|---|
| **Player detection** | Find every person in every frame, 5–10 of them, at 20–40 m, ~80–200 px tall | Nothing. The shot pipeline finds *one* person and is told which one by a ball seed. |
| **Player tracking / re-identification** | Keep an identity across occlusions, crossings, and a camera pan; know which one is "me" | Nothing. `BodyTracker` tracks a crop, not an identity, and drops to a whole-frame reacquire after 2 misses. |
| **Court registration (homography)** | Map image pixels to court coordinates so "three" and "open" mean something measurable | Nothing. `RimCalibration` fits the rim ellipse and calibrates the *shot plane* only; it is a one-object calibration, not a court model. `ShooterProfile` records the measured refusal to use the rim as a ruler away from the rim's own depth (implied standing heights of 2.30 / 2.29 / 1.24 m on the three labelled windows). |
| **Ball possession attribution** | Decide who has the ball at each instant, and when a pass completes | Nothing. `BallDetector` / `CoreMLBallDetector` find the ball; nothing attributes it. |
| **Shot detection** | Know a shot was taken and when | **Partly available** — see §3. |
| **Shot outcome (make/miss)** | Know whether it went in | **Partly available** — see §3. |
| **"Open"** | A distance-to-nearest-defender threshold, in metres, on a court plane, with the defender's team known | Needs all four of the above at once. This is the hardest label in the list and the one the user's example sentence rests on. |

The chain matters more than the parts. "You passed up an open three" needs, simultaneously: the right
player identified as "you", the ball attributed to you, your feet located behind a court-registered
three-point line, every other player located and assigned to a team, the nearest opponent's distance
in metres, and the judgement that you *could* have shot. Each link is a probability, and they
multiply. Four links at 90 % is 66 %; one wrong label in three is a coach the player stops trusting.

---

## 3. What the current pipeline could supply

Two parts, and only with the rim in view and marked.

- **Shot detection.** `SessionScanner` (`.fast` mode → `RimArrivalScanner`) is a ported version of
  `tools/pytrack/session.py`'s `find_arrivals`: a ball-sized candidate within 2.5 diameters of the
  rim centre, moving down, preceded within 1.5 real seconds by at least six ball-sized candidates
  high in the frame, at most one arrival per 3 s. This is what v1 already uses for its candidates.
  Recorded evidence: on `footage/2026-09-13/IMG_1765.mov` the fast scanner and Vision's
  `DetectTrajectoriesRequest` each found **30 arrivals, 28 of which agreed within 0.1 s** (the other
  two were the same two shots, seen 0.6 real seconds later) — `docs/HANDOFF.md`, "Speed, 2026-09-14",
  whole-clip row. That is scanner-against-scanner agreement on tripod practice footage: **not** recall
  against a hand-labelled ground truth, and **not** on game film. Recall on game film is UNMEASURED.
- **Make / miss.** `ShotGeometry/MakeModel.swift` has `MakeGeometry.cleanPass` — exact geometry for
  whether the swept ball misses the ring entirely — and a parametric `SoftMakeModel` whose parameters
  must be fitted from tagged outcomes. The file's own comment is the honest one: clean-pass is a
  *lower bound* on makes (simulation 2026-09-13: ~12 % clean passes against ~45 % makes at a 16 cm
  depth SD), so it must never be presented as an expected-FG number. Both need a rim calibration and
  a fitted trajectory, which means a static camera and a ball track — which is practice footage, not
  a game.

Both break on the things game film does: the camera pans, the rim leaves the frame, the far basket
is at the other end, bodies occlude the ball, and the ball spends most of the clip nowhere near a
rim. `DetectTrajectoriesRequest` is recorded in `docs/DECISIONS.md` as needing a **stationary
camera**, and the fast scanner's running background model assumes the same.

---

## 4. Apple APIs that exist for the rest

Only names **verified in `docs/reference/sdk-and-licensing-research-2026-09-12.md`** are listed. No
API is named here that the research file does not record; where something would be needed and is not
recorded, this note says so rather than inventing a symbol.

- `DetectHumanBodyPoseRequest` (iOS 18) → **`[HumanBodyPoseObservation]`** — an *array*, so it is
  already a multi-person request. 19 joints per person via
  `HumanBodyPoseObservation.JointName`. Config: `detectsHands`, `supportedJointNames`,
  `supportedJointsGroupNames`; `.revision2` only.
- `DetectHumanBodyPose3DRequest` (iOS 18) → `HumanBodyPose3DObservation` — 17 joints, a
  `StatefulRequest`, and it carries `bodyHeight` / `heightEstimationTechnique`. Measured cost in this
  repo makes it a poor fit for many people at once: it was about a quarter of the body stage for one
  person, which is why `BodyTracker.Options.everyNthFrame3D` defaults to 2.
- `DetectTrajectoriesRequest` (iOS 18) — a `StatefulRequest` with `frameAnalysisSpacing`; the
  zero-model baseline for the ball, and stationary-camera only.
- `DetectHumanHandPoseRequest` — not relevant here.

**Not verified in this repo, so not designed against:** a person/object *rectangle* detector, any
per-object tracking request, and anything for image registration or homography. The research file has
none of them under those or any other names. Before any of that is planned, the API surface has to be
checked in the SDK and written into the research file, per CLAUDE.md's rule about where knowledge
lives.

The practical consequence: multi-person *pose* is available for free and would give per-player
positions frame by frame, but **identity across frames is not** — pose observations come back
unordered and unlabelled, so tracking, re-identification and "which one is me" would all have to be
built on top, from scratch.

---

## 5. Licence position (already recorded in `docs/DECISIONS.md`)

- **Ultralytics YOLO v8/11 — AGPL-3.0, excluded.** Confirmed incompatible with a closed-source app.
- **YOLO-NAS — weights non-commercial, excluded.**
- **RT-DETR / RF-DETR / YOLOX / DETR fine-tunes — Apache-2.0, viable**, and the realistic route if a
  player detector is ever trained.
- **Create ML transfer learning — output model is the developer's**; the Xcode SLA has no clause
  restricting it. Needs labelled footage.
- **Datasets:** several Roboflow basketball sets are CC BY 4.0 / MIT (re-check each page before use);
  **SportsMOT is CC BY-NC 4.0 — not usable.** SportsMOT is the obvious multi-player basketball
  tracking benchmark, and it being non-commercial is a real obstacle: training a tracker would mean
  labelling footage by hand or finding a permissive set.
- The existing foot model (`ArcLabFootModel.mlmodelc`) is the standing example of the trap: Apache-2.0
  code and weights, but annotations (AlphaPose / Halpe / COCO-WholeBody) that are research-only, so it
  is off by default and **must not ship in a commercial build**. Any player detector trained on
  someone else's annotations inherits the same question.

---

## 6. Honest accuracy risks

- **Error multiplies down the chain.** §2. A decision label is the product of five or six uncertain
  labels, and the failure mode is a confident wrong sentence, which is worse than no sentence.
- **Scale.** Players are 80–200 px tall on a baseline-corner phone clip. Vision's body pose already
  needed a tracked crop to work on *one* person at 500 px in this repo; at a quarter of that, on ten
  people, with no crop to give any of them, expect a large drop and no way to know which detections
  are wrong.
- **Occlusion and crossing.** Basketball is people passing in front of each other. Without
  re-identification, identities swap at every crossing, and an identity swap turns "you passed up an
  open three" into an accusation about the wrong player.
- **Camera motion.** Everything the ball pipeline does assumes a static camera. Game film is panned,
  usually handheld, often zoomed. Court registration would have to be re-solved per frame, and the
  rim scanner's background model simply stops working.
- **"Open" has no ground truth.** There is no measurement that makes a shot open; there is a
  threshold someone chooses (nearest defender in metres) and a contest that does not fit it — a
  closeout in flight, a help defender two steps away. Even with perfect tracking this label would be
  a convention presented as a fact.
- **Team assignment** needs jersey colour, which fails on similar kits, in bad light, and on a white
  home team against a grey floor.
- **Cost.** Multi-person pose on every frame of a 40-minute game is not a phone workload. Even
  heavily decimated, the analysis would be tens of minutes of thermal-throttled phone time for one
  game, against ~12 s for one shot window today.

---

## 7. If this is picked up again, the order that makes sense

Each step is useful on its own and none of them promises the next one.

1. **Make the manual path fast.** Keyboard-free, one-thumb, undo, and jump-to-next-candidate. Most of
   the value of film review is the watching; the app's job is to not get in the way. (v1 is this.)
2. **Better candidates, still rim-only.** Let the person mark the rim more than once so a clip with
   two baskets or one camera move still produces candidates, and measure recall against a
   hand-labelled game clip — the number that is currently UNMEASURED is the first thing to fix.
3. **Make/miss on candidates**, where the rim is calibrated and the camera did not move, presented as
   the lower bound it is.
4. **Multi-person pose as a scrub aid only** — e.g. "how many people are in the paint here" — with no
   identity claim attached. This is the first honest use of `[HumanBodyPoseObservation]`.
5. **Identity, court registration, possession.** Only with a dataset that can be licensed and a
   measured error budget per link, and only if the product of those links is good enough to put a
   sentence in front of a player. If it is not, the manual path stays, and that is a fine answer.
