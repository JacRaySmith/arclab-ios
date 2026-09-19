import Foundation

// MARK: - What a fix is made of

/// The five plain lines every drill answers, in the order a shooter needs them. Built by
/// `Drill.plainCard` and `CurriculumDrill.card`, so Learn, Plan and the block card all render the
/// same shape and a new drill cannot quietly ship in a different one.
public struct DrillCard: Sendable {
    /// Where to stand, where the phone goes, how many shots.
    public var setup: String
    /// The one thing to do on every shot. Imperative, one sentence. The only line the block card
    /// shows large, because it is the one read at arm's length on a court.
    public var doThis: String
    /// What makes a shot count, in plain words.
    public var counts: String
    /// How to spread the sets over the session.
    public var order: String
    /// What the app measures while you shoot, named the way a shooter would say it.
    public var watches: String
    /// When it is done, with the number the app will actually use.
    public var doneWhen: String
    /// Why it works, one sentence, ending in the grade of the evidence behind it.
    public var why: String
    /// The exact version for anyone who wants it: the study, the statistic, the gate in the app's
    /// own terms. Shown on tap, never on the court. This is the one field allowed to use the words
    /// the lines above deliberately avoid.
    public var detail: String?
}

public struct Drill: Sendable {
    public var name: String
    /// Shots per set.
    public var reps: Int
    public var sets: Int
    /// Where to shoot them. Empty means "wherever the finding was".
    public var spots: [DoctorSpot]
    /// What makes a shot count, rather than it being shooting around. Plain words: it is read on a
    /// court, and it is pasted verbatim into the practice block's instruction.
    public var constraint: String
    /// How to spread the sets over the session — one spot until it holds, then shuffled
    /// (`DESIGN-MEMO` C4; Shamshiri 2025). Plain words, for the same reason.
    public var schedule: String

    // MARK: - The plain-language card (added 2026-09-19)
    //
    // "Some of the descriptions are hard to follow" was a complaint about a real screen. The answer
    // is that every drill answers the same five questions in the same order, never states a
    // statistic where an instruction belongs, and keeps the precise version in `detail`.
    // Defaults are empty so every existing call site still compiles; `hasPlainCard` says which
    // drills have been written up and the tests require all of them to have been.

    /// Where to stand, where the phone goes, how many shots. Never an instruction.
    public var setup: String = ""
    /// The one thing to do on every shot. Imperative, one sentence.
    public var doThis: String = ""
    /// What the app measures while you shoot, in plain words.
    public var watches: String = ""
    /// When the drill is done, with the number the app will actually use.
    public var doneWhen: String = ""
    /// Why it works, one sentence, ending in its evidence grade.
    public var why: String = ""
    /// The precise version of all of the above. Shown on tap.
    public var detail: String? = nil

    public var totalShots: Int { reps * sets }

    /// True when the five lines have been written. False only for a drill that is not really a
    /// drill (`releaseHeightDrift` ships "None", because there is no honest thing to practise).
    public var hasPlainCard: Bool { !setup.isEmpty && !doThis.isEmpty }

    /// The card, or nil when there is nothing to show.
    public var plainCard: DrillCard? {
        guard hasPlainCard else { return nil }
        return DrillCard(setup: setup, doThis: doThis, counts: constraint, order: schedule,
                         watches: watches, doneWhen: doneWhen, why: why, detail: detail)
    }

    public init(name: String, reps: Int, sets: Int, spots: [DoctorSpot],
                constraint: String, schedule: String,
                setup: String = "", doThis: String = "", watches: String = "",
                doneWhen: String = "", why: String = "", detail: String? = nil) {
        self.name = name
        self.reps = reps
        self.sets = sets
        self.spots = spots
        self.constraint = constraint
        self.schedule = schedule
        self.setup = setup
        self.doThis = doThis
        self.watches = watches
        self.doneWhen = doneWhen
        self.why = why
        self.detail = detail
    }
}

public enum PassMeasure: String, Sendable, Codable, CaseIterable {
    case releaseSpeedSD, releaseSpeedSDRatioAcrossDistance
    case entryAngleMeanDegrees, depthMeanCm, depthSDCm
    case lateralMeanCm, lateralSDCm
    case dipToReleaseMean, dipToReleaseChangeAcrossDistance
    case spinAxisTiltDegrees, forearmFromVerticalDegrees
    case kneeDriveChangeAcrossDistance, proximalToDistalRate
    case headStabilityNormalised, depthTotalChangeOverSession
    case speedShareOfDepthVariance
}

public enum PassSpotScope: String, Sendable, Codable {
    /// The spot the finding was made at.
    case findingSpot
    /// The farthest spot with data — where a range problem shows.
    case farSpot
    /// Across distance: near vs far.
    case acrossDistance
}

/// How the next session's number has to relate to this session's.
public enum PassTarget: Sendable {
    /// Narrow to at most baseline ÷ (detectable ratio at the smaller n). The smallest honest target.
    case narrowByDetectableRatio
    /// Narrow to at most `fraction` × baseline.
    case narrowByFraction(Double)
    /// Land inside `[low, high]` in the measure's own unit.
    case insideBand(low: Double, high: Double)
    /// Move at least this far in the named direction, in the measure's own unit.
    case moveBy(Double)
    /// No numeric target exists — the number is reported and watched, never scored.
    case reportOnly
}

public struct PassCheck: Sendable {
    public var measure: PassMeasure
    public var scope: PassSpotScope
    public var target: PassTarget
    /// What the shooter is told to expect, in words a shooter uses. No statistic stands in for an
    /// instruction here: the precise version goes in `detail`.
    public var description: String
    /// Below this the check is not run and says so.
    public var minimumN: Int
    /// The gate stated exactly — the measure's engine name, the arithmetic, the study. Shown on tap
    /// behind the plain sentence, so nothing is lost by saying it plainly first.
    public var detail: String? = nil
}

public struct FixPackage: Sendable {
    public var hypothesis: HypothesisID
    /// One sentence, external focus (on the ball and the target, not on the body).
    public var cue: String
    public var drill: Drill
    /// The measure the app watches, named in the shooter's words.
    public var measureThatShouldMove: String
    /// How much movement is plausible, and over what.
    public var expectedMagnitude: String
    public var passCheck: PassCheck
    /// What must still be true the session after, or the change did not stick.
    public var retentionRule: String
    /// The grade of the *evidence that this measure matters*, not of the cue's wording.
    public var grade: ShotEvidenceGrade
    public var source: String
    /// The per-player A/B this fix should really be settled by (`DESIGN-MEMO` C1), when one is worth running.
    public var trialSuggestion: String?
}

// MARK: - The library

public enum FixLibrary {

    /// Non-negotiable, shown with every plan.
    public static let honestyRules: [String] = [
        "One fix at a time. The app keeps exactly one active plan; everything else waits in the queue, because two changes at once means neither can be scored.",
        "Nothing fires below its shot floor. A finding drawn from too few shots is a coin flip with a sentence attached.",
        "Everything here is \"associated with\", never \"because\". Nothing in the published literature is a demonstrated cause of a make for an individual shooter, and nothing measured on you is either.",
        "Cue wording itself is unproven: the bias-corrected meta-analysis of external-focus cues finds g = 0.01 on performance with Bayes factors favouring the null. The cue is a delivery vehicle; the measured change is the evidence.",
        "The score of a fix is what survives to the next session, not what happened at the end of this one.",
    ]

