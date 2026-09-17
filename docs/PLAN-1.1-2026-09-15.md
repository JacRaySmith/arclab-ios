# ArcLab 1.1 — plan (2026-09-15)

ArcLab 1.0 is what is on the phone as of 14:20 PT 2026-09-15 (see HANDOFF.md, same date). 1.1 has three tracks. Each
ships behind the same honesty line as 1.0: no fabricated numbers, `nil` with a reason, evidence grades on coaching claims.

## Track A — the 3-D model: a head you can read, depth you can trust

User's words: "the head is messed up. it should [be drawn] in such a way that the head is obvious. the tracking seems
somewhat flat and inaccurate."

1. **Head.** Draw a head that reads as a head: skull ellipsoid seated on the neck (not a ball floating past the nose),
   a face side marked by nose + eye marks driven by the measured 2-D facing cues (`HeadCues`: yaw/pitch/noseOffset), a
   chin line so up is obvious. When the facing cue is unavailable the face is not drawn and the legend says why.
   Same treatment in both viewers (`FormModelView` skeleton and `SceneBody` body).
2. **Flatness.** The monocular skeleton fit initialises every joint at the body depth and only takes the depth *sign*
   from Vision's 3-D body. Measure how flat the fitted shots are (per-phase depth range of the elbows/wrists/knees vs the
   sagittal excursion a shot must have, e.g. the shooting elbow travels forward ~0.2–0.3 stature from set to release),
   then improve: use Vision's 3-D joint *placement* as a weak prior (not just sign), add bone-symmetry (left = right
   lengths), a depth smoothness term at the shot's own tempo, and the rim-ruler scale when the shooter is at rim depth.
   Report before/after on ≥ 30 of the 110 phone shots in `scratchpad/phone2/body` (reprojection RMS, bone constancy,
   sagittal elbow excursion, knee flexion range at the dip/set).
3. Deliverables: code + tests, `docs/PHASE2-PREP.md` section "3-D model 1.1", one PNG strip (front + side, six phases).

## Track B — depth of knowledge: coach like an NBA shooting coach teaches

User's words: "This should train you like an NBA shooting coach would teach you."

1. A **curriculum**, not a list of fixes: base → footwork/balance → dip and rhythm → guide hand → release and
   follow-through → range → off-the-dribble → game speed. Each module: what the coach watches, the cue they say
   (external focus, one sentence), the drill with reps and constraint, what "done" looks like measurably in ArcLab
   terms, the common faults and how they show in ArcLab's numbers. Grades A–D per claim, sources listed.
2. Wire it in: `Curriculum` in ShotGeometry (modules, lessons, drills, prerequisites), a **Learn** screen (read a
   module, see the drill, start it as a practice block), and the shot doctor's plans point at modules.
3. Deliverable: `docs/research/shooting-curriculum-2026-09-15.md`, code + tests, screen wired from Home.

## Track C — economy of movement: footwork and the gather

User's words: "if I was shooting off the dribble in a drill (which should be able to be recommended long term) then it
should be able to tell me if I'm stepping wrong."

1. **Footwork metrics** from the body timeline: foot contacts (ankle/heel/toe vertical velocity → ground contacts),
   step count and order before the lift (1-2 step vs hop, inside/outside foot first), stance width and stagger at
   the set, foot angle vs the rim bearing, time from last contact to release (the gather), lateral drift of the hips
   from last contact to release, and the jump's vertical vs forward travel. Everything `nil` with a reason when the
   view cannot see it (a side view cannot see foot angle; say so).
2. **Evaluation**: "stepping wrong" defined per drill (e.g. off-the-dribble right-hand pull-up for a right-handed
   shooter: inside foot plants first, hips square by the set, gather ≤ 0.35 s, no lateral drift > 0.1 stature).
   Evidence-graded; folklore is labelled.
3. **Drills**: a drill catalogue with what to film (camera position, distance) and what ArcLab will measure, so the
   app can recommend off-the-dribble work long term. No off-the-dribble footage exists yet — build and test the
   metrics on the catch/free-throw timelines we have, and write the filming request for the user.
4. Deliverable: `FootworkMetrics` in ShotGeometry + tests, a `Footwork` card in results, `docs/DESIGN-FOOTWORK-2026-09-15.md`.

## Rules for this cycle
- CLAUDE.md rules stand. ShotGeometry stays Foundation + simd only.
- Every metric has a unit, a provenance and an unavailable reason.
- Agents write their own tests and run `swift test` in ShotGeometry before reporting; the app must build.
