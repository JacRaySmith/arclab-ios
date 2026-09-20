import Foundation

// MARK: - The curriculum
//
// `FixLibrary` answers "your numbers say X, so do Y". This file answers the other question a coach
// gets asked: "teach me to shoot." It is the order an NBA shooting coach works in — base, footwork,
// dip and rhythm, guide hand, release, range, off the dribble, game speed — with, for every module,
// what the coach watches, the one cue, the drills, what "done" looks like *in ArcLab's own numbers*,
// and the faults with how each one shows up in those numbers.
//
// Every claim carries a grade (`ShotEvidenceGrade`) and a source. The research pass behind it is
// `docs/research/shooting-curriculum-2026-09-15.md`, which sits on top of
// `docs/research/healthy-shot-model-2026-09-14.md` and `docs/research/coaching-evidence-2026-09-13.md`.
//
// Three rules this file obeys, all from CLAUDE.md:
//  1. No fabricated number. Every numeric gate below is either reused verbatim from `FixLibrary`
//     (which sourced it) or is exact geometry/arithmetic, and says which.
//  2. A module gate that ArcLab cannot measure today is `check == nil` with an `unavailableReason`,
//     never a number the app cannot produce.
//  3. Folklore is shipped *labelled* (`.d`), not hidden — coaches teach these, so the shooter should
//     be told they are being taught something unmeasured rather than find it repeated as fact.

// MARK: - Pieces

/// A drill, plus the things a drill needs that a `FixPackage`'s drill did not have to carry: what it
/// is for, where the camera goes, and the grade of the evidence that the *method* does anything —
/// which is a different question from the grade of the measure it is scored on.
public struct CurriculumDrill: Sendable {
    public var drill: Drill
    /// One sentence: what this drill is for.
    public var purpose: String
    /// Where the phone goes. Some modules cannot be seen at all from the wrong side.
    public var filmFrom: ClipRequirement
    /// The grade of the evidence that **this way of practising** changes anything. Most coaching
    /// drills are `.c` (consensus with a rationale) or `.d` (never tested); a few — the dip A/B, the
    /// blocked-then-random schedule — have a real design behind them.
    public var methodGrade: ShotEvidenceGrade
    public var source: String
    /// Anything precise that belongs to *this drill in the curriculum* rather than to the drill
    /// itself — the schedule research, what the module cannot see yet. Merged into the card's
    /// `detail` behind the plain lines. Added 2026-09-19 with the plain-language card.
    public var detail: String?

    /// The five plain lines, with the camera line folded into Setup and the method grade folded
    /// into Why, so Learn renders exactly what Plan and the block card render.
    public var card: DrillCard? {
        guard var c = drill.plainCard else { return nil }
        c.setup = "\(c.setup) \(filmFrom.whatToFilm)"
        if !c.why.isEmpty, !c.why.contains("Grade \(methodGrade.letter)") {
            c.why = "\(c.why) Grade \(methodGrade.letter) for this way of practising: \(methodGrade.meaning)."
        }
        c.detail = [c.detail, detail].compactMap { $0 }.joined(separator: " ")
        if c.detail?.isEmpty == true { c.detail = nil }
        return c
    }

    public init(drill: Drill, purpose: String, filmFrom: ClipRequirement,
                methodGrade: ShotEvidenceGrade, source: String, detail: String? = nil) {
        self.drill = drill
        self.purpose = purpose
        self.filmFrom = filmFrom
        self.methodGrade = methodGrade
        self.source = source
        self.detail = detail
    }
}

/// One measurable gate on a module. Exactly one of `check` and `unavailableReason` is non-nil.
public struct DoneCheck: Sendable {
    /// What passing it means, in the shooter's words.
    public var plainWords: String
    /// The gate in the app's own check type, so `FixLibrary.check` scores a module exactly the way it
    /// scores a plan. Nil when nothing ArcLab measures today can close this gate.
    public var check: PassCheck?
    /// Why there is no gate, when there is none. Never empty when `check` is nil. Plain words: it
    /// is the sentence a shooter reads instead of a number.
    public var unavailableReason: String?
    /// The precise version of the gate, for a gate that has no `PassCheck` to carry one. Shown on
    /// tap behind `plainWords`. Added 2026-09-19 with the plain-language pass.
    public var detail: String?
    /// The grade of the evidence that this measure is worth passing.
    public var grade: ShotEvidenceGrade
    public var source: String

    public init(plainWords: String, check: PassCheck? = nil, unavailableReason: String? = nil,
                detail: String? = nil, grade: ShotEvidenceGrade, source: String) {
        self.plainWords = plainWords
        self.check = check
        self.unavailableReason = unavailableReason
        self.detail = detail
        self.grade = grade
        self.source = source
    }

    /// True when the app can actually score this gate from a saved session today.
    public var isMeasurableToday: Bool { check != nil }

    /// The exact statement behind the plain one, wherever it lives.
    public var precise: String? { check?.detail ?? detail }
}

/// A fault the coach sees, and the fingerprint it leaves in the app's numbers.
public struct CurriculumFault: Sendable, Identifiable {
    /// What the coach calls it.
    public var name: String
    /// How it shows up in ArcLab's numbers — or that it does not, said plainly.
    public var howItShowsInNumbers: String
    /// The shot-doctor hypothesis that tests it, when one exists. Nil means the app has no test for
    /// this fault and the sentence above says so.
    public var hypothesis: HypothesisID?
    /// The grade of the claim that **this is a fault at all**.
    public var grade: ShotEvidenceGrade
    public var sources: [String]

    public var id: String { name }

    public init(name: String, howItShowsInNumbers: String, hypothesis: HypothesisID? = nil,
                grade: ShotEvidenceGrade, sources: [String]) {
        self.name = name
        self.howItShowsInNumbers = howItShowsInNumbers
        self.hypothesis = hypothesis
        self.grade = grade
        self.sources = sources
    }
}

public enum CurriculumModuleID: String, Sendable, Codable, CaseIterable, Identifiable {
    case base, footwork, dipAndRhythm, guideHand, releaseAndFollowThrough, range, offTheDribble, gameSpeed
    /// Added 2026-09-19 (1.4 "game"). The two modules that come after the shot itself: moving the
    /// ball, and doing it with somebody in the way.
    case ballHandling, handlingUnderPressure
    public var id: String { rawValue }
}

public struct CurriculumModule: Sendable, Identifiable {
    public var id: CurriculumModuleID
    public var title: String
    /// Position in the teaching order, from 0. Unique across the catalogue.
    public var order: Int
    /// Modules that should be closed first. The graph is acyclic and every edge points backwards in
    /// `order` — both are asserted in the tests.
    public var prerequisites: [CurriculumModuleID]
    /// Why this module exists, in the coach's framing.
    public var summary: String
    /// What the coach's eye is actually on while the shooter shoots.
    public var whatCoachWatches: [String]
    /// The one sentence the coach says. External focus — on the ball and the target, not the body.
    /// The wording itself is unproven (see `Curriculum.honestyRules`); it is a delivery vehicle.
    public var cue: String
    public var drills: [CurriculumDrill]
    /// What "done" looks like, measurably. At least one entry per module.
    public var doneWhen: [DoneCheck]
    public var faults: [CurriculumFault]
    /// What ArcLab still cannot see for this module, named so the gap is not mistaken for a pass.
    public var openQuestions: [String]
}

// MARK: - The catalogue

public enum Curriculum {

    /// Shown with the curriculum, the way `FixLibrary.honestyRules` is shown with a plan.
    public static let honestyRules: [String] = [
        "This is the order a coach teaches in, not a proven sequence. No study has compared teaching orders for shooting; the order below is coaching consensus with a biomechanical rationale (grade C).",
        "A module is closed by a measured change in your own numbers that survives to the next session, never by reading it or by feeling different.",
        "The cue is wording, and wording is the weakest link here: the bias-corrected meta-analysis of external-focus cues finds g = 0.01 on performance with Bayes factors favouring the null. What is graded is the measure, not the sentence.",
        "Where a coach commonly teaches something unmeasured, it is listed and labelled D rather than left out. Being told that a thing is folklore is more useful than never hearing it.",
        "Modules whose gate ArcLab cannot measure today say so and stay open. An unmeasurable module is never quietly marked done.",
    ]

    public static let modules: [CurriculumModule] = [base, footwork, dipAndRhythm, guideHand,
                                                     releaseAndFollowThrough, range, offTheDribble, gameSpeed,
                                                     ballHandling, handlingUnderPressure]

    public static func module(_ id: CurriculumModuleID) -> CurriculumModule {
        // Total by construction: `modules` covers every case, asserted in the tests.
        modules.first { $0.id == id } ?? base
    }

    /// The module that teaches the thing a shot-doctor hypothesis is about — the "learn why" link
    /// behind a plan. Nil when no module claims the hypothesis.
    public static func module(for hypothesis: HypothesisID) -> CurriculumModule? {
        modules.sorted { $0.order < $1.order }
            .first { $0.faults.contains { $0.hypothesis == hypothesis } }
    }

    /// Modules whose prerequisites are all in `completed`, in teaching order.
    public static func available(completed: Set<CurriculumModuleID>) -> [CurriculumModule] {
        modules.sorted { $0.order < $1.order }
            .filter { m in m.prerequisites.allSatisfy { completed.contains($0) } }
    }

    public static func isUnlocked(_ id: CurriculumModuleID, completed: Set<CurriculumModuleID>) -> Bool {
        module(id).prerequisites.allSatisfy { completed.contains($0) }
    }

    // MARK: Numbers reused rather than invented

    /// `exp(1.96 / √30) = 1.43`: the smallest *widening* of an SD that 30 shots a side can be told
    /// from chance, straight out of `DoctorStats.detectableSDRatio`. Used where "done" is "this did
    /// not get worse" rather than "this got better" — the versatility definition in
    /// `healthy-shot-model-2026-09-14.md` §4. Arithmetic, so grade A.
    static let notWiderRatio = 1.43

    /// `notWiderRatio` said the way a shooter reads it, because "÷ 1.43" is not an instruction.
    /// Narrowing to 1 ÷ 1.43 of last session's spread **is** a 30 % narrowing, and widening to
    /// 1.43 × it **is** 43 % wider. Both are the same arithmetic as the gate they describe, so a
    /// change to `DoctorStats.detectableSDRatio` moves the words too. Asserted in the tests.
    static let narrowByPercent = Int(((1 - 1 / notWiderRatio) * 100).rounded())   // 30
    static let widerByPercent = Int(((notWiderRatio - 1) * 100).rounded())        // 43

    /// The published make-depth band, 25–28 cm past the front rim, in centimetres.
    /// Daly-Grafstein & Bornn 2019 JQAS over >50 000 NBA three-point trajectories.
    static let depthBandCm = (low: ShotDoctor.publishedMakeDepthBand.low * 100,
                              high: ShotDoctor.publishedMakeDepthBand.high * 100)

    // MARK: 1 — Base and balance

