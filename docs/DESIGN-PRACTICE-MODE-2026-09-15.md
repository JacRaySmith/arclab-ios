# Practice mode — progressive training with immediate feedback (design, 2026-09-15)

The lens: an elite coach runs a session, not a video review. The app already measures every shot from a clip; practice
mode turns that into a guided session with a plan, blocks, and feedback close to the shot.

## The loop the shooter experiences

1. **Today's plan** (home): built from the active plan (shot doctor) or, without one, a baseline block. Blocks: warm-up
   baseline (10 shots at the plan's spot), the drill block(s) (e.g. distance ladder 5 × 16: free throw → elbow → mid →
   college three → three), a retention block (10 shots at the plan's spot, un-cued). Each block states its pass check.
2. **Record a block** in the app (240 fps, exact lens, rim found automatically once per tripod position). The scanner
   runs on the recording as soon as it stops; analysis streams shot by shot with the feedback line
   ("Shot 7: 7.21 m/s at 49°, 4 cm long of the make band"). A spot is attached per block, never defaulted.
3. **Block card** when the block's shots are in: the block's number that matters (the plan's measure, e.g. release-speed
   SD), pass/fail against the plan with n, and one cue for the next block. Under n, it says "n more shots".
4. **Session close**: the session saves itself per block/spot (no save button to forget), the plan advances (baseline
   recorded → follow-up → retention), and Progress shows the trend.

## Coaching mechanics (evidence-graded, from healthy-shot-model-2026-09-14.md)

- The measure per plan is fixed by the fix package (FixLibrary): speed SD for consistency and range; entry angle for flat
  arc; crossing bias for long/short; dip→release SD for rhythm; extension-peak order for the chain (once trusted).
- Cues are external-focus, one sentence; the app never shows a joint-angle target to the shooter mid-session.
- Progression: a block passes when its check passes at n ≥ the block size; the next difficulty (distance, tempo,
  constraint) unlocks only after a pass AND a retention pass in a later session ("practised, not learned" otherwise).
- Variability of practice: the distance ladder alternates spots; the app can randomise block order and record it.

## Data and state

- `PracticeSession` { date, plan id, blocks: [ { spot, intended n, recording id, sessionID (saved), check result } ] }
  persisted next to sessions.json; each block is a normal SavedSession with `blockOf` set, so pooling and the doctor
  keep working.
- Feedback latency: the per-shot pipeline (currently 6–20 s/shot on the phone) runs during recording of the next block;
  a block's card appears ~1–3 min after the block. True per-shot live feedback needs the fast tracker at ≤ 3 s/shot and
  the scanner running on the capture stream — the next speed target.

## Screens (SwiftUI)

- `PracticeHomeView` (Today's plan), `PracticeBlockView` (record → analysing → block card), `PracticeSummaryView`.
- Reuses CaptureView (onRecorded), SessionModel (scan/analyse), SessionStore (auto-save with spot), ShotDoctorModel
  (plan, check, retention), FormModelView (form of the block vs the shooter's model).

## Order of work

1. Auto-save per block with spot; PracticeSession store; Today's plan from the active plan (or baseline).
2. Block card with the plan's measure and pass/fail; feedback line during analysis (done in GuidedSessionView).
3. Progression and randomised order; retention gating.
4. Live feedback when the per-shot pipeline is under 3 s.
