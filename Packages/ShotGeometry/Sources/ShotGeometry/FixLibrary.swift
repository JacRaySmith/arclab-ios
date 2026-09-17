import Foundation

// MARK: - What a fix is made of

public struct Drill: Sendable {
    public var name: String
    /// Shots per set.
    public var reps: Int
    public var sets: Int
    /// Where to shoot them. Empty means "wherever the finding was".
    public var spots: [DoctorSpot]
    /// The constraint that makes the drill a drill rather than shooting around.
    public var constraint: String
    /// Blocked while a change is new, random once it holds (`DESIGN-MEMO` C4; Shamshiri 2025:
    /// blocked wins acquisition, loses retention and transfer).
    public var schedule: String

    public var totalShots: Int { reps * sets }
}

public enum PassMeasure: String, Sendable, Codable {
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
    /// What the shooter is told to expect, in words.
    public var description: String
    /// Below this the check is not run and says so.
    public var minimumN: Int
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
                             constraint: "Five shots at each of four distances, four rounds. Step back only after two shots in a row cross inside your own make band; step forward again the moment three in a row miss it.",
                             schedule: "Blocked by distance for the first two sessions, then shuffled — blocked practice wins during acquisition and loses on retention and transfer (Shamshiri 2025, ηp² = 0.24)."),
                measureThatShouldMove: "release-speed SD at your farthest spot",
                expectedMagnitude: "With 30 shots at that spot the smallest narrowing that can be told from chance is about 1.4×, so aim to bring the far-spot SD down to roughly your near-spot SD × 1.4 — not to a number, to a ratio.",
                passCheck: PassCheck(measure: .releaseSpeedSD, scope: .farSpot, target: .narrowByDetectableRatio,
                                     description: "next session's release-speed SD at the far spot at or below this session's ÷ the detectable ratio",
                                     minimumN: 25),
                retentionRule: "The narrowing must still be there in the session after next, measured on the first two counted sets after warm-up — that set is the retention test for the change, not the end of the session that practised it.",
                grade: .a,
                source: "Slegers, Lee & Wong 2021 JSSM: skilled velocity SD was the same at free-throw and 3-point range and correlated r = −0.96 with 3P%. Variable-distance practice: Shoenfelt et al. 2002 (equalled constant practice on delayed retention), grade B.",
                trialSuggestion: "Worth a randomized cue trial: alternate sets of \"same spot on the back of the ring\" against your normal routine, at the far spot only, set as the unit, and read set-level speed SD. Expect to need 12 sets per arm across two or three sessions before the interval means anything.")

        case .speedVariability:
            return FixPackage(
                hypothesis: id,
                cue: "Finish every shot with the ball leaving the same two fingers at the same moment.",
                drill: Drill(name: "One-spot depth band", reps: 10, sets: 8, spots: [],
                             constraint: "Same spot all session. A shot counts only if it crosses inside your own make band; makes that come in short or long are called out as misses.",
                             schedule: "Blocked. This is an acquisition drill for a new feel."),
                measureThatShouldMove: "release-speed SD at the spot the finding was made at",
                expectedMagnitude: "Below 100 shots per side no honest claim of a narrowing smaller than 20 % can be made; plan on two or three sessions before the number means anything.",
                passCheck: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot, target: .narrowByDetectableRatio,
                                     description: "next session's release-speed SD at or below this session's ÷ the detectable ratio",
                                     minimumN: 25),
                retentionRule: "The narrower SD must appear again in the first two counted sets of the following session, unprompted.",
                grade: .a,
                source: "Slegers 2021 (speed SD is the strongest measured correlate); delta-method attribution, textbook Ch 5; detectability floor, DESIGN-MEMO §3.5.",
                trialSuggestion: nil)

        case .speedUndershoot:
            return FixPackage(
                hypothesis: id,
                cue: "Send it over the front rim to the back of the ring, every time.",
                drill: Drill(name: "Back-of-the-ring block", reps: 10, sets: 6, spots: [],
                             constraint: "Aim at the back of the ring. A shot that touches the front rim does not count, even if it goes in.",
                             schedule: "Blocked while the feel is new."),
                measureThatShouldMove: "mean crossing depth at the finding's spot",
                expectedMagnitude: "Aiming at the back rather than the front of the ring is a 5–10 cm mean shift, which is about the smallest a set of ten can see (a set-of-10 mean depth has a standard error of 4.7 cm).",
                passCheck: PassCheck(measure: .depthMeanCm, scope: .findingSpot,
                                     target: .insideBand(low: ShotDoctor.publishedMakeDepthBand.low * 100,
                                                         high: ShotDoctor.publishedMakeDepthBand.high * 100),
                                     description: "next session's mean crossing between 25 and 28 cm past the front rim",
                                     minimumN: 20),
                retentionRule: "The mean must still sit in the band in the following session's first two counted sets, pooled across three session pairs before it is called a change.",
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019 JQAS: make probability peaked 25–28 cm past the front rim over >50 000 NBA 3-point trajectories. Mullineaux & Uhl 2010: misses released 0.12 m/s slow, swishes 0.02 m/s.",
                trialSuggestion: "This is the textbook randomized cue trial: \"back of the ring\" against \"normal\", alternating sets, mean depth as the outcome. It is one of the few cues large enough to be detectable in a single session.")

        case .rushedPreparation:
            return FixPackage(
                hypothesis: id,
                cue: "Let the ball sit in the dip for a beat before you send it.",
                drill: Drill(name: "Metronome dip", reps: 8, sets: 8, spots: [],
                             constraint: "Shoot to a metronome set to your own near-spot dip→release time. The shot leaves on the second click, from every distance.",
                             schedule: "Blocked, near spot first, then the far spot with the same tempo."),
                measureThatShouldMove: "dip→release time at your far spot, and its SD",
                expectedMagnitude: "The target is your own near-spot tempo, not a published number: there is no published reference range for dip-to-release at all.",
                passCheck: PassCheck(measure: .dipToReleaseChangeAcrossDistance, scope: .acrossDistance,
                                     target: .moveBy(0.05),
                                     description: "the far-spot dip→release moves at least 0.05 s back toward the near-spot value",
                                     minimumN: 20),
                retentionRule: "The far-spot tempo must still be within one near-spot SD of the near-spot tempo in the following session, without the metronome.",
                grade: .b,
                source: "Cabarkapa et al. 2023 Front Sports Act Living: proficient shooters moved slower and lower in preparation (knee peak 212.9 vs 269.4 °/s, ES 1.04) with no release-phase differences. Botsi et al. 2024: higher-level U18s released 12.5 % faster — direction only, and the two findings pull opposite ways, so only your own consistency is read.",
                trialSuggestion: "Because the literature disagrees on direction, run this as a trial rather than a prescription: alternate metronome sets against normal sets and read set-level depth SD.")

        case .armDominantDrive:
            return FixPackage(
                hypothesis: id,
                cue: "Push the floor away and let the ball go on the way up.",
                drill: Drill(name: "Step-in range extension", reps: 6, sets: 8, spots: [.midRange, .three],
                             constraint: "One step into the shot from behind the line so the legs supply the extra distance. Then repeat the same shot standing still and compare.",
                             schedule: "Alternating pairs: one stepping set, one standing set."),
                measureThatShouldMove: "knee-extension peak rate at the far spot, and release-speed SD with it",
                expectedMagnitude: "No published target exists for knee-extension peak rate on an individual, so the comparison is your stepping sets against your standing sets in the same session.",
                passCheck: PassCheck(measure: .kneeDriveChangeAcrossDistance, scope: .acrossDistance,
                                     target: .reportOnly,
                                     description: "knee-extension peak rate rises with distance instead of staying flat — reported, not scored, because no reference range exists",
                                     minimumN: 15),
                retentionRule: "The far-spot release-speed SD must be narrower in the following session; the joint number is context, not the score.",
                grade: .b,
                source: "Cabarkapa et al. 2023 (knee peak angular velocity separates proficient from non-proficient, recreational sample, between groups); Okazaki & Rodacki 2012 (experts showed no significant ankle/knee/hip change with distance and compensated with speed). Requires a close form clip; ArcLab's metre-scale body numbers are not trusted yet.",
                trialSuggestion: nil)

        case .flatArcGeometry:
            return FixPackage(
                hypothesis: id,
                cue: "Drop it through the top of the ring, not through the front of it.",
                drill: Drill(name: "Over-the-top", reps: 10, sets: 6, spots: [],
                             constraint: "A helper holds a pole (or you imagine a bar) a metre in front of the rim at rim height plus half a metre. Any shot that would clip it does not count.",
                             schedule: "Blocked."),
                measureThatShouldMove: "mean entry angle at the finding's spot",
                expectedMagnitude: "Getting from below 40° to above it buys real margin — under 40° the ball has less than 3 cm of room; at the geometric floor it has none. Above the mid-40s there is nothing more to gain: entry is the least peaked of the three rim-plane variables.",
                passCheck: PassCheck(measure: .entryAngleMeanDegrees, scope: .findingSpot,
                                     target: .insideBand(low: 40, high: 52),
                                     description: "next session's mean entry angle at or above 40° and not chasing past the mid-40s",
                                     minimumN: 20),
                retentionRule: "Entry angle must still clear 40° in the following session's first two counted sets, and depth SD must not have widened to buy it.",
                grade: .a,
                source: "Exact geometry: asin(d_ball/d_rim) floor: 31.4° for a 0.2385 m ball, 32.1° at the top of the rulebook tolerance, under 3 cm of margin by 40°. Daly-Grafstein & Bornn 2020 for the band being flat over a range; \"45° for everyone\" is a vendor claim with no published method (grade D).",
                trialSuggestion: nil)

        case .arcVersusTurnover:
            return FixPackage(
                hypothesis: id,
                cue: "Same height on the ball every time; let the distance come from the legs, not from the arc.",
                drill: Drill(name: "Arc hold", reps: 10, sets: 6, spots: [],
                             constraint: "One spot, one arc. Shots are graded on whether the arc repeated, not on whether they went in.",
                             schedule: "Blocked."),
                measureThatShouldMove: "the pairwise θ–speed variance term, and depth SD with it",
                expectedMagnitude: "This is arithmetic, not a training effect: if your angle and speed errors stop moving together, the pairwise term goes negative and your depth SD falls without either channel getting tighter.",
                passCheck: PassCheck(measure: .depthSDCm, scope: .findingSpot, target: .narrowByDetectableRatio,
                                     description: "next session's depth SD at or below this session's ÷ the detectable ratio",
                                     minimumN: 25),
                retentionRule: "The narrower depth SD must repeat in the following session; a one-session drop of this size is within what noise can produce.",
                grade: .a,
                source: "Geometry per shot (`ReleaseSensitivity.depthTurnoverAngle`); textbook Ch 5 §5.4 — the pairwise term 2·Jθ·Jv·Cov(θ,v) helps only when its sign is negative, which is not the same as Cov(θ,v) being negative. Slegers 2022: each shooter's optimal angle sits 4.3 ± 2.1° above their own minimum-speed angle and correlates r = 0.78 with their own release covariance.",
                trialSuggestion: nil)

        case .depthBiasShort:
            var p = package(for: .speedUndershoot)
            p.hypothesis = id
            p.measureThatShouldMove = "mean crossing depth at the finding's spot — the whole cloud, not the misses"
            return p

        case .depthBiasLong:
            return FixPackage(
                hypothesis: id,
                cue: "Drop it just past the front rim, not onto the back of the ring.",
                drill: Drill(name: "Front-half band", reps: 10, sets: 6, spots: [],
                             constraint: "Aim to land the ball in the first half of the ring. Anything that touches the back iron does not count.",
                             schedule: "Blocked."),
                measureThatShouldMove: "mean crossing depth at the finding's spot",
                expectedMagnitude: "A front/back aim change is a 5–10 cm mean shift, at the edge of what a set of ten can resolve.",
                passCheck: PassCheck(measure: .depthMeanCm, scope: .findingSpot,
                                     target: .insideBand(low: ShotDoctor.publishedMakeDepthBand.low * 100,
                                                         high: ShotDoctor.publishedMakeDepthBand.high * 100),
                                     description: "next session's mean crossing between 25 and 28 cm past the front rim",
                                     minimumN: 20),
                retentionRule: "The mean must hold in the band across three session pairs before the shift is called real — one pair can only see a 13 cm change.",
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019 JQAS, as above.",
                trialSuggestion: "Front-of-ring versus back-of-ring is the single best-powered cue trial available: a 5–10 cm mean shift with sets as the unit.")

        case .lateralAimBias:
            return FixPackage(
                hypothesis: id,
                cue: "Send it over the middle of the ring, between the two side hooks.",
                drill: Drill(name: "Behind-camera line set", reps: 10, sets: 4, spots: [],
                             constraint: "Every set filmed from directly behind you so left/right is measured, not felt.",
                             schedule: "Blocked."),
                measureThatShouldMove: "mean left-right offset at the rim",
                expectedMagnitude: "The ring leaves the ball's centre about 11 cm either side. Moving a mean offset from 6 cm to under 3 cm is a real change; chasing zero is not, because the mean is near zero in professionals and it is the spread that predicts.",
                passCheck: PassCheck(measure: .lateralMeanCm, scope: .findingSpot, target: .insideBand(low: -3, high: 3),
                                     description: "next session's mean left-right offset inside ±3 cm",
                                     minimumN: 20),
                retentionRule: "The centred mean must survive into the following session's first two counted sets, filmed from behind again.",
                grade: .a,
                source: "Daly-Grafstein & Bornn 2019/2020: mean offset near zero in professionals; the variance, not the mean, predicts, and in-game contests raise lateral variance 38 % without moving the mean. The ±11 cm tolerance is exact ring geometry.",
                trialSuggestion: nil)

        case .lateralVariability:
            var p = package(for: .lateralAimBias)
            p.hypothesis = id
            p.cue = "Finish with your hand pointing down the middle of the ring and hold it there until the ball lands."
            p.measureThatShouldMove = "left-right SD at the rim"
            p.passCheck = PassCheck(measure: .lateralSDCm, scope: .findingSpot, target: .narrowByDetectableRatio,
                                    description: "next session's left-right SD at or below this session's ÷ the detectable ratio",
                                    minimumN: 25)
            p.expectedMagnitude = "Below 100 shots per side no narrowing smaller than 20 % can be claimed honestly."
            return p

        case .spinAxisTilt:
            return FixPackage(
                hypothesis: id,
                cue: "Roll the ball off the two middle fingers so it comes back straight at you.",
                drill: Drill(name: "Taped-stripe spin set", reps: 10, sets: 4, spots: [],
                             constraint: "One strip of tape around the ball's seam, camera behind you. Watch the stripe, not the result.",
                             schedule: "Blocked, near spot first: spin axis is easier to control before the distance forces effort."),
                measureThatShouldMove: "spin-axis tilt from pure backspin, and left-right SD with it",
                expectedMagnitude: "A 0.2 rev/s sidespin component shows as roughly 20° of axis tilt at 120 fps; the measurement resolves 2–3° per frame, so a 10° change is visible.",
                passCheck: PassCheck(measure: .spinAxisTiltDegrees, scope: .findingSpot, target: .insideBand(low: -10, high: 10),
                                     description: "next session's mean spin-axis tilt inside ±10°",
                                     minimumN: 15),
                retentionRule: "Tilt must stay inside ±10° in the following session and left-right SD must not have widened.",
                grade: .b,
                source: "Spin-axis consistency correlates r = 0.80 with left-right consistency (healthy-shot model §6 row 4). Feasibility and resolution: DESIGN-MEMO §3.7. Needs the behind-the-shooter clip and the taped-stripe mode.",
                trialSuggestion: nil)

        case .forearmFlare:
            return FixPackage(
                hypothesis: id,
                cue: "Send the ball up the same line your arm is already on.",
                drill: Drill(name: "Wall-line form set", reps: 10, sets: 4, spots: [.freeThrow],
                             constraint: "Shoot along a floor line, filmed from behind, so the forearm's frontal plane is visible.",
                             schedule: "Blocked, close range."),
                measureThatShouldMove: "forearm-from-vertical in the frontal plane",
                expectedMagnitude: "The published groups sat at 7.9 ± 7.2° (proficient) and 19.8 ± 17.6° (non-proficient) — between groups, n = 17 recreationally active males. Those are where two groups sat, not a target for you.",
                passCheck: PassCheck(measure: .forearmFromVerticalDegrees, scope: .findingSpot, target: .narrowByFraction(0.8),
                                     description: "next session's mean forearm-from-vertical at or below 80 % of this session's",
                                     minimumN: 15),
                retentionRule: "The reduced flare must appear in the following session's behind-camera set without a reminder.",
                grade: .b,
                source: "Cabarkapa & Fry 2021 CEJSSM. Between-group, recreational, one session. Note the grade-A null against importing a joint target at all: excellent and good professionals showed no kinematic differences (Cabarkapa et al. 2022).",
                trialSuggestion: nil)

        case .shoulderSquareness:
            return FixPackage(
                hypothesis: id,
                cue: "Start every shot facing the same way you finish.",
                drill: Drill(name: "Same-feet repeat", reps: 10, sets: 4, spots: [],
                             constraint: "Chalk your feet. Every shot starts from the same two marks.",
                             schedule: "Blocked."),
                measureThatShouldMove: "your own shoulder-line yaw SD — never its mean",
                expectedMagnitude: "No published squareness range exists, so there is no magnitude to expect. Only your own repeatability can change.",
                passCheck: PassCheck(measure: .headStabilityNormalised, scope: .findingSpot, target: .reportOnly,
                                     description: "reported only — there is no published range to pass or fail against",
                                     minimumN: 15),
                retentionRule: "Reported across sessions as a consistency trend; never scored.",
                grade: .c,
                source: "No published range at all; coaching consensus only. ArcLab's 3-D shoulder yaw from a near-side view is refused outright, and from other views is in the noisy class.",
                trialSuggestion: nil)

        case .withinSessionDrift:
            return FixPackage(
                hypothesis: id,
                cue: "Treat the last set like the first one: same routine, same tempo.",
                drill: Drill(name: "Bookend sets", reps: 10, sets: 6, spots: [],
                             constraint: "Two counted sets at the start, two at the end, the same spot, with rest between blocks. The middle is free shooting.",
                             schedule: "Blocked bookends around whatever else the session holds."),
                measureThatShouldMove: "total change in crossing depth from the first shot to the last",
                expectedMagnitude: "A set-of-10 mean depth has a standard error of 4.7 cm, so a single first/last pair can only see a 13 cm change; pool three session pairs to see 7.6 cm.",
                passCheck: PassCheck(measure: .depthTotalChangeOverSession, scope: .findingSpot, target: .narrowByFraction(0.5),
                                     description: "next session's end-to-end depth change at or below half this session's",
                                     minimumN: 20),
                retentionRule: "The flatter session profile must appear again in the following session; one flat session is inside what noise produces.",
                grade: .a,
                source: "Textbook Ch 15 §15.3.4 (report the total change across the session, not the slope, not a p-value). That drift can happen is established (Bourdas et al. 2024); that it happens to you is measured, never assumed (Slawinski et al. 2018 found none in elite U18s).",
                trialSuggestion: nil)

        case .fatigueDrift:
            return FixPackage(
                hypothesis: id,
                cue: "Push the floor away on the last set exactly as hard as on the first.",
                drill: Drill(name: "Rested blocks", reps: 10, sets: 6, spots: [],
                             constraint: "Sixty seconds of rest between sets, and the session stops at the set where entry angle has fallen a full session SD rather than pushing through it.",
                             schedule: "Blocked, with the rest interval as the variable under test."),
                measureThatShouldMove: "entry angle from the start of the session to the end",
                expectedMagnitude: "The measured fatigue signature is entry angle −3 to −4 % and release time +15–25 % after 12 minutes of simulated game load. Your own number is the one that counts.",
                passCheck: PassCheck(measure: .entryAngleMeanDegrees, scope: .findingSpot, target: .reportOnly,
                                     description: "next session's end-to-end entry-angle change smaller than this session's — reported against your own history, since no reliability SD exists yet",
                                     minimumN: 20),
                retentionRule: "Two consecutive sessions without the fall before the rest interval is credited.",
                grade: .a,
                source: "Bourdas et al. 2024 (entry −3.1 to −3.9 %, release time +15–25 %, makes −14 to −19 % after simulated game load); Li et al. 2025 meta (accuracy SMD 0.67 moderate, 1.39 severe); Slawinski et al. 2018 (zero change in elite U18s after sprints).",
                trialSuggestion: nil)

        case .sequencingDistalDominant:
            return FixPackage(
                hypothesis: id,
                cue: "Start the shot from the floor and let the ball be the last thing that moves.",
                drill: Drill(name: "Slow-to-fast chain", reps: 8, sets: 6, spots: [.freeThrow, .elbow],
                             constraint: "Half-speed shots filmed close and waist-up, then full speed. The order — shoulder before elbow before wrist — is what is graded, not the make.",
                             schedule: "Blocked, close range only until the order repeats."),
                measureThatShouldMove: "the fraction of shots where the shoulder leads the elbow",
                expectedMagnitude: "The published finding is a pattern, not a number: collegiate players were proximal-dominant at short range, recreational players distal-dominant. No lag in milliseconds has ever been published, so ArcLab never scores one.",
                passCheck: PassCheck(measure: .proximalToDistalRate, scope: .findingSpot, target: .insideBand(low: 0.5, high: 1.0),
                                     description: "next session's proximal-to-distal rate at or above 50 %",
                                     minimumN: 15),
                retentionRule: "The order must hold at full speed and at the far spot, not only in the slow sets.",
                grade: .b,
                source: "Jiang et al. 2025 J Hum Kinet, 20 players, 13-camera 240 Hz, 3 successful shots per distance per player. Needs a close form clip.",
                trialSuggestion: nil)

        case .headInstability:
            return FixPackage(
                hypothesis: id,
                cue: "Keep your eyes on the back of the ring until the ball lands.",
                drill: Drill(name: "Hold the look", reps: 10, sets: 4, spots: [],
                             constraint: "Eyes stay on the target through the follow-through; the shot does not count if you track the ball.",
                             schedule: "Blocked."),
                measureThatShouldMove: "head movement between dip and release, as a fraction of your own height",
                expectedMagnitude: "No published range exists in any unit ArcLab can measure, so only the direction of your own trend is readable.",
                passCheck: PassCheck(measure: .headStabilityNormalised, scope: .findingSpot, target: .narrowByFraction(0.8),
                                     description: "next session's head movement at or below 80 % of this session's — your own number, with no published range behind it",
                                     minimumN: 15),
                retentionRule: "Reported as a trend across three sessions; a single session's change is not a result.",
                grade: .b,
                source: "Ripoll et al. 1986 (head/eye stabilisation discriminates experts from beginners, small n, no retrievable effect size). The quiet-eye meta-analysis reports large effects on weak designs, and gaze is not measurable from a tripod — only head displacement is. Requires a close form clip and a fixed camera.",
                trialSuggestion: nil)

        case .releaseHeightDrift:
            return FixPackage(
                hypothesis: id,
                cue: "No cue. This measure has no agreed direction, so there is nothing honest to tell you to do.",
                drill: Drill(name: "None", reps: 0, sets: 0, spots: [],
                             constraint: "There is no drill, because there is no target. Release height is reported alongside your other numbers and watched for change.",
                             schedule: "n/a"),
                measureThatShouldMove: "nothing — release height is context for your release angle, not a lever",
                expectedMagnitude: "None claimed.",
                passCheck: PassCheck(measure: .releaseSpeedSD, scope: .findingSpot, target: .reportOnly,
                                     description: "reported only",
                                     minimumN: 20),
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
            return RetentionResult(held: nil, sentence: "Not enough to judge retention yet. \(first.sentence) \(second.sentence)")
        }
        if a && b { return RetentionResult(held: true, sentence: "The change held: it passed in the session you practised it and again in the session after, unprompted. \(second.sentence)") }
        if a && !b { return RetentionResult(held: false, sentence: "Practised, not learned: it passed straight after the drill and did not survive to the next session. \(second.sentence)") }
        if !a && b { return RetentionResult(held: true, sentence: "Late, but it arrived: the change did not show in the first follow-up and did in the second. \(second.sentence)") }
        return RetentionResult(held: false, sentence: "No change either session. \(second.sentence)")
    }
}