    public static func package(for id: HypothesisID) -> FixPackage {
        switch id {

        case .rangeStrengthLimit:
            return FixPackage(
                hypothesis: id,
                cue: "From every distance, send the ball over the front rim to the same spot on the back of the ring.",
                drill: Drill(name: "Distance ladder", reps: 5, sets: 16,
                             spots: [.freeThrow, .elbow, .midRange, .three],
                             constraint: "Step back only after two shots in a row pass inside your own make band. Step forward again the moment three in a row miss it.",
                             schedule: "Stay in distance order for your first two sessions, then shuffle the distances.",
                             setup: "Four distances: free throws, elbow, mid-range and three. Phone side-on on a tripod with the ring in frame. 5 shots at each distance, four rounds — 80 shots.",
                             doThis: "Send the ball to the same point over the back of the ring from every distance.",
                             watches: "How much the speed you send the ball at varies at your farthest spot.",
                             doneWhen: "Next session that spread is clearly tighter than this session's — about \(Curriculum.narrowByPercent) % tighter if you shoot 30 there.",
                             why: "How much your release speed varies is the strongest published predictor of shooting percentage there is, and shooters with real range do not vary more when they step back. Grade A.",
                             detail: "Gate: releaseSpeedSD at the far spot ÷ the detectable SD ratio exp(1.96/√n), 1.43 at n = 30. Slegers, Lee & Wong 2021 JSSM: skilled velocity SD was the same at free-throw and 3-point range and correlated r = −0.96 with 3P%. Schedule: blocked practice wins during acquisition and loses on retention and transfer (Shamshiri 2025, ηp² = 0.24)."),
                measureThatShouldMove: "how much the speed you send the ball at varies, at your farthest spot",
                expectedMagnitude: "At 30 shots there, the smallest narrowing that can be told from luck is about \(Curriculum.narrowByPercent) %. So the target is to get your far-spot spread down to roughly your near-spot spread — not to a number, to a match.",
                passCheck: PassCheck(measure: .releaseSpeedSD, scope: .farSpot, target: .narrowByDetectableRatio,
                                     description: "next session's speed spread at your far spot is clearly tighter than this session's — about \(Curriculum.narrowByPercent) % tighter if you shoot 30 there",
                                     minimumN: 25,
                                     detail: "releaseSpeedSD at the far spot, next session at or below this session's ÷ exp(1.96/√n) — the detectable SD ratio, 1.43 at n = 30. Minimum 25 counted shots."),
                retentionRule: "It has to still be there the session after next, in the first two counted sets after your warm-up. Those sets are the real test — not the end of the session you practised it in.",
                grade: .a,
                source: "Slegers, Lee & Wong 2021 JSSM: skilled velocity SD was the same at free-throw and 3-point range and correlated r = −0.96 with 3P%. Variable-distance practice: Shoenfelt et al. 2002 (equalled constant practice on delayed retention), grade B.",
                trialSuggestion: "Worth testing the cue itself: alternate sets of \"same spot on the back of the ring\" against your normal routine, at the far spot only, and compare set against set. Expect to need about 12 sets each way across two or three sessions before the answer means anything.")

        case .speedVariability:
            return FixPackage(
                hypothesis: id,
                cue: "Finish every shot with the ball leaving the same two fingers at the same moment.",
                drill: Drill(name: "One-spot depth band", reps: 10, sets: 8, spots: [],
                             constraint: "A shot counts only if it passed inside your own make band. A shot that drops in short or long is called a miss here, because depth is what is being practised.",
                             schedule: "One spot, every set, the whole session — the feel is new.",
                             setup: "One spot, and stay there all session. Phone side-on on a tripod with the ring in frame. 10 shots a set, 8 sets.",
                             doThis: "Send every ball to the same point over the back half of the ring.",
                             watches: "How much the speed you send the ball at varies from shot to shot.",
                             doneWhen: "Next session that spread is clearly tighter than this session's — about \(Curriculum.narrowByPercent) % tighter if you shoot 30 a side.",
                             why: "How much your release speed varies is the strongest published predictor of shooting percentage there is, at r = −0.96 with three-point percentage in skilled shooters. Grade A.",
                             detail: "Gate: releaseSpeedSD at the finding spot ÷ exp(1.96/√n). Slegers 2021: speed SD is the strongest measured correlate. Delta-method attribution, textbook Ch 5; detectability floor, DESIGN-MEMO §3.5. The make band is your own, computed from your own makes once there are enough of them."),
                measureThatShouldMove: "how much the speed you send the ball at varies, at the spot this came from",
                expectedMagnitude: "Under 100 shots a side, nothing smaller than a fifth can be claimed honestly. Plan on two or three sessions before the number means anything.",
                passCheck: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot, target: .narrowByDetectableRatio,
                                     description: "next session's shot-to-shot speed spread is clearly tighter than this session's — about \(Curriculum.narrowByPercent) % tighter if you shoot 30 a side",
                                     minimumN: 25,
                                     detail: "releaseSpeedSD at the finding spot, next session at or below this session's ÷ exp(1.96/√n), 1.43 at n = 30. Minimum 25 counted shots."),
                retentionRule: "The tighter spread has to turn up again in the first two counted sets of the next session, with nobody reminding you.",
                grade: .a,
                source: "Slegers 2021 (speed SD is the strongest measured correlate); delta-method attribution, textbook Ch 5; detectability floor, DESIGN-MEMO §3.5.",
                trialSuggestion: nil)

        case .speedUndershoot:
            return FixPackage(
                hypothesis: id,
                cue: "Send it over the front rim to the back of the ring, every time.",
                drill: Drill(name: "Back-of-the-ring block", reps: 10, sets: 6, spots: [],
                             constraint: "A shot counts only if it missed the front of the ring. Touching the front rim does not count, even if it goes in.",
                             schedule: "One spot, every set, while the feel is new.",
                             setup: "One spot. Phone side-on on a tripod with the ring in frame. 10 shots a set, 6 sets.",
                             doThis: "Send every ball over the front of the ring and onto the back of it.",
                             watches: "How far past the front of the ring your shots pass, on average.",
                             doneWhen: "Next session that average sits between 25 and 28 cm past the front of the ring, over at least 20 counted shots.",
                             why: "Across more than 50 000 tracked NBA threes, the shots that went in passed 25–28 cm past the front of the ring. Grade A, but measured on NBA threes rather than on you.",
                             detail: "Gate: depthMeanCm inside ShotDoctor.publishedMakeDepthBand (25–28 cm), minimum 20 counted shots. Daly-Grafstein & Bornn 2019 JQAS, >50 000 NBA 3-point trajectories, against a ring centre at 22.9 cm. Mullineaux & Uhl 2010: misses released 0.12 m/s slow, swishes 0.02 m/s."),
                measureThatShouldMove: "how far past the front of the ring your shots pass, on average",
                expectedMagnitude: "Aiming at the back of the ring rather than the front moves that average 5–10 cm, which is about the smallest a set of ten can see at all.",
                passCheck: PassCheck(measure: .depthMeanCm, scope: .findingSpot,
                                     target: .insideBand(low: ShotDoctor.publishedMakeDepthBand.low * 100,
                                                         high: ShotDoctor.publishedMakeDepthBand.high * 100),
                                     description: "next session's average passes between 25 and 28 cm past the front of the ring",
                                     minimumN: 20,
                                     detail: "depthMeanCm inside ShotDoctor.publishedMakeDepthBand, minimum 20 counted shots. A set-of-10 mean depth has a standard error of 4.7 cm, so one session pair only resolves a 13 cm change; three pooled pairs resolve 7.6 cm."),
                retentionRule: "The average has to still be in that band in the next session's first two counted sets, and it takes three session pairs before the shift is called real.",
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019 JQAS: make probability peaked 25–28 cm past the front rim over >50 000 NBA 3-point trajectories. Mullineaux & Uhl 2010: misses released 0.12 m/s slow, swishes 0.02 m/s.",
                trialSuggestion: "This is the one worth testing properly: \"back of the ring\" against your normal routine, alternating sets, judged on how deep your shots pass. It is one of the few cues big enough to show up in a single session.")

        case .rushedPreparation:
            return FixPackage(
                hypothesis: id,
                cue: "Let the ball sit in the dip for a beat before you send it.",
                drill: Drill(name: "Metronome dip", reps: 8, sets: 8, spots: [],
                             constraint: "A shot counts only if it left on the second click. Set the metronome to your own near-spot time from the bottom of the dip to the release, and keep that same beat from every distance.",
                             schedule: "Near spot first, every set, then the far spot on the same beat.",
                             setup: "One near spot and one far spot, plus a metronome on your watch or phone. Phone side-on on a tripod. 8 shots a set, 8 sets.",
                             doThis: "Let the ball sit at the bottom of the dip for one click, then send it on the next.",
                             watches: "The time from the lowest point of the ball to the ball leaving your hand, and how much it changes when you step back.",
                             doneWhen: "Your far-spot time moves at least 0.05 s back towards your near-spot time, over at least 20 counted shots.",
                             why: "Holding one beat stops you hurrying the long shots — and since two studies disagree about whether quicker or slower is better, the only honest target is your own tempo. Grade B.",
                             detail: "Gate: dipToReleaseChangeAcrossDistance, far spot moving ≥ 0.05 s toward the near-spot value, minimum 20 counted shots. No published reference range for dip-to-release exists in any population; 0.05 s is the smallest move the measure resolves at these counts."),
                measureThatShouldMove: "the time from the bottom of your dip to the release at your far spot, and how much it varies",
                expectedMagnitude: "The target is your own near-spot tempo rather than a published number, because nobody has published a normal range for this at all.",
                passCheck: PassCheck(measure: .dipToReleaseChangeAcrossDistance, scope: .acrossDistance,
                                     target: .moveBy(0.05),
                                     description: "your far-spot time from the bottom of the dip to the release moves at least 0.05 s back towards your near-spot time",
                                     minimumN: 20,
                                     detail: "dipToReleaseChangeAcrossDistance, scope acrossDistance, target moveBy(0.05), minimum 20 counted shots. 0.05 s is the smallest move the measure resolves at these shot counts, not a published number."),
                retentionRule: "Next session, without the metronome, your far-spot tempo has to still be closer to your near-spot tempo than your near-spot times are to each other.",
                grade: .b,
                source: "Cabarkapa et al. 2023 Front Sports Act Living: proficient shooters moved slower and lower in preparation (knee peak 212.9 vs 269.4 °/s, ES 1.04) with no release-phase differences. Botsi et al. 2024: higher-level U18s released 12.5 % faster — direction only, and the two findings pull opposite ways, so only your own consistency is read.",
                trialSuggestion: "Because the studies disagree about which direction is better, run this as a test rather than a rule: alternate metronome sets against normal sets and compare how much your shots spread front to back.")

        case .armDominantDrive:
            return FixPackage(
                hypothesis: id,
                cue: "Push the floor away and let the ball go on the way up.",
                drill: Drill(name: "Step-in range extension", reps: 6, sets: 8, spots: [.midRange, .three],
                             constraint: "A shot counts only if the step and the shot were one movement. Record the stepping sets and the standing sets separately so the two can be compared.",
                             schedule: "Alternate: one stepping set, one standing set.",
                             setup: "Mid-range and three. Phone side-on on a tripod. 6 shots a set, 8 sets — four stepping, four standing.",
                             doThis: "Take one step into the shot from behind the line so your legs supply the extra distance.",
                             watches: "How fast your knees straighten, and how much your release speed varies with it.",
                             doneWhen: "Done when you have four sets each way and the app can show you which way your own numbers went. The knee number is shown, never scored — nobody has published a target for one person.",
                             why: "Experts get extra distance by changing how fast they send the ball rather than by bending more, so \"use your legs\" is a thing to test on yourself, not a rule. Grade B.",
                             detail: "kneeDriveChangeAcrossDistance is reportOnly: no published reference range exists for knee-extension peak rate on an individual. Cabarkapa et al. 2023 (knee peak angular velocity separates proficient from non-proficient, recreational, between groups); Okazaki & Rodacki 2012 (experts compensated with release speed, not joint angles). Needs a close form clip; ArcLab's metre-scale body numbers are not trusted yet."),
                measureThatShouldMove: "how fast your knees straighten at the far spot, and how much your release speed varies with it",
                expectedMagnitude: "Nobody has published a target for how fast one person's knees should straighten, so the comparison is your stepping sets against your standing sets in the same session.",
                passCheck: PassCheck(measure: .kneeDriveChangeAcrossDistance, scope: .acrossDistance,
                                     target: .reportOnly,
                                     description: "your knees straighten faster as you step back instead of staying the same — there is no published range to score it against",
                                     minimumN: 15,
                                     detail: "kneeDriveChangeAcrossDistance, scope acrossDistance, target reportOnly, minimum 15 counted shots."),
                retentionRule: "What has to be tighter next session is your far-spot release speed. The knee number is background, not the score.",
                grade: .b,
                source: "Cabarkapa et al. 2023 (knee peak angular velocity separates proficient from non-proficient, recreational sample, between groups); Okazaki & Rodacki 2012 (experts showed no significant ankle/knee/hip change with distance and compensated with speed). Requires a close form clip; ArcLab's metre-scale body numbers are not trusted yet.",
                trialSuggestion: nil)

        case .flatArcGeometry:
            return FixPackage(
                hypothesis: id,
                cue: "Drop it through the top of the ring, not through the front of it.",
                drill: Drill(name: "Over-the-top", reps: 10, sets: 6, spots: [],
                             constraint: "A shot counts only if it cleared the bar. A shot that would clip it does not count, even if it goes in.",
                             schedule: "One spot, every set.",
                             setup: "One spot. Get a helper to hold a pole about a metre in front of the ring and half a metre above ring height — or picture a bar there. Phone side-on on a tripod. 10 shots a set, 6 sets.",
                             doThis: "Send every ball over the bar and down into the ring.",
                             watches: "The angle your ball is falling at when it reaches the ring.",
                             doneWhen: "Next session your average falling angle is 40° or steeper, over at least 20 counted shots. Steeper than the mid-40s buys nothing, so the app does not ask for it.",
                             why: "Below 40° the ball has under 3 cm of room to fit through the ring, and below about 32° it cannot fit at all. Grade A for that geometry; grade C for a bar being the way to change it.",
                             detail: "Gate: entryAngleMeanDegrees inside 40–52°, minimum 20 counted shots. The floor is asin(d_ball/d_rim) — 31.4° for a 0.2385 m ball, 32.1° at the top of the rulebook tolerance. Daly-Grafstein & Bornn 2020: entry angle is the least peaked of the three rim-plane variables, so there is nothing to gain past the mid-40s."),
                measureThatShouldMove: "the angle your ball is falling at when it reaches the ring, on average",
                expectedMagnitude: "Getting from below 40° to above it buys real room — under 40° the ball has less than 3 cm to spare, and at the floor it has none. Past the mid-40s there is nothing more to gain.",
                passCheck: PassCheck(measure: .entryAngleMeanDegrees, scope: .findingSpot,
                                     target: .insideBand(low: 40, high: 52),
                                     description: "next session's average falling angle is 40° or steeper, and no steeper than the mid-40s",
                                     minimumN: 20,
                                     detail: "entryAngleMeanDegrees inside 40–52° at the finding spot, minimum 20 counted shots."),
                retentionRule: "It has to still clear 40° in the next session's first two counted sets — and your front-to-back spread must not have got wider to pay for it.",
                grade: .a,
                source: "Exact geometry: asin(d_ball/d_rim) floor: 31.4° for a 0.2385 m ball, 32.1° at the top of the rulebook tolerance, under 3 cm of margin by 40°. Daly-Grafstein & Bornn 2020 for the band being flat over a range; \"45° for everyone\" is a vendor claim with no published method (grade D).",
                trialSuggestion: nil)

        case .arcVersusTurnover:
            return FixPackage(
                hypothesis: id,
                cue: "Same height on the ball every time; let the distance come from the legs, not from the arc.",
                drill: Drill(name: "Arc hold", reps: 10, sets: 6, spots: [],
                             constraint: "A shot counts only if the arc looked like the last one. Whether it went in does not decide it.",
                             schedule: "One spot, every set.",
                             setup: "One spot. Phone side-on on a tripod with the ring in frame. 10 shots a set, 6 sets.",
                             doThis: "Send every ball up on the same arc, and let the distance come from your legs.",
                             watches: "How far past the front of the ring your shots pass, and how much that varies.",
                             doneWhen: "Next session your front-to-back spread is clearly tighter than this session's — about \(Curriculum.narrowByPercent) % tighter if you shoot 30 a side.",
                             why: "When your angle errors and your speed errors stop happening together, your shots tighten up front to back without either one getting steadier on its own. Grade A: that part is arithmetic.",
                             detail: "Gate: depthSDCm at the finding spot ÷ exp(1.96/√n). Geometry per shot (`ReleaseSensitivity.depthTurnoverAngle`); textbook Ch 5 §5.4 — the pairwise term 2·Jθ·Jv·Cov(θ,v) helps only when its sign is negative, which is not the same as Cov(θ,v) being negative. Slegers 2022: each shooter's optimal angle sits 4.3 ± 2.1° above their own minimum-speed angle."),
                measureThatShouldMove: "how much your shots vary front to back",
                expectedMagnitude: "This is arithmetic rather than a training effect: when your angle errors and your speed errors stop moving together, your front-to-back spread falls without either of them getting tighter.",
                passCheck: PassCheck(measure: .depthSDCm, scope: .findingSpot, target: .narrowByDetectableRatio,
                                     description: "next session's front-to-back spread is clearly tighter than this session's — about \(Curriculum.narrowByPercent) % tighter if you shoot 30 a side",
                                     minimumN: 25,
                                     detail: "depthSDCm at the finding spot, next session at or below this session's ÷ exp(1.96/√n), 1.43 at n = 30. Minimum 25 counted shots."),
                retentionRule: "It has to happen again the following session. One tighter session on its own is inside what luck produces.",
                grade: .a,
                source: "Geometry per shot (`ReleaseSensitivity.depthTurnoverAngle`); textbook Ch 5 §5.4 — the pairwise term 2·Jθ·Jv·Cov(θ,v) helps only when its sign is negative, which is not the same as Cov(θ,v) being negative. Slegers 2022: each shooter's optimal angle sits 4.3 ± 2.1° above their own minimum-speed angle and correlates r = 0.78 with their own release covariance.",
                trialSuggestion: nil)

        case .depthBiasShort:
            var p = package(for: .speedUndershoot)
            p.hypothesis = id
            p.measureThatShouldMove = "how far past the front of the ring your shots pass, on average — all of them, not just the misses"
            return p

        case .depthBiasLong:
            return FixPackage(
                hypothesis: id,
                cue: "Drop it just past the front rim, not onto the back of the ring.",
                drill: Drill(name: "Front-half band", reps: 10, sets: 6, spots: [],
                             constraint: "A shot counts only if it landed in the front half of the ring. Touching the back iron does not count.",
                             schedule: "One spot, every set.",
                             setup: "One spot. Phone side-on on a tripod with the ring in frame. 10 shots a set, 6 sets.",
                             doThis: "Drop every ball into the front half of the ring, just past the front rim.",
                             watches: "How far past the front of the ring your shots pass, on average.",
                             doneWhen: "Next session that average sits between 25 and 28 cm past the front of the ring, over at least 20 counted shots.",
                             why: "Across more than 50 000 tracked NBA threes, the shots that went in passed 25–28 cm past the front of the ring, and you are currently passing deeper than that. Grade A.",
                             detail: "Gate: depthMeanCm inside ShotDoctor.publishedMakeDepthBand, minimum 20 counted shots. Daly-Grafstein & Bornn 2019 JQAS. A set-of-10 mean depth has a standard error of 4.7 cm, so one pair only resolves a 13 cm change."),
                measureThatShouldMove: "how far past the front of the ring your shots pass, on average",
                expectedMagnitude: "Changing where you aim, front against back, moves that average 5–10 cm — right at the edge of what a set of ten can see.",
                passCheck: PassCheck(measure: .depthMeanCm, scope: .findingSpot,
                                     target: .insideBand(low: ShotDoctor.publishedMakeDepthBand.low * 100,
                                                         high: ShotDoctor.publishedMakeDepthBand.high * 100),
                                     description: "next session's average passes between 25 and 28 cm past the front of the ring",
                                     minimumN: 20,
                                     detail: "depthMeanCm inside ShotDoctor.publishedMakeDepthBand, minimum 20 counted shots."),
                retentionRule: "The average has to hold in that band across three session pairs before the shift is called real — one pair can only see a 13 cm change.",
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019 JQAS, as above.",
                trialSuggestion: "Front of the ring against back of the ring is the clearest test available: it moves your average 5–10 cm, which is big enough to see.")

        case .lateralAimBias:
            return FixPackage(
                hypothesis: id,
                cue: "Send it over the middle of the ring, between the two side hooks.",
                drill: Drill(name: "Behind-camera line set", reps: 10, sets: 4, spots: [],
                             constraint: "A set counts only if it was filmed from directly behind you, so left and right are measured rather than felt.",
                             schedule: "One spot, every set.",
                             setup: "One spot, with the phone directly behind you on the line to the basket and the ring in frame. 10 shots a set, 4 sets.",
                             doThis: "Send every ball over the middle of the ring, between the two side hooks.",
                             watches: "How far left or right of the middle of the ring your shots pass, on average.",
                             doneWhen: "Next session that average sits within 3 cm either side of the middle, over at least 20 counted shots.",
                             why: "The ring leaves the ball about 11 cm of room either side, so 3 cm off centre is real but chasing dead centre is not — professionals average near zero and it is the scatter that predicts. Grade A.",
                             detail: "Gate: lateralMeanCm inside ±3 cm, minimum 20 counted shots. Daly-Grafstein & Bornn 2019/2020: mean offset near zero in professionals; the variance, not the mean, predicts, and in-game contests raise lateral variance 38 % without moving the mean. The ±11 cm tolerance is exact ring geometry."),
                measureThatShouldMove: "how far left or right of the middle your shots pass, on average",
                expectedMagnitude: "The ring leaves the ball about 11 cm of room either side. Bringing an average of 6 cm off centre down to under 3 cm is a real change; chasing dead centre is not, because professionals sit near zero and it is the scatter that predicts.",
                passCheck: PassCheck(measure: .lateralMeanCm, scope: .findingSpot, target: .insideBand(low: -3, high: 3),
                                     description: "next session's average left-right miss sits inside 3 cm either side of the middle",
                                     minimumN: 20,
                                     detail: "lateralMeanCm at the finding spot inside ±3 cm, minimum 20 counted shots. Needs the behind-the-shooter clip."),
                retentionRule: "The centred average has to survive into the next session's first two counted sets, filmed from behind again.",
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019/2020: mean offset near zero in professionals; the variance, not the mean, predicts, and in-game contests raise lateral variance 38 % without moving the mean. The ±11 cm tolerance is exact ring geometry.",
                trialSuggestion: nil)

        case .lateralVariability:
            var p = package(for: .lateralAimBias)
            p.hypothesis = id
            p.cue = "Finish with your hand pointing down the middle of the ring and hold it there until the ball lands."
            p.measureThatShouldMove = "how much your shots scatter left and right at the ring"
            p.passCheck = PassCheck(measure: .lateralSDCm, scope: .findingSpot, target: .narrowByDetectableRatio,
                                    description: "next session's left-right spread is clearly tighter than this session's — about \(Curriculum.narrowByPercent) % tighter if you shoot 30 a side",
                                    minimumN: 25,
                                    detail: "lateralSDCm at the finding spot, next session at or below this session's ÷ exp(1.96/√n), 1.43 at n = 30. Minimum 25 counted shots.")
            p.expectedMagnitude = "Under 100 shots a side, nothing smaller than a fifth can be claimed honestly."
            p.drill.doThis = "Finish every shot with your hand pointing down the middle of the ring, and hold it there until the ball lands."
            p.drill.watches = "How much your shots scatter left and right of the middle of the ring."
            p.drill.doneWhen = "Next session that scatter is clearly tighter than this session's — about \(Curriculum.narrowByPercent) % tighter if you shoot 30 a side."
            p.drill.why = "How consistently the ball comes off your hand on the same line predicts your left-right accuracy; how far off centre you average does not. Grade A."
            return p

        case .spinAxisTilt:
            return FixPackage(
                hypothesis: id,
                cue: "Roll the ball off the two middle fingers so it comes back straight at you.",
                drill: Drill(name: "Taped-stripe spin set", reps: 10, sets: 4, spots: [],
                             constraint: "A shot counts only if you watched the stripe rather than the result. Whether it went in does not decide it.",
                             schedule: "One near spot, every set — the spin is easier to control before the distance makes you work.",
                             setup: "One near spot, with a strip of tape right around the ball's seam and the phone directly behind you. 10 shots a set, 4 sets.",
                             doThis: "Watch the stripe as the ball flies and make it come back at you flat, with no tilt.",
                             watches: "How far the ball's spin is tilted away from straight backspin.",
                             doneWhen: "Next session that tilt averages within 10° of straight backspin, over at least 15 counted shots — and your left-right scatter has not got wider.",
                             why: "How steady your spin stays predicts where the ball misses left and right. Grade B: one study, skilled shooters.",
                             detail: "Gate: spinAxisTiltDegrees inside ±10°, minimum 15 counted shots. Spin-axis consistency correlates r = 0.80 with left-right consistency (healthy-shot model §6 row 4). Feasibility and resolution: DESIGN-MEMO §3.7 — 2–3° per frame at 120 fps, so a 10° change is visible. Needs the behind-the-shooter clip and the taped-stripe mode, which is not shipped."),
                measureThatShouldMove: "how far the ball's spin is tilted away from straight backspin, and your left-right scatter with it",
                expectedMagnitude: "A little sidespin — a fifth of a turn a second — shows up as roughly 20° of tilt, and the app can see a 10° change. So this is a visible thing, not a hair-splitting one.",
                passCheck: PassCheck(measure: .spinAxisTiltDegrees, scope: .findingSpot, target: .insideBand(low: -10, high: 10),
                                     description: "next session's average spin tilt is within 10° of straight backspin",
                                     minimumN: 15,
                                     detail: "spinAxisTiltDegrees at the finding spot inside ±10°, minimum 15 counted shots. Needs the taped-stripe capture mode, which is not shipped."),
                retentionRule: "The tilt has to stay within 10° next session, and your left-right scatter must not have got wider to pay for it.",
                grade: .b,
                source: "Spin-axis consistency correlates r = 0.80 with left-right consistency (healthy-shot model §6 row 4). Feasibility and resolution: DESIGN-MEMO §3.7. Needs the behind-the-shooter clip and the taped-stripe mode.",
                trialSuggestion: nil)

        case .forearmFlare:
            return FixPackage(
                hypothesis: id,
                cue: "Send the ball up the same line your arm is already on.",
                drill: Drill(name: "Wall-line form set", reps: 10, sets: 4, spots: [.freeThrow],
                             constraint: "A shot counts only if you shot along the floor line with the phone behind you — it is the only view that can see your forearm lean.",
                             schedule: "One spot close to the ring, every set.",
                             setup: "Free throws or closer, standing on a floor line, with the phone directly behind you on that line. 10 shots a set, 4 sets.",
                             doThis: "Send the ball up the same line your arm is already on, with your forearm upright.",
                             watches: "How far your forearm leans away from upright, seen from behind.",
                             doneWhen: "Next session that lean is at least a fifth smaller than this session's, over at least 15 counted shots.",
                             why: "Better shooters' forearms sat about 8° off upright and weaker shooters' about 20°. Grade B: between two groups of 17 recreational players in one session, so it is a direction, not a target.",
                             detail: "Gate: forearmFromVerticalDegrees, next session at or below 0.8 × this session's, minimum 15 counted shots. Cabarkapa & Fry 2021 CEJSSM: proficient 7.9 ± 7.2° vs non-proficient 19.8 ± 17.6°. Note the grade-A null against importing a joint target at all: excellent and good professionals showed no kinematic differences (Cabarkapa et al. 2022)."),
                measureThatShouldMove: "how far your forearm leans away from upright, seen from behind",
                expectedMagnitude: "The two published groups sat at about 8° and about 20° off upright. Those are where two groups happened to sit, not a target for you — what is scored is your own change.",
                passCheck: PassCheck(measure: .forearmFromVerticalDegrees, scope: .findingSpot, target: .narrowByFraction(0.8),
                                     description: "next session's average forearm lean is at least a fifth smaller than this session's",
                                     minimumN: 15,
                                     detail: "forearmFromVerticalDegrees at the finding spot, next session at or below 0.8 × this session's, minimum 15 counted shots. Needs the behind-the-shooter clip."),
                retentionRule: "The smaller lean has to turn up in the next session's behind-the-shooter set with nobody reminding you.",
                grade: .b,
                source: "Cabarkapa & Fry 2021 CEJSSM. Between-group, recreational, one session. Note the grade-A null against importing a joint target at all: excellent and good professionals showed no kinematic differences (Cabarkapa et al. 2022).",
                trialSuggestion: nil)

        case .shoulderSquareness:
            return FixPackage(
                hypothesis: id,
                cue: "Start every shot facing the same way you finish.",
                drill: Drill(name: "Same-feet repeat", reps: 10, sets: 4, spots: [],
                             constraint: "A shot counts only if it started from the same two chalk marks as the last one.",
                             schedule: "One spot, every set.",
                             setup: "One spot, with two chalk marks for your feet. Phone side-on on a tripod. 10 shots a set, 4 sets.",
                             doThis: "Start every shot facing the same way you finish it.",
                             watches: "How much the way you face changes from shot to shot — never how square you are, which has no published right answer.",
                             doneWhen: "There is no pass mark. Nobody has published a range for how square is square enough, so the app shows your own trend across sessions and never scores it.",
                             why: "What can be defended is that yours repeats, not that any particular angle is correct — the same coaches teach different answers. Grade C.",
                             detail: "reportOnly. No published squareness range exists at all; coaching consensus only. ArcLab's 3-D shoulder yaw from a near-side view is refused outright, and from other views is in the noisy class."),
                measureThatShouldMove: "how much the way you face changes from shot to shot — never how square you are",
                expectedMagnitude: "Nobody has published a range for how square is square enough, so there is no size of change to expect. Only your own repeatability can move.",
                passCheck: PassCheck(measure: .headStabilityNormalised, scope: .findingSpot, target: .reportOnly,
                                     description: "there is no published range to pass or fail against, so only your own trend across sessions is shown",
                                     minimumN: 15,
                                     detail: "headStabilityNormalised, target reportOnly, minimum 15 counted shots."),
                retentionRule: "Shown across sessions as a trend in how well it repeats. Never scored.",
                grade: .c,
                source: "No published range at all; coaching consensus only. ArcLab's 3-D shoulder yaw from a near-side view is refused outright, and from other views is in the noisy class.",
                trialSuggestion: nil)

        case .withinSessionDrift:
            return FixPackage(
                hypothesis: id,
                cue: "Treat the last set like the first one: same routine, same tempo.",
                drill: Drill(name: "Bookend sets", reps: 10, sets: 6, spots: [],
                             constraint: "Only the four counted sets count — two at the start and two at the end, same spot. What you shoot in between is yours.",
                             schedule: "Two counted sets at the start, two at the end, with rest in between and free shooting in the middle.",
                             setup: "One spot, the same all session, with the phone in the same place at the start and at the end. 10 shots a set, 6 sets.",
                             doThis: "Shoot your last set exactly the way you shot your first: same routine, same tempo.",
                             watches: "How much deeper or shorter your shots pass at the end of the session than at the start.",
                             doneWhen: "Next session that start-to-end change is half of this session's or less, over at least 20 counted shots.",
                             why: "Whether your shot drifts through a session is measured on you rather than assumed — elite juniors showed no drift at all. Grade A for measuring first against last.",
                             detail: "Gate: depthTotalChangeOverSession, next session at or below 0.5 × this session's, minimum 20 counted shots. Textbook Ch 15 §15.3.4: report the total change across the session, not the slope and not a p-value. A set-of-10 mean depth has a standard error of 4.7 cm, so one pair only resolves 13 cm; three pooled pairs resolve 7.6 cm."),
                measureThatShouldMove: "how much deeper or shorter your shots pass at the end of the session than at the start",
                expectedMagnitude: "A set of ten pins the average down to about 4.7 cm, so a single start-and-end pair can only see a 13 cm change. Three session pairs together see 7.6 cm.",
                passCheck: PassCheck(measure: .depthTotalChangeOverSession, scope: .findingSpot, target: .narrowByFraction(0.5),
                                     description: "next session's start-to-end change in depth is half of this session's or less",
                                     minimumN: 20,
                                     detail: "depthTotalChangeOverSession at the finding spot, next session at or below 0.5 × this session's, minimum 20 counted shots."),
                retentionRule: "The flatter session has to happen again the session after. One flat session on its own is inside what luck produces.",
                grade: .a,
                source: "Textbook Ch 15 §15.3.4 (report the total change across the session, not the slope, not a p-value). That drift can happen is established (Bourdas et al. 2024); that it happens to you is measured, never assumed (Slawinski et al. 2018 found none in elite U18s).",
                trialSuggestion: nil)

        case .fatigueDrift:
            return FixPackage(
                hypothesis: id,
                cue: "Push the floor away on the last set exactly as hard as on the first.",
                drill: Drill(name: "Rested blocks", reps: 10, sets: 6, spots: [],
                             constraint: "Stop at the set where your falling angle has dropped by more than it normally varies, instead of pushing through it.",
                             schedule: "One spot, every set, with sixty seconds of rest between them — the rest is the thing being tested.",
                             setup: "One spot, and a timer for the rest. Phone side-on on a tripod. 10 shots a set, 6 sets.",
                             doThis: "Rest a full sixty seconds between sets, and push the floor away on the last set exactly as hard as on the first.",
                             watches: "The angle your ball is falling at, from the start of the session to the end.",
                             doneWhen: "Next session your falling angle drops less across the session than it did this one. It is shown against your own history, because there is no published range for it.",
                             why: "Twelve minutes of game-like load cost high-level players 3–4 % of their falling angle and 14–19 % of their makes — but elite juniors lost nothing, so it is measured on you. Grade A for the measurement.",
                             detail: "Gate: entryAngleMeanDegrees, target reportOnly, minimum 20 counted shots — reported against your own history, since no reliability SD exists yet. Bourdas et al. 2024 (entry −3.1 to −3.9 %, release time +15–25 %, makes −14 to −19 %); Li et al. 2025 meta (SMD 0.67 moderate, 1.39 severe); Slawinski et al. 2018 (zero change in elite U18s after sprints)."),
                measureThatShouldMove: "the angle your ball falls at, from the start of the session to the end",
                expectedMagnitude: "What has been measured elsewhere is a 3–4 % drop in falling angle and a 15–25 % slower release after twelve minutes of game-like work. Your own number is the one that counts.",
                passCheck: PassCheck(measure: .entryAngleMeanDegrees, scope: .findingSpot, target: .reportOnly,
                                     description: "next session's start-to-end drop in falling angle is smaller than this session's — shown against your own history, because there is no published range for it yet",
                                     minimumN: 20,
                                     detail: "entryAngleMeanDegrees, target reportOnly, minimum 20 counted shots. No reliability SD for the within-session change exists yet, so it cannot be scored against a threshold."),
                retentionRule: "Two sessions in a row without the drop before the rest is credited with anything.",
                grade: .a,
                source: "Bourdas et al. 2024 (entry −3.1 to −3.9 %, release time +15–25 %, makes −14 to −19 % after simulated game load); Li et al. 2025 meta (accuracy SMD 0.67 moderate, 1.39 severe); Slawinski et al. 2018 (zero change in elite U18s after sprints).",
                trialSuggestion: nil)

        case .sequencingDistalDominant:
            return FixPackage(
                hypothesis: id,
                cue: "Start the shot from the floor and let the ball be the last thing that moves.",
                drill: Drill(name: "Slow-to-fast chain", reps: 8, sets: 6, spots: [.freeThrow, .elbow],
                             constraint: "A shot counts only if the order was right — shoulder, then elbow, then wrist. Whether it went in does not decide it.",
                             schedule: "One spot close to the ring, every set, until the order repeats itself.",
                             setup: "Free throws and the elbow, with the phone close and waist-up at the highest frame rate it offers. 8 shots a set, 6 sets.",
                             doThis: "Start the shot from the floor and let the ball be the last thing that moves.",
                             watches: "How often your shoulder starts moving before your elbow does.",
                             doneWhen: "Next session your shoulder leads on at least half your shots, over at least 15 counted shots.",
                             why: "College players led with the shoulder at short range and recreational players led with the wrist. Grade B: 20 players, three shots each, so it is a pattern rather than a number.",
                             detail: "Gate: proximalToDistalRate inside 0.5–1.0, minimum 15 counted shots. Jiang et al. 2025 J Hum Kinet, 20 players, 13-camera 240 Hz, 3 successful shots per distance per player. No lag in milliseconds has ever been published, so ArcLab never scores one. Needs a close form clip."),
                measureThatShouldMove: "how often your shoulder starts moving before your elbow does",
                expectedMagnitude: "What was published is a pattern rather than a number: college players led with the shoulder, recreational players with the wrist. Nobody has published how many milliseconds apart they should be, so the app never scores one.",
                passCheck: PassCheck(measure: .proximalToDistalRate, scope: .findingSpot, target: .insideBand(low: 0.5, high: 1.0),
                                     description: "your shoulder leads on at least half of next session's shots",
                                     minimumN: 15,
                                     detail: "proximalToDistalRate inside 0.5–1.0, minimum 15 counted shots. Needs a close form clip."),
                retentionRule: "The order has to hold at full speed and at the far spot, not only in the slow sets.",
                grade: .b,
                source: "Jiang et al. 2025 J Hum Kinet, 20 players, 13-camera 240 Hz, 3 successful shots per distance per player. Needs a close form clip.",
                trialSuggestion: nil)

        case .headInstability:
            return FixPackage(
                hypothesis: id,
                cue: "Keep your eyes on the back of the ring until the ball lands.",
                drill: Drill(name: "Hold the look", reps: 10, sets: 4, spots: [],
                             constraint: "A shot counts only if your eyes stayed on the ring the whole way. If you tracked the ball out of your hand it does not count.",
                             schedule: "One spot, every set.",
                             setup: "One spot, with the phone close and waist-up so your head and shoulders fill the frame. 10 shots a set, 4 sets.",
                             doThis: "Keep your eyes on the back of the ring until the ball lands.",
                             watches: "How far your head travels between the lowest point of the ball and the release, as a share of your own height.",
                             doneWhen: "Next session your head travels at least a fifth less than this session — your own number, with no published range behind it.",
                             why: "Expert shooters hold their head and eyes steadier than beginners do, and the head is the part of balance a camera can actually see. Grade B: the studies are real but small.",
                             detail: "Gate: headStabilityNormalised, next session at or below 0.8 × this session's, minimum 15 counted shots. Ripoll et al. 1986 (head/eye stabilisation discriminates experts from beginners, small n, no retrievable effect size). The quiet-eye meta-analysis reports large effects on weak designs, and gaze is not measurable from a tripod — only head displacement is. Requires a close form clip and a fixed camera."),
                measureThatShouldMove: "how far your head travels between the dip and the release, as a share of your own height",
                expectedMagnitude: "No range has ever been published in any unit the app can measure, so only the direction of your own trend can be read.",
                passCheck: PassCheck(measure: .headStabilityNormalised, scope: .findingSpot, target: .narrowByFraction(0.8),
                                     description: "next session's head movement is at least a fifth smaller than this session's — your own number, with no published range behind it",
                                     minimumN: 15,
                                     detail: "headStabilityNormalised, next session at or below 0.8 × this session's, minimum 15 counted shots. Needs a close form clip and a camera that does not move."),
                retentionRule: "Shown as a trend across three sessions. One session's change is not a result.",
                grade: .b,
                source: "Ripoll et al. 1986 (head/eye stabilisation discriminates experts from beginners, small n, no retrievable effect size). The quiet-eye meta-analysis reports large effects on weak designs, and gaze is not measurable from a tripod — only head displacement is. Requires a close form clip and a fixed camera.",
                trialSuggestion: nil)

        case .releaseHeightDrift:
            return FixPackage(
                hypothesis: id,
                cue: "No cue. This measure has no agreed direction, so there is nothing honest to tell you to do.",
                drill: Drill(name: "None", reps: 0, sets: 0, spots: [],
                             constraint: "There is no drill here, because there is no target. How high you release is shown beside your other numbers and watched for change.",
                             schedule: "n/a"),
                measureThatShouldMove: "nothing — how high you release is background to your release angle, not something to change",
                expectedMagnitude: "None claimed.",
                passCheck: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot, target: .reportOnly,
                                     description: "studies disagree on which direction is better, so there is nothing honest to aim at",
                                     minimumN: 20,
                                     detail: "target reportOnly. Contradictory across studies; see the source below."),
                retentionRule: "n/a",
                grade: .b,
                source: "Contradictory across studies: Wang et al. 2026 (makes higher, d = 1.85 but a suspiciously uniform effect size across every variable), Cabarkapa 2023 (misses higher, ES 0.161), Amaro et al. 2025 (ρ = 0.116, η²p < 0.01, n = 18 national-level, 710 shots). \"Release as high as possible\" is C at best and contradicted at worst.",
                trialSuggestion: nil)
        }
    }

    // MARK: - Pass checks the app computes from the next session

    public struct PassCheckResult: Sendable {
        /// Nil when the check could not be computed — never a silent false.
        public var passed: Bool?
        public var baselineValue: Double?
        public var followUpValue: Double?
        public var target: Double?
        public var n: Int?
        public var sentence: String
    }

    public struct RetentionResult: Sendable {
        /// Nil when it could not be computed.
        public var held: Bool?
        public var sentence: String
    }

    /// Reads one number out of a diagnosis. Nil (with no reason here — the caller supplies the words)
    /// when the measure is not present.
    static func value(_ m: PassMeasure, _ d: Diagnosis, spot: DoctorSpot?, scope: PassSpotScope) -> (value: Double, n: Int)? {
        let target: SpotProfile?
        switch scope {
        case .findingSpot: target = spot.flatMap { s in d.distance.profiles.first { $0.spot == s } } ?? d.distance.profiles.first
        case .farSpot: target = d.distance.profiles.last
        case .acrossDistance: target = nil
        }
        switch m {
        case .releaseSpeedSD:
            guard let p = target, let s = p.releaseSpeed else { return nil }
            return (s.sd, s.n)
        case .releaseSpeedSDRatioAcrossDistance:
            guard let a = d.distance.profiles.first?.releaseSpeed, let b = d.distance.profiles.last?.releaseSpeed,
                  a.sd > 1e-9 else { return nil }
            return (b.sd / a.sd, min(a.n, b.n))
        case .entryAngleMeanDegrees:
            guard let p = target, let e = p.entryAngle else { return nil }
            return (Angle.degrees(e.mean), e.n)
        case .depthMeanCm:
            guard let p = target, let x = p.depthPastFrontRim else { return nil }
            return (x.mean * 100, x.n)
        case .depthSDCm:
            guard let p = target, let x = p.depthPastFrontRim else { return nil }
            return (x.sd * 100, x.n)
        case .lateralMeanCm:
            guard let p = target, let x = p.lateralDeviation else { return nil }
            return (x.mean * 100, x.n)
        case .lateralSDCm:
            guard let p = target, let x = p.lateralDeviation else { return nil }
            return (x.sd * 100, x.n)
        case .dipToReleaseMean:
            guard let p = target, let x = p.dipToRelease else { return nil }
            return (x.mean, x.n)
        case .dipToReleaseChangeAcrossDistance:
            guard let a = d.distance.profiles.first?.dipToRelease, let b = d.distance.profiles.last?.dipToRelease else { return nil }
            return (b.mean - a.mean, min(a.n, b.n))
        case .speedShareOfDepthVariance:
            guard let s = spot.flatMap({ d.spot($0) }) ?? d.perSpot.first, let a = s.attribution else { return nil }
            return (a.speedShare, s.n)
        case .spinAxisTiltDegrees, .forearmFromVerticalDegrees, .kneeDriveChangeAcrossDistance,
             .proximalToDistalRate, .headStabilityNormalised, .depthTotalChangeOverSession:
            return nil   // body/spin measures live on the records, not on the diagnosis; the caller says so
        }
    }

    /// Did the next session pass? `baseline` is the session the finding came from, `followUp` the next one.
    public static func check(_ c: PassCheck, baseline: Diagnosis, followUp: Diagnosis,
                             spot: DoctorSpot?) -> PassCheckResult {
        guard let b = value(c.measure, baseline, spot: spot, scope: c.scope) else {
            return PassCheckResult(passed: nil, baselineValue: nil, followUpValue: nil, target: nil, n: nil,
                                   sentence: "The baseline session has no \(c.measure.rawValue) to check against, so this plan cannot be scored yet.")
        }
        guard let f = value(c.measure, followUp, spot: spot, scope: c.scope) else {
            return PassCheckResult(passed: nil, baselineValue: b.value, followUpValue: nil, target: nil, n: nil,
                                   sentence: "The follow-up session has no \(c.measure.rawValue), so this plan cannot be scored yet.")
        }
        guard f.n >= c.minimumN else {
            return PassCheckResult(passed: nil, baselineValue: b.value, followUpValue: f.value, target: nil, n: f.n,
                                   sentence: "The follow-up session has \(f.n) shots and this check needs \(c.minimumN). Not a fail — not enough shots to tell.")
        }
        switch c.target {
        case .reportOnly:
            return PassCheckResult(passed: nil, baselineValue: b.value, followUpValue: f.value, target: nil, n: f.n,
                                   sentence: String(format: "%.3f → %.3f (n=%d). Reported, not scored: %@", b.value, f.value, f.n, c.description))
        case .narrowByDetectableRatio:
            guard let ratio = DoctorStats.detectableSDRatio(n: min(b.n, f.n)) else {
                return PassCheckResult(passed: nil, baselineValue: b.value, followUpValue: f.value, target: nil, n: f.n,
                                       sentence: "Too few shots to set an honest target.")
            }
            let t = b.value / ratio
            let passed = f.value <= t
            return PassCheckResult(passed: passed, baselineValue: b.value, followUpValue: f.value, target: t, n: f.n,
                                   sentence: String(format: "%.3f → %.3f against a target of %.3f (baseline ÷ %.2f, the smallest change %d shots can see): %@.",
                                                    b.value, f.value, t, ratio, min(b.n, f.n), passed ? "passed" : "not yet"))
        case .narrowByFraction(let k):
            let t = b.value * k
            let passed = f.value <= t
            return PassCheckResult(passed: passed, baselineValue: b.value, followUpValue: f.value, target: t, n: f.n,
                                   sentence: String(format: "%.3f → %.3f against a target of %.3f: %@.", b.value, f.value, t, passed ? "passed" : "not yet"))
        case .insideBand(let lo, let hi):
            let passed = f.value >= lo && f.value <= hi
            return PassCheckResult(passed: passed, baselineValue: b.value, followUpValue: f.value, target: (lo + hi) / 2, n: f.n,
                                   sentence: String(format: "%.2f → %.2f against a band of %.2f–%.2f: %@.", b.value, f.value, lo, hi, passed ? "passed" : "not yet"))
        case .moveBy(let delta):
            let passed = abs(f.value - b.value) >= delta && (f.value - b.value) * delta >= 0
            return PassCheckResult(passed: passed, baselineValue: b.value, followUpValue: f.value, target: b.value + delta, n: f.n,
                                   sentence: String(format: "%.3f → %.3f, needed a move of at least %.3f: %@.", b.value, f.value, delta, passed ? "passed" : "not yet"))
        }
    }

    /// The change is only credited if it is still there the session after (`DESIGN-MEMO` C2).
    public static func retention(_ c: PassCheck, baseline: Diagnosis, followUp: Diagnosis,
                                 retention: Diagnosis, spot: DoctorSpot?) -> RetentionResult {
        let first = check(c, baseline: baseline, followUp: followUp, spot: spot)
        let second = check(c, baseline: baseline, followUp: retention, spot: spot)
        guard let a = first.passed, let b = second.passed else {
            return RetentionResult(held: nil, sentence: "Not enough shots yet to tell whether it stuck. \(first.sentence) \(second.sentence)")
        }
        if a && b { return RetentionResult(held: true, sentence: "The change held: it passed in the session you practised it and again in the session after, unprompted. \(second.sentence)") }
        if a && !b { return RetentionResult(held: false, sentence: "Practised, not learned: it passed straight after the drill and did not survive to the next session. \(second.sentence)") }
        if !a && b { return RetentionResult(held: true, sentence: "Late, but it arrived: the change did not show in the first follow-up and did in the second. \(second.sentence)") }
        return RetentionResult(held: false, sentence: "No change either session. \(second.sentence)")
    }
}
