# ArcLab — possible improvements (2026-09-16)

A working list turned into a design document, not a schedule. Ordered by the three lenses
(user-friendliness, coaching, biometrics) with UI first, as asked. Each item says what the evidence is:
the phone logs (34 launches, 353 screen visits, 2026-09-14 → 16), the simulator screenshots taken today,
the source itself, or outside research (`docs/research/ui-research-2026-09-16.md`,
`docs/research/competitive-landscape-2026-09-13.md`). Effort: **S** (hours), **M** (a day), **L** (several days).

Numbering is stable: items 1–55 keep the numbers they had on the first pass, new work is numbered from 56.
Where a spec in §2 supersedes the one-line version of an item, it says so and keeps the number. Every
"Today" description below is the app as it stood at the start of this pass; implementation started while it
was being written (`TodayView`, `YouView`, `ShotFeedView`, `SessionSummaryTiles` and a four-tab
`ContentView` already exist), so check the source before treating a quoted string as current.

Three rules from `CLAUDE.md` that this document holds itself to: **no invented measurement** — every number
here is in the logs, the source, or a graded research doc, and a design opinion is labelled as one; **every
number keeps its unavailable-reason path** — a redesign that drops `releaseUnavailableReason` /
`entryAngleUnavailableReason` / `bodyUnavailableReason` is a regression, and each spec below names the reason
it must still show; **evidence grades travel with the copy** — no screen implies a learning benefit its grade
does not support (§4 rule 10).

## 0. What the logs say about how the app is actually used

| observation | number | what it means |
|---|---|---|
| screen visits: session 126, home 98, guided 57, form clip 20, doctor 20, progress 10, form 3-D 10, practice 6, learn 1, filming guide 3 | 353 | the session screen is the product; Learn and Practice are undiscovered |
| `analysis.cancel` | 30 | analysis was stopped 30 times in two days: too slow, or the user wanted to leave the screen and could not |
| the same clip imported and fully re-analysed | 3× (FT clip), 3× (form clip) | no "already analysed" path existed until yesterday; 30 min of phone time lost |
| `clip.failed` AVFoundation −11847 "Operation Interrupted" | 5 | the probe/decoder is interrupted when the app leaves the foreground or the screen locks; the user retried by hand each time |
| a 6-minute gap mid-analysis (shot 7 of 31, 01:18 → 01:46) | 1 | iOS suspended the app; analysis does not survive the screen locking |
| `rim.notFound` | 1 | the finder failed once at 0 s (ball or body over the ring); the user had to re-try at another time |
| glance card shows `Plan: speedVariability at Free throws` | every launch | a raw identifier leaks into the UI (`ContentView.progressSection`) |
| form clip saved 3× from the same recording, 39 forms each | 3 | duplicates on Progress; the fingerprint check does not cover form clips yet |
| AR body capture, single-shot tools, probe view | 0 | never opened; developer tools are in the user's way |

Read together: the only paths used are *record or import → analyse → read the session*; anything behind a
fifth row of six was never discovered. The redesign below is mostly a claim about **where things are**.

---

## 1. Information architecture

### 1.1 Today's screen graph

`ContentView` is a single `NavigationStack` around one `List`. Everything is a push; nothing is a peer.

```
ArcLab (ContentView, NavigationStack)
├─ Start  (six rows, then an 82-word footer)
│  ├─ "Practice: today's plan"            → PracticeHomeView → PracticeBlockView → CaptureView,
│  │                                        RimMarkingView, SessionView, PracticeSummaryView
│  ├─ "Record or analyze a session"       → GuidedSessionView → CaptureView, RimMarkingView,
│  │                                        EditSessionView ("you analysed this before"), SessionView →
│  │                                        ResultsView → BodyPlayerView / FormModelView
│  ├─ "Analyze a form clip (close-up…)"   → FormClipView → FormClipShotView → FormModelView
│  ├─ "Ask about your shot"               → AskView → PlanView → LearnModuleView
│  ├─ "Learn: the curriculum a coach…"    → LearnView → LearnModuleView → PracticeHomeView
│  └─ "How to film a session"             → FilmingGuideView
├─ Progress  (glance card, then two rows)
│  ├─ "Progress across sessions"          → HistoryView (title "Progress") → ProgressChartsView
│  │                                        (inline), DiagnosisView, EditSessionView
│  └─ "Diagnosis and plan"                → DiagnosisView → AskView / PlanView
└─ "Step-by-step tools" (toggle, off) → 1 · Clip → 2 · Timing and lens → 3 · Rim → 4 · Session →
   5 · One shot → 6 · Result → Tools → ProbeTrackView, ARFormCaptureView
```

Four structural facts follow from that drawing:

1. **There is no lateral movement.** Leaving a running analysis to look at last week means popping the stack,
   which tears down `SessionModel`'s in-flight work — the mechanical reason behind 30 `analysis.cancel` events.
2. **The same destination is reached three ways with three different names** — `SessionView` from the
   guided flow, from a practice block, and (as a saved session) from `HistoryView` → `EditSessionView`.
3. **The shooter's path and the developer's path share a screen.** The six step sections sit on Home behind a
   toggle whose footer reads *"The same measurements, one step at a time: timing and lens by hand, the rim,
   one chosen window, the raw Vision tracks."* That sentence is for whoever wrote the tracker; 0 shooter uses.
4. **Progress is a destination, not a surface.** The one glance card that is read on every launch sits
   below six Start rows and an 82-word footer.

### 1.2 The proposed graph

Four tabs, because the platform's floating tab bar holds 2–5 (ui-research §1.3, medium confidence, needs
a browser check of the HIG). The research doc proposes five (Today · Capture · Progress · Doctor · Learn);
this document proposes four, because Capture is a step inside Shoot rather than a place, and Doctor is
what Review is *for*. The tab set is a naming choice, not an architectural one — item 3 stands either way.

```
┌ Shoot ──────────────┐ ┌ Review ─────────────┐ ┌ Learn ──────────┐ ┌ You ──────────────┐
│ Today card          │ │ Progress (spot)     │ │ Module deck     │ │ Profile           │
│  ↳ resume / next    │ │  ↳ charts, ranges   │ │  ↳ module       │ │  height, hand     │
│ Record or import    │ │ Sessions            │ │    ↳ drill →    │ │  spot, formats    │
│  ↳ Capture          │ │  ↳ Session results  │ │      Shoot      │ │ Filming guide     │
│  ↳ Filming guide    │ │    ↳ Shot result    │ │ Filming guide   │ │ What the app did  │
│ Rim check           │ │      ↳ 3-D form     │ │  (shared)       │ │ Advanced ▸        │
│ Analysing (live)    │ │ Diagnosis           │ │                 │ │  step-by-step     │
│ Session done        │ │  ↳ Ask ↔ Plan       │ │                 │ │  probe, AR, log   │
└─────────────────────┘ └─────────────────────┘ └─────────────────┘ └───────────────────┘
        practice blocks are Shoot sessions with a plan attached, not a separate tree
```

**What moves where**

| today | tomorrow | why |
|---|---|---|
| "Record or analyze a session" (row 2 of Start) | **Shoot** tab, the primary button | 57 visits to guided; it is the product |
| "Practice: today's plan" (row 1) | **Shoot** tab — the Today card *is* today's plan when one exists | practice was opened 6 times as a separate tree; as the default content of Shoot it cannot be missed |
| "Analyze a form clip (close-up, body only, no rim)" | **Shoot** → "Film your form instead" (second option inside the record step) | it is a kind of clip, not a kind of app |
| "How to film a session" | **Shoot** (inline, before recording) and **Learn** and **You** — one view, three entry points | 3 visits; it is needed at the moment of filming, not from a menu |
| Glance card | **Shoot** Today card, top of the first screen | read every launch, currently 7th row |
| "Progress across sessions" | **Review** tab root | |
| "Diagnosis and plan", Ask, Plan | **Review** → Diagnosis (Ask is the way in) | Doctor and Progress answer the same question at two zoom levels |
| Session screen, shot screen, 3-D form | **Review**, reachable from a session *and* from the Shoot flow's done state | the same destination should have one address |
| Learn curriculum | **Learn** tab | 1 visit in two days as row 5 of 6 |
| "Step-by-step tools" (6 sections) | **You → Advanced** | 0 shooter uses |
| "Probe & Vision tracks", "AR body capture (experiment)" | **You → Advanced** | 0 uses; `arbody.start` fired only from a bench run |
| activity log | **You → "What the app did"** (item 53) | currently only readable over the wire |

