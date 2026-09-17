# UI research — how the best training apps present feedback, and what ArcLab should change — 2026-09-16

Scope: the *interface*, not the measurement. What Apple's current platform guidance asks for on iOS 26,
what comparable motion-analysis products actually do screen by screen, what the motor-learning
literature says about *delivering* feedback (frequency, banding, wording, modality, video), which
retention mechanics are honest, and a ranked backlog for ArcLab's existing screens.

**Builds on, does not repeat,** `docs/research/competitive-landscape-2026-09-13.md` — especially its
§"Presentation patterns that make feedback obvious" (13 patterns: one number per rep, target as a
band, SD-as-consistency, spread→inches, rim map, three-tier disclosure, one colour vocabulary,
baseline windows, personal records, goal-hit ticks, before/after overlay, learner-pulled feedback,
no unexplained scores) and its §"Ranked product ideas". Those are taken as decided. Everything below
is new ground: platform-level guidance, screen architecture, the feedback-delivery evidence, and
engagement mechanics.

## 0. How to read this

- **Confidence** (high / medium / low) = how sure we are the claim is true of the world, given the
  sources reachable this session.
- **Grade A–D** = ArcLab's evidence scale (`healthy-shot-model-2026-09-14.md` §0), applied only to
  §3's motor-learning claims: **A** peer-reviewed on skilled performers / large-n / exact geometry ·
  **B** peer-reviewed, small n or indirect · **C** consensus with a rationale, no controlled
  measurement · **D** opinion, vendor marketing, or an untested in-house hypothesis.

**Source caveat (important).** Apple's Human Interface Guidelines pages are client-rendered; the
fetch tool returned only page titles for `/liquid-glass` (404 on the direct path), `/charts` and
`/accessibility`. Every HIG claim below is therefore sourced to a **secondary** summary and marked
*medium* confidence at best. Before implementing anything in §1, open the HIG pages in a browser and
confirm. NN/g's Liquid Glass article fetched only partially; WHOOP's home-screen post returned 403
(its content below comes from search snippets of the same post).

---

## 1. Apple platform guidance (iOS 26) — what ArcLab should adopt

