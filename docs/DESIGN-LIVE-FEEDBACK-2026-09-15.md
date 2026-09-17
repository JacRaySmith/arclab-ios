# Live feedback during recording (design, 2026-09-15)

Goal (lens 1 + 2): the shooter hears the number that matters a few seconds after each shot, without touching the phone.
"Seven point two, four long." The loop closes on the court, which is where a cue can change the next shot.

## How it works

1. **Arrival detection on the capture stream.** `CaptureController` already owns an `AVCaptureVideoDataOutput` for the
   rim indicator. `RimArrivalScanner`'s rule (ball-sized moving blob near the rim, preceded by a descent) runs on the
   live quarter-res crop at 60 Hz; the rim ellipse comes from the one-time automatic rim find on the preview.
2. **Ring buffer.** The last 2.6 s of frames are kept as half-res Y/Cr planes (the detector's own input) plus, for each
   frame, the 512-px full-res tile around the predicted ball when a ball is being tracked live. At 240 fps: 624 frames
   × ~1 MB half-res = too much on a phone; keep quarter-res planes (0.25 MB) → ~160 MB, and full-res tiles only where
   the live tracker has a lock (a few hundred KB per frame). Budget 300 MB, drop to every 2nd frame if exceeded.
3. **Window job.** On an arrival, the buffer's frames from −2.2 s to +0.4 s real are handed to the same window pipeline
   the session uses (`WindowFrames` built from the buffer instead of a decode), on a background queue, while recording
   continues. Result ~6–20 s later (today's per-window cost).
4. **Speak it.** `AVSpeechSynthesizer` (on device): release speed to one decimal, then cm vs the make band, then one
   word from the active plan's measure when it is off ("rushed" when dip→release is 2 SD short of the baseline). Never
   a joint angle. A gravity reject says "not measured" — no number is invented.
5. **Block card** at the end as in practice mode; the recording is also saved and re-analysed offline for the record,
   so the live numbers are provisional and the saved session is authoritative (they are the same pipeline; they differ
   only if the live buffer dropped frames — the card says so).

## Dependencies and order

- The tracker at 240 fps (in flight) and its `WindowFrames` API; the per-window cost target ≤ 3 s for feedback to
  arrive before the next shot in a normal rhythm (10–12 s between free throws).
- Thermal: live analysis at 240 fps will heat the phone; the capture side must keep 240 fps priority and the analysis
  drops to every 2nd frame when `.serious`.
- UI: `LiveSessionView` = CaptureView + a translucent strip with the last three results and a mute toggle.
