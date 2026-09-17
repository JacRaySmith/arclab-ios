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

    public init(drill: Drill, purpose: String, filmFrom: ClipRequirement,
                methodGrade: ShotEvidenceGrade, source: String) {
        self.drill = drill
        self.purpose = purpose
        self.filmFrom = filmFrom
        self.methodGrade = methodGrade
        self.source = source
    }
}

/// One measurable gate on a module. Exactly one of `check` and `unavailableReason` is non-nil.
public struct DoneCheck: Sendable {
    /// What passing it means, in the shooter's words.
    public var plainWords: String
    /// The gate in the app's own check type, so `FixLibrary.check` scores a module exactly the way it
    /// scores a plan. Nil when nothing ArcLab measures today can close this gate.
    public var check: PassCheck?
    /// Why there is no gate, when there is none. Never empty when `check` is nil.
    public var unavailableReason: String?
    /// The grade of the evidence that this measure is worth passing.
    public var grade: ShotEvidenceGrade
    public var source: String

    public init(plainWords: String, check: PassCheck? = nil, unavailableReason: String? = nil,
                grade: ShotEvidenceGrade, source: String) {
        self.plainWords = plainWords
        self.check = check
        self.unavailableReason = unavailableReason
        self.grade = grade
        self.source = source
    }