**Removed from the shooter's path entirely:** the timing/lens hand-entry section (slo-mo toggle, fps
field, hFOV field), the "one chosen window" picker (`ShotPickerView`), `ProbeTrackView`,
`ARFormCaptureView`, and the `g_fit` / release-angle / entry-angle `LabeledContent` rows in section 6.
None are deleted; all move behind **You → Advanced**, which is off by default and is the only place a raw
identifier or an unformatted number is allowed to appear.

### 1.3 Rules the new shell must obey

**56. One routing type, one owner (M).** `AppRoute` (new, `App/Sources/AppRoute.swift`): destinations as an
enum with `NavigationStack(path:)` per tab, so a session opens from Shoot's done state and from Review's list
without duplicating the view tree, and a notification can deep-link into it (`SessionView` is built at three
call sites today).

**3. Tab bar instead of a stack (M).** Shoot / Review / Learn / You, with the analysis in a model owned above
the tabs (`SessionModel` is already an `@Observable` held by `ContentView`) so switching tabs does not tear it
down. The highest-value structural change: the precondition for items 8, 57 and 58, and the removal of the
reason the user cancels.

**4. Footers → "Why?" disclosures (S).** Every explanatory paragraph becomes a collapsed row with a constant
label ("Why?" / "How this is measured"): the honesty text stays available and stops being the first thing on
every screen. There are 47 `} footer:` blocks in `App/Sources`; the scan footer alone is 74 words.

**5. Kill raw identifiers (S).** `speedVariability` → `DoctorNames.hypothesis(id)` on Home; `ShotSpot`,
`InferredOutcome`, `PassCheck.measure` and `ClipSource` all reach the screen as `rawValue` today. Audit with
`grep -n "rawValue" App/Sources/*View.swift`; enforced by item 74.

**6. iOS 26 look, where the platform puts it (M).** Material navigation bars, large-title collapsing,
`.glassEffect` on the floating tab bar and the capture shutter **only** — glass is a controls layer, never a
content layer (research §1.1), so the arc overlay, rim map, charts and 3-D scene stay on opaque surfaces and
every number over a frame gets a ≥ 80 % opaque scrim. Zero custom chrome elsewhere.

**New items at a glance (56–78).** 56 routing type · 57 per-shot checkpoint · 58 auto-resume on foreground ·
59 Live Activity · 60 keep-awake wherever busy · 61 shot-result verdict header · 62 shared band/tile component
that renders value-or-reason · 63 chart range switch · 64 reps banked, no loss mechanic · 65 shared state kit
(empty / loading with ETA / error / partial), used by every spec in §2 · 66 accessibility pass · 67 outdoor
mode · 68 grounded Ask questions · 69 Learn gate rings · 70 real framing gate on capture · 71 volume-button
capture · 72 test-clip preflight · 73 environment presets · 74 copy lint · 75 navigation telemetry ·
76 Advanced behind You · 77 paused notification · 78 the "keep ArcLab open" line.

**75. Navigation telemetry (S).** The `screen` event already carries a name; add `nav.tab` (from, to, whether
analysis was running) and a `screen.dwell` field, so the next pass answers "did the tab bar stop the cancels"
with a number rather than an opinion.

---

## 2. Per-screen redesign specs

Each spec can be implemented without re-reading the rest. "Exists" means the type is in `App/Sources` or
`Packages/` today; "does not exist" names the file that would have to be written.

### 2.1 Home / Today — items 1, 2, 30, 64

**Purpose.** Answer "what do I do now" in one screen without scrolling, and show the one number the active
plan is being scored on.

**Today.** `ContentView.startSection` + `progressSection`.
- Six equal `NavigationLink` rows, each a sentence: *"Record or analyze a session"*, *"Analyze a form clip
  (close-up, body only, no rim)"*, *"Learn: the curriculum a coach teaches"*. A parenthetical spec inside a
  button is documentation, not a label.
- The Start footer is three sentences (82 words) beginning *"Practice runs a session as blocks: a spot and a
  number of shots each…"* — it is the first prose on the app's first screen.
- The glance card shows four equal-weight stats (accepted / release m/s / past front rim / inferred makes)
  with no indication which one the plan cares about, then *"Plan: speedVariability at Free throws"* — a raw
  enum case in the one sentence the user reads every launch.
- *"Step-by-step tools"* sits between the shooter's content and their history.

**Proposed layout (Shoot tab root), top to bottom.**
1. **Today card.** Headline = the active plan's measure, this shooter's own last value against their own
   baseline, with a trend arrow: `Release speed spread 0.19 m/s` (≥ 34 pt) / `target ≤ 0.13 · your baseline 0.21`.
2. **Primary button** (full width, 44 pt+): the next thing to record — `Record block 2 · 10 free throws`,
   or `Record a session` with no plan, or `Resume analysis · shot 12 of 31` when a draft exists (item 57).
3. **Secondary row**: `Use a clip from Photos` · `Film your form instead`.
4. **Last session strip**: one line, tappable — `Yesterday · free throws · 37 counted · 15 inferred makes`.
5. **Reps banked** (item 64): a 30-day dot calendar, no streak, no loss mechanic.
6. `Why?` disclosure holding the honesty paragraph that is a footer today.

**States.**
- *First run, nothing saved:* headline `No shots yet`; body `Film ten free throws from the side and ArcLab
  will measure every one.`; primary `Record a session`; no plan line at all, rather than an empty one.
- *Sessions but no plan:* headline = last session's counted shots and speed spread, then
  `No fix is being scored — ask about your shot to start one.`
- *Baseline building:* `Collecting baseline: 18 of 30 counted shots at free throws` with a determinate bar
  (the string exists in `SessionCoach`; reuse it verbatim).
- *Analysis running:* primary becomes `Analysing · shot 12 of 31 · about 4 min left`, tapping through to it.
- *Draft interrupted:* `Analysis stopped when the phone locked. 12 of 31 shots are measured.` + `Resume`.
- *Error:* `Saved sessions could not be read: <error>. Nothing was deleted.` + `Try again`.

**Data.** Exists: `SessionStore.sessions`, `SavedSession.summary` → `BlockSummary`, `store.activePlan`
(`ActivePlan`), `DoctorNames.hypothesis`, `PracticeStore` for the next block. Does not exist:
`SessionDraft` (item 57) for the resume line; a "reps banked" rollup (cheap: derive from
`store.sessions`, no new storage).

**Accessibility.** The headline number and its unit are one `accessibilityElement` with
`accessibilityLabel` "release speed spread" and `accessibilityValue` "0.19 metres per second, target 0.13
or less". Trend arrow is never the only carrier of direction — the value line says `down from 0.21`.
Dynamic Type: the card must stack (number over label) beyond the accessibility sizes rather than truncate.
Contrast: the plan band colour is paired with a printed word (`inside band` / `outside band`), never colour
alone (research §1.5).
**Success measure.** `screen` events with `name: "home"` should stop being followed by a second navigation
before any content is read — measurable as `nav.tab` (item 75) plus the ratio of home visits to
`analysis.start`. Today: 98 home visits, 57 guided visits.
**Effort** M. **Depends on** 3 (tab shell), 5 (identifier audit), 57 (draft) for the resume state.

### 2.2 Guided session — items 7, 9, 11, 12, 56, 57, 58, 59

**Purpose.** Take a shooter from "I have a clip" to "here is the session" without a decision they cannot
make, and without losing work when the phone locks.

**Today.** `GuidedSessionView`, four sections that unfold in order.
- The sections are titled *"1 · Video"*, *"2 · Rim"*, *"3 · Analysis"*, *"4 · Results"* but there is no
  stepper: earlier sections stay expanded, so the live status line ends up below three blocks of prose.
- The rim step's success state is *"Rim marked: camera 9.7 m from the ring, ellipse ratio 0.28"*. Neither
  number is actionable for a shooter, and the picture that would be — the ellipse drawn on the ring — is
  behind a push labelled *"Check the ring on the frame, or re-mark it"*.