    public static let base = CurriculumModule(
        id: .base,
        title: "Base and balance",
        order: 0,
        prerequisites: [],
        summary: """
            Everything above the waist is measured against where the feet are. A coach starts here not \
            because the base is where the accuracy comes from — it is not, the release is — but because \
            every later module is read off a shot that repeats, and a shot that lands somewhere new \
            every time cannot be read at all.
            """,
        whatCoachWatches: [
            "Where the feet start and where they land: the shot should finish inside its own footprints.",
            "Whether the head travels between the dip and the release, or stays over the same patch of floor.",
            "Whether the eyes find the rim before the ball starts up, and stay there through the follow-through.",
            "Whether the last set of the session looks like the first one.",
        ],
        cue: "Land where you took off, with your eyes on the back of the ring the whole way.",
        drills: [
            CurriculumDrill(
                drill: Drill(name: "Footprint holds", reps: 10, sets: 4, spots: [.freeThrow],
                             constraint: "A shot counts only if both feet land back inside your marks and you are still holding your finish when the ball reaches the ring.",
                             schedule: "Stay at this one spot for your first two sessions. After that, shuffle in a second spot.",
                             setup: "Free throws. Chalk or tape two marks where your feet start. 10 shots a set, 4 sets.",
                             doThis: "Land back on your own two marks and hold the finish until the ball reaches the ring.",
                             watches: "How far past the front of the ring your shots pass, and how much that varies.",
                             doneWhen: "Next session that spread is clearly tighter than this session's — about \(narrowByPercent) % tighter if you shoot 30 a side. Below 25 counted shots the app says it cannot tell yet.",
                             why: "A shot that starts from the same patch of floor every time is the only shot the app can read at all.",
                             detail: "Gate: depth SD at the finding spot, next session at or below this session's ÷ the detectable SD ratio exp(1.96/√n), which is 1.43 at n = 30. Minimum 25 counted shots. Schedule: blocked practice wins during acquisition and loses on retention and transfer (Shamshiri 2025, ηp² = 0.24). Knudson 1993 JOPERD: balanced stance, minimise horizontal COM travel."),
                purpose: "Make the shot repeat from the same place, so every later measurement is of the shot and not of where you were standing.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "Knudson 1993 JOPERD six teaching points (balanced stance, minimise horizontal COM travel) — coaching consensus with a rationale, no controlled measurement. The schedule is Shamshiri et al. 2025 (grade B, 84 novices, 3 days)."),
            CurriculumDrill(
                drill: Drill(name: "Hold the look", reps: 10, sets: 3, spots: [],
                             constraint: "A shot counts only if your eyes stayed on the ring the whole way. If you watched the ball leave your hand it does not count, whatever it does at the ring.",
                             schedule: "One spot, all three sets, in the same session.",
                             setup: "Any one spot — this drill does not name one. 10 shots a set, 3 sets.",
                             doThis: "Put your eyes on the back of the ring before you start and leave them there until the ball lands.",
                             watches: "How far your head travels between the lowest point of the ball and the moment it leaves your hand.",
                             doneWhen: "There is no pass mark here. Nobody has published a normal range for head movement, so the app shows it as your own trend across sessions and never scores it.",
                             why: "Expert shooters hold their head and eyes steadier than beginners do, and the head is the part of balance a camera can actually see.",
                             detail: "Head displacement between dip and release, in pixels from a fixed tripod, normalised by your own height. No published reference range exists in any unit, and two camera positions give two different numbers (healthy-shot-model-2026-09-14.md §2.4, §7). Ripoll et al. 1986 Human Movement Science; Lebeau et al. 2016 quiet-eye meta-analysis — large effects on weak designs, and gaze is not measurable from a tripod."),
                purpose: "Stop the head from leading the shot, which is the part of 'balance' a camera can actually see.",
                filmFrom: .closeForm,
                methodGrade: .b,
                source: "Ripoll et al. 1986 Human Movement Science: head/eye stabilisation on target discriminates experts from beginners and successful from failed shots — small n, no retrievable effect size. The quiet-eye meta-analysis (Lebeau et al. 2016) reports large effects on weak designs, and gaze is not measurable from a tripod; only head displacement is."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Your shots stop spreading out front to back — next session's spread is clearly tighter than this session's.",
                check: PassCheck(measure: .depthSDCm, scope: .findingSpot, target: .narrowByDetectableRatio,
                                 description: "next session's front-to-back spread is clearly tighter than this session's — about \(narrowByPercent) % tighter if you shoot 30 a side",
                                 minimumN: 25,
                                 detail: "depthSDCm at the finding spot, next session at or below this session's ÷ the detectable SD ratio exp(1.96/√n) — 1.43 at n = 30, so a \(narrowByPercent) % narrowing. At least 25 counted shots, or the check reports that it cannot tell."),
                grade: .a,
                source: "Depth SD is the observable consequence of release-speed SD, which is the strongest published correlate of shooting percentage (Slegers, Lee & Wong 2021 JSSM, r = −0.96 with 3P%). The detectable-ratio floor is arithmetic (`DoctorStats.detectableSDRatio`)."),
            DoneCheck(
                plainWords: "Your head stops travelling between the start of the shot and the release.",
                unavailableReason: "Head movement is measured in pixels from a tripod and there is no published range to compare it against, so two camera positions give two different numbers. The app shows it as your own trend across sessions and never scores it, which means it cannot finish this module.",
                detail: "headStabilityNormalised is reported, never gated: no published reference range exists in any unit ArcLab can measure (healthy-shot-model-2026-09-14.md §2.4, §7).",
                grade: .b,
                source: "healthy-shot-model-2026-09-14.md §2.4 and §7 ('metrics that need better tracking before they are shown at all')."),
            DoneCheck(
                plainWords: "Your shot does not change from the first set of the session to the last.",
                unavailableReason: "The change across a whole session is shown on your results as a trend rather than as a pass mark, so it cannot finish a module. Compare your first set with your last one instead.",
                detail: "depthTotalChangeOverSession comes from the shot doctor's over-session read-out, not from the pass-check reader. Textbook Ch 15 §15.3.4: report the total change across the session, never a slope and never a p-value.",
                grade: .a,
                source: "Textbook Ch 15 §15.3.4 (report the total change across the session, not a slope and not a p-value). That drift can happen is established (Bourdas et al. 2024); that it happens to you is measured, never assumed (Slawinski et al. 2018 found none in elite U18s)."),
        ],
        faults: [
            CurriculumFault(
                name: "Drifting or fading out of the shot",
                howItShowsInNumbers: "Your shots sit off to one side on average, and they scatter more left and right than they do on your own standing-still sets. Only a clip filmed from behind you can see this; from the side it is invisible.",
                hypothesis: .lateralAimBias,
                grade: .c,
                sources: ["Knudson 1993 JOPERD: minimise horizontal COM travel — consensus with a rationale, no controlled measurement.",
                          "That the *variance* rather than the mean is what predicts is grade A: Daly-Grafstein & Bornn 2020 JSA."]),
            CurriculumFault(
                name: "Head moving through the shot",
                howItShowsInNumbers: "How far your head travels between the start of the shot and the release, in pixels, on a close waist-up clip. It has no published range, so only your own trend across sessions can be read — a number here is never a pass or a fail.",
                hypothesis: .headInstability,
                grade: .b,
                sources: ["Ripoll et al. 1986 Human Movement Science (small n, no effect size).",
                          "Lebeau et al. 2016 quiet-eye meta-analysis: large effects on weak designs, and gaze is not measurable from a tripod."]),
            CurriculumFault(
                name: "Stance too wide (or too narrow)",
                howItShowsInNumbers: "Nothing. Stance width would have to come from the body model in metres, and ArcLab does not trust its body measurements in metres until that scale has been checked against the ring.",
                hypothesis: nil,
                grade: .b,
                sources: ["Cabarkapa, Cabarkapa & Fry 2026: proficient three-point shooters had a *narrower* stance than non-proficient (27.4 vs 34.3 cm), which is the opposite direction to the usual 'shoulder width or wider' coaching. Between-group, recreational sample, n = 24."]),
            CurriculumFault(
                name: "\"You must be perfectly square to the rim\"",
                howItShowsInNumbers: "Nothing measurable. Nobody has published a range for how square is square enough, and the app refuses the shoulder angle outright from a near-side view and calls it noisy from the others. Only your own shot-to-shot repeatability could ever be reported.",
                hypothesis: .shoulderSquareness,
                grade: .d,
                sources: ["healthy-shot-model-2026-09-14.md §2.5 and row 18: no published range exists; 'square to the rim' is coaching lore stated as a fact.",
                          "Cabarkapa et al. 2022: excellent and good professionals showed no kinematic differences at all — the grade-A null against importing any posture target."]),
        ],
        openQuestions: [
            "Head stillness needs a phone that does not move and a note of the scale before two sessions can be compared. Until then this module is finished on its consequence — your front-to-back spread — rather than on its cause.",
            "Foot contacts, stance width and where you land are being built now (`docs/DESIGN-FOOTWORK-2026-09-15.md`). When they arrive, this module gets a pass mark on its own subject instead of on its consequence.",
        ])

    // MARK: 2 — Footwork into the shot

    public static let footwork = CurriculumModule(
        id: .footwork,
        title: "Footwork into the shot",
        order: 1,
        prerequisites: [.base],
        summary: """
            A shot that starts from a catch or a dribble has to arrive at the base the last module \
            built. The coach is not teaching a style here — the one measured test of foot placement \
            found no accuracy difference between stances — but a repeat: the same feet, pointed \
            before the ball arrives, every time.
            """,
        whatCoachWatches: [
            "Whether the feet are pointed at the rim before the ball arrives, or are still turning as it does.",
            "Which foot lands first, and whether it is the same one every repetition.",
            "Whether the hips are square by the time the ball reaches the set point.",
            "Whether the shooter travels sideways between the catch and the release.",
        ],
        cue: "Have your feet pointed at the rim before the ball gets to you.",
        drills: [
            CurriculumDrill(
                drill: Drill(name: "Same-feet catch and shoot", reps: 10, sets: 4, spots: [.freeThrow, .elbow],
                             constraint: "A shot counts only if you started and finished on your two marks and the ball left before your feet moved again.",
                             schedule: "Stay at the first spot for two sessions, then shuffle the two spots.",
                             setup: "Free throws and the elbow. Two chalk marks for your feet, and a passer or a self-toss. 10 shots a set, 4 sets.",
                             doThis: "Have both feet on your marks and pointed at the ring before the ball reaches your hands.",
                             watches: "How far left or right of the middle of the ring your shots pass.",
                             doneWhen: "Next session your average left-right miss sits inside 3 cm either side of the middle, over at least 20 counted shots.",
                             why: "Arriving the same way every time stops your feet from being a source of scatter — and the one study that compared foot placements found no accuracy difference at all, so what is trained here is the repeat, not a style.",
                             detail: "Gate: lateralMeanCm inside ±3 cm at the finding spot, minimum 20 counted shots; the ±11 cm of ring tolerance either side of the ball is exact geometry. The Sport Journal foot-placement study, 11 NCAA Division I women: no significant effect of foot placement on accuracy (grade B for the null). Schedule: blocked first, then shuffled (Shamshiri 2025, ηp² = 0.24)."),
                purpose: "Make the arrival repeat, so the footwork stops being a source of spread.",
                filmFrom: .behindShooter,
                methodGrade: .c,
                source: "Coaching consensus. The one measured test of stance — 11 NCAA Division I women, dominant-staggered vs parallel vs cross-dominant — found no significant effect of foot placement on accuracy, though players favoured the dominant staggered stance (The Sport Journal, foot-placement study, grade B for the null)."),
            CurriculumDrill(
                drill: Drill(name: "One-two ladder", reps: 8, sets: 6, spots: [.elbow, .midRange],
                             constraint: "A shot counts only if the same foot landed first. If the other foot goes down first it does not count, whatever the shot does — what is graded is that it repeated, not which foot it was.",
                             schedule: "Stay at the near spot until the order repeats itself, then alternate the two spots.",
                             setup: "The elbow and mid-range. 8 shots a set, 6 sets.",
                             doThis: "Step into every shot with the same foot first.",
                             watches: "How much your shots scatter left and right, against the same spot standing still.",
                             doneWhen: "There is no pass mark for the step itself — the app cannot see your feet land yet. What it can score is the left-right scatter this drill is meant to shrink.",
                             why: "No study picks a step order, so the only defensible target is that yours repeats.",
                             detail: "Which foot should land first is coaching folklore on both sides — the 1-2 and the hop are both taught as correct, and no peer-reviewed comparison was found (searched 2026-09-15). Foot contacts, step order and gather time are Track C (`docs/DESIGN-FOOTWORK-2026-09-15.md`) and are not scored today."),
                purpose: "Fix the step order as *yours* rather than as a prescribed one, because no published evidence picks an order.",
                filmFrom: .behindShooter,
                methodGrade: .d,
                source: "Which foot should land first is coaching folklore on both sides: the 1-2 and the hop are both taught as correct by well-known coaches, and no peer-reviewed comparison of the two was found (searched 2026-09-15). Only the repeatability is defensible, and that is an in-house argument, not a measured one."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Filmed from behind, your shots average within 3 cm either side of the middle of the ring.",
                check: PassCheck(measure: .lateralMeanCm, scope: .findingSpot, target: .insideBand(low: -3, high: 3),
                                 description: "next session's average left-right miss sits inside 3 cm either side of the middle, filmed from behind",
                                 minimumN: 20,
                                 detail: "lateralMeanCm at the finding spot inside ±3 cm, minimum 20 counted shots. Daly-Grafstein & Bornn 2019/2020: the mean offset is near zero in professionals, and contests raise lateral variance 38 % without moving the mean. The ±11 cm tolerance either side of the ball is exact ring geometry."),
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019/2020: the mean offset is near zero in professionals, and contests raise lateral *variance* 38 % without moving the mean. The ±11 cm tolerance either side of the ball is exact ring geometry. Reused verbatim from `FixLibrary`'s lateral-aim package."),
            DoneCheck(
                plainWords: "Your shots stop scattering left and right — next session's side-to-side spread is clearly tighter.",
                check: PassCheck(measure: .lateralSDCm, scope: .findingSpot, target: .narrowByDetectableRatio,
                                 description: "next session's left-right spread is clearly tighter than this session's — about \(narrowByPercent) % tighter if you shoot 30 a side",
                                 minimumN: 25,
                                 detail: "lateralSDCm at the finding spot, next session at or below this session's ÷ exp(1.96/√n) — 1.43 at n = 30, so a \(narrowByPercent) % narrowing. Slegers & Love 2022: spin-axis SD correlated r = 0.80 with lateral accuracy while mean misalignment did not."),
                grade: .a,
                source: "Slegers & Love 2022: spin-axis SD correlated r = 0.80 with lateral accuracy while mean misalignment did not — consistency is the signal. Detectable-ratio floor is arithmetic."),
            DoneCheck(
                plainWords: "Your step repeats: same foot first, same timing, no sliding sideways.",
                unavailableReason: "ArcLab cannot see your feet land yet. Step order, stance width, the time from your last step to the release and any sideways slide are all being built now, and stance width in metres is not trusted until that scale has been checked against the ring. Nothing here is scored until they arrive.",
                detail: "Track C (`docs/DESIGN-FOOTWORK-2026-09-15.md`); healthy-shot-model-2026-09-14.md §7 — body measurements in metres are the unreliable class.",
                grade: .c,
                source: "healthy-shot-model-2026-09-14.md §7 (body metres are the unreliable class); `docs/PLAN-1.1-2026-09-15.md` Track C."),
        ],
        faults: [
            CurriculumFault(
                name: "Fading or drifting sideways into the shot",
                howItShowsInNumbers: "Your shots average off to one side, the same side each time, on a clip filmed from behind. A side view cannot see it and says so.",
                hypothesis: .lateralAimBias,
                grade: .b,
                sources: ["Daly-Grafstein & Bornn 2020 JSA: NBA contests raised left–right variance 38 % without biasing direction — disturbance shows in spread first.",
                          "That drifting specifically causes the offset is a coaching inference, grade C."]),
            CurriculumFault(
                name: "Different feet every repetition",
                howItShowsInNumbers: "Your shots scatter more left and right on catch-and-shoot sets than on your own standing-still sets at the same spot — recorded as two sets and compared.",
                hypothesis: .lateralVariability,
                grade: .c,
                sources: ["No published study compares repeatable against variable step order. The claim that spread follows from it is coaching consensus; what ArcLab can do is measure your two blocks."]),
            CurriculumFault(
                name: "Drifting forward into the rim",
                howItShowsInNumbers: "Your shots pass deeper than 28 cm past the front of the ring on average, or you keep creeping closer to the ring between sets at what is meant to be the same spot.",
                hypothesis: .depthBiasLong,
                grade: .c,
                sources: ["The depth band itself is grade A (Daly-Grafstein & Bornn 2019). That travelling forward is what moved it is a coaching inference on your own data."]),
            CurriculumFault(
                name: "\"The hop is quicker\" / \"the 1-2 is more balanced\"",
                howItShowsInNumbers: "Nothing, today. Coaches teach both as the right answer, nobody has compared them, and the one study that did compare foot placements found no accuracy difference.",
                hypothesis: nil,
                grade: .d,
                sources: ["Dr Dish Basketball coaching blog, '1-2 vs. The Hop' — a summary of the coaching argument, not evidence (https://blog.drdishbasketball.com/basketball-shooting-footwork-1-2-vs.-the-hop).",
                          "The Sport Journal, 'The Effect of Foot Placement on the Jump Shot Accuracy of NCAA Division I Basketball Players': 11 D-I women, no significant effect of foot placement on accuracy (grade B for the null, practitioner journal, small n)."]),
        ],
        openQuestions: [
            "Left and right is the only thing that sees footwork today, and it needs the phone behind you. On a side view this module cannot be scored at all.",
            "Nothing has been filmed off the dribble yet, so the foot measurements being built will be tested on catch and free-throw clips first.",
        ])

    // MARK: 3 — The dip and the rhythm

    public static let dipAndRhythm = CurriculumModule(
        id: .dipAndRhythm,
        title: "The dip and the rhythm",
        order: 2,
        prerequisites: [.base],
        summary: """
            The part of the shot most video apps ignore is the part where proficient and \
            non-proficient shooters actually differ: the preparation, not the release. This module is \
            about the ball going down before it goes up, and about the tempo from the bottom of that \
            dip to the ball leaving — the same tempo from every distance.
            """,
        whatCoachWatches: [
            "Whether the ball goes down before it goes up, and whether it goes to the same place every time.",
            "The tempo from the lowest point of the ball to the release, and whether it repeats.",
            "Whether that tempo changes when the shooter steps back.",
            "Whether the legs start the shot and the ball is the last thing to move.",
        ],
        cue: "Let the ball sit in the dip for a beat, then send it.",
        drills: [
            CurriculumDrill(
                drill: Drill(name: "Metronome dip", reps: 8, sets: 8, spots: [],
                             constraint: "A shot counts only if it left on the second click. Set the metronome to your own near-spot time from the bottom of the dip to the release, and keep that same beat from every distance.",
                             schedule: "Near spot first, every set, then the far spot on the same beat.",
                             setup: "One near spot and one far spot, and a metronome on your watch or phone. 8 shots a set, 8 sets.",
                             doThis: "Let the ball sit at the bottom of the dip for one click, then send it on the next.",
                             watches: "The time from the lowest point of the ball to the ball leaving your hand, and how much that time changes when you step back.",
                             doneWhen: "Your far-spot time moves at least 0.05 s back towards your near-spot time, over at least 20 counted shots.",
                             why: "Holding one beat stops you hurrying the long shots — and since two studies disagree about whether quicker or slower is better, the only honest target is your own tempo.",
                             detail: "Gate: dipToReleaseChangeAcrossDistance, far spot moving at least 0.05 s toward the near-spot value, minimum 20 counted shots. There is no published reference range for dip-to-release in any population, so the target is your own near-spot tempo and 0.05 s is the smallest move the measure resolves at these counts. Cabarkapa et al. 2023: proficient shooters moved slower and lower in preparation (knee peak 212.9 vs 269.4 °/s, ES 1.04). Botsi et al. 2024: higher-level U18s released 12.5 % faster."),
                purpose: "Hold one tempo across distances instead of hurrying the far ones.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "Reused from `FixLibrary`'s rushed-preparation package. Cabarkapa et al. 2023 found proficient shooters moved slower and lower in preparation (knee peak 212.9 vs 269.4 °/s, ES 1.04) with no release-phase differences; Botsi et al. 2024 found higher-level U18s released 12.5 % *faster*. The two pull opposite ways, so only your own consistency is read — the metronome method itself is untested."),
            CurriculumDrill(
                drill: Drill(name: "Dip / no-dip A-B", reps: 10, sets: 6, spots: [.freeThrow, .midRange],
                             constraint: "A set counts only if the whole set was shot the same way. Record each set on its own so the two can be compared set against set.",
                             schedule: "Alternate: one set with the dip, one set without, and keep alternating.",
                             setup: "Free throws and mid-range. 10 shots a set, 6 sets — three with a dip, three without.",
                             doThis: "On dip sets take the ball down before it goes up; on the other sets start it at your set point and go straight up.",
                             watches: "How many went in and how far past the front of the ring your shots passed, one kind of set against the other.",
                             doneWhen: "Done when you have three sets each way at the same spot and the app can show you which way your own numbers went. There is no pass mark: the answer is whichever way your own sets fall.",
                             why: "Elite shooters gained 7–9 % accuracy with the dip in a trial run on each shooter individually, which is exactly why you run the same trial on yourself.",
                             detail: "Penner 2021 Front Psychol: 36 elite males, within-subject with and without a dip at four distances (3.125–6.75 m), 7–9 % accuracy gain, F(1,17) = 27.6 and 53.1, p < 0.001. Unblinded, single-session and acute, with no retention test — which is why this ships as your own A-B rather than as a rule."),
                purpose: "Settle whether the dip does anything for *you*, rather than importing someone else's answer.",
                filmFrom: .sideView,
                methodGrade: .a,
                source: "Penner 2021 Front Psychol: 36 elite males, within-subject with and without a dip at four distances (3.125–6.75 m), 7–9 % accuracy gain, F(1,17) = 27.6 and 53.1, p < 0.001. Grade A for the design class, with the caveat that it is unblinded, single-session and acute, with no retention test — which is exactly why this is run as your own A-B."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Your rhythm stops changing when you step back: the far spot moves at least 0.05 s back towards the near one.",
                check: PassCheck(measure: .dipToReleaseChangeAcrossDistance, scope: .acrossDistance,
                                 target: .moveBy(0.05),
                                 description: "your far-spot time from the bottom of the dip to the release moves at least 0.05 s back towards your near-spot time",
                                 minimumN: 20,
                                 detail: "dipToReleaseChangeAcrossDistance, scope acrossDistance, target moveBy(0.05), minimum 20 counted shots. No published reference range for dip-to-release exists in any population, so the target is your own near-spot tempo; 0.05 s is the smallest move the measure resolves at these shot counts, not a published number."),
                grade: .b,
                source: "Reused verbatim from `FixLibrary`'s rushed-preparation package. There is no published reference range for dip-to-release at all, so the target is your own near-spot tempo, and 0.05 s is the smallest move the measure resolves at these shot counts — not a published number."),
            DoneCheck(
                plainWords: "The speed you send the ball at stops varying so much from shot to shot.",
                check: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot, target: .narrowByDetectableRatio,
                                 description: "next session's shot-to-shot speed spread is clearly tighter than this session's — about \(narrowByPercent) % tighter if you shoot 30 a side",
                                 minimumN: 25,
                                 detail: "releaseSpeedSD at the finding spot ÷ exp(1.96/√n) — 1.43 at n = 30, so a \(narrowByPercent) % narrowing. Slegers, Lee & Wong 2021 JSSM: release-velocity SD correlated r = −0.96 with 3-point and r = −0.88 with free-throw performance in 12 skilled shooters; skilled range 0.05–0.13 m/s."),
                grade: .a,
                source: "Slegers, Lee & Wong 2021 JSSM: release-velocity SD correlated r = −0.96 with 3-point and r = −0.88 with free-throw performance in 12 skilled shooters; skilled range 0.05–0.13 m/s."),
            DoneCheck(
                plainWords: "Your legs lead your arm on most shots.",
                unavailableReason: "Seeing which joint moves first needs a close waist-up clip, and the order is not carried on the results the pass marks read, so it cannot finish this module. Where it is shown at all it is shown as a pattern — never as a number of milliseconds, because no such number has ever been published.",
                detail: "proximalToDistalRate is not carried on Diagnosis. Jiang et al. 2025 J Hum Kinet: collegiate players were proximal-dominant at 3.2 m, recreational players distal-dominant; 20 players, 3 successful shots per distance.",
                grade: .b,
                source: "Jiang et al. 2025 J Hum Kinet: collegiate players were proximal-dominant at 3.2 m, recreational players distal-dominant; 20 players, 3 successful shots per distance."),
        ],
        faults: [
            CurriculumFault(
                name: "Rushing the gather at range",
                howItShowsInNumbers: "Your time from the bottom of the dip to the release gets shorter as the distance gets longer, and the speed you send the ball at varies more with it.",
                hypothesis: .rushedPreparation,
                grade: .b,
                sources: ["Cabarkapa et al. 2023 Front Sports Act Living: proficient shooters moved slower and lower in preparation, no release-phase differences (markerless 120 Hz, 34 males, between groups).",
                          "Botsi et al. 2024 JFMK: higher-level U18s released 12.5 % faster (t(77) = −3.213, p = 0.002) — the opposite direction, which is why only your own consistency is scored."]),
            CurriculumFault(
                name: "No dip at all",
                howItShowsInNumbers: "Nothing in a single set. It shows only in your own alternating sets: dip sets against no-dip sets at the same spot, compared on how many went in and how deep they passed.",
                hypothesis: nil,
                grade: .a,
                sources: ["Penner 2021: +7–9 % accuracy with the dip, within-subject, 36 elite males — grade A for an acute effect.",
                          "\"Always dip\" as a permanent prescription is grade D: the study was single-session, unblinded and had no retention test."]),
            CurriculumFault(
                name: "Shooting with the arm only",
                howItShowsInNumbers: "Your knees do not straighten any faster as you step back. It needs a close form clip, and the number is reported rather than scored, because nobody has published a range for one person.",
                hypothesis: .armDominantDrive,
                grade: .b,
                sources: ["Cabarkapa et al. 2023: knee peak angular velocity separates proficient from non-proficient (recreational, between groups).",
                          "Okazaki & Rodacki 2012: experts showed no significant ankle/knee/hip change with distance and compensated with release speed — so 'use your legs more' is not a settled instruction."]),
            CurriculumFault(
                name: "\"One-motion is faster, two-motion is more powerful\"",
                howItShowsInNumbers: "Nothing. Nobody has compared one-motion with two-motion shooting, so the app measures whether your rhythm repeats and takes no position on its shape.",
                hypothesis: nil,
                grade: .d,
                sources: ["healthy-shot-model-2026-09-14.md §2.6 (searched 2026-09-14, nothing found); set-point height is in the same class and is deliberately not shown at all."]),
        ],
        openQuestions: [
            "Nobody has published a normal range for the time from dip to release, in any group of shooters. So the only pass marks possible here are your own consistency and your own change across distance.",
            "Which joint leads needs the close form clip and a body model the app trusts in 3-D. Until then this module finishes on rhythm and speed alone.",
        ])

    // MARK: 4 — The guide hand

    public static let guideHand = CurriculumModule(
        id: .guideHand,
        title: "The guide hand",
        order: 3,
        prerequisites: [.dipAndRhythm],
        summary: """
            The off hand is where most left–right misses are blamed, and it is also the module with \
            the weakest evidence in the whole curriculum: the sources are coaching sites and patent \
            filings. What *is* grade A is the consequence a coach is really chasing — the ball coming \
            back on a straight axis and the left–right spread narrowing.
            """,
        whatCoachWatches: [
            "Where the off hand sits on the ball, and whether it is still on the ball at the release.",
            "Whether the off thumb pushes as the ball leaves.",
            "Whether the ball comes back on a straight axis or with a tilt.",
            "Whether the misses fall to one side rather than scattering.",
        ],
        cue: "Roll the ball off the two middle fingers so it comes back straight at you.",
        drills: [
            CurriculumDrill(
                drill: Drill(name: "Taped-stripe spin set", reps: 10, sets: 4, spots: [],
                             constraint: "A shot counts only if you watched the stripe rather than the result. Whether it went in does not decide it.",
                             schedule: "One near spot, every set — the spin is easier to control before the distance makes you work.",
                             setup: "One near spot, with a strip of tape right around the ball's seam. 10 shots a set, 4 sets.",
                             doThis: "Watch the stripe as the ball flies and make it come back at you flat, with no tilt.",
                             watches: "How far left or right of the middle your shots pass. The tilt of the spin itself is not measured yet.",
                             doneWhen: "Next session your left-right spread is clearly tighter — about \(narrowByPercent) % tighter if you shoot 30 a side. The tilt itself is not scored, because the app cannot measure it yet.",
                             why: "How steady your spin stays predicts where the ball misses left and right; how far off it points does not.",
                             detail: "Slegers & Love 2022: SD of spin-axis alignment predicted lateral accuracy (r = 0.80) while mean misalignment did not. The taped-stripe capture mode is not shipped and spinAxisTiltDegrees is not carried on Diagnosis, so lateralSDCm is what is scored."),
                purpose: "Turn an invisible fault into a visible one — the stripe shows the axis the hand actually left on.",
                filmFrom: .behindShooter,
                methodGrade: .b,
                source: "Reused from `FixLibrary`'s spin-axis package. Slegers & Love 2022: SD of spin-axis alignment predicted lateral accuracy (r = 0.80) while mean misalignment did not. The taped-stripe capture mode is not shipped yet."),
            CurriculumDrill(
                drill: Drill(name: "One-hand form set", reps: 10, sets: 4, spots: [.freeThrow],
                             constraint: "A shot counts only if the ball came back at you flat, with your guide hand off it completely.",
                             schedule: "One spot close to the ring, all four sets.",
                             setup: "Close to the ring — free-throw distance at most — with your guide hand behind your back. 10 shots a set, 4 sets.",
                             doThis: "Shoot with your shooting hand only, rolling the ball off your two middle fingers.",
                             watches: "How far left or right of the middle of the ring your shots pass, and how much that varies.",
                             doneWhen: "Next session your left-right spread is clearly tighter than this session's — about \(narrowByPercent) % tighter if you shoot 30 a side, over at least 25 counted shots.",
                             why: "Taking the off hand away stops whatever it was doing to the ball, so your shooting hand's own line can be seen.",
                             detail: "One-hand form shooting is near-universal coaching practice with no controlled measurement behind it that could be found. What is scored is lateralSDCm, not the drill."),
                purpose: "Remove the off hand so whatever it was doing to the ball stops, and the shooting hand's own line can be seen.",
                filmFrom: .behindShooter,
                methodGrade: .d,
                source: "One-hand form shooting is near-universal coaching practice with no controlled measurement behind it that could be found. It is listed because coaches run it and shooters expect it, not because it is established. What is scored is the left–right spread, not the drill."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Your shots stop scattering left and right by more than luck can explain.",
                check: PassCheck(measure: .lateralSDCm, scope: .findingSpot, target: .narrowByDetectableRatio,
                                 description: "next session's left-right spread is clearly tighter than this session's — about \(narrowByPercent) % tighter if you shoot 30 a side",
                                 minimumN: 25,
                                 detail: "lateralSDCm at the finding spot ÷ exp(1.96/√n) — 1.43 at n = 30, so a \(narrowByPercent) % narrowing. Slegers & Love 2022 (spin-axis SD r = 0.80 with lateral accuracy; mean misalignment did not predict); Daly-Grafstein & Bornn 2020 (it is the variance that moves when the shot is disturbed, not the mean)."),
                grade: .a,
                source: "Slegers & Love 2022 (spin-axis SD r = 0.80 with lateral accuracy; mean misalignment did not predict); Daly-Grafstein & Bornn 2020 (it is the variance that moves when the shot is disturbed, not the mean)."),
            DoneCheck(
                plainWords: "Your shots stop favouring one side: the average sits within 3 cm either side of the middle of the ring.",
                check: PassCheck(measure: .lateralMeanCm, scope: .findingSpot, target: .insideBand(low: -3, high: 3),
                                 description: "next session's average left-right miss sits inside 3 cm either side of the middle",
                                 minimumN: 20,
                                 detail: "lateralMeanCm inside ±3 cm, minimum 20 counted shots. Reused verbatim from `FixLibrary`'s lateral-aim package: mean offset near zero in professionals, ±11 cm of ring tolerance either side of the ball (exact geometry)."),
                grade: .a,
                source: "Reused verbatim from `FixLibrary`'s lateral-aim package: mean offset near zero in professionals, ±11 cm of ring tolerance either side of the ball (exact geometry)."),
            DoneCheck(
                plainWords: "The ball comes back at you flat, within 10° of straight backspin.",
                unavailableReason: "The taped-ball mode is not shipped yet, and the app does not carry the tilt on your results, so this cannot be scored. The left-right spread above is what the tilt shows up as, not a substitute for it.",
                detail: "spinAxisTiltDegrees is not carried on Diagnosis. Slegers & Love 2022 for the axis-consistency link; the ±10° band and the 2–3° per-frame resolution are the app's own feasibility numbers (`DESIGN-MEMO-2026-09-13.md` §3.7), not a published range.",
                grade: .b,
                source: "Slegers & Love 2022 for the axis-consistency link; the ±10° band and the 2–3° per-frame resolution are the app's own feasibility numbers (`DESIGN-MEMO-2026-09-13.md` §3.7), not a published range."),
        ],
        faults: [
            CurriculumFault(
                name: "Thumb flick from the off hand",
                howItShowsInNumbers: "A tilted spin, which is not measurable yet, and — when it happens the same way every time — shots that average off to one side. The scatter is what is actually scored.",
                hypothesis: .lateralAimBias,
                grade: .d,
                sources: ["The claim that the off thumb causes the miss is coaching folklore: the retrievable sources are training-aid patent filings (US 10,427,020; US 5,188,356) and coaching sites, not measurement.",
                          "What is grade A is only that lateral *consistency* predicts and the mean does not (Slegers & Love 2022; Daly-Grafstein & Bornn 2020)."]),
            CurriculumFault(
                name: "Guide hand still on the ball at release",
                howItShowsInNumbers: "Nothing directly. Seeing it would need a close waist-up clip and a hand-contact measurement ArcLab does not have; only the left-right scatter can carry it.",
                hypothesis: nil,
                grade: .c,
                sources: ["Coaching consensus with a mechanical rationale (a second contact adds a second force at release); no controlled measurement found."]),
            CurriculumFault(
                name: "\"Thumb up\" / \"hand at three o'clock\" as the rule",
                howItShowsInNumbers: "Nothing. There is no published hand-placement range, and the same coaches teach different clock positions.",
                hypothesis: nil,
                grade: .d,
                sources: ["Coaching-site instruction only (e.g. Revolution Basketball Training, 'guide hand placement'). Listed so it is recognised as unmeasured when a coach says it."]),
        ],
        openQuestions: [
            "This module cannot be scored at all from a side view: everything it touches is left and right, which needs the phone behind you.",
            "The taped-ball mode is the one thing that would turn this module's real subject into a measurement.",
        ])

    // MARK: 5 — Release and follow-through

    public static let releaseAndFollowThrough = CurriculumModule(
        id: .releaseAndFollowThrough,
        title: "Release and follow-through",
        order: 4,
        prerequisites: [.guideHand],
        summary: """
            This is where the accuracy is: the release parameters are what the ball actually leaves \
            with, and the spread of those parameters — the speed channel above all — is the strongest \
            published correlate of shooting percentage there is. The follow-through is the part the \
            shooter can feel; the release speed is the part the app can measure.
            """,
        whatCoachWatches: [
            "Whether the ball leaves the same two fingers at the same moment every shot.",
            "Whether the arc clears the front rim with room, rather than arriving at a chosen number of degrees.",
            "Whether the hand holds its line until the ball lands.",
            "Whether the misses are short, long, or scattered.",
        ],
        cue: "Finish every shot with the ball leaving the same two fingers at the same moment.",
        drills: [
            CurriculumDrill(
                drill: Drill(name: "One-spot depth band", reps: 10, sets: 8, spots: [],
                             constraint: "A shot counts only if it passed inside your own make band. A shot that drops in short or long is called a miss here, because depth is what is being practised.",
                             schedule: "One spot, every set, the whole session — the feel is new.",
                             setup: "One spot, and stay there all session. 10 shots a set, 8 sets.",
                             doThis: "Send every ball to the same point over the back half of the ring.",
                             watches: "How far past the front of the ring each shot passes, and how much the speed you send the ball at varies.",
                             doneWhen: "Next session the speed you send the ball at varies clearly less than this session — about \(narrowByPercent) % less if you shoot 30 a side — and it is still tighter the session after.",
                             why: "How much your release speed varies is the strongest published predictor of shooting percentage there is, at r = −0.96 with three-point percentage in skilled shooters.",
                             detail: "Gate: releaseSpeedSD at the finding spot ÷ exp(1.96/√n). Slegers, Lee & Wong 2021 JSSM: release-velocity SD r = −0.96 with 3P%. The make band is your own, computed from your own makes once there are enough of them, and falls back to the published 25–28 cm band below that floor."),
                purpose: "Score depth rather than the result, so the thing that carries the percentage is the thing being practised.",
                filmFrom: .sideView,
                methodGrade: .a,
                source: "Reused from `FixLibrary`'s speed-variability package. Slegers, Lee & Wong 2021: release-velocity SD r = −0.96 with 3P%. The band itself is your own, computed from your own makes when there are enough of them."),
            CurriculumDrill(
                drill: Drill(name: "Over-the-top", reps: 10, sets: 6, spots: [],
                             constraint: "A shot counts only if it cleared the bar. A shot that would clip it does not count, even if it goes in.",
                             schedule: "One spot, every set.",
                             setup: "One spot. Get a helper to hold a pole about a metre in front of the ring and half a metre above ring height — or picture a bar there. 10 shots a set, 6 sets.",
                             doThis: "Send every ball over the bar and down into the ring.",
                             watches: "The angle your ball is falling at when it reaches the ring.",
                             doneWhen: "Next session your average falling angle is 40° or steeper, over at least 20 counted shots. Steeper than the mid-40s buys nothing, so the app does not ask for it.",
                             why: "Below 40° the ball has under 3 cm of room to fit through the ring, and below about 32° it cannot fit at all — that part is exact geometry, grade A.",
                             detail: "Gate: entryAngleMeanDegrees inside 40–52°, minimum 20 counted shots. The floor is asin(ball diameter ÷ rim diameter) = 31.4° for a 0.2385 m ball, 32.1° at the top of the rulebook tolerance. Daly-Grafstein & Bornn 2020: entry angle is the least peaked of the three rim-plane variables, so there is nothing to gain past the mid-40s."),
                purpose: "Buy room through the ring when the ball is falling at less than 40°, where it has under 3 cm to spare.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "Reused from `FixLibrary`'s flat-arc package. The 40° margin and the ≈32° floor are exact geometry (grade A); that a physical constraint is the way to change the arc is coaching consensus (grade C)."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "The speed you send the ball at varies clearly less than it did, and it is still tighter the session after.",
                check: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot, target: .narrowByDetectableRatio,
                                 description: "next session's shot-to-shot speed spread is clearly tighter than this session's — about \(narrowByPercent) % tighter if you shoot 30 a side",
                                 minimumN: 25,
                                 detail: "releaseSpeedSD at the finding spot ÷ exp(1.96/√n) — 1.43 at n = 30, so a \(narrowByPercent) % narrowing. Slegers, Lee & Wong 2021 JSSM, 12 skilled shooters: velocity SD r = −0.96 with 3-point performance; skilled range 0.05–0.13 m/s."),
                grade: .a,
                source: "Slegers, Lee & Wong 2021 JSSM (n = 12 skilled shooters, matched measurement class): velocity SD r = −0.96 with 3-point performance; skilled range 0.05–0.13 m/s at both free-throw and three-point distance."),
            DoneCheck(
                plainWords: "Your ball falls at 40° or steeper on average, without chasing anything steeper than the mid-40s.",
                check: PassCheck(measure: .entryAngleMeanDegrees, scope: .findingSpot,
                                 target: .insideBand(low: 40, high: 52),
                                 description: "next session's average falling angle is 40° or steeper, and no steeper than the mid-40s",
                                 minimumN: 20,
                                 detail: "entryAngleMeanDegrees inside 40–52°, minimum 20 counted shots. Exact geometry for the floor, asin(d_ball/d_rim) ≈ 31.4–32.1°, under 3 cm of margin by 40°; Daly-Grafstein & Bornn 2020 for make probability being flat over a range of entry angles."),
                grade: .a,
                source: "Exact geometry for the floor (asin(d_ball/d_rim) ≈ 31.4–32.1°, under 3 cm of margin by 40°); Daly-Grafstein & Bornn 2020 for make probability being flat over a range of entry angles. Reused verbatim from `FixLibrary`'s flat-arc package."),
            DoneCheck(
                plainWords: "Your shots pass between 25 and 28 cm past the front of the ring on average.",
                check: PassCheck(measure: .depthMeanCm, scope: .findingSpot,
                                 target: .insideBand(low: depthBandCm.low, high: depthBandCm.high),
                                 description: "next session's average passes between 25 and 28 cm past the front of the ring",
                                 minimumN: 20,
                                 detail: "depthMeanCm inside the published band, minimum 20 counted shots. Daly-Grafstein & Bornn 2019 JQAS: over >50 000 NBA three-point trajectories, make probability peaked 25–28 cm (10–11 in) past the front rim, against a ring centre at 22.9 cm. Measured on NBA threes, not on this shooter."),
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019 JQAS: over >50 000 NBA three-point trajectories, make probability peaked 25–28 cm (10–11 in) past the front rim, against a ring centre at 22.9 cm. Measured on NBA threes, not on this shooter."),
        ],
        faults: [
            CurriculumFault(
                name: "Flat arc",
                howItShowsInNumbers: "Your ball is falling at less than 40° on average, where it has under 3 cm of room to fit through the ring. Below about 32° it cannot fit at all.",
                hypothesis: .flatArcGeometry,
                grade: .a,
                sources: ["Exact geometry: the entry-angle floor is asin(ball diameter / rim diameter), 31.4° for a 0.2385 m ball and 32.1° at the top of the rulebook tolerance.",
                          "Daly-Grafstein & Bornn 2020: entry angle is the least peaked of the three rim-plane variables — there is nothing to gain past the mid-40s."]),
            CurriculumFault(
                name: "Release speed varying shot to shot",
                howItShowsInNumbers: "How much the speed you send the ball at changes from shot to shot, and how much of your front-to-back scatter comes from it. At about 7.2 m/s over 5.3 m, a change of 0.1 m/s is roughly 15 cm at the ring.",
                hypothesis: .speedVariability,
                grade: .a,
                sources: ["Slegers, Lee & Wong 2021 (the correlation); the speed-to-depth conversion is the exact range derivative, so it is geometry."]),
            CurriculumFault(
                name: "Short misses",
                howItShowsInNumbers: "Misses that left your hand slower than your makes did, and an average that passes short of the 25–28 cm band.",
                hypothesis: .depthBiasShort,
                grade: .a,
                sources: ["Mullineaux & Uhl 2010: misses released −0.12 ± 0.10 m/s below optimal vs −0.02 ± 0.07 for swishes (grade B, 3 makes vs 3 misses per subject).",
                          "Daly-Grafstein & Bornn 2019/2020 for the band and for contests biasing shots short."]),
            CurriculumFault(
                name: "Elbow flaring away from vertical",
                howItShowsInNumbers: "How far your forearm leans away from upright, seen from behind you. ArcLab's elbow numbers today come from a side view and cannot see the lean at all.",
                hypothesis: .forearmFlare,
                grade: .b,
                sources: ["Cabarkapa & Fry 2021 CEJSSM: proficient 7.9 ± 7.2° vs non-proficient 19.8 ± 17.6° from vertical — between groups, 17 recreationally active males, one session.",
                          "\"Keep the elbow under the ball\" as a universal instruction is grade D: Cabarkapa et al. 2022 found no kinematic differences at all between excellent and good professionals."]),
            CurriculumFault(
                name: "\"Shoot 45° arc\"",
                howItShowsInNumbers: "It is not a fault and not a target. The mid-40s is where NBA makes happen to cluster; the same NBA player shoots about 38° from mid-range, 45° from three and 53° from the line.",
                hypothesis: nil,
                grade: .d,
                sources: ["Slegers 2022 IJPAS: each shooter's optimal release angle sits 4.3 ± 2.1° above their own minimum-velocity angle and correlates r = 0.78 with their own release covariance — the right angle is individual by construction.",
                          "The 45° universal traces to vendor marketing with no published method (Noah, 'Building the Perfect Arc'), and to per-shot-type averages misread as targets (Nylon Calculus 2018)."]),
            CurriculumFault(
                name: "\"Hold the follow-through for two seconds\"",
                howItShowsInNumbers: "Nothing. It is a way of keeping your hand still long enough not to disturb the ball; nobody has ever measured how long to hold it.",
                hypothesis: nil,
                grade: .d,
                sources: ["Coaching consensus with no measurement. The measurable consequence a coach is after is a narrower left–right spread, which is the guide-hand module's gate."]),
        ],
        openQuestions: [
            "Studies disagree about whether shooting from higher helps, so the app shows your release height as background to your release angle and never as something to change.",
            "The forearm lean needs the phone behind you and an angle ArcLab does not yet carry on your session summary.",
        ])

    // MARK: 6 — Range

    public static let range = CurriculumModule(
        id: .range,
        title: "Range",
        order: 5,
        prerequisites: [.dipAndRhythm, .releaseAndFollowThrough],
        summary: """
            Range is not a distance you can reach; it is the distance at which your shot still behaves \
            like your shot. The published signature of a shooter who has range is not a bigger number \
            anywhere — it is that the speed you send the ball at does not start varying more when the \
            distance goes up. Skilled shooters varied no more from three than from the free-throw line.
            """,
        whatCoachWatches: [
            "Whether the release-speed spread widens when the shooter steps back.",
            "Whether the tempo changes to buy the extra distance.",
            "Whether the arc collapses at the far spot.",
            "Whether the extra distance comes from the floor or from the arm.",
        ],
        cue: "From every distance, send the ball over the front rim to the same spot on the back of the ring.",
        drills: [
            CurriculumDrill(
                drill: Drill(name: "Distance ladder", reps: 5, sets: 16,
                             spots: [.freeThrow, .elbow, .midRange, .three],
                             constraint: "Step back only after two shots in a row pass inside your own make band. Step forward again the moment three in a row miss it.",
                             schedule: "Stay in distance order for your first two sessions, then shuffle the distances.",
                             setup: "Four distances: free throws, elbow, mid-range and three. 5 shots at each, four rounds — 80 shots.",
                             doThis: "Send the ball to the same point over the back of the ring from every distance.",
                             watches: "How much the speed you send the ball at varies at your far spot, against your near spot.",
                             doneWhen: "Your far spot's speed spread is no more than about \(widerByPercent) % wider than your near spot's. Anything closer than that, 30 shots a side cannot tell from luck.",
                             why: "Shooters with real range do not get more variable when they step back: skilled shooters' speed varied the same amount from three as from the free-throw line.",
                             detail: "Gate: releaseSpeedSDRatioAcrossDistance inside 0–1.43, minimum 25 counted shots. 1.43 is DoctorStats.detectableSDRatio(n: 30) = exp(1.96/√30) — arithmetic from the shipped code, not a published threshold. Slegers, Lee & Wong 2021: skilled velocity SD 0.086 vs 0.089 m/s at free-throw and three-point range. Variable-distance practice equalled constant practice on delayed retention (Shoenfelt et al. 2002, 94 participants, randomised, 3 weeks); blocked beats random during acquisition and loses on retention and transfer (Shamshiri 2025, ηp² = 0.24)."),
                purpose: "Let the far spot be earned by the near one, and measure both on the same day so the comparison means something.",
                filmFrom: .sideView,
                methodGrade: .b,
                source: "Reused from `FixLibrary`'s range package. Variable-distance practice equalled constant practice on delayed retention despite worse practice performance (Shoenfelt et al. 2002, 94 participants, randomised, 3 weeks) — it is not better, it is not worse, and it is the only way to measure the ratio."),
            CurriculumDrill(
                drill: Drill(name: "Step-in range extension", reps: 6, sets: 8, spots: [.midRange, .three],
                             constraint: "A shot counts only if the step and the shot were one movement. Record the stepping sets and the standing sets separately so the two can be compared.",
                             schedule: "Alternate: one stepping set, one standing set.",
                             setup: "Mid-range and three. 6 shots a set, 8 sets — four stepping, four standing.",
                             doThis: "Take one step into the shot from behind the line so your legs supply the extra distance.",
                             watches: "How fast your knees straighten and how much your release speed varies — stepping sets against standing sets.",
                             doneWhen: "Done when you have four sets each way at the same spot and the app can show you which way your own numbers went. There is no pass mark: nobody has published a target for how fast one person's knees should straighten.",
                             why: "Experts get extra distance by changing how fast they send the ball rather than by bending more, so \"use your legs\" is a thing to test on yourself, not a rule.",
                             detail: "Okazaki & Rodacki 2012: experts showed no significant ankle/knee/hip change with distance and compensated with release speed. kneeDriveChangeAcrossDistance is reported, not scored — no published target exists for an individual."),
                purpose: "Find out whether the far-spot problem is power or technique, by supplying the power a different way.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "Reused from `FixLibrary`'s arm-dominant package. Okazaki & Rodacki 2012 found experts compensated for distance with release speed rather than with joint-angle change, so 'use the legs' is a hypothesis to test on your own sets, not a prescription."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Your shot does not get more variable when you step back: the far spot's speed spread is no more than about \(widerByPercent) % wider than the near spot's.",
                check: PassCheck(measure: .releaseSpeedSDRatioAcrossDistance, scope: .acrossDistance,
                                 target: .insideBand(low: 0, high: notWiderRatio),
                                 description: "your far spot's speed spread is no more than about \(widerByPercent) % wider than your near spot's, which is the smallest widening 30 shots a side can tell from luck",
                                 minimumN: 25,
                                 detail: "releaseSpeedSDRatioAcrossDistance inside 0–1.43, minimum 25 counted shots. 1.43 is `DoctorStats.detectableSDRatio(n: 30) = exp(1.96/√30)` — arithmetic from the shipped code, not a published threshold. Slegers, Lee & Wong 2021: skilled velocity SD was the same at free-throw and three-point range, 0.086 vs 0.089 m/s."),
                grade: .a,
                source: "Slegers, Lee & Wong 2021: skilled velocity SD was the same at free-throw and three-point range (0.086 vs 0.089 m/s). The 1.43 is `DoctorStats.detectableSDRatio(n: 30) = exp(1.96/√30)` — arithmetic from the shipped code, not a published threshold."),
            DoneCheck(
                plainWords: "The speed you send the ball at from your far spot stops varying so much in its own right.",
                check: PassCheck(measure: .releaseSpeedSD, scope: .farSpot, target: .narrowByDetectableRatio,
                                 description: "next session's speed spread at your far spot is clearly tighter than this session's — about \(narrowByPercent) % tighter if you shoot 30 there",
                                 minimumN: 25,
                                 detail: "releaseSpeedSD at the far spot ÷ exp(1.96/√n) — 1.43 at n = 30, so a \(narrowByPercent) % narrowing. Reused verbatim from `FixLibrary`'s range package; Slegers 2021 for why the speed channel leads."),
                grade: .a,
                source: "Reused verbatim from `FixLibrary`'s range package. Slegers 2021 for why the speed channel leads."),
            DoneCheck(
                plainWords: "Your arc holds up at the far spot: the ball still falls at 40° or steeper instead of flattening out to reach.",
                check: PassCheck(measure: .entryAngleMeanDegrees, scope: .farSpot,
                                 target: .insideBand(low: 40, high: 52),
                                 description: "your far-spot average falling angle is 40° or steeper",
                                 minimumN: 20,
                                 detail: "entryAngleMeanDegrees at the far spot inside 40–52°, minimum 20 counted shots. Exact geometry for the floor and the 3 cm margin at 40°; Okazaki & Rodacki 2012 for release angle falling with distance (grade B), which is why the far spot is where this is checked."),
                grade: .a,
                source: "Exact geometry for the floor and the 3 cm margin at 40°; Okazaki & Rodacki 2012 for release angle falling with distance in the first place (grade B), which is why the far spot is where this is checked."),
        ],
        faults: [
            CurriculumFault(
                name: "Running out of power at range",
                howItShowsInNumbers: "The speed you send the ball at varies clearly more at the far spot than at the near one, and your misses fall short.",
                hypothesis: .rangeStrengthLimit,
                grade: .a,
                sources: ["Slegers, Lee & Wong 2021: skilled shooters' velocity SD was the *same* at both distances, so a widening ratio is a departure from the skilled pattern.",
                          "Okazaki & Rodacki 2012: accuracy falls 59 % → 37 % from 2.8 m to 6.4 m even in experts, so some fall-off is normal and only the spread ratio is scored."]),
            CurriculumFault(
                name: "Arc collapsing at the far spot",
                howItShowsInNumbers: "Your ball falls at less than 40° at the far spot while it still clears 40° at the near one.",
                hypothesis: .flatArcGeometry,
                grade: .a,
                sources: ["Exact geometry for the margin; Okazaki & Rodacki 2012 for release angle falling with distance (grade B)."]),
            CurriculumFault(
                name: "Rushing the far shots",
                howItShowsInNumbers: "Your time from the bottom of the dip to the release is shorter at the far spot than at the near one, by more than your near-spot times vary among themselves.",
                hypothesis: .rushedPreparation,
                grade: .b,
                sources: ["Cabarkapa et al. 2023 and Botsi et al. 2024, which disagree on direction — so it is your own change across distance that is read, not a published tempo."]),
            CurriculumFault(
                name: "Shooting with the arm at range",
                howItShowsInNumbers: "Your knees do not straighten any faster as you step back while the ball leaves faster. It needs a close form clip, and the joint number is reported rather than scored.",
                hypothesis: .armDominantDrive,
                grade: .b,
                sources: ["Cabarkapa et al. 2023 (between-group knee angular velocity); Okazaki & Rodacki 2012 (experts changed speed, not joint angles)."]),
            CurriculumFault(
                name: "\"Shoot from further back to build range\"",
                howItShowsInNumbers: "Nothing measures the method. What the app can see is whether the gap between your far-spot and near-spot spreads moved.",
                hypothesis: nil,
                grade: .d,
                sources: ["No study tested shooting beyond one's range as a range-building method. The nearest tested thing is variable-distance practice, which merely *equalled* constant practice on delayed retention (Shoenfelt et al. 2002, grade B)."]),
        ],
        openQuestions: [
            "Comparing far with near needs both spots filmed the same way. Two spots filmed on different days from different camera positions are not a comparison worth reading.",
            "Whether strength work shrinks the far-spot spread is untested here, and ArcLab does not measure it.",
        ])

    // MARK: 7 — Off the dribble

    public static let offTheDribble = CurriculumModule(
        id: .offTheDribble,
        title: "Off the dribble",
        order: 6,
        prerequisites: [.footwork, .range],
        summary: """
            Everything so far has been measured on a shot that started from a catch or a stand-still. \
            The off-the-dribble shot is the same shot arriving from a worse place, and the honest \
            framing is a comparison: your pull-up blocks against your catch blocks at the same spot on \
            the same day. There is no peer-reviewed kinematic comparison of the two to import.
            """,
        whatCoachWatches: [
            "Whether the gather leaves the feet where the catch-and-shoot version leaves them.",
            "Whether the ball reaches the same set point out of the dribble as off a catch.",
            "Whether the tempo out of the gather matches the stand-still tempo.",
            "Whether the shooter is still travelling sideways when the ball goes.",
        ],
        cue: "Pick the ball up into the same place it starts from on a catch.",
        drills: [
            CurriculumDrill(
                drill: Drill(name: "Pull-up pair", reps: 6, sets: 8, spots: [.elbow, .midRange],
                             constraint: "A set counts only if the whole set was one kind of shot, from the same mark, with the phone in the same place. Record each set on its own so catch sets and pull-up sets can be compared.",
                             schedule: "Alternate: one catch set, one pull-up set, in that order every time — the comparison is the point, not the mix.",
                             setup: "The elbow and mid-range, with a chalk mark to shoot from. 6 shots a set, 8 sets — four catch, four pull-up.",
                             doThis: "On pull-up sets, take one dribble and shoot from the same mark the catch sets used.",
                             watches: "How much your release speed and your depth past the front of the ring vary — pull-up sets against catch sets.",
                             doneWhen: "Your pull-up sets vary no more than about \(widerByPercent) % more than your catch sets. Anything closer than that, 30 shots a side cannot tell from luck.",
                             why: "Nobody has compared catch shooting with pull-up shooting in a laboratory, so the honest version is the comparison you run on yourself.",
                             detail: "Gate: releaseSpeedSD, pull-up block at or below 1.43 × the catch block's — `DoctorStats.detectableSDRatio(n: 30)`. The A-B design is the one `DESIGN-MEMO-2026-09-13.md` §C1 asks for; no peer-reviewed kinematic comparison of catch-and-shoot against off-the-dribble release parameters was found."),
                purpose: "Measure the cost of the dribble instead of guessing it.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "The A-B design is sound (it is the design `DESIGN-MEMO-2026-09-13.md` §C1 asks for); the claim that a pull-up should match a catch is coaching consensus. No peer-reviewed kinematic comparison of catch-and-shoot against off-the-dribble release parameters was found."),
            CurriculumDrill(
                drill: Drill(name: "Gather tempo match", reps: 8, sets: 6, spots: [.elbow],
                             constraint: "A shot counts only if it left inside your own catch-and-shoot rhythm time, whatever it does at the ring.",
                             schedule: "One spot, every set, until the rhythm repeats itself.",
                             setup: "The elbow, with a chalk mark to shoot from. 8 shots a set, 6 sets.",
                             doThis: "Take one dribble to the mark and shoot on the same count you use off a catch.",
                             watches: "The time from the lowest point of the ball to the release, pull-up against catch.",
                             doneWhen: "There is no pass mark. Your target is your own catch-and-shoot rhythm, and matching it off the dribble has never been tested by anyone.",
                             why: "Stopping the dribble from squeezing your rhythm is an idea, not a finding.",
                             detail: "The rhythm band is your own measured dip→release spread. No published reference exists for gather time in any population."),
                purpose: "Stop the dribble from compressing the tempo the rhythm module just settled.",
                filmFrom: .sideView,
                methodGrade: .d,
                source: "In-house: the tempo band is your own measured dip→release spread, and matching it off the dribble is an untested hypothesis rather than a published finding."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Recorded as two sets at the same spot, your pull-up shots vary no more than about \(widerByPercent) % more than your catch shots.",
                check: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot,
                                 target: .narrowByFraction(notWiderRatio),
                                 description: "your pull-up set's speed spread is no more than about \(widerByPercent) % wider than your catch set's, which is the smallest widening 30 shots a side can tell from luck",
                                 minimumN: 25,
                                 detail: "releaseSpeedSD, pull-up block at or below 1.43 × the catch block's. The versatility definition in healthy-shot-model-2026-09-14.md §4: a versatile shot is one whose release-speed and depth spread do not inflate when the condition changes (Slegers 2021 across distance; Amaro et al. 2025 across defender and noise; Daly-Grafstein & Bornn 2020 for contests raising variance 56 %/38 % without moving the mean). The 1.43 is `DoctorStats.detectableSDRatio(n: 30)` — arithmetic."),
                grade: .a,
                source: "The versatility definition in healthy-shot-model-2026-09-14.md §4: a versatile shot is one whose release-speed and depth spread do not inflate when the condition changes (Slegers 2021 across distance; Amaro et al. 2025 across defender and noise; Daly-Grafstein & Bornn 2020 for contests raising variance 56 %/38 % without moving the mean). The 1.43 is `DoctorStats.detectableSDRatio(n: 30)` — arithmetic."),
            DoneCheck(
                plainWords: "Off the dribble your shots still pass between 25 and 28 cm past the front of the ring on average.",
                check: PassCheck(measure: .depthMeanCm, scope: .findingSpot,
                                 target: .insideBand(low: depthBandCm.low, high: depthBandCm.high),
                                 description: "your pull-up set's average passes between 25 and 28 cm past the front of the ring",
                                 minimumN: 20,
                                 detail: "depthMeanCm inside the published band, minimum 20 counted shots. Daly-Grafstein & Bornn 2019 JQAS for the band; that contested and disturbed shots bias short is 2020, same authors."),
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019 JQAS for the band; that contested and disturbed shots bias short is 2020, same authors."),
            DoneCheck(
                plainWords: "Your step into the shot repeats: same foot first, same timing, no sliding sideways.",
                unavailableReason: "ArcLab cannot see feet land, cannot time the gather and cannot see a sideways slide yet, and nothing has been filmed off the dribble to build them on. The numbers a drill would use — a 0.35 s gather, a slide under a tenth of your height — are in-house guesses with nothing published behind them, and will be reported, never scored.",
                detail: "Track C (`docs/PLAN-1.1-2026-09-15.md`, `docs/DESIGN-FOOTWORK-2026-09-15.md`). No published reference range exists for gather time or lateral drift in any population.",
                grade: .d,
                source: "`docs/PLAN-1.1-2026-09-15.md` Track C. No published reference range exists for gather time or drift in any population."),
        ],
        faults: [
            CurriculumFault(
                name: "Everything widens off the dribble",
                howItShowsInNumbers: "Your release speed and your depth both vary more on the pull-up sets than on the catch sets, at the same spot on the same day.",
                hypothesis: .speedVariability,
                grade: .a,
                sources: ["The measure is grade A (Slegers, Lee & Wong 2021). That the dribble is what widened it is your own block comparison, not a published fact — no kinematic comparison of the two shot types was found."]),
            CurriculumFault(
                name: "Drifting sideways out of the dribble",
                howItShowsInNumbers: "Your pull-up shots average off to one side when your catch shots do not. It needs the phone behind you.",
                hypothesis: .lateralAimBias,
                grade: .c,
                sources: ["Daly-Grafstein & Bornn 2020 for disturbance showing in lateral spread (grade A); the attribution to the dribble is a coaching inference."]),
            CurriculumFault(
                name: "Rushing the gather",
                howItShowsInNumbers: "Your time from the bottom of the dip to the release is shorter on the pull-up sets than your own catch sets ever go.",
                hypothesis: .rushedPreparation,
                grade: .c,
                sources: ["No published gather-time reference exists in any population; only your own two blocks can be compared."]),
            CurriculumFault(
                name: "\"Catch-and-shoot is 20–40 % better than off the dribble\"",
                howItShowsInNumbers: "Nothing you can act on. It is an average over play types from game data, which mixes shot selection, defence and the clock in with technique.",
                hypothesis: nil,
                grade: .d,
                sources: ["Breakthrough Basketball's analytics summary quotes ~20 % (NBA) to ~40 % (college women) — aggregator, no method, no control for shot selection. healthy-shot-model-2026-09-14.md §4 grades it D."]),
            CurriculumFault(
                name: "\"You stepped wrong\"",
                howItShowsInNumbers: "Nothing today, and no study supports the idea that one step order is the correct one. When the app can see feet land it will be able to say whether your step *repeated* — a different and answerable question.",
                hypothesis: nil,
                grade: .d,
                sources: ["No peer-reviewed comparison of step orders into a jump shot was found (searched 2026-09-15).",
                          "The Sport Journal foot-placement study found no significant effect of foot placement on accuracy (11 NCAA D-I women)."]),
        ],
        openQuestions: [
            "Nothing has been filmed off the dribble yet. Until some is, every pass mark in this module is a design rather than a result.",
            "A pull-up and a catch shot recorded on different days are not a comparison. This module needs both sets on the same day, same spot, same camera.",
        ])

    // MARK: 8 — Game speed

    public static let gameSpeed = CurriculumModule(
        id: .gameSpeed,
        title: "Game speed",
        order: 7,
        prerequisites: [.offTheDribble],
        summary: """
            The last module is the one where the coaching instinct and the evidence disagree most \
            usefully. At skilled level a defender and crowd noise changed nothing measurable about the \
            release parameters; what changes under game conditions is the *spread*, and what changes \
            with fatigue is measurable but is not universal — elite juniors showed none at all. So \
            this module measures drift on you instead of assuming it.
            """,
        whatCoachWatches: [
            "Whether the last set of the session looks like the first.",
            "Whether the shot survives a clock and a contest, or only survives an empty gym.",
            "Whether the arc falls late in the session.",
            "Whether what changes is the average or the spread — under pressure it is usually the spread.",
        ],
        cue: "Treat the last set like the first one: same routine, same tempo.",
        drills: [
            CurriculumDrill(
                drill: Drill(name: "Bookend sets", reps: 10, sets: 6, spots: [],
                             constraint: "Only the four counted sets count — two at the start and two at the end, same spot. What you shoot in between is yours.",
                             schedule: "Two counted sets at the start, two at the end, with rest in between and free shooting in the middle.",
                             setup: "One spot, the same all session, with the phone in the same place at the start and at the end. 10 shots a set, 6 sets.",
                             doThis: "Shoot your last set exactly the way you shot your first: same routine, same tempo.",
                             watches: "How much the speed you send the ball at varies late in the session, against how much it varied at the start.",
                             doneWhen: "Your late sets vary no more than about \(widerByPercent) % more than your first sets. Anything closer than that, 30 shots a side cannot tell from luck.",
                             why: "Measuring the drop-off beats assuming it: elite juniors showed no drop at all after hard running, so the first and last sets are the whole experiment.",
                             detail: "Textbook Ch 15 §15.3.4: report the total change across the session, not a slope and not a p-value. A set-of-10 mean depth has a standard error of 4.7 cm, so one first/last pair can only resolve a 13 cm change; three session pairs pooled resolve about 7.6 cm."),
                purpose: "Measure the drift rather than assume it — the first and last blocks are the whole experiment.",
                filmFrom: .sideView,
                methodGrade: .a,
                source: "Reused from `FixLibrary`'s within-session-drift package. Textbook Ch 15 §15.3.4: report the total change across the session, not a slope and not a p-value. A set-of-10 mean depth has a standard error of 4.7 cm, so one pair can only see a 13 cm change."),
            CurriculumDrill(
                drill: Drill(name: "Rested blocks", reps: 10, sets: 6, spots: [],
                             constraint: "Stop at the set where your falling angle has dropped by more than it normally varies, instead of pushing through it.",
                             schedule: "One spot, every set, with sixty seconds of rest between them — the rest is the thing being tested.",
                             setup: "One spot, and a timer for the rest. 10 shots a set, 6 sets.",
                             doThis: "Rest a full sixty seconds between sets, and stop the session when your arc drops rather than shooting through it.",
                             watches: "The angle your ball is falling at, from the start of the session to the end.",
                             doneWhen: "There is no pass mark. The app shows how your falling angle moved across the session, and you pick the rest that keeps it flat.",
                             why: "Twelve minutes of game-like load cost high-level players 3–4 % of their falling angle and 14–19 % of their makes — but elite juniors lost nothing at all, so it is measured on you rather than assumed.",
                             detail: "Bourdas et al. 2024: after 12 min of simulated game load in 38 high-level players, entry angle −3.1 to −3.9 %, release time +15–25 %, makes −14 to −19 %. Li et al. 2025 meta: SMD 0.67 moderate, 1.39 severe. Slawinski et al. 2018: zero release change in elite U18s after sprints."),
                purpose: "Find the rest interval at which your own drift disappears, instead of training through it.",
                filmFrom: .sideView,
                methodGrade: .b,
                source: "Reused from `FixLibrary`'s fatigue package. Bourdas et al. 2024: after 12 min of simulated game load in 38 high-level players, entry angle −3.1 to −3.9 %, release time +15–25 %, makes −14 to −19 %. Li et al. 2025 meta: SMD 0.67 moderate, 1.39 severe. Slawinski et al. 2018: zero release change in elite U18s after sprints."),
            CurriculumDrill(
                drill: Drill(name: "Clock sets", reps: 8, sets: 6, spots: [.midRange, .three],
                             constraint: "A shot counts only if it left inside four seconds of the catch. A late shot does not count, wherever it goes.",
                             schedule: "Near spot first, every set, then the far spot.",
                             setup: "Mid-range and three, with a passer or a self-toss and a four-second count. 8 shots a set, 6 sets.",
                             doThis: "Catch and get the shot away inside a four-second count.",
                             watches: "How much the speed you send the ball at varies under the count, against your unhurried sets.",
                             doneWhen: "There is no pass mark for the count itself. What is scored is whether your release speed stays as steady under it as it is without it.",
                             why: "A clock makes the drill resemble a possession rather than a drill — every coach uses time pressure and nobody has measured what it does to technique.",
                             detail: "No controlled measurement of time-pressure drills on shooting mechanics was found. The constraints-led literature is quasi-experimental with no shooting-mechanics outcome (grade C)."),
                purpose: "Put a constraint on the shot that resembles a possession rather than a drill.",
                filmFrom: .sideView,
                methodGrade: .d,
                source: "Time-pressure drills are near-universal coaching practice with no controlled measurement found for shooting mechanics. The constraints-led literature is quasi-experimental with no shooting-mechanics outcome (grade C)."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Your late sets are no more variable than your first ones: the speed spread is no more than about \(widerByPercent) % wider.",
                check: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot,
                                 target: .narrowByFraction(notWiderRatio),
                                 description: "your late set's speed spread is no more than about \(widerByPercent) % wider than your first set's, which is the smallest widening 30 shots a side can tell from luck",
                                 minimumN: 25,
                                 detail: "releaseSpeedSD, late block at or below 1.43 × the first block's. healthy-shot-model-2026-09-14.md §4: the defensible definition of versatility is unchanged spread across conditions. Amaro et al. 2025 (18 national-level players, 90 shots each): no significant effect of a 1.2×-height defender at 1 m or 105 dBA noise on jump height, release height, angle or velocity (all p ≥ 0.092). The ratio is arithmetic."),
                grade: .a,
                source: "healthy-shot-model-2026-09-14.md §4: the defensible definition of versatility is unchanged spread across conditions. Amaro et al. 2025 (18 national-level players, 90 shots each): no significant effect of a 1.2×-height defender at 1 m or 105 dBA noise on jump height, release height, angle or velocity (all p ≥ 0.092). The ratio is arithmetic."),
            DoneCheck(
                plainWords: "Late in the session your ball still falls at 40° or steeper.",
                check: PassCheck(measure: .entryAngleMeanDegrees, scope: .findingSpot,
                                 target: .insideBand(low: 40, high: 52),
                                 description: "your late set's average falling angle is 40° or steeper, the same as your first set's",
                                 minimumN: 20,
                                 detail: "entryAngleMeanDegrees inside 40–52°, minimum 20 counted shots. Bourdas et al. 2024 for entry angle being the channel that falls under game load (−3.1 to −3.9 %); the 40° band is exact geometry."),
                grade: .a,
                source: "Bourdas et al. 2024 for entry angle being the channel that falls under game load (−3.1 to −3.9 %); the 40° band is exact geometry. That it falls for *you* is measured, never assumed — Slawinski et al. 2018 found no change in elite U18s."),
            DoneCheck(
                plainWords: "Your shot does not change from the start of the session to the end.",
                unavailableReason: "The change across a whole session is shown on your results as a trend rather than as a pass mark, so it cannot finish the module. Compare a first set with a last set instead — one pair can only see a change of about 13 cm in how deep your shots pass.",
                detail: "depthTotalChangeOverSession comes from the over-session read-out, not the pass-check reader. Textbook Ch 15 §15.3.4; the 4.7 cm standard error of a set-of-10 mean depth is arithmetic (`DESIGN-MEMO-2026-09-13.md` §3.5).",
                grade: .a,
                source: "Textbook Ch 15 §15.3.4; the 4.7 cm standard error of a set-of-10 mean depth is arithmetic (`DESIGN-MEMO-2026-09-13.md` §3.5)."),
        ],
        faults: [
            CurriculumFault(
                name: "Fading late in the session",
                howItShowsInNumbers: "Your ball falls at a shallower angle and takes longer to leave your hand between the first sets and the last ones, with the makes following.",
                hypothesis: .fatigueDrift,
                grade: .a,
                sources: ["Bourdas et al. 2024 (38 high-level players, 12-min simulated game protocol).",
                          "Li et al. 2025 meta-analysis of 14 studies, n = 388: accuracy SMD 0.67 moderate, 1.39 severe."]),
            CurriculumFault(
                name: "The shot drifting through the session",
                howItShowsInNumbers: "The total change in how deep your shots pass, from the first counted shot to the last, reported as a total and never as a trend line.",
                hypothesis: .withinSessionDrift,
                grade: .a,
                sources: ["Textbook Ch 15 §15.3.4. That drift can happen is established; that it happens to you is measured (Slawinski et al. 2018 found none in elite U18s)."]),
            CurriculumFault(
                name: "\"Fatigue always flattens your arc\"",
                howItShowsInNumbers: "Sometimes nothing at all. Elite juniors showed no change at all after repeated sprints, and being moderately tired had no significant effect on three-point shooting in the pooled studies.",
                hypothesis: nil,
                grade: .d,
                sources: ["Slawinski et al. 2018 (no release change after repeated sprints in elite U18s).",
                          "Li et al. 2025 (no significant three-point effect at moderate fatigue). Measure drift; never assume it."]),
            CurriculumFault(
                name: "\"A defender changes your mechanics\"",
                howItShowsInNumbers: "At skilled level, not measurably — what widens is the scatter, not the average. In NBA games, contested shots scattered 56 % more front to back and 38 % more left to right without the technique changing.",
                hypothesis: nil,
                grade: .a,
                sources: ["Amaro et al. 2025: no significant effect of opposition or noise on jump height, release height, release angle or velocity in 18 national-level players (all p ≥ 0.092, η²p ≤ 0.004).",
                          "Daly-Grafstein & Bornn 2020: tight contests biased shots short and raised depth variance 56 %, lateral variance 38 %."]),
        ],
        openQuestions: [
            "ArcLab cannot film a defender or a shot clock, so this module is scored on sets inside your own session, which is a weaker test than a game.",
            "Spotting drift needs a first and a last set at the same spot in the same session, and one pair only shows a big change — three session pairs together show about 7.6 cm.",
        ])

    // MARK: 9 — Ball handling
    //
    // Added 2026-09-19 for 1.4 "game": *"I want to add ball handling drills. These should be as
    // applicable to game situations as possible."*
    //
    // The honest shape of this module is set by one fact: **ArcLab has no ball-handling measure.**
    // There is no detector for the ball in a hand, no published reference range for any dribbling
    // quantity in skilled players, and nothing filmed. So no gate here scores a dribble. Every drill
    // instead ends in the shot that came out of the move — which is the shot the app already
    // measures, and which is what a game actually asks the handling to produce — and every gate on
    // the handling itself is a count the shooter keeps, said in those words.
    //
    // Research: `docs/research/ball-handling-and-transfer-2026-09-19.md`. No controlled trial of
    // ball-handling training with a game outcome was found (searched 2026-09-19), which is why the
    // method grades below are C and D.

    public static let ballHandling = CurriculumModule(
        id: .ballHandling,
        title: "Ball handling",
        order: 8,
        prerequisites: [.base],
        summary: """
            This is the part of the app with the least behind it, and it says so first. ArcLab cannot \
            see a dribble at all: no detector, no published range to compare you with, nothing filmed. \
            So nothing here is scored on your handling. What each drill does instead is finish in a \
            shot, because the shot is the thing the app can measure and the thing the move exists to \
            produce. The counts on the moves themselves are yours, and the app stores them as your \
            word rather than as a measurement.
            """,
        whatCoachWatches: [
            "Whether the ball is on the side of your body the defender cannot reach.",
            "Whether the change of speed moves the defender, or only moves you.",
            "Whether you come out of the move balanced enough to shoot your own shot.",
            "Whether your eyes are on the floor or on what is in front of you.",
        ],
        cue: "Move the defender first, then take the space they give you.",
        drills: [
            CurriculumDrill(
                drill: Drill(name: "Get to your spot", reps: 6, sets: 5, spots: [.elbow],
                             constraint: "A shot counts only if your partner stayed within an arm's length until you picked the ball up. If they stood off you, it was not the drill.",
                             schedule: "Change which side your partner starts on every set, rather than doing all the right-hand sets first.",
                             setup: "The elbow, with a chalk mark to shoot from and a partner starting on your hip. 6 shots a set, 5 sets.",
                             doThis: "Get to the mark with the ball on the far side of your body, then shoot.",
                             watches: "The shot at the end: how much the speed you send the ball at varies, against your calm sets at the same mark.",
                             doneWhen: "Your shots out of the move vary no more than about \(widerByPercent) % more than your calm sets. Whether you actually beat your partner is counted by you, not measured by the app.",
                             why: "Practising a move on its own and practising it into a shot are different skills, and only the second one is what a game asks for.",
                             detail: "Gate: releaseSpeedSD out of the move at or below 1.43 × your own un-cued block at the same spot — `DoctorStats.detectableSDRatio(n: 30)`. Whether the handling improved is not measured: there is no ball-handling metric in ArcLab and no controlled trial of one (`docs/research/ball-handling-and-transfer-2026-09-19.md` §1.1, §1.3)."),
                purpose: "Tie getting to your spot against a defender's hip to the shot it is supposed to produce.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "Keeping the ball on the far hip is coaching consensus with a clear reason and no controlled measurement; no trial of a ball-handling drill against a game outcome was found (`docs/research/ball-handling-and-transfer-2026-09-19.md` §1.1). The shot measure it closes on is grade A (Slegers, Lee & Wong 2021)."),
            CurriculumDrill(
                drill: Drill(name: "Change of pace pull-up", reps: 6, sets: 6, spots: [.elbow, .midRange],
                             constraint: "A shot counts only if the slow part was slow enough that your partner closed the gap. Without that it is one dribble and a shot.",
                             schedule: "Near mark first every set, then the far one.",
                             setup: "The elbow and the mid-range, with a mark to shoot from and a partner to react to you. 6 shots a set, 6 sets.",
                             doThis: "Slow the dribble for two beats, then go hard into one dribble and shoot.",
                             watches: "The speed you send the ball at, and how far past the front of the ring your shots pass.",
                             doneWhen: "Out of the change of pace your shots still pass between 25 and 28 cm past the front of the ring on average.",
                             why: "A defender reacts to a change of speed rather than to the dribble itself, which coaches agree on and nobody has measured.",
                             detail: "Gate: depthMeanCm inside the published 25–28 cm band, minimum 20 counted shots (Daly-Grafstein & Bornn 2019 JQAS, >50 000 NBA trajectories). The claim that the pace change is the active part of the move is grade C — no measurement of it was found."),
                purpose: "Make the change of pace finish in a pull-up, which is the game version of it.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "The pace change is coaching consensus with a rationale and no controlled measurement. The band it is scored on is Daly-Grafstein & Bornn 2019 (grade A)."),
            CurriculumDrill(
                drill: Drill(name: "Escape the trap", reps: 5, sets: 6, spots: [.midRange],
                             constraint: "A go counts only if both partners closed to within an arm's length before you moved.",
                             schedule: "Change which sideline you start on every set.",
                             setup: "The mid-range, with two partners trapping you near the sideline and a mark to shoot from. 5 shots a set, 6 sets.",
                             doThis: "Push the ball back out of the trap with one hard dribble, then get to the mark and shoot.",
                             watches: "Only the shot at the end. ArcLab cannot see a trap, a dribble, or a ball you nearly lost.",
                             doneWhen: "You get out of eight traps in ten with the ball still yours, counted by you, not measured by the app. The shot afterwards is the part the app scores.",
                             why: "A lost ball costs a whole possession, which makes the escape the handling skill with the clearest price on it — and it is taught everywhere and tested nowhere.",
                             detail: "The eight-in-ten mark is a convention, not a finding: no published success rate for escaping a trap exists in any population. The shot afterwards is scored on the ordinary depth and speed gates (`docs/research/ball-handling-and-transfer-2026-09-19.md` §1.3)."),
                purpose: "Practise the one handling mistake that costs a possession outright.",
                filmFrom: .sideView,
                methodGrade: .d,
                source: "In-house: the eight-in-ten mark is a convention with nothing published behind it, and no study of trap escapes was found (searched 2026-09-19)."),
            CurriculumDrill(
                drill: Drill(name: "Pocket dribble read", reps: 6, sets: 5, spots: [.elbow],
                             constraint: "A go counts only if the defender picked one thing to take away rather than standing still. A defender who does nothing gives you nothing to read.",
                             schedule: "Change which way the screen is set every set.",
                             setup: "The elbow, with one partner setting a screen and a second defending it. 6 shots a set, 5 sets.",
                             doThis: "Take one dribble into the pocket behind the screen, read the defender, then shoot or pass.",
                             watches: "The shots you take. The read itself is yours — the app has no way to see a defender or a pass.",
                             doneWhen: "There is no pass mark. Count the reads with your partner and use the app only for the shots you took.",
                             why: "The pocket dribble exists to buy the half-second a read needs, which is coaching convention with a clear reason and no measurement behind it.",
                             detail: "No study of pick-and-roll ball-handler decisions with a measured outcome was found. The app stores the shots and nothing about the read; there is no handling or passing measure in ArcLab."),
                purpose: "Couple the move to a decision, because in a game the move is never the whole task.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "Constraints-led coaching consensus. The nearest evidence is a quasi-experimental game-based training study with no mechanics outcome (grade C, `healthy-shot-model-2026-09-14.md` §7)."),
            CurriculumDrill(
                drill: Drill(name: "Retreat and reset", reps: 6, sets: 5, spots: [.three],
                             constraint: "A shot counts only if you gave up ground first. A shot taken over the top of the pressure is a different shot.",
                             schedule: "One spot, every set, until the shot after the retreat looks like your ordinary one.",
                             setup: "The three-point line, with a partner pressuring you and a mark to step into. 6 shots a set, 5 sets.",
                             doThis: "Retreat two dribbles to win your space back, then step into the shot.",
                             watches: "How much the speed you send the ball at varies, against your calm sets at the same spot.",
                             doneWhen: "Your shots after a retreat vary no more than about \(widerByPercent) % more than your calm sets at the same spot.",
                             why: "Backing out of trouble beats forcing a shot out of it, which every coach says and no study has tested — what can be checked is whether the shot afterwards is still yours.",
                             detail: "Gate: releaseSpeedSD after the retreat at or below 1.43 × your own un-cued block at the same spot. That giving up ground is the better choice is grade D: no study of retreat dribbles was found."),
                purpose: "Keep the shot intact after the move that a game forces most often.",
                filmFrom: .sideView,
                methodGrade: .d,
                source: "In-house: no study of retreat dribbles or of shot selection under pressure at an individual level was found (searched 2026-09-19). The spread measure is grade A."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Out of a move, your shots still pass between 25 and 28 cm past the front of the ring on average.",
                check: PassCheck(measure: .depthMeanCm, scope: .findingSpot,
                                 target: .insideBand(low: depthBandCm.low, high: depthBandCm.high),
                                 description: "your shots out of a move pass between 25 and 28 cm past the front of the ring on average",
                                 minimumN: 20,
                                 detail: "depthMeanCm inside the published band, minimum 20 counted shots. Daly-Grafstein & Bornn 2019 JQAS for the band. Nothing about the move is scored: this gate reads the shot only."),
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019 JQAS for the band, from more than 50 000 tracked NBA trajectories. The gate reads the shot that came out of the move, never the move."),
            DoneCheck(
                plainWords: "Out of a move, your shots are no more scattered than on your calm sets — no more than about \(widerByPercent) % wider.",
                check: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot,
                                 target: .narrowByFraction(notWiderRatio),
                                 description: "your speed spread out of a move is no more than about \(widerByPercent) % wider than on your calm sets, which is the smallest widening 30 shots a side can tell from luck",
                                 minimumN: 25,
                                 detail: "releaseSpeedSD out of the move at or below 1.43 × the calm block's — `DoctorStats.detectableSDRatio(n: 30)`, arithmetic. The versatility definition in healthy-shot-model-2026-09-14.md §4: a versatile shot is one whose spread does not inflate when the condition changes."),
                grade: .a,
                source: "healthy-shot-model-2026-09-14.md §4, on Slegers, Lee & Wong 2021 for release-speed spread predicting makes and Amaro et al. 2025 for the spread being what changes when conditions do. The ratio is arithmetic."),
            DoneCheck(
                plainWords: "Your handling itself got better.",
                unavailableReason: "ArcLab has no way to measure a dribble. There is no detector for the ball in your hand, no published range to compare you with, and nothing has been filmed. Every count on a move in this module is yours, and the app keeps it as your word rather than as something it watched.",
                detail: "`docs/research/ball-handling-and-transfer-2026-09-19.md` §1.1 and §1.3. Searched 2026-09-19 and not found: a controlled trial of ball-handling training with a game outcome, and any published reference range for dribble height, hand speed or change-of-direction time in skilled players.",
                grade: .d,
                source: "`docs/research/ball-handling-and-transfer-2026-09-19.md` §1.1. No controlled trial of ball-handling training with a game outcome was found (searched 2026-09-19)."),
        ],
        faults: [
            CurriculumFault(
                name: "The shot out of the move is not your shot",
                howItShowsInNumbers: "The speed you send the ball at is more scattered on the sets that start with a move than on your calm sets at the same spot on the same day.",
                hypothesis: .speedVariability,
                grade: .a,
                sources: ["The measure is grade A (Slegers, Lee & Wong 2021: velocity spread r = −0.96 with three-point makes across 12 skilled shooters).",
                          "That the move is what widened it is your own comparison of two blocks, not a published fact."]),
            CurriculumFault(
                name: "A move that goes nowhere",
                howItShowsInNumbers: "Nothing at all in the app. A move that does not shift your defender leaves no trace in any number ArcLab records, so this one is your partner's word and yours.",
                hypothesis: nil,
                grade: .c,
                sources: ["Coaching consensus that a move is judged by what the defender does, not by how it looks. No controlled measurement was found (`docs/research/ball-handling-and-transfer-2026-09-19.md` §1.1)."]),
            CurriculumFault(
                name: "\"Two-ball drills make you a better ball handler\"",
                howItShowsInNumbers: "Nothing. No trial of two-ball work against any game outcome was found, and the app cannot see a dribble, so neither the drill nor the claim can be checked here.",
                hypothesis: nil,
                grade: .d,
                sources: ["Searched 2026-09-19 and not found: any controlled trial of two-ball dribbling against a game or transfer outcome. Shipped labelled rather than left out."]),
            CurriculumFault(
                name: "\"Keep your eyes up\"",
                howItShowsInNumbers: "Nothing measurable here. Coaches say it everywhere; no study was found that measured head or eye position while dribbling against any outcome on a court.",
                hypothesis: nil,
                grade: .d,
                sources: ["Searched 2026-09-19 and not found. The quiet-eye work is about a still shooter's gaze before a free throw, which is a different claim about a different moment."]),
        ],
        openQuestions: [
            "No drill in this module has ever been shot by anyone, so every mark in it is a design rather than a result.",
            "ArcLab cannot see whether you beat your partner. Count generously and the module will say you passed something it never watched.",
            "A handling drill that ends in a shot is still not a possession. Nobody has measured whether either one carries into a game.",
        ])

    // MARK: 10 — Handling under pressure

    public static let handlingUnderPressure = CurriculumModule(
        id: .handlingUnderPressure,
        title: "Handling under pressure",
        order: 9,
        prerequisites: [.ballHandling, .offTheDribble],
        summary: """
            The gap between an empty gym and a game is the thing this module is about, and there is \
            more evidence for it than for anything in the module before. A measured gap exists: one \
            college team shot better at the line in practice than in games across two seasons. What a \
            defender changes at skilled level is not how the ball leaves your hand but how much the \
            shots scatter. What tiredness changes is the shot itself, for some players and not for \
            others. So each drill below puts one of those conditions on your ordinary shot and the app \
            measures the same numbers it always does — while saying plainly that it cannot see your \
            partner, the clock or the score.
            """,
        whatCoachWatches: [
            "Whether the shot changes when somebody closes out, or only the result does.",
            "Whether the last set of a tired session looks like the first one.",
            "Whether you are deciding what to do before the ball arrives.",
            "Whether a miss under pressure was short, or off to one side.",
        ],
        cue: "Shoot the same shot whoever is in front of you.",
        drills: [
            CurriculumDrill(
                drill: Drill(name: "Called on the catch", reps: 6, sets: 6, spots: [.elbow, .three],
                             constraint: "A shot counts only if the call came after the ball left your partner's hands. A call you heard early is not a decision.",
                             schedule: "Mix the three calls with no pattern, and change spot every set.",
                             setup: "The elbow and the three, with a passer who calls what to do as the ball leaves their hands. 6 shots a set, 6 sets.",
                             doThis: "Do whatever your partner calls at the catch, without deciding before the ball arrives.",
                             watches: "The shots you take: the speed you send the ball at, and how far past the front of the ring they pass.",
                             doneWhen: "Your called sets vary no more than about \(widerByPercent) % more than the sets where you knew what was coming.",
                             why: "Practising a decision and practising a shot are different tasks, and in the one randomised trial of practice order, the easy version won while they practised and lost on the test afterwards.",
                             detail: "Shamshiri et al. 2025 (84 novice females, randomised, 3 days): one-condition practice scored 1.79 during practice against 1.11–1.52, then 1.28 on the later test against 1.69–1.73 and 0.54 on transfer against 1.27–1.38. Grade B: novices, three days. The call the partner made is typed in by you if you enter it; the app never hears it."),
                purpose: "Couple the shot to a decision made at the catch, which is what a possession actually does.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "Constraints-led coaching consensus, with the practice-order evidence behind it one step removed: Shamshiri et al. 2025 is randomised but on 84 novices over three days, and its task was shooting rather than deciding (grade B for that study, C for this drill)."),
            CurriculumDrill(
                drill: Drill(name: "Tired sets", reps: 8, sets: 6, spots: [.three],
                             constraint: "A set counts only if you started it inside ten seconds of stopping. Rest first and it is an ordinary set.",
                             schedule: "One fresh set first, then a run and a set, over and over, to the end.",
                             setup: "One spot, a timer, and something to run — the length of the court is enough. 8 shots a set, 6 sets.",
                             doThis: "Run hard for ninety seconds, then shoot your set straight away with no rest.",
                             watches: "The angle your ball is falling at and how far past the front of the ring your shots pass, tired against fresh.",
                             doneWhen: "There is no pass mark. The app shows what the running did to your shot, and some players lose nothing at all.",
                             why: "Twelve minutes of game-like running cost 38 high-level players 14–19 % of their makes and 3–4 % of their falling angle, while elite juniors lost nothing, so it has to be measured on you.",
                             detail: "Bourdas et al. 2024: 38 high-level players, 12-min simulated game protocol, entry angle −3.1 to −3.9 %, release time +15–25 %, makes −14 to −19 %. Li et al. 2025 meta, k = 14, n = 388. Slawinski et al. 2018: no release change in elite U18s after repeated sprints. The 90 s bout is shorter than any of those protocols and is our own choice, stated as such."),
                purpose: "Find out whether tiredness moves your shot at all, instead of assuming it does.",
                filmFrom: .sideView,
                methodGrade: .b,
                source: "The effect is grade A (Bourdas et al. 2024; Li et al. 2025 meta of 14 studies, n = 388), with a grade-A exception (Slawinski et al. 2018, no change in elite U18s). The 90-second bout is our own shortening of a 12-minute protocol, which is why the drill is B rather than A."),
            CurriculumDrill(
                drill: Drill(name: "Hands up", reps: 6, sets: 6, spots: [.three],
                             constraint: "A shot counts only if your partner got a hand inside the line between the ball and the ring. A late closeout is an open shot.",
                             schedule: "One open set, one set with hands up, in that order every time — the comparison is the point.",
                             setup: "The three, with a partner closing out with a hand up. 6 shots a set, 6 sets — three open, three with hands up.",
                             doThis: "Shoot your normal shot with your partner's hand in front of the ball.",
                             watches: "How much your shots scatter, front to back and left to right, against your open sets. ArcLab cannot see your partner at all.",
                             doneWhen: "Your pressured sets scatter no more than about \(widerByPercent) % more than your open sets at the same spot.",
                             why: "In NBA tracking a tight contest left the technique alone and widened the scatter by about half, so the scatter is the thing worth watching.",
                             detail: "Daly-Grafstein & Bornn 2020: tight contests biased shots short and raised depth spread 56 % and left-right spread 38 %. Amaro et al. 2025 (18 national-level players, 90 shots each): no significant effect of a 1.2×-height defender at 1 m or 105 dBA noise on jump height, release height, angle or velocity, all p ≥ 0.092. That a partner's closeout resembles a game contest is grade D — nobody has measured it."),
                purpose: "Put the one condition on the shot that large-n tracking says changes the result.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "The measures are grade A (Daly-Grafstein & Bornn 2020 on >50 000 tracked shots; Amaro et al. 2025 for the null on technique). That a partner with a hand up stands in for a game defender is untested — grade D for that step, which is what holds this drill at C."),
            CurriculumDrill(
                drill: Drill(name: "Shuffled spots", reps: 5, sets: 8, spots: [.freeThrow, .elbow, .midRange, .three],
                             constraint: "A set counts only if the set before it was at a different spot. Two in a row at the same place is not this drill.",
                             schedule: "Shuffled: a different order every session, and never two sets in a row at the same spot. The app will pick the order for you.",
                             setup: "Four spots marked on the floor. 5 shots a set, 8 sets — two sets at each spot.",
                             doThis: "Shoot one set, then move to a different spot for the next one.",
                             watches: "The speed you send the ball at, spot by spot, against the sessions where you stayed in one place.",
                             doneWhen: "Your shuffled sets vary no more than about \(widerByPercent) % more than your one-spot sets. Shuffling usually looks worse on the day and holds up better later.",
                             why: "In the one randomised trial of practice order for shooting, staying in one place won while they were practising and came last on the test afterwards.",
                             detail: "Shamshiri et al. 2025, 84 novice females, randomised, 3 days: one-condition practice 1.79 during practice against 1.11–1.52, 1.28 on the later test against 1.69–1.73 (ηp² = 0.24), 0.54 on transfer against 1.27–1.38. Shoenfelt et al. 2002 (94 participants, 3 weeks, randomised): varied practice equalled constant practice on the delayed test. Grade B both: novices and short. The order comes from `NextBlock.randomSpotSequence`, which never repeats a spot back to back. Note the limit: ArcLab shuffles **sets**, not single shots, because a recording is saved at one spot and shots from different spots are never pooled into one number. A one-shot-per-spot version of this drill cannot be measured by this app at all."),
                purpose: "Make the app's own shuffled order the drill, since it is the one game-like condition ArcLab knows in advance.",
                filmFrom: .sideView,
                methodGrade: .b,
                source: "Shamshiri et al. 2025 (randomised, 84 novice females, 3 days) and Shoenfelt et al. 2002 (randomised, 94 participants, 3 weeks). Both are grade B: novices and short studies, so the size of the effect in a shooter who takes 300 shots a session is unknown."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Under pressure your shots are no more scattered than when you are left alone: no more than about \(widerByPercent) % wider.",
                check: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot,
                                 target: .narrowByFraction(notWiderRatio),
                                 description: "your pressured set's speed spread is no more than about \(widerByPercent) % wider than your calm set's, which is the smallest widening 30 shots a side can tell from luck",
                                 minimumN: 25,
                                 detail: "releaseSpeedSD, pressured block at or below 1.43 × the calm block's — `DoctorStats.detectableSDRatio(n: 30)`. Amaro et al. 2025: a defender and 105 dBA noise changed nothing measurable about the release in 18 national-level players (all p ≥ 0.092); Daly-Grafstein & Bornn 2020: contests raised depth spread 56 % and left-right spread 38 % without moving the mean."),
                grade: .a,
                source: "healthy-shot-model-2026-09-14.md §4: a versatile shot is one whose spread does not inflate when the condition changes. Amaro et al. 2025 for the technique null, Daly-Grafstein & Bornn 2020 for the scatter. The ratio is arithmetic."),
            DoneCheck(
                plainWords: "After running, your ball still falls at 40° or steeper.",
                check: PassCheck(measure: .entryAngleMeanDegrees, scope: .findingSpot,
                                 target: .insideBand(low: 40, high: 52),
                                 description: "your tired set's average falling angle is 40° or steeper, the same as your fresh set's",
                                 minimumN: 20,
                                 detail: "entryAngleMeanDegrees inside 40–52°, minimum 20 counted shots. The 40° floor is exact geometry; that falling angle is the channel game load moves is Bourdas et al. 2024 (−3.1 to −3.9 %). That it moves for you is measured, never assumed — Slawinski et al. 2018 found no change in elite U18s."),
                grade: .a,
                source: "Bourdas et al. 2024 for entry angle being what falls under game load; the 40° band is exact geometry. Slawinski et al. 2018 is the grade-A exception: measure it, never assume it."),
            DoneCheck(
                plainWords: "You make the same share of your shots in a game as you do in practice.",
                unavailableReason: "ArcLab never sees a game. The only comparison it can make is against shots you type in yourself afterwards, and it needs 20 on each side before two make rates can be told apart at all — below that it says so instead of drawing a conclusion.",
                detail: "`GameTransfer.floor` is `ShotDoctor.attributionFloor` (20 counted shots a side), reused rather than invented; the smallest gap your own counts can resolve is printed at your own n from `GameTransfer.detectableMakeRateDifference`, a 95 % Wald interval on a difference of two proportions. Kozar, Vaughn, Lord & Whitfield 1995 (J Sport Behavior 18(2):123–129) found practice free-throw percentage significantly above game percentage for one NCAA team over two seasons; the magnitude is UNVERIFIED (`docs/research/ball-handling-and-transfer-2026-09-19.md` §2.1). A practice make is inferred from the ball at the ring; a game make is typed from memory. They are never added together.",
                grade: .b,
                source: "Kozar, Vaughn, Lord & Whitfield 1995, Journal of Sport Behavior 18(2):123–129 — practice free-throw percentage significantly higher than game percentage for one NCAA team across two seasons. Grade B: one team, retrospective, and the effect size could not be retrieved."),
        ],
        faults: [
            CurriculumFault(
                name: "Practice shooter, game shooter",
                howItShowsInNumbers: "Your make rate in games sits below your make rate in practice by more than the two counts can explain. It needs 20 shots logged on each side before the app will say anything at all.",
                hypothesis: nil,
                grade: .b,
                sources: ["Kozar, Vaughn, Lord & Whitfield 1995: practice free-throw percentage significantly higher than game percentage for one NCAA team over two seasons. One team, retrospective, magnitude unverified.",
                          "The comparison is a difference of two proportions, so the app prints the smallest gap your own counts can tell rather than a verdict."]),
            CurriculumFault(
                name: "Falling apart when you are tired",
                howItShowsInNumbers: "Your ball falls at a shallower angle and takes longer to leave your hand in the sets after running than in the fresh ones, with the makes following.",
                hypothesis: .fatigueDrift,
                grade: .a,
                sources: ["Bourdas et al. 2024: 38 high-level players, 12-min simulated game protocol, makes −14 to −19 %, entry angle −3.1 to −3.9 %.",
                          "Li et al. 2025 meta-analysis, 14 studies, n = 388. Slawinski et al. 2018 is the exception that makes it worth measuring on you."]),
            CurriculumFault(
                name: "\"More reps in an empty gym will fix it\"",
                howItShowsInNumbers: "Nothing you can see on the day, which is the trap. The easy version of practice scored best while it was being practised and worst on the test afterwards in the one randomised trial there is.",
                hypothesis: nil,
                grade: .c,
                sources: ["Shamshiri et al. 2025 (84 novice females, randomised, 3 days) and Shoenfelt et al. 2002 (94 participants, 3 weeks). Both grade B, neither on a skilled shooter — applying them to you is an inference, which is why this line is C."]),
            CurriculumFault(
                name: "\"Some players are just clutch\"",
                howItShowsInNumbers: "Nothing ArcLab can test. It cannot see the score or the clock, the late-game mark in your game log is a label you type, and a handful of late shots cannot separate a clutch shooter from a good night.",
                hypothesis: nil,
                grade: .d,
                sources: ["Searched 2026-09-19 and not found: a study isolating late-game shooting from shot selection and defence at an individual level.",
                          "The counts needed to tell two make rates apart are in `docs/research/ball-handling-and-transfer-2026-09-19.md` §2.4: about 31 points at 20 shots a side, 20 points at 50, 14 points at 100."]),
        ],
        openQuestions: [
            "ArcLab cannot see a defender, a clock or a score. Every game-like block is your own word that the condition was really there.",
            "Your game log is typed from memory after the game; your practice makes are inferred from the ball at the ring. They are two different measurements, so the app shows them side by side and never adds them together.",
            "Nobody has shot these blocks yet, so it is unknown whether practising under these conditions moves anything in a game.",
        ])
}

// MARK: - Finding a drill's card again

/// Every drill the app ships, addressable by name.
///
/// A saved practice block records the drill's *name* (and, for a plan's blocks, only an instruction
/// sentence that begins with it). The block card needs the drill's plain lines back so it can show
/// **Do this** large instead of the paragraph the store pasted together. `PracticeStore` is owned
/// elsewhere, so this reads what it writes rather than changing it.
public enum DrillDirectory {

    /// Curriculum first, then the plan library. Names repeat across the two — the same drill is
    /// taught in a module and prescribed by a fix — and the curriculum copy is the fuller one.
    public static var all: [(name: String, card: DrillCard)] {
        var out: [(String, DrillCard)] = []
        for m in Curriculum.modules {
            for d in m.drills {
                if let c = d.card { out.append((d.drill.name, c)) }
            }
        }
        for id in HypothesisID.allCases {
            let d = FixLibrary.package(for: id).drill
            if let c = d.plainCard, !out.contains(where: { $0.0 == d.name }) { out.append((d.name, c)) }
        }
        return out
    }

    /// The card for a drill named exactly this. Nil for a name we do not ship.
    public static func card(named name: String?) -> DrillCard? {
        guard let name, !name.isEmpty else { return nil }
        return all.first { $0.name == name }?.card
    }

    /// The card for a practice block, found by its recorded drill name first and then by the drill
    /// name its instruction was built from. Nil when the block is a warm-up or a retention set,
    /// which are not drills and have nothing to look up.
    public static func card(forBlockNamed name: String?, instruction: String) -> DrillCard? {
        if let c = card(named: name) { return c }
        // The store writes "<drill name>, set 1 of 2: …" and "<module> — <drill name>, step 1 …".
        // Longest name first, so "Distance ladder" never loses to a shorter name inside it.
        return all.sorted { $0.name.count > $1.name.count }
            .first { instruction.contains($0.name) }?.card
    }
}