    /// True when the app can actually score this gate from a saved session today.
    public var isMeasurableToday: Bool { check != nil }
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
                                                     releaseAndFollowThrough, range, offTheDribble, gameSpeed]

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
                             constraint: "Chalk or tape the two marks your feet start on. A shot counts only if both feet land back inside the marks and you hold the finish until the ball reaches the rim.",
                             schedule: "Blocked for the first two sessions, then mixed with another spot — blocked practice wins during acquisition and loses on retention and transfer (Shamshiri 2025, ηp² = 0.24)."),
                purpose: "Make the shot repeat from the same place, so every later measurement is of the shot and not of where you were standing.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "Knudson 1993 JOPERD six teaching points (balanced stance, minimise horizontal COM travel) — coaching consensus with a rationale, no controlled measurement. The schedule is Shamshiri et al. 2025 (grade B, 84 novices, 3 days)."),
            CurriculumDrill(
                drill: Drill(name: "Hold the look", reps: 10, sets: 3, spots: [],
                             constraint: "Eyes stay on the back of the ring through the follow-through. A shot where you track the ball out of your hand does not count, whatever it does at the rim.",
                             schedule: "Blocked."),
                purpose: "Stop the head from leading the shot, which is the part of 'balance' a camera can actually see.",
                filmFrom: .closeForm,
                methodGrade: .b,
                source: "Ripoll et al. 1986 Human Movement Science: head/eye stabilisation on target discriminates experts from beginners and successful from failed shots — small n, no retrievable effect size. The quiet-eye meta-analysis (Lebeau et al. 2016) reports large effects on weak designs, and gaze is not measurable from a tripod; only head displacement is."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Your front-to-back spread at the spot you practise narrows, and the narrowing is bigger than what this many shots could produce by chance.",
                check: PassCheck(measure: .depthSDCm, scope: .findingSpot, target: .narrowByDetectableRatio,
                                 description: "next session's crossing-depth SD at or below this session's ÷ the detectable ratio",
                                 minimumN: 25),
                grade: .a,
                source: "Depth SD is the observable consequence of release-speed SD, which is the strongest published correlate of shooting percentage (Slegers, Lee & Wong 2021 JSSM, r = −0.96 with 3P%). The detectable-ratio floor is arithmetic (`DoctorStats.detectableSDRatio`)."),
            DoneCheck(
                plainWords: "Your head stops moving between the dip and the release.",
                unavailableReason: "Head movement is measured in pixels from a fixed tripod, has no published reference range in any unit, and is not comparable between camera positions. It is reported as your own trend across sessions and never scored, so it cannot close this module.",
                grade: .b,
                source: "healthy-shot-model-2026-09-14.md §2.4 and §7 ('metrics that need better tracking before they are shown at all')."),
            DoneCheck(
                plainWords: "Your shot does not drift from the first set of the session to the last.",
                unavailableReason: "The end-to-end change across a session is produced by the shot doctor's over-session trend read-out, not by the pass-check reader, so it is shown as a trend and cannot be used as a module gate yet.",
                grade: .a,
                source: "Textbook Ch 15 §15.3.4 (report the total change across the session, not a slope and not a p-value). That drift can happen is established (Bourdas et al. 2024); that it happens to you is measured, never assumed (Slawinski et al. 2018 found none in elite U18s)."),
        ],
        faults: [
            CurriculumFault(
                name: "Drifting or fading out of the shot",
                howItShowsInNumbers: "A left–right mean that sits off centre, and a left–right SD wider than the same shooter's static sets. Only a behind-the-shooter clip can see it; from the side it is invisible.",
                hypothesis: .lateralAimBias,
                grade: .c,
                sources: ["Knudson 1993 JOPERD: minimise horizontal COM travel — consensus with a rationale, no controlled measurement.",
                          "That the *variance* rather than the mean is what predicts is grade A: Daly-Grafstein & Bornn 2020 JSA."]),
            CurriculumFault(
                name: "Head moving through the shot",
                howItShowsInNumbers: "Head displacement between dip and release, in pixels, on a close waist-up clip. It has no published range, so only your own trend across sessions can be read — a number here is never a pass or a fail.",
                hypothesis: .headInstability,
                grade: .b,
                sources: ["Ripoll et al. 1986 Human Movement Science (small n, no effect size).",
                          "Lebeau et al. 2016 quiet-eye meta-analysis: large effects on weak designs, and gaze is not measurable from a tripod."]),
            CurriculumFault(
                name: "Stance too wide (or too narrow)",
                howItShowsInNumbers: "Nothing. Stance width would come from the body model in metres, and body metres are in ArcLab's untrusted class until the metre scale is validated against the rim calibration.",
                hypothesis: nil,
                grade: .b,
                sources: ["Cabarkapa, Cabarkapa & Fry 2026: proficient three-point shooters had a *narrower* stance than non-proficient (27.4 vs 34.3 cm), which is the opposite direction to the usual 'shoulder width or wider' coaching. Between-group, recreational sample, n = 24."]),
            CurriculumFault(
                name: "\"You must be perfectly square to the rim\"",
                howItShowsInNumbers: "Nothing measurable. There is no published squareness range at all, and ArcLab's 3-D shoulder-line yaw is refused from a near-side view and noisy from the others. Only your own shot-to-shot repeatability of it could ever be reported.",
                hypothesis: .shoulderSquareness,
                grade: .d,
                sources: ["healthy-shot-model-2026-09-14.md §2.5 and row 18: no published range exists; 'square to the rim' is coaching lore stated as a fact.",
                          "Cabarkapa et al. 2022: excellent and good professionals showed no kinematic differences at all — the grade-A null against importing any posture target."]),
        ],
        openQuestions: [
            "Head stability needs a fixed tripod and a pixel-to-scale note before it can be compared across sessions; until then the module's own best gate is the depth-SD consequence, not the cause.",
            "Foot contacts, stance width and landing position are being built in Track C (`docs/DESIGN-FOOTWORK-2026-09-15.md`). When they land, this module gets a gate on its own subject instead of on its consequence.",
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
                             constraint: "Self-toss or a passer, and two chalk marks. Every shot starts and ends on the marks, and the ball leaves before the feet move again.",
                             schedule: "Blocked by spot for the first two sessions, then the two spots shuffled."),
                purpose: "Make the arrival repeat, so the footwork stops being a source of spread.",
                filmFrom: .behindShooter,
                methodGrade: .c,
                source: "Coaching consensus. The one measured test of stance — 11 NCAA Division I women, dominant-staggered vs parallel vs cross-dominant — found no significant effect of foot placement on accuracy, though players favoured the dominant staggered stance (The Sport Journal, foot-placement study, grade B for the null)."),
            CurriculumDrill(
                drill: Drill(name: "One-two ladder", reps: 8, sets: 6, spots: [.elbow, .midRange],
                             constraint: "Step into every shot with the same foot first. A repetition where the other foot lands first does not count, whatever the shot does — the graded thing is that it repeated, not which foot it was.",
                             schedule: "Blocked at the near spot until the order repeats, then alternating spots."),
                purpose: "Fix the step order as *yours* rather than as a prescribed one, because no published evidence picks an order.",
                filmFrom: .behindShooter,
                methodGrade: .d,
                source: "Which foot should land first is coaching folklore on both sides: the 1-2 and the hop are both taught as correct by well-known coaches, and no peer-reviewed comparison of the two was found (searched 2026-09-15). Only the repeatability is defensible, and that is an in-house argument, not a measured one."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Filmed from behind, your mean left–right offset at the rim sits inside ±3 cm.",
                check: PassCheck(measure: .lateralMeanCm, scope: .findingSpot, target: .insideBand(low: -3, high: 3),
                                 description: "next session's mean left–right offset inside ±3 cm, filmed from behind",
                                 minimumN: 20),
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019/2020: the mean offset is near zero in professionals, and contests raise lateral *variance* 38 % without moving the mean. The ±11 cm tolerance either side of the ball is exact ring geometry. Reused verbatim from `FixLibrary`'s lateral-aim package."),
            DoneCheck(
                plainWords: "Your left–right spread narrows by more than this many shots could produce by chance.",
                check: PassCheck(measure: .lateralSDCm, scope: .findingSpot, target: .narrowByDetectableRatio,
                                 description: "next session's left–right SD at or below this session's ÷ the detectable ratio",
                                 minimumN: 25),
                grade: .a,
                source: "Slegers & Love 2022: spin-axis SD correlated r = 0.80 with lateral accuracy while mean misalignment did not — consistency is the signal. Detectable-ratio floor is arithmetic."),
            DoneCheck(
                plainWords: "Your step order, gather time and landing position repeat.",
                unavailableReason: "ArcLab does not measure foot contacts yet. Step order, stance width, gather time (last contact → release) and lateral drift are being built in Track C (`docs/DESIGN-FOOTWORK-2026-09-15.md`), and stance width in metres from the body model stays in the untrusted class until the metre scale is validated. Nothing here is scored until those exist.",
                grade: .c,
                source: "healthy-shot-model-2026-09-14.md §7 (body metres are the unreliable class); `docs/PLAN-1.1-2026-09-15.md` Track C."),
        ],
        faults: [
            CurriculumFault(
                name: "Fading or drifting sideways into the shot",
                howItShowsInNumbers: "A left–right mean off centre that repeats in the same direction, from a behind-the-shooter clip. A side view cannot see it and says so.",
                hypothesis: .lateralAimBias,
                grade: .b,
                sources: ["Daly-Grafstein & Bornn 2020 JSA: NBA contests raised left–right variance 38 % without biasing direction — disturbance shows in spread first.",
                          "That drifting specifically causes the offset is a coaching inference, grade C."]),
            CurriculumFault(
                name: "Different feet every repetition",
                howItShowsInNumbers: "Left–right SD wider on catch-and-shoot blocks than on the same shooter's stand-still blocks at the same spot, recorded as two blocks and compared.",
                hypothesis: .lateralVariability,
                grade: .c,
                sources: ["No published study compares repeatable against variable step order. The claim that spread follows from it is coaching consensus; what ArcLab can do is measure your two blocks."]),
            CurriculumFault(
                name: "Drifting forward into the rim",
                howItShowsInNumbers: "Mean crossing depth past the 25–28 cm band, or a release distance that shortens between blocks at the same nominal spot.",
                hypothesis: .depthBiasLong,
                grade: .c,
                sources: ["The depth band itself is grade A (Daly-Grafstein & Bornn 2019). That travelling forward is what moved it is a coaching inference on your own data."]),
            CurriculumFault(
                name: "\"The hop is quicker\" / \"the 1-2 is more balanced\"",
                howItShowsInNumbers: "Nothing, today. Coaches teach both as the correct answer; no peer-reviewed kinematic comparison was found, and the one measured stance study found no accuracy difference between placements.",
                hypothesis: nil,
                grade: .d,
                sources: ["Dr Dish Basketball coaching blog, '1-2 vs. The Hop' — a summary of the coaching argument, not evidence (https://blog.drdishbasketball.com/basketball-shooting-footwork-1-2-vs.-the-hop).",
                          "The Sport Journal, 'The Effect of Foot Placement on the Jump Shot Accuracy of NCAA Division I Basketball Players': 11 D-I women, no significant effect of foot placement on accuracy (grade B for the null, practitioner journal, small n)."]),
        ],
        openQuestions: [
            "Left–right is the only channel that sees footwork today, and it needs a behind-the-shooter clip. On a side view this module cannot be scored at all.",
            "No off-the-dribble footage exists yet, so the footwork metrics Track C is building will first be tested on catch and free-throw timelines.",
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
                             constraint: "Shoot to a metronome set to your own near-spot dip→release time. The shot leaves on the second click, from every distance.",
                             schedule: "Blocked, near spot first, then the far spot at the same tempo."),
                purpose: "Hold one tempo across distances instead of hurrying the far ones.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "Reused from `FixLibrary`'s rushed-preparation package. Cabarkapa et al. 2023 found proficient shooters moved slower and lower in preparation (knee peak 212.9 vs 269.4 °/s, ES 1.04) with no release-phase differences; Botsi et al. 2024 found higher-level U18s released 12.5 % *faster*. The two pull opposite ways, so only your own consistency is read — the metronome method itself is untested."),
            CurriculumDrill(
                drill: Drill(name: "Dip / no-dip A-B", reps: 10, sets: 6, spots: [.freeThrow, .midRange],
                             constraint: "Alternate sets: one with your normal dip, one with the ball starting at the set point and going straight up. Record each set as its own block so the comparison is set against set.",
                             schedule: "Alternating sets — this is a within-you trial, which is the design the dip evidence came from."),
                purpose: "Settle whether the dip does anything for *you*, rather than importing someone else's answer.",
                filmFrom: .sideView,
                methodGrade: .a,
                source: "Penner 2021 Front Psychol: 36 elite males, within-subject with and without a dip at four distances (3.125–6.75 m), 7–9 % accuracy gain, F(1,17) = 27.6 and 53.1, p < 0.001. Grade A for the design class, with the caveat that it is unblinded, single-session and acute, with no retention test — which is exactly why this is run as your own A-B."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Your dip→release tempo stops changing when you step back: the far spot moves at least 0.05 s back towards the near one.",
                check: PassCheck(measure: .dipToReleaseChangeAcrossDistance, scope: .acrossDistance,
                                 target: .moveBy(0.05),
                                 description: "the far-spot dip→release moves at least 0.05 s back toward the near-spot value",
                                 minimumN: 20),
                grade: .b,
                source: "Reused verbatim from `FixLibrary`'s rushed-preparation package. There is no published reference range for dip-to-release at all, so the target is your own near-spot tempo, and 0.05 s is the smallest move the measure resolves at these shot counts — not a published number."),
            DoneCheck(
                plainWords: "Your release-speed spread at the practised spot narrows.",
                check: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot, target: .narrowByDetectableRatio,
                                 description: "next session's release-speed SD at or below this session's ÷ the detectable ratio",
                                 minimumN: 25),
                grade: .a,
                source: "Slegers, Lee & Wong 2021 JSSM: release-velocity SD correlated r = −0.96 with 3-point and r = −0.88 with free-throw performance in 12 skilled shooters; skilled range 0.05–0.13 m/s."),
            DoneCheck(
                plainWords: "The legs lead the arm on most shots.",
                unavailableReason: "The proximal-to-distal order needs a close waist-up clip and is not carried on the diagnosis the checks read, so it cannot be scored as a gate. Where it is shown at all it is shown as a pattern — never as a lag in milliseconds, because no lag has ever been published.",
                grade: .b,
                source: "Jiang et al. 2025 J Hum Kinet: collegiate players were proximal-dominant at 3.2 m, recreational players distal-dominant; 20 players, 3 successful shots per distance."),
        ],
        faults: [
            CurriculumFault(
                name: "Rushing the gather at range",
                howItShowsInNumbers: "Dip→release time falls as the distance rises, and release-speed SD widens with it.",
                hypothesis: .rushedPreparation,
                grade: .b,
                sources: ["Cabarkapa et al. 2023 Front Sports Act Living: proficient shooters moved slower and lower in preparation, no release-phase differences (markerless 120 Hz, 34 males, between groups).",
                          "Botsi et al. 2024 JFMK: higher-level U18s released 12.5 % faster (t(77) = −3.213, p = 0.002) — the opposite direction, which is why only your own consistency is scored."]),
            CurriculumFault(
                name: "No dip at all",
                howItShowsInNumbers: "Nothing in a single block. It shows only in your own alternating sets: dip blocks against no-dip blocks at the same spot, compared on make rate and depth.",
                hypothesis: nil,
                grade: .a,
                sources: ["Penner 2021: +7–9 % accuracy with the dip, within-subject, 36 elite males — grade A for an acute effect.",
                          "\"Always dip\" as a permanent prescription is grade D: the study was single-session, unblinded and had no retention test."]),
            CurriculumFault(
                name: "Shooting with the arm only",
                howItShowsInNumbers: "Knee-extension peak rate that does not rise as the distance rises. It needs a close form clip, and the number is reported rather than scored because no reference range exists for an individual.",
                hypothesis: .armDominantDrive,
                grade: .b,
                sources: ["Cabarkapa et al. 2023: knee peak angular velocity separates proficient from non-proficient (recreational, between groups).",
                          "Okazaki & Rodacki 2012: experts showed no significant ankle/knee/hip change with distance and compensated with release speed — so 'use your legs more' is not a settled instruction."]),
            CurriculumFault(
                name: "\"One-motion is faster, two-motion is more powerful\"",
                howItShowsInNumbers: "Nothing. No comparative biomechanical study of one-motion against two-motion shooting was found, so ArcLab measures your tempo's consistency and takes no position on its shape.",
                hypothesis: nil,
                grade: .d,
                sources: ["healthy-shot-model-2026-09-14.md §2.6 (searched 2026-09-14, nothing found); set-point height is in the same class and is deliberately not shown at all."]),
        ],
        openQuestions: [
            "Dip-to-release has no published reference range in any population, so only the within-shooter consistency and the across-distance change can ever be gates here.",
            "The sequencing order needs the close form clip and a trusted 3-D body model (Track A). Until then the module closes on tempo and speed SD alone.",
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
                             constraint: "One strip of tape around the ball's seam, camera directly behind you. Watch the stripe, not the result.",
                             schedule: "Blocked, near spot first: the spin axis is easier to control before the distance forces effort."),
                purpose: "Turn an invisible fault into a visible one — the stripe shows the axis the hand actually left on.",
                filmFrom: .behindShooter,
                methodGrade: .b,
                source: "Reused from `FixLibrary`'s spin-axis package. Slegers & Love 2022: SD of spin-axis alignment predicted lateral accuracy (r = 0.80) while mean misalignment did not. The taped-stripe capture mode is not shipped yet."),
            CurriculumDrill(
                drill: Drill(name: "One-hand form set", reps: 10, sets: 4, spots: [.freeThrow],
                             constraint: "Guide hand off the ball entirely, close to the rim, filmed from behind. A shot counts only if the stripe comes back flat.",
                             schedule: "Blocked, close range."),
                purpose: "Remove the off hand so whatever it was doing to the ball stops, and the shooting hand's own line can be seen.",
                filmFrom: .behindShooter,
                methodGrade: .d,
                source: "One-hand form shooting is near-universal coaching practice with no controlled measurement behind it that could be found. It is listed because coaches run it and shooters expect it, not because it is established. What is scored is the left–right spread, not the drill."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Your left–right spread at the rim narrows by more than chance can explain.",
                check: PassCheck(measure: .lateralSDCm, scope: .findingSpot, target: .narrowByDetectableRatio,
                                 description: "next session's left–right SD at or below this session's ÷ the detectable ratio",
                                 minimumN: 25),
                grade: .a,
                source: "Slegers & Love 2022 (spin-axis SD r = 0.80 with lateral accuracy; mean misalignment did not predict); Daly-Grafstein & Bornn 2020 (it is the variance that moves when the shot is disturbed, not the mean)."),
            DoneCheck(
                plainWords: "Your mean left–right offset sits inside ±3 cm rather than favouring one side.",
                check: PassCheck(measure: .lateralMeanCm, scope: .findingSpot, target: .insideBand(low: -3, high: 3),
                                 description: "next session's mean left–right offset inside ±3 cm",
                                 minimumN: 20),
                grade: .a,
                source: "Reused verbatim from `FixLibrary`'s lateral-aim package: mean offset near zero in professionals, ±11 cm of ring tolerance either side of the ball (exact geometry)."),
            DoneCheck(
                plainWords: "Your spin axis sits inside ±10° of pure backspin.",
                unavailableReason: "The taped-stripe capture mode is not shipped, and spin-axis tilt is not carried on the diagnosis the checks read. Until it is, this gate cannot be scored — the left–right spread above is its measurable consequence, not a substitute for it.",
                grade: .b,
                source: "Slegers & Love 2022 for the axis-consistency link; the ±10° band and the 2–3° per-frame resolution are the app's own feasibility numbers (`DESIGN-MEMO-2026-09-13.md` §3.7), not a published range."),
        ],
        faults: [
            CurriculumFault(
                name: "Thumb flick from the off hand",
                howItShowsInNumbers: "A tilted spin axis (not measurable yet) and, when it is systematic, a left–right mean that sits on one side. The spread is what is actually scored.",
                hypothesis: .lateralAimBias,
                grade: .d,
                sources: ["The claim that the off thumb causes the miss is coaching folklore: the retrievable sources are training-aid patent filings (US 10,427,020; US 5,188,356) and coaching sites, not measurement.",
                          "What is grade A is only that lateral *consistency* predicts and the mean does not (Slegers & Love 2022; Daly-Grafstein & Bornn 2020)."]),
            CurriculumFault(
                name: "Guide hand still on the ball at release",
                howItShowsInNumbers: "Nothing directly. It would need a close waist-up clip and a hand-contact measurement ArcLab does not have; only the left–right spread can carry it.",
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
            "This module cannot be scored at all from a side view: everything it touches lives in the left–right channel, which needs the camera behind the shooter.",
            "The taped-stripe spin mode is the single unlock that would turn this module's real subject into a measurement.",
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
                             constraint: "Same spot all session. A shot counts only if it crosses inside your own make band; makes that come in short or long are called out as misses.",
                             schedule: "Blocked. This is an acquisition drill for a new feel."),
                purpose: "Score depth rather than the result, so the channel that carries the percentage is the one being practised.",
                filmFrom: .sideView,
                methodGrade: .a,
                source: "Reused from `FixLibrary`'s speed-variability package. Slegers, Lee & Wong 2021: release-velocity SD r = −0.96 with 3P%. The band itself is your own, computed from your own makes when there are enough of them."),
            CurriculumDrill(
                drill: Drill(name: "Over-the-top", reps: 10, sets: 6, spots: [],
                             constraint: "A helper holds a pole (or you imagine a bar) a metre in front of the rim at rim height plus half a metre. Any shot that would clip it does not count.",
                             schedule: "Blocked."),
                purpose: "Buy arc margin when the entry angle is under 40°, where the ball has less than 3 cm of room.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "Reused from `FixLibrary`'s flat-arc package. The 40° margin and the ≈32° floor are exact geometry (grade A); that a physical constraint is the way to change the arc is coaching consensus (grade C)."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Your release-speed spread narrows by more than chance can explain, and stays narrow next session.",
                check: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot, target: .narrowByDetectableRatio,
                                 description: "next session's release-speed SD at or below this session's ÷ the detectable ratio",
                                 minimumN: 25),
                grade: .a,
                source: "Slegers, Lee & Wong 2021 JSSM (n = 12 skilled shooters, matched measurement class): velocity SD r = −0.96 with 3-point performance; skilled range 0.05–0.13 m/s at both free-throw and three-point distance."),
            DoneCheck(
                plainWords: "Your mean entry angle clears 40° without chasing past the mid-40s.",
                check: PassCheck(measure: .entryAngleMeanDegrees, scope: .findingSpot,
                                 target: .insideBand(low: 40, high: 52),
                                 description: "next session's mean entry angle at or above 40° and not chasing past the mid-40s",
                                 minimumN: 20),
                grade: .a,
                source: "Exact geometry for the floor (asin(d_ball/d_rim) ≈ 31.4–32.1°, under 3 cm of margin by 40°); Daly-Grafstein & Bornn 2020 for make probability being flat over a range of entry angles. Reused verbatim from `FixLibrary`'s flat-arc package."),
            DoneCheck(
                plainWords: "Your mean crossing depth sits between 25 and 28 cm past the front rim.",
                check: PassCheck(measure: .depthMeanCm, scope: .findingSpot,
                                 target: .insideBand(low: depthBandCm.low, high: depthBandCm.high),
                                 description: "next session's mean crossing between 25 and 28 cm past the front rim",
                                 minimumN: 20),
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019 JQAS: over >50 000 NBA three-point trajectories, make probability peaked 25–28 cm (10–11 in) past the front rim, against a ring centre at 22.9 cm. Measured on NBA threes, not on this shooter."),
        ],
        faults: [
            CurriculumFault(
                name: "Flat arc",
                howItShowsInNumbers: "Mean entry angle under 40°, where the ball has under 3 cm of margin through the ring; below about 32° it cannot fit at all.",
                hypothesis: .flatArcGeometry,
                grade: .a,
                sources: ["Exact geometry: the entry-angle floor is asin(ball diameter / rim diameter), 31.4° for a 0.2385 m ball and 32.1° at the top of the rulebook tolerance.",
                          "Daly-Grafstein & Bornn 2020: entry angle is the least peaked of the three rim-plane variables — there is nothing to gain past the mid-40s."]),
            CurriculumFault(
                name: "Release speed varying shot to shot",
                howItShowsInNumbers: "Release-speed SD, and the share of your depth spread the delta method attributes to the speed channel. At ~7.2 m/s over ~5.3 m, 0.1 m/s is about 15 cm of depth at the rim.",
                hypothesis: .speedVariability,
                grade: .a,
                sources: ["Slegers, Lee & Wong 2021 (the correlation); the speed-to-depth conversion is the exact range derivative, so it is geometry."]),
            CurriculumFault(
                name: "Short misses",
                howItShowsInNumbers: "Misses whose release speed sits below the makes', and a mean crossing depth short of the 25–28 cm band.",
                hypothesis: .depthBiasShort,
                grade: .a,
                sources: ["Mullineaux & Uhl 2010: misses released −0.12 ± 0.10 m/s below optimal vs −0.02 ± 0.07 for swishes (grade B, 3 makes vs 3 misses per subject).",
                          "Daly-Grafstein & Bornn 2019/2020 for the band and for contests biasing shots short."]),
            CurriculumFault(
                name: "Elbow flaring away from vertical",
                howItShowsInNumbers: "Forearm-from-vertical in the frontal plane, which needs a behind-the-shooter clip. ArcLab's elbow numbers today are sagittal, from a side view, and cannot see flare at all.",
                hypothesis: .forearmFlare,
                grade: .b,
                sources: ["Cabarkapa & Fry 2021 CEJSSM: proficient 7.9 ± 7.2° vs non-proficient 19.8 ± 17.6° from vertical — between groups, 17 recreationally active males, one session.",
                          "\"Keep the elbow under the ball\" as a universal instruction is grade D: Cabarkapa et al. 2022 found no kinematic differences at all between excellent and good professionals."]),
            CurriculumFault(
                name: "\"Shoot 45° arc\"",
                howItShowsInNumbers: "It is not a fault and not a target. Mid-40s is where NBA makes cluster; the same NBA player shoots about 38° mid-range, 45° from three and 53° from the line.",
                hypothesis: nil,
                grade: .d,
                sources: ["Slegers 2022 IJPAS: each shooter's optimal release angle sits 4.3 ± 2.1° above their own minimum-velocity angle and correlates r = 0.78 with their own release covariance — the right angle is individual by construction.",
                          "The 45° universal traces to vendor marketing with no published method (Noah, 'Building the Perfect Arc'), and to per-shot-type averages misread as targets (Nylon Calculus 2018)."]),
            CurriculumFault(
                name: "\"Hold the follow-through for two seconds\"",
                howItShowsInNumbers: "Nothing. It is a way of keeping the hand still long enough not to disturb the release; no controlled measurement of the hold duration was found.",
                hypothesis: nil,
                grade: .d,
                sources: ["Coaching consensus with no measurement. The measurable consequence a coach is after is a narrower left–right spread, which is the guide-hand module's gate."]),
        ],
        openQuestions: [
            "Release height has no agreed direction of effect across studies, so it is reported as context for the release angle and never as a lever.",
            "Elbow flare needs a behind-the-shooter clip and a frontal forearm angle ArcLab does not carry on the session summary yet.",
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
            anywhere — it is that the release-speed spread does not inflate when the distance goes up. \
            Skilled shooters' velocity SD was the same at the free-throw line and from three.
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
                             constraint: "Five shots at each of four distances, four rounds. Step back only after two shots in a row cross inside your own make band; step forward again the moment three in a row miss it.",
                             schedule: "Blocked by distance for the first two sessions, then shuffled — blocked practice wins during acquisition and loses on retention and transfer (Shamshiri 2025, ηp² = 0.24)."),
                purpose: "Let the far spot be earned by the near one, and measure the two on the same day so the ratio means something.",
                filmFrom: .sideView,
                methodGrade: .b,
                source: "Reused from `FixLibrary`'s range package. Variable-distance practice equalled constant practice on delayed retention despite worse practice performance (Shoenfelt et al. 2002, 94 participants, randomised, 3 weeks) — it is not better, it is not worse, and it is the only way to measure the ratio."),
            CurriculumDrill(
                drill: Drill(name: "Step-in range extension", reps: 6, sets: 8, spots: [.midRange, .three],
                             constraint: "One step into the shot from behind the line so the legs supply the extra distance. Then repeat the same shot standing still and compare.",
                             schedule: "Alternating pairs: one stepping set, one standing set."),
                purpose: "Find out whether the far-spot problem is power or mechanics, by supplying the power a different way.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "Reused from `FixLibrary`'s arm-dominant package. Okazaki & Rodacki 2012 found experts compensated for distance with release speed rather than with joint-angle change, so 'use the legs' is a hypothesis to test on your own sets, not a prescription."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Your far-spot release-speed spread is no more than about 1.4× your near-spot spread — it is not distinguishably wider.",
                check: PassCheck(measure: .releaseSpeedSDRatioAcrossDistance, scope: .acrossDistance,
                                 target: .insideBand(low: 0, high: notWiderRatio),
                                 description: "far ÷ near release-speed SD at or below 1.43, which is the smallest widening 30 shots a side can be told from chance",
                                 minimumN: 25),
                grade: .a,
                source: "Slegers, Lee & Wong 2021: skilled velocity SD was the same at free-throw and three-point range (0.086 vs 0.089 m/s). The 1.43 is `DoctorStats.detectableSDRatio(n: 30) = exp(1.96/√30)` — arithmetic from the shipped code, not a published threshold."),
            DoneCheck(
                plainWords: "Your far-spot release-speed spread narrows in its own right.",
                check: PassCheck(measure: .releaseSpeedSD, scope: .farSpot, target: .narrowByDetectableRatio,
                                 description: "next session's release-speed SD at the far spot at or below this session's ÷ the detectable ratio",
                                 minimumN: 25),
                grade: .a,
                source: "Reused verbatim from `FixLibrary`'s range package. Slegers 2021 for why the speed channel leads."),
            DoneCheck(
                plainWords: "Your arc at the far spot still clears 40°, rather than flattening to buy the distance.",
                check: PassCheck(measure: .entryAngleMeanDegrees, scope: .farSpot,
                                 target: .insideBand(low: 40, high: 52),
                                 description: "far-spot mean entry angle at or above 40°",
                                 minimumN: 20),
                grade: .a,
                source: "Exact geometry for the floor and the 3 cm margin at 40°; Okazaki & Rodacki 2012 for release angle falling with distance in the first place (grade B), which is why the far spot is where this is checked."),
        ],
        faults: [
            CurriculumFault(
                name: "Running out of power at range",
                howItShowsInNumbers: "Release-speed SD that is distinguishably wider at the far spot than the near one, and misses that fall short.",
                hypothesis: .rangeStrengthLimit,
                grade: .a,
                sources: ["Slegers, Lee & Wong 2021: skilled shooters' velocity SD was the *same* at both distances, so a widening ratio is a departure from the skilled pattern.",
                          "Okazaki & Rodacki 2012: accuracy falls 59 % → 37 % from 2.8 m to 6.4 m even in experts, so some fall-off is normal and only the spread ratio is scored."]),
            CurriculumFault(
                name: "Arc collapsing at the far spot",
                howItShowsInNumbers: "Far-spot mean entry angle under 40° while the near spot clears it.",
                hypothesis: .flatArcGeometry,
                grade: .a,
                sources: ["Exact geometry for the margin; Okazaki & Rodacki 2012 for release angle falling with distance (grade B)."]),
            CurriculumFault(
                name: "Rushing the far shots",
                howItShowsInNumbers: "Dip→release time at the far spot shorter than at the near spot by more than your own near-spot SD.",
                hypothesis: .rushedPreparation,
                grade: .b,
                sources: ["Cabarkapa et al. 2023 and Botsi et al. 2024, which disagree on direction — so it is your own change across distance that is read, not a published tempo."]),
            CurriculumFault(
                name: "Shooting with the arm at range",
                howItShowsInNumbers: "Knee-extension peak rate flat across distances while the release speed rises. Needs a close form clip, and the joint number is reported rather than scored.",
                hypothesis: .armDominantDrive,
                grade: .b,
                sources: ["Cabarkapa et al. 2023 (between-group knee angular velocity); Okazaki & Rodacki 2012 (experts changed speed, not joint angles)."]),
            CurriculumFault(
                name: "\"Shoot from further back to build range\"",
                howItShowsInNumbers: "Nothing measures the method; what the app can see is whether the far/near spread ratio moved.",
                hypothesis: nil,
                grade: .d,
                sources: ["No study tested shooting beyond one's range as a range-building method. The nearest tested thing is variable-distance practice, which merely *equalled* constant practice on delayed retention (Shoenfelt et al. 2002, grade B)."]),
        ],
        openQuestions: [
            "The far ÷ near ratio needs both spots measured in comparable conditions; two spots filmed on different days from different camera positions are not a ratio worth reading.",
            "Whether strength work moves the far-spot spread is untested here and unmeasured by ArcLab.",
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
                             constraint: "Alternate: one set catch-and-shoot from the mark, one set one-dribble pull-up to the same mark. Same spot, same camera, each set recorded as its own block so the comparison is block against block.",
                             schedule: "Alternating pairs. The order is fixed rather than randomised because the comparison, not the practice schedule, is the point."),
                purpose: "Measure the cost of the dribble instead of guessing it.",
                filmFrom: .sideView,
                methodGrade: .c,
                source: "The A-B design is sound (it is the design `DESIGN-MEMO-2026-09-13.md` §C1 asks for); the claim that a pull-up should match a catch is coaching consensus. No peer-reviewed kinematic comparison of catch-and-shoot against off-the-dribble release parameters was found."),
            CurriculumDrill(
                drill: Drill(name: "Gather tempo match", reps: 8, sets: 6, spots: [.elbow],
                             constraint: "One-dribble pull-up to a chalk mark. A repetition counts only if the ball leaves inside your own catch-and-shoot dip→release band, whatever it does at the rim.",
                             schedule: "Blocked at one spot until the tempo repeats."),
                purpose: "Stop the dribble from compressing the tempo the rhythm module just settled.",
                filmFrom: .sideView,
                methodGrade: .d,
                source: "In-house: the tempo band is your own measured dip→release spread, and matching it off the dribble is an untested hypothesis rather than a published finding."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Recorded as two blocks at the same spot, your pull-up block's release-speed spread is no more than about 1.4× your catch block's.",
                check: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot,
                                 target: .narrowByFraction(notWiderRatio),
                                 description: "the pull-up block's release-speed SD at or below 1.43 × the catch block's — the smallest widening 30 shots a side can be told from chance",
                                 minimumN: 25),
                grade: .a,
                source: "The versatility definition in healthy-shot-model-2026-09-14.md §4: a versatile shot is one whose release-speed and depth spread do not inflate when the condition changes (Slegers 2021 across distance; Amaro et al. 2025 across defender and noise; Daly-Grafstein & Bornn 2020 for contests raising variance 56 %/38 % without moving the mean). The 1.43 is `DoctorStats.detectableSDRatio(n: 30)` — arithmetic."),
            DoneCheck(
                plainWords: "Your mean crossing depth off the dribble still sits between 25 and 28 cm past the front rim.",
                check: PassCheck(measure: .depthMeanCm, scope: .findingSpot,
                                 target: .insideBand(low: depthBandCm.low, high: depthBandCm.high),
                                 description: "the pull-up block's mean crossing between 25 and 28 cm past the front rim",
                                 minimumN: 20),
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019 JQAS for the band; that contested and disturbed shots bias short is 2020, same authors."),
            DoneCheck(
                plainWords: "Your step into the shot repeats: same foot first, gather inside your own band, no sideways drift.",
                unavailableReason: "ArcLab measures no foot contacts, no gather time and no lateral drift yet, and no off-the-dribble footage exists to build them on. Track C is building the metrics (`docs/DESIGN-FOOTWORK-2026-09-15.md`); the specific numbers a drill definition would use — a 0.35 s gather, a drift under 0.1 stature — are in-house proposals with no published support and will be reported, never scored.",
                grade: .d,
                source: "`docs/PLAN-1.1-2026-09-15.md` Track C. No published reference range exists for gather time or drift in any population."),
        ],
        faults: [
            CurriculumFault(
                name: "Everything widens off the dribble",
                howItShowsInNumbers: "Release-speed SD and depth SD wider on the pull-up blocks than on the catch blocks at the same spot on the same day.",
                hypothesis: .speedVariability,
                grade: .a,
                sources: ["The measure is grade A (Slegers, Lee & Wong 2021). That the dribble is what widened it is your own block comparison, not a published fact — no kinematic comparison of the two shot types was found."]),
            CurriculumFault(
                name: "Drifting sideways out of the dribble",
                howItShowsInNumbers: "A left–right mean off centre on the pull-up blocks that is not there on the catch blocks. Needs the camera behind the shooter.",
                hypothesis: .lateralAimBias,
                grade: .c,
                sources: ["Daly-Grafstein & Bornn 2020 for disturbance showing in lateral spread (grade A); the attribution to the dribble is a coaching inference."]),
            CurriculumFault(
                name: "Rushing the gather",
                howItShowsInNumbers: "Dip→release time on the pull-up blocks shorter than your own catch-block band.",
                hypothesis: .rushedPreparation,
                grade: .c,
                sources: ["No published gather-time reference exists in any population; only your own two blocks can be compared."]),
            CurriculumFault(
                name: "\"Catch-and-shoot is 20–40 % better than off the dribble\"",
                howItShowsInNumbers: "Nothing you can act on. It is a play-type aggregate from observational game data, which mixes shot selection, defence and clock with mechanics.",
                hypothesis: nil,
                grade: .d,
                sources: ["Breakthrough Basketball's analytics summary quotes ~20 % (NBA) to ~40 % (college women) — aggregator, no method, no control for shot selection. healthy-shot-model-2026-09-14.md §4 grades it D."]),
            CurriculumFault(
                name: "\"You stepped wrong\"",
                howItShowsInNumbers: "Nothing today, and the claim that one step order is correct has no published support. When Track C's foot contacts land, ArcLab will be able to say whether your step *repeated* — which is a different and answerable question.",
                hypothesis: nil,
                grade: .d,
                sources: ["No peer-reviewed comparison of step orders into a jump shot was found (searched 2026-09-15).",
                          "The Sport Journal foot-placement study found no significant effect of foot placement on accuracy (11 NCAA D-I women)."]),
        ],
        openQuestions: [
            "No off-the-dribble footage exists yet. Until some is filmed, every gate in this module is a design, not a result.",
            "A pull-up and a catch shot recorded on different days are not a comparison; the module needs both blocks on the same day, same spot, same camera.",
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
                             constraint: "Two counted sets at the start of the session and two at the end, same spot, with rest between blocks. The middle of the session is free shooting.",
                             schedule: "Blocked bookends around whatever else the session holds."),
                purpose: "Measure the drift rather than assume it — the first and last blocks are the whole experiment.",
                filmFrom: .sideView,
                methodGrade: .a,
                source: "Reused from `FixLibrary`'s within-session-drift package. Textbook Ch 15 §15.3.4: report the total change across the session, not a slope and not a p-value. A set-of-10 mean depth has a standard error of 4.7 cm, so one pair can only see a 13 cm change."),
            CurriculumDrill(
                drill: Drill(name: "Rested blocks", reps: 10, sets: 6, spots: [],
                             constraint: "Sixty seconds of rest between sets, and the session stops at the set where entry angle has fallen a full session SD rather than pushing through it.",
                             schedule: "Blocked, with the rest interval as the variable under test."),
                purpose: "Find the rest interval at which your own drift disappears, instead of training through it.",
                filmFrom: .sideView,
                methodGrade: .b,
                source: "Reused from `FixLibrary`'s fatigue package. Bourdas et al. 2024: after 12 min of simulated game load in 38 high-level players, entry angle −3.1 to −3.9 %, release time +15–25 %, makes −14 to −19 %. Li et al. 2025 meta: SMD 0.67 moderate, 1.39 severe. Slawinski et al. 2018: zero release change in elite U18s after sprints."),
            CurriculumDrill(
                drill: Drill(name: "Clock sets", reps: 8, sets: 6, spots: [.midRange, .three],
                             constraint: "Shoot each repetition inside a four-second count from the catch. A shot that leaves late does not count.",
                             schedule: "Blocked, near spot first."),
                purpose: "Put a constraint on the shot that resembles a possession rather than a drill.",
                filmFrom: .sideView,
                methodGrade: .d,
                source: "Time-pressure drills are near-universal coaching practice with no controlled measurement found for shooting mechanics. The constraints-led literature is quasi-experimental with no shooting-mechanics outcome (grade C)."),
        ],
        doneWhen: [
            DoneCheck(
                plainWords: "Your late-session block's release-speed spread is no more than about 1.4× your first block's.",
                check: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot,
                                 target: .narrowByFraction(notWiderRatio),
                                 description: "the late block's release-speed SD at or below 1.43 × the first block's — the smallest widening 30 shots a side can be told from chance",
                                 minimumN: 25),
                grade: .a,
                source: "healthy-shot-model-2026-09-14.md §4: the defensible definition of versatility is unchanged spread across conditions. Amaro et al. 2025 (18 national-level players, 90 shots each): no significant effect of a 1.2×-height defender at 1 m or 105 dBA noise on jump height, release height, angle or velocity (all p ≥ 0.092). The ratio is arithmetic."),
            DoneCheck(
                plainWords: "Your late-session mean entry angle still clears 40°.",
                check: PassCheck(measure: .entryAngleMeanDegrees, scope: .findingSpot,
                                 target: .insideBand(low: 40, high: 52),
                                 description: "the late block's mean entry angle at or above 40°, the same band as the first block",
                                 minimumN: 20),
                grade: .a,
                source: "Bourdas et al. 2024 for entry angle being the channel that falls under game load (−3.1 to −3.9 %); the 40° band is exact geometry. That it falls for *you* is measured, never assumed — Slawinski et al. 2018 found no change in elite U18s."),
            DoneCheck(
                plainWords: "Your shot does not drift end to end across the session.",
                unavailableReason: "The end-to-end change is produced by the shot doctor's over-session trend read-out rather than by the pass-check reader, so it is shown as a trend and cannot close the module. Compare a first and a last block instead; one pair can only resolve a 13 cm change in mean depth.",
                grade: .a,
                source: "Textbook Ch 15 §15.3.4; the 4.7 cm standard error of a set-of-10 mean depth is arithmetic (`DESIGN-MEMO-2026-09-13.md` §3.5)."),
        ],
        faults: [
            CurriculumFault(
                name: "Fading late in the session",
                howItShowsInNumbers: "Entry angle falling and release time lengthening between the first and last blocks, with the makes following.",
                hypothesis: .fatigueDrift,
                grade: .a,
                sources: ["Bourdas et al. 2024 (38 high-level players, 12-min simulated game protocol).",
                          "Li et al. 2025 meta-analysis of 14 studies, n = 388: accuracy SMD 0.67 moderate, 1.39 severe."]),
            CurriculumFault(
                name: "The shot drifting through the session",
                howItShowsInNumbers: "Total change in crossing depth from the first counted shot to the last, reported as a total and never as a slope.",
                hypothesis: .withinSessionDrift,
                grade: .a,
                sources: ["Textbook Ch 15 §15.3.4. That drift can happen is established; that it happens to you is measured (Slawinski et al. 2018 found none in elite U18s)."]),
            CurriculumFault(
                name: "\"Fatigue always flattens your arc\"",
                howItShowsInNumbers: "Sometimes nothing at all. Elite U18s showed zero release change after repeated sprints, and moderate fatigue had no significant three-point effect in the meta-analysis.",
                hypothesis: nil,
                grade: .d,
                sources: ["Slawinski et al. 2018 (no release change after repeated sprints in elite U18s).",
                          "Li et al. 2025 (no significant three-point effect at moderate fatigue). Measure drift; never assume it."]),
            CurriculumFault(
                name: "\"A defender changes your mechanics\"",
                howItShowsInNumbers: "At skilled level, not measurably — what widens is the spread, not the mean. In NBA games, contests raised depth variance 56 % and left–right variance 38 % without biasing the mechanics.",
                hypothesis: nil,
                grade: .a,
                sources: ["Amaro et al. 2025: no significant effect of opposition or noise on jump height, release height, release angle or velocity in 18 national-level players (all p ≥ 0.092, η²p ≤ 0.004).",
                          "Daly-Grafstein & Bornn 2020: tight contests biased shots short and raised depth variance 56 %, lateral variance 38 %."]),
        ],
        openQuestions: [
            "ArcLab cannot film a defender or a shot clock; this module is scored on blocks inside your own session, which is a weaker condition than a game.",
            "Drift needs a first and a last block at the same spot in the same session, and the pair only resolves a large change — three session pairs pooled resolve about 7.6 cm.",
        ])
}