- Analysis is one status line plus *"Last shot 7: accept — 7.21 m/s at 49°, 4 cm long"*. The session builds
  invisibly; the only way to see it is to leave, which cancels it.
- The spot is never asked here. It is asked at save time at the bottom of `SessionView`
  (*"Pick the spot first — the statistics pool per spot and never across spots."*), which is how a session
  gets analysed and then abandoned unsaved.
**Proposed layout.** A persistent 4-step stepper pinned under the navigation bar
(`Film · Spot · Ring · Analyse`), with exactly one step expanded.
1. **Film.** Two buttons — `Record now`, `Use a clip from Photos` — plus `Earlier recordings (3)`. The
   already-analysed branch stays and keeps its copy.
2. **Spot** (item 9, moved before analysis): `Where were you shooting from?` as a row of chips
   (Free throws · Elbow · Mid-range · College three · NBA three · Other). One tap, no picker wheel.
3. **Ring** (item 11): the frame thumbnail with the fitted ellipse drawn and two draggable end-point
   handles inline; buttons `Looks right` / `Adjust`. The distance and axis ratio move into `Why?`.
4. **Analyse** (item 7): a live feed — one row per shot as it finishes: number, a 40 pt sparkline of the
   fitted arc, speed, entry angle, a depth chip (`short` / `in band` / `long`), and a counted/not-counted
   dot. Above it: `Shot 12 of 31 · about 4 min left` and a tick strip along the clip timeline showing where
   shots were found (item 12). Below it: `Stop` (destructive) and nothing else.
5. **Done.** `31 shots · 24 measured · 19 counted`, the one coaching sentence, `Open the session`,
   and `Saved to free throws` — the session saves itself at the chosen spot with a 10-second `Undo`.

**States.**
- *Empty:* no clip — only the Film step, later steps dimmed but visible. *Probing:* `Reading the file…`, then
  the format line (`1920 × 1080, 240 fps in the file, 41 s of file time, lens 68°`) moved into `Why?`.
- *Loading with ETA:* scan `Finding shots… 14 s of 41 s`; analysis `Shot 12 of 31 · about 4 min left` — both
  already computed (`SessionModel.scanProgress`, `scanMessage`, the median-per-shot ETA).
- *Partial:* `19 of 31 measured · 5 could not be measured` + `Retry the 5 failed windows` (`redoFailed` exists).
- *Interrupted (new):* `Analysis paused when ArcLab went to the background. 12 of 31 measured.` + `Resume`
  (item 57). Never an error dialogue; nothing is lost.
- *Error:* rim not found → `The ring was not found in that frame — something is in front of it.` +
  `Try another frame` + `Mark it by hand`. Scan failed → the existing message + `Try the scan again`.

**Copy.** Headlines: `Film the block` · `Where were you shooting from?` · `Is this the ring?` ·
`Measuring your shots` · `Session done`. Buttons: `Record now`, `Use a clip from Photos`, `Looks right`,
`Adjust`, `Stop`, `Resume`, `Open the session`, `Undo`. Chips: `short`, `in band`, `long`, `counted`,
`not counted`. Reject reasons are two words with the sentence on tap: `gravity off`, `too few points`,
`tip-in`, `no release`.

**Data.** Exists: `SessionModel` (phase, `scanProgress`, `scanMessage`, `shots: [SessionShot]`,
`lastMeasured`, the ETA, `summary`), `SessionScanResult.windows` for the tick strip, `ShotOverlay` +
`ImageFit` for the sparkline, `RimCalibration.ellipse` for the drawn ring, `ShotSpot` for the chips.
Does not exist: a per-shot arc thumbnail renderer (`ShotSparkline.swift`), `SessionDraft` persistence,
and the auto-save-with-undo path (`SessionStore.save(session:spot:…)` exists; the call site does not).

**Accessibility.** Each feed row is one VoiceOver element: "Shot 12, counted, 7.2 metres per second at 49
degrees, 4 centimetres long". The sparkline is decorative (`accessibilityHidden`) because its content is in
the row's value. The stepper exposes `accessibilityValue` "step 3 of 4". Progress uses
`ProgressView(value:total:)` so VoiceOver announces the count, not a percentage. Gym contrast: the
counted/not-counted dot is paired with the word, and the depth chip is a word first.
**Success measure.** `analysis.cancel` per `analysis.start` falls (today 30 cancels against 34 launches);
`session.saved` per `analysis.end` rises towards 1.0; `rim.found` → `rim.calibrated` conversion without an
intervening `screen: rimMarking` visit.
**Effort** M for the flow, L including items 57–59. **Depends on** 3, 57, 11, 12.

### 2.3 Session results — items 13, 14, 16, 17, 62

**Purpose.** Say what this block was, in one instruction and three numbers, with everything else one tap away.

**Today.** `SessionView`, seven sections: Scan · Block summary · 2-D camera-side angles · Rim map · Strip
chart · Form · Shots · What this session says · How to film next time · Save.
- The block summary is nine equal rows; the three the doctor uses (release-speed SD, entry angle, depth past
  front rim) are not distinguished from `g_fit` or release height.
- The rim map — the most instantly readable thing the app produces — is section four, under a 74-word footer
  (*"A shot is a ball arriving at the rim: a ball-sized object within 2.5 diameters of the rim centre…"*).
- The coaching card (*"What this session says"*) is seventh, and its first sentence is the only thing on the
  screen that says what to do.
- Save is last and needs a `Picker` choice; leaving loses the analysis, as the scan footer admits:
  *"until then closing the app loses it."*