### 1.1 Liquid Glass is a controls-and-navigation layer, never a content layer
Apple's guidance places Liquid Glass on "a functional layer for controls and navigation that sits
above the content layer"; it is explicitly *not* applied to content layers like lists, tables, media,
full-screen backgrounds or scrollable content, and glass should not be stacked on glass.
(medium — secondary: https://www.rvsmedia.co.uk/blog/designing-for-ios-26-liquid-glass-ui-updates/ ·
https://www.learnui.design/blog/ios-design-guidelines-templates.html)
*ArcLab:* glass on the tab bar, the capture shutter/close buttons and pull-down menus only. The arc
overlay, the rim map, the 3-D avatar and every chart stay on opaque content surfaces.

### 1.2 Anything over video or camera must be readable first, pretty second
NN/g's critique of iOS 26: "anything placed on top of something else becomes harder to see", text on
top of images is "a bad idea", and controls have been crammed together against "the long-standing
guideline of at least 0.4 cm between targets (and 1 cm × 1 cm tap areas)"; motion for its own sake is
"distraction with a side of nausea", and collapsing navigation costs predictability.
(high — https://www.nngroup.com/articles/liquid-glass/)
*ArcLab:* numbers burned over a clip (entry angle, release angle, tier) get a solid or ≥80 %-opaque
scrim, not glass. Keep the 4.5:1 contrast floor for text over any frame
(medium — https://www.rvsmedia.co.uk/blog/designing-for-ios-26-liquid-glass-ui-updates/). Never
auto-collapse the controls the player needs mid-review.

### 1.3 Navigation: a floating tab bar, 2–5 tabs
The iOS 26 tab bar is the primary navigation pattern — floating, centred, pill-shaped, 21 pt inset —
holding 2–5 tabs with a "More" catch-all beyond that; sheets slide from the bottom over dimmed,
still-visible content. (medium — https://www.learnui.design/blog/ios-design-guidelines-templates.html)
*ArcLab:* `ContentView` is currently one `List` with `startSection`, `progressSection` and a
"Step-by-step tools" toggle that reveals six more sections. That is a debug console, not a task app.
Five tabs (Today · Capture · Progress · Doctor · Learn) with the step-by-step tools moved to
Settings is the shape the platform expects.

### 1.4 Type, targets, and reading a phone on a court
Standard iOS sizes: 34 pt bold large title, 17 pt semibold compact title, 17 pt body, 15 pt
secondary, 13 pt tertiary, 11 pt tab labels (the floor); 44 × 44 pt minimum tap target, with inline
text links the only exception. (medium — https://www.learnui.design/blog/ios-design-guidelines-templates.html)
Standard accessibility expectations for an outdoor app: 4.5:1 contrast for normal text, 3:1 for large
text, Dynamic Type support, `accessibilityLabel`/`accessibilityValue` on custom visualisations, and
respect for Reduce Motion / Reduce Transparency. (medium — model-summarised from the unfetchable HIG
accessibility page: https://developer.apple.com/design/human-interface-guidelines/accessibility ·
treat the exact ratios as WCAG-standard rather than as verified Apple quotes)
*ArcLab:* nothing load-bearing at 13 pt. The one number per rep should be ≥34 pt. A shot result must
survive 300 % Dynamic Type without truncating the unit. A high-contrast/outdoor toggle (black on
white, no glass, maximum brightness while capturing) is cheap and is the difference between a usable
and a useless screen in sun.

### 1.5 Charts
Not verified this session (HIG `/charts` returned only its title). Carry forward as *design intent*,
low confidence: Swift Charts supports VoiceOver chart descriptors and audio graphs; never encode
make/miss or in-band/out-of-band by colour alone — pair colour with shape and a printed label, which
ArcLab already needs for sunlight legibility anyway.

### 1.6 Capture UX
Apple's Camera Control guidance (iPhone 16+) expects an app to "provide people with a camera
viewfinder as soon as possible after launch", and the hardware affordances include volume-up to
capture and press-and-hold to record video.
(medium — https://developer.apple.com/design/human-interface-guidelines/camera-control ·
https://developer.apple.com/videos/play/wwdc2025/253/)
*ArcLab:* `CaptureView` should show the preview before any permission copy or setup wizard; support
volume-button start/stop (the player is 5 m away from a tripod-mounted phone, so every on-screen
control is a walk); lock exposure and white balance once framing is confirmed, since auto-exposure
drift is a tracking hazard as well as a UI one.

---

## 2. Screen-level patterns from comparable products

### 2.1 Home structure
WHOOP's redesign "reorganized the home screen to highlight key stats and trends", with a one-tap
switch between 1-week / 1-month / 6-month trends per metric, plus shortcuts and inline coaching tips;
its Weekly Plan ships **three preset plans** built around "the most impactful and attainable goals",
each a single focus. (medium — https://www.whoop.com/us/en/thelocker/the-all-new-whoop-home-screen/ ·
https://www.whoop.com/us/en/thelocker/set-and-reach-your-goals-with-weekly-plan/ — both via search
snippets; the first 403s to the fetch tool)
*Pattern:* home answers "what do I do now", then "how am I trending", then everything else. Presets
beat a configurator.

### 2.2 A single rep's result in ≤ 2 seconds
Sportsbox lets a player set **target zones** per metric in training mode and "after each swing the
system instantly tells you whether you hit your goal", with a one-line plain-language verdict ("Get
to Your Lead Side at Impact. Your body is not shifting over to your lead side").
(high — https://golficity.com/sportsbox-ai-review-turn-your-phone-into-a-3d-golf-coach/ ·
https://www.golflink.com/equipment/sportsbox-ai-review)
*Pattern:* verdict first (hit / missed the band), number second, explanation third, evidence fourth.
Two seconds buys a tick, a colour and one number — nothing else.

### 2.3 Session summary
Two shapes exist: the **report card** (Noah's letter grades, covered in the 2026-09-13 doc) and the
**one-focus week** (WHOOP's Weekly Plan: pick one behaviour, track it for seven days). The second
generalises better to ArcLab because the Shot Doctor already produces a ranked diagnosis; the summary
should end with exactly one instruction, not a grade sheet.
(medium — https://www.whoop.com/us/en/thelocker/set-and-reach-your-goals-with-weekly-plan/)

### 2.4 3-D and overlay form review — the richest borrowable pattern set
Sportsbox 3D Golf, the closest analogue to ArcLab's 3-D form screen:
- three view modes — **2-D video, 3-D avatar, or split view** side by side;
- **free rotation** of the avatar (top, bottom, left, right) after capture, so one clip serves every
  camera angle a coach would have wanted;
- **compare two swings** as 3-D animations plus their metric deltas;
- **overlap** your model with a professional model;
- per-metric **target zones** with instant hit/miss.
(high — https://golficity.com/sportsbox-ai-review-turn-your-phone-into-a-3d-golf-coach/ ·
https://apps.apple.com/us/app/sportsbox-3d-golf/id1578921026 · https://www.sportsbox.ai/)
General video-analysis tooling adds: ghosted/opaque overlay of two athletes or two takes, frame-step
with pen/angle annotation, and continuously visible text overlays that do not require pausing.
(medium — https://simplifaster.com/articles/buyers-guide-sport-video-analysis/ ·
https://once.sport/once-sport-analyser/)

### 2.5 Drills and plans
The honest version in this cohort is WHOOP's: a small number of presets, one focus, a week-long
horizon, progress shown against the plan rather than against other people. OnForm's model is
coach-authored assignment + messaging (2026-09-13 doc). Nothing in the cohort ships an evidence-graded
curriculum, which is ArcLab's differentiator — the UI job is to make the grade visible without making
it the headline.

### 2.6 "Analysis takes time"
Uplift's two-phone capture is cloud-processed in roughly 10 minutes and is explicitly not real time
(2026-09-13 doc, https://www.uplift.ai/faqs). ArcLab's on-device analysis is the same UX problem
with a better ending: per-shot progress is *knowable*, so show "shot 7 of 24", stream results in as
each shot finishes (the list is usable before the run ends), keep working when the app is backgrounded,
and post a local notification on completion. A spinner with no count is the one option that is strictly
worse than the competition. (design inference; medium)

### 2.7 First run and camera setup
The best-documented protocol, from an iPhone sports-video guide: **record a short test clip and
inspect paused frames before starting the full set**; turn the grid on "if repeatable framing is
needed"; assign the athlete before recording. Capture targets: 60 fps general / 120 fps for fast
movement; shutter 1/250–1/500 for slow drills, 1/500 baseline, 1/1000+ for explosive actions; ISO as
low as practical; resolution ranks *below* frame rate, shutter and stable framing. Environment
presets: outdoor daylight 60–120 fps at 1/500–1/1000 and minimal ISO; indoor moderate 60 fps
targeting ≥1/500 with ISO raised carefully; indoor poor light — protect shutter speed, accept ISO.
(high — https://www.kine.vision/blog/camera-setup-protocol-for-sports-video-analysis-on-iphone-and-ipad)
*ArcLab:* this is the content of `FilmingGuideView`, and the test-clip-then-inspect-frames loop is
exactly the preflight already ranked #5 in the 2026-09-13 doc. Ship the three environment presets as
tappable cards rather than prose. Note the guide gives **no** tripod height/distance/angle numbers —
ArcLab's own geometry constraints (rim visible, plane calibration) have to supply those.

---

## 3. Evidence on presenting feedback to athletes

### 3.1 Every rep vs. reduced frequency — weaker than the textbooks say
The guidance hypothesis predicts that feedback after every trial helps practice performance but
*degrades* learning, because the learner leans on the augmented signal instead of their own.
(https://link.springer.com/chapter/10.1007/978-94-011-3626-6_6) But the 2022 meta-analysis of reduced
relative feedback frequency found "substantial heterogeneity but no significant moderators, high
levels of uncertainty, and no significant effect of reduced feedback frequency at any time point".
(https://www.sciencedirect.com/science/article/abs/pii/S1469029222000334)
**Grade B** (peer-reviewed meta, null result) · confidence high.
*ArcLab:* do not build faded/percentage feedback schedules and do not claim a learning benefit for
withholding numbers. The defensible reason to keep the per-rep surface quiet is different and
stronger: learners who *control* their own video feedback transfer better (2026-09-13 doc,
η² = .153, https://pmc.ncbi.nlm.nih.gov/articles/PMC3438820/ — **Grade B**). Pull, not push.

### 3.2 Bandwidth feedback — the one that maps cleanly onto ArcLab
Bandwidth feedback gives a number only when performance falls outside a preset range; bandwidth KR
"increases movement consistency relative to 100 % relative frequency KR", and benefits have been
shown on a complex gymnastic skill.
(https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3796837/ ·
https://www.sciencedirect.com/science/article/abs/pii/S0167945715300555 ·
https://www.atlantis-press.com/article/25906243.pdf)
**Grade B** (small-n peer-reviewed, mostly lab/gymnastics tasks; not basketball) · confidence medium.
*ArcLab:* this is the strongest evidential justification for the band UI the product already wants.
Per-rep display defaults to a **tick inside the band, a number only when outside it**. Consistency —
not accuracy — is the outcome the evidence supports, which is also exactly what ArcLab measures.

### 3.3 External-focus cue wording — do it for measurability, not for the science
Earlier meta-analyses reported external-focus superiority
(https://pubmed.ncbi.nlm.nih.gov/34843301/), and a 2025 meta of 20 RCTs / 497 participants found
distal external focus better than proximal or internal *for performance*, moderated by skill level
(https://pmc.ncbi.nlm.nih.gov/articles/PMC12424610/). But McKay et al.'s robust Bayesian re-analysis
of the literature found "moderate to strong evidence of publication bias for all analyses" and,
after correction, mean effects of g = 0.01 (performance), 0.15 (retention), 0.09 (transfer),
−0.01 (distance effect), with Bayes factors favouring the null (BF₀₁ 1.3–5.75): "focus of attention
appears to have a variety of effects that we cannot account for, and on average those effects are
small to nil". (https://sportrxiv.org/index.php/server/preprint/view/304)
**Grade C** for "external cues improve learning" · confidence high that the effect is overstated.
*ArcLab:* keep writing cues in outcome/environment terms ("through the top of a window a metre above
the rim") because such cues are *checkable against a measured number*, and say so in Learn — not
because an external focus is proven superior. Any copy in the app claiming otherwise should be
removed or marked C.

### 3.4 Concurrent vs. terminal, and modality
A 2021 systematic review of augmented feedback calls visual feedback "the cornerstone of all AF
types", finds multimodal feedback most effective overall ("multimodal stimuli are perceived faster
and tend to be retained longer than unimodal stimuli"), and notes that "closer feedback to the time
of action" facilitates learning — but its evidence base is small clinical/rehab samples (6–36
participants) from 2017–2020, with few direct immediate-vs-delayed comparisons.
(https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8681883/ ·
https://link.springer.com/article/10.3758/s13423-012-0333-8)
**Grade C** for transferring this to basketball shooting · confidence medium.
*ArcLab:* this does not overturn the v1 non-goal of real-time audio (it argues weakly for it while
§3.1's guidance literature argues weakly against). The safe reading: post-shot review within seconds
is fine, in-flight concurrent coaching is not evidenced enough to build. Pairing a number with a
short spoken line during *review* is the cheap multimodal win.

### 3.5 Video with overlay, and who should be in the overlay
A systematic review of video-based visual feedback in physical education found significant
improvements in nine studies, and "moderate evidence suggested that there is no significant
difference in the effectiveness of observing an expert model compared to a self-model".
(https://link.springer.com/article/10.1007/s12662-021-00782-y)
**Grade B** · confidence medium (PE populations, not skilled shooters).
*ArcLab:* overlay the player's **own best rep** against the current one rather than licensing pro
footage — equally effective per the evidence, free, legally clean, and it makes the comparison a
personal band rather than an unreachable ideal. Sportsbox's overlap-with-pro feature is a marketing
affordance, not an evidenced one.

### 3.6 Number overload
No sport-science evidence was located this session for "fewer numbers on screen improves learning".
The support is design practice — progressive disclosure, score-first dashboards, three-colour
semantics (2026-09-13 doc §"Presentation patterns" 6–7) — plus §3.1's self-controlled-feedback
result, which is about *who chooses* rather than *how many*.
**Grade D** as a learning claim · **strong** as a usability claim (NN/g legibility findings above).
*ArcLab:* present it internally as a readability decision, never as "science says fewer numbers".

---

## 4. Retention and engagement: honest patterns, and what to refuse

**Honest, and supported by something:**
- One focus per week, chosen from a small preset set, tracked against yourself
  (https://www.whoop.com/us/en/thelocker/set-and-reach-your-goals-with-weekly-plan/) · medium.
- A weekly review that reports what changed with an n attached, and says "not enough shots yet" when
  n is short — the honest-baseline pattern already decided in the 2026-09-13 doc (item 7).
- Personal records against your own history, no leaderboards (2026-09-13 doc, item 8; Strava Best
  Efforts). Leaderboards in this category invite the miscount-gaming that HomeCourt users complain of.
- Learner-pulled feedback: findings and clips one tap away, nothing auto-plays (Grade B, §3.1).

**Dark patterns to refuse, with the evidence that they misfire:**
- **Loss-aversion streaks.** Streaks work through loss aversion and, over-leveraged, "trigger guilt,
  anxiety, and compulsive checking"; gamified feedback systems "often increase anxiety, guilt,
  dependency, and burnout, particularly when they hinge on streaks, rankings, and daily goals";
  Duolingo is listed on deceptive.design for pushy reminders and disguised ads.
  (https://thedecisionlab.com/insights/consumer-insights/streak-creep-the-perils-of-too-much-gamification ·
  https://dev.to/yaptech/duolingos-shallow-learning-trap-gamified-streaks-harmful-habits-4134)
  Confidence medium (commentary and mixed literature, not an RCT) · **Grade C**.
  *Honest substitute:* a 30-day session calendar plus "reps banked", with **no loss mechanic**, no
  guilt copy, and a streak — if any — that counts *quality* sessions (enough shots, tier A/B) and
  ships with free passes.
- Notifications the user did not ask for; completion screens that are really upsells; any score with
  no method behind it (the 2025–26 "AI coach" cohort, 2026-09-13 doc); variable-reward animation on
  results; and daily-goal nagging for a sport that needs rest days.

---

## 5. Ranked UI improvements for ArcLab

Ranked by (effect on a player actually improving) × (feasibility). Effort: **S** ≤ half a day,
**M** ≤ two days, **L** more.

| # | What | Why (source) | Effort | Screen |
|---|---|---|---|---|
| 1 | Replace the single-`List` home + "Step-by-step tools" toggle with a 5-tab bar (Today · Capture · Progress · Doctor · Learn); move the eight debug sections to Settings → Step-by-step tools | iOS 26's primary navigation is a 2–5 tab floating bar; a task app should not open on a tool console (§1.3) | M | Home |
| 2 | "Today" card at the top answering *what do I do now* — resume session / start the plan's block / read yesterday's one finding | WHOOP home reorganisation; one-focus Weekly Plan (§2.1, §2.3) | M | Home |
| 3 | Shot result in ≤2 s: verdict tick + one ≥34 pt number + band; angle/depth/residual/frames behind one tap | Sportsbox instant goal-hit; §1.4 type sizes (§2.2) | S | Shot results |
| 4 | Bandwidth mode as the default per-rep surface: tick when inside the player's own band, number only when outside | Bandwidth KR increases movement consistency, Grade B (§3.2) | M | Guided session, Session results |
| 5 | Opaque scrim (≥80 %) behind every number burned over a clip or the 3-D scene; no Liquid Glass over footage or charts | Glass is a controls layer; text over images is a legibility failure (§1.1, §1.2) | S | Shot results, 3-D form, Capture |
| 6 | Capture opens straight to the viewfinder; volume-button start/stop; exposure+WB lock after framing | HIG camera-control expectations; the player is 5 m from the phone (§1.6) | M | Capture |
| 7 | Test-clip preflight: record 3 s, inspect paused frames, report predicted tier before the session | "Record a short test clip and inspect paused frames before starting the full set" (§2.7) | M | Capture, Filming guide |
| 8 | Three environment preset cards (outdoor daylight / indoor moderate / indoor poor) with fps, shutter, ISO and grid-on, replacing prose | KineVision protocol numbers (§2.7) | S | Filming guide |
| 9 | Analysis progress = "shot 7 of 24" + results streaming in as each finishes + keeps running backgrounded + local notification | Uplift's ~10 min cloud wait is the bar; a countless spinner is worse than the competition (§2.6) | M | Guided session, Session results |
| 10 | Session results open with **one** instruction, then at most 3 findings, everything else disclosed | One-focus week; progressive disclosure (§2.3) | S | Session results |
| 11 | 3-D form: 2-D video / 3-D avatar / split-view toggle with free rotation and preset angle chips (face-on, side, top) | Sportsbox's core interaction (§2.4) | L | 3-D form |
| 12 | 3-D form: overlay the player's own best rep against the current one (ghosted), with the metric delta — not a pro model | Self-model ≈ expert model, Grade B (§3.5) | M | 3-D form |
| 13 | Player-set target zones per metric, defaulting to their own make-band, with per-rep hit ticks along the session timeline | Sportsbox target zones; bandwidth evidence (§2.2, §3.2) | M | Shot results, Practice |
| 14 | Every number taps through to the frames, the fit residual and an A–D grade chip; unavailable metrics show the reason, not a blank | CLAUDE.md rule 1; the unexplained-score anti-pattern (2026-09-13 doc) | M | Shot results, Diagnosis |
| 15 | One-tap 1 w / 1 m / 6 m range switch on every progress chart | WHOOP trend switching (§2.1) | S | Progress |
| 16 | Outdoor mode: high-contrast palette, glass off, max brightness while capturing, numbers ≥34 pt, full Dynamic Type to 300 % | Sunlight legibility, 4.5:1 text contrast, 44 pt targets (§1.2, §1.4) | M | All; first Capture + Session results |
| 17 | Never encode make/miss or in/out-of-band by colour alone — colour + shape + printed label; VoiceOver descriptors on charts | Accessibility guidance (§1.5) | M | Progress, Session results, Shot results |
| 18 | Honest streak: 30-day session calendar + "reps banked", no loss mechanic, quality-gated, free passes, no guilt notifications | Streak-driven guilt/anxiety/burnout evidence, Grade C (§4) | S | Home, Progress |
| 19 | Nothing auto-plays; findings and clips are pull-only and the app remembers which finding the player opened | Self-controlled feedback transfers better, Grade B (§3.1) | S | Session results, Shot results |
| 20 | Weekly review screen: the Doctor proposes 3 preset plans; the player picks one focus for the week | WHOOP Weekly Plan presets (§2.1, §2.3) | M | Shot doctor Plan, Practice |
| 21 | Ask offers 3 questions grounded in *this* session's numbers instead of an empty field | Blank-field abandonment; grounded prompts keep answers inside measured data | S | Shot doctor Ask |
| 22 | Practice block screen readable from 5 m: reps remaining at display size, band ticks, no body text | The phone is on a tripod across the court (§1.6) | S | Practice |
| 23 | Learn: each module shows the measure that closes its gate as a ring with n, and the module's evidence grade inline | ArcLab's graded curriculum is the differentiator; grades must be visible but not the headline (§2.5) | M | Learn |
| 24 | Guided session gets a persistent 3-step stepper with resumable state ("Film → Analyse → Review") | Predictability; avoid iOS 26's collapsing-navigation failure mode (§1.2) | M | Guided session |
| 25 | Cue copy audit: rewrite cues in checkable outcome terms and stop implying an external-focus learning advantage | External-focus effects are small-to-nil after bias correction, Grade C (§3.3) | S | Learn, Diagnosis, Plan |

### Top 10, in order
1 · 3 · 5 · 9 · 4 · 7 · 10 · 2 · 16 · 14 — i.e. fix the navigation shell, make one rep land in two
seconds on a readable surface, make waiting honest, adopt band-based per-rep feedback, add the
test-clip preflight, cut the session summary to one instruction, give home a "what now" card, make
the whole thing survive sunlight, and keep every number one tap from its evidence.

---

## 6. What could not be verified this session
- Apple HIG `/liquid-glass` (404 on that path), `/charts`, `/accessibility`: client-rendered, fetch
  returned titles only. All §1 claims are secondary-sourced and need a browser check.
- https://www.whoop.com/us/en/thelocker/the-all-new-whoop-home-screen/ — HTTP 403; content from
  search snippets.
- https://www.nngroup.com/articles/liquid-glass/ — fetched partially; quotes above are what came back.
- No sport-science source was found for "fewer numbers on screen improves learning" (§3.6, Grade D).
- No published UI study of any basketball shooting app exists; every product claim in §2 is from
  vendor pages, app listings or review sites, not from usability research.