**Proposed layout.**
1. **One instruction** (the coaching card's first sentence, ≥ 20 pt), with `Why?` holding its numbers and n.
2. **Rim map, hero size**, one dot per counted shot, coloured by depth band, with `n` and the view class
   printed on it (item 14).
3. **Three tiles**: release speed `7.21 ± 0.19 m/s`, entry angle `46.2 ± 2.1°`, depth past front rim
   `+4 ± 9 cm`. Each tile carries the band and a printed word, and each is a doorway to its own detail.
4. **Shot strip** (existing `ShotStripChartView`), unchanged but moved up.
5. **Shots list** with the chip vocabulary from §2.2 rather than the sentence
   *"accept — gravity 9.35 within 8 %"*.
6. Disclosures, in order: `The rest of the numbers` (the other six summary rows, the 2-D camera-side
   angles, `g_fit`), `How the windows were found` (provenance), `How to film next time`, `Form`.
7. **Saved** state at the top as a quiet line, because saving happens automatically now.

**States.** *Scanning* / *analysing*: this screen is reachable mid-run; it shows the live feed instead of
the summary. *Partial*: `19 counted of 24 measured — 5 windows could not be measured` with the reasons
grouped. *Under the floor*: `Collecting baseline: 18 of 30 counted shots.` and no finding, which is the
existing honest behaviour and must survive. *Nothing fired*: keep the current sentence verbatim —
*"Nothing to work on from this block: at 22 accepted shots no rule fired, which means nothing here
separated itself from the shot-to-shot noise."* *Error*: a failed save shows `Not saved: <reason>` with
`Try again`, and the session stays on screen.

**Copy.** Tiles: `release speed`, `entry angle`, `depth past front rim`, each subtitled `± is one standard
deviation over 19 counted shots`. Chips: `counted` / `not counted` — the app says **counted** everywhere
(§4 rule 3), as `PracticeBlockView` already does.

**Data.** Exists: `BlockSummary` (every tile value with its SD and n), `CoachingCard` from `SessionCoach`,
`RimMapView`, `ShotStripChartView`, `SessionScanResult.notes`. Does not exist: a shared `BandChip` /
`TileView` component (item 62) that renders value-or-reason, so that a `nil` metric shows
`not measured — <reason>` in the same shape as a value.

**Accessibility.** Rim map gets `accessibilityLabel` "rim map, 19 counted shots" and
`accessibilityValue` "12 in band, 4 long, 3 short"; individual dots are not separate elements. Tiles are
one element each. At 300 % Dynamic Type the three tiles become three rows, and the unit never truncates
(test: `7.21 ± 0.19 m/s` at `.accessibility5`).
**Success measure.** `session.saved` within 60 s of `analysis.end`; a new `result.evidenceOpen` event
counting disclosure taps tells us whether the hidden numbers are actually wanted.
**Effort** S–M. **Depends on** 62, and on item 9 for the automatic save.

### 2.4 Shot result — items 15, 17, 50, 61

**Purpose.** Show one shot as a picture first, its verdict second, its numbers third, and its evidence fourth.

**Today.** `ResultsView` is a `ScrollView` of nine `GroupBox` cards: verdict, arc-over-frame, gravity,
metrics, pose, body, footwork, form link, rim map, quality, warnings, notes.
- It opens on a capsule reading `ACCEPT` over *"This shot is counted in the block summary."*
- The picture is second and is a single still — the release frame with the parabola drawn. No scrubber, so
  the shot cannot be watched.
- Third is `g_fit 9.48 m/s²` at title size with three sentences of explanation. `g` is the app's internal
  check (`CLAUDE.md` rule 3); at the top of a shooter's screen it is noise (item 50).
- The body link reads *"Play this shot as a 3-D body — experimental, 412 frames"*: a status word, a
  qualifier and an internal count in one button.
**Proposed layout.**
1. **Frame viewer, full width**, opening on the release frame with the fitted arc, release ring and rim
   points drawn; a scrubber across the shot's window; `Show every detection` stays as a toggle under it.
   All burnt-in text on a ≥ 80 % opaque scrim (research §1.2).
2. **Verdict strip** under the picture: `counted` chip + the one number that matters for this shot in the
   plan's measure (≥ 34 pt) + the depth chip.
3. **Three numbers**: release speed, entry angle, depth past front rim — same component as §2.3.
4. **`Why this counted`** disclosure: the gravity line, restated as `Scale check ✓ within 3 %` with
   `g_fit 9.48 m/s²` and the existing explanation inside (item 50).
5. **`The body`** disclosure: pose table, footwork card, chain order — each row keeping its
   `not measured — <reason>` path (`bodyUnavailableReason`, per-phase `why` strings, `ShooterProfile.missingReason`).
6. **`This shot in 3-D`** as a single labelled button: `Play this shot in 3-D`.
7. **`Frames and fit`** disclosure: quality, warnings, notes, the release-frame timing line.

**States.** *Loading the frame*: the existing placeholder with a spinner, plus `Loading the release frame…`.
*No frame* (clip file gone — it is a temporary copy): `The clip this shot came from is no longer on the
phone. The numbers are kept; the picture is not.` *Not measured*: the screen still renders with every tile
showing its reason. *Low confidence*: an amber chip `low confidence` with the gravity sentence promoted out
of the disclosure, because that is the one case where `g` is the shooter's business.

**Copy.** `counted` / `not counted` / `low confidence`; `Scale check ✓ within 3 %`; `Play this shot in 3-D`;
`Show every detection`. Removed: caps `ACCEPT`, `experimental`, the frame count in a button.

**Data.** Exists: `ShotResultContext` (analysis, samples, rim points, intrinsics, verdict, outcome, window),
`ShotOverlay`, `ImageFit`, `FrameLoader`, `GravityGate.explain`. Does not exist: a frame **sequence**
loader for the scrubber — `FrameLoader` fetches one frame; the scrubber needs a cached strip
(`ShotFrameStrip.swift`, decode every n-th frame of the window once, hold ~40 thumbnails).

**Accessibility.** The frame viewer is one element: "release frame, fitted arc drawn" plus the scrubber as a
standard `Slider` with `accessibilityValue` in seconds from release. Numbers ≥ 34 pt for the headline value.
Never colour alone for the verdict — the chip always contains the word.
**Success measure.** Time from opening a shot to a disclosure tap (proxy for "the picture answered it");
a fall in repeat opens of the same shot.
**Effort** M (S without the scrubber). **Depends on** `ShotFrameStrip`, 62.

### 2.5 3-D form — items 18, 19, 20, 21, 42

**Purpose.** Let the shooter see their own shape at a phase, compared with their own best, without reading a
number they did not ask for.

**Today.** Two screens do this and disagree. `FormModelView` (block mean, phase-normalised) already opens at
release (`tau = FormPhase.release.normalisedTime`), already shows the block mean by default and already has a
compare-with-an-earlier-session picker — item 18 as first written was wrong about this screen and is corrected
here; its camera is `SceneView(options: [.allowsCameraControl])`, free orbit with no presets.
`BodyPlayerView` (one shot, real frames) is the opposite: it *has* presets (`SceneBodyCamera`: side, front,
top, free) and a speed picker, but opens at `index = 0` — the first frame of the file, before the dip — and
its mean overlay is off by default. Two screens, two interaction models, two defaults, two entry points.
Neither offers the 2-D video / 3-D / split toggle that is the borrowable pattern (research §2.4). The honesty
text is correct and permanent where it should be a disclosure: *"Every joint position is this file's fitted
skeleton. The body's thickness — torso, limbs, head, hands — is a drawn proportion, not a measurement…"*
**Proposed layout.** One screen, two modes.
1. **Scene**, full width, opaque background, opening at **release** in both modes.
2. **View toggle**: `Video` · `3-D` · `Split`. Video is the clip frames (needs `ShotFrameStrip` from §2.4);
   in Split they share the scrubber.
3. **Camera chips**: `Side` `Front` `Top` `Free` — `SceneBodyCamera` promoted into `FormModelView` (item 21).
4. **Phase chips** (`set · dip · lift · release · follow-through`), already in `FormModelView`.
5. **Ghost toggle**: `Your best reps` (item 19, changed) — the research says self-model ≈ expert model
   (grade B), so the ghost is the shooter's own best reps, not the block mean and never a pro. The block
   mean stays available as a second option.
6. **Tap a joint → its angle at this phase**, with the band and the 1σ spread, dismissed by a second tap
   (item 20). No permanent numbers on the body.
7. Disclosures: `What is drawn and what is measured`, `Real durations`, `Inferred by symmetry`.

**States.** *Fewer than 3 shots in the block*: the existing line — ellipsoids unavailable, reason printed.
*Joint never seen*: dashed limb, `mirrored from the other side — no number is read off it`. *No face*:
existing reason string. *Metres unavailable*: `ShooterProfile.missingReason` with a `Add your height` button
inline (item 29). *No form for this shot*: `formUnavailableReason` shown in place of the scene.

**Copy.** `Your best reps` · `Block mean` · `Side/Front/Top/Free` · `Tap a joint for its angle`. Remove
`experimental` from entry buttons: if a thing ships it is not experimental, and if it is, it lives in
**You → Advanced**.

**Data.** Exists: `FormModel` (mean, per-joint ellipsoids, phases), `BodyShot`, `SceneBodyScene`,
`SceneBodyCamera`, `ShotForm`, the compare machinery (`form.compare` is already logged). Does not exist:
"best reps" selection (needs a rule — e.g. the counted shots nearest the shooter's own make band, n ≥ 3 —
written down before it is coded), the video/split mode, and USDZ export (item 42).

**Accessibility.** The scene already has `accessibilityLabel "A rotatable 3-D skeleton of the shooting form"`;
add `accessibilityValue` naming the phase and the largest deviation ("release, right elbow 8 degrees more
open than your best reps"), so the screen is usable without sight of it. Camera and phase chips are a
`Picker` with `.segmented` semantics, not tap targets under 44 pt.
**Success measure.** `body.player.camera` and `body.player.mean` events per form-screen visit (both exist);
`form.compare` usage rising from its current near-zero.
**Effort** M (L with video/split). **Depends on** `ShotFrameStrip`, a written best-reps rule.

### 2.6 Progress — items 13, 63, 64

**Purpose.** Show whether the thing being worked on is moving, per spot, with n attached.

**Today.** `HistoryView` (title "Progress"): doctor card, a spot `Picker`, the pooled block, an inline
`ProgressChartsView`, the pooled coaching card, the sessions list.
- Charts need two sessions at a spot — *"Charts start at two saved sessions from this spot; 3 so far."*
- No time-range control; every chart is all-time (research item 15: WHOOP's 1 w / 1 m / 6 m switch).
- The duplicate form clips (3 saves of one recording) appear as three points: `sessions(fromClip:)` filters
  with `!$0.isFormClip` and `FormClipView` never calls it (item 10).
- The spot picker is the only way to change context and it is the third element down.

**Proposed layout.** 1. Spot chips pinned at the top (not a picker). 2. The plan's measure as the first,
largest chart, with the baseline marked and the target band drawn. 3. `1 w · 1 m · 6 m · All` range chips
(item 63). 4. The other metrics as small multiples, tappable to full size. 5. Personal bests, honest:
`tightest 20-shot window`, `best session spread`, no leaderboards. 6. Sessions list, unchanged, with a
`duplicate of <date>` badge where the clip fingerprint repeats.

**States.** *No sessions*: existing copy. *One session at this spot*: show the single session's numbers as
tiles plus `One more session here and the chart starts.` *Metric missing from some sessions*: the existing
honest line (`3 of 5 saved sessions have it`). *Pooled below the floor*: `Collecting baseline: 18 of 30`.

**Data.** Exists: `PooledBlock`, `ProgressChartsView.Metric`, `SavedSession.clipFingerprint`,
`ActivePlan.baselineAcceptedShots`. Does not exist: the range filter (trivial — filter `points` by date),
the personal-best rollup, and the form-clip fingerprint check (item 10, a one-line call plus relaxing the
`!$0.isFormClip` filter for form-clip saves).

**Accessibility.** Swift Charts: give every chart an `accessibilityLabel` and per-point
`accessibilityValue` with date, value, SD and n (`MetricChart` already sets a summary label — extend it to
points). Never encode in-band/out-of-band by colour alone: the reference band is labelled `published` on
the chart, as it is today.
**Success measure.** Progress visits (10 in two days) rising, and range-chip use; `session.moved` /
`session.deleted` falling once duplicates stop being created.
**Effort** S (S+S+S). **Depends on** nothing; item 10 is independent and should ship first.

### 2.7 Ask · Diagnosis · Plan — items 24, 25, 68

**Purpose.** Turn a complaint into one scored fix, and show how that fix is going.

**Today.** Three screens, 839 lines, and the most carefully written copy in the app.
- `AskView` opens on an empty text field under *"In your own words"*; the symptom list that would unblock a
  blank field is the last section.
- `DiagnosisView` opens on a spot picker and a count line; the verdict — which channel dominates — is inside
  the chart section rather than being the headline.
- `PlanView` leads with the cue and answers the shooter's real question ("is it working?") in section five.
- All three carry honesty paragraphs that are permanently expanded, e.g. *"Shares are of the spread the three
  release channels predict, not of the makes."*
**Proposed layout.** *Ask*: three grounded question chips built from this shooter's own last session
(item 68) — `Short from three` · `My depth is all over the place` · `Flat arc at the elbow` — then the free
field, then the full symptom list behind `Or pick from the list (23)`. *Diagnosis*: headline verdict first —
`Your depth misses are mostly a speed problem` with the share and n as the subhead — then the decomposition
chart, then distance, then arc, then the misses one by one. *Plan*: `What should move` first (the measure,
the baseline, the target), `The cue` second, `The drill` third, `How it is going` fourth, honesty last.

**States.** *No match*: existing behaviour — show the list, never guess. *Below a floor*: the engine already
refuses; the screen prints which floor and how far off (`attributionFloor`, `spotFloor`, `ownMakesFloor`).
*No plan*: `No fix is being scored.` + `Ask about your shot`. *Check cannot run*: existing string —
`not enough shots to tell`, never "fail".

**Data.** Exists: `SymptomLibrary`, `ComplaintAnswer`, `Diagnosis`, `FixLibrary`, `ActivePlan`,
`DoctorNames`, the grade badges (`DoctorGradeBadge`, `DoctorVerdictChip`). Does not exist: the grounded
question generator — a small function mapping the last session's outliers to symptom ids
(`SymptomLibrary.grounded(in:)`).

**Accessibility.** Grade badges (`A`/`B`/`C`/`D`) must have `accessibilityLabel` "evidence grade B" — a
bare letter is read as a letter. Charts as in §2.6.
**Success measure.** `doctor.ask` events that end in `doctor.plan.started` (today: 2 asks, 1 plan).
**Effort** S per screen. **Depends on** 5 (identifiers), nothing else.

### 2.8 Practice home · block — items 22, 28, 32

**Purpose.** Run a session as blocks with a pass check, readable from across the court.

**Today.** `PracticeHomeView` is a `List` of plan, blocks, continue, honesty; `PracticeBlockView` runs
brief → record → analysing → card. The machinery is right; the presentation is a document: the block brief is
body text at 15–17 pt while the phone is 4–6 m away, the block card's number competes with four paragraphs,
and the wait is explained passively — *"A block's card appears a minute or two after the block, not shot by
shot: measuring one shot still takes several seconds on this phone."*

**Proposed layout.** *Home*: today's plan as one card (measure, baseline, target), the blocks as a
horizontal row of chips with state (done / now / next), `Record this block` as the primary button.
*Block*: full-bleed, high-contrast — `10 free throws` at display size, the cue as one line, a rep counter
that fills as shots are found, and the pass check as a single line when it lands. Spoken feedback toggle
visible on the screen, not in a menu (`ShotSpeaker` exists and is already logged via `speak.toggle`).

**States.** *Pre-record*: brief. *Recording*: the capture screen. *Analysing*: `Shot 7 of 10 · about 40 s left`
plus the live feed rows. *Card*: `Release speed spread 0.17 m/s · was 0.21 · 10 counted` with
`inside your band` or `outside`. *Short*: existing string — `3 more shots at this spot before the check can
run. Not a fail — not enough shots to tell.` *Un-cued block*: keep the existing sentence; it is the best
explanation of a control block in the app.

**Copy.** Per-rep surface follows bandwidth feedback (grade B, research §3.2): a tick inside the band, the
number only when outside, spoken if the toggle is on (item 32). Default on, because the evidence is about
consistency and consistency is the plan measure.

**Data.** Exists: `PracticeSession`, `PracticeStore`, `PracticeNames`, `SessionModel`, `ShotSpeaker`,
`FixLibrary` pass checks. Does not exist: the shooter's own band per measure (item 13 in the research,
item 51 here) — until it does, the band is the block's own ±1 SD and must say so.

**Accessibility.** Display-size numbers at 5 m are the accessibility feature; also support 300 % Dynamic
Type without the counter wrapping. VoiceOver: the rep counter announces changes (`accessibilityValue`),
polite not assertive, so it does not fight the speaker.
**Success measure.** `practice.block.start` → `practice.block.saved` completion rate; `speak.toggle` usage;
practice screen visits (6 in two days).
**Effort** M. **Depends on** 28 (outdoor readability), 67.

### 2.9 Learn — items 23, 69

**Purpose.** Make the graded curriculum visible and give each module a way into practice.

**Today.** `LearnView`: intro, then eight modules as rows, then honesty. One visit in two days — it is row
five of six on Home. The content is strong (each module carries its measure, its gate, its faults and their
grades); the presentation is a table of contents.

**Proposed layout.** A horizontally scrolling deck, current module first: each card carries the module number
and title, a **ring** towards its gate with `n` printed (item 69), the grade chip, and `Start the drill`.
Below it: `What the coach watches` for the current module, then the honesty disclosure.

**States.** *Nothing recorded*: existing copy — `Nothing recorded from this module yet… there is no box to
tick.` *Gate not scorable*: `One block never passes a gate on its own` (existing). *Prerequisite not met*: the
card stays readable, the gate reads `not claimable yet` with the prerequisite named — never locked.

**Data.** Exists: `Curriculum`, `LearnView.ModuleProgress`, `PracticeStore` blocks with `drillName`,
`learn.block.scored`. Does not exist: nothing — the ring is a view over data that is already computed.

**Accessibility.** The ring needs `accessibilityValue` "14 of 30 counted shots towards this module's gate".
Grade chips get spelled-out labels. The deck must be operable with VoiceOver's swipe order (use a `List` or
`LazyHStack` with proper traits, not a custom pager).
**Success measure.** Learn visits and `learn.drill.added` (1 visit, 0 drills added in two days).
**Effort** S. **Depends on** 3 (the tab).

### 2.10 Capture — items 26, 28, 70, 71, 72

**Purpose.** Get a measurable clip on the first take, from 5 m away.

**Today.** `CaptureView` is better than the research assumed: it opens straight to the preview, locks focus
and exposure on tap, shows the format line, and already runs a colour check — `rimInFrame` drives *"Orange in
the rim band"* / *"No orange in the rim band — re-aim"*. What it does not do:
- The framing guide is a drawn band with three separate instructions — *"rim inside this band"*, *"keep about
  a metre of sky above the highest arc"*, *"feet on this line"* — and the record button is enabled whether or
  not any of them is true.
- Detection is colour, not geometry: an orange bag in the band passes. `RimFinder` runs in ~30 ms and is not
  used here (item 70).
- Everything is on-screen, so the shooter walks back to the phone to start and stop (item 71), and there is
  no preflight — a bad clip is discovered after the session (item 72).
**Proposed layout.** Viewfinder full-bleed; a single **framing state** line at the top —
`Ring found · shooter in frame · ready` — with the band turning green only when both are true; the shutter
and the close button are the only glass; the format line and lock note move into a `Details` pull-down.
Below the shutter, one line: `Volume button starts and stops` (item 71).

**States.** *Setting up*: `Setting the camera up…` (exists). *Not framed*: `Ring not found — move the phone
left/right or step back` (direction from the ellipse fit where available, otherwise no direction).
*Framed*: `Ready`. *Recording*: elapsed badge (exists) plus a shot counter if the live arrival check is
cheap enough. *Permission denied*: existing screen, unchanged — it is already correct.
*Preflight* (item 72): after a 3 s test clip, `Predicted quality: B — the ring is thin in this view; move
1 m to your left` with `Record anyway` and `Try again`.

**Data.** Exists: `CaptureController` (formats, locks, `rimInFrame`), `RecordedClip` sidecar with lens and
fps, `RimFinder`, `FramingOverlay`. Does not exist: `PreflightResult` / `ClipQualityTier` (the quality tier
is computed after analysis today — the preflight needs the same rule applied to one frame plus a 3 s scan),
and volume-button capture (`AVCaptureEventInteraction`, iOS 17.2+; confirm the API name against the SDK
before relying on it).

**Accessibility.** VoiceOver users cannot see a band: the framing state must be spoken on change
(`accessibilityLabel` + `.updatesFrequently` or an explicit announcement). Outdoor: the state line is white
on a ≥ 80 % black scrim, never thin text on the preview.
**Success measure.** `capture.recorded` clips whose later analysis reaches tier A/B; `rim.notFound` per
session falling from 1 in 34 launches to 0; `preflight.result` (new) correlating with the final tier.
**Effort** M. **Depends on** `RimFinder` on the capture stream (thermal budget — measure it), 67.

### 2.11 Filming guide — items 27, 73

**Purpose.** Make the four conditions for a measurable clip obvious before the shooter films, and reachable
at the moment of filming.

**Today.** `FilmingGuideView` is 85 lines of prose: four conditions, numbered steps, then two cards for the
form clip and the behind clip. It is accurate and nobody reads it (3 visits). It gives no diagram, and the
capture screen does not link to it.

**Proposed layout.** 1. A drawn side-elevation — phone on a tripod at 4–6 m, the rim, the shooter, the arc —
with the constraints labelled on the picture rather than in sentences. 2. Three **environment preset cards**
(item 73) — outdoor daylight, indoor moderate, indoor poor — each with fps, shutter and ISO from the
KineVision protocol (research §2.7, high confidence) and a `Use these settings` button where capture can
honour them. 3. The form and behind clips as cards, keeping their existing copy. 4. `What broke last time`,
from `SessionScanResult.notes` and the existing "How to film next time" card — the guide should know what
this shooter's footage actually failed on.

**States.** *No sessions yet*: the guide without the last-time card. *Last session clean*: `Nothing in your
last clip broke the measurement.`

**Data.** Exists: the coaching card's filming advice, `SessionScanResult.notes`, `CaptureConfiguration`.
Does not exist: the diagram (a drawn `Canvas`, not an asset, so it scales and themes), and the preset →
capture-configuration binding.

**Accessibility.** The diagram needs a full `accessibilityLabel` describing the setup in words — it is
load-bearing content, not decoration. Preset cards are buttons with the numbers in their labels.
**Success measure.** Filming-guide visits from inside the Shoot flow; the tier distribution of recorded
clips.
**Effort** S (M with the capture binding). **Depends on** 2.10.

---

## 3. Analysis reliability — why the app stops, and the honest design

The largest source of lost work in the logs: 30 `analysis.cancel`, five `clip.failed` with −11847, one
six-minute gap while the phone was locked. Item 8 as first written ("move the analysis to a
`BGProcessingTask`-backed task") describes something iOS does not offer; what follows is what it does.

### 3.1 Why it stops

**1. Leaving the foreground suspends the app.** A normal app gets a short extension after backgrounding —
`UIApplication.beginBackgroundTask` buys on the order of 30 seconds (the exact figure is not contractual and
must not be designed against) — and is then suspended. A session of 31 shots at 6–20 s per shot is 3–10
minutes of work. No amount of task assertion covers that.

**2. Hardware video decode is a foreground privilege.** The analysis is decode-bound: `VideoReader` builds an
`AVAssetReader` per window and every pass (`RimArrivalScanner`, `TrajectoryTracker`, `BodyTracker`) pulls
decoded frames. When the app loses the foreground the system reclaims the hardware decode session, the
reader's `next()` fails, and AVFoundation reports **−11847** — which matches `AVError.operationInterrupted`
(confirm the symbol against the SDK header before quoting it in code). That is exactly the five `clip.failed`
events. *Confidence:* the symptom is certain, it is in our own log; the mechanism — VideoToolbox reclaiming
codec resources from non-foreground apps — is a strong inference, not a quote.

**3. `BGProcessingTask` is a deferred re-launch, not a continuation.** `BGTaskScheduler` requires the
`processing` background mode and a registered identifier; the system launches the app *later* — commonly when
the device is idle and charging — with an expiration handler, and may never run it at all on a given day. It
could finish work while the shooter sleeps; it cannot keep the current run alive while they read a message,
and the app starts fresh, so anything not on disk is gone. Whether hardware decode works inside such a task
is **untested here** — assume not until measured.

**4. A Live Activity does not grant runtime.** ActivityKit shows state on the Lock Screen and in the Dynamic
Island; it does not keep the process running. Updates come from the app while it is alive, or by push — and
push means a network call, which rule 6 forbids in the analysis path.

**5. The routes that would keep the app alive are not open to us.** The continuous background modes (audio,
location, VoIP, external accessory) do keep a process running, and using one as a keep-alive for video
analysis is the misuse App Review exists to catch; `ShotSpeaker`'s audio session is for speech during review
and must not be repurposed. No public entitlement grants an iOS app unbounded background CPU. If iOS 26 added
a longer-running processing API we have not verified it — **check before designing around it**.

### 3.2 The honest design

**57. Checkpoint per shot (M) — the foundation.** `SessionDraft` (new, `App/Sources/SessionDraftStore.swift`):
clip URL and fingerprint, time scale, intrinsics, rim calibration, the scan's windows, the chosen spot, and one
`SavedShot`-shaped record per measured shot, written after each `analysis.shot.done`. A draft is a
`SavedSession` missing its unmeasured windows, so the store types do most of the work, and one small JSON write
against a 6–20 s compute is immaterial. It also deletes the scariest sentence in the app: *"…until then
closing the app loses it."*

**58. Auto-resume on foreground (S).** On `scenePhase == .active`, if a draft has unmeasured windows,
resume automatically from the first of them and say so once: `Picking up where it stopped — shot 12 of 31.`
No dialogue, no decision. Combined with item 48 this makes −11847 invisible: a read interrupted by
backgrounding marks its window **pending**, never `failed`, and the shot is re-queued rather than surfaced
as an error.

**59. Live Activity for status (M).** Start one with the analysis — `ArcLab · shot 12 of 31 · about 4 min
left` — updated as each shot finishes, with a `Paused — open ArcLab` state written during the backgrounding
window. Honest signage for a wait visible from the Lock Screen; it is not a mechanism and must never be
described as one. Needs `ActivityKit` and a widget extension the project does not have (`App/ArcLabActivity/`).

**60. Keep awake wherever the app is busy (S).** `SessionModel.keepAwake` sets `isIdleTimerDisabled` while
scanning or analysing; `FormClipModel` does not, and the form-clip run is the longer one. Auto-lock is the
common case — the side button is not — so this alone removes most interruptions, paired with restoring the
flag on completion and on cancel (the `keepAwake` event logs both edges).

**78. Say it in one line (S).** Under the progress row: `Keep ArcLab open — measuring needs the video
decoder, which iOS only gives to the app you are looking at.` It states the mechanism and replaces a mystery
with a rule; it must not appear when nothing is running.

**77. Tell them when it pauses (S).** In the backgrounding window, schedule a local notification:
`Analysis paused at shot 12 of 31. Open ArcLab to finish.` with a deep link (item 56) back to the analysing
step. Cancel it on resume. `UNUserNotificationCenter` needs permission, asked at the first long analysis,
not at launch.

**What we cannot honestly promise.** Finishing a session while the phone is in a pocket. The only legitimate
route is an overnight `BGProcessingTask` resuming the draft — worth trying *after* 57–58 exist, when it is an
experiment rather than a rewrite. Two things must be measured before the UI claims it: whether the task is
scheduled at all on this phone, and whether `AVAssetReader` decodes inside it. Until then the app says "keep
ArcLab open" and means it.

**Gate for this section.** A 31-shot session must survive: the screen auto-locking, the user switching to
another app for two minutes, and a phone call. Measured as: `analysis.start` → `analysis.end` with
`analysis.cancel` = 0 and zero `clip.failed` in the run, repeated three times on the iPhone 14 Pro.

---

## 4. Copy and tone guide

Ten rules, each with a before/after taken from a string that is in the app today. "Before" is quoted exactly;
"after" is a proposal. Rule 5 is `CLAUDE.md` rule 1 restated for the interface and is not negotiable.

1. **The headline is the number the shooter can act on; the provenance goes behind `Why?`.**
   *Before:* `Rim marked: camera 9.7 m from the ring, ellipse ratio 0.28`
   *After:* `Ring found.` + the ellipse drawn on the frame + `Why?` → the distance and axis ratio, unchanged.
2. **Never show an identifier.** *Before:* `Plan: speedVariability at Free throws`
   *After:* `Working on: how much your release speed changes shot to shot — free throws`.
3. **One word per concept, everywhere.** Today `accepted`, `counted` and `measured` all appear for two
   different ideas. *Before:* `Save this session (24 measured, 19 accepted)`
   *After:* `24 measured · 19 counted` — **measured** = the fit ran, **counted** = it passed the block rule.
4. **One spelling, one verb.** *Before:* `Find and analyze every shot` (Home) beside `Find and analyse every
   shot` (guided) and `Analyze every shot` (session). *After:* `Measure every shot`, en-GB, in all three.
5. **A number appears with its unit and its n, or it appears as its reason.**
   *Before (good, keep):* `not measured: the body-pose stage did not run for this shot`
   *Before (bad):* an empty cell in the pose table. *After:* every empty cell renders the reason string.
6. **Say what happens next, not what the app did.** *Before:* `Saved. 19 accepted of 24 measured shots now
   count towards Free throws…` *After:* `Saved to free throws. 12 more counted shots and a finding unlocks.`
7. **One sentence of theory on screen; the rest is a disclosure.** *Before:* the 74-word scan footer
   beginning `A shot is a ball arriving at the rim: a ball-sized object within 2.5 diameters…`
   *After:* `Shots are found where a ball arrives at the ring.` + `How this works` disclosure with the
   paragraph intact.
8. **A wait shows a count and an ETA.** *Before:* `finding every shot in the clip…`
   *After:* `Finding shots… 14 s of 41 s` and `Shot 12 of 31 · about 4 min left` (both already computed).
9. **Buttons are a verb and an object, four words at most; the spec goes underneath.**
   *Before:* `Analyze a form clip (close-up, body only, no rim)`
   *After:* `Film your form` with the subtitle `Close up, body only — no rim needed`.
10. **Never claim a learning benefit the grade does not support.** Bias-corrected, external-focus cue wording
    is g = 0.01 on performance (grade C, research §3.3). *Before:* any sentence implying the cue teaches
    faster. *After:* `The cue is a way of carrying the change into the shot. What is graded is the measure.`
    — which `LearnModuleView` already says; the rule is to keep it and audit for the opposite.

**Also banned:** `experimental` as a shipped label (it belongs in **You → Advanced**), ALL-CAPS verdicts
(`ACCEPT`), internal counts in button labels, and any sentence warning the user the app will lose their work.

**74. Enforce it (S).** A test in `App/Tests` that fails on `rawValue` inside a `Text(` in
`App/Sources/*View.swift`, on `"analyze"` in user-facing strings, and on footers over 40 words. Cheap,
mechanical, and it is the only way a copy rule survives six months.

---

## 5. Coaching depth

31. **Drill picker on record (S).** Footwork evaluation infers the drill from the step pattern; an explicit
    picker (spot-up, catch-and-shoot, pull-up left/right) makes the evaluation deterministic and feeds the
    curriculum's off-the-dribble module. *How:* one chip row in the Shoot flow's spot step, stored on
    `PracticeSession.blocks` and `SavedSession`. *Needs:* the footwork footage before the inference can be
    checked against a label.
32. **Per-shot cue, not per-session (M).** With speed SD as the plan measure, say after each shot
    `0.2 faster than your mean` — only when outside the band, spoken via `ShotSpeaker`. *How:* bandwidth
    feedback (grade B) with the band = the block's own ±1 SD until item 51 lands. *Needs:* per-shot results
    streaming, which §2.2 provides.
33. **Weekly review (M).** One screen: shots this week, the plan's number against baseline, one thing next
    week. *How:* a `Review` tab section built from `store.sessions` filtered by date — no new storage.
    *Needs:* the honest-n rule (`not enough shots to tell`) wired in, and no streak mechanic (research §4).
34. **Make/miss from the ball, shown as such (S).** `15/40 inferred makes` beside `37 accepted` confuses two
    denominators. *How:* show makes over *counted* shots and label the inference: `15 of 37 counted shots
    went in (inferred from the ball at the rim)`. *Needs:* nothing new — `InferredOutcome` already carries
    its reason and strength.
35. **Distance ladder as a first-class session (M).** The versatility finding (spread widens with distance)
    needs sessions that alternate spots. *How:* a `PracticeSession` template of five blocks at five spots
    with randomised order recorded. *Needs:* the block machinery (exists) plus the template and its check.
36. **Spin (L).** Rotation rate and axis tilt from the behind clip with a taped ball; closes the
    curriculum's release module. *How:* `SpinTracker` exists in `ShotVideo` and refuses footage where the
    seams are not visible. *Needs:* the behind clip filmed, which is a user task, not a code task.

## 6. Biometrics and the 3-D model

37. **Merge the two body-pose passes (M, re-baseline).** Saves ~2 s per shot at 240 fps, but the release
    rule moves by a pixel. *How:* one `BodyTracker` pass feeding both the release detector and the form
    fit. *Needs:* re-baselining the phase timings on the 110 phone shots and accepting the shift *with
    numbers* in a phase report, per `CLAUDE.md` rule 5.
38. **Shooting-arm opening 36° vs 49° in the image (M).** Limb bones fit 2–4 % long (thigh +16 %).
    *How:* settle it on the swinging-arm synthetic first (is the floor biased?), then on the phone shots.
    *Needs:* the synthetic harness output kept alongside the phone numbers in one table.
39. **Stance width and shoulder line need a 30–45° clip (user).** Everything transverse is a prior on side-on
    footage, and the screen that shows them should say so, not only a doc.
40. **Toe/heel landmarks (L).** Vision has no foot landmarks, so foot angle is `nil` on every view.
    *How:* either a small detector on a foot crop trained on this user's footage, or ARKit body tracking
    (which has toes) when the phone is the camera. *Needs:* a decision recorded in `DECISIONS.md` — the two
    paths have different licence and accuracy stories.
41. **Mesh, not sticks (L).** A parametric body mesh with our own parameters (no third-party licence) fitted
    to the same joints gives a form the shooter recognises as themselves. *How:* bone lengths, breadth prior
    and facing already exist in `SceneBodyProportions`. *Needs:* an explicit rule that the mesh is drawn,
    never measured.
42. **Export (S).** Share a `BodyShot` JSON or a USDZ of the form from the 3-D screen (`body.export` is
    already an event name); the share sheet must say the file holds joint positions, not video.

## 7. Speed and reliability

43. Background analysis is superseded by §3 (items 57–60, 77): checkpoint, resume, signage. 44. **Smaller
decoded window (M):** 224 MB per lane is over budget for two lanes under the 320 MB cap (`SessionModel.memoryBudgetBytes`);
`VideoReader`'s `outputSize` already scales in VideoToolbox, so the win is choosing the scale per pass rather
than per clip. 45. **Fewer Core ML frames per window (M, re-baseline):** motion-gated seeding plus blob
tracking between seeds; needs a re-baseline because it changes which detections the fit sees. 46. **Compute
units A/B on the phone (S):** `.all` vs `.cpuAndNeuralEngine`, measured with `analysis.shot` stopwatch
medians and `ActivityLog.thermal()` — heat, not FLOPs, is the limit on a 31-shot session. 47. **One-pixel
tile-origin bug in `CoreMLBallDetector` (S):** fix with the re-baseline, not before, so the gate numbers move
once. 48. **Resume the reader after −11847 (S):** treat it as pending, not failed (§3.2).

## 8. Data and measurement

49. **Lens from the file, not the format table (M).** Read the intrinsics sidecar Apple writes for in-app
recordings; for Photos clips derive hFOV from the rim ellipse over ≥ 8 clean shots. *Needs:* the fallback
(which exists) promoted to default, with the provenance line already shown in `FormClipView` shown everywhere.
50. **g as a displayed confidence, not a number (S).** `Scale check ✓ within 3 %` on the shot screen,
`g_fit 9.48 m/s²` inside the disclosure; `g` stays the check it is in `TrajectoryFit`, and nothing about the
fit changes. 51. **Make band from the shooter's own makes (M).** 25–28 cm past the front rim is the
population band; after 100 shots with inferred outcomes, fit this shooter's own and label which one is in
use — every band-coloured chip in §2 depends on this eventually being real.

## 9. Ops

52. **Crash and hang reporting in the activity log (S)** — a `MetricKit` payload handler writing into the same
JSONL, so a hang during analysis is visible next to the stopwatch that preceded it. 53. **The log viewer in
the app (S)**, under **You → "What the app did"**, with a share button; `ActivityLog.tail` exists. 54.
**TestFlight build with Advanced hidden (S)** — one build setting; the tools stay in the binary for the
developer's own device. 55. **`swift test` + `swift run -c release GeometryHarness` in a pre-build script
(S)** so a phone build cannot ship a failing gate (`CLAUDE.md` rule 5).

---

## 10. Three builds

**1.2 — the shell and the wait (UI).** Ships: tab bar and routing (3, 56), Home/Today (1, 2), the guided
flow as a stepper with spot-before-clip and the ring drawn inline (7, 9, 11, 12), checkpoint + resume +
Live Activity + keep-awake + the paused notification (48, 57–60, 77), session results as instruction →
rim map → three tiles (13, 14, 16, 17, 62), the shot screen's picture-first layout (15, 50, 61), footers to
disclosures (4), the identifier audit and the copy lint (5, 74), the accessibility pass (66), outdoor mode
(67), form-clip fingerprint (10), Advanced tab (76).
*Gates:* a 31-shot session survives an auto-lock, a two-minute app switch and a phone call, three times, with
zero `analysis.cancel` and zero `clip.failed`; `session.saved` follows `analysis.end` with no manual save; no
`rawValue` reaches a `Text`; every screen readable at 300 % Dynamic Type with no truncated unit; every
metric's unavailable-reason path still renders; `swift test` and `swift run -c release GeometryHarness` pass
unchanged — a UI build must not move a measurement.

**1.3 — coaching (depth).** Ships: bandwidth per-rep feedback as the default surface (32), practice block
readable at 5 m (22, 28), weekly review (33), distance-ladder template (35), drill picker (31), Ask's grounded
questions (24, 68), Diagnosis verdict-first (25), Learn deck with gate rings (23, 69), makes over counted
shots (34), the shooter's own make band (51).
*Gates:* the plan's measure is computed identically before and after (no silent redefinition); every new
sentence carries its n and its grade; a block under the floor says `not enough shots to tell`, never a fail;
no streak with a loss mechanic ships (research §4); evidence grades stay visible where they are quoted.

**1.4 — biometrics.** Ships: merged pose pass with a published re-baseline (37), the 3-D screen unified with
video/3-D/split and camera chips (18–21), ghost of the shooter's own best reps (19), angles on tap (20), the
arm-opening question settled (38), the foot-landmark decision recorded (40), export (42), and a mesh spike
(41) that ships only if it is honest about being drawn.
*Gates:* the re-baseline is a `docs/PHASE<N>-REPORT.md` with before/after numbers on the 110 phone shots, not
a claim; no metric gains a number where it previously had a reason; `Packages/ShotGeometry` still depends on
Foundation and simd only; nothing on the 3-D screen is quotable unless the file computed it.

---

## 11. What the outside research adds

From `docs/research/ui-research-2026-09-16.md`, with its grades:

- **Bandwidth feedback (grade B)** is the one motor-learning result that maps onto ArcLab's bands: a number
  only outside the shooter's own band, and the outcome it supports is *consistency*, the plan measure.
  Items 7, 22 and 32 adopt it; default on.
- **Do not build faded feedback schedules** — the 2022 meta-analysis of reduced frequency is null. The
  defensible quiet default is *learner-pulled* feedback (grade B): a tick per rep, the number one tap away.
- **External-focus wording is weaker than coaching literature says** (g ≈ 0.15 retention after bias
  correction, grade C). Keep cues external because they are checkable; delete copy claiming faster learning.
- **Self-model ≈ expert model (grade B)** — item 19's ghost is the shooter's own best reps. No licensed footage.
- **"Fewer numbers" has no sport-science support (grade D)**, strong as a usability claim. Items 13, 17 and
  25 are readability decisions and say so in their `Why?` text.
- **Sportsbox 3D Golf is the pattern set** for the form screen: 2-D / 3-D / split, free rotation, two-rep
  compare, per-metric target zones with instant hit/miss (§2.5 adopts the structure, not the pro overlay).
- **Legibility over footage:** a ≥ 80 % opaque scrim behind every number over a clip or the 3-D scene; glass
  on controls and navigation only (§1.3 item 6).
- **iOS 26 navigation** is a 2–5 tab floating bar; the research proposes five tabs, this document proposes
  four. Item 3 stands either way.
- **A test-clip preflight** (3 s, inspect paused frames, predict the tier) is the capture-heavy pattern —
  item 72 in §2.10.
- **Confidence caveat, carried forward:** Apple's HIG pages did not render for the fetch tool, so every iOS 26
  platform claim here is secondary-sourced (medium confidence) and should be checked in a browser first. The
  same applies to §3's background rules: documented behaviour and our own logs, not a HIG page fetched today.

Verified in code while writing this pass: the raw `speedVariability` identifier is on Home
(`ContentView.progressSection`); `FormClipView`/`FormClipModel` never call `SessionStore.sessions(fromClip:)`,
which itself filters with `!$0.isFormClip`, so form clips duplicate twice over; `SessionModel` sets
`isIdleTimerDisabled` while busy and `FormClipModel` does not; `FormModelView` opens at release with the block
mean on but has free orbit only, while `BodyPlayerView` has camera presets and opens at frame 0 (items 18 and
21 corrected in §2.5); `CaptureView` already opens on the viewfinder and already checks for orange in the rim
band, so item 26 is a geometry upgrade, not a new feature.
